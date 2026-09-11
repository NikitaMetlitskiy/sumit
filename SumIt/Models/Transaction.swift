import SwiftData
import Foundation

enum TransactionType: String, Codable, CaseIterable {
    case expense  = "expense"
    case income   = "income"
    case transfer = "transfer"

    var label: String {
        switch self {
        case .expense:  return L("type_expense")
        case .income:   return L("type_income")
        case .transfer: return L("type_transfer")
        }
    }
    var sign: String { self == .income ? "+" : "-" }
}

enum TransactionSource: String, Codable {
    case text   = "text"
    case photo  = "photo"
    case manual = "manual"
}

@Model
final class Transaction {
    var id: UUID
    var userId: String
    var typeRaw: String
    var originalAmount: Double
    var originalCurrency: String
    var amountInBase: Double
    var baseCurrency: String
    var rateAtTime: Double
    var categoryName: String
    var merchant: String
    var note: String
    var occurredAt: Date
    var createdAt: Date
    var sourceRaw: String
    var confidence: Double
    var rawInput: String
    var walletName: String          // "Binance", "Monobank", "Cash", ""
    var linkedMessageID: UUID?      // for delete sync
    var isSynced: Bool              // false = needs upload to Supabase

    // MARK: — Ledger V2 (additive; the Double fields above stay as written)
    /// Canonical decimal string of the original quantity. Authoritative once set;
    /// `originalAmount` is kept as a compatibility mirror for untouched callers.
    var amountExact: String?
    /// Booked USD value, and USD per one original unit, as canonical strings.
    var baseAmountExact: String?
    var rateExact: String?
    /// Stable wallet relationships. Names are labels; these are the identity.
    var walletID: UUID?
    var destinationWalletID: UUID?
    /// Frozen effect on each wallet, in that wallet's own currency.
    var walletAmountExact: String?
    var destinationAmountExact: String?
    /// Encoded `RateQuote`: where this valuation came from and when.
    var quoteJSON: Data?
    var valuationStateRaw: String = ValuationState.legacyUnverified.rawValue
    /// Last revision the server acknowledged for this row.
    var serverRevision: Int64 = 0
    /// Bumped by every local command, so an acknowledgment can tell whether the
    /// row still holds the version the server accepted.
    var localGeneration: Int64 = 0
    /// Tombstone. Deletion is a persisted fact, not an immediate erase.
    var deletedAt: Date?
    /// Whether this row has been through adoption or is still a pre-ledger record.
    var migrationStateRaw: String = LedgerMigrationState.legacy.rawValue

    var valuationState: ValuationState {
        get { ValuationState(rawValue: valuationStateRaw) ?? .legacyUnverified }
        set { valuationStateRaw = newValue.rawValue }
    }
    var migrationState: LedgerMigrationState {
        get { LedgerMigrationState(rawValue: migrationStateRaw) ?? .legacy }
        set { migrationStateRaw = newValue.rawValue }
    }
    var isActive: Bool { deletedAt == nil }

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRaw) ?? .text }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        userId: String = "local",
        type: TransactionType = .expense,
        originalAmount: Double,
        originalCurrency: String,
        amountInBase: Double,
        baseCurrency: String = "USD",
        rateAtTime: Double,
        categoryName: String,
        merchant: String,
        note: String = "",
        occurredAt: Date = .now,
        source: TransactionSource = .text,
        confidence: Double = 1.0,
        rawInput: String = "",
        walletName: String = "",
        linkedMessageID: UUID? = nil,
        isSynced: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.typeRaw = type.rawValue
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.amountInBase = amountInBase
        self.baseCurrency = baseCurrency
        self.rateAtTime = rateAtTime
        self.categoryName = categoryName
        self.merchant = merchant
        self.note = note
        self.occurredAt = occurredAt
        self.createdAt = .now
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.rawInput = rawInput
        self.walletName = walletName
        self.linkedMessageID = linkedMessageID
        self.isSynced = isSynced
    }
}
