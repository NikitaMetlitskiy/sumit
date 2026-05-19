import SwiftData
import Foundation
import SwiftUI

@Model
final class Wallet {
    var id: UUID
    var userId: String
    var name: String
    var typeRaw: String          // bank, exchange, crypto, custom
    var currency: String
    var balance: Double
    var icon: String
    var createdAt: Date
    var isSynced: Bool

    var walletType: WalletType {
        get { WalletType(rawValue: typeRaw) ?? .bank }
        set { typeRaw = newValue.rawValue }
    }

    init(
        userId: String = "local",
        name: String,
        type: WalletType = .bank,
        currency: String = "UAH",
        balance: Double = 0,
        icon: String = ""
    ) {
        self.id = UUID()
        self.userId = userId
        self.name = name
        self.typeRaw = type.rawValue
        self.currency = currency
        self.balance = balance
        self.icon = icon.isEmpty ? type.defaultIcon : icon
        self.createdAt = .now
        self.isSynced = false
    }
}

enum WalletType: String, CaseIterable, Codable {
    case bank     = "bank"
    case exchange  = "exchange"
    case crypto   = "crypto"
    case cash     = "cash"
    case custom   = "custom"

    var label: String {
        switch self {
        case .bank:     return L("wallet_type_bank")
        case .exchange:  return L("wallet_type_exchange")
        case .crypto:   return L("wallet_type_crypto")
        case .cash:     return L("wallet_type_cash")
        case .custom:   return L("wallet_type_custom")
        }
    }

    var defaultIcon: String {
        switch self {
        case .bank:     return "building.columns.fill"
        case .exchange:  return "chart.line.uptrend.xyaxis"
        case .crypto:   return "bitcoinsign.circle.fill"
        case .cash:     return "banknote.fill"
        case .custom:   return "wallet.pass.fill"
        }
    }
}
