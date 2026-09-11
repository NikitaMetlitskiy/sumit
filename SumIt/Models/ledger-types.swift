import Foundation

// MARK: — Account scope

/// Identifies whose data an operation belongs to. The epoch changes on every
/// sign-in, sign-out and user switch, so a response that comes back after the
/// account changed can be recognised and discarded instead of being applied to
/// the new account.
struct AccountScope: Equatable, Sendable {
    let ownerID: String
    let epoch: UUID

    /// The device-only dataset used before sign-in. It is never dispatched to
    /// Supabase and never silently adopted by whoever signs in next.
    static let localOwnerID = "local"
    var isLocalOnly: Bool { ownerID == Self.localOwnerID }
}

// MARK: — Enumerations shared by storage and the wire

enum LedgerEntityKind: String, Codable, Sendable, CaseIterable {
    case transaction, wallet, category
}

enum LedgerAction: String, Codable, Sendable, CaseIterable {
    case put, delete
}

/// Whether a transaction's USD value is known, absent, or inherited from the
/// pre-ledger app and therefore not verifiable.
enum ValuationState: String, Codable, Sendable, CaseIterable {
    case unvalued
    case valued
    case legacyUnverified = "legacy_unverified"
}

/// Whether a row has been through adoption or is still an unreconciled record
/// from before the ledger protocol.
enum LedgerMigrationState: String, Codable, Sendable, CaseIterable {
    case legacy
    case adopted
}

/// How a rate was arrived at. `identity` is USD at rate 1; `manual` is a rate
/// the user confirmed; the two reference kinds come from a provider quote.
enum ValuationKind: String, Codable, Sendable, CaseIterable {
    case identity
    case manual
    case currentReference = "current_reference"
    case historicalReference = "historical_reference"
}

// MARK: — Rate quote

/// A dated exchange rate with its provenance. The same shape is used locally,
/// by `/api/rates` and inside remote snapshots.
struct RateQuote: Equatable, Sendable {
    /// Server-issued identifier of the immutable cache row. Absent for identity
    /// and manual quotes, required for provider quotes.
    var id: UUID?
    var currency: String
    /// Canonical decimal string: USD per one unit of `currency`.
    var usdPerUnit: String
    /// ISO day the valuation was requested for, if this is a historical quote.
    var requestedDate: String?
    var effectiveAt: Date
    var fetchedAt: Date
    var source: String
    /// Provider metadata. Travels as a JSON **object**, never as base64.
    var sourceDetail: JSONValue
    var valuationKind: ValuationKind
    var isStale: Bool

    /// The only valuation that needs no provider: USD priced in USD.
    static func identity(at date: Date) -> RateQuote {
        RateQuote(id: nil, currency: "USD", usdPerUnit: "1", requestedDate: nil,
                  effectiveAt: date, fetchedAt: date, source: "identity",
                  sourceDetail: .object([:]), valuationKind: .identity, isStale: false)
    }
}

extension RateQuote: Codable {
    private enum CodingKeys: String, CodingKey {
        case id = "quote_id"
        case currency
        case usdPerUnit = "usd_per_unit"
        case requestedDate = "requested_date"
        case effectiveAt = "effective_at"
        case fetchedAt = "fetched_at"
        case source
        case sourceDetail = "source_detail"
        case valuationKind = "valuation_kind"
        case isStale = "stale"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        currency = try container.decode(String.self, forKey: .currency)
        usdPerUnit = try LedgerCoding.decodeCanonicalDecimal(container, .usdPerUnit)
        requestedDate = try container.decodeIfPresent(String.self, forKey: .requestedDate)
        effectiveAt = try LedgerCoding.decodeDate(container, .effectiveAt)
        fetchedAt = try LedgerCoding.decodeDate(container, .fetchedAt)
        source = try container.decode(String.self, forKey: .source)
        sourceDetail = try container.decodeIfPresent(JSONValue.self, forKey: .sourceDetail) ?? .object([:])
        valuationKind = try container.decode(ValuationKind.self, forKey: .valuationKind)
        isStale = try container.decode(Bool.self, forKey: .isStale)

