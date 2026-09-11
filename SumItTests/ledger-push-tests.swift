import XCTest
import SwiftData
@testable import SumIt

/// PUSH group from acceptance-tests.md §7. The transport is a fake, so no test
/// touches the network; the store is file-backed, so every claim about what
/// survives is checked after a real close and reopen.
@MainActor
final class LedgerPushTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var store: LedgerStore!
    private var transport: FakeTransport!
    private var coordinator: LedgerSyncCoordinator!
    private var clock = LedgerIDs.testClock

    private let scope = AccountScope(ownerID: LedgerIDs.ownerA, epoch: UUID())

    // MARK: — Fake transport

    final class FakeTransport: LedgerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [LedgerMutationRequest] = []
        /// Answers one request. Set per test; may throw a transport error.
        nonisolated(unsafe) var handler: (@Sendable (LedgerMutationRequest, Int) throws -> LedgerMutationResult)?

        var requests: [LedgerMutationRequest] {
            lock.withLock { recorded }
        }

        func readLedgerChanges(after: Int64, through: Int64?, limit: Int,
                               scope: AccountScope) async throws -> LedgerChangePage {
            throw LedgerTransportError.unreachable   // these tests only push
        }

        func applyLedgerMutation(_ request: LedgerMutationRequest,
                                 scope: AccountScope) async throws -> LedgerMutationResult {
            let (attempt, handler) = lock.withLock {
                recorded.append(request)
                return (recorded.count, self.handler)
            }
            guard let handler else { throw LedgerTransportError.unreachable }
            return try handler(request, attempt)
        }
    }

    // MARK: — Setup

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        clock = LedgerIDs.testClock
        rebuild()
    }

    override func tearDownWithError() throws {
        coordinator = nil
        store = nil
        transport = nil
        context = nil
        try fixture?.destroy()
        fixture = nil
    }

    private func rebuild(persist: (() throws -> Void)? = nil) {
        context = ModelContext(fixture.container)
        store = LedgerStore(context: context)
        transport = FakeTransport()
        coordinator = LedgerSyncCoordinator(context: context,
                                            transport: transport,
                                            now: { [weak self] in self?.clock ?? Date() },
                                            persist: persist ?? { [context] in try context!.save() })
    }

    /// Closes the store, reopens the same files, and rebuilds everything on top.
    private func relaunch() throws {
        coordinator = nil
        store = nil
        context = nil
        try fixture.closeAndReopen()
        rebuild()
    }

    private func run() async {
        coordinator.trigger(scope: scope)
        await coordinator.waitUntilIdle()
    }

    // MARK: — Fixtures

    @discardableResult
    private func queueWallet(_ id: UUID = LedgerIDs.walletA) throws -> LocalSaveReceipt {
        try store.saveWallet(WalletDraft(id: id, name: "Monobank", type: .bank, currency: "USD",
                                         openingBalance: try MoneyCodec.decode("1000"), icon: ""),
                             scope: scope)
    }

    @discardableResult
    private func queueExpense(_ id: UUID = LedgerIDs.expense, amount: String = "12.5",
                              wallet: UUID? = LedgerIDs.walletA) throws -> LocalSaveReceipt {
        let value = try MoneyCodec.decode(amount)
        let draft = TransactionDraft(id: id, type: .expense, amount: value, currency: "USD",
                                     walletID: wallet, walletAmount: wallet == nil ? nil : value,
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: "Cafe", note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "",
                                     valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
        if (try? context.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == id })).first) != nil {
            return try store.editTransaction(draft, scope: scope)
        }
        return try store.saveTransaction(draft, scope: scope)
    }

    private func mutations() throws -> [PendingMutation] {
        try context.fetch(FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    // MARK: — PUSH-01, PUSH-02, PUSH-12

    /// Offline before the first send: the operation stays queued with its frozen
    /// bytes intact, and it is never discarded.
    func testOfflineKeepsTheOperationAndItsFrozenPayload() async throws {
        try queueWallet()
        transport.handler = { _, _ in throw LedgerTransportError.unreachable }

        await run()
        try relaunch()

        let queued = try XCTUnwrap(try mutations().first)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.lastErrorCode, "unreachable")
        XCTAssertNotNil(queued.frozenRequestJSON, "the frozen request must survive")
        XCTAssertNotNil(queued.nextAttemptAt)
    }

    /// PUSH-02. A relaunch retries the same operation id and the same content —
    /// it does not mint a replacement.
    func testRelaunchRetriesTheExactOperation() async throws {
        let receipt = try queueWallet()
        transport.handler = { _, _ in throw LedgerTransportError.unreachable }
        await run()

        try relaunch()
        clock = clock.addingTimeInterval(3600)          // past the backoff wait
        transport.handler = { request, _ in try acceptedResult(request, revision: 1, owner: LedgerIDs.ownerA) }
        await run()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].operationID, receipt.operationID)
        XCTAssertEqual(transport.requests[0].entityID, LedgerIDs.walletA)
        XCTAssertEqual(try mutations().first?.state, .completed)
    }

    /// PUSH-12. Long offline: no expiry, no deletion, still waiting.
    func testAnOperationIsNeverDiscardedHoweverLongItWaits() async throws {
        try queueWallet()
        transport.handler = { _, _ in throw LedgerTransportError.unreachable }

        for _ in 0..<8 {
            clock = clock.addingTimeInterval(86_400)     // a day per attempt
            await run()
        }
        try relaunch()

        let queued = try XCTUnwrap(try mutations().first)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertGreaterThanOrEqual(queued.attemptCount, 8)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 1)
    }

    // MARK: — PUSH-03: the server committed but the answer was lost

    func testUnknownOutcomeIsRetriedAndResolvesToOneEffect() async throws {
        try queueWallet()
        transport.handler = { request, attempt in
            if attempt == 1 { throw LedgerTransportError.unknownOutcome }
            return try acceptedResult(request, revision: 1, owner: LedgerIDs.ownerA)    // the server's stored receipt
        }

        await run()
        XCTAssertEqual(try mutations().first?.state, .queued, "an unknown outcome stays retryable")

        clock = clock.addingTimeInterval(3600)
        await run()

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].operationID, transport.requests[1].operationID,
                       "the replay must reuse the same operation id")
        XCTAssertEqual(try mutations().filter { $0.state == .completed }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Wallet>()), 1)
    }

    // MARK: — PUSH-04: the answer arrived but we could not write it down

    func testFailedAcknowledgmentLeavesTheOperationPending() async throws {
        try queueWallet()
        try context.save()

        // Fail every save from the moment the coordinator tries to record the ack.
        let frozen = TestFlag()
        rebuildWithFailingPersistAfterFreeze(shouldFail: { frozen.isRaised })
        transport.handler = { request, _ in
            frozen.raise()
            return try acceptedResult(request, revision: 1, owner: LedgerIDs.ownerA)
        }

        await run()
        try relaunch()

        let queued = try XCTUnwrap(try mutations().first)
        XCTAssertNotEqual(queued.state, .completed,
                          "an acknowledgment that was not written down is not an acknowledgment")
        XCTAssertNotNil(queued.frozenRequestJSON)
    }

    private func rebuildWithFailingPersistAfterFreeze(shouldFail: @escaping () -> Bool) {
        context = ModelContext(fixture.container)
        store = LedgerStore(context: context)
        transport = FakeTransport()
        coordinator = LedgerSyncCoordinator(
            context: context, transport: transport,
            now: { [weak self] in self?.clock ?? Date() },
            persist: { [context] in
                if shouldFail() { throw LedgerWriteError.persistence(code: "disk") }
                try context!.save()
            })
    }

    // MARK: — PUSH-05, PUSH-06: generations and ordering

    /// An acknowledgment for an older generation records the base revision but
    /// must not present the row as synced when a newer edit is waiting.
    func testAckForAnOlderGenerationDoesNotMarkTheNewerEditSynced() async throws {
        try queueWallet()
        transport.handler = { request, _ in try acceptedResult(request, revision: 1, owner: LedgerIDs.ownerA) }
        await run()

        try queueExpense(amount: "12.5")                 // generation 1
        try queueExpense(amount: "99.99")                // generation 2, queued behind it

        // Only answer the first transaction operation, then stop.
        transport.handler = { request, attempt in
            if request.entityKind == .transaction && attempt >= 2 {
                if attempt == 2 { return try acceptedResult(request, revision: 2, owner: LedgerIDs.ownerA) }
                throw LedgerTransportError.unreachable
            }
            return try acceptedResult(request, revision: 1, owner: LedgerIDs.ownerA)
        }
        await run()

        let transaction = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(transaction.amountExact, "99.99", "the newest local edit stands")
        XCTAssertEqual(transaction.serverRevision, 2, "the acknowledged base is recorded")
        XCTAssertFalse(transaction.isSynced,
                       "a newer generation is still pending, so this is not synced")

        let pending = try mutations().filter { $0.entityKind == .transaction }
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].state, .completed)
        XCTAssertNotEqual(pending[1].state, .completed)
    }

    /// PUSH-06. Three offline edits produce an ordered predecessor chain and the
    /// server ends at the latest draft.
    func testThreeOfflineEditsFormAnOrderedChain() async throws {
        try queueWallet()
        try queueExpense(amount: "10")
        try queueExpense(amount: "11")
        try queueExpense(amount: "12")

        let revision = TestCounter()
        transport.handler = { request, _ in
            try acceptedResult(request, revision: revision.next(), owner: LedgerIDs.ownerA)
        }
        await run()

        let sent = transport.requests.filter { $0.entityKind == .transaction }
        XCTAssertEqual(sent.count, 3)
        // Each write is made against the revision the previous one established.
        XCTAssertEqual(sent.map { $0.expectedRevision.value }, [0, 2, 3])

        let chain = try mutations().filter { $0.entityKind == .transaction }
        XCTAssertNil(chain[0].predecessorOperationID)
        XCTAssertEqual(chain[1].predecessorOperationID, chain[0].operationID)
        XCTAssertEqual(chain[2].predecessorOperationID, chain[1].operationID)
        XCTAssertTrue(chain.allSatisfy { $0.state == .completed })

        let transaction = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(transaction.amountExact, "12")
        XCTAssertTrue(transaction.isSynced)
    }

    // MARK: — PUSH-07: one dispatcher

    func testOverlappingTriggersRunOneDispatcher() async throws {
        try queueWallet()
        try queueExpense()
        let revision = TestCounter()
        transport.handler = { request, _ in
            try acceptedResult(request, revision: revision.next(), owner: LedgerIDs.ownerA)
        }

        coordinator.trigger(scope: scope)
        coordinator.trigger(scope: scope)
        coordinator.trigger(scope: scope)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(transport.requests.count, 2, "each operation is sent once, not once per trigger")
        XCTAssertEqual(Set(transport.requests.map(\.operationID)).count, 2)
    }

    // MARK: — PUSH-08: dependencies

    /// A transaction referencing a wallet whose creation has not been
    /// acknowledged must wait for it, not be rejected by the server.
    func testTransactionWaitsForItsWalletCreation() async throws {
        try queueWallet()
        try queueExpense()

        // The wallet's own operation never succeeds.
        transport.handler = { request, _ in
            if request.entityKind == .wallet { throw LedgerTransportError.unreachable }
            throw LedgerTransportError.protocolMismatch     // must never be reached
        }
        await run()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].entityKind, .wallet)

        let transactionOp = try XCTUnwrap(try mutations().first { $0.entityKind == .transaction })
        XCTAssertEqual(transactionOp.state, .queued)
        XCTAssertNil(transactionOp.frozenRequestJSON, "a dependent operation is not even frozen yet")
    }

    // MARK: — PUSH-09: conflicts

    /// A conflict blocks that entity and its successors, records an issue, and
    /// leaves independent entities free to sync.
    func testConflictBlocksItsEntityButNotOthers() async throws {
        try queueWallet()
        try queueExpense(LedgerIDs.expense)
        try queueExpense(LedgerIDs.cryptoExpense, amount: "1", wallet: nil)

        transport.handler = { request, _ in
            if request.entityID == LedgerIDs.expense { return try conflictResult(request) }
            return try acceptedResult(request, revision: 1, owner: LedgerIDs.ownerA)
        }
        await run()

        let issues = try context.fetch(FetchDescriptor<SyncIssue>())
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .conflict)
        XCTAssertEqual(issues.first?.entityID, LedgerIDs.expense)
        XCTAssertEqual(issues.first?.reason, "revision_mismatch")

        let all = try mutations()
        XCTAssertEqual(all.first { $0.entityID == LedgerIDs.expense }?.state, .blocked)
        XCTAssertEqual(all.first { $0.entityID == LedgerIDs.cryptoExpense }?.state, .completed,
                       "an independent entity still syncs")
    }

    /// An explicit Retry releases a blocked operation without rewriting it.
    func testRetryReleasesABlockedOperation() async throws {
        try queueWallet()
        transport.handler = { request, attempt in
            attempt == 1 ? try conflictResult(request) : try acceptedResult(request, revision: 3, owner: LedgerIDs.ownerA)
        }
        await run()

        let blocked = try XCTUnwrap(try mutations().first)
        XCTAssertEqual(blocked.state, .blocked)
        let frozenBefore = blocked.frozenRequestJSON

        try coordinator.retry(operationID: blocked.operationID, scope: scope)
        await coordinator.waitUntilIdle()

        let after = try XCTUnwrap(try mutations().first)
        XCTAssertEqual(after.state, .completed)
        XCTAssertEqual(after.frozenRequestJSON, frozenBefore, "Retry must not rewrite the request")
    }

    // MARK: — PUSH-10: account change

    func testResponseForAnotherAccountIsNotApplied() async throws {
        try queueWallet()
        transport.handler = { _, _ in throw LedgerTransportError.scopeChanged }
        await run()

        let queued = try XCTUnwrap(try mutations().first)
        XCTAssertNotEqual(queued.state, .completed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Wallet>()).first?.serverRevision, 0)
    }

    /// The signed-out local dataset is never dispatched.
    func testLocalOnlyScopeIsNeverDispatched() async throws {
        let localScope = AccountScope(ownerID: AccountScope.localOwnerID, epoch: UUID())
        try store.saveWallet(WalletDraft(id: LedgerIDs.walletB, name: "Cash", type: .cash,
                                         currency: "USD", openingBalance: 0, icon: ""),
                             scope: localScope)
        transport.handler = { _, _ in throw LedgerTransportError.protocolMismatch }

        coordinator.trigger(scope: localScope)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: — PUSH-11: bounded scheduling

    func testRetryAfterSchedulesWithoutDeletingTheOperation() async throws {
        try queueWallet()
        transport.handler = { _, _ in
            throw LedgerTransportError.retryable(status: 429, retryAfter: 300)
        }
        await run()

        let queued = try XCTUnwrap(try mutations().first)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.lastErrorCode, "retryable_429")
        let wait = try XCTUnwrap(queued.nextAttemptAt)
        XCTAssertEqual(wait.timeIntervalSince(clock), 300, accuracy: 1)

        // Still waiting: a trigger before the deadline sends nothing.
        await run()
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testBackoffGrowsAndNeverDiscards() async throws {
        try queueWallet()
        transport.handler = { _, _ in throw LedgerTransportError.unreachable }

        var previous: TimeInterval = 0
        for _ in 0..<4 {
            await run()
            let queued = try XCTUnwrap(try mutations().first)
            let wait = try XCTUnwrap(queued.nextAttemptAt).timeIntervalSince(clock)
            XCTAssertGreaterThanOrEqual(wait, previous, "backoff must not shrink")
            previous = wait
            clock = clock.addingTimeInterval(wait + 1)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 1)
    }
}

