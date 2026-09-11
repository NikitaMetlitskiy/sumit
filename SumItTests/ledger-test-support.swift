import Foundation
import SwiftData
import XCTest
@testable import SumIt

// MARK: — Fixed identities and dates

/// Static identifiers from acceptance-tests.md §1. Owner IDs for pure local
/// tests are fixed strings with UUID syntax; SQL/auth suites must instead use
/// accounts actually created in the disposable staging project.
enum LedgerIDs {
    static let ownerA = "10000000-0000-4000-8000-00000000000a"
    static let ownerB = "10000000-0000-4000-8000-00000000000b"

    static let walletA   = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
    static let walletB   = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
    static let walletEUR = UUID(uuidString: "40000000-0000-4000-8000-000000000003")!
    static let walletBTC = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!

    static let expense  = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    static let transfer = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    static let cryptoExpense = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!

    static let customCategory = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    static let linkedMessage  = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!

    /// Fixed event time: 2026-05-19T12:00:00Z.
    static let eventTime = Date(timeIntervalSince1970: 1_779_192_000)
    /// Fixed test clock: 2026-09-09T12:00:00Z.
    static let testClock = Date(timeIntervalSince1970: 1_788_868_800)
}

// MARK: — Comparable snapshot of a persistent store

/// A sorted, Codable value record of everything in a store. Comparing two of
/// these is how a test proves that reopening, migrating or replaying changed
/// nothing. It deliberately holds no live model references.
struct StoreSnapshot: Codable, Equatable {

    struct TransactionRecord: Codable, Equatable {
        var id: String
        var userId: String
        var type: String
        var originalAmount: String      // decimal text, so a Double epsilon can never hide a change
        var originalCurrency: String
        var amountInBase: String
        var baseCurrency: String
        var rateAtTime: String
        var categoryName: String
        var merchant: String
        var note: String
        var occurredAt: Date
        var source: String
        var confidence: String
        var rawInput: String
        var walletName: String
        var linkedMessageID: String?
        var isSynced: Bool
    }

    struct WalletRecord: Codable, Equatable {
        var id: String
        var userId: String
        var name: String
        var type: String
        var currency: String
        var balance: String
        var icon: String
        var isSynced: Bool
    }

    struct CategoryRecord: Codable, Equatable {
        var id: String
        var name: String
        var icon: String
        var colorHex: String
        var type: String
        var isDefault: Bool
        var sortOrder: Int
    }

    struct MessageRecord: Codable, Equatable {
        var id: String
        var role: String
        var content: String
        var linkedTransactionID: String?
        var isSystemMessage: Bool
        var hasImage: Bool
    }

    struct SettingsRecord: Codable, Equatable {
        var language: String
        var baseCurrency: String
        var displayCurrency: String
        var userName: String
    }

    var transactions: [TransactionRecord]
    var wallets: [WalletRecord]
    var categories: [CategoryRecord]
    var messages: [MessageRecord]
    var settings: [SettingsRecord]

    // Convenience projections used by migration assertions.
    var transactionIDs: [String] { transactions.map(\.id) }
    var originalAmounts: [String] { transactions.map(\.originalAmount) }
    var walletBalances: [String: String] {
        Dictionary(uniqueKeysWithValues: wallets.map { ($0.id, $0.balance) })
    }
}

// MARK: — Isolated file-backed store

/// An isolated, **file-backed** SwiftData store in its own temporary directory.
///
/// File-backed rather than in-memory on purpose: this plan's claims are about
/// what survives a close and reopen, and an in-memory container cannot prove
/// that. `destroy()` removes only this fixture's own directory.
final class PersistentStoreFixture {

    let directory: URL
    let storeURL: URL
    private(set) var container: ModelContainer
    private var schema: Schema
    private var migrationPlan: (any SchemaMigrationPlan.Type)?

    /// The schema the app itself uses.
    static let schema = Schema(versionedSchema: SumItSchemaV2.self)
    /// The frozen shapes the shipped app wrote before the ledger work.
    static let schemaV1 = Schema(versionedSchema: SumItSchemaV1.self)