        // A provider quote without its persisted cache row cannot be verified.
        if valuationKind == .currentReference || valuationKind == .historicalReference {
            guard id != nil else {
                throw LedgerCodingError.missingProviderQuoteID
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)          // explicit null, not omitted
        try container.encode(currency, forKey: .currency)
        try container.encode(usdPerUnit, forKey: .usdPerUnit)
        try container.encode(requestedDate, forKey: .requestedDate)
        try container.encode(LedgerCoding.string(from: effectiveAt), forKey: .effectiveAt)
        try container.encode(LedgerCoding.string(from: fetchedAt), forKey: .fetchedAt)
        try container.encode(source, forKey: .source)
        try container.encode(sourceDetail, forKey: .sourceDetail)
        try container.encode(valuationKind, forKey: .valuationKind)
        try container.encode(isStale, forKey: .isStale)
    }
}

/// Whether and how a transaction's USD value is established.
enum LedgerValuation: Equatable, Sendable {
    case unvalued
    case quoted(RateQuote)
    /// Numbers inherited from before the ledger protocol. Preserved exactly,
    /// never presented as a verified valuation.
    case legacyUnverified(baseAmount: Decimal?, rate: Decimal?)

    var state: ValuationState {
        switch self {
        case .unvalued:         return .unvalued
        case .quoted:           return .valued
        case .legacyUnverified: return .legacyUnverified
        }
    }
    var quote: RateQuote? {
        if case .quoted(let quote) = self { return quote }
        return nil
    }
}

// MARK: — Drafts

/// A transaction as the user intends it, before it is applied to the store.
/// Editors hold one of these, never a partially mutated live SwiftData object.
struct TransactionDraft: Sendable, Equatable {
    let id: UUID
    var type: TransactionType
    var amount: Decimal
    var currency: String
    var walletID: UUID?
    var walletAmount: Decimal?
    var destinationWalletID: UUID?
    var destinationAmount: Decimal?
    var categoryName: String
    var merchant: String
    var note: String
    var occurredAt: Date
    var source: TransactionSource
    var confidence: Decimal
    var rawInput: String
    var valuation: LedgerValuation
}

struct WalletDraft: Sendable, Equatable {
    let id: UUID
    var name: String
    var type: WalletType
    var currency: String
    /// The balance a wallet started from. Current balance is derived, never entered.
    var openingBalance: Decimal
    var icon: String
}

struct CategoryDraft: Sendable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var type: String
    var sortOrder: Int
}

// MARK: — Command results

/// Proof that a local command reached disk. Returned only after a successful
/// save, so a caller can never mistake a failure for a success.
struct LocalSaveReceipt: Equatable, Sendable {
    let entityID: UUID
    let operationID: UUID
    let generation: Int64
}

/// The parts of a wallet a calculation needs, with no live model reference.
struct WalletDescriptor: Sendable, Equatable {
    let id: UUID
    let ownerID: String
    let currency: String
    let isArchived: Bool
}

/// One signed effect a transaction has on one wallet, in that wallet's currency.
struct WalletEffect: Equatable, Sendable {
    let walletID: UUID
    let signedAmount: Decimal
}

// MARK: — Cursors and revisions

/// A server cursor or entity revision. Nonnegative, bounded, and carried on the
/// wire as a decimal **string** so no JSON parser can coerce it into a float.
struct LedgerCursor: Codable, Equatable, Comparable, Sendable {
    let value: Int64

    init(_ value: Int64) throws {
        guard value >= 0 else { throw LedgerCodingError.cursorOutOfRange }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw LedgerCodingError.malformedCursor
        }
        guard let parsed = Int64(text), parsed >= 0 else {
            throw LedgerCodingError.cursorOutOfRange
        }
        self.value = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }

    static let zero = LedgerCursor(unchecked: 0)
    private init(unchecked value: Int64) { self.value = value }
    static func < (lhs: LedgerCursor, rhs: LedgerCursor) -> Bool { lhs.value < rhs.value }
}

// MARK: — Coding errors and helpers

enum LedgerCodingError: Error, Equatable {
    case malformedCursor
    case cursorOutOfRange
    case malformedDecimal(field: String)
    case malformedDate(field: String)
    case unknownEntityKind(String)
    case unknownAction(String)
    case missingProviderQuoteID
    case unexpectedStatus(String)
}

