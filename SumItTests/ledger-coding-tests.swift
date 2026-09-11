import XCTest
@testable import SumIt

/// Wire-contract tests. The specimens are taken verbatim from
/// `database-and-rollout.md` §4–§6, so a drift between the document and the
/// client shows up here rather than against a live database.
final class LedgerCodingTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: — Specimens

    private let transferRequestJSON = """
    {
      "protocol_version": 1,
      "operation_id": "20000000-0000-4000-8000-000000000001",
      "entity_kind": "transaction",
      "entity_id": "30000000-0000-4000-8000-000000000001",
      "action": "put",
      "expected_revision": "0",
      "record": {
        "type": "transfer",
        "original_amount": "100",
        "original_currency": "USD",
        "wallet_id": "40000000-0000-4000-8000-000000000001",
        "wallet_amount": "100",
        "destination_wallet_id": "40000000-0000-4000-8000-000000000003",
        "destination_amount": "90",
        "category_name": "Other",
        "merchant": "",
        "note": "Synthetic transfer fixture",
        "occurred_at": "2026-05-19T12:00:00Z",
        "source": "manual",
        "confidence": "1",
        "raw_input": "",
        "base_amount": "100",
        "usd_per_unit": "1",
        "valuation_state": "valued",
        "quote": {
          "quote_id": null,
          "currency": "USD",
          "usd_per_unit": "1",
          "requested_date": "2026-05-19",
          "effective_at": "2026-05-19T12:00:00Z",
          "fetched_at": "2026-05-19T12:00:00Z",
          "source": "identity",
          "source_detail": {},
          "valuation_kind": "identity",
          "stale": false
        }
      }
    }
    """

    private func snapshotJSON(deletedAt: String = "null", revision: String = "41") -> String {
        """
        {
          "entity_kind": "transaction",
          "local_id": "30000000-0000-4000-8000-000000000001",
          "user_id": "10000000-0000-4000-8000-000000000001",
          "ledger_revision": "\(revision)",
          "deleted_at": \(deletedAt),
          "ledger_version": 1,
          "type": "transfer",
          "original_amount": "100",
          "original_currency": "USD",
          "wallet_id": "40000000-0000-4000-8000-000000000001",
          "wallet_amount": "100",
          "destination_wallet_id": "40000000-0000-4000-8000-000000000003",
          "destination_amount": "90",
          "category_name": "Other",
          "merchant": "",
          "note": "Synthetic transfer fixture",
          "occurred_at": "2026-05-19T12:00:00Z",
          "source": "manual",
          "confidence": "1",
          "raw_input": "",
          "base_amount": "100",
          "usd_per_unit": "1",
          "valuation_state": "valued",
          "quote": {
            "quote_id": null, "currency": "USD", "usd_per_unit": "1",
            "requested_date": "2026-05-19", "effective_at": "2026-05-19T12:00:00Z",
            "fetched_at": "2026-05-19T12:00:00Z", "source": "identity",
            "source_detail": {}, "valuation_kind": "identity", "stale": false
          },
          "created_at": "2026-05-19T12:00:00Z"
        }
        """
    }

    // MARK: — Requests

    func testDecodesTheTransferRequestSpecimen() throws {
        let request = try decode(LedgerMutationRequest.self, transferRequestJSON)

        XCTAssertEqual(request.protocolVersion, 1)
        XCTAssertEqual(request.entityKind, .transaction)
        XCTAssertEqual(request.action, .put)
        XCTAssertEqual(request.expectedRevision.value, 0)

        guard case .transaction(let record) = try XCTUnwrap(request.record) else {
            return XCTFail("expected a transaction record")
        }
        XCTAssertEqual(record.type, "transfer")
        XCTAssertEqual(record.originalAmount, "100")
        XCTAssertEqual(record.walletAmount, "100")
        XCTAssertEqual(record.destinationAmount, "90")
        XCTAssertEqual(record.valuationState, .valued)
        XCTAssertEqual(record.quote?.valuationKind, .identity)
        XCTAssertEqual(record.quote?.usdPerUnit, "1")
    }

    /// A frozen request must survive encode/decode byte-for-byte in meaning:
    /// a retry that changed the payload would be rejected by the server.
    func testRequestRoundTripIsStable() throws {
        let request = try decode(LedgerMutationRequest.self, transferRequestJSON)
        let reencoded = try encoder.encode(request)
        let decoded = try decoder.decode(LedgerMutationRequest.self, from: reencoded)
        XCTAssertEqual(decoded, request)
    }

    func testDeleteRequestCarriesNoRecord() throws {
        let json = """
        {
          "protocol_version": 1,
          "operation_id": "20000000-0000-4000-8000-000000000009",
          "entity_kind": "transaction",
          "entity_id": "30000000-0000-4000-8000-000000000001",
          "action": "delete",
          "expected_revision": "41"
        }
        """
        let request = try decode(LedgerMutationRequest.self, json)
        XCTAssertEqual(request.action, .delete)
        XCTAssertNil(request.record)
        XCTAssertEqual(request.expectedRevision.value, 41)
    }

    // MARK: — Responses

    func testDecodesAcceptedResponse() throws {
        let json = """
        {
          "status": "accepted",
          "operation_id": "20000000-0000-4000-8000-000000000001",
          "entity_id": "30000000-0000-4000-8000-000000000001",
          "revision": "41",
          "cursor": "41",
          "snapshot": \(snapshotJSON())
        }
        """
        guard case .accepted(let accepted) = try decode(LedgerMutationResult.self, json) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(accepted.revision.value, 41)
        XCTAssertEqual(accepted.cursor.value, 41)
        XCTAssertEqual(accepted.snapshot.header.ledgerVersion, 1)
        XCTAssertFalse(accepted.snapshot.header.isDeleted)

        guard case .transaction(let snapshot) = accepted.snapshot else {
            return XCTFail("expected a transaction snapshot")
        }
        XCTAssertEqual(snapshot.record.destinationAmount, "90")
        XCTAssertEqual(snapshot.createdAt, LedgerIDs.eventTime)
    }

    /// A conflict arrives as an HTTP success. It must decode as a conflict,
    /// never be mistaken for an acceptance.
    func testDecodesConflictResponse() throws {
        let json = """
        {
          "status": "conflict",
          "operation_id": "20000000-0000-4000-8000-000000000001",
          "entity_id": "30000000-0000-4000-8000-000000000001",
          "expected_revision": "40",
          "actual_revision": "41",
          "reason": "revision_mismatch",
          "server_snapshot": \(snapshotJSON())
        }
        """
        guard case .conflict(let conflict) = try decode(LedgerMutationResult.self, json) else {
            return XCTFail("expected conflict")
        }
        XCTAssertEqual(conflict.expectedRevision.value, 40)
        XCTAssertEqual(conflict.actualRevision.value, 41)
        XCTAssertEqual(conflict.reason, "revision_mismatch")
        XCTAssertNotNil(conflict.serverSnapshot)
    }

    /// An unrecognised status is an unknown outcome. Treating it as success is
    /// exactly how a failed write becomes a false "synced".
    func testUnknownStatusIsRejected() {
        let json = """
        {"status": "maybe", "operation_id": "20000000-0000-4000-8000-000000000001"}
        """
        XCTAssertThrowsError(try decode(LedgerMutationResult.self, json)) { error in
            XCTAssertEqual(error as? LedgerCodingError, .unexpectedStatus("maybe"))
        }
    }

    // MARK: — Change feed

    func testDecodesPullPageWithATombstone() throws {
        let json = """
        {
          "through_cursor": "87",
          "next_cursor": "42",
          "has_more": true,
          "changes": [
            {
              "cursor": "42",
              "operation_id": "20000000-0000-4000-8000-000000000002",
              "entity_kind": "transaction",
              "entity_id": "30000000-0000-4000-8000-000000000001",
              "snapshot": \(snapshotJSON(deletedAt: "\"2026-05-20T12:00:00Z\"", revision: "42"))
            }
          ]
        }
        """
        let page = try decode(LedgerChangePage.self, json)
        XCTAssertEqual(page.throughCursor.value, 87)
        XCTAssertEqual(page.nextCursor.value, 42)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.changes.count, 1)

        let change = try XCTUnwrap(page.changes.first)
        XCTAssertEqual(change.cursor.value, 42)
        XCTAssertTrue(change.snapshot.header.isDeleted, "a tombstone must decode as deleted")
        XCTAssertEqual(change.snapshot.header.ledgerRevision.value, 42)
    }

    // MARK: — Cursors

    func testCursorsAreStringsAndBounded() throws {
        XCTAssertEqual(try decode(LedgerCursor.self, "\"0\"").value, 0)
        XCTAssertEqual(try decode(LedgerCursor.self, "\"9007199254740993\"").value, 9_007_199_254_740_993)

        for bad in ["\"-1\"", "\"4.1\"", "\"\"", "\"abc\"", "\" 1\"", "\"1 \"", "\"+1\""] {
            XCTAssertThrowsError(try decode(LedgerCursor.self, bad), "accepted \(bad)")
        }
        // A bare JSON number is not the contract: it would be coerced to a float.
        XCTAssertThrowsError(try decode(LedgerCursor.self, "41"))
    }

    // MARK: — Rejections that must not become defaults

    func testUnknownEntityKindIsAnError() {
        let json = transferRequestJSON.replacingOccurrences(of: "\"entity_kind\": \"transaction\"",
                                                            with: "\"entity_kind\": \"budget\"")
        XCTAssertThrowsError(try decode(LedgerMutationRequest.self, json)) { error in
            XCTAssertEqual(error as? LedgerCodingError, .unknownEntityKind("budget"))
        }
    }

    func testUnknownActionIsAnError() {
        let json = transferRequestJSON.replacingOccurrences(of: "\"action\": \"put\"",
                                                            with: "\"action\": \"upsert\"")
        XCTAssertThrowsError(try decode(LedgerMutationRequest.self, json)) { error in
            XCTAssertEqual(error as? LedgerCodingError, .unknownAction("upsert"))
        }
    }

    func testNonCanonicalAmountsAreRejected() {
        for bad in ["1e3", "12,5", "+100", "100.", " 100"] {
            let json = transferRequestJSON.replacingOccurrences(of: "\"original_amount\": \"100\"",
                                                                with: "\"original_amount\": \"\(bad)\"")
            XCTAssertThrowsError(try decode(LedgerMutationRequest.self, json), "accepted \(bad)") { error in
                XCTAssertEqual(error as? LedgerCodingError, .malformedDecimal(field: "original_amount"))
            }
        }
    }

    /// A malformed historic date must surface, never be replaced with "now".
    func testMalformedDateIsRejectedRatherThanDefaulted() {
        let json = transferRequestJSON.replacingOccurrences(of: "\"occurred_at\": \"2026-05-19T12:00:00Z\"",
                                                            with: "\"occurred_at\": \"19/05/2026\"")
        XCTAssertThrowsError(try decode(LedgerMutationRequest.self, json)) { error in
            XCTAssertEqual(error as? LedgerCodingError, .malformedDate(field: "occurred_at"))
        }
    }

    /// A quote claiming provider provenance without its persisted cache row
    /// cannot be verified against anything.
    func testProviderQuoteWithoutIDIsRejected() {
        let json = transferRequestJSON
            .replacingOccurrences(of: "\"valuation_kind\": \"identity\"",
                                  with: "\"valuation_kind\": \"historical_reference\"")
        XCTAssertThrowsError(try decode(LedgerMutationRequest.self, json)) { error in
            XCTAssertEqual(error as? LedgerCodingError, .missingProviderQuoteID)
        }
    }

    // MARK: — Null handling

    func testUnvaluedTransactionDecodesWithNoValuationFields() throws {
        let json = """
        {
          "protocol_version": 1,
          "operation_id": "20000000-0000-4000-8000-000000000003",
          "entity_kind": "transaction",
          "entity_id": "30000000-0000-4000-8000-000000000004",
          "action": "put",
          "expected_revision": "0",
          "record": {
            "type": "expense",
            "original_amount": "100",
            "original_currency": "UAH",
            "wallet_id": null,
            "wallet_amount": null,
            "destination_wallet_id": null,
            "destination_amount": null,
            "category_name": "Food",
            "merchant": "Cafe",
            "note": "",
            "occurred_at": "2026-05-19T12:00:00Z",
            "source": "text",
            "confidence": "0.9",
            "raw_input": "100 grn coffee",
            "base_amount": null,
            "usd_per_unit": null,
            "valuation_state": "unvalued",
            "quote": null
          }
        }
        """
        let request = try decode(LedgerMutationRequest.self, json)
        guard case .transaction(let record) = try XCTUnwrap(request.record) else {
            return XCTFail("expected a transaction record")
        }
        XCTAssertNil(record.baseAmount)
        XCTAssertNil(record.usdPerUnit)
        XCTAssertNil(record.quote)
        XCTAssertEqual(record.valuationState, .unvalued)
        XCTAssertEqual(record.originalAmount, "100", "the original quantity is still present")
    }

    func testWalletlessTransactionKeepsAllReferenceFieldsNull() throws {
        let json = transferRequestJSON
            .replacingOccurrences(of: "\"wallet_id\": \"40000000-0000-4000-8000-000000000001\"",
                                  with: "\"wallet_id\": null")
            .replacingOccurrences(of: "\"wallet_amount\": \"100\"", with: "\"wallet_amount\": null")
            .replacingOccurrences(of: "\"destination_wallet_id\": \"40000000-0000-4000-8000-000000000003\"",
                                  with: "\"destination_wallet_id\": null")
            .replacingOccurrences(of: "\"destination_amount\": \"90\"", with: "\"destination_amount\": null")

        let request = try decode(LedgerMutationRequest.self, json)
        guard case .transaction(let record) = try XCTUnwrap(request.record) else {
            return XCTFail("expected a transaction record")
        }
        XCTAssertNil(record.walletID)
        XCTAssertNil(record.walletAmount)
        XCTAssertNil(record.destinationWalletID)
        XCTAssertNil(record.destinationAmount)
    }

    // MARK: — Provider metadata must stay JSON

    func testSourceDetailTravelsAsAnObjectNotBase64() throws {
        let quoteJSON = """
        {
          "quote_id": "60000000-0000-4000-8000-000000000001",
          "currency": "EUR",
          "usd_per_unit": "1.08",
          "requested_date": "2026-05-19",
          "effective_at": "2026-05-19T12:00:00Z",
          "fetched_at": "2026-05-19T12:00:00Z",
          "source": "frankfurter",
          "source_detail": {"provider_date": "2026-05-19", "base": "USD", "requests": 1, "cached": false},
          "valuation_kind": "historical_reference",
          "stale": false
        }
        """
        let quote = try decode(RateQuote.self, quoteJSON)
        guard case .object(let detail) = quote.sourceDetail else {
            return XCTFail("source_detail must decode as a JSON object")
        }
        XCTAssertEqual(detail["provider_date"], .string("2026-05-19"))
        XCTAssertEqual(detail["requests"], .number(1))
        XCTAssertEqual(detail["cached"], .bool(false))

        let reencoded = String(decoding: try encoder.encode(quote), as: UTF8.self)
        XCTAssertTrue(reencoded.contains("\"provider_date\""),
                      "re-encoding must keep an object, not a base64 blob: \(reencoded)")
        XCTAssertEqual(try decoder.decode(RateQuote.self, from: Data(reencoded.utf8)), quote)
    }

    /// Production's `public.categories` has no `created_at` column, and the DTO
    /// inventory does not list one for category snapshots. A category snapshot
    /// must therefore decode without it — while transaction and wallet
    /// snapshots still require theirs.
    func testCategorySnapshotDecodesWithoutCreatedAt() throws {
        let json = """
        {"entity_kind":"category",
         "local_id":"20000000-0000-4000-8000-000000000001",
         "user_id":"10000000-0000-4000-8000-000000000001",
         "ledger_revision":"7","deleted_at":null,"ledger_version":1,
         "name":"Coffee","icon":"cup.and.saucer.fill","color_hex":"8B5E3C",
         "type":"expense","sort_order":50,"is_default":false}
        """
        guard case .category(let snapshot) = try decode(LedgerSnapshot.self, json) else {
            return XCTFail("expected a category snapshot")
        }
        XCTAssertNil(snapshot.createdAt)
        XCTAssertEqual(snapshot.record.name, "Coffee")
        XCTAssertEqual(snapshot.header.ledgerRevision.value, 7)
        XCTAssertFalse(snapshot.record.isDefault)
    }

    func testWalletSnapshotStillRequiresCreatedAt() {
        let json = """
        {"entity_kind":"wallet",
         "local_id":"40000000-0000-4000-8000-000000000001",
         "user_id":"10000000-0000-4000-8000-000000000001",
         "ledger_revision":"7","deleted_at":null,"ledger_version":1,
         "name":"Monobank","type":"bank","currency":"USD",
         "opening_balance":"1000","icon":""}
        """
        XCTAssertThrowsError(try decode(LedgerSnapshot.self, json))
    }

    func testIdentityQuoteIsUSDAtRateOne() {
        let quote = RateQuote.identity(at: LedgerIDs.eventTime)
        XCTAssertEqual(quote.currency, "USD")
        XCTAssertEqual(quote.usdPerUnit, "1")
        XCTAssertEqual(quote.valuationKind, .identity)
        XCTAssertNil(quote.id)
        XCTAssertFalse(quote.isStale)
    }
}
