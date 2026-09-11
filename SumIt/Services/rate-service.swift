import Foundation
import Combine
import SwiftData

// MARK: — Wire

nonisolated struct RateUnavailable: Decodable, Equatable, Sendable {
    let currency: String
    /// One of the server's documented reasons — or a newer one this build does
    /// not know. An unknown reason is still an unavailable state, never success.
    let reason: String
    let retryable: Bool
}

nonisolated struct RatesResponse: Decodable, Sendable {
    let quotes: [RateQuote]
    let unavailable: [RateUnavailable]
}

// MARK: — Policy

/// The client's copy of the automatic-use windows, for quotes read back from
/// the local cache while offline. The server applies the same numbers.
nonisolated enum RatePolicy {
    static let cryptoCurrencies: Set<String> = ["BTC", "ETH", "USDC", "USDT"]
    static let fiatAutomaticUse: TimeInterval = 96 * 3600
    static let cryptoAutomaticUse: TimeInterval = 15 * 60

    static func isStale(_ quote: RateQuote, now: Date) -> Bool {
        switch quote.valuationKind {
        case .identity, .manual, .historicalReference:
            return false
        case .currentReference:
            let window = cryptoCurrencies.contains(quote.currency) ? cryptoAutomaticUse : fiatAutomaticUse
            return now.timeIntervalSince(quote.effectiveAt) > window
        }
    }

    /// The day to ask a quote for. A record dated today (in the user's calendar)
    /// uses a current quote; any other day asks for that day's observation and
    /// never falls back to today's.
    static func requestDay(for occurredAt: Date, now: Date, calendar: Calendar = .current) -> String? {
        if calendar.isDate(occurredAt, inSameDayAs: now) { return nil }
        return isoDay(occurredAt, calendar: calendar)
    }

    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

// MARK: — Availability

nonisolated enum QuoteAvailability: Equatable, Sendable {
    /// USD: exactly 1, no request.
    case identity(RateQuote)
    /// A provider quote usable without asking.
    case fresh(RateQuote)
    /// A provider quote older than the automatic window. Usable only after the
    /// user explicitly confirms it.
    case stale(RateQuote)
    /// Nothing usable. The record can still be saved with a manual rate or
    /// without conversion.
    case unavailable(reason: String, retryable: Bool)

    var quote: RateQuote? {
        switch self {
        case .identity(let quote), .fresh(let quote), .stale(let quote): return quote
        case .unavailable: return nil
        }
    }
}

// MARK: — Service

/// Obtains dated quotes and keeps a local copy of what it has seen.
///
/// It never writes a transaction. A quote only becomes part of a record when
/// the user saves that record with it; a later refresh — or a provider's
/// correction of a historical observation — lands in the cache and nowhere else.
@MainActor
final class RateService: ObservableObject {

    typealias Fetch = (_ currencies: [String], _ date: String?) async throws -> Data

    private let cache: ModelContext
    private let fetch: Fetch
    private let now: () -> Date

    /// - Parameter container: the store the cache lives in. The service uses
    ///   its own context, so a cache write can never commit — or roll back —
    ///   someone else's pending ledger work.
    init(container: ModelContainer, fetch: @escaping Fetch, now: @escaping () -> Date = { Date() }) {
        self.cache = ModelContext(container)
        self.fetch = fetch
        self.now = now
    }

    func availability(currency: String, day: String?) async -> QuoteAvailability {
        let code = currency.uppercased()
        if code == "USD" { return .identity(.identity(at: now())) }

        let failure: (reason: String, retryable: Bool)
        do {
            let data = try await fetch([code], day)
            let response = try JSONDecoder().decode(RatesResponse.self, from: data)
            if let quote = response.quotes.first(where: { $0.currency == code }) {
                guard Self.matches(quote, day: day) else {
                    return cached(code, day: day) ?? .unavailable(reason: "invalid_quote", retryable: false)
                }
                remember(quote)
                return quote.isStale || RatePolicy.isStale(quote, now: now()) ? .stale(quote) : .fresh(quote)
            }
            let entry = response.unavailable.first { $0.currency == code }
            failure = (entry?.reason ?? "missing_currency", entry?.retryable ?? false)
        } catch BackendError.notSignedIn {
            failure = ("not_signed_in", false)
        } catch BackendError.serverError {
            failure = ("service_unavailable", true)
        } catch is DecodingError {
            failure = ("invalid_quote", false)
        } catch {
            failure = ("offline", true)
        }
        return cached(code, day: day) ?? .unavailable(reason: failure.reason, retryable: failure.retryable)
    }

    /// A server answer has to be the kind of quote that was asked for: a
    /// current request gets a current quote, a dated one that day's.
    private static func matches(_ quote: RateQuote, day: String?) -> Bool {
        guard quote.id != nil else { return false }
        if let day {
            return quote.valuationKind == .historicalReference && quote.requestedDate == day
        }
        return quote.valuationKind == .currentReference && quote.requestedDate == nil
    }

    // MARK: — Local cache

    /// The newest cached quote for exactly this key. A historical day only ever
    /// matches that day; a current quote is re-checked against the window.
    func cached(_ currency: String, day: String?) -> QuoteAvailability? {
        let code = currency.uppercased()
        let kind = (day == nil ? ValuationKind.currentReference : .historicalReference).rawValue
        var descriptor = FetchDescriptor<CachedRateQuote>(
            predicate: #Predicate { $0.currency == code && $0.valuationKindRaw == kind && $0.requestedDate == day },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let row = try? cache.fetch(descriptor).first, let quote = row.rateQuote(now: now()) else {
            return nil
        }
        return quote.isStale ? .stale(quote) : .fresh(quote)
    }

    private func remember(_ quote: RateQuote) {
        guard let id = quote.id else { return }
        let existing = (try? cache.fetchCount(FetchDescriptor<CachedRateQuote>(
            predicate: #Predicate { $0.quoteID == id }))) ?? 0
        guard existing == 0 else { return }
        cache.insert(CachedRateQuote(quoteID: id, currency: quote.currency,
                                     usdPerUnitExact: quote.usdPerUnit,
                                     requestedDate: quote.requestedDate,
                                     effectiveAt: quote.effectiveAt, fetchedAt: quote.fetchedAt,
                                     source: quote.source, valuationKind: quote.valuationKind,
                                     sourceDetailJSON: try? JSONEncoder().encode(quote.sourceDetail)))
        do { try cache.save() } catch {
            // Losing a cache row costs an offline fallback, nothing more.
            cache.rollback()
        }
    }
}

extension CachedRateQuote {
    /// The cached row as a quote, with staleness evaluated at `now`. `nil` if
    /// the stored rate is not canonical — a damaged row is not served.
    func rateQuote(now: Date) -> RateQuote? {
        guard (try? MoneyCodec.decode(usdPerUnitExact)) != nil else { return nil }
        var quote = RateQuote(id: quoteID, currency: currency, usdPerUnit: usdPerUnitExact,
                              requestedDate: requestedDate, effectiveAt: effectiveAt, fetchedAt: fetchedAt,
                              source: source,
                              sourceDetail: sourceDetailJSON.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                                  ?? .object([:]),
                              valuationKind: valuationKind, isStale: false)
        quote.isStale = RatePolicy.isStale(quote, now: now)
        return quote
    }
}

// MARK: — Manual rate

nonisolated enum ManualRate {

    /// A rate the user typed, as a `manual` quote — or the reason it cannot be.
    ///
    /// Positive, at most 18 fractional digits, within `numeric(38,18)`, and the
    /// booked product must not round to zero at the ledger's scale (VAL-11): a
    /// positive amount silently booked as 0 USD is exactly the invented number
    /// this whole path exists to avoid.
    static func quote(text: String, currency: String, amount: Decimal?, occurredAt: Date,
                      now: Date = .now, locale: Locale = AppLocale.current) -> Result<RateQuote, TransactionEditorProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rate = try? AmountParser.parseRate(trimmed, locale: locale) else {
            return .failure(.form("invalid_rate"))
        }
        guard let canonical = try? MoneyCodec.encode(rate) else { return .failure(.form("invalid_rate")) }
        if let amount {
            guard let base = try? MoneyCodec.quantize(amount * rate, scale: MoneyPrecision.baseScale), base > 0 else {
                return .failure(.form("base_amount_rounds_to_zero"))
            }
            guard base <= MoneyCodec.maxBaseAmount else { return .failure(.form("amount_out_of_range")) }
        }
        return .success(RateQuote(id: nil, currency: currency.uppercased(), usdPerUnit: canonical,
                                  requestedDate: RatePolicy.isoDay(occurredAt),
                                  effectiveAt: occurredAt, fetchedAt: now,
                                  source: "manual",
                                  sourceDetail: .object(["confirmed_by_user": .bool(true)]),
                                  valuationKind: .manual, isStale: false))
    }
}

// MARK: — Wording

@MainActor
enum QuoteText {
    static func sourceName(_ source: String) -> String {
        switch source {
        case "frankfurter": return "Frankfurter"
        case "coingecko":   return "CoinGecko"
        case "manual":      return L("valuation_source_manual")
        case "identity":    return "USD"
        default:            return source
        }
    }

    /// "1 EUR = 1.162 USD · Frankfurter · 11 Sep 2026". The rate is shown with
    /// every digit it was booked with.
    static func line(_ quote: RateQuote) -> String {
        "1 \(quote.currency) = \(Formatters.exactAmount(quote.usdPerUnit)) USD · "
            + "\(sourceName(quote.source)) · \(Formatters.shortDate(quote.effectiveAt))"
    }

    /// A reason code as a sentence. A reason this build does not know is still
    /// shown as unavailable, never as success.
    static func reason(_ code: String) -> String {
        let key = "rate_reason_\(code)"
        let text = L(key)
        return text == key ? L("rate_reason_unknown") : text
    }
}
