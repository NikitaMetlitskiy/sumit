import Foundation

/// The editable state of one transaction, as text.
///
/// The editor holds this, never a live SwiftData object. That is the whole
/// point: the previous editor mutated the stored record field by field, so a
/// rejected save left the record half-changed and a cancelled edit had already
/// happened. Here nothing reaches the store until a complete, valid draft is
/// produced.
nonisolated struct TransactionEditorFields: Equatable {
    var type: TransactionType
    /// Exactly what the user typed. Never re-rendered from a Double.
    var amountText: String
    var currency: String
    var categoryName: String
    var merchant: String
    var note: String
    var occurredAt: Date
    var walletID: UUID?
    /// Only used when the wallet's currency differs from `currency`.
    var walletAmountText: String
    var destinationWalletID: UUID?
    var destinationAmountText: String
    /// How the record is valued in USD. See `ValuationChoice`.
    var valuation: ValuationChoice = .automatic
}

/// The user's decision about USD valuation.
nonisolated enum ValuationChoice: Equatable {
    /// No explicit decision. Keeps an existing record's valuation when nothing
    /// that affects it changed, reuses its confirmed quote when only the amount
    /// changed, values USD at identity, and leaves a new non-USD record
    /// without conversion. Anything else needs a decision.
    case automatic
    /// Keep the record's confirmed rate although its date changed.
    case keepExisting
    /// A quote the user saw — provider or identity. The form only offers a
    /// stale one after the user confirms it.
    case quote(RateQuote)
    /// A rate the user typed.
    case manual(String)
    /// Explicitly without conversion.
    case unvalued
}

/// Which field is wrong, and why. The view puts the message under that field
/// rather than showing one message for the whole form.
nonisolated enum TransactionEditorProblem: Error, Equatable {
    case amount(String)
    case walletAmount(String)
    case destinationAmount(String)
    case form(String)

    var code: String {
        switch self {
        case .amount(let code), .walletAmount(let code),
             .destinationAmount(let code), .form(let code): return code
        }
    }
}

/// Either the exact value, or the machine code saying why it could not be read.
nonisolated enum DecodedAmount {
    case success(Decimal)
    case failure(String)
}

