import XCTest
@testable import SumIt

/// The client side of parse contract version 2: what a response has to be to
/// become a pending transaction, and what the request tells the server.
final class ParseContractTests: XCTestCase {

    private let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    private func response(_ json: String) throws -> BackendParseResponse {
        try JSONDecoder().decode(BackendParseResponse.self, from: Data(json.utf8))
    }

    private func v2(_ overrides: [String: String] = [:]) throws -> BackendParseResponse {
        var fields: [String: String] = [
            "contract_version": "2", "type": "\"expense\"", "amount_decimal": "\"12.5\"",
            "amount": "12.5", "currency": "\"EUR\"", "category": "\"Food\"",
            "merchant": "\"Cafe\"", "date": "\"2026-05-18\"", "note": "\"\"",
            "confidence": "0.9", "wallet_name": "\"\"",
        ]
        for (key, value) in overrides { fields[key] = value }
        let body = fields.filter { $0.value != "__absent__" }
            .map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return try response("{\(body)}")
    }

    private func decode(_ r: BackendParseResponse, segment: Int? = nil) throws -> ParsedTransaction {
        try ParseResponseDecoder.transaction(from: r, rawInput: "raw", source: .text,
                                             expectedSegmentIndex: segment, timeZone: kyiv)
    }

    private func malformedReason(_ body: () throws -> Void,
                                 file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            try body()
            XCTFail("expected a refusal", file: file, line: line)
        } catch BackendError.malformedResponse(let reason) {
            return reason
        } catch {
            XCTFail("expected malformedResponse, got \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: — Version 2: exact

    func testTheExactStringIsAuthoritativeAndTheDoubleIsIgnored() throws {
        let parsed = try decode(try v2(["amount_decimal": "\"12.50\"", "amount": "99"]))
        XCTAssertEqual(parsed.amountExact, "12.5", "the mirror field must never win")
        XCTAssertEqual(parsed.currency, "EUR")
        XCTAssertEqual(parsed.type, .expense)
    }

    func testCryptoPrecisionSurvivesTheWire() throws {
        let parsed = try decode(try v2(["amount_decimal": "\"0.00000001\"", "currency": "\"BTC\""]))
        XCTAssertEqual(parsed.amountExact, "0.00000001")

        let eth = try decode(try v2(["amount_decimal": "\"0.000000000000000001\"", "currency": "\"ETH\""]))
        XCTAssertEqual(eth.amountExact, "0.000000000000000001", "not zero")
    }

    // MARK: — Version 2: refused, never repaired

    func testAMalformedAmountIsRefusedWithoutFallingBackToTheDouble() throws {
        let r = try v2(["amount_decimal": "\"1e3\"", "amount": "1000"])
        XCTAssertEqual(malformedReason { _ = try decode(r) }, "invalid_amount")
    }

    func testAMissingExactAmountIsRefusedEvenWhenTheDoubleIsThere() throws {
        let r = try v2(["amount_decimal": "__absent__", "amount": "12.5"])
        XCTAssertEqual(malformedReason { _ = try decode(r) }, "missing_amount_decimal")
    }

    func testExcessPrecisionIsRefusedNotRounded() throws {
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["amount_decimal": "\"12.345\""])) },
                       "excess_precision")
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["amount_decimal": "\"12.5\"",
                                                                "currency": "\"JPY\""])) },
                       "excess_precision")
    }

    func testAnUnknownTypeIsRefusedNotTurnedIntoAnExpense() throws {
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["type": "\"refund\""])) }, "unknown_type")
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["type": "__absent__"])) }, "unknown_type")
    }

    func testAnImpossibleDateIsRefused() throws {
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["date": "\"2026-02-30\""])) }, "invalid_date")
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["date": "\"вчера\""])) }, "invalid_date")
    }

    func testConfidenceOutsideTheRangeIsRefused() throws {
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["confidence": "1.5"])) }, "invalid_confidence")
    }

    func testAnAnswerForADifferentSegmentIsRefused() throws {
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["segment_index": "1"]), segment: 2) },
                       "segment_index_mismatch")
        XCTAssertNoThrow(try decode(try v2(["segment_index": "2"]), segment: 2))
    }

    func testTheServersOwnRefusalCarriesItsReason() throws {
        let r = try response(#"{"contract_version":2,"error":"invalid_model_output","reason":"amount_not_string"}"#)
        XCTAssertEqual(malformedReason { _ = try decode(r) }, "amount_not_string")
    }

    func testNotATransactionIsAParseFailureNotAMalformedResponse() throws {
        let r = try response(#"{"contract_version":2,"error":"not_a_transaction"}"#)
        XCTAssertThrowsError(try decode(r)) { error in
            guard case BackendError.parseFailed = error else { return XCTFail("got \(error)") }
        }
    }

    func testAnUnknownContractVersionIsRefused() throws {
        XCTAssertEqual(malformedReason { _ = try decode(try v2(["contract_version": "3"])) },
                       "unsupported_contract_version")
    }

    func testTheDateIsThatDayInTheUsersTimeZone() throws {
        let parsed = try decode(try v2(["date": "\"2026-05-18\""]))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kyiv
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: parsed.occurredAt)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 5, 18, 0])
    }

    // MARK: — Legacy compatibility

    func testALegacyResponseStillWorksThroughTheLabelledPath() throws {
        let r = try response(#"{"type":"expense","amount":12.5,"currency":"eur","date":"2026-05-18","confidence":0.9}"#)
        let parsed = try decode(r)
        XCTAssertEqual(parsed.amountExact, "12.5")
        XCTAssertEqual(parsed.currency, "EUR")
    }

    func testTheLegacyPathDoesNotCoerceTypesOrCapAmounts() throws {
        let unknownType = try response(#"{"type":"refund","amount":12.5,"currency":"EUR"}"#)
        XCTAssertEqual(malformedReason { _ = try decode(unknownType) }, "unknown_type")

        // The old builder silently capped this at 1e12.
        let huge = try response(#"{"type":"expense","amount":5000000000000,"currency":"USD"}"#)
        XCTAssertEqual(malformedReason { _ = try decode(huge) }, "amount_out_of_range")
    }

    // MARK: — Request

    func testTheRequestCarriesTheContractAndTheUsersContext() throws {
        let context = ParseContext(localDate: "2026-05-19", timeZone: "Europe/Kyiv", locale: "uk")
        let data = try JSONEncoder().encode(ParseRequest(text: "вчора 12,50 кава", model: "gpt-4o-mini",
                                                         context: context, segmentIndex: 1))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["contract_version"] as? Int, 2)
        XCTAssertEqual(json["local_date"] as? String, "2026-05-19")
        XCTAssertEqual(json["timezone"] as? String, "Europe/Kyiv")
        XCTAssertEqual(json["locale"] as? String, "uk")
        XCTAssertEqual(json["segment_index"] as? Int, 1)
        XCTAssertEqual(json["text"] as? String, "вчора 12,50 кава")
        XCTAssertNil(json["image"], "the unused field is omitted, not sent as null")
        XCTAssertNil(json["wallets"])
    }

    /// "Today" is the user's today. A server resolving "yesterday" in UTC would
    /// be a day off for anyone far enough from Greenwich.
    func testTheLocalDateFollowsTheUsersTimeZoneNotUTC() {
        let noonUTC = ISO8601DateFormatter().date(from: "2026-05-19T12:00:00Z")!
        XCTAssertEqual(ParseContext.current(now: noonUTC,
                                            timeZone: TimeZone(identifier: "Pacific/Kiritimati")!,
                                            locale: "en").localDate, "2026-05-20")

        let earlyUTC = ISO8601DateFormatter().date(from: "2026-05-19T03:00:00Z")!
        XCTAssertEqual(ParseContext.current(now: earlyUTC,
                                            timeZone: TimeZone(identifier: "America/Los_Angeles")!,
                                            locale: "en").localDate, "2026-05-18")
    }

    // MARK: — Transfers

    /// The parser can say "transfer"; it cannot choose the two wallets. A name
    /// match is not enough, so the draft is incomplete and the store refuses it.
    @MainActor
    func testATransferSuggestionDoesNotPickWalletsByName() throws {
        let cash = Wallet(userId: "local", name: "Cash", currency: "EUR")
        let bank = Wallet(userId: "local", name: "Bank", currency: "EUR")
        var parsed = ParsedTransaction(type: .transfer, amount: 100, currency: "EUR",
                                       categoryName: "Other", merchant: "", note: "",
                                       occurredAt: .now, confidence: 0.9, rawInput: "",
                                       source: .text, amountExact: "100")
        parsed.walletName = "Cash"

        let draft = try ParsedTransactionDraft.make(from: parsed, categoryName: "Other",
                                                    wallets: [cash, bank], ownerID: "local")
        XCTAssertNil(draft.walletID)
        XCTAssertNil(draft.destinationWalletID)

        parsed.walletID = cash.id
        parsed.destinationWalletID = bank.id
        let chosen = try ParsedTransactionDraft.make(from: parsed, categoryName: "Other",
                                                     wallets: [cash, bank], ownerID: "local")
        XCTAssertEqual(chosen.walletID, cash.id)
        XCTAssertEqual(chosen.destinationWalletID, bank.id)
        XCTAssertEqual(chosen.destinationAmount, chosen.walletAmount,
                       "same currency moves the same quantity")
    }

    func testTheMalformedResponseMessageIsLocalized() {
        let translations = LocalizationManager.translationsData["backend_malformed_response"]
        for language in ["en", "uk", "ru", "es", "de", "pl"] {
            XCTAssertNotNil(translations?[language], "no \(language)")
        }
    }
}
