import Foundation

/// Reads stored rows as the exact values the ledger calculations expect.
///
/// The stored `Double` mirrors (`Wallet.balance`, `Transaction.originalAmount`)
/// are display leftovers. Nothing here reads them as authority except where a
/// row predates the ledger entirely and there is no exact field to read.

extension Wallet {

    /// The balance this wallet started from.
    ///
    /// A wallet written before the ledger has no `openingBalanceExact` and a
    /// `balance` that was maintained as a running total. For such a wallet no
    /// transaction carries its id, so no effects are added to it and treating
    /// the stored total as the opening balance yields exactly the number the
    /// user already sees. Once it is adopted, the exact field is authoritative.
    var openingBalance: Decimal {
        if let exact = openingBalanceExact, let value = try? MoneyCodec.decode(exact) {
            return value
        }
        return Decimal(balance)
    }

    var descriptor: WalletDescriptor {
        WalletDescriptor(id: id, ownerID: userId, currency: currency, isArchived: isArchived)
    }
}

extension Transaction {

    /// The stored record as a draft, for balance and reporting calculations.
    ///
    /// `nil` when the row has no exact amount — a legacy row that has not been
    /// adopted. Such a row is left out of exact calculations rather than
    /// having a Double read in as if it were exact.
    var draftForCalculation: TransactionDraft? {
        guard let exact = amountExact, let amount = try? MoneyCodec.decode(exact) else { return nil }
        return TransactionDraft(id: id,
                                type: type,
                                amount: amount,
                                currency: originalCurrency,
                                walletID: walletID,
                                walletAmount: walletAmountExact.flatMap { try? MoneyCodec.decode($0) },
                                destinationWalletID: destinationWalletID,
                                destinationAmount: destinationAmountExact.flatMap { try? MoneyCodec.decode($0) },
                                categoryName: categoryName,
                                merchant: merchant,
                                note: note,
                                occurredAt: occurredAt,
                                source: source,
                                confidence: (try? MoneyCodec.decode(String(confidence))) ?? 1,
                                rawInput: rawInput,
                                valuation: storedValuation)
    }

    private var storedValuation: LedgerValuation {
        switch valuationState {
        case .unvalued:
            return .unvalued
        case .valued:
            if let data = quoteJSON, let quote = try? JSONDecoder().decode(RateQuote.self, from: data) {
                return .quoted(quote)
            }
            // Marked valued with no quote to show for it. Reported as what it
            // is rather than upgraded to a verified valuation.
            return .legacyUnverified(baseAmount: baseAmountExact.flatMap { try? MoneyCodec.decode($0) },
                                     rate: rateExact.flatMap { try? MoneyCodec.decode($0) })
        case .legacyUnverified:
            return .legacyUnverified(baseAmount: baseAmountExact.flatMap { try? MoneyCodec.decode($0) },
                                     rate: rateExact.flatMap { try? MoneyCodec.decode($0) })
        }
    }
}
