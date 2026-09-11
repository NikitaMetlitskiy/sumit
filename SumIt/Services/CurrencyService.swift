import Foundation

/// Stateless utility — all methods marked `nonisolated` so they can be called from
/// actors and the main actor without crossing isolation boundaries
/// (matters under Swift 6's default-MainActor isolation).
struct CurrencyService {
    /// Whether the app records amounts in this currency. This is metadata
    /// only — it says nothing about whether a rate is available. There is no
    /// rate table here any more: the old one priced BTC at a hard-coded
    /// $105,000, pinned stablecoins to exactly 1 and answered 1.0 for anything
    /// it did not know. Rates now come only from dated quotes.
    nonisolated static func isSupported(_ currency: String) -> Bool {
        MoneyPrecision.isSupported(currency)
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
