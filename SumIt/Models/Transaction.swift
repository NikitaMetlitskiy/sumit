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

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRaw) ?? .text }
        set { sourceRaw = newValue.rawValue }
    }

    init(
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
        self.id = UUID()
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