enum LedgerCoding {
    /// ISO 8601 with an explicit timezone, matching the wire contract.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from text: String) -> Date? {
        formatter.date(from: text) ?? fractionalFormatter.date(from: text)
    }

    static func decodeDate<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
        let text = try container.decode(String.self, forKey: key)
        guard let value = date(from: text) else {
            // A malformed historic date is an issue to surface, never `.now`.
            throw LedgerCodingError.malformedDate(field: key.stringValue)
        }
        return value
    }

    static func decodeOptionalDate<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = date(from: text) else {
            throw LedgerCodingError.malformedDate(field: key.stringValue)
        }
        return value
    }

    /// Decodes a monetary string and proves it is canonical before accepting it.
    static func decodeCanonicalDecimal<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> String {
        let text = try container.decode(String.self, forKey: key)
        guard (try? MoneyCodec.decode(text)) != nil else {
            throw LedgerCodingError.malformedDecimal(field: key.stringValue)
        }
        return text
    }

    static func decodeOptionalCanonicalDecimal<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard (try? MoneyCodec.decode(text)) != nil else {
            throw LedgerCodingError.malformedDecimal(field: key.stringValue)
        }
        return text
    }
}

// MARK: — JSON value

/// A JSON value carried verbatim. Used for provider metadata so `source_detail`
/// reaches the wire as an object rather than as an accidental base64 blob.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Decimal.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let value):   try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value):  try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: — Wire records (request bodies)

/// The transaction fields a `put` carries. Header fields (identity, owner,
/// revision, timestamps) are not part of the record: the server owns them.
struct TransactionRecordV1: Codable, Equatable, Sendable {
    var type: String
    var originalAmount: String
    var originalCurrency: String
    var walletID: UUID?
    var walletAmount: String?
    var destinationWalletID: UUID?
    var destinationAmount: String?
    var categoryName: String
    var merchant: String
    var note: String
    var occurredAt: Date
    var source: String
    var confidence: String
    var rawInput: String
    var baseAmount: String?
    var usdPerUnit: String?
    var valuationState: ValuationState
    var quote: RateQuote?

    enum CodingKeys: String, CodingKey {
        case type
        case originalAmount = "original_amount"
        case originalCurrency = "original_currency"
        case walletID = "wallet_id"
        case walletAmount = "wallet_amount"
        case destinationWalletID = "destination_wallet_id"
        case destinationAmount = "destination_amount"
        case categoryName = "category_name"
        case merchant, note
        case occurredAt = "occurred_at"
        case source, confidence
        case rawInput = "raw_input"
        case baseAmount = "base_amount"
        case usdPerUnit = "usd_per_unit"
        case valuationState = "valuation_state"
        case quote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        originalAmount = try LedgerCoding.decodeCanonicalDecimal(container, .originalAmount)
        originalCurrency = try container.decode(String.self, forKey: .originalCurrency)
        walletID = try container.decodeIfPresent(UUID.self, forKey: .walletID)
        walletAmount = try LedgerCoding.decodeOptionalCanonicalDecimal(container, .walletAmount)
        destinationWalletID = try container.decodeIfPresent(UUID.self, forKey: .destinationWalletID)
        destinationAmount = try LedgerCoding.decodeOptionalCanonicalDecimal(container, .destinationAmount)
        categoryName = try container.decode(String.self, forKey: .categoryName)
        merchant = try container.decode(String.self, forKey: .merchant)
        note = try container.decode(String.self, forKey: .note)
        occurredAt = try LedgerCoding.decodeDate(container, .occurredAt)
        source = try container.decode(String.self, forKey: .source)
        confidence = try LedgerCoding.decodeCanonicalDecimal(container, .confidence)
        rawInput = try container.decode(String.self, forKey: .rawInput)
        baseAmount = try LedgerCoding.decodeOptionalCanonicalDecimal(container, .baseAmount)
        usdPerUnit = try LedgerCoding.decodeOptionalCanonicalDecimal(container, .usdPerUnit)
        valuationState = try container.decode(ValuationState.self, forKey: .valuationState)
        quote = try container.decodeIfPresent(RateQuote.self, forKey: .quote)
    }