    init(schema: Schema = PersistentStoreFixture.schema,
         migrationPlan: (any SchemaMigrationPlan.Type)? = nil) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sumit-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("baseline.store")
        self.schema = schema
        self.migrationPlan = migrationPlan
        container = try Self.openContainer(at: storeURL, schema: schema, migrationPlan: migrationPlan)
    }

    private static func openContainer(at url: URL, schema: Schema,
                                      migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: url)
        if let migrationPlan {
            return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration)
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Drops the container and opens the same files again. Everything asserted
    /// after this call is proved to be on disk.
    func closeAndReopen() throws {
        container = try Self.openContainer(at: storeURL, schema: schema, migrationPlan: migrationPlan)
    }

    /// Reopens the same files under a different schema, the way an app update
    /// meets a store written by the previous version.
    func reopen(schema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.schema = schema
        self.migrationPlan = migrationPlan
        container = try Self.openContainer(at: storeURL, schema: schema, migrationPlan: migrationPlan)
    }

    /// Runs the real V1 → V2 migration on this store.
    func upgradeToV2() throws {
        try reopen(schema: Self.schema, migrationPlan: SumItMigrationPlan.self)
    }

    func destroy() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Baseline content

    /// The V1 baseline from the plan's Task 00: a 12.50 expense, a 0.001 BTC
    /// record, two wallets, a custom category, a linked chat message, an
    /// unsynced row and settings. Amounts are the values the app stores today
    /// (`Double`), because this fixture represents the **pre-migration** shape.
    @MainActor
    static func makeBaseline() throws -> PersistentStoreFixture {
        let fixture = try PersistentStoreFixture()
        let context = ModelContext(fixture.container)

        let walletA = Wallet(userId: LedgerIDs.ownerA, name: "Monobank", type: .bank,
                             currency: "USD", balance: 1000)
        walletA.id = LedgerIDs.walletA
        walletA.isSynced = true

        let walletBTC = Wallet(userId: LedgerIDs.ownerA, name: "Binance", type: .exchange,
                               currency: "BTC", balance: 0.01)
        walletBTC.id = LedgerIDs.walletBTC
        walletBTC.isSynced = false          // the unsynced row

        let message = ChatMessage(role: .assistant, content: "Saved", isSystemMessage: false)
        message.id = LedgerIDs.linkedMessage

        let expense = Transaction(userId: LedgerIDs.ownerA, type: .expense,
                                  originalAmount: 12.50, originalCurrency: "USD",
                                  amountInBase: 12.50, rateAtTime: 1.0,
                                  categoryName: "Food", merchant: "Cafe",
                                  occurredAt: LedgerIDs.eventTime, walletName: "Monobank",
                                  linkedMessageID: LedgerIDs.linkedMessage, isSynced: true)
        expense.id = LedgerIDs.expense
        expense.createdAt = LedgerIDs.eventTime

        let crypto = Transaction(userId: LedgerIDs.ownerA, type: .expense,
                                 originalAmount: 0.001, originalCurrency: "BTC",
                                 amountInBase: 100.0, rateAtTime: 100_000,
                                 categoryName: "Other", merchant: "Ledger",
                                 occurredAt: LedgerIDs.eventTime, walletName: "Binance",
                                 isSynced: false)
        crypto.id = LedgerIDs.cryptoExpense
        crypto.createdAt = LedgerIDs.eventTime

        let category = SumIt.Category(name: "Coffee", icon: "cup.and.saucer.fill",
                                colorHex: "8B5E3C", type: "expense", isDefault: false, sortOrder: 50)
        category.id = LedgerIDs.customCategory

        let settings = AppSettings()
        settings.baseCurrency = "USD"
        settings.displayCurrency = "EUR"
        settings.userName = "Fixture Owner"

        for object in [walletA, walletBTC] { context.insert(object) }
        context.insert(message)
        for object in [expense, crypto] { context.insert(object) }
        context.insert(category)
        context.insert(settings)
        try context.save()

        return fixture
    }

    // MARK: Snapshot

    /// Reads the store into a sorted value record. Throws on any read failure —
    /// a test helper must never turn a broken store into an empty result.
    @MainActor
    func snapshot() throws -> StoreSnapshot {
        let context = ModelContext(container)

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
            .map { transaction in
                StoreSnapshot.TransactionRecord(
                    id: transaction.id.uuidString.lowercased(),
                    userId: transaction.userId,
                    type: transaction.typeRaw,
                    originalAmount: Self.decimalText(transaction.originalAmount),
                    originalCurrency: transaction.originalCurrency,
                    amountInBase: Self.decimalText(transaction.amountInBase),
                    baseCurrency: transaction.baseCurrency,
                    rateAtTime: Self.decimalText(transaction.rateAtTime),
                    categoryName: transaction.categoryName,
                    merchant: transaction.merchant,
                    note: transaction.note,
                    occurredAt: transaction.occurredAt,
                    source: transaction.sourceRaw,
                    confidence: Self.decimalText(transaction.confidence),
                    rawInput: transaction.rawInput,
                    walletName: transaction.walletName,
                    linkedMessageID: transaction.linkedMessageID?.uuidString.lowercased(),
                    isSynced: transaction.isSynced)
            }
            .sorted { $0.id < $1.id }

        let wallets = try context.fetch(FetchDescriptor<Wallet>())
            .map { wallet in
                StoreSnapshot.WalletRecord(
                    id: wallet.id.uuidString.lowercased(),
                    userId: wallet.userId,
                    name: wallet.name,
                    type: wallet.typeRaw,
                    currency: wallet.currency,
                    balance: Self.decimalText(wallet.balance),
                    icon: wallet.icon,
                    isSynced: wallet.isSynced)
            }
            .sorted { $0.id < $1.id }

        let categories = try context.fetch(FetchDescriptor<SumIt.Category>())
            .map { category in
                StoreSnapshot.CategoryRecord(
                    id: category.id.uuidString.lowercased(),
                    name: category.name,
                    icon: category.icon,
                    colorHex: category.colorHex,
                    type: category.typeRaw,
                    isDefault: category.isDefault,
                    sortOrder: category.sortOrder)
            }
            .sorted { $0.id < $1.id }

        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
            .map { message in
                StoreSnapshot.MessageRecord(
                    id: message.id.uuidString.lowercased(),
                    role: message.roleRaw,
                    content: message.content,
                    linkedTransactionID: message.linkedTransactionID?.uuidString.lowercased(),
                    isSystemMessage: message.isSystemMessage,
                    hasImage: message.imageData != nil)
            }
            .sorted { $0.id < $1.id }

        let settings = try context.fetch(FetchDescriptor<AppSettings>())
            .map {
                StoreSnapshot.SettingsRecord(language: $0.language,
                                             baseCurrency: $0.baseCurrency,
                                             displayCurrency: $0.displayCurrency,
                                             userName: $0.userName)
            }
            .sorted { $0.baseCurrency < $1.baseCurrency }

        return StoreSnapshot(transactions: transactions, wallets: wallets,
                             categories: categories, messages: messages, settings: settings)
    }

    /// Exact decimal text for a stored `Double`. `Decimal(value:)` would carry
    /// the binary representation's noise; going through the shortest round-trip
    /// description keeps `12.5` as `12.5`.
    static func decimalText(_ value: Double) -> String {
        (try? MoneyCodec.encode(Decimal(string: String(value)) ?? Decimal(value))) ?? String(value)
    }
}

