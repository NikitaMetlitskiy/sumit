import Foundation
import SwiftData
import SwiftUI

/// Versioned SwiftData schemas and the migration between them.
///
/// V1 is a **frozen copy** of the five model shapes as the shipped app wrote
/// them. It exists so a test can create a store exactly the way a real user's
/// device did, and then prove that opening it under V2 preserves every
/// identity and value. Without a frozen copy there is nothing to migrate
/// *from*, and "migration works" would be an assumption rather than a result.
///
/// Do not edit V1 again. A future change adds V3.
enum SumItSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Transaction.self, Category.self, ChatMessage.self, AppSettings.self, Wallet.self]
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
        var walletName: String
        var linkedMessageID: UUID?
        var isSynced: Bool

        init(id: UUID = UUID(), userId: String = "local", typeRaw: String = "expense",
             originalAmount: Double, originalCurrency: String, amountInBase: Double,
             baseCurrency: String = "USD", rateAtTime: Double, categoryName: String,
             merchant: String, note: String = "", occurredAt: Date = .now,
             createdAt: Date = .now, sourceRaw: String = "text", confidence: Double = 1.0,
             rawInput: String = "", walletName: String = "",
             linkedMessageID: UUID? = nil, isSynced: Bool = false) {
            self.id = id
            self.userId = userId
            self.typeRaw = typeRaw
            self.originalAmount = originalAmount
            self.originalCurrency = originalCurrency
            self.amountInBase = amountInBase
            self.baseCurrency = baseCurrency
            self.rateAtTime = rateAtTime
            self.categoryName = categoryName
            self.merchant = merchant
            self.note = note
            self.occurredAt = occurredAt
            self.createdAt = createdAt
            self.sourceRaw = sourceRaw
            self.confidence = confidence
            self.rawInput = rawInput
            self.walletName = walletName
            self.linkedMessageID = linkedMessageID
            self.isSynced = isSynced
        }
    }

    @Model
    final class Wallet {
        var id: UUID
        var userId: String
        var name: String
        var typeRaw: String
        var currency: String
        var balance: Double
        var icon: String
        var createdAt: Date
        var isSynced: Bool

        init(id: UUID = UUID(), userId: String = "local", name: String, typeRaw: String = "bank",
             currency: String = "UAH", balance: Double = 0, icon: String = "",
             createdAt: Date = .now, isSynced: Bool = false) {
            self.id = id
            self.userId = userId
            self.name = name
            self.typeRaw = typeRaw
            self.currency = currency
            self.balance = balance
            self.icon = icon
            self.createdAt = createdAt
            self.isSynced = isSynced
        }
    }

    @Model
    final class Category {
        var id: UUID
        var name: String
        var icon: String
        var colorHex: String
        var typeRaw: String
        var isDefault: Bool
        var sortOrder: Int

        init(id: UUID = UUID(), name: String, icon: String, colorHex: String,
             typeRaw: String = "expense", isDefault: Bool = false, sortOrder: Int = 99) {
            self.id = id
            self.name = name
            self.icon = icon
            self.colorHex = colorHex
            self.typeRaw = typeRaw
            self.isDefault = isDefault
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class ChatMessage {
        var id: UUID
        var roleRaw: String
        var content: String
        var timestamp: Date
        var linkedTransactionID: UUID?
        var isSystemMessage: Bool
        var imageData: Data?

        init(id: UUID = UUID(), roleRaw: String, content: String, timestamp: Date = .now,
             linkedTransactionID: UUID? = nil, isSystemMessage: Bool = false, imageData: Data? = nil) {
            self.id = id
            self.roleRaw = roleRaw
            self.content = content
            self.timestamp = timestamp
            self.linkedTransactionID = linkedTransactionID
            self.isSystemMessage = isSystemMessage
            self.imageData = imageData
        }
    }

    @Model
    final class AppSettings {
        var id: UUID
        var language: String
        var baseCurrency: String
        var displayCurrency: String
        var notificationsEnabled: Bool
        var biometricLockEnabled: Bool
        var weeklySummaryEnabled: Bool
        var dailyReminderEnabled: Bool
        var userName: String
        var userAvatar: Data?

        init(id: UUID = UUID(), language: String = "", baseCurrency: String = "USD",
             displayCurrency: String = "USD", notificationsEnabled: Bool = true,
             biometricLockEnabled: Bool = false, weeklySummaryEnabled: Bool = true,
             dailyReminderEnabled: Bool = true, userName: String = "", userAvatar: Data? = nil) {
            self.id = id
            self.language = language
            self.baseCurrency = baseCurrency
            self.displayCurrency = displayCurrency
            self.notificationsEnabled = notificationsEnabled
            self.biometricLockEnabled = biometricLockEnabled
            self.weeklySummaryEnabled = weeklySummaryEnabled
            self.dailyReminderEnabled = dailyReminderEnabled
            self.userName = userName
            self.userAvatar = userAvatar
        }
    }
}

/// The shapes the app uses now: the same five entities with additive optional
/// ledger fields, plus the four synchronization models.
///
/// Every V2 addition is optional or has a default, so the step from V1 is a
/// lightweight migration. Nothing is renamed, retyped or dropped, and no
/// uniqueness constraint is imposed on existing rows before reconciliation —
/// a constraint added to unreconciled data would fail the open, which is the
/// one outcome a financial app must not have.
enum SumItSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Transaction.self, Category.self, ChatMessage.self, AppSettings.self, Wallet.self,
         PendingMutation.self, SyncCheckpoint.self, SyncIssue.self, CachedRateQuote.self]
    }
}

enum SumItMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SumItSchemaV1.self, SumItSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SumItSchemaV1.self, toVersion: SumItSchemaV2.self)]
    }
}