// These build server answers for the fake transport. They are free functions so
// the nonisolated handler closure can call them without hopping actors.
nonisolated private func acceptedResult(_ request: LedgerMutationRequest, revision: Int64,
                            owner: String) throws -> LedgerMutationResult {
    let entity = request.entityID.uuidString.lowercased()
    let body: String
    if request.entityKind == .wallet {
        body = """
        {"entity_kind":"wallet","local_id":"\(entity)","user_id":"\(owner)",
         "ledger_revision":"\(revision)","deleted_at":null,"ledger_version":1,
         "name":"Monobank","type":"bank","currency":"USD","opening_balance":"1000","icon":"",
         "created_at":"2026-05-19T12:00:00Z"}
        """
    } else {
        body = """
        {"entity_kind":"transaction","local_id":"\(entity)","user_id":"\(owner)",
         "ledger_revision":"\(revision)","deleted_at":null,"ledger_version":1,
         "type":"expense","original_amount":"12.5","original_currency":"USD",
         "wallet_id":null,"wallet_amount":null,"destination_wallet_id":null,"destination_amount":null,
         "category_name":"Food","merchant":"Cafe","note":"","occurred_at":"2026-05-19T12:00:00Z",
         "source":"manual","confidence":"1","raw_input":"","base_amount":null,"usd_per_unit":null,
         "valuation_state":"unvalued","quote":null,"created_at":"2026-05-19T12:00:00Z"}
        """
    }
    let json = """
    {"status":"accepted","operation_id":"\(request.operationID.uuidString.lowercased())",
     "entity_id":"\(entity)","revision":"\(revision)","cursor":"\(revision)",
     "snapshot":\(body)}
    """
    return try JSONDecoder().decode(LedgerMutationResult.self, from: Data(json.utf8))
}

nonisolated private func conflictResult(_ request: LedgerMutationRequest) throws -> LedgerMutationResult {
    let json = """
    {"status":"conflict","operation_id":"\(request.operationID.uuidString.lowercased())",
     "entity_id":"\(request.entityID.uuidString.lowercased())",
     "expected_revision":"0","actual_revision":"7","reason":"revision_mismatch",
     "server_snapshot":null}
    """
    return try JSONDecoder().decode(LedgerMutationResult.self, from: Data(json.utf8))
}
