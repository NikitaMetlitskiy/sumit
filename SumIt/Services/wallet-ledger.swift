import Foundation

/// Why a wallet effect was rejected. Every case is a condition the old
/// name-and-delta code could not even express.
nonisolated enum WalletLedgerError: Error, Equatable {
    /// The draft references a wallet that does not exist in the given set.
    case unknownWallet(UUID)
    /// The wallet belongs to a different account.
    case wrongOwner(UUID)
    /// A new or edited record may not point at an archived wallet.
    case archivedWallet(UUID)
    /// Source and destination are the same wallet.
    case selfTransfer
    /// A transfer is missing a wallet reference or one of its two quantities.
    case incompleteTransfer
    /// A quantity that must be strictly positive is not.
    case nonPositiveAmount
    /// Destination fields appear on something that is not a transfer.
    case destinationOnNonTransfer
    /// A wallet quantity was given with no wallet, or the reverse.
    case walletAmountMismatch
    /// The effect in a wallet of the same currency must equal the original amount.
    case sameCurrencyEffectMismatch
    /// A transfer between two wallets of one currency must move equal quantities.
    case unequalSameCurrencyLegs
    /// A transfer's original currency must be its source wallet's currency.
    case transferCurrencyMismatch
    /// Arithmetic produced a non-finite result.
    case arithmeticFailure
}

