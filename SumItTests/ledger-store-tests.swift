import XCTest
import SwiftData
@testable import SumIt

/// LOC group from acceptance-tests.md §5. Every assertion is made **after
/// closing and reopening the store**, because the claim under test is about
/// what reached the disk, not about what an object graph in memory says.
@MainActor
final class LedgerStoreTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var saves: SaveController!
    private var store: LedgerStore!

    private let scope = AccountScope(ownerID: LedgerIDs.ownerA, epoch: UUID())

    /// Lets a test fail the Nth save, so a rollback path can be exercised with
    /// the real context rather than a fake database.
    private final class SaveController {
        let context: ModelContext
        var failFromCall: Int?
        private(set) var calls = 0
        struct DiskFull: Error {}

        init(context: ModelContext) { self.context = context }

        func persist() throws {
            calls += 1
            if let failFromCall, calls >= failFromCall { throw DiskFull() }
            try context.save()
        }
    }

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        rebuildStore()
    }

    override func tearDownWithError() throws {
        store = nil
        saves = nil
        context = nil
        try fixture?.destroy()
        fixture = nil
    }

    private func rebuildStore() {
        context = ModelContext(fixture.container)
        saves = SaveController(context: context)
        store = LedgerStore(context: context, persist: { [saves] in try saves!.persist() })
    }

    /// Closes the container, reopens the same files and rebuilds the store.
    private func reopen() throws {
        store = nil
        saves = nil
        context = nil
        try fixture.closeAndReopen()
        rebuildStore()
    }

    // MARK: — Fixture builders

    @discardableResult
    private func makeWallet(_ id: UUID = LedgerIDs.walletA, currency: String = "USD",
                            opening: String = "1000") throws -> WalletDraft {
        let draft = WalletDraft(id: id, name: "Monobank", type: .bank, currency: currency,
                                openingBalance: try MoneyCodec.decode(opening),
                                icon: "building.columns.fill")
        try store.saveWallet(draft, scope: scope)
        return draft
    }

    private func expenseDraft(id: UUID = LedgerIDs.expense, amount: String = "12.5",
                              wallet: UUID? = LedgerIDs.walletA) throws -> TransactionDraft {
        TransactionDraft(id: id, type: .expense, amount: try MoneyCodec.decode(amount),
                         currency: "USD", walletID: wallet,
                         walletAmount: wallet == nil ? nil : try MoneyCodec.decode(amount),
                         destinationWalletID: nil, destinationAmount: nil,
                         categoryName: "Food", merchant: "Cafe", note: "",
                         occurredAt: LedgerIDs.eventTime, source: .manual,
                         confidence: 1, rawInput: "12.50 coffee",
                         valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
    }

    private func insertReply() throws -> UUID {
        let message = ChatMessage(id: LedgerIDs.linkedMessage, role: .assistant, content: "Saved")
        context.insert(message)
        try context.save()
        return message.id
    }

    private func counts() throws -> (transactions: Int, mutations: Int) {
        (try context.fetchCount(FetchDescriptor<Transaction>()),
         try context.fetchCount(FetchDescriptor<PendingMutation>()))
    }

    private func storedTransaction(_ id: UUID = LedgerIDs.expense) throws -> Transaction? {
        try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })).first
    }

    private func mutations() throws -> [PendingMutation] {
        try context.fetch(FetchDescriptor<PendingMutation>(
            sortBy: [SortDescriptor(\.createdAt)]))
    }

    // MARK: — LOC-01, LOC-10

    func testSuccessfulSaveCommitsEntityReplyAndQueueTogether() throws {
        try makeWallet()
        let replyID = try insertReply()
        let receipt = try store.saveTransaction(try expenseDraft(), scope: scope,
                                                linkedMessageID: replyID)
        try reopen()

        let stored = try XCTUnwrap(try storedTransaction())
        XCTAssertEqual(stored.amountExact, "12.5")
        XCTAssertEqual(stored.userId, scope.ownerID)
        XCTAssertEqual(stored.localGeneration, 1)
        XCTAssertEqual(stored.migrationState, .adopted)
        XCTAssertEqual(stored.walletID, LedgerIDs.walletA)
        XCTAssertNil(stored.deletedAt)

        let reply = try XCTUnwrap(try context.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(reply.linkedTransactionID, LedgerIDs.expense)

        let queued = try mutations().filter { $0.entityKind == .transaction }
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].operationID, receipt.operationID)
        XCTAssertEqual(queued[0].localGeneration, receipt.generation)
        XCTAssertEqual(queued[0].ownerID, scope.ownerID)
        XCTAssertEqual(queued[0].state, .queued)
        XCTAssertNotNil(queued[0].desiredSnapshotJSON)
    }

    /// The receipt's identity survives a restart, which is what lets a retry
    /// replay the same operation instead of creating a second one.
    func testReceiptIdentitySurvivesReopen() throws {
        try makeWallet()
        let receipt = try store.saveTransaction(try expenseDraft(), scope: scope)
        try reopen()
        let queued = try mutations().first { $0.entityKind == .transaction }
        XCTAssertEqual(queued?.operationID, receipt.operationID)
        XCTAssertEqual(try storedTransaction()?.amountExact, "12.5")
    }

    // MARK: — LOC-02, LOC-09: failure leaves nothing behind

    func testSaveFailureLeavesNoEntityNoReplyLinkAndNoQueueEntry() throws {
        try makeWallet()
        let replyID = try insertReply()
        saves.failFromCall = saves.calls + 1

        XCTAssertThrowsError(try store.saveTransaction(try expenseDraft(), scope: scope,
                                                       linkedMessageID: replyID)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .persistence(code: "save_failed"))
        }
        try reopen()

        XCTAssertEqual(try counts().transactions, 0)
        XCTAssertEqual(try mutations().filter { $0.entityKind == .transaction }.count, 0)
        let reply = try XCTUnwrap(try context.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertNil(reply.linkedTransactionID,
                     "a 'saved' reply must not survive a save that failed")
    }

    // MARK: — LOC-04: a failed edit changes nothing

    func testEditFailureLeavesTheOriginalIntact() throws {
        try makeWallet()
        try store.saveTransaction(try expenseDraft(), scope: scope)

        var edited = try expenseDraft(amount: "99.99")
        edited.merchant = "Changed"
        saves.failFromCall = saves.calls + 1
        XCTAssertThrowsError(try store.editTransaction(edited, scope: scope))

        try reopen()
        let stored = try XCTUnwrap(try storedTransaction())
        XCTAssertEqual(stored.amountExact, "12.5")
        XCTAssertEqual(stored.merchant, "Cafe")
        XCTAssertEqual(stored.localGeneration, 1)
        XCTAssertEqual(try mutations().filter { $0.entityKind == .transaction }.count, 1)
    }

    // MARK: — LOC-05, LOC-06: deletion

    func testDeleteFailureLeavesTheRecordActive() throws {
        try makeWallet()
        try store.saveTransaction(try expenseDraft(), scope: scope)
        saves.failFromCall = saves.calls + 1

        XCTAssertThrowsError(try store.deleteTransaction(id: LedgerIDs.expense, scope: scope))
        try reopen()

        let stored = try XCTUnwrap(try storedTransaction())
        XCTAssertNil(stored.deletedAt, "a failed delete must not hide the record")
        XCTAssertEqual(try mutations().filter { $0.entityKind == .transaction }.count, 1)
    }

    /// A delete is a tombstone plus a durable intent — never `context.delete`.
    func testDeleteSucceedsAsATombstoneThatSurvivesRestart() throws {
        try makeWallet()
        try store.saveTransaction(try expenseDraft(), scope: scope)
        let receipt = try store.deleteTransaction(id: LedgerIDs.expense, scope: scope)
        try reopen()

        let stored = try XCTUnwrap(try storedTransaction(), "the row itself must still exist")
        XCTAssertNotNil(stored.deletedAt)
        XCTAssertFalse(stored.isActive)
        XCTAssertEqual(stored.localGeneration, 2)

        let queued = try mutations().filter { $0.entityKind == .transaction }
        XCTAssertEqual(queued.count, 2)
        XCTAssertEqual(queued.last?.operationID, receipt.operationID)
        XCTAssertNil(queued.last?.desiredSnapshotJSON, "a delete carries no record body")
    }

    // MARK: — LOC-07: unrelated work is not collateral damage

    func testUnrelatedUnsavedEditIsNotLostByAFinancialRollback() throws {
        try makeWallet()

        // Something unrelated is sitting uncommitted in the same context.
        let settings = AppSettings()
        settings.userName = "Unrelated draft"
        context.insert(settings)

        // The financial command commits that pending work first, then fails.
        saves.failFromCall = saves.calls + 2
        XCTAssertThrowsError(try store.saveTransaction(try expenseDraft(), scope: scope))

        try reopen()
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).first?.userName,
                       "Unrelated draft", "the unrelated edit must survive")
        XCTAssertEqual(try counts().transactions, 0, "the financial write must not have landed")
    }

    // MARK: — LOC-08: wallets and categories

    func testWalletSaveFailureLeavesNothing() throws {
        saves.failFromCall = saves.calls + 1
        let draft = WalletDraft(id: LedgerIDs.walletA, name: "Monobank", type: .bank,
                                currency: "USD", openingBalance: 1000, icon: "")
        XCTAssertThrowsError(try store.saveWallet(draft, scope: scope))
        try reopen()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Wallet>()), 0)
        XCTAssertEqual(try mutations().count, 0)
    }

    func testWalletIsArchivedNotErased() throws {
        try makeWallet()
        try store.saveTransaction(try expenseDraft(), scope: scope)
        try store.archiveWallet(id: LedgerIDs.walletA, scope: scope)
        try reopen()

        let wallet = try XCTUnwrap(try context.fetch(FetchDescriptor<Wallet>()).first)
        XCTAssertTrue(wallet.isArchived)
        XCTAssertNotNil(try storedTransaction(), "history referencing it must remain")
    }

    func testCategoryIsArchivedNotErased() throws {
        let draft = CategoryDraft(id: LedgerIDs.customCategory, name: "Coffee",
                                  icon: "cup.and.saucer.fill", colorHex: "8B5E3C",
                                  type: "expense", sortOrder: 50)
        try store.saveCategory(draft, scope: scope)
        try store.archiveCategory(id: LedgerIDs.customCategory, scope: scope)
        try reopen()

        let category = try XCTUnwrap(try context.fetch(FetchDescriptor<SumIt.Category>()).first)
        XCTAssertTrue(category.isArchived)
        XCTAssertEqual(category.ownerID, scope.ownerID)
    }

    func testWalletCurrencyIsLockedOnceReferenced() throws {
        try makeWallet()
        try store.saveTransaction(try expenseDraft(), scope: scope)

        var renamed = try makeWalletDraft(currency: "EUR")
        renamed.name = "Monobank EUR"
        XCTAssertThrowsError(try store.saveWallet(renamed, scope: scope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .validation(code: "wallet_currency_is_locked"))
        }
    }

    private func makeWalletDraft(currency: String) throws -> WalletDraft {
        WalletDraft(id: LedgerIDs.walletA, name: "Monobank", type: .bank, currency: currency,
                    openingBalance: try MoneyCodec.decode("1000"), icon: "")
    }

    // MARK: — Identity and ordering

    /// UIEDIT-06. A repeated confirm must not mint a second transaction.
    func testSecondCreateForTheSameIdentityIsRejected() throws {
        try makeWallet()
        try store.saveTransaction(try expenseDraft(), scope: scope)
        XCTAssertThrowsError(try store.saveTransaction(try expenseDraft(), scope: scope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .duplicateEntity(LedgerIDs.expense))
        }
        try reopen()
        XCTAssertEqual(try counts().transactions, 1)
    }

    /// Repeated edits append linked intents; they are not coalesced and they do
    /// not reuse an operation ID.
    func testRepeatedEditsAppendPredecessorLinkedOperations() throws {
        try makeWallet()
        let first = try store.saveTransaction(try expenseDraft(), scope: scope)
        let second = try store.editTransaction(try expenseDraft(amount: "10.25"), scope: scope)
        let third = try store.editTransaction(try expenseDraft(amount: "11"), scope: scope)
        try reopen()

        let queued = try mutations().filter { $0.entityKind == .transaction }
        XCTAssertEqual(queued.count, 3)
        XCTAssertEqual(Set([first.operationID, second.operationID, third.operationID]).count, 3)
        XCTAssertNil(queued[0].predecessorOperationID)
        XCTAssertEqual(queued[1].predecessorOperationID, first.operationID)
        XCTAssertEqual(queued[2].predecessorOperationID, second.operationID)
        XCTAssertEqual(queued.map(\.localGeneration), [1, 2, 3])
    }

    func testEditingAMissingRecordIsRejected() throws {
        try makeWallet()
        XCTAssertThrowsError(try store.editTransaction(try expenseDraft(), scope: scope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .missingEntity(LedgerIDs.expense))
        }
    }

    // MARK: — Validation happens before anything is touched

    func testInvalidAmountIsRejectedAndNothingIsWritten() throws {
        try makeWallet()
        let tooPrecise = try expenseDraft(amount: "12.345")
        XCTAssertThrowsError(try store.saveTransaction(tooPrecise, scope: scope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .validation(code: "excess_precision"))
        }
        try reopen()
        XCTAssertEqual(try counts().transactions, 0)
        XCTAssertEqual(try mutations().filter { $0.entityKind == .transaction }.count, 0)
    }

    func testWalletFromAnotherOwnerIsOutOfScope() throws {
        // A wallet that exists, but belongs to somebody else.
        let foreign = Wallet(id: LedgerIDs.walletB, userId: LedgerIDs.ownerB, name: "Theirs",
                             type: .bank, currency: "USD", balance: 0)
        context.insert(foreign)
        try context.save()

        let draft = try expenseDraft(wallet: LedgerIDs.walletB)
        XCTAssertThrowsError(try store.saveTransaction(draft, scope: scope)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .wrongScope)
        }
        try reopen()
        XCTAssertEqual(try counts().transactions, 0)
    }

    /// The booked USD value is the exact product, half-even to scale 18 — the
    /// same rule the server re-derives and rejects a mismatch on.
    func testBookedBaseAmountMatchesTheSharedRounding() throws {
        try makeWallet(currency: "USD")
        let quote = RateQuote(id: nil, currency: "USD", usdPerUnit: "1", requestedDate: nil,
                              effectiveAt: LedgerIDs.eventTime, fetchedAt: LedgerIDs.eventTime,
                              source: "identity", sourceDetail: .object([:]),
                              valuationKind: .identity, isStale: false)
        var draft = try expenseDraft()
        draft.valuation = .quoted(quote)
        try store.saveTransaction(draft, scope: scope)
        try reopen()

        let stored = try XCTUnwrap(try storedTransaction())
        XCTAssertEqual(stored.baseAmountExact, "12.5")
        XCTAssertEqual(stored.rateExact, "1")
        XCTAssertEqual(stored.valuationState, .valued)
        XCTAssertNotNil(stored.quoteJSON)
    }

    func testUnvaluedTransactionStoresNoValuation() throws {
        try makeWallet()
        var draft = try expenseDraft()
        draft.valuation = .unvalued
        try store.saveTransaction(draft, scope: scope)
        try reopen()

        let stored = try XCTUnwrap(try storedTransaction())
        XCTAssertNil(stored.baseAmountExact)
        XCTAssertNil(stored.rateExact)
        XCTAssertNil(stored.quoteJSON)
        XCTAssertEqual(stored.valuationState, .unvalued)
        XCTAssertEqual(stored.amountExact, "12.5", "the original quantity is still recorded")
    }
}
