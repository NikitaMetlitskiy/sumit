import SwiftData
import Foundation
import SwiftUI

// MARK: — Parsed Transaction (AI result, NOT saved yet)
struct ParsedTransaction: Equatable {
    var id: UUID = UUID()
    var type: TransactionType
    var amount: Double
    var currency: String
    var categoryName: String
    var merchant: String
    var note: String
    var occurredAt: Date
    var confidence: Double
    var rawInput: String
    var source: TransactionSource
    var walletName: String = ""

    static func == (lhs: ParsedTransaction, rhs: ParsedTransaction) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: — Chat Message
@Model
final class ChatMessage {
    var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var linkedTransactionID: UUID?
    var isSystemMessage: Bool
    var imageData: Data?

    var role: Role {
        get { Role(rawValue: roleRaw) ?? .assistant }
        set { roleRaw = newValue.rawValue }
    }

    enum Role: String, Codable {
        case user, assistant
    }

    init(role: Role, content: String, linkedTransactionID: UUID? = nil, isSystemMessage: Bool = false, imageData: Data? = nil) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.timestamp = .now
        self.linkedTransactionID = linkedTransactionID
        self.isSystemMessage = isSystemMessage
        self.imageData = imageData
    }
}

// MARK: — Category
@Model
final class Category {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var typeRaw: String
    var isDefault: Bool
    var sortOrder: Int

    var color: Color { Color(hex: colorHex) ?? .blue }

    /// Localized display name for default categories; raw name for custom ones.
    /// Uses the global nonisolated `L(_:)` — safe to call from SwiftData @Model accessors.
    var displayName: String {
        guard isDefault else { return name }
        let key = "cat_\(name.lowercased())"
        let translated = L(key)
        // L() returns the key itself when no translation exists.
        return translated == key ? name : translated
    }

    init(name: String, icon: String, colorHex: String,
         type: String = "expense", isDefault: Bool = false, sortOrder: Int = 99) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.typeRaw = type
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }

    static var defaults: [Category] { [
        Category(name: "Food",          icon: "fork.knife",           colorHex: "FF6B6B", isDefault: true, sortOrder: 0),
        Category(name: "Transport",     icon: "car.fill",             colorHex: "4ECDC4", isDefault: true, sortOrder: 1),
        Category(name: "Shopping",      icon: "bag.fill",             colorHex: "45B7D1", isDefault: true, sortOrder: 2),
        Category(name: "Health",        icon: "cross.fill",           colorHex: "96CEB4", isDefault: true, sortOrder: 3),
        Category(name: "Entertainment", icon: "tv.fill",              colorHex: "A29BFE", isDefault: true, sortOrder: 4),
        Category(name: "Education",     icon: "book.fill",            colorHex: "DDA0DD", isDefault: true, sortOrder: 5),
        Category(name: "Housing",       icon: "house.fill",           colorHex: "F0A500", isDefault: true, sortOrder: 6),
        Category(name: "Bills",         icon: "bolt.fill",            colorHex: "FD79A8", isDefault: true, sortOrder: 7),
        Category(name: "Travel",        icon: "airplane",             colorHex: "00CEC9", isDefault: true, sortOrder: 8),
        Category(name: "Subscriptions", icon: "arrow.clockwise",      colorHex: "6C5CE7", isDefault: true, sortOrder: 9),
        Category(name: "Salary",        icon: "banknote.fill",        colorHex: "00B894", type: "income", isDefault: true, sortOrder: 10),
        Category(name: "Freelance",     icon: "laptopcomputer",       colorHex: "0984E3", type: "income", isDefault: true, sortOrder: 11),
        Category(name: "Other",         icon: "ellipsis.circle.fill", colorHex: "B2BEC3", isDefault: true, sortOrder: 12),
    ]}
}

// MARK: — App Settings
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

    init() {
        self.id = UUID()
        // Empty string lets LocalizationManager auto-detect on first launch.
        self.language = ""
        self.baseCurrency = "USD"
        self.displayCurrency = "USD"
        self.notificationsEnabled = true
        self.biometricLockEnabled = false
        self.weeklySummaryEnabled = true
        self.dailyReminderEnabled = true
        self.userName = ""
        self.userAvatar = nil
    }
}

// MARK: — Color hex helper
extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        guard h.count == 6 else { return nil }
        self.init(
            red:   Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8)  & 0xFF) / 255,
            blue:  Double(int         & 0xFF) / 255
        )
    }
}