    init(type: String, originalAmount: String, originalCurrency: String,
         walletID: UUID?, walletAmount: String?, destinationWalletID: UUID?, destinationAmount: String?,
         categoryName: String, merchant: String, note: String, occurredAt: Date,
         source: String, confidence: String, rawInput: String,
         baseAmount: String?, usdPerUnit: String?, valuationState: ValuationState, quote: RateQuote?) {
        self.type = type
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.walletID = walletID
        self.walletAmount = walletAmount
        self.destinationWalletID = destinationWalletID
        self.destinationAmount = destinationAmount
        self.categoryName = categoryName
        self.merchant = merchant
        self.note = note
        self.occurredAt = occurredAt
        self.source = source
        self.confidence = confidence
        self.rawInput = rawInput
        self.baseAmount = baseAmount
        self.usdPerUnit = usdPerUnit
        self.valuationState = valuationState
        self.quote = quote
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(originalAmount, forKey: .originalAmount)
        try container.encode(originalCurrency, forKey: .originalCurrency)
        try container.encode(walletID, forKey: .walletID)
        try container.encode(walletAmount, forKey: .walletAmount)
        try container.encode(destinationWalletID, forKey: .destinationWalletID)
        try container.encode(destinationAmount, forKey: .destinationAmount)
        try container.encode(categoryName, forKey: .categoryName)
        try container.encode(merchant, forKey: .merchant)
        try container.encode(note, forKey: .note)
        try container.encode(LedgerCoding.string(from: occurredAt), forKey: .occurredAt)
        try container.encode(source, forKey: .source)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(rawInput, forKey: .rawInput)
        try container.encode(baseAmount, forKey: .baseAmount)
        try container.encode(usdPerUnit, forKey: .usdPerUnit)
        try container.encode(valuationState, forKey: .valuationState)
        try container.encode(quote, forKey: .quote)
    }
}

struct WalletRecordV1: Codable, Equatable, Sendable {
    var name: String
    var type: String
    var currency: String
    /// Signed canonical string: a negative opening balance is a debt balance.
    var openingBalance: String
    var icon: String

    enum CodingKeys: String, CodingKey {
        case name, type, currency, icon
        case openingBalance = "opening_balance"
    }

    init(name: String, type: String, currency: String, openingBalance: String, icon: String) {
        self.name = name; self.type = type; self.currency = currency
        self.openingBalance = openingBalance; self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        currency = try container.decode(String.self, forKey: .currency)
        openingBalance = try LedgerCoding.decodeCanonicalDecimal(container, .openingBalance)
        icon = try container.decode(String.self, forKey: .icon)
    }
}

struct CategoryRecordV1: Codable, Equatable, Sendable {
    var name: String
    var icon: String
    var colorHex: String
    var type: String
    var sortOrder: Int
    /// A user cannot claim a custom row is a bundled default.
    var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case name, icon, type
        case colorHex = "color_hex"
        case sortOrder = "sort_order"
        case isDefault = "is_default"
    }
}

/// The record a request carries, chosen by the request's `entity_kind`.
/// It encodes as the bare payload object; the tag lives at the top level.
enum LedgerRecord: Equatable, Sendable {
    case transaction(TransactionRecordV1)
    case wallet(WalletRecordV1)
    case category(CategoryRecordV1)

    var kind: LedgerEntityKind {
        switch self {
        case .transaction: return .transaction
        case .wallet:      return .wallet
        case .category:    return .category
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .transaction(let record): try record.encode(to: encoder)
        case .wallet(let record):      try record.encode(to: encoder)
        case .category(let record):    try record.encode(to: encoder)
        }
    }

    static func decode(kind: LedgerEntityKind, from decoder: Decoder) throws -> LedgerRecord {
        switch kind {
        case .transaction: return .transaction(try TransactionRecordV1(from: decoder))
        case .wallet:      return .wallet(try WalletRecordV1(from: decoder))
        case .category:    return .category(try CategoryRecordV1(from: decoder))
        }
    }
}

// MARK: — Mutation request

/// One immutable command. Once dispatch begins these bytes are frozen: a retry
/// replays the identical payload under the identical operation ID, which is
/// what makes the server's receipt able to answer "did my write land?".
struct LedgerMutationRequest: Equatable, Sendable {
    var protocolVersion: Int = 1
    var operationID: UUID
    var entityKind: LedgerEntityKind
    var entityID: UUID
    var action: LedgerAction
    var expectedRevision: LedgerCursor
    /// Absent for `delete`: a delete targets an identity and revision, not a body.
    var record: LedgerRecord?
}

extension LedgerMutationRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case entityKind = "entity_kind"
        case entityID = "entity_id"
        case action
        case expectedRevision = "expected_revision"
        case record
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        operationID = try container.decode(UUID.self, forKey: .operationID)

        let kindText = try container.decode(String.self, forKey: .entityKind)
        guard let kind = LedgerEntityKind(rawValue: kindText) else {
            throw LedgerCodingError.unknownEntityKind(kindText)
        }
        entityKind = kind

        entityID = try container.decode(UUID.self, forKey: .entityID)

        let actionText = try container.decode(String.self, forKey: .action)
        guard let action = LedgerAction(rawValue: actionText) else {
            throw LedgerCodingError.unknownAction(actionText)
        }
        self.action = action

        expectedRevision = try container.decode(LedgerCursor.self, forKey: .expectedRevision)

        if container.contains(.record), try !container.decodeNil(forKey: .record) {
            record = try LedgerRecord.decode(kind: kind,
                                             from: try container.superDecoder(forKey: .record))
        } else {
            record = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(entityKind, forKey: .entityKind)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(action, forKey: .action)
        try container.encode(expectedRevision, forKey: .expectedRevision)
        if let record {
            try record.encode(to: container.superEncoder(forKey: .record))
        }
    }
}

