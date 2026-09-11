import Foundation
import SwiftData

/// Why a local financial command was refused. Every case carries a stable
/// machine code rather than a sentence, so it can be asserted in a test, stored
/// as `PendingMutation.lastErrorCode`, and localized for display without ever
/// putting a merchant name or an amount into a log.
enum LedgerWriteError: Error, Equatable {
    case validation(code: String)
    case wrongScope
    case missingEntity(UUID)
    /// A create was attempted for an owner+UUID that already exists. Repeat
    /// taps must resolve to the record that is already saved.
    case duplicateEntity(UUID)
    case persistence(code: String)

    var code: String {
        switch self {
        case .validation(let code):  return code
        case .wrongScope:            return "wrong_scope"
        case .missingEntity:         return "missing_entity"
        case .duplicateEntity:       return "duplicate_entity"
        case .persistence(let code): return code
        }
    }
}

/// The only place financial data is written locally.
///
/// The path it replaces returned the transaction object even when the save had
/// thrown:
///
///     do { try ctx.save() } catch { Log.error("Tx save failed"); return tx }
///
/// so a caller could not tell a stored transaction from a lost one, and the
/// chat cheerfully printed "saved" either way. Here a command either commits
/// the entity change, the queued sync intent and the linked chat reply
/// **together**, or it commits none of them and throws.
@MainActor
final class LedgerStore {

    private let context: ModelContext
    private let persist: () throws -> Void

    /// - Parameter persist: injected in tests to force a save failure. Production
    ///   passes nil and gets `context.save()`.
    init(context: ModelContext, persist: (() throws -> Void)? = nil) {
        self.context = context
        // The single checked save is the transaction boundary. Autosave would
        // commit a half-applied command behind our back.
        context.autosaveEnabled = false
        self.persist = persist ?? { [context] in try context.save() }
    }

    // MARK: — Transactions

    @discardableResult
    func saveTransaction(_ draft: TransactionDraft,
                         scope: AccountScope,
                         linkedMessageID: UUID? = nil) throws -> LocalSaveReceipt {
        try beginBoundary()
        try validate(draft, scope: scope)

        guard try transaction(id: draft.id, ownerID: scope.ownerID) == nil else {
            throw LedgerWriteError.duplicateEntity(draft.id)
        }

        return try commit {
            let entity = Transaction(id: draft.id, userId: scope.ownerID,
                                     type: draft.type,
                                     originalAmount: 0, originalCurrency: draft.currency,
                                     amountInBase: 0, rateAtTime: 0,
                                     categoryName: draft.categoryName, merchant: draft.merchant,
                                     note: draft.note, occurredAt: draft.occurredAt,
                                     source: draft.source, confidence: 1,
                                     rawInput: draft.rawInput,
                                     linkedMessageID: linkedMessageID, isSynced: false)
            context.insert(entity)
            try apply(draft, to: entity)
            entity.localGeneration = 1

            let operation = try enqueue(entityKind: .transaction, entityID: draft.id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: try encode(record(from: draft)))
            try linkReply(linkedMessageID, to: draft.id)
            return (draft.id, operation, entity.localGeneration)
        }
    }

    @discardableResult
    func editTransaction(_ draft: TransactionDraft, scope: AccountScope) throws -> LocalSaveReceipt {
        try beginBoundary()
        try validate(draft, scope: scope)

        guard let entity = try transaction(id: draft.id, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(draft.id)
        }
        guard entity.deletedAt == nil else { throw LedgerWriteError.missingEntity(draft.id) }

        return try commit {
            try apply(draft, to: entity)
            entity.localGeneration += 1
            let operation = try enqueue(entityKind: .transaction, entityID: draft.id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: try encode(record(from: draft)))
            return (draft.id, operation, entity.localGeneration)
        }
    }