nonisolated enum TransactionEditor {

    // MARK: — Opening

    /// Loads a stored record into editable text.
    ///
    /// The amount comes from the exact stored string. The previous editor used
    /// `String(format: "%.0f", …)`, so opening a €12.50 entry and pressing Save
    /// wrote €12 — the defect this whole plan exists to remove.
    static func fields(from transaction: Transaction) -> TransactionEditorFields {
        let amount = transaction.amountExact
            ?? (try? MoneyCodec.editString(Decimal(transaction.originalAmount), locale: AppLocale.current))
            ?? ""
        return TransactionEditorFields(
            type: transaction.type,
            amountText: amount,
            currency: transaction.originalCurrency,
            categoryName: transaction.categoryName,
            merchant: transaction.merchant == "Unknown" ? "" : transaction.merchant,
            note: transaction.note,
            occurredAt: transaction.occurredAt,
            walletID: transaction.walletID,
            walletAmountText: transaction.walletAmountExact ?? "",
            destinationWalletID: transaction.destinationWalletID,
            destinationAmountText: transaction.destinationAmountExact ?? "")
    }

    static func fields(from parsed: ParsedTransaction, wallets: [Wallet], ownerID: String)
        -> TransactionEditorFields {
        let amount = parsed.amountExact
            ?? (try? MoneyCodec.editString(Decimal(parsed.amount), locale: AppLocale.current))
            ?? ""
        let named = wallets.first {
            $0.userId == ownerID && $0.deletedAt == nil && !parsed.walletName.isEmpty
                && $0.name.compare(parsed.walletName, options: .caseInsensitive) == .orderedSame
        }
        return TransactionEditorFields(
            type: parsed.type,
            amountText: amount,
            currency: parsed.currency,
            categoryName: parsed.categoryName,
            merchant: parsed.merchant == "Unknown" ? "" : parsed.merchant,
            note: parsed.note,
            occurredAt: parsed.occurredAt,
            walletID: parsed.walletID ?? named?.id,
            walletAmountText: parsed.walletAmountExact ?? "",
            destinationWalletID: parsed.destinationWalletID,
            destinationAmountText: parsed.destinationAmountExact ?? "",
            valuation: {
                switch parsed.valuation {
                case .quoted(let quote)?: return .quote(quote)
                case .unvalued?:          return .unvalued
                default:                  return .automatic
                }
            }())
    }

    // MARK: — Saving

    /// Produces the draft to commit, or the first problem that stops it.
    ///
    /// - Parameter previous: the record being edited, when there is one. Its
    ///   valuation is carried over untouched unless the amount or the currency
    ///   actually changed — editing a merchant must not silently re-rate the
    ///   entry at today's rate.
    static func draft(from fields: TransactionEditorFields,
                      id: UUID,
                      wallets: [Wallet],
                      ownerID: String,
                      previous: Transaction? = nil,
                      now: Date = .now) -> Result<TransactionDraft, TransactionEditorProblem> {

        guard CurrencyService.isSupported(fields.currency) else {
            return .failure(.amount("unsupported_currency"))
        }
        let amount: Decimal
        switch decode(fields.amountText, currency: fields.currency) {
        case .success(let value): amount = value
        case .failure(let code):  return .failure(.amount(code))
        }

        let live = wallets.filter { $0.userId == ownerID }
        func wallet(_ id: UUID?) -> Wallet? { id.flatMap { wid in live.first { $0.id == wid } } }

        var walletAmount: Decimal?
        var destinationAmount: Decimal?

        if let source = wallet(fields.walletID) {
            if source.currency.uppercased() == fields.currency.uppercased() {
                // Same currency moves the same quantity. Asking for it again
                // would only create a way for the two to disagree.
                walletAmount = amount
            } else {
                switch decode(fields.walletAmountText, currency: source.currency) {
                case .success(let value): walletAmount = value
                case .failure(let code):  return .failure(.walletAmount(code))
                }
            }
        } else if fields.walletID != nil {
            return .failure(.form("unknown_wallet"))
        }

        if fields.type == .transfer {
            guard let destination = wallet(fields.destinationWalletID) else {
                return .failure(.form("incomplete_transfer"))
            }
            guard let source = wallet(fields.walletID) else {
                return .failure(.form("incomplete_transfer"))
            }
            guard source.id != destination.id else {
                return .failure(.form("transfer_to_same_wallet"))
            }
            if source.currency.uppercased() == destination.currency.uppercased() {
                // Equal currencies move equal quantities; a difference would be
                // a fee hidden inside the transfer, and fees are their own entry.
                destinationAmount = walletAmount
            } else {
                switch decode(fields.destinationAmountText, currency: destination.currency) {
                case .success(let value): destinationAmount = value
                case .failure(let code):  return .failure(.destinationAmount(code))
                }
            }
        }

        let valuation: LedgerValuation
        switch resolveValuation(fields, amount: amount, previous: previous, now: now) {
        case .success(let value): valuation = value
        case .failure(let problem): return .failure(problem)
        }

        let draft = TransactionDraft(
            id: id,
            type: fields.type,
            amount: amount,
            currency: fields.currency.uppercased(),
            walletID: fields.walletID,
            walletAmount: walletAmount,
            destinationWalletID: fields.type == .transfer ? fields.destinationWalletID : nil,
            destinationAmount: fields.type == .transfer ? destinationAmount : nil,
            categoryName: fields.categoryName,
            merchant: fields.merchant,
            note: fields.note,
            occurredAt: fields.occurredAt,
            source: previous?.source ?? .manual,
            confidence: previous.map { (try? MoneyCodec.decode(String($0.confidence))) ?? 1 } ?? 1,
            rawInput: previous?.rawInput ?? "",
            valuation: valuation)

        // The same rules the store will enforce, run here so Save can be
        // disabled with the real reason instead of failing after the tap.
        do {
            try WalletLedger.validateForSave(
                draft,
                wallets: Dictionary(live.map { ($0.id, $0.descriptor) },
                                    uniquingKeysWith: { first, _ in first }),
                ownerID: ownerID)
        } catch let error as WalletLedgerError {
            return .failure(.form(code(for: error)))
        } catch {
            return .failure(.form("save_failed"))
        }

        return .success(draft)
    }

    /// The problem to show, or `nil` when the form is ready to save.
    static func problem(in fields: TransactionEditorFields, id: UUID, wallets: [Wallet],
                        ownerID: String, previous: Transaction? = nil) -> TransactionEditorProblem? {
        switch draft(from: fields, id: id, wallets: wallets, ownerID: ownerID, previous: previous) {
        case .success: return nil
        case .failure(let problem): return problem
        }
    }

    // MARK: — Helpers

    private static func decode(_ text: String, currency: String) -> DecodedAmount {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("invalid_amount") }
        do {
            return .success(try AmountParser.parse(trimmed, currency: currency, locale: AppLocale.current))
        } catch let error as MoneyError {
            return .failure(code(for: error))
        } catch {
            return .failure("invalid_amount")
        }
    }

    /// Decides the USD valuation of a draft (VAL-01…11).
    ///
    /// The rule that matters most: nothing replaces a booked rate behind the
    /// user's back. A metadata edit keeps it; an amount edit keeps the same
    /// confirmed quote and lets the store recompute the base; a change of
    /// currency or date needs an explicit keep, new quote, manual rate or
    /// no-conversion decision.
    private static func resolveValuation(_ fields: TransactionEditorFields, amount: Decimal,
                                         previous: Transaction?, now: Date) -> Result<LedgerValuation, TransactionEditorProblem> {
        let currency = fields.currency.uppercased()
        let stored = previous.flatMap(storedValuation)
        let currencyChanged = previous.map { $0.originalCurrency.uppercased() != currency } ?? false
        let dayChanged = previous.map { !Calendar.current.isDate($0.occurredAt, inSameDayAs: fields.occurredAt) } ?? false
        let amountChanged = previous.map { row in
            (row.amountExact.flatMap { try? MoneyCodec.decode($0) } ?? Decimal(row.originalAmount)) != amount
        } ?? false

        switch fields.valuation {
        case .unvalued:
            return .success(.unvalued)

        case .manual(let text):
            switch ManualRate.quote(text: text, currency: currency, amount: amount,
                                    occurredAt: fields.occurredAt, now: now) {
            case .success(let quote): return .success(.quoted(quote))
            case .failure(let problem): return .failure(problem)
            }

        case .quote(let quote):
            guard quote.currency == currency else { return .failure(.form("valuation_decision_required")) }
            return .success(.quoted(quote))

        case .keepExisting:
            guard !currencyChanged, case .quoted(let quote)? = stored else {
                return .failure(.form("valuation_decision_required"))
            }
            return .success(.quoted(quote))

        case .automatic:
            guard let previous else {
                return .success(ParsedTransactionDraft.defaultValuation(currency: currency, at: fields.occurredAt))
            }
            let existing = stored ?? legacyValuation(previous)
            if !currencyChanged && !dayChanged && !amountChanged {
                return .success(existing)
            }
            if case .unvalued = existing {
                // Nothing booked, so nothing can be silently replaced.
                return .success(.unvalued)
            }
            if !currencyChanged && !dayChanged, case .quoted(let quote) = existing {
                return .success(.quoted(quote))      // VAL-03: same quote, new base
            }
            if currency == "USD" && !currencyChanged {
                return .success(.quoted(.identity(at: fields.occurredAt)))
            }
            return .failure(.form("valuation_decision_required"))
        }
    }

    private static func storedValuation(_ row: Transaction) -> LedgerValuation? {
        row.draftForCalculation?.valuation
    }

    /// A row from before the ledger keeps its original stored numbers,
    /// labelled unverified (VAL-09). They are not re-derived or corrected.
    private static func legacyValuation(_ row: Transaction) -> LedgerValuation {
        let base = row.amountInBase.isFinite && row.amountInBase > 0
            ? try? MoneyCodec.decode(String(row.amountInBase)) : nil
        let rate = row.rateAtTime.isFinite && row.rateAtTime > 0
            ? try? MoneyCodec.decode(String(row.rateAtTime)) : nil
        return .legacyUnverified(baseAmount: base, rate: rate)
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

    private static func code(for error: WalletLedgerError) -> String {
        switch error {
        case .unknownWallet:              return "unknown_wallet"
        case .wrongOwner:                 return "wrong_scope"
        case .archivedWallet:             return "archived_wallet"
        case .selfTransfer:               return "transfer_to_same_wallet"
        case .incompleteTransfer:         return "incomplete_transfer"
        case .nonPositiveAmount:          return "non_positive_amount"
        case .destinationOnNonTransfer:   return "destination_on_non_transfer"
        case .walletAmountMismatch:       return "wallet_amount_mismatch"
        case .sameCurrencyEffectMismatch: return "same_currency_effect_mismatch"
        case .unequalSameCurrencyLegs:    return "unequal_same_currency_legs"
        case .transferCurrencyMismatch:   return "transfer_currency_mismatch"
        case .arithmeticFailure:          return "arithmetic_failure"
        }
    }
}
