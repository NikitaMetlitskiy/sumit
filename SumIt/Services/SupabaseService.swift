import Foundation

actor SupabaseService {
    static let shared = SupabaseService()

    private var baseURL: String { AppConfig.supabaseURL }
    private var anonKey: String { AppConfig.supabaseAnonKey }

    // MARK: — Auth headers
    /// Builds Supabase REST headers. If user is not signed in, returns nil
    /// to signal that the caller should not write to authenticated tables.
    private func authHeaders(requireAuth: Bool = true) async -> [String: String]? {
        let token = await MainActor.run { AuthService.shared.accessToken }
        if requireAuth && token == nil { return nil }
        return [
            "apikey": anonKey,
            "Content-Type": "application/json",
            "Authorization": "Bearer \(token ?? anonKey)"
        ]
    }

    // MARK: — URL building helpers
    private func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    // MARK: — Save transaction (idempotent upsert by local_id)
    func saveTransaction(_ tx: TransactionSnapshot) async throws {
        guard let url = endpoint("/rest/v1/transactions",
                                 query: [URLQueryItem(name: "on_conflict", value: "local_id")]) else { return }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }

        let body: [String: Any] = [
            "user_id":           tx.userId,
            "type":              tx.typeRaw,
            "original_amount":   tx.originalAmount,
            "original_currency": tx.originalCurrency,
            "amount_in_base":    tx.amountInBase,
            "base_currency":     tx.baseCurrency,
            "rate_at_time":      tx.rateAtTime,
            "category_name":     tx.categoryName,
            "merchant":          tx.merchant,
            "note":              tx.note,
            "occurred_at":       Formatters.iso(tx.occurredAt),
            "source":            tx.sourceRaw,
            "confidence":        tx.confidence,
            "raw_input":         tx.rawInput,
            "wallet_name":       tx.walletName,
            "local_id":          tx.localId
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        // Upsert: server resolves on local_id unique index; retries are idempotent.
        req.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
            Log.warn("Supabase save \(http.statusCode)")
            throw SupabaseError.saveFailed(http.statusCode)
        }
    }

    // MARK: — Delete transaction (soft delete via tombstone column, see DB migration)
    func deleteTransaction(localId: String) async throws {
        guard let url = endpoint("/rest/v1/transactions",
                                 query: [URLQueryItem(name: "local_id", value: "eq.\(localId)")]) else { return }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["deleted_at": Formatters.iso(Date.now)])

        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
            Log.warn("Supabase soft-delete \(http.statusCode)")
        }
    }

    // MARK: — Fetch all (non-deleted) transactions for current user
    func fetchTransactions() async throws -> [RemoteTransaction] {
        let userId = await MainActor.run { AuthService.shared.userId }
        guard userId != "local" else { return [] }
        guard let url = endpoint(
            "/rest/v1/transactions",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "deleted_at", value: "is.null"),
                URLQueryItem(name: "order", value: "occurred_at.desc"),
                URLQueryItem(name: "limit", value: "1000")
            ]
        ) else { return [] }

        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw SupabaseError.fetchFailed(code)
        }

        return try JSONDecoder().decode([RemoteTransaction].self, from: data)
    }

    // MARK: — Sync unsynced transactions with token refresh + early abort on 401
    func syncUnsynced(_ snapshots: [TransactionSnapshot]) async -> [String] {
        // Returns local_ids that were successfully synced.
        _ = await AuthService.shared.refreshSessionIfNeeded()
        var synced: [String] = []
        for snap in snapshots {
            do {
                try await saveTransaction(snap)
                synced.append(snap.localId)
            } catch SupabaseError.notAuthenticated {
                break
            } catch SupabaseError.saveFailed(let code) where code == 401 {
                break
            } catch {
                Log.warn("Sync retry failed")
            }
        }
        return synced
    }

    // MARK: — Wallet
    func saveWallet(_ snap: WalletSnapshot) async throws {
        guard let url = endpoint("/rest/v1/wallets",
                                 query: [URLQueryItem(name: "on_conflict", value: "local_id")]) else { return }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }
        let body: [String: Any] = [
            "user_id":  snap.userId,
            "name":     snap.name,
            "type":     snap.typeRaw,
            "currency": snap.currency,
            "balance":  snap.balance,
            "icon":     snap.icon,
            "local_id": snap.localId
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    func deleteWallet(localId: String) async throws {
        guard let url = endpoint("/rest/v1/wallets",
                                 query: [URLQueryItem(name: "local_id", value: "eq.\(localId)")]) else { return }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        _ = try await URLSession.shared.data(for: req)
    }

    func fetchWallets() async throws -> [RemoteWallet] {
        let userId = await MainActor.run { AuthService.shared.userId }
        guard userId != "local" else { return [] }
        guard let url = endpoint(
            "/rest/v1/wallets",
            query: [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        ) else { return [] }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode([RemoteWallet].self, from: data)) ?? []
    }

    // MARK: — Category
    func saveCategory(_ snap: CategorySnapshot) async throws {
        guard let url = endpoint("/rest/v1/categories",
                                 query: [URLQueryItem(name: "on_conflict", value: "local_id")]) else { return }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }
        let body: [String: Any] = [
            "user_id":    snap.userId,
            "name":       snap.name,
            "icon":       snap.icon,
            "color_hex":  snap.colorHex,
            "is_default": snap.isDefault,
            "sort_order": snap.sortOrder,
            "type":       snap.typeRaw,
            "local_id":   snap.localId
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    func fetchCategories() async throws -> [RemoteCategory] {
        let userId = await MainActor.run { AuthService.shared.userId }
        guard userId != "local" else { return [] }
        guard let url = endpoint(
            "/rest/v1/categories",
            query: [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        ) else { return [] }
        guard let headers = await authHeaders() else { throw SupabaseError.notAuthenticated }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode([RemoteCategory].self, from: data)) ?? []
    }

    // MARK: — Profile (read only; server is source of truth for subscription_tier)
    func fetchProfile(userId: String) async throws -> RemoteProfile? {
        guard !userId.isEmpty, userId != "local" else { return nil }
        guard let url = endpoint(
            "/rest/v1/profiles",
            query: [
                URLQueryItem(name: "id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "*")
            ]
        ) else { return nil }
        guard let headers = await authHeaders() else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await URLSession.shared.data(for: req)
        let profiles = (try? JSONDecoder().decode([RemoteProfile].self, from: data)) ?? []
        return profiles.first
    }
}

// MARK: — Snapshots (Sendable, plain data — safe to pass into actor/Task boundaries)
struct TransactionSnapshot: Sendable {
    let localId: String
    let userId: String
    let typeRaw: String
    let originalAmount: Double
    let originalCurrency: String
    let amountInBase: Double
    let baseCurrency: String
    let rateAtTime: Double
    let categoryName: String
    let merchant: String
    let note: String
    let occurredAt: Date
    let sourceRaw: String
    let confidence: Double
    let rawInput: String
    let walletName: String
}

struct WalletSnapshot: Sendable {
    let localId: String
    let userId: String
    let name: String
    let typeRaw: String
    let currency: String
    let balance: Double
    let icon: String
}

struct CategorySnapshot: Sendable {
    let localId: String
    let userId: String
    let name: String
    let icon: String
    let colorHex: String
    let isDefault: Bool
    let sortOrder: Int
    let typeRaw: String
}

// MARK: — Remote DTOs
struct RemoteTransaction: Decodable {
    let id: String
    let user_id: String?
    let type: String?
    let original_amount: Double
    let original_currency: String
    let amount_in_base: Double?
    let base_currency: String?
    let rate_at_time: Double?
    let category_name: String?
    let merchant: String?
    let note: String?
    let occurred_at: String?
    let source: String?
    let confidence: Double?
    let raw_input: String?
    let wallet_name: String?
    let local_id: String?
    let deleted_at: String?
}

struct RemoteWallet: Decodable {
    let id: String
    let user_id: String?
    let name: String
    let type: String?
    let currency: String?
    let balance: Double?
    let icon: String?
    let local_id: String?
}

struct RemoteCategory: Decodable {
    let id: String
    let user_id: String?
    let name: String
    let icon: String?
    let color_hex: String?
    let is_default: Bool?
    let sort_order: Int?
    let type: String?
    let local_id: String?
}

struct RemoteProfile: Decodable {
    let id: String
    let subscription_tier: String?
    let subscription_expires_at: String?
    let monthly_parse_count: Int?
    let total_transaction_count: Int?
}

// MARK: — Errors
enum SupabaseError: LocalizedError {
    case notAuthenticated
    case saveFailed(Int)
    case fetchFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return L("auth_required")
        case .saveFailed(let c): return "Supabase save error: \(c)"
        case .fetchFailed(let c): return "Supabase fetch error: \(c)"
        }
    }
}
