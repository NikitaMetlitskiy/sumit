import SwiftUI
import SwiftData
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var displayCurrency: String = "USD"
    @Published var allCategories: [Category] = []
    @Published var userName: String = ""
    @Published var userAvatar: UIImage? = nil

    var modelContext: ModelContext?

    /// Why the last local write failed, as a stable machine code. `nil` means
    /// the last write succeeded. Callers use it to say what actually went wrong
    /// instead of guessing.
    @Published private(set) var lastWriteErrorCode: String?

    /// The checked, atomic write path. Views are migrated onto it in Task 14;
    /// until then `saveConfirmed` above remains the live path and this is the
    /// entry point new code should use.
    private(set) var ledger: LedgerStore?

    /// Dispatches the durable queue. It is deliberately **not** triggered yet:
    /// the live save path still writes through `saveConfirmed`, so no
    /// `PendingMutation` is ever created in production and there is nothing to
    /// send. Task 14 migrates the callers, and triggering starts there.
    private(set) var syncCoordinator: LedgerSyncCoordinator?

    /// Dated quotes for editors, the confirmation card and report display.
    /// It never writes a transaction.
    private(set) var rateService: RateService?

    func setup(context: ModelContext) {
        self.modelContext = context
        self.ledger = LedgerStore(context: context)
        self.syncCoordinator = LedgerSyncCoordinator(context: context)
        self.rateService = RateService(container: context.container, fetch: { currencies, date in
            try await BackendService.shared.getRates(currencies: currencies, date: date)
        })
        seedCategoriesIfNeeded()
        loadCategories()
        loadSettings()
        Log.info("AppStore setup complete. Categories: \(self.allCategories.count)")

        Task { [weak self] in
            _ = await AuthService.shared.refreshSessionIfNeeded()
            guard AuthService.shared.isSignedIn else { return }
            let scope = AuthService.shared.currentScope
            // Pull first so local work is queued against what the server
            // actually holds, then push. Both are idempotent by identity, so a
            // relaunch in the middle of either repeats rather than duplicates.
            await self?.syncCoordinator?.pull(scope: scope)
            await self?.restoreLegacyRowsFromCloud()
            self?.syncCoordinator?.trigger(scope: scope)
        }
    }

    /// Records that device-only rows exist and are waiting for an explicit
    /// import, instead of silently attaching them to the account that just
    /// signed in. One open issue per account, never a pile of duplicates.
    func recordLocalDataAwaitingImport(ownerID: String) {
        guard let ctx = modelContext, ownerID != AccountScope.localOwnerID else { return }

        let localOwner = AccountScope.localOwnerID
        let localTransactions = (try? ctx.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.userId == localOwner }))) ?? 0
        let localWallets = (try? ctx.fetchCount(FetchDescriptor<Wallet>(
            predicate: #Predicate { $0.userId == localOwner }))) ?? 0
        guard localTransactions + localWallets > 0 else { return }

        let reason = "local_data_awaiting_import"
        let existing = (try? ctx.fetch(FetchDescriptor<SyncIssue>(
            predicate: #Predicate { $0.ownerID == ownerID && $0.reason == reason && $0.resolvedAt == nil }))) ?? []
        guard existing.isEmpty else { return }

        // An account-level issue rather than one about a single row.
        ctx.insert(SyncIssue(ownerID: ownerID, entityKind: .transaction,
                             entityID: AppStore.accountLevelIssueID,
                             kind: .legacyAmbiguity, reason: reason))
        try? ctx.save()
    }

    /// Sentinel identity for issues that concern the account rather than one entity.
    static let accountLevelIssueID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    // MARK: — Settings
    func loadSettings() {
        guard let ctx = modelContext else { return }
        guard let s = (try? ctx.fetch(FetchDescriptor<AppSettings>()))?.first else { return }
        displayCurrency = s.displayCurrency
        userName = s.userName
        if let data = s.userAvatar { userAvatar = UIImage(data: data) }
    }

    func saveSettings(displayCurrency: String? = nil, userName: String? = nil, avatar: UIImage? = nil) {
        guard let ctx = modelContext else { return }

        let existing = (try? ctx.fetch(FetchDescriptor<AppSettings>()))?.first
        let settings: AppSettings
        if let e = existing { settings = e }
        else {
            settings = AppSettings()
            ctx.insert(settings)
        }

        if let c = displayCurrency {
            settings.displayCurrency = c
            self.displayCurrency = c
        }
        if let n = userName {
            settings.userName = n
            self.userName = n
        }
        if let img = avatar, let data = img.pngData() {
            settings.userAvatar = data
            self.userAvatar = img
        }

        do { try ctx.save() } catch { Log.error("Settings save failed") }
    }

    // MARK: — Categories
    func loadCategories() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)])
        allCategories = (try? ctx.fetch(desc)) ?? []
    }

    func seedCategoriesIfNeeded() {
        guard let ctx = modelContext else { return }
        let count = (try? ctx.fetchCount(FetchDescriptor<Category>())) ?? 0
        guard count == 0 else { return }
        Category.defaults.forEach { ctx.insert($0) }
        try? ctx.save()
    }

    // MARK: — Save confirmed transaction

    /// The live save path. Everything it used to do by hand — insert, adjust a
    /// stored wallet balance, save, then upload and hope — is now one checked
    /// atomic command plus a durable queue entry.
    ///
    /// Returns the saved transaction, or `nil` with `lastWriteErrorCode` set.
    /// It never returns a transaction that was not committed.
    @discardableResult
    func saveConfirmed(parsed: ParsedTransaction, linkedMessageID: UUID? = nil) async -> Transaction? {
        lastWriteErrorCode = nil
        guard let ctx = modelContext, let ledger else {
            lastWriteErrorCode = "storage_unavailable"
            return nil
        }
        let scope = AuthService.shared.currentScope

        let draft: TransactionDraft
        do {
            draft = try ParsedTransactionDraft.make(
                from: parsed, id: parsed.id,
                categoryName: matchCategoryKey(parsed.categoryName),
                wallets: (try? ctx.fetch(FetchDescriptor<Wallet>())) ?? [],
                ownerID: scope.ownerID)
        } catch let error as ParsedTransactionDraft.BuildError {
            lastWriteErrorCode = error.code
            return nil
        } catch {
            lastWriteErrorCode = "invalid_amount"
            return nil
        }

        do {
            try ledger.saveTransaction(draft, scope: scope, linkedMessageID: linkedMessageID)
        } catch let error as LedgerWriteError {
            // A second tap on the same confirmation card is not a second
            // transaction: the identity already exists, so the first save is
            // the answer.
            if case .duplicateEntity(let id) = error {
                return try? transaction(id: id, ownerID: scope.ownerID)
            }
            lastWriteErrorCode = error.code
            return nil
        } catch {
            lastWriteErrorCode = "save_failed"
            return nil
        }

        dispatchQueuedWork()
        return try? transaction(id: draft.id, ownerID: scope.ownerID)
    }

    /// Applies an edited draft. The caller owns a draft, never a half-mutated
    /// live object, so a rejected edit leaves the stored record untouched.
    @discardableResult
    func editTransaction(_ draft: TransactionDraft) -> Bool {
        lastWriteErrorCode = nil
        guard let ledger else {
            lastWriteErrorCode = "storage_unavailable"
            return false
        }
        do {
            try ledger.editTransaction(draft, scope: AuthService.shared.currentScope)
            dispatchQueuedWork()
            return true
        } catch let error as LedgerWriteError {
            lastWriteErrorCode = error.code
            return false
        } catch {
            lastWriteErrorCode = "save_failed"
            return false
        }
    }

    // MARK: — Wallets and categories

    /// Creates or updates; `saveWallet` on the store is an upsert by identity.
    @discardableResult
    func saveWallet(_ draft: WalletDraft) -> Bool {
        write { ledger, scope in try ledger.saveWallet(draft, scope: scope) }
    }

    /// Archiving, never deletion. The wallet stops accepting new entries and
    /// stays behind every record that already points at it.
    @discardableResult
    func archiveWallet(id: UUID) -> Bool {
        write { ledger, scope in try ledger.archiveWallet(id: id, scope: scope) }
    }

    @discardableResult
    func saveCategory(_ draft: CategoryDraft) -> Bool {
        write { ledger, scope in try ledger.saveCategory(draft, scope: scope) }
    }

    @discardableResult
    func archiveCategory(id: UUID) -> Bool {
        write { ledger, scope in try ledger.archiveCategory(id: id, scope: scope) }
    }

    /// Whether anything already points at this wallet. A wallet with history
    /// cannot change currency: doing so would silently reinterpret every
    /// quantity recorded against it.
    func walletHasLinkedRecords(id: UUID) -> Bool {
        guard let ctx = modelContext else { return false }
        let count = (try? ctx.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.walletID == id || $0.destinationWalletID == id }))) ?? 0
        return count > 0
    }

    /// Whether this entity still has work in the durable queue. Used for the
    /// "waiting to sync" line: a local save is a real receipt on its own, and
    /// saying so is not the same as claiming the server has it.
    func isAwaitingSync(entityID: UUID) -> Bool {
        guard let ctx = modelContext else { return false }
        let completed = PendingMutationState.completed.rawValue
        let count = (try? ctx.fetchCount(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.entityID == entityID && $0.stateRaw != completed }))) ?? 0
        return count > 0
    }

    func walletName(id: UUID?) -> String {
        guard let id, let ctx = modelContext else { return "" }
        return (try? ctx.fetch(FetchDescriptor<Wallet>(
            predicate: #Predicate { $0.id == id })).first?.name) ?? "" 
    }

    private func write(_ body: (LedgerStore, AccountScope) throws -> LocalSaveReceipt) -> Bool {
        lastWriteErrorCode = nil
        guard let ledger else {
            lastWriteErrorCode = "storage_unavailable"
            return false
        }
        do {
            _ = try body(ledger, AuthService.shared.currentScope)
            dispatchQueuedWork()
            return true
        } catch let error as LedgerWriteError {
            lastWriteErrorCode = error.code
            return false
        } catch {
            lastWriteErrorCode = "save_failed"
            return false
        }
    }

    /// Pulls the change feed, then pushes whatever is queued. Used on launch
    /// and right after signing in.
    func syncNow() async {
        guard AuthService.shared.isSignedIn else { return }
        let scope = AuthService.shared.currentScope
        await syncCoordinator?.pull(scope: scope)
        // Rows that predate the ledger are not in the feed; see the comment on
        // `restoreLegacyRowsFromCloud`.
        await restoreLegacyRowsFromCloud()
        syncCoordinator?.trigger(scope: scope)
        loadCategories()
    }

    /// Starts the push loop. Safe to call after every write: the coordinator
    /// collapses concurrent runs.
    func dispatchQueuedWork() {
        guard let syncCoordinator, AuthService.shared.isSignedIn else { return }
        syncCoordinator.trigger(scope: AuthService.shared.currentScope)
    }

    private func transaction(id: UUID, ownerID: String) throws -> Transaction? {
        guard let ctx = modelContext else { return nil }
        return try ctx.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == id && $0.userId == ownerID })).first
    }

    /// Current balance of every live wallet, derived from opening balance plus
    /// the effects of the owner's transactions. Never a stored running total.
    func walletBalances() -> [UUID: Decimal] {
        guard let ctx = modelContext else { return [:] }
        let ownerID = AuthService.shared.userId
        // Archived wallets are included deliberately. Archiving hides a wallet
        // from new entries; the transactions already pointing at it still have
        // effects, and leaving it out makes `effects` throw `unknownWallet` —
        // which would wipe out *every* balance, not just this one's.
        let wallets = ((try? ctx.fetch(FetchDescriptor<Wallet>())) ?? [])
            .filter { $0.userId == ownerID }
        let transactions = LedgerScope.activeTransactions(
            (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? [], ownerID: ownerID)
        return (try? WalletLedger.balances(
            opening: Dictionary(wallets.map { ($0.id, $0.openingBalance) },
                                uniquingKeysWith: { first, _ in first }),
            transactions: transactions.compactMap { $0.draftForCalculation },
            wallets: Dictionary(wallets.map { ($0.id, $0.descriptor) },
                                uniquingKeysWith: { first, _ in first }),
            ownerID: ownerID)) ?? [:]
    }

    // MARK: — Legacy cloud rows

    /// Reads rows that predate the ledger protocol.
    ///
    /// **This is still needed and must not be retired yet.** The change feed
    /// returns rows with `cursor > after`, and every row already in production
    /// carries `ledger_revision = 0` — so a pull from zero returns none of
    /// them. Removing this path would make an existing user's history
    /// disappear on a new device. Task 18 adopts those rows into the ledger;
    /// this goes away then, and not before.
    ///
    /// Two things are fixed compared with the version this replaces:
    /// identity is compared as **UUID values**, not as strings (Swift writes
    /// `uuidString` in uppercase and the server returns lowercase, which is why
    /// a restore used to create a second copy of the same transaction — 32 of
    /// the 70 production rows are uppercase); and anything the ledger already
    /// knows about is left alone.
    ///
    /// Not fixed here: the server-side row cap on this legacy endpoint. A
    /// history larger than that cap is still not fully represented by this
    /// path — only by the feed, once the rows are adopted.
    func restoreLegacyRowsFromCloud() async {
        guard let ctx = modelContext, AuthService.shared.isSignedIn else { return }
        let ownerID = AuthService.shared.userId

        do {
            let remote = try await SupabaseService.shared.fetchTransactions()
            let known = Set(((try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.id))

            for row in remote where row.deleted_at == nil {
                guard let localID = row.local_id.flatMap(UUID.init(uuidString:)),
                      !known.contains(localID) else { continue }
                let tx = Transaction(
                    id: localID,
                    userId: row.user_id ?? ownerID,
                    type: TransactionType(rawValue: row.type ?? "expense") ?? .expense,
                    originalAmount: row.original_amount,
                    originalCurrency: row.original_currency,
                    // Missing means missing. Defaulting the base to the original
                    // amount and the rate to 1 claimed a USD value nobody had —
                    // reports now count such a row as unconverted instead.
                    amountInBase: row.amount_in_base ?? 0,
                    baseCurrency: row.base_currency ?? "USD",
                    rateAtTime: row.rate_at_time ?? 0,
                    categoryName: row.category_name ?? "Other",
                    merchant: row.merchant ?? "",
                    note: row.note ?? "",
                    occurredAt: row.occurred_at.flatMap { Formatters.date(fromISO: $0) } ?? .now,
                    source: TransactionSource(rawValue: row.source ?? "text") ?? .text,
                    confidence: row.confidence ?? 0.8,
                    rawInput: row.raw_input ?? "",
                    walletName: row.wallet_name ?? "",
                    isSynced: true)
                // Marked legacy on purpose: it has no exact amount and no
                // ledger revision, so it is excluded from exact calculations
                // until Task 18 adopts it.
                tx.migrationState = .legacy
                ctx.insert(tx)
            }

            let remoteCategories = (try? await SupabaseService.shared.fetchCategories()) ?? []
            let knownCategories = Set(((try? ctx.fetch(FetchDescriptor<SumIt.Category>())) ?? []).map(\.id))
            for row in remoteCategories where !(row.is_default ?? false) {
                guard let localID = row.local_id.flatMap(UUID.init(uuidString:)),
                      !knownCategories.contains(localID) else { continue }
                let category = SumIt.Category(id: localID, name: row.name,
                                              icon: row.icon ?? "tag",
                                              colorHex: row.color_hex ?? "5271B4",
                                              type: row.type ?? "expense",
                                              isDefault: false,
                                              sortOrder: row.sort_order ?? 99,
                                              ownerID: ownerID)
                ctx.insert(category)
            }

            let remoteWallets = (try? await SupabaseService.shared.fetchWallets()) ?? []
            let knownWallets = Set(((try? ctx.fetch(FetchDescriptor<Wallet>())) ?? []).map(\.id))
            for row in remoteWallets {
                guard let localID = row.local_id.flatMap(UUID.init(uuidString:)),
                      !knownWallets.contains(localID) else { continue }
                let wallet = Wallet(id: localID, userId: row.user_id ?? ownerID, name: row.name,
                                    type: WalletType(rawValue: row.type ?? "bank") ?? .bank,
                                    currency: row.currency ?? "USD",
                                    balance: row.balance ?? 0,
                                    icon: row.icon ?? "")
                wallet.isSynced = true
                ctx.insert(wallet)
            }

            try ctx.save()
            loadCategories()
        } catch {
            Log.warn("Legacy cloud restore failed")
        }
    }

    // MARK: — Delete

    /// Records a tombstone through the ledger. The row is not removed: the
    /// intent to delete has to outlive this launch and reach other devices.
    /// Deleting the chat messages that mention it is a separate, local concern.
    @discardableResult
    func deleteTransaction(_ tx: Transaction, messages: [ChatMessage]) -> Bool {
        lastWriteErrorCode = nil
        guard let ctx = modelContext, let ledger else {
            lastWriteErrorCode = "storage_unavailable"
            return false
        }
        let scope = AuthService.shared.currentScope
        do {
            try ledger.deleteTransaction(id: tx.id, scope: scope)
        } catch let error as LedgerWriteError {
            lastWriteErrorCode = error.code
            return false
        } catch {
            lastWriteErrorCode = "save_failed"
            return false
        }

        let linked = messages.filter { $0.id == tx.linkedMessageID || $0.linkedTransactionID == tx.id }
        if !linked.isEmpty {
            linked.forEach { ctx.delete($0) }
            do { try ctx.save() } catch {
                // The transaction is already tombstoned and queued; failing to
                // tidy the chat does not undo that, and must not claim it did.
                Log.warn("Chat cleanup after delete failed")
            }
        }
        dispatchQueuedWork()
        return true
    }

    // MARK: — Wipe (signOut helper)
    func wipeLocalUserData() {
        guard let ctx = modelContext else { return }
        do {
            try ctx.delete(model: Transaction.self)
            try ctx.delete(model: Wallet.self)
            try ctx.delete(model: ChatMessage.self)
            // Keep AppSettings (language/currency preferences). Reset avatar/name only.
            if let settings = (try? ctx.fetch(FetchDescriptor<AppSettings>()))?.first {
                settings.userAvatar = nil
                settings.userName = ""
            }
            try ctx.save()
            userAvatar = nil
            userName = ""
        } catch {
            Log.error("Wipe local data failed")
        }
    }

    // MARK: — Display helpers
    func color(for name: String) -> Color { allCategories.first { $0.name == name }?.color ?? .gray }
    func icon(for name: String) -> String { allCategories.first { $0.name == name }?.icon ?? "questionmark.circle" }

    /// Localized category display name (English key → translated)
    func displayCategoryName(_ name: String) -> String {
        allCategories.first { $0.name == name }?.displayName ?? name
    }

    func matchCategoryKey(_ input: String) -> String {
        let lower = input.lowercased()
        if allCategories.contains(where: { $0.name.lowercased() == lower }) { return input }
        if let cat = allCategories.first(where: { $0.displayName.lowercased() == lower }) { return cat.name }
        let translations = LocalizationManager.shared.translations
        for cat in allCategories where cat.isDefault {
            let key = "cat_\(cat.name.lowercased())"
            if let dict = translations[key] {
                for (_, val) in dict where val.lowercased() == lower { return cat.name }
            }
        }
        return input
    }

}

// MARK: — Report Period
enum ReportPeriod: String, CaseIterable {
    case week = "week", month = "month", year = "year"

    var label: String {
        switch self {
        case .week:  return L("period_week")
        case .month: return L("period_month")
        case .year:  return L("period_year")
        }
    }

    var dateRange: (Date, Date) {
        let cal = Calendar.current
        let now = Date.now
        switch self {
        case .week:
            let start = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return (start, now)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps) ?? now
            let end = cal.date(byAdding: .month, value: 1, to: start) ?? now
            return (start, end)
        case .year:
            let comps = cal.dateComponents([.year], from: now)
            let start = cal.date(from: comps) ?? now
            let end = cal.date(byAdding: .year, value: 1, to: start) ?? now
            return (start, end)
        }
    }
}

// MARK: — Snapshot bridging
extension Transaction {
    func snapshot() -> TransactionSnapshot {
        TransactionSnapshot(
            localId: id.uuidString,
            userId: userId,
            typeRaw: typeRaw,
            originalAmount: originalAmount,
            originalCurrency: originalCurrency,
            amountInBase: amountInBase,
            baseCurrency: baseCurrency,
            rateAtTime: rateAtTime,
            categoryName: categoryName,
            merchant: merchant,
            note: note,
            occurredAt: occurredAt,
            sourceRaw: sourceRaw,
            confidence: confidence,
            rawInput: rawInput,
            walletName: walletName
        )
    }
}

extension Wallet {
    func snapshot() -> WalletSnapshot {
        WalletSnapshot(
            localId: id.uuidString,
            userId: userId,
            name: name,
            typeRaw: typeRaw,
            currency: currency,
            balance: balance,
            icon: icon
        )
    }
}

extension Category {
    func snapshot(userId: String) -> CategorySnapshot {
        CategorySnapshot(
            localId: id.uuidString,
            userId: userId,
            name: name,
            icon: icon,
            colorHex: colorHex,
            isDefault: isDefault,
            sortOrder: sortOrder,
            typeRaw: typeRaw
        )
    }
}
