import Foundation

/// Locale-aware formatters cached on first use. Locale is rebuilt when the user
/// changes language in-app, so "1 234,56" vs "1,234.56" follows the chosen language.
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

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    // MARK: — Public

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

    /// ISO8601 for Supabase POSTs.
    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Parse ISO8601.
    static func date(fromISO string: String) -> Date? { isoFormatter.date(from: string) }

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
