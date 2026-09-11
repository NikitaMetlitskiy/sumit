import XCTest
@testable import SumIt

/// WAL group from acceptance-tests.md §6. Pure arithmetic: no store, no
/// network, no UI. Every expectation is compared as an exact `Decimal`.
final class WalletLedgerTests: XCTestCase {

    // MARK: — Fixture helpers

    private let owner = LedgerIDs.ownerA
    private let otherOwner = LedgerIDs.ownerB

    private func wallet(_ id: UUID, _ currency: String, archived: Bool = false,
                        owner: String? = nil) -> WalletDescriptor {
        WalletDescriptor(id: id, ownerID: owner ?? self.owner,
                         currency: currency, isArchived: archived)
    }

    private var usdWallets: [UUID: WalletDescriptor] {
        [LedgerIDs.walletA: wallet(LedgerIDs.walletA, "USD"),
         LedgerIDs.walletB: wallet(LedgerIDs.walletB, "USD")]
    }

    private var mixedWallets: [UUID: WalletDescriptor] {
        var wallets = usdWallets
        wallets[LedgerIDs.walletEUR] = wallet(LedgerIDs.walletEUR, "EUR")
        wallets[LedgerIDs.walletBTC] = wallet(LedgerIDs.walletBTC, "BTC")
        return wallets
    }

    private func draft(_ type: TransactionType,
                       _ amount: String,
                       id: UUID = UUID(),
                       currency: String = "USD",
                       wallet walletID: UUID? = nil,
                       walletAmount: String? = nil,
                       destination: UUID? = nil,
                       destinationAmount: String? = nil) throws -> TransactionDraft {
        TransactionDraft(id: id, type: type,
                         amount: try MoneyCodec.decode(amount),
                         currency: currency,
                         walletID: walletID,
                         walletAmount: try walletAmount.map(MoneyCodec.decode) ?? (walletID == nil ? nil : try MoneyCodec.decode(amount)),
                         destinationWalletID: destination,
                         destinationAmount: try destinationAmount.map(MoneyCodec.decode),
                         categoryName: "Other", merchant: "", note: "",
                         occurredAt: LedgerIDs.eventTime, source: .manual,
                         confidence: 1, rawInput: "",
                         valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
    }

    private func balances(_ drafts: [TransactionDraft],
                          wallets: [UUID: WalletDescriptor]? = nil,
                          openingA: String = "1000",
                          openingB: String = "200") throws -> [UUID: Decimal] {
        try WalletLedger.balances(
            opening: [LedgerIDs.walletA: try MoneyCodec.decode(openingA),
                      LedgerIDs.walletB: try MoneyCodec.decode(openingB)],
            transactions: drafts,
            wallets: wallets ?? usdWallets,
            ownerID: owner)
    }

    private func text(_ value: Decimal?) throws -> String {
        try MoneyCodec.encode(try XCTUnwrap(value))
    }

    // MARK: — WAL-01, the canonical scenario

    /// The six steps from acceptance-tests.md §1, in order, each asserted exactly.
    func testFullBaseScenario() throws {
        let expense = try draft(.expense, "12.5", id: LedgerIDs.expense, wallet: LedgerIDs.walletA)
        let transfer = try draft(.transfer, "100", id: LedgerIDs.transfer,
                                 wallet: LedgerIDs.walletA, destination: LedgerIDs.walletB,
                                 destinationAmount: "100")

        // 1. opening
        var current = try balances([])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "1000")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "200")