// MARK: — HTTP fault injection

/// URLProtocol stub for transport tests. Install it on an **ephemeral**
/// configuration so no unit test can reach the network or a real credential.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Response: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        var error: Error?

        nonisolated init(statusCode: Int = 200, headers: [String: String] = ["Content-Type": "application/json"],
             body: Data = Data("{}".utf8), error: Error? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    /// Handler receives each request and returns the response to fake.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    /// Every request the session made, for asserting what was sent.
    nonisolated(unsafe) private(set) static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// An ephemeral session that can only ever talk to this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = handler(request)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let httpResponse = HTTPURLResponse(url: request.url ?? URL(string: "https://invalid")!,
                                           statusCode: response.statusCode,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: — Version 1 baseline

extension PersistentStoreFixture {

    /// A store written by the **frozen V1 shapes**, exactly as the shipped app
    /// produced one. This is the only honest starting point for a migration
    /// test: a store created with today's models has already migrated.
    @MainActor
    static func makeVersionOneBaseline() throws -> PersistentStoreFixture {
        let fixture = try PersistentStoreFixture(schema: PersistentStoreFixture.schemaV1)
        let context = ModelContext(fixture.container)

        let walletA = SumItSchemaV1.Wallet(id: LedgerIDs.walletA, userId: LedgerIDs.ownerA,
                                           name: "Monobank", typeRaw: "bank",
                                           currency: "USD", balance: 1000,
                                           icon: "building.columns.fill", isSynced: true)
        let walletBTC = SumItSchemaV1.Wallet(id: LedgerIDs.walletBTC, userId: LedgerIDs.ownerA,
                                             name: "Binance", typeRaw: "exchange",
                                             currency: "BTC", balance: 0.01,
                                             icon: "chart.line.uptrend.xyaxis", isSynced: false)

        let message = SumItSchemaV1.ChatMessage(id: LedgerIDs.linkedMessage, roleRaw: "assistant",
                                                content: "Saved", timestamp: LedgerIDs.eventTime)

        let expense = SumItSchemaV1.Transaction(
            id: LedgerIDs.expense, userId: LedgerIDs.ownerA, typeRaw: "expense",
            originalAmount: 12.50, originalCurrency: "USD", amountInBase: 12.50,
            rateAtTime: 1.0, categoryName: "Food", merchant: "Cafe",
            occurredAt: LedgerIDs.eventTime, createdAt: LedgerIDs.eventTime,
            walletName: "Monobank", linkedMessageID: LedgerIDs.linkedMessage, isSynced: true)

        let crypto = SumItSchemaV1.Transaction(
            id: LedgerIDs.cryptoExpense, userId: LedgerIDs.ownerA, typeRaw: "expense",
            originalAmount: 0.001, originalCurrency: "BTC", amountInBase: 100.0,
            rateAtTime: 100_000, categoryName: "Other", merchant: "Ledger",
            occurredAt: LedgerIDs.eventTime, createdAt: LedgerIDs.eventTime,
            walletName: "Binance", isSynced: false)

        let category = SumItSchemaV1.Category(id: LedgerIDs.customCategory, name: "Coffee",
                                              icon: "cup.and.saucer.fill", colorHex: "8B5E3C",
                                              typeRaw: "expense", isDefault: false, sortOrder: 50)

        let settings = SumItSchemaV1.AppSettings(baseCurrency: "USD", displayCurrency: "EUR",
                                                 userName: "Fixture Owner")

        for object in [walletA, walletBTC] { context.insert(object) }
        context.insert(message)
        for object in [expense, crypto] { context.insert(object) }
        context.insert(category)
        context.insert(settings)
        try context.save()
        return fixture
    }

    /// Reads a V1 store into the same comparable record shape as `snapshot()`,
    /// so before/after can be compared across the migration boundary.
    @MainActor
    func snapshotV1() throws -> StoreSnapshot {
        let context = ModelContext(container)

        let transactions = try context.fetch(FetchDescriptor<SumItSchemaV1.Transaction>())
            .map { transaction in
                StoreSnapshot.TransactionRecord(
                    id: transaction.id.uuidString.lowercased(),
                    userId: transaction.userId,
                    type: transaction.typeRaw,
                    originalAmount: PersistentStoreFixture.decimalText(transaction.originalAmount),
                    originalCurrency: transaction.originalCurrency,
                    amountInBase: PersistentStoreFixture.decimalText(transaction.amountInBase),
                    baseCurrency: transaction.baseCurrency,
                    rateAtTime: PersistentStoreFixture.decimalText(transaction.rateAtTime),
                    categoryName: transaction.categoryName,
                    merchant: transaction.merchant,
                    note: transaction.note,
                    occurredAt: transaction.occurredAt,
                    source: transaction.sourceRaw,
                    confidence: PersistentStoreFixture.decimalText(transaction.confidence),
                    rawInput: transaction.rawInput,
                    walletName: transaction.walletName,
                    linkedMessageID: transaction.linkedMessageID?.uuidString.lowercased(),
                    isSynced: transaction.isSynced)
            }
            .sorted { $0.id < $1.id }

        let wallets = try context.fetch(FetchDescriptor<SumItSchemaV1.Wallet>())
            .map { wallet in
                StoreSnapshot.WalletRecord(
                    id: wallet.id.uuidString.lowercased(),
                    userId: wallet.userId,
                    name: wallet.name,
                    type: wallet.typeRaw,
                    currency: wallet.currency,
                    balance: PersistentStoreFixture.decimalText(wallet.balance),
                    icon: wallet.icon,
                    isSynced: wallet.isSynced)
            }
            .sorted { $0.id < $1.id }

        let categories = try context.fetch(FetchDescriptor<SumItSchemaV1.Category>())
            .map { category in
                StoreSnapshot.CategoryRecord(
                    id: category.id.uuidString.lowercased(),
                    name: category.name,
                    icon: category.icon,
                    colorHex: category.colorHex,
                    type: category.typeRaw,
                    isDefault: category.isDefault,
                    sortOrder: category.sortOrder)
            }
            .sorted { $0.id < $1.id }

        let messages = try context.fetch(FetchDescriptor<SumItSchemaV1.ChatMessage>())
            .map { message in
                StoreSnapshot.MessageRecord(
                    id: message.id.uuidString.lowercased(),
                    role: message.roleRaw,
                    content: message.content,
                    linkedTransactionID: message.linkedTransactionID?.uuidString.lowercased(),
                    isSystemMessage: message.isSystemMessage,
                    hasImage: message.imageData != nil)
            }
            .sorted { $0.id < $1.id }

        let settings = try context.fetch(FetchDescriptor<SumItSchemaV1.AppSettings>())
            .map {
                StoreSnapshot.SettingsRecord(language: $0.language,
                                             baseCurrency: $0.baseCurrency,
                                             displayCurrency: $0.displayCurrency,
                                             userName: $0.userName)
            }
            .sorted { $0.baseCurrency < $1.baseCurrency }

        return StoreSnapshot(transactions: transactions, wallets: wallets,
                             categories: categories, messages: messages, settings: settings)
    }
}

// MARK: — Draft fixtures

/// Typed drafts for the wallet, ledger-store and sync suites.
/// Every builder parses its amounts through `MoneyCodec` and **throws** on
/// invalid data, so a typo in a fixture fails loudly instead of quietly
/// becoming a different number.
enum LedgerFixtures {

    static func wallet(id: UUID, currency: String, opening: String) throws -> WalletDraft {
        WalletDraft(id: id,
                    name: "Wallet \(id.uuidString.prefix(4))",
                    type: .bank,
                    currency: currency,
                    openingBalance: try MoneyCodec.decode(opening),
                    icon: "building.columns.fill")
    }

    static func usdExpense(id: UUID, amount: String, walletID: UUID?) throws -> TransactionDraft {
        let value = try MoneyCodec.decode(amount)
        return TransactionDraft(id: id,
                                type: .expense,
                                amount: value,
                                currency: "USD",
                                walletID: walletID,
                                walletAmount: walletID == nil ? nil : value,
                                destinationWalletID: nil,
                                destinationAmount: nil,
                                categoryName: "Food",
                                merchant: "Cafe",
                                note: "",
                                occurredAt: LedgerIDs.eventTime,
                                source: .manual,
                                confidence: 1,
                                rawInput: "",
                                valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
    }

    static func transfer(id: UUID, sourceID: UUID, destinationID: UUID,
                         sourceAmount: String, destinationAmount: String) throws -> TransactionDraft {
        let source = try MoneyCodec.decode(sourceAmount)
        return TransactionDraft(id: id,
                                type: .transfer,
                                amount: source,
                                currency: "USD",
                                walletID: sourceID,
                                walletAmount: source,
                                destinationWalletID: destinationID,
                                destinationAmount: try MoneyCodec.decode(destinationAmount),
                                categoryName: "Other",
                                merchant: "",
                                note: "Synthetic transfer fixture",
                                occurredAt: LedgerIDs.eventTime,
                                source: .manual,
                                confidence: 1,
                                rawInput: "",
                                valuation: .quoted(.identity(at: LedgerIDs.eventTime)))
    }

    /// walletA and walletB, both USD, both owned by ownerA and both active.
    static var usdWalletDescriptors: [UUID: WalletDescriptor] {
        [LedgerIDs.walletA: WalletDescriptor(id: LedgerIDs.walletA, ownerID: LedgerIDs.ownerA,
                                             currency: "USD", isArchived: false),
         LedgerIDs.walletB: WalletDescriptor(id: LedgerIDs.walletB, ownerID: LedgerIDs.ownerA,
                                             currency: "USD", isArchived: false)]
    }
}
