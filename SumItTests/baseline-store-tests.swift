import XCTest
import SwiftData
@testable import SumIt

/// Task 00's harness proof: the baseline fixture is a real file-backed store,
/// its content survives a close and reopen, and the snapshot comparison is
/// sensitive enough to notice a change.
@MainActor
final class BaselineStoreTests: XCTestCase {

    private var fixture: PersistentStoreFixture?

    override func tearDownWithError() throws {
        try fixture?.destroy()
        fixture = nil
    }

    func testPersistentStoreSurvivesReopen() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        self.fixture = fixture
        let before = try fixture.snapshot()
        try fixture.closeAndReopen()
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testBaselineIsOnDiskNotInMemory() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        self.fixture = fixture
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.storeURL.path),
                      "baseline store file must exist at \(fixture.storeURL.path)")
    }

    /// The exact content the plan requires of the baseline.
    func testBaselineContent() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        self.fixture = fixture
        let snapshot = try fixture.snapshot()

        XCTAssertEqual(snapshot.transactions.count, 2)
        XCTAssertEqual(snapshot.wallets.count, 2)
        XCTAssertEqual(snapshot.categories.count, 1)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.settings.count, 1)

        let expense = try XCTUnwrap(snapshot.transactions.first { $0.id == LedgerIDs.expense.uuidString.lowercased() })
        XCTAssertEqual(expense.originalAmount, "12.5")
        XCTAssertEqual(expense.originalCurrency, "USD")
        XCTAssertEqual(expense.linkedMessageID, LedgerIDs.linkedMessage.uuidString.lowercased())
        XCTAssertTrue(expense.isSynced)

        let crypto = try XCTUnwrap(snapshot.transactions.first { $0.id == LedgerIDs.cryptoExpense.uuidString.lowercased() })
        XCTAssertEqual(crypto.originalAmount, "0.001")
        XCTAssertEqual(crypto.originalCurrency, "BTC")
        XCTAssertFalse(crypto.isSynced, "the baseline must contain an unsynced row")

        XCTAssertEqual(snapshot.walletBalances[LedgerIDs.walletA.uuidString.lowercased()], "1000")
        XCTAssertEqual(snapshot.walletBalances[LedgerIDs.walletBTC.uuidString.lowercased()], "0.01")

        let category = try XCTUnwrap(snapshot.categories.first)
        XCTAssertEqual(category.name, "Coffee")
        XCTAssertFalse(category.isDefault)
    }

    /// A snapshot that ignored a changed amount would make every later
    /// migration assertion worthless, so prove it does not.
    func testSnapshotDetectsAChangedAmount() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        self.fixture = fixture
        let before = try fixture.snapshot()

        let context = ModelContext(fixture.container)
        let identifier = LedgerIDs.expense
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == identifier })
        let transaction = try XCTUnwrap(try context.fetch(descriptor).first)
        transaction.originalAmount = 12.0
        try context.save()

        try fixture.closeAndReopen()
        XCTAssertNotEqual(try fixture.snapshot(), before)
    }

    /// Two fixtures must not share a directory, so a failing test cannot
    /// corrupt another one's data.
    func testFixturesAreIsolated() throws {
        let first = try PersistentStoreFixture.makeBaseline()
        let second = try PersistentStoreFixture()
        defer { try? first.destroy(); try? second.destroy() }
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertTrue(try second.snapshot().transactions.isEmpty)
    }

    func testDestroyRemovesOnlyItsOwnDirectory() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        let directory = fixture.directory
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        try fixture.destroy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryRoot.path))
    }

    // MARK: — Transport stub

    func testStubURLProtocolInterceptsAndRecords() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(statusCode: 503, body: Data(#"{"error":"unavailable"}"#.utf8))
        }
        let session = StubURLProtocol.makeSession()
        var request = URLRequest(url: URL(string: "https://example.invalid/rpc")!)
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"error":"unavailable"}"#)
        XCTAssertEqual(StubURLProtocol.requests().count, 1)
        XCTAssertEqual(StubURLProtocol.requests().first?.httpMethod, "POST")
    }
}