        // 2. expense 12.5 from A
        current = try balances([expense])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "987.5")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "200")

        // 3. transfer 100 A→B
        current = try balances([expense, transfer])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "887.5")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "300")
        XCTAssertEqual(try text(current[LedgerIDs.walletA]! + current[LedgerIDs.walletB]!), "1187.5")

        // 4. edit the expense to 10.25 — the record is replaced, not adjusted
        let edited = try draft(.expense, "10.25", id: LedgerIDs.expense, wallet: LedgerIDs.walletA)
        current = try balances([edited, transfer])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "889.75")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "300")

        // 5. delete the transfer — it is simply absent
        current = try balances([edited])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "989.75")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "200")

        // 6. delete the expense — back to opening
        current = try balances([])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "1000")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "200")
    }

    /// The expense totals from the same scenario. A transfer is counted zero times.
    func testReportingTotalsAcrossTheScenario() throws {
        let expense = try draft(.expense, "12.5", id: LedgerIDs.expense, wallet: LedgerIDs.walletA)
        let transfer = try draft(.transfer, "100", id: LedgerIDs.transfer,
                                 wallet: LedgerIDs.walletA, destination: LedgerIDs.walletB,
                                 destinationAmount: "100")

        func expenses(_ drafts: [TransactionDraft]) -> Decimal {
            drafts.reduce(0) { $0 + WalletLedger.reportingAmount(for: $1).expense }
        }
        XCTAssertEqual(expenses([expense]), try MoneyCodec.decode("12.5"))
        XCTAssertEqual(expenses([expense, transfer]), try MoneyCodec.decode("12.5"),
                       "a transfer must not inflate expenses")
        XCTAssertEqual(expenses([]), 0)
    }

    // MARK: — WAL-02..04

    func testIncomeRaisesTheWallet() throws {
        let income = try draft(.income, "50", wallet: LedgerIDs.walletA)
        let current = try balances([income])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "1050")
        XCTAssertEqual(WalletLedger.reportingAmount(for: income).income, try MoneyCodec.decode("50"))
    }

    /// WAL-03. One record, two effects, combined balance unchanged.
    func testSameCurrencyTransferConservesTheCombinedBalance() throws {
        let transfer = try draft(.transfer, "100", id: LedgerIDs.transfer,
                                 wallet: LedgerIDs.walletA, destination: LedgerIDs.walletB,
                                 destinationAmount: "100")
        let effects = try WalletLedger.effects(for: transfer, wallets: usdWallets, ownerID: owner)
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(try WalletLedger.balance(opening: 0, effects: effects), 0)

        let current = try balances([transfer])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]! + current[LedgerIDs.walletB]!), "1200")
    }

    /// WAL-04. Both quantities are explicit and preserved; nothing is derived
    /// from a current market rate.
    func testCrossCurrencyTransferKeepsBothExplicitQuantities() throws {
        let transfer = try draft(.transfer, "100", wallet: LedgerIDs.walletA,
                                 destination: LedgerIDs.walletEUR, destinationAmount: "90")
        let effects = try WalletLedger.effects(for: transfer, wallets: mixedWallets, ownerID: owner)
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(effects.first { $0.walletID == LedgerIDs.walletA }?.signedAmount,
                       try MoneyCodec.decode("-100"))
        XCTAssertEqual(effects.first { $0.walletID == LedgerIDs.walletEUR }?.signedAmount,
                       try MoneyCodec.decode("90"))
    }

    // MARK: — WAL-05, WAL-06, WAL-17

    /// Editing both legs replaces both effects. There is no stale original.
    func testEditingATransferReplacesBothEffectsExactlyOnce() throws {
        let edited = try draft(.transfer, "40", id: LedgerIDs.transfer,
                               wallet: LedgerIDs.walletA, destination: LedgerIDs.walletB,
                               destinationAmount: "40")
        let current = try balances([edited])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "960")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "240")
    }

    /// WAL-06 / WAL-17. A deleted record is absent and contributes nothing;
    /// a record with a pending edit contributes once, in its edited form.
    func testDeletedContributesNothingAndPendingContributesOnce() throws {
        let pending = try draft(.expense, "10.25", id: LedgerIDs.expense, wallet: LedgerIDs.walletA)
        XCTAssertEqual(try text(try balances([])[LedgerIDs.walletA]), "1000")
        XCTAssertEqual(try text(try balances([pending])[LedgerIDs.walletA]), "989.75")
        // Passing the same entity twice would be a caller bug; the contract is
        // "current desired state of each active record, exactly once".
        XCTAssertEqual(try text(try balances([pending, pending])[LedgerIDs.walletA]), "979.5")
    }

    // MARK: — WAL-07..09, WAL-20 rejections

    func testSelfTransferIsRejected() throws {
        let bad = try draft(.transfer, "10", wallet: LedgerIDs.walletA,
                            destination: LedgerIDs.walletA, destinationAmount: "10")
        XCTAssertThrowsError(try WalletLedger.effects(for: bad, wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .selfTransfer)
        }
    }

    func testWalletFromAnotherOwnerIsRejected() throws {
        var wallets = usdWallets
        wallets[LedgerIDs.walletB] = wallet(LedgerIDs.walletB, "USD", owner: otherOwner)
        let bad = try draft(.transfer, "10", wallet: LedgerIDs.walletA,
                            destination: LedgerIDs.walletB, destinationAmount: "10")
        XCTAssertThrowsError(try WalletLedger.effects(for: bad, wallets: wallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .wrongOwner(LedgerIDs.walletB))
        }
    }

    func testUnknownWalletIsRejected() throws {
        let stranger = UUID()
        let bad = try draft(.expense, "10", wallet: stranger)
        XCTAssertThrowsError(try WalletLedger.effects(for: bad, wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .unknownWallet(stranger))
        }
    }

    /// WAL-09. An archived wallet may not be newly referenced — but the history
    /// that already points at it must still calculate.
    func testArchivedWalletRejectedForSaveButStillCalculable() throws {
        var wallets = usdWallets
        wallets[LedgerIDs.walletB] = wallet(LedgerIDs.walletB, "USD", archived: true)
        let record = try draft(.transfer, "10", wallet: LedgerIDs.walletA,
                               destination: LedgerIDs.walletB, destinationAmount: "10")

        XCTAssertThrowsError(try WalletLedger.validateForSave(record, wallets: wallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .archivedWallet(LedgerIDs.walletB))
        }
        XCTAssertEqual(try WalletLedger.effects(for: record, wallets: wallets, ownerID: owner).count, 2,
                       "archiving must not erase existing history")
    }

    /// WAL-20. A difference between equal-currency legs would be a hidden fee.
    func testUnequalSameCurrencyLegsAreRejected() throws {
        let bad = try draft(.transfer, "100", wallet: LedgerIDs.walletA,
                            destination: LedgerIDs.walletB, destinationAmount: "97")
        XCTAssertThrowsError(try WalletLedger.effects(for: bad, wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .unequalSameCurrencyLegs)
        }
    }

    func testIncompleteTransferIsRejected() throws {
        let missingDestination = try draft(.transfer, "10", wallet: LedgerIDs.walletA)
        XCTAssertThrowsError(try WalletLedger.effects(for: missingDestination,
                                                      wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .incompleteTransfer)
        }
    }

    func testNonTransferMayNotCarryADestination() throws {
        let bad = try draft(.expense, "10", wallet: LedgerIDs.walletA,
                            destination: LedgerIDs.walletB, destinationAmount: "10")
        XCTAssertThrowsError(try WalletLedger.effects(for: bad, wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .destinationOnNonTransfer)
        }
    }

    func testNonPositiveQuantitiesAreRejected() throws {
        let zero = try draft(.expense, "10", wallet: LedgerIDs.walletA, walletAmount: "0")
        XCTAssertThrowsError(try WalletLedger.effects(for: zero, wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .nonPositiveAmount)
        }
    }

    // MARK: — WAL-10, WAL-11: identity is the UUID, never the name

    /// `WalletDescriptor` carries no name at all, so a rename cannot reach the
    /// arithmetic. Two wallets sharing a display name are simply two UUIDs.
    func testEffectsFollowTheSelectedUUIDNotAName() throws {
        let toB = try draft(.expense, "25", wallet: LedgerIDs.walletB)
        let current = try balances([toB])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "1000", "the other wallet is untouched")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "175")
    }

    // MARK: — WAL-13: opening balance

    func testEditingOpeningBalanceShiftsCurrentBalanceExactly() throws {
        let expense = try draft(.expense, "12.5", wallet: LedgerIDs.walletA)
        let before = try balances([expense], openingA: "1000")
        let after = try balances([expense], openingA: "900")
        XCTAssertEqual(try text(before[LedgerIDs.walletA]), "987.5")
        XCTAssertEqual(try text(after[LedgerIDs.walletA]), "887.5")
        XCTAssertEqual(try XCTUnwrap(before[LedgerIDs.walletA]) - XCTUnwrap(after[LedgerIDs.walletA]),
                       try MoneyCodec.decode("100"),
                       "changing the opening balance must not invent income or expense")
    }

    func testNegativeOpeningBalanceIsADebtBalance() throws {
        let current = try balances([], openingA: "-50")
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "-50")
    }

    // MARK: — WAL-14..16

    /// WAL-14. Two independently created expenses both count. Nothing here can
    /// express "last writer wins on an absolute balance".
    func testIndependentRecordsFromTwoDevicesBothCount() throws {
        let first = try draft(.expense, "12.5", wallet: LedgerIDs.walletA)
        let second = try draft(.expense, "7.25", wallet: LedgerIDs.walletA)
        XCTAssertEqual(try text(try balances([first, second])[LedgerIDs.walletA]), "980.25")
    }

    /// WAL-15. A foreign-currency expense uses the confirmed exact wallet
    /// effect, never a conversion invented at read time.
    func testForeignCurrencyExpenseUsesTheConfirmedWalletEffect() throws {
        let expense = try draft(.expense, "90", currency: "EUR",
                                wallet: LedgerIDs.walletA, walletAmount: "97.20")
        let effects = try WalletLedger.effects(for: expense, wallets: usdWallets, ownerID: owner)
        XCTAssertEqual(effects.first?.signedAmount, try MoneyCodec.decode("-97.2"))
    }

    /// The same-currency case is the one that must agree exactly.
    func testSameCurrencyEffectMustEqualTheOriginalAmount() throws {
        let mismatch = try draft(.expense, "90", wallet: LedgerIDs.walletA, walletAmount: "80")
        XCTAssertThrowsError(try WalletLedger.effects(for: mismatch, wallets: usdWallets, ownerID: owner)) {
            XCTAssertEqual($0 as? WalletLedgerError, .sameCurrencyEffectMismatch)
        }
    }

    /// WAL-16. A fee is an ordinary expense of its own. It moves the expense
    /// total once and leaves the transfer excluded.
    func testFeeIsASeparateExpenseAndTransferStaysExcluded() throws {
        let transfer = try draft(.transfer, "100", wallet: LedgerIDs.walletA,
                                 destination: LedgerIDs.walletB, destinationAmount: "100")
        let fee = try draft(.expense, "1.5", wallet: LedgerIDs.walletA)

        let current = try balances([transfer, fee])
        XCTAssertEqual(try text(current[LedgerIDs.walletA]), "898.5")
        XCTAssertEqual(try text(current[LedgerIDs.walletB]), "300")

        let expenses = [transfer, fee].reduce(Decimal(0)) { $0 + WalletLedger.reportingAmount(for: $1).expense }
        XCTAssertEqual(expenses, try MoneyCodec.decode("1.5"))
    }

    // MARK: — WAL-19: order independence

    /// The balance is a function of the final set of active records, not of the
    /// order they arrived in. A stored-delta implementation cannot promise this.
    func testBalanceIsIndependentOfArrivalOrder() throws {
        var records: [TransactionDraft] = []
        var generator = SeededGenerator(seed: 20260909)
        for index in 0..<40 {
            let cents = Decimal(1 + (index * 7) % 97) / 4     // exact quarters
            let amount = try MoneyCodec.encode(cents)
            let toA = index % 3 != 0
            records.append(try draft(index % 5 == 0 ? .income : .expense, amount,
                                     wallet: toA ? LedgerIDs.walletA : LedgerIDs.walletB))
        }
        let reference = try balances(records)
        for _ in 0..<20 {
            let shuffled = records.shuffled(using: &generator)
            XCTAssertEqual(try balances(shuffled), reference)
        }
    }
}

/// Deterministic shuffling, so a failure can be reproduced exactly.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
