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

    // MARK: — Ledger V2 (additive)
    /// The balance this wallet started from, as a canonical signed string.
    /// Current balance is derived from it plus active transaction effects —
    /// `balance` above survives only as a display cache during migration.
    var openingBalanceExact: String?
    var serverRevision: Int64 = 0
    var localGeneration: Int64 = 0
    /// Archive marker. Deleting a wallet must not erase the history that
    /// references it, so archived wallets stay readable.
    var deletedAt: Date?
    var migrationStateRaw: String = LedgerMigrationState.legacy.rawValue

    var migrationState: LedgerMigrationState {
        get { LedgerMigrationState(rawValue: migrationStateRaw) ?? .legacy }
        set { migrationStateRaw = newValue.rawValue }
    }
    var isArchived: Bool { deletedAt != nil }

    var walletType: WalletType {
        get { WalletType(rawValue: typeRaw) ?? .bank }
        set { typeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        userId: String = "local",
        name: String,
        type: WalletType = .bank,
        currency: String = "UAH",
        balance: Double = 0,
        icon: String = ""
    ) {
        self.id = id
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
