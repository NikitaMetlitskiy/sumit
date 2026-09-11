import XCTest
import SwiftData
@testable import SumIt

/// REST group from acceptance-tests.md §8. The feed is a fake; the store is
/// file-backed, so "restore twice gives the same dataset" is checked against
/// what is actually on disk.
@MainActor
final class LedgerRestoreTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var store: LedgerStore!
    private var feed: FakeFeed!
    private var coordinator: LedgerSyncCoordinator!

    private let scope = AccountScope(ownerID: LedgerIDs.ownerA, epoch: UUID())

    // MARK: — Fake feed

    final class FakeFeed: LedgerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: LedgerChangePage] = [:]
        private var recorded: [(after: Int64, through: Int64?)] = []
        nonisolated(unsafe) var failure: LedgerTransportError?

        var calls: [(after: Int64, through: Int64?)] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func setPage(after: Int64, _ page: LedgerChangePage) {
            lock.lock(); pages["\(after)"] = page; lock.unlock()
        }

        func applyLedgerMutation(_ request: LedgerMutationRequest,
                                 scope: AccountScope) async throws -> LedgerMutationResult {
            throw LedgerTransportError.unreachable
        }

        func readLedgerChanges(after: Int64, through: Int64?, limit: Int,
                               scope: AccountScope) async throws -> LedgerChangePage {
            lock.lock()
            recorded.append((after, through))
            let page = pages["\(after)"]
            let failure = self.failure
            lock.unlock()
            if let failure { throw failure }
            guard let page else { throw LedgerTransportError.unknownOutcome }
            return page
        }
    }

    // MARK: — Setup

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        rebuild()
    }

    override func tearDownWithError() throws {
        coordinator = nil
        store = nil
        feed = nil
        context = nil
        try fixture?.destroy()
        fixture = nil
    }

    private func rebuild(persist: (() throws -> Void)? = nil) {
        context = ModelContext(fixture.container)
        store = LedgerStore(context: context)
        feed = FakeFeed()
        coordinator = LedgerSyncCoordinator(context: context, transport: feed,
                                            now: { LedgerIDs.testClock },
                                            persist: persist ?? { [context] in try context!.save() })
    }

    private func relaunch() throws {
        coordinator = nil; store = nil; context = nil
        try fixture.closeAndReopen()
        rebuild()
    }

    // MARK: — Page building

    private func transactionSnapshot(id: String, revision: Int64, amount: String = "12.5",
                                     merchant: String = "Cafe", deletedAt: String = "null",
                                     walletID: String = "null",
                                     occurredAt: String = "2026-05-19T12:00:00Z",
                                     owner: String? = nil) -> String {
        """
        {"entity_kind":"transaction","local_id":"\(id)","user_id":"\(owner ?? scope.ownerID)",
         "ledger_revision":"\(revision)","deleted_at":\(deletedAt),"ledger_version":1,
         "type":"expense","original_amount":"\(amount)","original_currency":"USD",
         "wallet_id":\(walletID),"wallet_amount":null,
         "destination_wallet_id":null,"destination_amount":null,
         "category_name":"Food","merchant":"\(merchant)","note":"",
         "occurred_at":"\(occurredAt)","source":"manual","confidence":"1","raw_input":"",
         "base_amount":null,"usd_per_unit":null,"valuation_state":"unvalued","quote":null,
         "created_at":"2026-05-19T12:00:00Z"}
        """
    }

    private func walletSnapshot(id: String, revision: Int64, name: String = "Monobank") -> String {
        """
        {"entity_kind":"wallet","local_id":"\(id)","user_id":"\(scope.ownerID)",
         "ledger_revision":"\(revision)","deleted_at":null,"ledger_version":1,
         "name":"\(name)","type":"bank","currency":"USD","opening_balance":"1000","icon":"",
         "created_at":"2026-05-19T12:00:00Z"}
        """
    }

    private func categorySnapshot(id: String, revision: Int64, name: String = "Coffee") -> String {
        """
        {"entity_kind":"category","local_id":"\(id)","user_id":"\(scope.ownerID)",
         "ledger_revision":"\(revision)","deleted_at":null,"ledger_version":1,
         "name":"\(name)","icon":"cup","color_hex":"8B5E3C","type":"expense",
         "sort_order":50,"is_default":false}
        """
    }

    private func change(cursor: Int64, kind: String, entity: String, snapshot: String,
                        operationID: String = "null") -> String {
        """
        {"cursor":"\(cursor)","operation_id":\(operationID),"entity_kind":"\(kind)",
         "entity_id":"\(entity)","snapshot":\(snapshot)}
        """
    }

    private func page(through: Int64, next: Int64, hasMore: Bool, _ changes: [String]) throws -> LedgerChangePage {
        let json = """
        {"through_cursor":"\(through)","next_cursor":"\(next)","has_more":\(hasMore),
         "changes":[\(changes.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(LedgerChangePage.self, from: Data(json.utf8))
    }

    private func transactions() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func checkpoint() throws -> Int64? {
        try context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.appliedCursor
    }

    private let txID = "30000000-0000-4000-8000-000000000001"
    private let walletID = "40000000-0000-4000-8000-000000000001"
    private let categoryID = "20000000-0000-4000-8000-000000000001"

    // MARK: — REST-01, REST-02: repeated restore

    /// The heart of P1. Restoring twice must leave one row with one identity.
    func testRestoringTheSameFeedTwiceIsIdempotent() async throws {
        feed.setPage(after: 0, try page(through: 3, next: 3, hasMore: false, [
            change(cursor: 1, kind: "wallet", entity: walletID, snapshot: walletSnapshot(id: walletID, revision: 1)),
            change(cursor: 2, kind: "category", entity: categoryID, snapshot: categorySnapshot(id: categoryID, revision: 2)),
            change(cursor: 3, kind: "transaction", entity: txID, snapshot: transactionSnapshot(id: txID, revision: 3))
        ]))

        await coordinator.pull(scope: scope)
        try relaunch()
        let first = try fixture.snapshot()

        // The same page again, exactly as a device that lost its checkpoint
        // would see it.
        feed.setPage(after: 0, try page(through: 3, next: 3, hasMore: false, [
            change(cursor: 1, kind: "wallet", entity: walletID, snapshot: walletSnapshot(id: walletID, revision: 1)),
            change(cursor: 2, kind: "category", entity: categoryID, snapshot: categorySnapshot(id: categoryID, revision: 2)),
            change(cursor: 3, kind: "transaction", entity: txID, snapshot: transactionSnapshot(id: txID, revision: 3))
        ]))
        feed.setPage(after: 3, try page(through: 3, next: 3, hasMore: false, []))
        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try fixture.snapshot(), first, "a repeated restore must change nothing")
        XCTAssertEqual(try transactions().count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Wallet>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SumIt.Category>()), 1)
        XCTAssertEqual(try transactions().first?.id.uuidString.lowercased(), txID)
    }

    // MARK: — REST-03: identity is a UUID value, not a string

    /// The exact production condition: 32 of 70 rows hold an uppercase UUID.
    func testUppercaseAndLowercaseIdentifiersAreTheSameEntity() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID.uppercased(),
                   snapshot: transactionSnapshot(id: txID.uppercased(), revision: 1))
        ]))
        await coordinator.pull(scope: scope)

        feed.setPage(after: 1, try page(through: 2, next: 2, hasMore: false, [
            change(cursor: 2, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 2, amount: "10.25"))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        let rows = try transactions()
        XCTAssertEqual(rows.count, 1, "case must not create a second identity")
        XCTAssertEqual(rows.first?.amountExact, "10.25")
        XCTAssertEqual(rows.first?.serverRevision, 2)
    }

    // MARK: — REST-04: no fallbacks

    func testMalformedSnapshotIsRejectedWithoutInventingIdentityOrOwner() throws {
        // Missing local_id
        let missingID = """
        {"through_cursor":"1","next_cursor":"1","has_more":false,"changes":[
          {"cursor":"1","operation_id":null,"entity_kind":"transaction",
           "entity_id":"\(txID)",
           "snapshot":{"entity_kind":"transaction","user_id":"\(scope.ownerID)",
             "ledger_revision":"1","deleted_at":null,"ledger_version":1,
             "type":"expense","original_amount":"1","original_currency":"USD",
             "wallet_id":null,"wallet_amount":null,"destination_wallet_id":null,
             "destination_amount":null,"category_name":"Food","merchant":"","note":"",
             "occurred_at":"2026-05-19T12:00:00Z","source":"manual","confidence":"1",
             "raw_input":"","base_amount":null,"usd_per_unit":null,
             "valuation_state":"unvalued","quote":null,"created_at":"2026-05-19T12:00:00Z"}}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(LedgerChangePage.self, from: Data(missingID.utf8)))

        // Missing user_id
        let missingOwner = missingID.replacingOccurrences(
            of: "\"user_id\":\"\(scope.ownerID)\",", with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(LedgerChangePage.self, from: Data(missingOwner.utf8)))
    }

    /// A row belonging to someone else is refused, not adopted into this session.
    func testSnapshotForAnotherOwnerIsNotAdopted() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 1, owner: LedgerIDs.ownerB))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try transactions().count, 0)
        XCTAssertNil(try checkpoint(), "a page that could not be applied must not move the cursor")
    }

    // MARK: — REST-05: timestamps

    func testFractionalTimestampKeepsTheOriginalInstant() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 1,
                                                 occurredAt: "2026-05-19T12:00:00.123Z"))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        let stored = try XCTUnwrap(try transactions().first)
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(stored.occurredAt, expected.date(from: "2026-05-19T12:00:00.123Z"))
        XCTAssertNotEqual(stored.occurredAt, LedgerIDs.testClock, "no .now substitution")
    }

    // MARK: — REST-06: a remote edit of a clean row

    func testRemoteEditOfACleanRowAppliesOnce() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 1, amount: "12.5"))
        ]))
        await coordinator.pull(scope: scope)

        feed.setPage(after: 1, try page(through: 2, next: 2, hasMore: false, [
            change(cursor: 2, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 2, amount: "10.25", merchant: "Updated"))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        let rows = try transactions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.amountExact, "10.25")
        XCTAssertEqual(rows.first?.merchant, "Updated")
        XCTAssertEqual(rows.first?.serverRevision, 2)
    }

    /// A stale event must not roll a row back to an older revision.
    func testOlderKnownEventDoesNotRollTheRowBack() async throws {
        feed.setPage(after: 0, try page(through: 5, next: 5, hasMore: false, [
            change(cursor: 5, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 5, amount: "10.25"))
        ]))
        await coordinator.pull(scope: scope)

        // A replayed lower-revision event for the same entity.
        feed.setPage(after: 5, try page(through: 6, next: 6, hasMore: false, [
            change(cursor: 6, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 3, amount: "999"))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try transactions().first?.amountExact, "10.25")
        XCTAssertEqual(try transactions().first?.serverRevision, 5)
    }

    // MARK: — REST-07: our own operation coming back

    func testOwnAcceptedOperationIsNotAConflict() async throws {
        // A local edit that has been acknowledged.
        let draft = TransactionDraft(id: UUID(uuidString: txID)!, type: .expense,
                                     amount: try MoneyCodec.decode("12.5"), currency: "USD",
                                     walletID: nil, walletAmount: nil,
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: "Cafe", note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "",
                                     valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
        let receipt = try store.saveTransaction(draft, scope: scope)
        let mutation = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingMutation>()).first)
        mutation.state = .completed
        try context.save()

        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 1, amount: "12.5"),
                   operationID: "\"\(receipt.operationID.uuidString.lowercased())\"")
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncIssue>()), 0,
                       "a device must not report a conflict against itself")
        XCTAssertEqual(try transactions().count, 1)
        XCTAssertEqual(try transactions().first?.serverRevision, 1)
    }

    /// A different device's edit meeting an unsent local edit is a conflict:
    /// both candidates are preserved and the entity's queue stops.
    func testRemoteEditMeetingAPendingLocalEditIsAConflict() async throws {
        let draft = TransactionDraft(id: UUID(uuidString: txID)!, type: .expense,
                                     amount: try MoneyCodec.decode("12.5"), currency: "USD",
                                     walletID: nil, walletAmount: nil,
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: "Mine", note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "",
                                     valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
        try store.saveTransaction(draft, scope: scope)
        // Pretend the row is known to the server at revision 1 already.
        let row = try XCTUnwrap(try transactions().first)
        row.serverRevision = 1
        try context.save()

        feed.setPage(after: 0, try page(through: 2, next: 2, hasMore: false, [
            change(cursor: 2, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 2, amount: "99", merchant: "Theirs"))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        let issues = try context.fetch(FetchDescriptor<SyncIssue>())
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .conflict)
        XCTAssertNotNil(issues.first?.localSnapshotJSON, "the local candidate is preserved")
        XCTAssertNotNil(issues.first?.remoteSnapshotJSON, "so is the remote one")

        XCTAssertEqual(try transactions().first?.merchant, "Mine",
                       "the local candidate is not overwritten while unresolved")
        XCTAssertEqual(try context.fetch(FetchDescriptor<PendingMutation>()).first?.state, .blocked)
    }

    // MARK: — REST-08: deletion converges

    func testRemoteDeleteConvergesAndDoesNotResurrect() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 1))
        ]))
        await coordinator.pull(scope: scope)

        feed.setPage(after: 1, try page(through: 2, next: 2, hasMore: false, [
            change(cursor: 2, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 2,
                                                 deletedAt: "\"2026-05-20T12:00:00Z\""))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        let row = try XCTUnwrap(try transactions().first)
        XCTAssertNotNil(row.deletedAt, "the tombstone arrived")
        XCTAssertFalse(row.isActive)

        // Replaying the whole feed must not bring it back.
        feed.setPage(after: 2, try page(through: 2, next: 2, hasMore: false, []))
        await coordinator.pull(scope: scope)
        try relaunch()
        XCTAssertNotNil(try transactions().first?.deletedAt, "a delete does not resurrect")
    }

    // MARK: — REST-10: a reference that has not arrived yet

    func testTransactionReferencingAnUnknownWalletIsKeptAndFlagged() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID,
                   snapshot: transactionSnapshot(id: txID, revision: 1, walletID: "\"\(walletID)\""))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try transactions().count, 1, "the row is kept, not silently dropped")
        XCTAssertEqual(try transactions().first?.walletID?.uuidString.lowercased(), walletID)
        let issues = try context.fetch(FetchDescriptor<SyncIssue>())
        XCTAssertEqual(issues.first?.reason, "missing_wallet_reference",
                       "the gap is visible rather than hidden")
    }

    // MARK: — Paging, checkpoints and atomicity

    /// More than a thousand records, so nothing can rely on a 1,000-row cap.
    func testPagesBeyondAThousandRecordsAreAllApplied() async throws {
        var cursor: Int64 = 0
        for pageIndex in 0..<5 {
            var changes: [String] = []
            for row in 0..<250 {
                let n = pageIndex * 250 + row + 1
                let id = String(format: "30000000-0000-4000-8000-%012d", n)
                changes.append(change(cursor: Int64(n), kind: "transaction", entity: id,
                                      snapshot: transactionSnapshot(id: id, revision: Int64(n))))
            }
            let next = Int64((pageIndex + 1) * 250)
            feed.setPage(after: cursor, try page(through: 1250, next: next,
                                                 hasMore: pageIndex < 4, changes))
            cursor = next
        }

        await coordinator.pull(scope: scope)

        // Captured before the relaunch, which replaces the fake feed.
        let calls = feed.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertNil(calls.first?.through, "the first page asks for the watermark")
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0.through == 1250 },
                      "every later page carries the watermark from the first")

        try relaunch()
        XCTAssertEqual(try transactions().count, 1250)
        XCTAssertEqual(try checkpoint(), 1250)
    }

    /// A page that cannot be committed leaves neither its rows nor its cursor.
    func testFailedPageCommitLeavesNothingAndDoesNotMoveTheCursor() async throws {
        rebuild(persist: { throw LedgerWriteError.persistence(code: "disk") })
        feed.setPage(after: 0, try page(through: 2, next: 2, hasMore: false, [
            change(cursor: 1, kind: "wallet", entity: walletID, snapshot: walletSnapshot(id: walletID, revision: 1)),
            change(cursor: 2, kind: "transaction", entity: txID, snapshot: transactionSnapshot(id: txID, revision: 2))
        ]))

        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try transactions().count, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Wallet>()), 0)
        XCTAssertNil(try checkpoint())
    }

    /// A resumed pull starts from the stored checkpoint, not from zero.
    func testPullResumesFromTheStoredCheckpoint() async throws {
        feed.setPage(after: 0, try page(through: 1, next: 1, hasMore: false, [
            change(cursor: 1, kind: "transaction", entity: txID, snapshot: transactionSnapshot(id: txID, revision: 1))
        ]))
        await coordinator.pull(scope: scope)
        try relaunch()
        XCTAssertEqual(try checkpoint(), 1)

        feed.setPage(after: 1, try page(through: 1, next: 1, hasMore: false, []))
        await coordinator.pull(scope: scope)

        XCTAssertEqual(feed.calls.last?.after, 1, "the resumed run asks from the checkpoint")
    }

    /// A server that moves its watermark between pages is refused.
    func testMovingWatermarkIsRefused() async throws {
        feed.setPage(after: 0, try page(through: 10, next: 5, hasMore: true, [
            change(cursor: 5, kind: "transaction", entity: txID, snapshot: transactionSnapshot(id: txID, revision: 5))
        ]))
        feed.setPage(after: 5, try page(through: 99, next: 6, hasMore: false, []))

        await coordinator.pull(scope: scope)
        try relaunch()

        XCTAssertEqual(try checkpoint(), 5, "the first page landed")
        XCTAssertEqual(try transactions().count, 1)
    }

    /// The signed-out dataset never pulls.
    func testLocalOnlyScopeNeverPulls() async {
        await coordinator.pull(scope: AccountScope(ownerID: AccountScope.localOwnerID, epoch: UUID()))
        XCTAssertTrue(feed.calls.isEmpty)
    }
}
