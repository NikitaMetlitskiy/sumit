import Foundation

/// Turns what the parser or an editor produced into the typed draft the ledger
/// commands accept.
///
/// `ParsedTransaction.amountExact` is authoritative. The typed path fills it
/// from keystrokes and the parse contract v2 path from `amount_decimal`. The
/// Double fallback below remains only for a `ParsedTransaction` built without
/// one; it reads the Double through its shortest decimal description — the
/// value it actually denotes — rather than multiplying it out and hoping.
enum ParsedTransactionDraft {

    enum BuildError: Error, Equatable {
        /// The amount could not be read exactly. Carries a machine code.
        case amount(String)
        /// A wallet was named but could not be attached safely.
        case wallet(String)

        var code: String {
            switch self {
            case .amount(let code): return code
            case .wallet(let code): return code
            }
        }
    }

    static func make(from parsed: ParsedTransaction,
                     id: UUID = UUID(),
                     categoryName: String,
                     wallets: [Wallet],
                     ownerID: String,
                     now: Date = .now) throws -> TransactionDraft {

        guard CurrencyService.isSupported(parsed.currency) else {
            throw BuildError.amount("unsupported_currency")
        }
        let amount = try decodeAmount(parsed)
        let (walletID, walletAmount) = try resolveWallet(parsed, amount: amount,
                                                         wallets: wallets, ownerID: ownerID)
        let (destinationID, destinationAmount) = try resolveDestination(
            parsed, sourceID: walletID, sourceAmount: walletAmount,
            wallets: wallets, ownerID: ownerID)

        return TransactionDraft(id: id,
                                type: parsed.type,
                                amount: amount,
                                currency: parsed.currency.uppercased(),
                                walletID: walletID,
                                walletAmount: walletAmount,
                                destinationWalletID: destinationID,
                                destinationAmount: destinationAmount,
                                categoryName: categoryName,
                                merchant: parsed.merchant,
                                note: parsed.note,
                                occurredAt: parsed.occurredAt,
                                source: parsed.source,
                                confidence: confidence(parsed.confidence),
                                rawInput: parsed.rawInput,
                                valuation: parsed.valuation
                                    ?? defaultValuation(currency: parsed.currency, at: parsed.occurredAt))
    }

    // MARK: — Amount

    static func decodeAmount(_ parsed: ParsedTransaction) throws -> Decimal {
        if let exact = parsed.amountExact, !exact.isEmpty {
            do { return try MoneyCodec.decode(exact) }
            catch let error as MoneyError { throw BuildError.amount(code(for: error)) }
        }
        guard parsed.amount.isFinite else { throw BuildError.amount("non_finite_amount") }
        // `description` on a Double is its shortest round-tripping decimal form.
        // Reading that is the closest thing to "what this Double means"; it is
        // not a claim that the original input had no more digits than this.
        do { return try MoneyCodec.decode(String(parsed.amount)) }
        catch let error as MoneyError { throw BuildError.amount(code(for: error)) }
    }

    private static func confidence(_ value: Double) -> Decimal {
        guard value.isFinite else { return 1 }
        let clamped = min(max(value, 0), 1)
        return (try? MoneyCodec.decode(String(clamped))) ?? 1
    }

    private static func code(for error: MoneyError) -> String {
        switch error {
        case .invalidSyntax:       return "invalid_amount"
        case .nonFinite:           return "non_finite_amount"
        case .outOfRange:          return "amount_out_of_range"
        case .excessPrecision:     return "excess_precision"
        case .arithmeticFailure:   return "arithmetic_failure"
        case .unsupportedCurrency: return "unsupported_currency"
        }
    }

    // MARK: — Wallet

    /// A wallet is attached only when it can be attached **exactly**.
    ///
    /// The old code matched wallets by name and adjusted a stored balance. Two
    /// wallets called "Cash" made that pick one arbitrarily, and a wallet in a
    /// different currency made it convert at whatever rate was loaded. Here a
    /// name has to resolve to exactly one live wallet, and a different currency
    /// means the exact wallet-currency quantity is the user's to enter — so the
    /// draft comes back with no wallet and the editor asks.
    private static func resolveWallet(_ parsed: ParsedTransaction,
                                      amount: Decimal,
                                      wallets: [Wallet],
                                      ownerID: String) throws -> (UUID?, Decimal?) {
        let live = wallets.filter { $0.userId == ownerID && $0.deletedAt == nil }

        // A transfer moves money between two of the user's own wallets. The
        // parser may *suggest* one by name; which two it is, is the user's call.
        if parsed.type == .transfer, parsed.walletID == nil { return (nil, nil) }

        if let id = parsed.walletID {
            guard let wallet = live.first(where: { $0.id == id }) else {
                throw BuildError.wallet("unknown_wallet")
            }
            return try attach(wallet, parsed: parsed, amount: amount)
        }

        let name = parsed.walletName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return (nil, nil) }
        let matches = live.filter { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        // Ambiguous or unknown: recorded without a wallet rather than guessed
        // into the wrong one. The transaction itself is never lost over this.
        guard matches.count == 1, let wallet = matches.first else { return (nil, nil) }
        return try attach(wallet, parsed: parsed, amount: amount)
    }

    /// Transfers only, and only from an identity the user picked. Anything
    /// incomplete stays incomplete here, and the store refuses it with
    /// `incomplete_transfer` — a half-specified transfer is never saved.
    private static func resolveDestination(_ parsed: ParsedTransaction,
                                           sourceID: UUID?,
                                           sourceAmount: Decimal?,
                                           wallets: [Wallet],
                                           ownerID: String) throws -> (UUID?, Decimal?) {
        guard parsed.type == .transfer, let destinationID = parsed.destinationWalletID else {
            return (nil, nil)
        }
        guard let destination = wallets.first(where: {
            $0.id == destinationID && $0.userId == ownerID && $0.deletedAt == nil
        }) else {
            throw BuildError.wallet("unknown_wallet")
        }
        if let exact = parsed.destinationAmountExact, !exact.isEmpty {
            do { return (destinationID, try MoneyCodec.decode(exact)) }
            catch let error as MoneyError { throw BuildError.amount(code(for: error)) }
        }
        let source = sourceID.flatMap { id in wallets.first { $0.id == id } }
        guard let source, source.currency.uppercased() == destination.currency.uppercased() else {
            return (destinationID, nil)
        }
        return (destinationID, sourceAmount)
    }

    private static func attach(_ wallet: Wallet, parsed: ParsedTransaction,
                               amount: Decimal) throws -> (UUID?, Decimal?) {
        if let exact = parsed.walletAmountExact, !exact.isEmpty {
            do { return (wallet.id, try MoneyCodec.decode(exact)) }
            catch let error as MoneyError { throw BuildError.amount(code(for: error)) }
        }
        // Same currency is the only case where the wallet-currency quantity is
        // known without a rate: it is the same number.
        guard wallet.currency.uppercased() == parsed.currency.uppercased() else { return (nil, nil) }
        return (wallet.id, amount)
    }

    // MARK: — Valuation

    /// What a record is valued at when nobody chose anything: USD at identity,
    /// everything else **without** conversion. No rate is looked up or assumed
    /// here; a quote reaches a record only because a person accepted it.
    static func defaultValuation(currency: String, at date: Date) -> LedgerValuation {
        currency.uppercased() == "USD" ? .quoted(.identity(at: date)) : .unvalued
    }
}
