import Foundation

/// Filters every list the financial UI shows down to one account.
///
/// Without this, `@Query` returns every row in the store regardless of owner.
/// On a device where two people have signed in, or where someone signed out and
/// someone else signed in, that means one person's transactions, wallets and
/// chat appear under the other's account. Keeping the previous account's rows on
/// the device is allowed; showing them is not.
///
/// Deleted rows are filtered here too: a tombstone is retained so the deletion
/// can reach other devices, and hidden so it reads as deleted.
enum LedgerScope {

    static func activeTransactions(_ transactions: [Transaction], ownerID: String) -> [Transaction] {
        transactions.filter { $0.userId == ownerID && $0.deletedAt == nil }
    }

    static func activeWallets(_ wallets: [Wallet], ownerID: String) -> [Wallet] {
        wallets.filter { $0.userId == ownerID && $0.deletedAt == nil }
    }

    /// Bundled defaults are shared templates and belong to no account. A custom
    /// category belongs to whoever created it.
    static func activeCategories(_ categories: [Category], ownerID: String) -> [Category] {
        categories.filter { category in
            guard category.deletedAt == nil else { return false }
            if category.isDefault { return true }
            return category.ownerID == ownerID
        }
    }

    /// Chat written before accounts existed carries no owner. It stays with the
    /// signed-out device dataset rather than being handed to whichever account
    /// signs in next; Task 18's import is where it can be claimed deliberately.
    static func visibleMessages(_ messages: [ChatMessage], ownerID: String) -> [ChatMessage] {
        messages.filter { message in
            if let owner = message.ownerID { return owner == ownerID }
            return ownerID == AccountScope.localOwnerID
        }
    }
}
