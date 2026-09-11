import XCTest
import SwiftData
@testable import SumIt

/// VAL group and the rate service. A booked valuation changes only when the
/// user decides it should; nothing is looked up, assumed or refreshed into a
/// saved record.
@MainActor
final class ValuationTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var ledger: LedgerStore!

    private let owner = AccountScope.localOwnerID
    private var scope: AccountScope { AccountScope(ownerID: owner, epoch: UUID()) }
    private let quoteID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        context = ModelContext(fixture.container)
        ledger = LedgerStore(context: context)
    }

    override func tearDownWithError() throws {
        ledger = nil; context = nil
        try fixture?.destroy()
        fixture = nil
    }

    // MARK: — Helpers

    private func eurQuote(_ rate: String = "1.08", id: UUID? = nil, day: String? = "2026-05-19",
                          stale: Bool = false, effectiveAt: Date = LedgerIDs.eventTime) -> RateQuote {
        RateQuote(id: id ?? quoteID, currency: "EUR", usdPerUnit: rate, requestedDate: day,
                  effectiveAt: effectiveAt, fetchedAt: effectiveAt, source: "frankfurter",
                  sourceDetail: .object([:]),
                  valuationKind: day == nil ? .currentReference : .historicalReference, isStale: stale)
    }

    @discardableResult
    private func save(amount: String = "10", currency: String = "EUR",
                      valuation: LedgerValuation, merchant: String = "Cafe") throws -> Transaction {
        let draft = TransactionDraft(id: LedgerIDs.expense, type: .expense,
                                     amount: try MoneyCodec.decode(amount), currency: currency,
                                     walletID: nil, walletAmount: nil,
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: merchant, note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "", valuation: valuation)
        try ledger.saveTransaction(draft, scope: scope)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
    }

    private func draft(_ fields: TransactionEditorFields, previous: Transaction?) -> Result<TransactionDraft, TransactionEditorProblem> {
        TransactionEditor.draft(from: fields, id: LedgerIDs.expense, wallets: [], ownerID: owner,
                                previous: previous, now: LedgerIDs.eventTime)
    }

    private func edit(_ fields: TransactionEditorFields, previous: Transaction) throws -> Transaction {
        guard case .success(let value) = draft(fields, previous: previous) else {
            XCTFail("expected a valid draft"); return previous
        }
        try ledger.editTransaction(value, scope: scope)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
    }

    // MARK: — VAL-01: booked with provenance

    func testSavingWithAQuoteBooksTheExactProductAndKeepsProvenance() throws {
        let row = try save(valuation: .quoted(eurQuote()))

        XCTAssertEqual(row.baseAmountExact, "10.8")
        XCTAssertEqual(row.rateExact, "1.08")
        XCTAssertEqual(row.valuationState, .valued)
        let stored = try JSONDecoder().decode(RateQuote.self, from: try XCTUnwrap(row.quoteJSON))
        XCTAssertEqual(stored.id, quoteID)
        XCTAssertEqual(stored.source, "frankfurter")

        let payload = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingMutation>()).first?.desiredSnapshotJSON)
        let record = try JSONDecoder().decode(TransactionRecordV1.self, from: payload)
        XCTAssertEqual(record.quote?.id, quoteID, "the provenance travels with the mutation")
        XCTAssertEqual(record.baseAmount, "10.8")
    }

    /// The mutation must carry what the server requires for a valued record.
    /// This was a hard-coded nil, which the RPC refuses as
    /// `valued_requires_base_rate_quote` — every USD entry included.
    func testEveryQueuedMutationCarriesItsBookedBaseAndRate() throws {
        func payload() throws -> TransactionRecordV1 {
            let mutation = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingMutation>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])).first)
            return try JSONDecoder().decode(TransactionRecordV1.self, from: try XCTUnwrap(mutation.desiredSnapshotJSON))
        }

        let usd = try save(amount: "12.5", currency: "USD", valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
        let identity = try payload()
        XCTAssertEqual(identity.baseAmount, "12.5")
        XCTAssertEqual(identity.usdPerUnit, "1")
        XCTAssertEqual(identity.valuationState, .valued)
        XCTAssertEqual(identity.baseAmount, usd.baseAmountExact, "what is queued is what is stored")

    }

    func testALegacyMutationCarriesItsOriginalNumbers() throws {
        try save(valuation: .legacyUnverified(baseAmount: try MoneyCodec.decode("10.84"),
                                              rate: try MoneyCodec.decode("1.084")))
        let mutation = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingMutation>()).first)
        let record = try JSONDecoder().decode(TransactionRecordV1.self, from: try XCTUnwrap(mutation.desiredSnapshotJSON))
        XCTAssertEqual(record.baseAmount, "10.84")
        XCTAssertEqual(record.usdPerUnit, "1.084")
        XCTAssertNil(record.quote)
        XCTAssertEqual(record.valuationState, .legacyUnverified)
    }

    // MARK: — VAL-02 / VAL-03

    func testAMetadataEditKeepsTheBookedValuation() throws {
        let row = try save(valuation: .quoted(eurQuote()))
        var fields = TransactionEditor.fields(from: row)
        fields.merchant = "Another cafe"

        let edited = try edit(fields, previous: row)
        XCTAssertEqual(edited.baseAmountExact, "10.8")
        XCTAssertEqual(edited.rateExact, "1.08")
    }

    func testAnAmountEditReusesTheConfirmedQuote() throws {
        let row = try save(valuation: .quoted(eurQuote()))
        var fields = TransactionEditor.fields(from: row)
        fields.amountText = "12"

        let edited = try edit(fields, previous: row)
        XCTAssertEqual(edited.baseAmountExact, "12.96", "12 × 1.08, same quote")
        XCTAssertEqual(try JSONDecoder().decode(RateQuote.self, from: try XCTUnwrap(edited.quoteJSON)).id, quoteID)
    }

    // MARK: — VAL-04: a changed date or currency needs a decision

    func testChangingTheDateOrCurrencyRequiresAnExplicitDecision() throws {
        let row = try save(valuation: .quoted(eurQuote()))

        var dated = TransactionEditor.fields(from: row)
        dated.occurredAt = LedgerIDs.eventTime.addingTimeInterval(-3 * 86_400)
        guard case .failure(let problem) = draft(dated, previous: row) else { return XCTFail("needs a decision") }
        XCTAssertEqual(problem.code, "valuation_decision_required")

        dated.valuation = .keepExisting
        guard case .success(let kept) = draft(dated, previous: row) else { return XCTFail("keep is a decision") }
        XCTAssertEqual(kept.valuation, .quoted(eurQuote()))

        var recurrency = TransactionEditor.fields(from: row)
        recurrency.currency = "GBP"
        guard case .failure(let noSilentRate) = draft(recurrency, previous: row) else { return XCTFail() }
        XCTAssertEqual(noSilentRate.code, "valuation_decision_required")
        recurrency.valuation = .keepExisting
        guard case .failure = draft(recurrency, previous: row) else {
            return XCTFail("a EUR rate cannot be kept for a GBP amount")
        }
        recurrency.valuation = .unvalued
        guard case .success(let unvalued) = draft(recurrency, previous: row) else { return XCTFail() }
        XCTAssertEqual(unvalued.valuation, .unvalued)
    }

    // MARK: — VAL-05 / VAL-07

    func testANewForeignEntryWithoutAChoiceIsSavedWithoutConversionNotAtAGuessedRate() throws {
        var fields = TransactionEditor.fields(from: try save(currency: "USD", valuation: .quoted(.identity(at: LedgerIDs.eventTime))))
        fields.currency = "EUR"
        guard case .success(let usdToEur) = TransactionEditor.draft(from: fields, id: UUID(), wallets: [],
                                                                    ownerID: owner) else { return XCTFail() }
        XCTAssertEqual(usdToEur.valuation, .unvalued, "a new record: no rate is assumed")

        XCTAssertEqual(ParsedTransactionDraft.defaultValuation(currency: "EUR", at: LedgerIDs.eventTime), .unvalued)
        XCTAssertEqual(ParsedTransactionDraft.defaultValuation(currency: "usd", at: LedgerIDs.eventTime),
                       .quoted(.identity(at: LedgerIDs.eventTime)))
    }

    func testSavingWithoutARateKeepsTheAmountAndBooksNothing() throws {
        let row = try save(valuation: .unvalued)
        XCTAssertEqual(row.amountExact, "10")
        XCTAssertNil(row.baseAmountExact, "not zero — absent")
        XCTAssertEqual(row.valuationState, .unvalued)
    }

    func testFillingInAValuationLaterIsAVersionedEdit() throws {
        let row = try save(valuation: .unvalued)
        var fields = TransactionEditor.fields(from: row)
        fields.valuation = .manual("1.08")

        let edited = try edit(fields, previous: row)
        XCTAssertEqual(edited.baseAmountExact, "10.8")
        XCTAssertEqual(edited.localGeneration, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutation>()), 2)
        let quote = try JSONDecoder().decode(RateQuote.self, from: try XCTUnwrap(edited.quoteJSON))
        XCTAssertEqual(quote.valuationKind, .manual)
        XCTAssertNil(quote.id, "a manual rate has no provider identity")
        XCTAssertEqual(quote.source, "manual")
    }

    // MARK: — VAL-09: legacy numbers are kept, not corrected

    func testLegacyValuationIsKeptUntouchedAndCannotBeSilentlyReused() throws {
        let row = try save(valuation: .legacyUnverified(baseAmount: try MoneyCodec.decode("10.84"),
                                                        rate: try MoneyCodec.decode("1.084")))
        var fields = TransactionEditor.fields(from: row)
        fields.note = "checked"
        let kept = try edit(fields, previous: row)
        XCTAssertEqual(kept.baseAmountExact, "10.84")
        XCTAssertEqual(kept.valuationState, .legacyUnverified)

        var changed = TransactionEditor.fields(from: kept)
        changed.amountText = "20"
        guard case .failure(let problem) = draft(changed, previous: kept) else {
            return XCTFail("an unverified base cannot be scaled to a new amount")
        }
        XCTAssertEqual(problem.code, "valuation_decision_required")
    }

    // MARK: — Manual rates and VAL-11

    func testManualRatesAreValidated() {
        let at = LedgerIDs.eventTime
        func code(_ text: String, amount: String = "10") -> String? {
            switch ManualRate.quote(text: text, currency: "EUR", amount: try? MoneyCodec.decode(amount),
                                    occurredAt: at, now: at, locale: Locale(identifier: "en_US")) {
            case .success: return nil
            case .failure(let problem): return problem.code
            }
        }
        XCTAssertNil(code("1.08"))
        XCTAssertEqual(code("0"), "invalid_rate")
        XCTAssertEqual(code("-1.08"), "invalid_rate")
        XCTAssertEqual(code("abc"), "invalid_rate")
        XCTAssertEqual(code("1e3"), "invalid_rate")
        XCTAssertEqual(code(""), "invalid_rate")
        XCTAssertEqual(code("1.0000000000000000001"), "invalid_rate", "19 fractional digits")

        guard case .success(let russian) = ManualRate.quote(text: "1,08", currency: "EUR", amount: 10,
                                                            occurredAt: at, now: at,
                                                            locale: Locale(identifier: "ru")) else {
            return XCTFail("the app locale's decimal comma is a rate too")
        }
        XCTAssertEqual(russian.usdPerUnit, "1.08")
    }

    func testARateThatBooksZeroIsRefusedNotBookedAsZero() {
        let result = ManualRate.quote(text: "0.1", currency: "ETH",
                                      amount: Decimal(string: "0.000000000000000001"),
                                      occurredAt: LedgerIDs.eventTime, now: LedgerIDs.eventTime,
                                      locale: Locale(identifier: "en_US"))
        guard case .failure(let problem) = result else { return XCTFail("1e-19 USD rounds to zero at scale 18") }
        XCTAssertEqual(problem.code, "base_amount_rounds_to_zero")
    }

    // MARK: — Rate service

    private func response(quotes: [RateQuote], unavailable: [[String: Any]] = []) throws -> Data {
        let encoded = try quotes.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return try JSONSerialization.data(withJSONObject: ["quotes": encoded, "unavailable": unavailable])
    }

    func testUSDNeverAsksTheServer() async {
        var calls = 0
        let service = RateService(container: fixture.container, fetch: { _, _ in calls += 1; return Data() })
        let result = await service.availability(currency: "usd", day: nil)
        guard case .identity(let quote) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(quote.usdPerUnit, "1")
        XCTAssertEqual(calls, 0)
    }

    func testAFreshQuoteIsCachedAndServedOfflineWithinItsWindow() async throws {
        let now = LedgerIDs.eventTime
        let current = eurQuote(day: nil, effectiveAt: now)
        let body = try response(quotes: [current])
        var online = true
        let clock = { now.addingTimeInterval(3600) }
        let service = RateService(container: fixture.container, fetch: { _, _ in
            if online { return body }
            throw URLError(.notConnectedToInternet)
        }, now: clock)

        guard case .fresh = await service.availability(currency: "EUR", day: nil) else { return XCTFail() }
        online = false
        guard case .fresh(let cached) = await service.availability(currency: "EUR", day: nil) else {
            return XCTFail("offline, the cached current quote is still usable within 96h")
        }
        XCTAssertEqual(cached.id, quoteID)
    }

    func testACachedCurrentQuoteOlderThanTheWindowIsOfferedAsStale() async throws {
        let effective = LedgerIDs.eventTime
        let body = try response(quotes: [eurQuote(day: nil, effectiveAt: effective)])
        var calls = 0
        var now = effective
        let service = RateService(container: fixture.container, fetch: { _, _ in
            calls += 1
            if calls == 1 { return body }
            throw URLError(.timedOut)
        }, now: { now })

        _ = await service.availability(currency: "EUR", day: nil)
        now = effective.addingTimeInterval(97 * 3600)
        guard case .stale = await service.availability(currency: "EUR", day: nil) else {
            return XCTFail("older than 96h needs explicit confirmation")
        }
    }

    func testAHistoricalDayNeverFallsBackToACurrentQuote() async throws {
        let body = try response(quotes: [eurQuote(day: nil)])
        var online = true
        let service = RateService(container: fixture.container, fetch: { _, _ in
            if online { return body }
            throw URLError(.notConnectedToInternet)
        }, now: { LedgerIDs.eventTime })
        _ = await service.availability(currency: "EUR", day: nil)   // caches a current quote
        online = false

        guard case .unavailable(let reason, _) = await service.availability(currency: "EUR", day: "2026-05-10") else {
            return XCTFail("today's rate is not a substitute for a past day")
        }
        XCTAssertEqual(reason, "offline")
    }

    func testTheServersReasonIsKeptEvenWhenThisBuildDoesNotKnowIt() async throws {
        let body = try response(quotes: [], unavailable: [["currency": "EUR", "reason": "brand_new_reason", "retryable": false]])
        let service = RateService(container: fixture.container, fetch: { _, _ in body })
        guard case .unavailable(let reason, let retryable) = await service.availability(currency: "EUR", day: nil) else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "brand_new_reason")
        XCTAssertFalse(retryable)
        XCTAssertEqual(QuoteText.reason("brand_new_reason"), L("rate_reason_unknown"))
    }

    func testAQuoteOfTheWrongKindIsRejected() async throws {
        // Asked for a day, answered with a current quote.
        let body = try response(quotes: [eurQuote(day: nil)])
        let service = RateService(container: fixture.container, fetch: { _, _ in body })
        guard case .unavailable(let reason, _) = await service.availability(currency: "EUR", day: "2026-05-10") else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "invalid_quote")
    }

    func testNotBeingSignedInIsReportedAsSuch() async {
        let service = RateService(container: fixture.container, fetch: { _, _ in throw BackendError.notSignedIn })
        guard case .unavailable(let reason, _) = await service.availability(currency: "EUR", day: nil) else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "not_signed_in")
    }

    /// VAL-08: a provider correction reaches the cache and nothing else.
    func testARefreshNeverRewritesABookedTransaction() async throws {
        let booked = try save(valuation: .quoted(eurQuote("1.08", day: "2026-05-19")))
        let corrected = eurQuote("1.09", id: UUID(), day: "2026-05-19")
        let body = try response(quotes: [corrected])
        let service = RateService(container: fixture.container, fetch: { _, _ in body })

        guard case .fresh(let quote) = await service.availability(currency: "EUR", day: "2026-05-19") else {
            return XCTFail()
        }
        XCTAssertEqual(quote.usdPerUnit, "1.09")

        let reread = try XCTUnwrap(try ModelContext(fixture.container).fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(reread.id, booked.id)
        XCTAssertEqual(reread.rateExact, "1.08")
        XCTAssertEqual(reread.baseAmountExact, "10.8")
        XCTAssertEqual(reread.localGeneration, 1)
    }

    func testTheValuationStringsAreLocalized() {
        let keys = LocalizationManager.translationsData.keys.filter {
            $0.hasPrefix("valuation_") || $0.hasPrefix("rate_reason_") || $0.hasPrefix("report_")
                || ["err_valuation_decision_required", "err_invalid_rate", "err_base_amount_rounds_to_zero",
                    "receipt_unconverted"].contains($0)
        }
        XCTAssertGreaterThanOrEqual(keys.count, 38)
        for key in keys {
            for language in ["en", "uk", "ru", "es", "de", "pl"] {
                XCTAssertNotNil(LocalizationManager.translationsData[key]?[language], "\(key) has no \(language)")
            }
        }
    }
}
