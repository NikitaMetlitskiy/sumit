import XCTest
@testable import SumIt

/// ERR group from acceptance-tests.md §5, for the transport layer.
/// Every case runs against `StubURLProtocol` on an **ephemeral** session, so no
/// test can reach the network or a real credential.
nonisolated final class SupabaseTransportTests: XCTestCase {

    private let scope = AccountScope(ownerID: "10000000-0000-4000-8000-00000000000a", epoch: UUID())

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    // MARK: — Harness

    private func makeService(ownerID: String? = nil,
                             token: String? = "token",
                             refreshSucceeds: Bool = true,
                             refreshCounter: RefreshCounter? = nil) -> SupabaseService {
        let owner = ownerID ?? scope.ownerID
        let auth = LedgerAuth(
            token: { token },
            currentOwnerID: { owner },
            refresh: { refreshCounter?.record(); return refreshSucceeds })
        return SupabaseService(session: StubURLProtocol.makeSession(), auth: auth)
    }

    nonisolated private final class RefreshCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func request(operationID: UUID = LedgerIDs.transfer,
                         entityID: UUID = LedgerIDs.expense) -> LedgerMutationRequest {
        LedgerMutationRequest(protocolVersion: 1, operationID: operationID,
                              entityKind: .transaction, entityID: entityID,
                              action: .delete, expectedRevision: .zero, record: nil)
    }

    private func acceptedBody(operationID: UUID = LedgerIDs.transfer,
                              entityID: UUID = LedgerIDs.expense,
                              owner: String? = nil) -> Data {
        let ownerID = owner ?? scope.ownerID
        return Data("""
        {"status":"accepted",
         "operation_id":"\(operationID.uuidString.lowercased())",
         "entity_id":"\(entityID.uuidString.lowercased())",
         "revision":"41","cursor":"41",
         "snapshot":{"entity_kind":"transaction",
           "local_id":"\(entityID.uuidString.lowercased())","user_id":"\(ownerID)",
           "ledger_revision":"41","deleted_at":null,"ledger_version":1,
           "type":"expense","original_amount":"12.5","original_currency":"USD",
           "wallet_id":null,"wallet_amount":null,
           "destination_wallet_id":null,"destination_amount":null,
           "category_name":"Food","merchant":"Cafe","note":"",
           "occurred_at":"2026-05-19T12:00:00Z","source":"manual","confidence":"1",
           "raw_input":"","base_amount":null,"usd_per_unit":null,
           "valuation_state":"unvalued","quote":null,
           "created_at":"2026-05-19T12:00:00Z"}}
        """.utf8)
    }

    private func expectError(_ expected: LedgerTransportError,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as LedgerTransportError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: — RPC argument envelope

    /// The defect this pins: PostgREST treats the body's top-level keys as the
    /// function's argument names. Sending the mutation itself made production
    /// answer 404 for every push — reads worked because they were named.
    func testTheWriteRPCNamesItsArgument() async throws {
        StubURLProtocol.handler = { _ in .init(statusCode: 200, body: self.acceptedBody()) }

        _ = try await makeService().applyLedgerMutation(request(), scope: scope)

        let body = try XCTUnwrap(StubURLProtocol.bodies().first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["p_request"],
                       "apply_ledger_mutation_v1 takes exactly one argument, p_request")
        let argument = try XCTUnwrap(object["p_request"] as? [String: Any])
        XCTAssertNotNil(argument["operation_id"], "the mutation travels inside the argument")
        XCTAssertNotNil(argument["protocol_version"])
    }

    func testTheReadRPCNamesItsArguments() async {
        StubURLProtocol.handler = { _ in .init(statusCode: 200, body: Data("{}".utf8)) }

        // The body is what matters here; the empty answer fails to decode.
        _ = try? await makeService().readLedgerChanges(after: 7, through: nil, limit: 50, scope: scope)

        guard let body = StubURLProtocol.bodies().first,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("no request body was captured")
        }
        XCTAssertEqual(Set(object.keys), ["p_after_cursor", "p_through_cursor", "p_limit"])
        XCTAssertEqual(object["p_after_cursor"] as? Int, 7)
        XCTAssertEqual(object["p_limit"] as? Int, 50)
        XCTAssertTrue(object["p_through_cursor"] is NSNull, "an absent watermark is explicit null")
    }

    // MARK: — Success

    func testAcceptedMutationIsReturned() async throws {
        StubURLProtocol.handler = { _ in .init(statusCode: 200, body: self.acceptedBody()) }
        let result = try await makeService().applyLedgerMutation(request(), scope: scope)
        guard case .accepted(let accepted) = result else { return XCTFail("expected acceptance") }
        XCTAssertEqual(accepted.revision.value, 41)
        XCTAssertEqual(StubURLProtocol.requests().count, 1)
        XCTAssertEqual(StubURLProtocol.requests().first?.httpMethod, "POST")
    }

    // MARK: — ERR-01: validation

    func testValidationRejectionKeepsTheServerCodeAndNotItsProse() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 400,
                  body: Data(#"{"code":"P0001","message":"transfer_to_same_wallet","details":"row for merchant Cafe, amount 12.50"}"#.utf8))
        }
        await expectError(.validationRejected(code: "transfer_to_same_wallet")) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    func testValidationCodeIsSanitized() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 400, body: Data(#"{"message":"Cafe — 12.50 <script>"}"#.utf8))
        }
        do {
            _ = try await makeService().applyLedgerMutation(request(), scope: scope)
            XCTFail("expected rejection")
        } catch let LedgerTransportError.validationRejected(code) {
            XCTAssertFalse(code.contains("<"), "raw payload must not survive: \(code)")
            XCTAssertFalse(code.contains("."), "amounts must not survive: \(code)")
        } catch { XCTFail("unexpected \(error)") }
    }

    // MARK: — ERR-02, ERR-03: authentication

    /// One refresh, one retry of the same bytes, then success. Not a loop.
    func testUnauthorizedRefreshesOnceAndRetries() async throws {
        let counter = RefreshCounter()
        let attempts = AttemptCounter()
        StubURLProtocol.handler = { _ in
            attempts.record() == 1
                ? .init(statusCode: 401, body: Data(#"{"message":"JWT expired"}"#.utf8))
                : .init(statusCode: 200, body: self.acceptedBody())
        }
        let service = makeService(refreshSucceeds: true, refreshCounter: counter)
        _ = try await service.applyLedgerMutation(request(), scope: scope)

        XCTAssertEqual(counter.count, 1, "exactly one refresh")
        XCTAssertEqual(StubURLProtocol.requests().count, 2, "one retry, not a loop")
    }

    func testRepeatedUnauthorizedStopsAfterOneRefresh() async {
        let counter = RefreshCounter()
        StubURLProtocol.handler = { _ in .init(statusCode: 401, body: Data("{}".utf8)) }
        await expectError(.notAuthenticated) {
            _ = try await self.makeService(refreshSucceeds: true, refreshCounter: counter)
                .applyLedgerMutation(self.request(), scope: self.scope)
        }
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(StubURLProtocol.requests().count, 2, "no unbounded retry")
    }

    func testFailedRefreshPausesForSignIn() async {
        StubURLProtocol.handler = { _ in .init(statusCode: 401, body: Data("{}".utf8)) }
        await expectError(.notAuthenticated) {
            _ = try await self.makeService(refreshSucceeds: false)
                .applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    func testMissingTokenDoesNotSendAnything() async {
        StubURLProtocol.handler = { _ in .init(statusCode: 200, body: self.acceptedBody()) }
        await expectError(.notAuthenticated) {
            _ = try await self.makeService(token: nil, refreshSucceeds: false)
                .applyLedgerMutation(self.request(), scope: self.scope)
        }
        XCTAssertEqual(StubURLProtocol.requests().count, 0)
    }

    // MARK: — ERR-04, ERR-05

    func testForbiddenIsItsOwnOutcome() async {
        StubURLProtocol.handler = { _ in .init(statusCode: 403, body: Data("{}".utf8)) }
        await expectError(.accessDenied) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    func testTransientStatusesAreRetryableAndCarryRetryAfter() async {
        for status in [408, 429, 500, 503] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { _ in
                .init(statusCode: status, headers: ["Retry-After": "30"], body: Data("{}".utf8))
            }
            await expectError(.retryable(status: status, retryAfter: 30)) {
                _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
            }
        }
    }

    /// A server cannot send the app to sleep for an hour.
    func testRetryAfterIsBounded() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 429, headers: ["Retry-After": "86400"], body: Data("{}".utf8))
        }
        await expectError(.retryable(status: 429, retryAfter: 300)) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    // MARK: — ERR-06: a 2xx that says nothing

    func testEmptyOrMalformedSuccessIsAnUnknownOutcome() async {
        for body in [Data(), Data("not json".utf8), Data("{}".utf8), Data(#"{"status":"maybe"}"#.utf8)] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { _ in .init(statusCode: 200, body: body) }
            await expectError(.unknownOutcome) {
                _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
            }
        }
    }

    // MARK: — ERR-07: the answer must match the question

    func testReceiptForAnotherOperationIsAProtocolFailure() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, body: self.acceptedBody(operationID: UUID()))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    func testReceiptForAnotherEntityIsAProtocolFailure() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, body: self.acceptedBody(entityID: UUID()))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    func testReceiptForAnotherOwnerIsAProtocolFailure() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, body: self.acceptedBody(owner: "10000000-0000-4000-8000-00000000000b"))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
    }

    // MARK: — ERR-08: offline

    func testTransportFailureIsUnreachableNotAnEmptyResult() async {
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        await expectError(.unreachable) {
            _ = try await self.makeService().applyLedgerMutation(self.request(), scope: self.scope)
        }
        await expectError(.unreachable) {
            _ = try await self.makeService().readLedgerChanges(after: 0, scope: self.scope)
        }
    }

    // MARK: — Scope

    /// A response that arrives after the account changed must not be applied.
    func testAccountChangeMidFlightIsRefused() async {
        StubURLProtocol.handler = { _ in .init(statusCode: 200, body: self.acceptedBody()) }
        let other = makeService(ownerID: "10000000-0000-4000-8000-00000000000b")
        await expectError(.scopeChanged) {
            _ = try await other.applyLedgerMutation(self.request(), scope: self.scope)
        }
        XCTAssertEqual(StubURLProtocol.requests().count, 0, "nothing is sent out of scope")
    }

    // MARK: — Change feed validation

    private func page(_ changes: String, through: String = "87", next: String = "42") -> Data {
        Data("""
        {"through_cursor":"\(through)","next_cursor":"\(next)","has_more":true,"changes":[\(changes)]}
        """.utf8)
    }

    private func change(cursor: String, entity: UUID = LedgerIDs.expense, owner: String? = nil) -> String {
        let ownerID = owner ?? scope.ownerID
        return """
        {"cursor":"\(cursor)","operation_id":null,"entity_kind":"transaction",
         "entity_id":"\(entity.uuidString.lowercased())",
         "snapshot":{"entity_kind":"transaction","local_id":"\(entity.uuidString.lowercased())",
           "user_id":"\(ownerID)","ledger_revision":"\(cursor)","deleted_at":null,"ledger_version":1,
           "type":"expense","original_amount":"12.5","original_currency":"USD",
           "wallet_id":null,"wallet_amount":null,"destination_wallet_id":null,"destination_amount":null,
           "category_name":"Food","merchant":"","note":"","occurred_at":"2026-05-19T12:00:00Z",
           "source":"manual","confidence":"1","raw_input":"","base_amount":null,"usd_per_unit":null,
           "valuation_state":"unvalued","quote":null,"created_at":"2026-05-19T12:00:00Z"}}
        """
    }

    func testWellFormedPageIsAccepted() async throws {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, body: self.page(self.change(cursor: "42")))
        }
        let result = try await makeService().readLedgerChanges(after: 0, scope: scope)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.throughCursor.value, 87)
    }

    func testPageWithAnotherOwnersRowIsRefused() async {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200,
                  body: self.page(self.change(cursor: "42", owner: "10000000-0000-4000-8000-00000000000b")))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().readLedgerChanges(after: 0, scope: self.scope)
        }
    }

    func testPageOutOfOrderOrOutOfWindowIsRefused() async {
        // Descending cursors.
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200,
                  body: self.page("\(self.change(cursor: "43")),\(self.change(cursor: "42"))"))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().readLedgerChanges(after: 0, scope: self.scope)
        }

        // A cursor beyond the page's own watermark.
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, body: self.page(self.change(cursor: "99"), through: "87"))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().readLedgerChanges(after: 0, scope: self.scope)
        }

        // A cursor at or below what we already have.
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, body: self.page(self.change(cursor: "10")))
        }
        await expectError(.protocolMismatch) {
            _ = try await self.makeService().readLedgerChanges(after: 20, scope: self.scope)
        }
    }
}

/// Counts stub invocations across the actor boundary.
nonisolated private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func record() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
