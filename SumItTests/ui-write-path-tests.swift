import XCTest
import SwiftData
@testable import SumIt

/// UIEDIT group plus the routing that replaced the views' own saves.
///
/// The editor's rules live in `TransactionEditor`, so they are exercised
/// directly rather than by driving SwiftUI: what matters is that opening an
/// entry and saving it cannot change the number, and that a rejected save
/// changes nothing at all.
@MainActor
final class UIWritePathTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var store: AppStore!
    private var ledger: LedgerStore!

    /// The tests write through `AppStore`, which uses the signed-in scope. A
    /// test bundle is signed out, so that is the device dataset — a legitimate
    /// scope, and the one the real code path will use here.
    private var ownerID: String { AuthService.shared.userId }
    private var scope: AccountScope { AuthService.shared.currentScope }

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        context = ModelContext(fixture.container)
        ledger = LedgerStore(context: context)
        store = AppStore()
        store.setup(context: context)
    }

    override func tearDownWithError() throws {
        store = nil; ledger = nil; context = nil
        try fixture?.destroy()
        fixture = nil
    }

    // MARK: — Helpers

    @discardableResult
    private func makeWallet(_ id: UUID, name: String, currency: String,
                            opening: String = "0") throws -> Wallet {
        try ledger.saveWallet(WalletDraft(id: id, name: name, type: .cash, currency: currency,
                                          openingBalance: try MoneyCodec.decode(opening), icon: ""),
                              scope: scope)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Wallet>(
            predicate: #Predicate { $0.id == id })).first)
    }

    @discardableResult
    private func makeTransaction(id: UUID = LedgerIDs.expense, amount: String,
                                 currency: String = "EUR", merchant: String = "Cafe",
                                 walletID: UUID? = nil) throws -> Transaction {
        let draft = TransactionDraft(id: id, type: .expense,
                                     amount: try MoneyCodec.decode(amount), currency: currency,
                                     walletID: walletID,
                                     walletAmount: walletID == nil ? nil : try MoneyCodec.decode(amount),
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: merchant, note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "",
                                     valuation: .legacyUnverified(baseAmount: nil, rate: nil))
        try ledger.saveTransaction(draft, scope: scope)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func wallets() throws -> [Wallet] {
        try context.fetch(FetchDescriptor<Wallet>())
    }

    // MARK: — UIEDIT-01/02: opening an entry does not round it

    func testChangingOnlyTheMerchantLeavesTheAmountExact() throws {
        let tx = try makeTransaction(amount: "12.50")
        var fields = TransactionEditor.fields(from: tx)
        XCTAssertEqual(fields.amountText, "12.5", "opened from the exact string, not from a Double")

        fields.merchant = "Another cafe"
        guard case .success(let draft) = TransactionEditor.draft(
            from: fields, id: tx.id, wallets: try wallets(), ownerID: ownerID, previous: tx) else {
            return XCTFail("the edit should be valid")
        }
        XCTAssertEqual(try MoneyCodec.encode(draft.amount), "12.5")
        XCTAssertTrue(store.editTransaction(draft))

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(reloaded.amountExact, "12.5", "12.50 must not become 13, or 12")
        XCTAssertEqual(reloaded.merchant, "Another cafe")
    }

    func testACryptoAmountSurvivesADateOnlyEdit() throws {
        let tx = try makeTransaction(amount: "0.00000001", currency: "BTC")
        var fields = TransactionEditor.fields(from: tx)
        XCTAssertEqual(fields.amountText, "0.00000001")

        fields.occurredAt = LedgerIDs.eventTime.addingTimeInterval(86_400)
        // A date change needs an explicit valuation decision (VAL-04); the
        // point of this test is only that the amount survives it.
        fields.valuation = .unvalued
        guard case .success(let draft) = TransactionEditor.draft(
            from: fields, id: tx.id, wallets: try wallets(), ownerID: ownerID, previous: tx) else {
            return XCTFail("the edit should be valid")
        }
        XCTAssertTrue(store.editTransaction(draft))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).first?.amountExact,
                       "0.00000001")
    }

    /// Reopening and saving with nothing touched must be a no-op on the money,
    /// including the valuation. Re-rating at today's rate would silently move
    /// the reported total of an entry the user did not change.
    func testSavingAnUnchangedEntryChangesNothingAboutTheMoney() throws {
        let tx = try makeTransaction(amount: "12.50")
        let storedValuation = try XCTUnwrap(tx.draftForCalculation).valuation
        let fields = TransactionEditor.fields(from: tx)

        guard case .success(let draft) = TransactionEditor.draft(
            from: fields, id: tx.id, wallets: try wallets(), ownerID: ownerID, previous: tx) else {
            return XCTFail("the edit should be valid")
        }
        XCTAssertEqual(draft.valuation, storedValuation, "an untouched entry is not re-rated")
        XCTAssertEqual(try MoneyCodec.encode(draft.amount), "12.5")
    }

    // MARK: — UIEDIT-03: a wallet keeps its opening balance precision

    func testRenamingAWalletLeavesItsOpeningBalanceExact() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Cold", currency: "BTC",
                                    opening: "0.12345678")
        XCTAssertEqual(wallet.openingBalanceExact, "0.12345678")

        XCTAssertTrue(store.saveWallet(WalletDraft(id: wallet.id, name: "Cold storage",
                                                   type: wallet.walletType, currency: wallet.currency,
                                                   openingBalance: wallet.openingBalance,
                                                   icon: wallet.icon)))
        let reloaded = try XCTUnwrap(try wallets().first)
        XCTAssertEqual(reloaded.name, "Cold storage")
        XCTAssertEqual(reloaded.openingBalanceExact, "0.12345678")
    }

    // MARK: — UIEDIT-04: cancelling is a real cancel

    /// The editor holds text, not the stored object, so abandoning an edit
    /// cannot leave a half-applied change behind.
    func testAbandonedEditsNeverReachTheStore() throws {
        let tx = try makeTransaction(amount: "12.50", merchant: "Cafe")
        var fields = TransactionEditor.fields(from: tx)
        fields.amountText = "999"
        fields.merchant = "Typo"
        // Nothing is committed: no `draft(...)` result is applied.

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(reloaded.amountExact, "12.5")
        XCTAssertEqual(reloaded.merchant, "Cafe")
        XCTAssertEqual(reloaded.localGeneration, 1, "no second generation was produced")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 1)
    }

    // MARK: — UIEDIT-05: clearing the wallet clears the effect

    func testClearingTheWalletRemovesItsEffect() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "EUR", opening: "100")
        let tx = try makeTransaction(amount: "10", walletID: wallet.id)
        XCTAssertEqual(store.walletBalances()[wallet.id], try MoneyCodec.decode("90"))

        var fields = TransactionEditor.fields(from: tx)
        fields.walletID = nil
        guard case .success(let draft) = TransactionEditor.draft(
            from: fields, id: tx.id, wallets: try wallets(), ownerID: ownerID, previous: tx) else {
            return XCTFail("clearing the wallet is a valid state")
        }
        XCTAssertNil(draft.walletID)
        XCTAssertNil(draft.walletAmount, "no stale quantity is left behind")
        XCTAssertTrue(store.editTransaction(draft))
        XCTAssertEqual(store.walletBalances()[wallet.id], try MoneyCodec.decode("100"))
    }

    // MARK: — UIEDIT-06: a second tap is not a second transaction

    func testASecondConfirmDoesNotCreateASecondTransaction() async throws {
        let parsed = ParsedTransaction(type: .expense, amount: 12.5, currency: "EUR",
                                       categoryName: "Food", merchant: "Cafe", note: "",
                                       occurredAt: LedgerIDs.eventTime, confidence: 1,
                                       rawInput: "", source: .manual, amountExact: "12.5")

        let first = await store.saveConfirmed(parsed: parsed)
        let second = await store.saveConfirmed(parsed: parsed)

        XCTAssertNotNil(first)
        XCTAssertEqual(second?.id, first?.id, "the same identity comes back, not a new record")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 1)
        XCTAssertNil(store.lastWriteErrorCode)
    }

    // MARK: — UIEDIT-07: a failed save is reported as a failure

    func testAFailedLocalSaveReportsItsCodeAndWritesNothing() async throws {
        let parsed = ParsedTransaction(type: .expense, amount: 12.5, currency: "ZZZ",
                                       categoryName: "Food", merchant: "Cafe", note: "",
                                       occurredAt: LedgerIDs.eventTime, confidence: 1,
                                       rawInput: "", source: .manual, amountExact: "12.5")

        let saved = await store.saveConfirmed(parsed: parsed)

        XCTAssertNil(saved, "a rejected entry must never come back as if it were saved")
        XCTAssertEqual(store.lastWriteErrorCode, "unsupported_currency")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 0)
    }

    /// Every code a write path can report has to reach the user as a sentence,
    /// never as the raw token.
    func testEveryKnownErrorCodeHasWording() {
        for code in LedgerErrorCopy.knownCodes {
            let text = LedgerErrorCopy.text(for: code)
            XCTAssertNotNil(text, code)
            XCTAssertNotEqual(text, "err_\(code)", "\(code) has no translation")
            XCTAssertFalse(text?.contains("_") == true, "\(code) leaked a raw token")
        }
        XCTAssertEqual(LedgerErrorCopy.text(for: "a_code_added_later"), L("err_generic"))
        XCTAssertNil(LedgerErrorCopy.text(for: nil))
    }

    // MARK: — UIEDIT-08: the app's locale decides, not the device's

    func testTheExactDisplayStringKeepsEveryStoredDigit() {
        // The separator follows the app's language, so the assertion is about
        // the digits surviving — which is what rounding used to destroy.
        let separator = Formatters.exactAmount("0.5").replacingOccurrences(of: "0", with: "")
            .replacingOccurrences(of: "5", with: "")

        XCTAssertEqual(Formatters.exactAmount("0.00000001"), "0\(separator)00000001")
        XCTAssertEqual(Formatters.exactAmount("1234567.89"), "1 234 567\(separator)89")
        XCTAssertEqual(Formatters.exactAmount("-12.5", currency: "EUR"), "-12\(separator)5 EUR")
        XCTAssertEqual(Formatters.exactAmount("12"), "12", "no separator is invented")
        XCTAssertEqual(Formatters.exactAmount("1000"), "1 000")
    }

    // MARK: — Wallet rules reaching the editor

    func testASelfTransferIsRefusedBeforeAnythingIsWritten() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "EUR", opening: "100")
        var fields = TransactionEditor.fields(from: try makeTransaction(amount: "10"))
        fields.type = .transfer
        fields.walletID = wallet.id
        fields.destinationWalletID = wallet.id

        XCTAssertEqual(TransactionEditor.problem(in: fields, id: LedgerIDs.expense,
                                                 wallets: try wallets(), ownerID: ownerID)?.code,
                       "transfer_to_same_wallet")
    }

    func testAnArchivedWalletCannotBeChosenForANewEntry() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Old", currency: "EUR", opening: "100")
        XCTAssertTrue(store.archiveWallet(id: wallet.id))

        var fields = TransactionEditor.fields(from: try makeTransaction(amount: "10"))
        fields.walletID = wallet.id
        XCTAssertEqual(TransactionEditor.problem(in: fields, id: LedgerIDs.expense,
                                                 wallets: try wallets(), ownerID: ownerID)?.code,
                       "archived_wallet")
    }

    /// WAL-12: the currency of a wallet with history is fixed.
    func testCurrencyCannotChangeOnceEntriesPointAtTheWallet() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "EUR", opening: "100")
        try makeTransaction(amount: "10", walletID: wallet.id)
        XCTAssertTrue(store.walletHasLinkedRecords(id: wallet.id))

        XCTAssertFalse(store.saveWallet(WalletDraft(id: wallet.id, name: "Cash", type: .cash,
                                                    currency: "USD",
                                                    openingBalance: try MoneyCodec.decode("100"),
                                                    icon: "")))
        XCTAssertEqual(store.lastWriteErrorCode, "wallet_currency_is_locked")
        XCTAssertEqual(try wallets().first?.currency, "EUR")
    }

    /// WAL-13: the opening balance moves the current balance by exactly that
    /// difference, without inventing a transaction to explain it.
    func testEditingTheOpeningBalanceMovesTheCurrentBalanceByExactlyThatMuch() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "EUR",
                                    opening: "1000")
        try makeTransaction(amount: "10", walletID: wallet.id)
        XCTAssertEqual(store.walletBalances()[wallet.id], try MoneyCodec.decode("990"))

        XCTAssertTrue(store.saveWallet(WalletDraft(id: wallet.id, name: "Cash", type: .cash,
                                                   currency: "EUR",
                                                   openingBalance: try MoneyCodec.decode("900"),
                                                   icon: "")))
        XCTAssertEqual(store.walletBalances()[wallet.id], try MoneyCodec.decode("890"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 1,
                       "no balancing entry was invented")
    }

    /// Archiving a wallet hides it from new entries and keeps its history.
    func testArchivingAWalletKeepsItsHistoryReadable() throws {
        let wallet = try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "EUR", opening: "100")
        let tx = try makeTransaction(amount: "10", walletID: wallet.id)

        XCTAssertTrue(store.archiveWallet(id: wallet.id))

        XCTAssertTrue(LedgerScope.activeWallets(try wallets(), ownerID: ownerID).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Wallet>()), 1, "the row is retained")
        XCTAssertNil(try context.fetch(FetchDescriptor<Transaction>()).first?.deletedAt)
        XCTAssertEqual(tx.walletID, wallet.id, "the link is not cut")
        XCTAssertEqual(store.walletBalances()[wallet.id], try MoneyCodec.decode("90"),
                       "an archived wallet still calculates")
    }

    // MARK: — Deleting

    func testDeletingLeavesATombstoneAndQueuesTheIntent() throws {
        let tx = try makeTransaction(amount: "12.50")
        XCTAssertTrue(store.deleteTransaction(tx, messages: []))

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertNotNil(row.deletedAt, "the intent to delete has to outlive this launch")
        XCTAssertTrue(LedgerScope.activeTransactions([row], ownerID: ownerID).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 2)
    }

    // MARK: — The parsed-to-draft conversion

    func testAnExactStringBeatsTheDouble() throws {
        let parsed = ParsedTransaction(type: .expense, amount: 12.499999999, currency: "EUR",
                                       categoryName: "Food", merchant: "", note: "",
                                       occurredAt: LedgerIDs.eventTime, confidence: 1,
                                       rawInput: "", source: .manual, amountExact: "12.50")
        let draft = try ParsedTransactionDraft.make(from: parsed, categoryName: "Food",
                                                    wallets: [], ownerID: ownerID)
        XCTAssertEqual(try MoneyCodec.encode(draft.amount), "12.5")
    }

    /// An ambiguous wallet name attaches nothing rather than picking one. The
    /// transaction is still recorded — the wallet is what is left unset.
    func testAnAmbiguousWalletNameIsNotGuessed() throws {
        try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "EUR")
        try makeWallet(LedgerIDs.walletB, name: "cash", currency: "EUR")

        var parsed = ParsedTransaction(type: .expense, amount: 10, currency: "EUR",
                                       categoryName: "Food", merchant: "", note: "",
                                       occurredAt: LedgerIDs.eventTime, confidence: 1,
                                       rawInput: "", source: .manual, amountExact: "10")
        parsed.walletName = "Cash"

        let draft = try ParsedTransactionDraft.make(from: parsed, categoryName: "Food",
                                                    wallets: try wallets(), ownerID: ownerID)
        XCTAssertNil(draft.walletID)
        XCTAssertNil(draft.walletAmount)
    }

    /// A wallet in another currency needs the exact quantity that left it, so
    /// the draft comes back without a wallet and the editor asks for it.
    func testADifferentCurrencyWalletIsNotAttachedAtAnInventedRate() throws {
        try makeWallet(LedgerIDs.walletA, name: "Cash", currency: "USD")
        var parsed = ParsedTransaction(type: .expense, amount: 10, currency: "EUR",
                                       categoryName: "Food", merchant: "", note: "",
                                       occurredAt: LedgerIDs.eventTime, confidence: 1,
                                       rawInput: "", source: .manual, amountExact: "10")
        parsed.walletName = "Cash"

        let draft = try ParsedTransactionDraft.make(from: parsed, categoryName: "Food",
                                                    wallets: try wallets(), ownerID: ownerID)
        XCTAssertNil(draft.walletID)
    }

    func testUSDIsValuedByIdentityAndNothingElseIsGivenARate() {
        let usd = ParsedTransactionDraft.defaultValuation(currency: "USD", at: LedgerIDs.eventTime)
        XCTAssertEqual(usd.state, .valued)
        XCTAssertEqual(usd.quote?.source, "identity")

        let eur = ParsedTransactionDraft.defaultValuation(currency: "EUR", at: LedgerIDs.eventTime)
        XCTAssertEqual(eur, .unvalued, "no rate table: an unchosen foreign valuation is none, not a guess")
    }

    func testEditorStringsAreLocalized() {
        for key in ["editor_transfer", "editor_wallet_source", "editor_wallet_destination",
                    "editor_wallet_none", "editor_wallet_archived", "editor_amount_in",
                    "editor_opening_balance", "editor_current_balance", "editor_currency_locked",
                    "editor_archive_wallet", "editor_archive_explains",
                    "status_saved_on_device", "status_waiting_to_sync", "err_generic"] {
            let translations = LocalizationManager.translationsData[key]
            XCTAssertNotNil(translations, "missing \(key)")
            for language in ["en", "uk", "ru", "es", "de", "pl"] {
                XCTAssertNotNil(translations?[language], "\(key) has no \(language)")
            }
        }
    }
}
