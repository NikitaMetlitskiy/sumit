import XCTest
import SwiftData
@testable import SumIt

/// MIG group. The question these answer is narrow and important: does a store
/// written by the shipped app open under the new schema without losing an
/// identity, an amount or a row?
@MainActor
final class LedgerSchemaMigrationTests: XCTestCase {

    private var fixture: PersistentStoreFixture?

    override func tearDownWithError() throws {
        try fixture?.destroy()
        fixture = nil
    }

    /// The prerequisite the plan puts before everything else: the frozen V1
    /// definition must be able to open a real V1 store.
    func testFrozenV1OpensAndReadsItsOwnStore() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture
        let snapshot = try fixture.snapshotV1()

        XCTAssertEqual(snapshot.transactions.count, 2)
        XCTAssertEqual(snapshot.wallets.count, 2)
        XCTAssertEqual(snapshot.categories.count, 1)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.settings.count, 1)

        try fixture.closeAndReopen()
        XCTAssertEqual(try fixture.snapshotV1(), snapshot, "V1 data must survive a reopen")
    }

    /// The plan's own specimen: identity, original quantities and wallet
    /// balances all cross the migration unchanged.
    func testUpgradePreservesIdentityAndOriginalQuantity() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture
        let before = try fixture.snapshotV1()

        try fixture.upgradeToV2()
        let after = try fixture.snapshot()

        XCTAssertEqual(after.transactionIDs, before.transactionIDs)
        XCTAssertEqual(after.originalAmounts, before.originalAmounts)
        XCTAssertEqual(after.walletBalances, before.walletBalances)
    }

    /// Nothing at all may change, not just the three projections above.
    func testUpgradePreservesEveryField() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture
        let before = try fixture.snapshotV1()

        try fixture.upgradeToV2()
        XCTAssertEqual(try fixture.snapshot(), before,
                       "the V1→V2 step must be additive: no value may differ")
    }

    func testMigratedStoreSurvivesReopen() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture
        let before = try fixture.snapshotV1()

        try fixture.upgradeToV2()
        try fixture.closeAndReopen()
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    /// Opening the migrated store again must be a no-op, not a second migration
    /// that re-derives anything.
    func testMigrationRerunIsIdempotentOnDisk() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture

        try fixture.upgradeToV2()
        let first = try fixture.snapshot()
        try fixture.upgradeToV2()
        let second = try fixture.snapshot()
        try fixture.upgradeToV2()
        let third = try fixture.snapshot()

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    /// Migration converts shapes. It must not invent exact amounts, opening
    /// balances or valuations — those are semantic decisions that belong to the
    /// adoption task, with the owner's involvement.
    func testMigrationDoesNotDeriveLedgerValues() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture
        try fixture.upgradeToV2()

        let context = ModelContext(fixture.container)
        for transaction in try context.fetch(FetchDescriptor<Transaction>()) {
            XCTAssertNil(transaction.amountExact, "schema migration must not fabricate an exact amount")
            XCTAssertNil(transaction.baseAmountExact)
            XCTAssertNil(transaction.rateExact)
            XCTAssertNil(transaction.walletID, "wallet identity is resolved by adoption, not by migration")
            XCTAssertNil(transaction.destinationWalletID)
            XCTAssertNil(transaction.quoteJSON)
            XCTAssertNil(transaction.deletedAt)
            XCTAssertEqual(transaction.serverRevision, 0)
            XCTAssertEqual(transaction.localGeneration, 0)
            XCTAssertEqual(transaction.valuationState, .legacyUnverified,
                           "an inherited number is not a verified valuation")
            XCTAssertEqual(transaction.migrationState, .legacy,
                           "rows stay legacy until adoption reconciles them")
        }

        for wallet in try context.fetch(FetchDescriptor<Wallet>()) {
            XCTAssertNil(wallet.openingBalanceExact,
                         "an opening balance cannot be guessed from a current balance")
            XCTAssertNil(wallet.deletedAt)
            XCTAssertEqual(wallet.migrationState, .legacy)
        }

        for category in try context.fetch(FetchDescriptor<SumIt.Category>()) {
            XCTAssertNil(category.ownerID, "migration must not claim an owner for a category")
            XCTAssertNil(category.deletedAt)
        }

        for message in try context.fetch(FetchDescriptor<ChatMessage>()) {
            XCTAssertNil(message.ownerID)
        }
    }

    /// The four synchronization models must exist and be empty after migration.
    func testNewSyncModelsExistAndStartEmpty() throws {
        let fixture = try PersistentStoreFixture.makeVersionOneBaseline()
        self.fixture = fixture
        try fixture.upgradeToV2()

        let context = ModelContext(fixture.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncCheckpoint>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncIssue>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CachedRateQuote>()), 0)
    }

    /// The new models must actually persist, not just compile.
    func testSyncModelsRoundTripThroughDisk() throws {
        let fixture = try PersistentStoreFixture()
        self.fixture = fixture
        let context = ModelContext(fixture.container)

        let operationID = UUID()
        let mutation = PendingMutation(operationID: operationID, ownerID: LedgerIDs.ownerA,
                                       entityKind: .transaction, entityID: LedgerIDs.expense,
                                       localGeneration: 3, createdAt: LedgerIDs.testClock)
        mutation.state = .inFlight
        mutation.frozenRequestJSON = Data(#"{"protocol_version":1}"#.utf8)

        context.insert(mutation)
        context.insert(SyncCheckpoint(ownerID: LedgerIDs.ownerA, appliedCursor: 42, adoptionVersion: 1))
        context.insert(SyncIssue(ownerID: LedgerIDs.ownerA, entityKind: .transaction,
                                 entityID: LedgerIDs.expense, kind: .conflict,
                                 reason: "revision_mismatch"))
        context.insert(CachedRateQuote(quoteID: UUID(), currency: "EUR", usdPerUnitExact: "1.08",
                                       requestedDate: "2026-05-19", effectiveAt: LedgerIDs.eventTime,
                                       fetchedAt: LedgerIDs.eventTime, source: "frankfurter",
                                       valuationKind: .historicalReference))
        try context.save()
        try fixture.closeAndReopen()

        let reopened = ModelContext(fixture.container)
        let storedMutation = try XCTUnwrap(try reopened.fetch(FetchDescriptor<PendingMutation>()).first)
        XCTAssertEqual(storedMutation.operationID, operationID)
        XCTAssertEqual(storedMutation.state, .inFlight)
        XCTAssertEqual(storedMutation.localGeneration, 3)
        XCTAssertNotNil(storedMutation.frozenRequestJSON)

        XCTAssertEqual(try reopened.fetch(FetchDescriptor<SyncCheckpoint>()).first?.appliedCursor, 42)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<SyncIssue>()).first?.kind, .conflict)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<CachedRateQuote>()).first?.usdPerUnitExact, "1.08")
    }

    /// Restoring a remote record must reuse its identity. A constructor that
    /// always minted a fresh UUID is what produced duplicates on every restore.
    func testConstructorsAcceptAnInjectedIdentity() throws {
        let identifier = LedgerIDs.expense
        let transaction = Transaction(id: identifier, originalAmount: 1, originalCurrency: "USD",
                                      amountInBase: 1, rateAtTime: 1,
                                      categoryName: "Food", merchant: "Cafe")
        XCTAssertEqual(transaction.id, identifier)

        let wallet = Wallet(id: LedgerIDs.walletA, name: "Monobank")
        XCTAssertEqual(wallet.id, LedgerIDs.walletA)

        let category = SumIt.Category(id: LedgerIDs.customCategory, name: "Coffee",
                                      icon: "cup.and.saucer.fill", colorHex: "8B5E3C")
        XCTAssertEqual(category.id, LedgerIDs.customCategory)

        let message = ChatMessage(id: LedgerIDs.linkedMessage, role: .assistant, content: "Saved")
        XCTAssertEqual(message.id, LedgerIDs.linkedMessage)

        // A genuinely new record still gets its own identity.
        XCTAssertNotEqual(Wallet(name: "Cash").id, Wallet(name: "Cash").id)
    }
}
