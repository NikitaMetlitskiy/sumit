import Foundation

/// Locale-aware formatters. Split into two:
///   • `Formatters` — main-actor cache for user-language sensitive helpers (amount, date)
///   • `Formatters.iso` / `Formatters.date(fromISO:)` — `nonisolated` and callable from
///     any actor; used by Supabase serialization where the device locale is irrelevant.
@MainActor
enum Formatters {

    private static var cachedLocale: Locale = currentLocale()
    private static var cachedLanguage: String = LocalizationManager.shared.current.rawValue

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.groupingSeparator = " "
        return f
    }()

    // MARK: — Locale-aware (MainActor only — view layer)

    /// "1 234.56" / "1.234,56" depending on user language. Currency code appended as plain text.
    static func amount(_ value: Double, currency: String? = nil, fractionDigits: Int = 0) -> String {
        refreshIfNeeded()
        amountFormatter.locale = cachedLocale
        amountFormatter.minimumFractionDigits = fractionDigits
        amountFormatter.maximumFractionDigits = max(fractionDigits, isFiat(currency) ? 2 : 8)
        let n = amountFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
        if let cur = currency, !cur.isEmpty { return "\(n) \(cur)" }
        return n
    }

    /// Renders an **exact** stored amount for display: every significant digit
    /// the record holds, grouped for the current language, never rounded.
    ///
    /// `amount(_:fractionDigits:)` above takes a `Double` and a digit count, so
    /// it can only ever show an approximation of what is stored. Confirmation
    /// and receipt copy must show the number that will actually be saved.
    static func exactAmount(_ canonical: String, currency: String? = nil) -> String {
        refreshIfNeeded()
        let separator = cachedLocale.decimalSeparator ?? "."
        var parts = canonical.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = String(parts.first ?? "0")
        let isNegative = integer.hasPrefix("-")
        if isNegative { integer.removeFirst() }

        var grouped = ""
        for (offset, character) in integer.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(" ") }
            grouped.append(character)
        }
        var text = (isNegative ? "-" : "") + String(grouped.reversed())
        if parts.count > 1, !parts[1].isEmpty { text += separator + String(parts[1]) }
        if let currency, !currency.isEmpty { return "\(text) \(currency)" }
        return text
    }

    /// Convenience for a `Decimal` that is already exact.
    static func exactAmount(_ value: Decimal, currency: String? = nil) -> String {
        guard let canonical = try? MoneyCodec.encode(value) else { return "\(value)" }
        return exactAmount(canonical, currency: currency)
    }

    /// Short date in current app language.
    static func shortDate(_ date: Date) -> String {
        refreshIfNeeded()
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(cachedLocale))
    }

    /// Day-of-week or "d MMMM yyyy" for divider, current app language.
    static func dayDivider(_ date: Date) -> String {
        refreshIfNeeded()
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("today") }
        if cal.isDateInYesterday(date) { return L("yesterday") }
        let days = cal.dateComponents([.day], from: date, to: .now).day ?? 0
        let fmt = DateFormatter()
        fmt.locale = cachedLocale
        if days < 7 {
            fmt.dateFormat = "EEEE"
            return fmt.string(from: date).capitalized(with: cachedLocale)
        }
        fmt.dateFormat = "d MMMM yyyy"
        return fmt.string(from: date)
    }

    // MARK: — Helpers

    private static func currentLocale() -> Locale {
        Locale(identifier: LocalizationManager.shared.current.rawValue)
    }

    private static func refreshIfNeeded() {
        let lang = LocalizationManager.shared.current.rawValue
        guard lang != cachedLanguage else { return }
        cachedLanguage = lang
        cachedLocale = currentLocale()
    }

    private static func isFiat(_ currency: String?) -> Bool {
        guard let c = currency?.uppercased() else { return true }
        return !["BTC", "ETH"].contains(c)
    }
}

// MARK: — Exact amounts (no Double, no grouping) — see money-value.swift

extension Formatters {
    /// Text for an **editable** amount field. Carries full precision and no
    /// grouping, so opening an editor and saving it unchanged cannot alter the
    /// stored value. Display formatting (`amount(_:currency:fractionDigits:)`)
    /// rounds for readability and must never be used to seed an editor.
    ///
    /// `nonisolated` so ViewModels, actors and tests can call it without hopping
    /// to the main actor.
    nonisolated static func editAmount(_ value: Decimal, locale: Locale) throws -> String {
        try MoneyCodec.editString(value, locale: locale)
    }
}

// MARK: — ISO 8601 (callable from any actor — no user-locale dependence)

extension Formatters {
    /// Thread-safe shared ISO formatter for Supabase serialization.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    nonisolated static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    nonisolated static func date(fromISO string: String) -> Date? { isoFormatter.date(from: string) }
}
