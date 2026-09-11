import XCTest
@testable import SumIt

/// REPORT group. Totals are exact, and what they leave out is counted.
@MainActor
final class ReportValuationTests: XCTestCase {

    private let day = LedgerIDs.eventTime
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(_ type: TransactionType, _ amount: String, _ currency: String = "EUR",
                       usd: String?, state: ReportValuationState = .valued,
                       category: String = "Food", at date: Date? = nil) -> ReportEntry {
        ReportEntry(id: UUID(), type: type, occurredAt: date ?? day, categoryName: category,
                    currency: currency, nativeAmount: Decimal(string: amount)!,
                    bookedUSD: usd.map { Decimal(string: $0)! },
                    state: usd == nil ? .unconverted : state)
    }

    // MARK: — REPORT-01

    func testMixedValuedAndUnvaluedTotalsSayWhatIsMissing() {
        let summary = ReportSummary.make(entries: [
            entry(.expense, "10", usd: "10.8"),
            entry(.expense, "5", usd: nil),
            entry(.expense, "3", "USD", usd: "3", state: .legacyUnverified),
        ], calendar: utc)

        XCTAssertEqual(summary.expenseUSD, Decimal(string: "13.8"))
        XCTAssertEqual(summary.unconvertedCount, 1)
        XCTAssertEqual(summary.legacyUnverifiedCount, 1)
        XCTAssertFalse(summary.isComplete, "a partial total is never presented as complete")
        XCTAssertEqual(summary.nativeExpense["EUR"], 15, "the unconverted record is still in its own currency's total")
        XCTAssertEqual(summary.nativeExpense["USD"], 3)
    }

    // MARK: — REPORT-02

    func testSwitchingDisplayCurrencyNeverChangesBookedUSD() {
        let summary = ReportSummary.make(entries: [entry(.expense, "10", usd: "10")], calendar: utc)
        let eur = DisplayConversion(currency: "EUR", quote: RateQuote(
            id: UUID(), currency: "EUR", usdPerUnit: "1.25", requestedDate: nil, effectiveAt: day,
            fetchedAt: day, source: "frankfurter", sourceDetail: .object([:]),
            valuationKind: .currentReference, isStale: false))

        XCTAssertEqual(eur.convert(summary.expenseUSD), 8)
        XCTAssertEqual(DisplayConversion.usd(at: day).convert(summary.expenseUSD), 10)
        XCTAssertEqual(summary.expenseUSD, 10, "the booked value is untouched by display")

        let missing = DisplayConversion(currency: "EUR", quote: nil)
        XCTAssertNil(missing.convert(10), "no quote, no invented display value")
    }

    func testDisplayConversionRoundsToTheDisplayCurrencysScale() {
        let jpy = DisplayConversion(currency: "JPY", quote: RateQuote(
            id: UUID(), currency: "JPY", usdPerUnit: "0.00648971", requestedDate: nil, effectiveAt: day,
            fetchedAt: day, source: "frankfurter", sourceDetail: .object([:]),
            valuationKind: .currentReference, isStale: false))
        let yen = jpy.convert(Decimal(string: "10")!)
        XCTAssertEqual(yen.map { MoneyCodec.fractionDigits(of: $0) }, 0)
        XCTAssertEqual(yen, 1541)
    }

    // MARK: — REPORT-03

    func testATransferIsNeitherIncomeNorExpenseAndCountsOnce() {
        let summary = ReportSummary.make(entries: [
            entry(.transfer, "100", usd: "108"),
            entry(.income, "50", usd: "54"),
        ], calendar: utc)
        XCTAssertEqual(summary.expenseUSD, 0)
        XCTAssertEqual(summary.incomeUSD, 54)
        XCTAssertEqual(summary.entryCount, 2)
        XCTAssertEqual(summary.transferCount, 1)
        XCTAssertTrue(summary.isComplete)
        XCTAssertNil(summary.nativeExpense["EUR"])
    }

    // MARK: — REPORT-04

    func testANegativePeriodShowsItsSign() {
        let summary = ReportSummary.make(entries: [
            entry(.income, "10", usd: "10"),
            entry(.expense, "25.5", usd: "25.5"),
        ], calendar: utc)
        XCTAssertEqual(summary.netUSD, Decimal(string: "-15.5"))
        XCTAssertTrue(Formatters.exactAmount(summary.netUSD, currency: "USD").hasPrefix("-"),
                      "the sign is in the text, not only in the colour")
    }

    // MARK: — REPORT-05 and exactness

    func testMoreThanAThousandRecordsAreAllCountedExactly() {
        let entries = (0..<1_250).map { _ in entry(.expense, "0.01", "USD", usd: "0.01") }
        let summary = ReportSummary.make(entries: entries, calendar: utc)
        XCTAssertEqual(summary.entryCount, 1_250)
        XCTAssertEqual(summary.expenseUSD, Decimal(string: "12.5"), "Double would drift here; Decimal does not")
    }

    func testAggregationIsDecimalNotDouble() {
        let summary = ReportSummary.make(entries: [
            entry(.expense, "0.1", "USD", usd: "0.1"),
            entry(.expense, "0.2", "USD", usd: "0.2"),
        ], calendar: utc)
        XCTAssertEqual(summary.expenseUSD, Decimal(string: "0.3"))
        XCTAssertEqual(summary.dailyExpense.count, 1)
        XCTAssertEqual(summary.dailyExpense.first?.usd, Decimal(string: "0.3"))
        XCTAssertEqual(DisplayConversion.chartValue(summary.dailyExpense[0].usd), 0.3, accuracy: 1e-12,
                       "Double appears only as a chart coordinate, after aggregation")
    }

    func testCategoriesAreOrderedByBookedAmount() {
        let summary = ReportSummary.make(entries: [
            entry(.expense, "1", usd: "1", category: "Taxi"),
            entry(.expense, "9", usd: "9", category: "Food"),
            entry(.expense, "2", usd: "2", category: "Taxi"),
        ], calendar: utc)
        XCTAssertEqual(summary.expenseByCategory, [CategoryTotal(name: "Food", usd: 9), CategoryTotal(name: "Taxi", usd: 3)])
    }

    // MARK: — Reading stored rows

    func testALegacyRowIsReportedWithItsOriginalNumbersAndLabelled() {
        let legacy = Transaction(userId: "local", originalAmount: 12.5, originalCurrency: "eur",
                                 amountInBase: 13.55, rateAtTime: 1.084, categoryName: "Food", merchant: "Old")
        let item = legacy.reportEntry
        XCTAssertEqual(item?.state, .legacyUnverified)
        XCTAssertEqual(item?.nativeAmount, Decimal(string: "12.5"))
        XCTAssertEqual(item?.bookedUSD, Decimal(string: "13.55"))
        XCTAssertEqual(item?.currency, "EUR")
    }

    func testAnUnreadableRowIsCountedNotHidden() {
        let broken = Transaction(userId: "local", originalAmount: .nan, originalCurrency: "EUR",
                                 amountInBase: .nan, rateAtTime: 1, categoryName: "Food", merchant: "?")
        XCTAssertNil(broken.reportEntry)
        let summary = ReportSummary.make([broken], calendar: utc)
        XCTAssertEqual(summary.unreadableCount, 1)
        XCTAssertFalse(summary.isComplete)
    }
}
