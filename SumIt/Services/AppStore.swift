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

    func setup(context: ModelContext) {
        self.modelContext = context
        seedCategoriesIfNeeded()
        loadCategories()
        loadSettings()
        Log.info("AppStore setup complete. Categories: \(self.allCategories.count)")

        Task {
            _ = await AuthService.shared.refreshSessionIfNeeded()
            await syncPendingTransactions()
            await syncPendingWallets()
            if AuthService.shared.isSignedIn {
                await restoreFromCloud()
            }
        }
    }

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

    // MARK: — Save confirmed transaction (atomic; wallet balance + sync)
    func saveConfirmed(parsed: ParsedTransaction, linkedMessageID: UUID? = nil) async -> Transaction? {
        guard let ctx = modelContext else { return nil }
        guard CurrencyService.isSupported(parsed.currency) else {
            Log.warn("Unsupported currency: \(parsed.currency)")
            return nil
        }
        let rate = CurrencyService.toUSD(parsed.currency)
        let tx = Transaction(
            userId: AuthService.shared.userId,
            type: parsed.type,
            originalAmount: parsed.amount,
            originalCurrency: parsed.currency,
            amountInBase: parsed.amount * rate,
            baseCurrency: "USD",
            rateAtTime: rate,
            categoryName: matchCategoryKey(parsed.categoryName),
            merchant: parsed.merchant,
            note: parsed.note,
            occurredAt: parsed.occurredAt,
            source: parsed.source,
            confidence: parsed.confidence,
            rawInput: parsed.rawInput,
            walletName: parsed.walletName,
            linkedMessageID: linkedMessageID,
            isSynced: false
        )

        ctx.insert(tx)
        applyWalletDelta(for: tx, sign: +1)
        do { try ctx.save() } catch { Log.error("Tx save failed"); return tx }

        // Fire-and-forget Supabase upload using a Sendable snapshot.
        let snap = tx.snapshot()
        let id = tx.id
        Task { [weak self] in
            do {
                try await SupabaseService.shared.saveTransaction(snap)
                await self?.markSynced(id: id)
            } catch {
                Log.warn("Supabase tx sync deferred")
            }
        }
        return tx
    }

    /// Wallet balance update — converts amount into wallet currency before applying.
    /// `sign` is +1 on save/income contribution, -1 on save/expense or on delete.
    private func applyWalletDelta(for tx: Transaction, sign: Double) {
        guard !tx.walletName.isEmpty, let ctx = modelContext else { return }
        let desc = FetchDescriptor<Wallet>()
        guard let wallets = try? ctx.fetch(desc),
              let wallet = wallets.first(where: { $0.name.lowercased() == tx.walletName.lowercased() }) else { return }
        let txEffect: Double = tx.type == .income ? +tx.originalAmount : -tx.originalAmount
        let inWalletCurrency = CurrencyService.convert(txEffect, from: tx.originalCurrency, to: wallet.currency)
        wallet.balance += inWalletCurrency * sign
        wallet.isSynced = false
    }

    private func markSynced(id: UUID) async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })
        if let tx = try? ctx.fetch(desc).first {
            tx.isSynced = true
            try? ctx.save()
        }
    }

    /// Mutate an existing transaction (used by edit sheets). Reconciles wallet balance
    /// from old values to new values and queues re-sync. Pass the *current* tx; new field values via closure.
    func editTransaction(_ tx: Transaction, apply mutate: (Transaction) -> Void) {
        guard let ctx = modelContext else { return }
        // Undo old wallet delta
        applyWalletDelta(for: tx, sign: -1)
        mutate(tx)
        // Apply new wallet delta
        applyWalletDelta(for: tx, sign: +1)
        // Recompute rateAtTime / amountInBase
        let rate = CurrencyService.toUSD(tx.originalCurrency)
        tx.rateAtTime = rate
        tx.amountInBase = tx.originalAmount * rate
        tx.isSynced = false
        try? ctx.save()
        let snap = tx.snapshot()
        let id = tx.id
        Task { [weak self] in
            try? await SupabaseService.shared.saveTransaction(snap)
            await self?.markSynced(id: id)
        }
    }

    // MARK: — Restore from Supabase
    func restoreFromCloud() async {
        guard let ctx = modelContext else { return }
        do {
            let remote = try await SupabaseService.shared.fetchTransactions()
            let existing = (try? ctx.fetch(FetchDescriptor<Transaction>()))?.compactMap { $0.id.uuidString } ?? []
            let existingSet = Set(existing)

            for r in remote {
                if r.deleted_at != nil { continue }
                if let localId = r.local_id, existingSet.contains(localId) { continue }
                let tx = Transaction(
                    userId: r.user_id ?? AuthService.shared.userId,
                    type: TransactionType(rawValue: r.type ?? "expense") ?? .expense,
                    originalAmount: r.original_amount,
                    originalCurrency: r.original_currency,
                    amountInBase: r.amount_in_base ?? r.original_amount,
                    baseCurrency: r.base_currency ?? "USD",
                    rateAtTime: r.rate_at_time ?? 1.0,
                    categoryName: r.category_name ?? "Other",
                    merchant: r.merchant ?? "",
                    note: r.note ?? "",
                    occurredAt: r.occurred_at.flatMap { Formatters.date(fromISO: $0) } ?? .now,
                    source: TransactionSource(rawValue: r.source ?? "text") ?? .text,
                    confidence: r.confidence ?? 0.8,
                    rawInput: r.raw_input ?? "",
                    walletName: r.wallet_name ?? "",
                    isSynced: true
                )
                ctx.insert(tx)
            }
            try? ctx.save()

            // Restore custom categories
            let remoteCats = (try? await SupabaseService.shared.fetchCategories()) ?? []
            let existingCatIds = Set((try? ctx.fetch(FetchDescriptor<Category>()))?.map { $0.id.uuidString } ?? [])
            for c in remoteCats where !(c.is_default ?? false) {
                if let localId = c.local_id, existingCatIds.contains(localId) { continue }
                let cat = Category(
                    name: c.name,
                    icon: c.icon ?? "tag",
                    colorHex: c.color_hex ?? "5271B4",
                    type: c.type ?? "expense",
                    isDefault: false,
                    sortOrder: c.sort_order ?? 99
                )
                ctx.insert(cat)
            }

            // Restore wallets
            let remoteWallets = (try? await SupabaseService.shared.fetchWallets()) ?? []
            let existingWalletIds = Set((try? ctx.fetch(FetchDescriptor<Wallet>()))?.map { $0.id.uuidString } ?? [])
            for w in remoteWallets {
                if let localId = w.local_id, existingWalletIds.contains(localId) { continue }
                let wallet = Wallet(
                    userId: w.user_id ?? AuthService.shared.userId,
                    name: w.name,
                    type: WalletType(rawValue: w.type ?? "bank") ?? .bank,
                    currency: w.currency ?? "USD",
                    balance: w.balance ?? 0,
                    icon: w.icon ?? ""
                )
                wallet.isSynced = true
                ctx.insert(wallet)
            }
            try? ctx.save()
            loadCategories()
        } catch {
            Log.warn("Cloud restore failed")
        }
    }

    // MARK: — Pending sync queues
    func syncPendingTransactions() async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.isSynced == false })
        guard let unsynced = try? ctx.fetch(desc), !unsynced.isEmpty else { return }
        let snaps = unsynced.map { $0.snapshot() }
        let syncedIds = await SupabaseService.shared.syncUnsynced(snaps)
        let syncedSet = Set(syncedIds)
        for tx in unsynced where syncedSet.contains(tx.id.uuidString) {
            tx.isSynced = true
        }
        try? ctx.save()
    }

    func syncPendingWallets() async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<Wallet>(predicate: #Predicate<Wallet> { $0.isSynced == false })
        guard let unsynced = try? ctx.fetch(desc), !unsynced.isEmpty else { return }
        for w in unsynced {
            let snap = w.snapshot()
            do {
                try await SupabaseService.shared.saveWallet(snap)
                w.isSynced = true
            } catch {
                Log.warn("Wallet sync deferred")
            }
        }
        try? ctx.save()
    }

    // MARK: — Delete (reverses wallet balance, soft-deletes remotely)
    func deleteTransaction(_ tx: Transaction, messages: [ChatMessage]) {
        guard let ctx = modelContext else { return }
        let localId = tx.id.uuidString

        applyWalletDelta(for: tx, sign: -1)

        messages.filter { $0.id == tx.linkedMessageID || $0.linkedTransactionID == tx.id }
            .forEach { ctx.delete($0) }

        ctx.delete(tx)
        try? ctx.save()

        Task {
            try? await SupabaseService.shared.deleteTransaction(localId: localId)
        }
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

    // MARK: — Wallet balances helper (used for Reports.WalletsSection)
    struct WalletBalance {
        let name: String
        let icon: String
        var totalUSD: Double
        var currencies: [String: Double]
    }

    func walletBalances(from txs: [Transaction]) -> [WalletBalance] {
        var map: [String: WalletBalance] = [:]
        for tx in txs where !tx.walletName.isEmpty {
            let w = tx.walletName
            var bal = map[w] ?? WalletBalance(name: w, icon: walletIcon(w), totalUSD: 0, currencies: [:])
            let sign: Double = tx.type == .income ? 1 : -1
            bal.totalUSD += tx.amountInBase * sign
            bal.currencies[tx.originalCurrency, default: 0] += tx.originalAmount * sign
            map[w] = bal
        }
        return map.values.sorted { abs($0.totalUSD) > abs($1.totalUSD) }
    }

    private func walletIcon(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("binance") { return "bitcoinsign.circle.fill" }
        if l.contains("mono")    { return "creditcard.fill" }
        if l.contains("cash") || l.contains("налич") { return "banknote.fill" }
        if l.contains("privat")  { return "building.columns.fill" }
        return "wallet.pass.fill"
    }

    // MARK: — Display helpers
    func display(amountUSD: Double) -> String {
        let converted = amountUSD * CurrencyService.usdTo(displayCurrency)
        return Formatters.amount(converted, currency: displayCurrency, fractionDigits: 2)
    }

    func toDisplay(_ usd: Double) -> Double { usd * CurrencyService.usdTo(displayCurrency) }
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

    func totalExpenses(_ txs: [Transaction]) -> Double { txs.filter { $0.type == .expense }.reduce(0) { $0 + $1.amountInBase } }
    func totalIncome(_ txs: [Transaction]) -> Double   { txs.filter { $0.type == .income  }.reduce(0) { $0 + $1.amountInBase } }
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
