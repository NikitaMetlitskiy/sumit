import XCTest
import SwiftData
@testable import SumIt

/// CONFLICT group. A conflict is resolved by the owner choosing a whole
/// version. No money field is ever merged, and nothing resolves itself.
@MainActor
final class LedgerConflictTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var store: LedgerStore!
    private var feed: StubFeed!
    private var coordinator: LedgerSyncCoordinator!

    private let scope = AccountScope(ownerID: LedgerIDs.ownerA, epoch: UUID())
    private let txID = "30000000-0000-4000-8000-000000000001"

    final class StubFeed: LedgerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: LedgerChangePage] = [:]

        func setPage(after: Int64, _ page: LedgerChangePage) {
            lock.lock(); pages["\(after)"] = page; lock.unlock()
        }

        func applyLedgerMutation(_ request: LedgerMutationRequest,
                                 scope: AccountScope) async throws -> LedgerMutationResult {
            throw LedgerTransportError.unreachable
        }

        func readLedgerChanges(after: Int64, through: Int64?, limit: Int,
                               scope: AccountScope) async throws -> LedgerChangePage {
            lock.lock(); let page = pages["\(after)"]; lock.unlock()
            guard let page else { throw LedgerTransportError.unknownOutcome }
            return page
        }
    }

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        rebuild()
    }

    override func tearDownWithError() throws {
        coordinator = nil; store = nil; feed = nil; context = nil
        try fixture?.destroy()
        fixture = nil
    }

    private func rebuild() {
        context = ModelContext(fixture.container)
        store = LedgerStore(context: context)
        feed = StubFeed()
        coordinator = LedgerSyncCoordinator(context: context, transport: feed,
                                            now: { LedgerIDs.testClock },
                                            persist: { [context] in try context!.save() })
    }

    private func relaunch() throws {
        coordinator = nil; store = nil; context = nil
        try fixture.closeAndReopen()
        rebuild()
    }

    // MARK: — Building the conflict

    private func remoteSnapshot(revision: Int64, amount: String, merchant: String,
                                deletedAt: String = "null") -> String {
        """
        {"entity_kind":"transaction","local_id":"\(txID)","user_id":"\(scope.ownerID)",
         "ledger_revision":"\(revision)","deleted_at":\(deletedAt),"ledger_version":1,
         "type":"expense","original_amount":"\(amount)","original_currency":"USD",
         "wallet_id":null,"wallet_amount":null,"destination_wallet_id":null,"destination_amount":null,
         "category_name":"Food","merchant":"\(merchant)","note":"",
         "occurred_at":"2026-05-19T12:00:00Z","source":"manual","confidence":"1","raw_input":"",
         "base_amount":null,"usd_per_unit":null,"valuation_state":"unvalued","quote":null,
         "created_at":"2026-05-19T12:00:00Z"}
        """
    }

    private func page(cursor: Int64, snapshot: String) throws -> LedgerChangePage {
        let json = """
        {"through_cursor":"\(cursor)","next_cursor":"\(cursor)","has_more":false,
         "changes":[{"cursor":"\(cursor)","operation_id":null,"entity_kind":"transaction",
                     "entity_id":"\(txID)","snapshot":\(snapshot)}]}
        """
        return try JSONDecoder().decode(LedgerChangePage.self, from: Data(json.utf8))
    }

    /// A local unsent edit meets a different remote edit.
    @discardableResult
    private func createConflict(localMerchant: String = "Mine",
                                remoteAmount: String = "99",
                                remoteMerchant: String = "Theirs",
                                remoteDeleted: Bool = false) async throws -> SyncIssue {
        let draft = TransactionDraft(id: UUID(uuidString: txID)!, type: .expense,
                                     amount: try MoneyCodec.decode("12.5"), currency: "USD",
                                     walletID: nil, walletAmount: nil,
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: localMerchant, note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "",
                                     valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
        try store.saveTransaction(draft, scope: scope)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        row.serverRevision = 1
        try context.save()

        feed.setPage(after: 0, try page(cursor: 7, snapshot: remoteSnapshot(
            revision: 7, amount: remoteAmount, merchant: remoteMerchant,
            deletedAt: remoteDeleted ? "\"2026-05-20T12:00:00Z\"" : "null")))
        await coordinator.pull(scope: scope)

        return try XCTUnwrap(try context.fetch(FetchDescriptor<SyncIssue>()).first)
    }

    private func transaction(_ id: String) throws -> Transaction? {
        let uuid = UUID(uuidString: id)!
        return try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == uuid })).first
    }

    private func pendingCount() throws -> Int {
        let completed = PendingMutationState.completed.rawValue
        return try context.fetchCount(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.stateRaw != completed }))
    }

    // MARK: — Nothing resolves itself

    func testAConflictWaitsForTheOwner() async throws {
        let issue = try await createConflict()

        XCTAssertNil(issue.resolvedAt, "a conflict is never resolved automatically")
        XCTAssertNotNil(issue.localSnapshotJSON)
        XCTAssertNotNil(issue.remoteSnapshotJSON)
        XCTAssertEqual(try transaction(txID)?.merchant, "Mine", "no silent last-write-wins")
        XCTAssertEqual(try pendingCount(), 1, "the entity's queue is held, not dropped")
    }

    // MARK: — Use the server's version

    func testUseServerAppliesRemoteAndKeepsTheDiscardedCandidate() async throws {
        let issue = try await createConflict()
        let issueID = issue.id

        try coordinator.resolve(issueID: issueID, with: .useServer, scope: scope)
        try relaunch()

        let row = try XCTUnwrap(try transaction(txID))
        XCTAssertEqual(row.merchant, "Theirs")
        XCTAssertEqual(row.amountExact, "99")
        XCTAssertEqual(row.serverRevision, 7)
        XCTAssertEqual(try pendingCount(), 0, "the superseded queue entries are cancelled")

        let resolved = try XCTUnwrap(try context.fetch(FetchDescriptor<SyncIssue>()).first)
        XCTAssertNotNil(resolved.resolvedAt)
        XCTAssertNotNil(resolved.localSnapshotJSON,
                        "the discarded version stays recoverable until dismissed")
    }

    func testDismissRemovesAResolvedIssueAndOnlyAResolvedOne() async throws {
        let issue = try await createConflict()
        let issueID = issue.id

        XCTAssertThrowsError(try coordinator.dismiss(issueID: issueID, scope: scope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .validation(code: "issue_not_resolved"))
        }

        try coordinator.resolve(issueID: issueID, with: .useServer, scope: scope)
        try coordinator.dismiss(issueID: issueID, scope: scope)
        try relaunch()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncIssue>()), 0)
    }

    // MARK: — Keep the local version

    /// Keeping the local version queues a **new** operation against the revision
    /// the server actually holds — not a retry of the stale one.
    func testKeepLocalQueuesANewOperationAgainstTheServersRevision() async throws {
        let issue = try await createConflict()
        let blockedOperation = try XCTUnwrap(
            try context.fetch(FetchDescriptor<PendingMutation>()).first).operationID

        try coordinator.resolve(issueID: issue.id, with: .keepLocal, scope: scope)
        try relaunch()

        let row = try XCTUnwrap(try transaction(txID))
        XCTAssertEqual(row.merchant, "Mine", "the local version is what will be sent")
        XCTAssertEqual(row.serverRevision, 7, "the new write is based on what the server holds")

        let queue = try context.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(queue.count, 1)
        XCTAssertNotEqual(queue.first?.operationID, blockedOperation,
                          "a resolved conflict retries as a new operation, never the stale one")
        XCTAssertEqual(queue.first?.state, .queued)
        XCTAssertNil(queue.first?.frozenRequestJSON, "it has not been dispatched yet")
    }

    /// A further remote edit during resolution conflicts again rather than
    /// quietly overwriting.
    func testAnotherRemoteEditAfterKeepLocalConflictsAgain() async throws {
        let issue = try await createConflict()
        try coordinator.resolve(issueID: issue.id, with: .keepLocal, scope: scope)

        feed.setPage(after: 7, try page(cursor: 9, snapshot: remoteSnapshot(
            revision: 9, amount: "55", merchant: "Third device")))
        await coordinator.pull(scope: scope)

        let open = try context.fetch(FetchDescriptor<SyncIssue>()).filter { $0.resolvedAt == nil }
        XCTAssertEqual(open.count, 1, "a new remote edit produces a new conflict")
        XCTAssertEqual(try transaction(txID)?.merchant, "Mine",
                       "and still does not overwrite the local candidate")
    }

    // MARK: — Save as a new record

    /// The server deleted it; the owner wants their version anyway. It becomes a
    /// new record with a new identity, and the old one keeps the tombstone.
    func testSaveAsNewCreatesAFreshIdentityAndLeavesTheTombstone() async throws {
        let issue = try await createConflict(remoteDeleted: true)

        try coordinator.resolve(issueID: issue.id, with: .saveAsNew, scope: scope)
        try relaunch()

        let rows = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, 2)

        let original = try XCTUnwrap(try transaction(txID))
        XCTAssertNotNil(original.deletedAt, "the deleted identity stays deleted")

        let fresh = try XCTUnwrap(rows.first { $0.id != original.id })
        XCTAssertNil(fresh.deletedAt)
        XCTAssertEqual(fresh.merchant, "Mine")
        XCTAssertEqual(fresh.amountExact, "12.5")
        XCTAssertEqual(fresh.userId, scope.ownerID)

        let queue = try context.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.entityID, fresh.id, "the new identity is what gets sent")
    }

    // MARK: — Guards

    func testResolvingAnAlreadyResolvedIssueIsANoOp() async throws {
        let issue = try await createConflict()
        try coordinator.resolve(issueID: issue.id, with: .useServer, scope: scope)
        let resolvedAt = issue.resolvedAt

        try coordinator.resolve(issueID: issue.id, with: .keepLocal, scope: scope)
        XCTAssertEqual(issue.resolvedAt, resolvedAt)
        XCTAssertEqual(try pendingCount(), 0, "the second call changed nothing")
    }

    func testResolvingAnIssueFromAnotherAccountIsRefused() async throws {
        let issue = try await createConflict()
        let otherScope = AccountScope(ownerID: LedgerIDs.ownerB, epoch: UUID())

        XCTAssertThrowsError(try coordinator.resolve(issueID: issue.id, with: .useServer,
                                                     scope: otherScope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .missingEntity(issue.id))
        }
        XCTAssertNil(issue.resolvedAt)
    }

    // MARK: — What the conflict screen shows

    /// The screen must present the exact stored amount strings for both sides,
    /// and know which side carries the server's revision and tombstone.
    func testBothCandidatesAreReadableForDisplay() async throws {
        let issue = try await createConflict(remoteAmount: "99.004", remoteMerchant: "Theirs")

        let local = try XCTUnwrap(SyncIssuePresentation.localCandidate(issue))
        XCTAssertEqual(local.amount, "12.5", "the exact string, not a rounded display value")
        XCTAssertEqual(local.currency, "USD")
        XCTAssertEqual(local.merchant, "Mine")
        XCTAssertNil(local.revision, "the local candidate has not been accepted by any revision")
        XCTAssertFalse(local.isDeleted)

        let remote = try XCTUnwrap(SyncIssuePresentation.remoteCandidate(issue))
        XCTAssertEqual(remote.amount, "99.004")
        XCTAssertEqual(remote.merchant, "Theirs")
        XCTAssertEqual(remote.revision, 7)
        XCTAssertFalse(remote.isDeleted)
    }

    func testADeletedRemoteVersionIsPresentedAsDeleted() async throws {
        let issue = try await createConflict(remoteDeleted: true)
        XCTAssertTrue(try XCTUnwrap(SyncIssuePresentation.remoteCandidate(issue)).isDeleted)
    }

    /// An issue that is not a two-version conflict must not be worded as one,
    /// and an unknown reason must not be shown to the user as a raw token.
    func testWordingIsChosenByReasonAndNeverShowsARawToken() {
        let conflict = SyncIssue(ownerID: scope.ownerID, entityKind: .transaction, entityID: UUID(),
                                 kind: .conflict, reason: "remote_edit_meets_local_candidate")
        XCTAssertEqual(SyncIssuePresentation.explanation(for: conflict), L("conflict_explain"))

        let missing = SyncIssue(ownerID: scope.ownerID, entityKind: .transaction, entityID: UUID(),
                                kind: .invalidRemoteRow, reason: "missing_wallet_reference")
        XCTAssertEqual(SyncIssuePresentation.explanation(for: missing), L("sync_issue_missing_wallet"))

        let legacy = SyncIssue(ownerID: scope.ownerID, entityKind: .transaction, entityID: UUID(),
                               kind: .legacyAmbiguity, reason: "local_data_awaiting_import")
        XCTAssertEqual(SyncIssuePresentation.explanation(for: legacy), L("sync_issue_awaiting_import"))

        let unknown = SyncIssue(ownerID: scope.ownerID, entityKind: .transaction, entityID: UUID(),
                                kind: .invalidRemoteRow, reason: "something_new_from_the_server")
        XCTAssertEqual(SyncIssuePresentation.explanation(for: unknown), L("sync_issue_generic"))
        XCTAssertFalse(SyncIssuePresentation.explanation(for: unknown).contains("something_new"))
    }

    func testConflictStringsAreLocalized() {
        for key in ["sync_issues_title", "sync_issues_open", "sync_issues_resolved", "sync_issues_empty",
                    "conflict_title", "conflict_explain", "conflict_your_version", "conflict_server_version",
                    "conflict_use_server", "conflict_keep_local", "conflict_save_as_new", "conflict_dismiss",
                    "conflict_no_merge_note", "conflict_resolved_note", "conflict_server_deleted",
                    "conflict_field_amount", "conflict_field_wallet", "conflict_field_merchant",
                    "conflict_field_date", "conflict_field_name", "conflict_field_revision",
                    "conflict_field_recorded", "conflict_unsent", "conflict_no_wallet",
                    "conflict_unknown_wallet", "conflict_action_failed", "sync_issue_legacy_title",
                    "sync_issue_invalid_title", "sync_issue_missing_wallet", "sync_issue_awaiting_import",
                    "sync_issue_generic", "sync_issues_row"] {
            let translations = LocalizationManager.translationsData[key]
            XCTAssertNotNil(translations, "missing \(key)")
            for language in ["en", "uk", "ru", "es", "de", "pl"] {
                XCTAssertNotNil(translations?[language], "\(key) has no \(language)")
            }
        }
    }
}
