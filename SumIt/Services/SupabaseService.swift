import Foundation

actor SupabaseService {
    static let shared = SupabaseService()

    /// Injected for tests. Production keeps `.shared`, so no unit test can
    /// reach the network and no production call site changes.
    let ledgerSession: URLSession
    let ledgerAuth: LedgerAuth

    init(session: URLSession = .shared, auth: LedgerAuth = .live) {
        self.ledgerSession = session
        self.ledgerAuth = auth
    }

    var baseURL: String { AppConfig.supabaseURL }
    var anonKey: String { AppConfig.supabaseAnonKey }

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
    func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL? {
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

// MARK: — Ledger transport (Task 10)

/// Every way a ledger request can end, as a distinct case.
///
/// The methods this replaces returned `Void` and threw only on a decode error,
/// or — worse — did `_ = try await URLSession.shared.data(for: req)` and
/// discarded the response entirely, so an HTTP 404 against a table that did not
/// exist looked exactly like a successful save. Production shows the result of
/// that: five transactions naming wallets, and zero wallets on the server.
enum LedgerTransportError: Error, Equatable {
    /// The configured URL cannot be built. Never a silent `return`.
    case configuration
    /// 401 that survived one refresh. Pause and ask for sign-in; keep everything.
    case notAuthenticated
    /// 403. Show an access problem; do not hammer it.
    case accessDenied
    /// 400. The server rejected the content itself; retrying the same bytes
    /// cannot help, so the operation is blocked for correction.
    case validationRejected(code: String)
    /// 408/429/5xx. Worth retrying later, with the server's Retry-After if given.
    case retryable(status: Int, retryAfter: TimeInterval?)
    /// DNS, offline, timeout. The request may or may not have been received.
    case unreachable
    /// 2xx whose body is empty or unparseable — an **unknown** outcome, never
    /// an acceptance and never an empty dataset.
    case unknownOutcome
    /// A well-formed response that does not answer the question that was asked.
    case protocolMismatch
    /// The signed-in account changed while the request was in flight.
    case scopeChanged
}

/// The authentication facts the transport needs, injectable so a unit test can
/// drive refresh behaviour without touching the real session.
struct LedgerAuth: Sendable {
    var token: @Sendable () async -> String?
    var currentOwnerID: @Sendable () async -> String
    /// Returns true when a refresh produced a usable session.
    var refresh: @Sendable () async -> Bool

    static let live = LedgerAuth(
        token: { await MainActor.run { AuthService.shared.accessToken } },
        currentOwnerID: { await MainActor.run { AuthService.shared.userId } },
        refresh: { await AuthService.shared.refreshSessionIfNeeded() })
}

extension SupabaseService {

    /// Submits one frozen mutation and returns what the server actually said.
    func applyLedgerMutation(_ request: LedgerMutationRequest,
                             scope: AccountScope) async throws -> LedgerMutationResult {
        let payload: Data
        do { payload = try JSONEncoder().encode(request) }
        catch { throw LedgerTransportError.configuration }

        let data = try await callRPC("apply_ledger_mutation_v1", body: payload, scope: scope)

        let result: LedgerMutationResult
        do { result = try JSONDecoder().decode(LedgerMutationResult.self, from: data) }
        catch { throw LedgerTransportError.unknownOutcome }

        // The answer has to be to *this* question. A receipt for another
        // operation, entity or owner is a protocol failure, not an acceptance.
        guard result.operationID == request.operationID else {
            throw LedgerTransportError.protocolMismatch
        }
        switch result {
        case .accepted(let accepted):
            guard accepted.entityID == request.entityID,
                  accepted.snapshot.header.localID == request.entityID,
                  accepted.snapshot.header.userID == scope.ownerID else {
                throw LedgerTransportError.protocolMismatch
            }
        case .conflict(let conflict):
            guard conflict.entityID == request.entityID else {
                throw LedgerTransportError.protocolMismatch
            }
            if let snapshot = conflict.serverSnapshot,
               snapshot.header.userID != scope.ownerID {
                throw LedgerTransportError.protocolMismatch
            }
        }
        return result
    }

    /// Reads one bounded page of the owner's change feed.
    func readLedgerChanges(after: Int64, through: Int64? = nil,
                           limit: Int = 250,
                           scope: AccountScope) async throws -> LedgerChangePage {
        var arguments: [String: Any] = ["p_after_cursor": after, "p_limit": limit]
        arguments["p_through_cursor"] = through as Any? ?? NSNull()

        let payload: Data
        do { payload = try JSONSerialization.data(withJSONObject: arguments) }
        catch { throw LedgerTransportError.configuration }

        let data = try await callRPC("read_ledger_changes_v1", body: payload, scope: scope)

        let page: LedgerChangePage
        do { page = try JSONDecoder().decode(LedgerChangePage.self, from: data) }
        catch { throw LedgerTransportError.unknownOutcome }

        // A page that is not strictly ascending, steps outside its own window,
        // or carries another owner's row is not a page we may apply.
        var previous = after
        for change in page.changes {
            guard change.cursor.value > previous,
                  change.cursor.value <= page.throughCursor.value,
                  change.snapshot.header.userID == scope.ownerID,
                  change.snapshot.header.localID == change.entityID else {
                throw LedgerTransportError.protocolMismatch
            }
            previous = change.cursor.value
        }
        guard page.nextCursor.value >= after else { throw LedgerTransportError.protocolMismatch }
        return page
    }

    // MARK: Request plumbing

    /// One POST to a PostgREST RPC, with a single serialized refresh-and-retry
    /// on 401 and an account check on both sides of every await.
    private func callRPC(_ function: String, body: Data, scope: AccountScope) async throws -> Data {
        try await requireScope(scope)

        var refreshed = false
        while true {
            guard let token = await ledgerAuth.token() else {
                if refreshed { throw LedgerTransportError.notAuthenticated }
                refreshed = true
                guard await ledgerAuth.refresh() else { throw LedgerTransportError.notAuthenticated }
                try await requireScope(scope)
                continue
            }

            guard let url = endpoint("/rest/v1/rpc/\(function)") else {
                throw LedgerTransportError.configuration
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            request.timeoutInterval = 30

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await ledgerSession.data(for: request)
            } catch {
                // Offline, DNS failure or timeout. The server may or may not
                // have received it, so the operation stays retryable.
                throw LedgerTransportError.unreachable
            }
            try await requireScope(scope)

            guard let http = response as? HTTPURLResponse else {
                throw LedgerTransportError.unknownOutcome
            }

            switch http.statusCode {
            case 200...299:
                guard !data.isEmpty else { throw LedgerTransportError.unknownOutcome }
                return data

            case 401:
                // Exactly one refresh, then one retry of the same bytes.
                guard !refreshed else { throw LedgerTransportError.notAuthenticated }
                refreshed = true
                guard await ledgerAuth.refresh() else { throw LedgerTransportError.notAuthenticated }
                try await requireScope(scope)
                continue

            case 403:
                throw LedgerTransportError.accessDenied

            case 400, 409, 422:
                throw LedgerTransportError.validationRejected(code: Self.errorCode(from: data))

            case 408, 429, 500...599:
                throw LedgerTransportError.retryable(status: http.statusCode,
                                                     retryAfter: Self.retryAfter(from: http))

            default:
                throw LedgerTransportError.unknownOutcome
            }
        }
    }

    private func requireScope(_ scope: AccountScope) async throws {
        guard await ledgerAuth.currentOwnerID() == scope.ownerID else {
            throw LedgerTransportError.scopeChanged
        }
    }

    /// Keeps PostgREST's machine code, discards its prose. A backend payload is
    /// never shown to a user and never written to a log.
    private static func errorCode(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "rejected"
        }
        let raw = (object["message"] as? String) ?? (object["code"] as? String) ?? "rejected"
        let sanitized = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return sanitized.isEmpty ? "rejected" : String(sanitized.prefix(64))
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(header), seconds >= 0 else { return nil }
        // A server may not send us to sleep for an hour.
        return min(seconds, 300)
    }
}