// MARK: — Snapshots

/// Fields every snapshot carries, whatever the entity is.
struct LedgerSnapshotHeader: Equatable, Sendable {
    var entityKind: LedgerEntityKind
    var localID: UUID
    var userID: String
    var ledgerRevision: LedgerCursor
    var deletedAt: Date?
    var ledgerVersion: Int

    /// A tombstone still carries its identity and revision.
    var isDeleted: Bool { deletedAt != nil }
}

struct TransactionSnapshotV1: Equatable, Sendable {
    var header: LedgerSnapshotHeader
    var record: TransactionRecordV1
    var createdAt: Date
    /// Kept only as display provenance while legacy rows are being adopted.
    var legacyWalletName: String?
}

struct WalletSnapshotV1: Equatable, Sendable {
    var header: LedgerSnapshotHeader
    var record: WalletRecordV1
    var createdAt: Date
}

struct CategorySnapshotV1: Equatable, Sendable {
    var header: LedgerSnapshotHeader
    var record: CategoryRecordV1
    /// Optional on purpose: the DTO inventory lists `created_at` for
    /// transaction and wallet snapshots but not for category, and production's
    /// `public.categories` genuinely has no such column.
    var createdAt: Date?
}

/// A snapshot of whichever entity the change concerns. Decoding is driven by
/// `entity_kind`; an unrecognised tag is an error, never a defaulted expense.
enum LedgerSnapshot: Equatable, Sendable {
    case transaction(TransactionSnapshotV1)
    case wallet(WalletSnapshotV1)
    case category(CategorySnapshotV1)

    var header: LedgerSnapshotHeader {
        switch self {
        case .transaction(let value): return value.header
        case .wallet(let value):      return value.header
        case .category(let value):    return value.header
        }
    }
}

extension LedgerSnapshot: Codable {
    private enum HeaderKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case localID = "local_id"
        case userID = "user_id"
        case ledgerRevision = "ledger_revision"
        case deletedAt = "deleted_at"
        case ledgerVersion = "ledger_version"
        case createdAt = "created_at"
        case walletName = "wallet_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HeaderKeys.self)
        let kindText = try container.decode(String.self, forKey: .entityKind)
        guard let kind = LedgerEntityKind(rawValue: kindText) else {
            throw LedgerCodingError.unknownEntityKind(kindText)
        }
        let header = LedgerSnapshotHeader(
            entityKind: kind,
            localID: try container.decode(UUID.self, forKey: .localID),
            userID: try container.decode(String.self, forKey: .userID),
            ledgerRevision: try container.decode(LedgerCursor.self, forKey: .ledgerRevision),
            deletedAt: try LedgerCoding.decodeOptionalDate(container, .deletedAt),
            ledgerVersion: try container.decode(Int.self, forKey: .ledgerVersion))
        switch kind {
        case .transaction:
            self = .transaction(TransactionSnapshotV1(
                header: header,
                record: try TransactionRecordV1(from: decoder),
                createdAt: try LedgerCoding.decodeDate(container, .createdAt),
                legacyWalletName: try container.decodeIfPresent(String.self, forKey: .walletName)))
        case .wallet:
            self = .wallet(WalletSnapshotV1(header: header,
                                            record: try WalletRecordV1(from: decoder),
                                            createdAt: try LedgerCoding.decodeDate(container, .createdAt)))
        case .category:
            self = .category(CategorySnapshotV1(header: header,
                                                record: try CategoryRecordV1(from: decoder),
                                                createdAt: try LedgerCoding.decodeOptionalDate(container, .createdAt)))
        }
    }

    func encode(to encoder: Encoder) throws {
        let header = self.header
        var container = encoder.container(keyedBy: HeaderKeys.self)
        try container.encode(header.entityKind, forKey: .entityKind)
        try container.encode(header.localID, forKey: .localID)
        try container.encode(header.userID, forKey: .userID)
        try container.encode(header.ledgerRevision, forKey: .ledgerRevision)
        try container.encode(header.deletedAt.map(LedgerCoding.string(from:)), forKey: .deletedAt)
        try container.encode(header.ledgerVersion, forKey: .ledgerVersion)

        switch self {
        case .transaction(let value):
            try container.encode(LedgerCoding.string(from: value.createdAt), forKey: .createdAt)
            try container.encodeIfPresent(value.legacyWalletName, forKey: .walletName)
            try value.record.encode(to: encoder)
        case .wallet(let value):
            try container.encode(LedgerCoding.string(from: value.createdAt), forKey: .createdAt)
            try value.record.encode(to: encoder)
        case .category(let value):
            try container.encode(value.createdAt.map(LedgerCoding.string(from:)), forKey: .createdAt)
            try value.record.encode(to: encoder)
        }
    }
}