    @discardableResult
    func deleteTransaction(id: UUID, scope: AccountScope) throws -> LocalSaveReceipt {
        try beginBoundary()
        guard let entity = try transaction(id: id, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(id)
        }
        return try commit {
            // A tombstone, never `context.delete`. The intent to delete has to
            // outlive this launch, and other devices have to learn about it.
            entity.deletedAt = .now
            entity.localGeneration += 1
            let operation = try enqueue(entityKind: .transaction, entityID: id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: nil)
            return (id, operation, entity.localGeneration)
        }
    }

    // MARK: — Wallets

    @discardableResult
    func saveWallet(_ draft: WalletDraft, scope: AccountScope) throws -> LocalSaveReceipt {
        try beginBoundary()
        // Zero and negative opening balances are legitimate: a wallet can start
        // empty, and a negative opening balance is a debt.
        try validateMoney { try MoneyCodec.validateEntry(draft.openingBalance,
                                                         currency: draft.currency,
                                                         allowNegative: true, allowZero: true) }
        guard !draft.name.isEmpty, draft.name.count <= 128 else {
            throw LedgerWriteError.validation(code: "invalid_wallet_name")
        }

        let existing = try wallet(id: draft.id, ownerID: scope.ownerID)
        if let existing {
            // Currency is immutable once anything references the wallet.
            if existing.currency != draft.currency,
               try transactionsReferencing(draft.id, ownerID: scope.ownerID) > 0 {
                throw LedgerWriteError.validation(code: "wallet_currency_is_locked")
            }
        }

        return try commit {
            let entity: Wallet
            if let existing {
                entity = existing
            } else {
                entity = Wallet(id: draft.id, userId: scope.ownerID, name: draft.name,
                                type: draft.type, currency: draft.currency,
                                balance: 0, icon: draft.icon)
                context.insert(entity)
            }
            entity.name = draft.name
            entity.walletType = draft.type
            entity.currency = draft.currency
            entity.icon = draft.icon
            entity.openingBalanceExact = try MoneyCodec.encode(draft.openingBalance)
            entity.migrationState = .adopted
            entity.localGeneration += 1

            let operation = try enqueue(entityKind: .wallet, entityID: draft.id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: try encode(WalletRecordV1(
                                            name: draft.name, type: draft.type.rawValue,
                                            currency: draft.currency,
                                            openingBalance: try MoneyCodec.encode(draft.openingBalance),
                                            icon: draft.icon)))
            return (draft.id, operation, entity.localGeneration)
        }
    }

    /// Wallets are archived, never erased: the transactions that reference one
    /// must stay readable and their effects must stay calculable.
    @discardableResult
    func archiveWallet(id: UUID, scope: AccountScope) throws -> LocalSaveReceipt {
        try beginBoundary()
        guard let entity = try wallet(id: id, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(id)
        }
        return try commit {
            entity.deletedAt = .now
            entity.localGeneration += 1
            let operation = try enqueue(entityKind: .wallet, entityID: id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: nil)
            return (id, operation, entity.localGeneration)
        }
    }

    // MARK: — Categories

    @discardableResult
    func saveCategory(_ draft: CategoryDraft, scope: AccountScope) throws -> LocalSaveReceipt {
        try beginBoundary()
        guard !draft.name.isEmpty, draft.name.count <= 128 else {
            throw LedgerWriteError.validation(code: "invalid_category_name")
        }
        guard draft.colorHex.count == 6,
              draft.colorHex.allSatisfy({ $0.isHexDigit }) else {
            throw LedgerWriteError.validation(code: "invalid_color_hex")
        }
        guard draft.sortOrder >= 0 else {
            throw LedgerWriteError.validation(code: "invalid_sort_order")
        }

        let existing = try category(id: draft.id, ownerID: scope.ownerID)
        return try commit {
            let entity: SumIt.Category
            if let existing {
                entity = existing
            } else {
                entity = SumIt.Category(id: draft.id, name: draft.name, icon: draft.icon,
                                        colorHex: draft.colorHex, type: draft.type,
                                        isDefault: false, sortOrder: draft.sortOrder,
                                        ownerID: scope.ownerID)
                context.insert(entity)
            }
            entity.name = draft.name
            entity.icon = draft.icon
            entity.colorHex = draft.colorHex
            entity.typeRaw = draft.type
            entity.sortOrder = draft.sortOrder
            entity.ownerID = scope.ownerID
            entity.localGeneration += 1

            let operation = try enqueue(entityKind: .category, entityID: draft.id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: try encode(CategoryRecordV1(
                                            name: draft.name, icon: draft.icon,
                                            colorHex: draft.colorHex, type: draft.type,
                                            sortOrder: draft.sortOrder, isDefault: false)))
            return (draft.id, operation, entity.localGeneration)
        }
    }

