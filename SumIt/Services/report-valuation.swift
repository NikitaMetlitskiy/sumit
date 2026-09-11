import Foundation

// MARK: — One record, as a report sees it

/// How a record contributes to USD totals.
enum ReportValuationState: Equatable, Sendable {
    /// Booked with a dated quote (provider, identity or manual). Counted.
    case valued
    /// Converted with the app's old built-in table before the ledger existed.
    /// Counted with its original stored numbers, and labelled as unverified.
    case legacyUnverified
    /// No USD value. Not in USD totals, and counted so the gap is visible.
    case unconverted
}

struct ReportEntry: Equatable, Sendable {
    let id: UUID
    let type: TransactionType
    let occurredAt: Date
    let categoryName: String
    let currency: String
    let nativeAmount: Decimal
    let bookedUSD: Decimal?
    let state: ReportValuationState
}

extension Transaction {

    /// The record for reporting, read from exact fields.
    ///
    /// A row written before the ledger has no exact amount. Its stored Double
    /// mirrors are read through their shortest decimal description and marked
    /// `legacyUnverified` — they are the numbers the user has always seen, not
    /// silently corrected and not silently dropped. `nil` only when even that
    /// cannot be read; the summary counts those rather than hiding them.
    var reportEntry: ReportEntry? {
        if let draft = draftForCalculation {
            let base = baseAmountExact.flatMap { try? MoneyCodec.decode($0) }
            let state: ReportValuationState
            switch draft.valuation {
            case .quoted:           state = base == nil ? .unconverted : .valued
            case .legacyUnverified: state = base == nil ? .unconverted : .legacyUnverified
            case .unvalued:         state = .unconverted
            }
            return ReportEntry(id: id, type: draft.type, occurredAt: draft.occurredAt,
                               categoryName: draft.categoryName, currency: draft.currency,
                               nativeAmount: draft.amount,
                               bookedUSD: state == .unconverted ? nil : base,
                               state: state)
        }

        guard originalAmount.isFinite, originalAmount > 0,
              let native = try? MoneyCodec.decode(String(originalAmount)) else { return nil }
        let base: Decimal? = (amountInBase.isFinite && amountInBase > 0)
            ? (try? MoneyCodec.decode(String(amountInBase))) : nil
        return ReportEntry(id: id, type: type, occurredAt: occurredAt, categoryName: categoryName,
                           currency: originalCurrency.uppercased(), nativeAmount: native,
                           bookedUSD: base, state: base == nil ? .unconverted : .legacyUnverified)
    }
}

// MARK: — The summary

struct CategoryTotal: Equatable, Sendable {
    let name: String
    let usd: Decimal
}

struct DayTotal: Equatable, Sendable {
    let day: Date
    let usd: Decimal
}

/// Period totals, aggregated in `Decimal`.
///
/// The old reports summed `amountInBase` as `Double`, which silently counted
/// every placeholder conversion as if it were real and could not say what was
/// missing. Here a record without a USD value stays out of the USD total and is
/// counted, so a partial total is never presented as a complete one. A transfer
/// is neither income nor expense and is counted once.
struct ReportSummary: Equatable, Sendable {
    var expenseUSD: Decimal = 0
    var incomeUSD: Decimal = 0
    var netUSD: Decimal { incomeUSD - expenseUSD }

    /// Every record once, transfers included.
    var entryCount = 0
    var transferCount = 0
    /// Income or expense with no USD value: excluded from USD totals.
    var unconvertedCount = 0
    /// Included in USD totals, converted with an unverified legacy rate.
    var legacyUnverifiedCount = 0
    /// Records that could not be read at all.
    var unreadableCount = 0

    var nativeExpense: [String: Decimal] = [:]
    var nativeIncome: [String: Decimal] = [:]
    var expenseByCategory: [CategoryTotal] = []
    var dailyExpense: [DayTotal] = []

    /// True only when every income and expense record is in the USD totals.
    var isComplete: Bool { unconvertedCount == 0 && unreadableCount == 0 }

    static func make(_ transactions: [Transaction], calendar: Calendar = .current) -> ReportSummary {
        make(entries: transactions.map(\.reportEntry), calendar: calendar)
    }

    static func make(entries: [ReportEntry?], calendar: Calendar = .current) -> ReportSummary {
        var summary = ReportSummary()
        var categories: [String: Decimal] = [:]
        var days: [Date: Decimal] = [:]

        for candidate in entries {
            summary.entryCount += 1
            guard let entry = candidate else {
                summary.unreadableCount += 1
                continue
            }
            switch entry.type {
            case .transfer:
                summary.transferCount += 1
                continue
            case .expense:
                summary.nativeExpense[entry.currency, default: 0] += entry.nativeAmount
            case .income:
                summary.nativeIncome[entry.currency, default: 0] += entry.nativeAmount
            }

            guard let usd = entry.bookedUSD else {
                summary.unconvertedCount += 1
                continue
            }
            if entry.state == .legacyUnverified { summary.legacyUnverifiedCount += 1 }

            if entry.type == .expense {
                summary.expenseUSD += usd
                categories[entry.categoryName, default: 0] += usd
                days[calendar.startOfDay(for: entry.occurredAt), default: 0] += usd
            } else {
                summary.incomeUSD += usd
            }
        }

        summary.expenseByCategory = categories
            .map { CategoryTotal(name: $0.key, usd: $0.value) }
            .sorted { $0.usd == $1.usd ? $0.name < $1.name : $0.usd > $1.usd }
        summary.dailyExpense = days
            .map { DayTotal(day: $0.key, usd: $0.value) }
            .sorted { $0.day < $1.day }
        return summary
    }
}

// MARK: — Showing a USD total in another currency

/// Converts a booked USD total into the display currency for **display only**.
///
/// The booked value stays in USD. This uses a separately obtained *current*
/// quote and is labelled as such, so switching display currency never changes a
/// historical income or expense figure, and market movement never rewrites one.
struct DisplayConversion: Equatable, Sendable {
    let currency: String
    /// USD per one unit of `currency`, or `nil` when no quote is available.
    let quote: RateQuote?

    static func usd(at date: Date = .now) -> DisplayConversion {
        DisplayConversion(currency: "USD", quote: .identity(at: date))
    }

    var isAvailable: Bool { quote != nil }

    /// `usd / usdPerUnit`, half-even to the display currency's entry scale.
    func convert(_ usd: Decimal) -> Decimal? {
        guard let quote, let rate = try? MoneyCodec.decode(quote.usdPerUnit), rate > 0 else { return nil }
        let scale = (try? MoneyPrecision.scale(for: currency)) ?? 2
        return try? MoneyCodec.quantize(usd / rate, scale: scale)
    }

    /// Chart coordinates only — after aggregation, never for a stored value.
    static func chartValue(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
