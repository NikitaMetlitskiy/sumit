import Foundation

// MARK: — Errors

/// Typed failures for every monetary boundary. No monetary path returns an
/// optional or falls back to a previous value: a bad amount is an error.
nonisolated enum MoneyError: Error, Equatable {
    /// The text is not a well-formed amount for the requested grammar.
    case invalidSyntax
    /// A Decimal is NaN, or an operation produced a non-finite value.
    case nonFinite
    /// The value is outside the ledger's explicit product limits, or violates
    /// the caller's positive/non-zero requirement.
    case outOfRange
    /// More fractional digits than the currency's entry precision allows.
    case excessPrecision
    /// NSDecimal reported a calculation error (overflow, underflow, divide by zero).
    case arithmeticFailure
    /// The currency has no declared ledger precision.
    case unsupportedCurrency
}

// MARK: — Currency entry precision

/// Ledger entry precision per currency. These are this application's ledger
/// decisions, not a claim about bank or exchange execution precision.
/// Legacy values recorded outside these limits are preserved unchanged; the
/// limits apply to newly entered amounts only.
nonisolated enum MoneyPrecision {
    /// Fractional digits accepted for a new entry in this currency.
    static let entryScale: [String: Int] = [
        "USD": 2, "EUR": 2, "UAH": 2, "GBP": 2, "PLN": 2, "CZK": 2,
        "CAD": 2, "CHF": 2, "RUB": 2, "KZT": 2,
        "JPY": 0,
        "USDC": 6, "USDT": 6,
        "BTC": 8,
        "ETH": 18,
    ]

    /// Scale used for booked USD base amounts and for rates.
    static let baseScale = 18

    static func scale(for currency: String) throws -> Int {
        guard let scale = entryScale[currency.uppercased()] else {
            throw MoneyError.unsupportedCurrency
        }
        return scale
    }

    static func isSupported(_ currency: String) -> Bool {
        entryScale[currency.uppercased()] != nil
    }
}

// MARK: — Canonical decimal encoding

/// Canonical string form of a monetary quantity: dot separator, no grouping,
/// no exponent, no leading plus, no unnecessary trailing fractional zeros,
/// zero written as `0`. This is the only form persisted or put on the wire.
nonisolated enum MoneyCodec {

    /// Largest absolute amount accepted for a new entry.
    static let maxEntryAmount = Decimal(string: "1000000000000")!      // 1e12
    /// Largest absolute booked base (USD) amount.
    static let maxBaseAmount = Decimal(string: "1000000000000000000")! // 1e18

    // MARK: Encode

    static func encode(_ value: Decimal) throws -> String {
        guard !value.isNaN else { throw MoneyError.nonFinite }
        // Decimal is exact base-10 and its description already drops redundant
        // trailing zeros and normalizes -0 to 0. Verify rather than trust it:
        // an exponent form or stray character must never reach the wire.
        let text = value.description
        guard isCanonical(text) else { throw MoneyError.arithmeticFailure }
        return text
    }

    /// True when `text` is exactly the canonical form this codec emits.
    static func isCanonical(_ text: String) -> Bool {
        guard let parts = split(text) else { return false }
        if parts.integer.count > 1 && parts.integer.hasPrefix("0") { return false }
        if let fraction = parts.fraction {
            if fraction.isEmpty || fraction.hasSuffix("0") { return false }
        }
        if parts.isNegative && parts.integer == "0" && parts.fraction == nil { return false }
        return true
    }

    // MARK: Decode

    /// Strict full-string decode. `Decimal(string:)` accepts exponents and
    /// silently parses a prefix ("12abc" → 12), so the grammar is validated
    /// first and the whole string must match.
    static func decode(_ text: String) throws -> Decimal {
        guard split(text) != nil else { throw MoneyError.invalidSyntax }
        guard let value = Decimal(string: text), !value.isNaN else {
            throw MoneyError.invalidSyntax
        }
        return value
    }

    // MARK: Quantize

    /// Half-even (bankers') quantization to `scale` fractional digits.
    /// PostgreSQL's `round` uses half-up on numeric, so this exact rule is the
    /// shared contract both sides implement and test.
    static func quantize(_ value: Decimal, scale: Int) throws -> Decimal {
        guard !value.isNaN else { throw MoneyError.nonFinite }
        guard scale >= 0, scale <= 38 else { throw MoneyError.outOfRange }
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .bankers)
        guard !result.isNaN else { throw MoneyError.arithmeticFailure }
        return result
    }

    /// Fractional digit count of an exact decimal. `12.50` normalizes to
    /// exponent -1 and therefore reports one fractional digit.
    static func fractionDigits(of value: Decimal) -> Int {
        max(0, -value.exponent)
    }

    // MARK: Entry validation

    /// Applies the product limits to a value a user is entering.
    /// - Parameters:
    ///   - allowNegative: true only for wallet opening balances (debt).
    ///   - allowZero: true only for wallet opening balances.
    static func validateEntry(_ value: Decimal,
                              currency: String,
                              allowNegative: Bool = false,
                              allowZero: Bool = false) throws {
        guard !value.isNaN else { throw MoneyError.nonFinite }
        if value == 0 {
            guard allowZero else { throw MoneyError.outOfRange }
        } else if value < 0 {
            guard allowNegative else { throw MoneyError.outOfRange }
        }
        var magnitude = value
        if magnitude < 0 { magnitude.negate() }
        guard magnitude <= maxEntryAmount else { throw MoneyError.outOfRange }
        let scale = try MoneyPrecision.scale(for: currency)
        guard fractionDigits(of: value) <= scale else { throw MoneyError.excessPrecision }
    }

    // MARK: Editing

    /// Exact text for an editable amount field: canonical digits with the
    /// locale's decimal separator and **no grouping**, so reopening an editor
    /// and saving it unchanged cannot alter the stored value.
    static func editString(_ value: Decimal, locale: Locale) throws -> String {
        let canonical = try encode(value)
        let separator = locale.decimalSeparator ?? "."
        return canonical.replacingOccurrences(of: ".", with: separator)
    }

    // MARK: Grammar

    private struct Parts {
        var isNegative: Bool
        var integer: String
        var fraction: String?
    }

    /// Validates `[-]digits[.digits]` over the whole string and returns its parts.
    /// Rejects a leading `+`, exponents, grouping separators, spaces, NaN and
    /// any trailing character.
    private static func split(_ text: String) -> Parts? {
        var rest = Substring(text)
        var isNegative = false
        if rest.hasPrefix("-") {
            isNegative = true
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        let pieces = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        let integer = String(pieces[0])
        let fraction = pieces.count == 2 ? String(pieces[1]) : nil
        guard !integer.isEmpty, isASCIIDigits(integer) else { return nil }
        if let fraction {
            guard !fraction.isEmpty, isASCIIDigits(fraction) else { return nil }
        }
        return Parts(isNegative: isNegative, integer: integer, fraction: fraction)
    }

    private static func isASCIIDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }
}
