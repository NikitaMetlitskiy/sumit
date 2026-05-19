import Foundation

/// Stateless utility — all methods marked `nonisolated` so they can be called from
/// actors and the main actor without crossing isolation boundaries
/// (matters under Swift 6's default-MainActor isolation).
struct CurrencyService {
    /// 1 USD = X foreign. Stablecoins pinned to 1; crypto rates are placeholders
    /// — see `LiveRateLoader` (TODO) for daily refresh from a server endpoint.
    /// Marked `nonisolated` so actors (BackendService.isSupported check) can read it.
    nonisolated static let rates: [String: Double] = [
        "USD":  1.0,
        "EUR":  0.922,
        "UAH":  41.5,
        "GBP":  0.786,
        "PLN":  4.08,
        "CZK":  23.2,
        "CAD":  1.36,
        "CHF":  0.90,
        "RUB":  92.0,
        "KZT":  475.0,
        "JPY":  155.0,
        "USDC": 1.0,
        "USDT": 1.0,
        "BTC":  0.0000095,   // ~$105,000 / BTC placeholder
        "ETH":  0.00028      // ~$3,500 / ETH placeholder
    ]

    /// Returns true if currency is known. Callers should reject saves with unknown currencies.
    nonisolated static func isSupported(_ currency: String) -> Bool {
        rates[currency.uppercased()] != nil
    }

    nonisolated static func toUSD(_ currency: String) -> Double {
        guard let r = rates[currency.uppercased()], r != 0 else { return 1.0 }
        return 1.0 / r
    }

    nonisolated static func usdTo(_ currency: String) -> Double {
        rates[currency.uppercased()] ?? 1.0
    }

    nonisolated static func convert(_ amount: Double, from: String, to: String) -> Double {
        amount * toUSD(from) * usdTo(to)
    }

    /// Localized currency rows for pickers. Stays MainActor because it calls `L(_:)` —
    /// which is fine since pickers always run on the main thread.
    @MainActor
    static var supported: [(code: String, name: String, flag: String)] { [
        ("USD",  L("cur_usd"),  "🇺🇸"),
        ("EUR",  L("cur_eur"),  "🇪🇺"),
        ("UAH",  L("cur_uah"),  "🇺🇦"),
        ("GBP",  L("cur_gbp"),  "🇬🇧"),
        ("PLN",  L("cur_pln"),  "🇵🇱"),
        ("CZK",  L("cur_czk"),  "🇨🇿"),
        ("CAD",  L("cur_cad"),  "🇨🇦"),
        ("CHF",  L("cur_chf"),  "🇨🇭"),
        ("RUB",  L("cur_rub"),  "🇷🇺"),
        ("KZT",  L("cur_kzt"),  "🇰🇿"),
        ("JPY",  L("cur_jpy"),  "🇯🇵"),
        ("USDC", L("cur_usdc"), "🟦"),
        ("USDT", L("cur_usdt"), "🟢"),
        ("BTC",  L("cur_btc"),  "🟠"),
        ("ETH",  L("cur_eth"),  "🟣")
    ] }
}
