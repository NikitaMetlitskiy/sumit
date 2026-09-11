import Foundation

/// Locale-aware parser for money the user types.
///
/// It consumes the **whole** string. `NumberFormatter` and `Decimal(string:)`
/// both accept a valid prefix and ignore the rest, which is how "12abc" and
/// "12.3.4" previously turned into 12; that behaviour is never acceptance here.
///
/// The app locale (not the device locale) decides ambiguous single separators:
/// `1,000` is 1000 in en-US and 1 in de-DE. The alternative decimal separator
/// is accepted only when it cannot be valid grouping for that locale, so
/// `12,50` in en-US is 12.5 while `1,23,456` stays a validation error.
enum AmountParser {

    /// Separators accepted as digit grouping whenever the locale groups with a
    /// space: ordinary space, no-break space, narrow no-break space, thin space.
    private static let spaceGrouping: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2009}"]

    static func parse(_ text: String,
                      currency: String,
                      locale: Locale,
                      allowNegative: Bool = false,
                      allowZero: Bool = false) throws -> Decimal {
        let value = try parseNumber(text, locale: locale, allowNegative: allowNegative)
        try MoneyCodec.validateEntry(value,
                                     currency: currency,
                                     allowNegative: allowNegative,
                                     allowZero: allowZero)
        return value
    }

    // MARK: — Grammar

    /// An exchange rate the user typed: the same whole-string, locale-aware
    /// grammar as an amount, but not bound to a currency's entry precision —
    /// a rate is a ratio, not a quantity of that currency. Strictly positive,
    /// at most 18 fractional digits, and within `numeric(38,18)`.
    static func parseRate(_ text: String, locale: Locale) throws -> Decimal {
        let value = try parseNumber(text, locale: locale, allowNegative: false)
        guard !value.isNaN else { throw MoneyError.nonFinite }
        guard value > 0 else { throw MoneyError.outOfRange }
        guard MoneyCodec.fractionDigits(of: value) <= MoneyPrecision.baseScale else {
            throw MoneyError.excessPrecision
        }
        guard value < Decimal(string: "100000000000000000000")! else { throw MoneyError.outOfRange }
        return value
    }

    private static func parseNumber(_ text: String,
                                    locale: Locale,
                                    allowNegative: Bool) throws -> Decimal {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty else { throw MoneyError.invalidSyntax }

        var isNegative = false
        if body.hasPrefix("-") {
            guard allowNegative else { throw MoneyError.outOfRange }
            isNegative = true
            body = body.dropFirst()
        }
        // A leading plus is not part of the accepted grammar.
        guard !body.isEmpty, !body.hasPrefix("+") else { throw MoneyError.invalidSyntax }

        let decimalSeparator = character(locale.decimalSeparator) ?? "."
        let groupingSeparators = groupingSet(for: locale)

        // 1. The locale's own interpretation always wins when it is valid.
        if let value = interpret(body,
                                 decimalSeparator: decimalSeparator,
                                 groupingSeparators: groupingSeparators) {
            return try finish(value, isNegative: isNegative)
        }

        // 2. Otherwise the other of `,`/`.` may be a decimal separator, but only
        //    because step 1 already proved it cannot be valid grouping here.
        let alternative: Character = decimalSeparator == "," ? "." : ","
        if body.filter({ $0 == alternative }).count == 1,
           let value = interpret(body,
                                 decimalSeparator: alternative,
                                 groupingSeparators: []) {
            return try finish(value, isNegative: isNegative)
        }

        throw MoneyError.invalidSyntax
    }

    /// Validates `intPart[decimalSeparator fracPart]` where `intPart` is either
    /// ungrouped digits or consistently grouped digits (1–3, then groups of 3).
    /// Returns nil when the text does not match — never a partial value.
    private static func interpret(_ body: Substring,
                                  decimalSeparator: Character,
                                  groupingSeparators: Set<Character>) -> Decimal? {
        let pieces = body.split(separator: decimalSeparator, omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }

        let integerText = String(pieces[0])
        let fractionText = pieces.count == 2 ? String(pieces[1]) : nil

        guard let integerDigits = ungroup(integerText, groupingSeparators: groupingSeparators) else {
            return nil
        }
        if let fractionText {
            // A fraction never carries grouping and never ends the string open.
            guard !fractionText.isEmpty, isASCIIDigits(fractionText) else { return nil }
            return MoneyCodec.isCanonicalCandidate(integerDigits + "." + fractionText)
        }
        return MoneyCodec.isCanonicalCandidate(integerDigits)
    }

    /// Removes valid grouping separators, or returns nil when grouping is
    /// malformed (`1,23,456`) or a separator appears where it cannot.
    private static func ungroup(_ text: String, groupingSeparators: Set<Character>) -> String? {
        guard !text.isEmpty else { return nil }
        if groupingSeparators.isEmpty || !text.contains(where: { groupingSeparators.contains($0) }) {
            return isASCIIDigits(text) ? text : nil
        }
        var groups: [String] = []
        var current = ""
        for character in text {
            if groupingSeparators.contains(character) {
                groups.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        groups.append(current)
        guard groups.count >= 2 else { return nil }
        guard let head = groups.first, (1...3).contains(head.count), isASCIIDigits(head) else {
            return nil
        }
        for group in groups.dropFirst() {
            guard group.count == 3, isASCIIDigits(group) else { return nil }
        }
        return groups.joined()
    }

    private static func finish(_ value: Decimal, isNegative: Bool) throws -> Decimal {
        guard !value.isNaN else { throw MoneyError.nonFinite }
        // Decimal normalizes -0 to 0, so a negated zero stays canonical zero.
        return isNegative ? -value : value
    }

    private static func character(_ text: String?) -> Character? {
        guard let text, text.count == 1 else { return nil }
        return text.first
    }

    private static func groupingSet(for locale: Locale) -> Set<Character> {
        guard let separator = character(locale.groupingSeparator) else { return [] }
        return spaceGrouping.contains(separator) ? spaceGrouping : [separator]
    }

    private static func isASCIIDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }
}

extension MoneyCodec {
    /// Decodes text this file has already reduced to canonical digits.
    /// Kept separate from `decode` so parser failures stay `nil` rather than
    /// throwing across the interpretation attempts.
    static func isCanonicalCandidate(_ digits: String) -> Decimal? {
        try? decode(digits)
    }
}