    @discardableResult
    func archiveCategory(id: UUID, scope: AccountScope) throws -> LocalSaveReceipt {
        try beginBoundary()
        guard let entity = try category(id: id, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(id)
        }
        return try commit {
            // The definition is archived; the category text already written on
            // historical transactions stays readable.
            entity.deletedAt = .now
            entity.localGeneration += 1
            let operation = try enqueue(entityKind: .category, entityID: id,
                                        generation: entity.localGeneration, scope: scope,
                                        payload: nil)
            return (id, operation, entity.localGeneration)
        }
    }

    // MARK: — Boundary

    /// SwiftData's `rollback()` discards *every* pending change in the context,
    /// including unrelated ones. Anything already sitting uncommitted is
    /// therefore committed first, so a financial failure cannot take an
    /// unrelated chat message or settings edit down with it.
    private func beginBoundary() throws {
        guard context.hasChanges else { return }
        do { try persist() }
        catch { throw LedgerWriteError.persistence(code: "pre_commit_failed") }
    }

    /// Runs the mutation and commits it as one unit. Any failure rolls the
    /// context back, so the entity, the queue entry and the reply are all
    /// unchanged — there is no state where one of the three landed alone.
    private func commit(_ body: () throws -> (UUID, UUID, Int64)) throws -> LocalSaveReceipt {
        do {
            let (entityID, operationID, generation) = try body()
            try persist()
            // The receipt exists only on the far side of a successful save.
            return LocalSaveReceipt(entityID: entityID, operationID: operationID,
                                    generation: generation)
        } catch let error as LedgerWriteError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw LedgerWriteError.persistence(code: "save_failed")
        }
    }

    /// Points the chat reply at the record it belongs to, inside the same
    /// boundary. The old flow saved the financial row and then wrote the
    /// "saved" reply in a *second*, unchecked save, so a failure there left a
    /// transaction with no visible confirmation — or a confirmation with no
    /// transaction.
    private func linkReply(_ messageID: UUID?, to transactionID: UUID) throws {
        guard let messageID else { return }
        let descriptor = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == messageID })
        do {
            guard let message = try context.fetch(descriptor).first else { return }
            message.linkedTransactionID = transactionID
        } catch {
            throw LedgerWriteError.persistence(code: "reply_lookup_failed")
        }
    }

    // MARK: — Queue

    private func enqueue(entityKind: LedgerEntityKind, entityID: UUID, generation: Int64,
                         scope: AccountScope, payload: Data?) throws -> UUID {
        // Repeated edits append linked intents rather than replacing one
        // another: each is an immutable record of what the user asked for, and
        // the server must see them in order.
        let predecessor = try lastPendingOperation(entityID: entityID, ownerID: scope.ownerID)
        let mutation = PendingMutation(ownerID: scope.ownerID,
                                       entityKind: entityKind,
                                       entityID: entityID,
                                       localGeneration: generation,
                                       predecessorOperationID: predecessor,
                                       desiredSnapshotJSON: payload)
        context.insert(mutation)
        return mutation.operationID
    }

    private func lastPendingOperation(entityID: UUID, ownerID: String) throws -> UUID? {
        let completed = PendingMutationState.completed.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.entityID == entityID && $0.ownerID == ownerID && $0.stateRaw != completed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).first?.operationID
    }

    // MARK: — Applying a draft

    private func apply(_ draft: TransactionDraft, to entity: Transaction) throws {
        entity.type = draft.type
        entity.originalCurrency = draft.currency
        entity.amountExact = try MoneyCodec.encode(draft.amount)
        entity.categoryName = draft.categoryName
        entity.merchant = draft.merchant
        entity.note = draft.note
        entity.occurredAt = draft.occurredAt
        entity.source = draft.source
        entity.rawInput = draft.rawInput
        entity.walletID = draft.walletID
        entity.destinationWalletID = draft.destinationWalletID
        entity.walletAmountExact = try draft.walletAmount.map(MoneyCodec.encode)
        entity.destinationAmountExact = try draft.destinationAmount.map(MoneyCodec.encode)
        entity.valuationState = draft.valuation.state
        entity.migrationState = .adopted
        entity.isSynced = false

        switch draft.valuation {
        case .unvalued:
            entity.rateExact = nil
            entity.baseAmountExact = nil
            entity.quoteJSON = nil
        case .quoted(let quote):
            let rate = try MoneyCodec.decode(quote.usdPerUnit)
            // The same rule the server re-derives: exact product, half-even to
            // scale 18. If the two disagree the write is rejected there.
            let base = try MoneyCodec.quantize(draft.amount * rate, scale: MoneyPrecision.baseScale)
            guard base > 0 else { throw LedgerWriteError.validation(code: "base_amount_rounds_to_zero") }
            entity.rateExact = quote.usdPerUnit
            entity.baseAmountExact = try MoneyCodec.encode(base)
            entity.quoteJSON = try JSONEncoder().encode(quote)
        case .legacyUnverified(let baseAmount, let rate):
            entity.baseAmountExact = try baseAmount.map(MoneyCodec.encode)
            entity.rateExact = try rate.map(MoneyCodec.encode)
            entity.quoteJSON = nil
        }

        // Compatibility mirrors for views that have not migrated yet. These are
        // the only Double values written, they are never read back as the
        // ledger's authority, and Task 14 removes their last readers.
        entity.originalAmount = doubleMirror(draft.amount)
        entity.amountInBase = entity.baseAmountExact.flatMap { try? MoneyCodec.decode($0) }
            .map(doubleMirror) ?? 0
        entity.rateAtTime = entity.rateExact.flatMap { try? MoneyCodec.decode($0) }
            .map(doubleMirror) ?? 0
        entity.confidence = doubleMirror(draft.confidence)
    }

    private func doubleMirror(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private func record(from draft: TransactionDraft) -> TransactionRecordV1 {
        TransactionRecordV1(
            type: draft.type.rawValue,
            originalAmount: (try? MoneyCodec.encode(draft.amount)) ?? "0",
            originalCurrency: draft.currency,
            walletID: draft.walletID,
            walletAmount: draft.walletAmount.flatMap { try? MoneyCodec.encode($0) },
            destinationWalletID: draft.destinationWalletID,
            destinationAmount: draft.destinationAmount.flatMap { try? MoneyCodec.encode($0) },
            categoryName: draft.categoryName,
            merchant: draft.merchant,
            note: draft.note,
            occurredAt: draft.occurredAt,
            source: draft.source.rawValue,
            confidence: (try? MoneyCodec.encode(draft.confidence)) ?? "1",
            rawInput: draft.rawInput,
            baseAmount: bookedBase(for: draft),
            usdPerUnit: bookedRate(for: draft),
            valuationState: draft.valuation.state,
            quote: draft.valuation.quote)
    }

    /// The booked USD value the mutation carries — the same number `apply`
    /// stores locally, by the same rule the server re-derives.
    ///
    /// This used to be a hard-coded `nil`. The server requires base, rate and
    /// quote together for every valued record (`valued_requires_base_rate_quote`),
    /// so every valued mutation — including every USD entry at identity — would
    /// have been refused on its first push.
    private func bookedBase(for draft: TransactionDraft) -> String? {
        switch draft.valuation {
        case .unvalued:
            return nil
        case .quoted(let quote):
            guard let rate = try? MoneyCodec.decode(quote.usdPerUnit),
                  let base = try? MoneyCodec.quantize(draft.amount * rate, scale: MoneyPrecision.baseScale) else {
                return nil
            }
            return try? MoneyCodec.encode(base)
        case .legacyUnverified(let base, _):
            return base.flatMap { try? MoneyCodec.encode($0) }
        }
    }

    private func bookedRate(for draft: TransactionDraft) -> String? {
        switch draft.valuation {
        case .unvalued:                      return nil
        case .quoted(let quote):             return quote.usdPerUnit
        case .legacyUnverified(_, let rate): return rate.flatMap { try? MoneyCodec.encode($0) }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw LedgerWriteError.validation(code: "encode_failed") }
    }

    // MARK: — Validation

    private func validate(_ draft: TransactionDraft, scope: AccountScope) throws {
        try validateMoney { try MoneyCodec.validateEntry(draft.amount, currency: draft.currency) }
        do {
            try WalletLedger.validateForSave(draft,
                                             wallets: try walletDescriptors(ownerID: scope.ownerID),
                                             ownerID: scope.ownerID)
        } catch let error as WalletLedgerError {
            if case .wrongOwner = error { throw LedgerWriteError.wrongScope }
            throw LedgerWriteError.validation(code: Self.code(for: error))
        }
    }

    private func validateMoney(_ body: () throws -> Void) throws {
        do { try body() }
        catch let error as MoneyError { throw LedgerWriteError.validation(code: Self.code(for: error)) }
    }

    private static func code(for error: MoneyError) -> String {
        switch error {
        case .invalidSyntax:        return "invalid_amount"
        case .nonFinite:            return "non_finite_amount"
        case .outOfRange:           return "amount_out_of_range"
        case .excessPrecision:      return "excess_precision"
        case .arithmeticFailure:    return "arithmetic_failure"
        case .unsupportedCurrency:  return "unsupported_currency"
        }
    }

    private static func code(for error: WalletLedgerError) -> String {
        switch error {
        case .unknownWallet:               return "unknown_wallet"
        case .wrongOwner:                  return "wrong_scope"
        case .archivedWallet:              return "archived_wallet"
        case .selfTransfer:                return "transfer_to_same_wallet"
        case .incompleteTransfer:          return "incomplete_transfer"
        case .nonPositiveAmount:           return "non_positive_amount"
        case .destinationOnNonTransfer:    return "destination_on_non_transfer"
        case .walletAmountMismatch:        return "wallet_amount_mismatch"
        case .sameCurrencyEffectMismatch:  return "same_currency_effect_mismatch"
        case .unequalSameCurrencyLegs:     return "unequal_same_currency_legs"
        case .transferCurrencyMismatch:    return "transfer_currency_mismatch"
        case .arithmeticFailure:           return "arithmetic_failure"
        }
    }

    // MARK: — Lookups, always scoped by owner

    private func transaction(id: UUID, ownerID: String) throws -> Transaction? {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == id && $0.userId == ownerID })
        return try context.fetch(descriptor).first
    }

    private func wallet(id: UUID, ownerID: String) throws -> Wallet? {
        let descriptor = FetchDescriptor<Wallet>(
            predicate: #Predicate { $0.id == id && $0.userId == ownerID })
        return try context.fetch(descriptor).first
    }

    private func category(id: UUID, ownerID: String) throws -> SumIt.Category? {
        let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == id })
        guard let found = try context.fetch(descriptor).first else { return nil }
        guard found.ownerID == nil || found.ownerID == ownerID else {
            throw LedgerWriteError.wrongScope
        }
        return found
    }

    private func walletDescriptors(ownerID: String) throws -> [UUID: WalletDescriptor] {
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        var result: [UUID: WalletDescriptor] = [:]
        for wallet in wallets {
            result[wallet.id] = WalletDescriptor(id: wallet.id, ownerID: wallet.userId,
                                                 currency: wallet.currency,
                                                 isArchived: wallet.deletedAt != nil)
        }
        return result
    }

    private func transactionsReferencing(_ walletID: UUID, ownerID: String) throws -> Int {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.walletID == walletID || $0.destinationWalletID == walletID })
        return try context.fetch(descriptor).filter { $0.userId == ownerID }.count
    }
}