// MARK: — Mutation result

/// What the server said about one mutation. A conflict arrives as an ordinary
/// HTTP success with `status: "conflict"`, so it is a domain outcome the client
/// must handle, not a transport error to retry blindly.
enum LedgerMutationResult: Equatable, Sendable {
    case accepted(Accepted)
    case conflict(Conflict)

    struct Accepted: Equatable, Sendable {
        var operationID: UUID
        var entityID: UUID
        var revision: LedgerCursor
        var cursor: LedgerCursor
        var snapshot: LedgerSnapshot
    }

    struct Conflict: Equatable, Sendable {
        var operationID: UUID
        var entityID: UUID
        var expectedRevision: LedgerCursor
        var actualRevision: LedgerCursor
        var reason: String
        var serverSnapshot: LedgerSnapshot?
    }

    var operationID: UUID {
        switch self {
        case .accepted(let value): return value.operationID
        case .conflict(let value): return value.operationID
        }
    }
}

extension LedgerMutationResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status
        case operationID = "operation_id"
        case entityID = "entity_id"
        case revision, cursor, snapshot, reason
        case expectedRevision = "expected_revision"
        case actualRevision = "actual_revision"
        case serverSnapshot = "server_snapshot"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "accepted":
            self = .accepted(Accepted(
                operationID: try container.decode(UUID.self, forKey: .operationID),
                entityID: try container.decode(UUID.self, forKey: .entityID),
                revision: try container.decode(LedgerCursor.self, forKey: .revision),
                cursor: try container.decode(LedgerCursor.self, forKey: .cursor),
                snapshot: try container.decode(LedgerSnapshot.self, forKey: .snapshot)))
        case "conflict":
            self = .conflict(Conflict(
                operationID: try container.decode(UUID.self, forKey: .operationID),
                entityID: try container.decode(UUID.self, forKey: .entityID),
                expectedRevision: try container.decode(LedgerCursor.self, forKey: .expectedRevision),
                actualRevision: try container.decode(LedgerCursor.self, forKey: .actualRevision),
                reason: try container.decode(String.self, forKey: .reason),
                serverSnapshot: try container.decodeIfPresent(LedgerSnapshot.self, forKey: .serverSnapshot)))
        default:
            // An unrecognised status is an unknown outcome, never an acceptance.
            throw LedgerCodingError.unexpectedStatus(status)
        }
    }
}

// MARK: — Change feed

struct LedgerChange: Decodable, Equatable, Sendable {
    var cursor: LedgerCursor
    var operationID: UUID?
    var entityKind: LedgerEntityKind
    var entityID: UUID
    var snapshot: LedgerSnapshot

    private enum CodingKeys: String, CodingKey {
        case cursor
        case operationID = "operation_id"
        case entityKind = "entity_kind"
        case entityID = "entity_id"
        case snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(LedgerCursor.self, forKey: .cursor)
        operationID = try container.decodeIfPresent(UUID.self, forKey: .operationID)
        let kindText = try container.decode(String.self, forKey: .entityKind)
        guard let kind = LedgerEntityKind(rawValue: kindText) else {
            throw LedgerCodingError.unknownEntityKind(kindText)
        }
        entityKind = kind
        entityID = try container.decode(UUID.self, forKey: .entityID)
        snapshot = try container.decode(LedgerSnapshot.self, forKey: .snapshot)
    }
}

/// One bounded page of the owner's change feed. `throughCursor` is fixed for
/// the whole run so a pull cannot chase a moving target.
struct LedgerChangePage: Decodable, Equatable, Sendable {
    var throughCursor: LedgerCursor
    var nextCursor: LedgerCursor
    var hasMore: Bool
    var changes: [LedgerChange]

    private enum CodingKeys: String, CodingKey {
        case throughCursor = "through_cursor"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case changes
    }
}