/// The one place a transaction becomes wallet movement.
///
/// The previous implementation matched wallets **by name** and mutated a stored
/// absolute balance by a delta on every save and delete. Two wallets called
/// "Cash" were one wallet; renaming one silently moved its history; a failed
/// sync left the delta applied anyway; and a transfer only ever debited one
/// side because there was nowhere to record the other. None of that is
/// expressible here: effects are keyed by wallet UUID and a balance is derived,
/// never stored and adjusted.
///
///     balance(W) = openingBalance(W)
///                + Σ income.walletAmount      where walletID == W
///                − Σ expense.walletAmount     where walletID == W
///                − Σ transfer.walletAmount    where walletID == W
///                + Σ transfer.destinationAmount where destinationWalletID == W
nonisolated enum WalletLedger {

    // MARK: — Effects

    /// The signed effects one transaction has, in each wallet's own currency.
    ///
    /// This is the **calculation** entry point, so it deliberately accepts
    /// archived wallets: archiving hides a wallet from new entries but must
    /// never erase the history that already points at it. Use
    /// `validateForSave` for a draft the user is creating or editing.
    static func effects(for draft: TransactionDraft,
                        wallets: [UUID: WalletDescriptor],
                        ownerID: String) throws -> [WalletEffect] {
        try effects(for: draft, wallets: wallets, ownerID: ownerID, rejectArchived: false)
    }

    /// Everything `effects` checks, plus the rule that a new or edited record
    /// may not newly reference an archived wallet.
    static func validateForSave(_ draft: TransactionDraft,
                                wallets: [UUID: WalletDescriptor],
                                ownerID: String) throws {
        _ = try effects(for: draft, wallets: wallets, ownerID: ownerID, rejectArchived: true)
    }

    private static func effects(for draft: TransactionDraft,
                                wallets: [UUID: WalletDescriptor],
                                ownerID: String,
                                rejectArchived: Bool) throws -> [WalletEffect] {
        // An explicit switch on the type. There is no "anything that is not
        // income is a debit" shortcut: that is what made transfers behave like
        // expenses and lose their second leg.
        switch draft.type {
        case .expense, .income:
            guard draft.destinationWalletID == nil, draft.destinationAmount == nil else {
                throw WalletLedgerError.destinationOnNonTransfer
            }
            guard let walletID = draft.walletID else {
                // No wallet is a valid, fully specified state: the transaction
                // is recorded, it just moves nothing.
                guard draft.walletAmount == nil else { throw WalletLedgerError.walletAmountMismatch }
                return []
            }
            guard let amount = draft.walletAmount else { throw WalletLedgerError.walletAmountMismatch }
            let wallet = try resolve(walletID, in: wallets, ownerID: ownerID, rejectArchived: rejectArchived)
            try requirePositive(amount)
            if wallet.currency == draft.currency, amount != draft.amount {
                throw WalletLedgerError.sameCurrencyEffectMismatch
            }
            return [WalletEffect(walletID: walletID,
                                 signedAmount: draft.type == .income ? amount : -amount)]

        case .transfer:
            guard let sourceID = draft.walletID,
                  let destinationID = draft.destinationWalletID,
                  let sourceAmount = draft.walletAmount,
                  let destinationAmount = draft.destinationAmount else {
                throw WalletLedgerError.incompleteTransfer
            }
            guard sourceID != destinationID else { throw WalletLedgerError.selfTransfer }
            try requirePositive(sourceAmount)
            try requirePositive(destinationAmount)

            let source = try resolve(sourceID, in: wallets, ownerID: ownerID, rejectArchived: rejectArchived)
            let destination = try resolve(destinationID, in: wallets, ownerID: ownerID, rejectArchived: rejectArchived)

            guard source.currency == draft.currency else {
                throw WalletLedgerError.transferCurrencyMismatch
            }
            guard sourceAmount == draft.amount else {
                throw WalletLedgerError.sameCurrencyEffectMismatch
            }
            // Equal currencies must move equal quantities. A difference here
            // would be a fee or a spread hidden inside the transfer; fees are
            // ordinary separate expenses, never inferred from a mismatch.
            if source.currency == destination.currency, sourceAmount != destinationAmount {
                throw WalletLedgerError.unequalSameCurrencyLegs
            }
            return [WalletEffect(walletID: sourceID, signedAmount: -sourceAmount),
                    WalletEffect(walletID: destinationID, signedAmount: destinationAmount)]
        }
    }

    // MARK: — Balances

    /// Opening balance plus the effects that land in this wallet.
    static func balance(opening: Decimal, effects: [WalletEffect]) throws -> Decimal {
        var total = opening
        for effect in effects {
            total += effect.signedAmount
            guard !total.isNaN else { throw WalletLedgerError.arithmeticFailure }
        }
        return total
    }

    /// Balances for a whole set of wallets.
    ///
    /// - Parameter transactions: the **current desired state of each active
    ///   record, exactly once**. A deleted record is simply absent, which is
    ///   how it contributes nothing; a record with a pending local edit appears
    ///   once, in its edited form. There is no accumulating save/delete delta
    ///   to drift out of step.
    static func balances(opening: [UUID: Decimal],
                         transactions: [TransactionDraft],
                         wallets: [UUID: WalletDescriptor],
                         ownerID: String) throws -> [UUID: Decimal] {
        var totals = opening
        for wallet in wallets.keys where totals[wallet] == nil {
            totals[wallet] = 0
        }
        for draft in transactions {
            for effect in try effects(for: draft, wallets: wallets, ownerID: ownerID) {
                let running = (totals[effect.walletID] ?? 0) + effect.signedAmount
                guard !running.isNaN else { throw WalletLedgerError.arithmeticFailure }
                totals[effect.walletID] = running
            }
        }
        return totals
    }

    /// Signed contribution to expense and income reporting.
    /// A transfer moves money between the owner's own wallets, so it is neither
    /// an expense nor an income and must be counted exactly zero times.
    static func reportingAmount(for draft: TransactionDraft) -> (expense: Decimal, income: Decimal) {
        switch draft.type {
        case .expense:  return (draft.amount, 0)
        case .income:   return (0, draft.amount)
        case .transfer: return (0, 0)
        }
    }

    // MARK: — Helpers

    private static func resolve(_ id: UUID,
                                in wallets: [UUID: WalletDescriptor],
                                ownerID: String,
                                rejectArchived: Bool) throws -> WalletDescriptor {
        guard let wallet = wallets[id] else { throw WalletLedgerError.unknownWallet(id) }
        guard wallet.ownerID == ownerID else { throw WalletLedgerError.wrongOwner(id) }
        if rejectArchived, wallet.isArchived { throw WalletLedgerError.archivedWallet(id) }
        return wallet
    }

    private static func requirePositive(_ value: Decimal) throws {
        guard !value.isNaN else { throw WalletLedgerError.arithmeticFailure }
        guard value > 0 else { throw WalletLedgerError.nonPositiveAmount }
    }
}
