import StoreKit
import SwiftUI
import Combine

// MARK: — Subscription Tier
enum SubscriptionTier: String, CaseIterable, Codable {
    case none  = "none"
    case basic = "basic"
    case pro   = "pro"

    var productId: String {
        switch self {
        case .none:  return ""
        case .basic: return "com.mykyta.SumIt.basic.monthly"
        case .pro:   return "com.mykyta.SumIt.pro.monthly"
        }
    }

    var label: String {
        switch self {
        case .none:  return L("not_selected")
        case .basic: return "Basic"
        case .pro:   return "Pro"
        }
    }

    var parseLimit: Int {
        switch self {
        case .none:  return 0
        case .basic: return 100
        case .pro:   return .max
        }
    }

    var transactionLimit: Int {
        switch self {
        case .none:  return 0
        case .basic: return 500
        case .pro:   return .max
        }
    }

    var gptModel: String {
        switch self {
        case .none, .basic: return "gpt-4o-mini"
        case .pro:          return "gpt-4o"
        }
    }
}

@MainActor
final class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()

    @Published var currentTier: SubscriptionTier = .none
    @Published var products: [Product] = []
    @Published var purchaseInProgress = false
    @Published var monthlyParseCount: Int = 0
    @Published var errorMessage: String? = nil

    private var transactionListener: Task<Void, Never>?
    private let productIds = [
        "com.mykyta.SumIt.basic.monthly",
        "com.mykyta.SumIt.pro.monthly"
    ]

    private init() {
        transactionListener = listenForTransactions()
        loadParseCount()
    }

    deinit { transactionListener?.cancel() }

    func setup() async {
        await loadProducts()
        await refreshSubscriptionStatus()
    }

    func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: Set(productIds))
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            Log.error("Products load error")
        }
    }

    func purchase(_ product: Product) async -> Bool {
        purchaseInProgress = true
        errorMessage = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let tx: StoreKit.Transaction = try checkVerified(verification)
                await updateTier(from: tx)
                // Forward JWS to server for authoritative validation.
                await reportPurchase(jws: jws(of: tx))
                await tx.finish()
                purchaseInProgress = false
                return true
            case .userCancelled:
                purchaseInProgress = false
                return false
            case .pending:
                purchaseInProgress = false
                errorMessage = L("purchase_pending")
                return false
            @unknown default:
                purchaseInProgress = false
                return false
            }
        } catch {
            purchaseInProgress = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func restorePurchases() async {
        do {
            try await StoreKit.AppStore.sync()
            await refreshSubscriptionStatus()
        } catch {
            errorMessage = L("restore_failed")
        }
    }

    func refreshSubscriptionStatus() async {
        var found: SubscriptionTier = .none
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            if tx.revocationDate != nil { continue }
            if tx.productID == SubscriptionTier.pro.productId {
                found = .pro; break
            } else if tx.productID == SubscriptionTier.basic.productId {
                found = .basic
            }
        }
        currentTier = found
        loadParseCount()
    }

    var hasActiveSubscription: Bool {
        // When paywall is disabled, treat the user as Pro for gating purposes
        // so dev/TestFlight builds don't trip subscription-required checks.
        if !PAYWALL_ENABLED { return true }
        return currentTier != .none
    }

    var effectiveTier: SubscriptionTier {
        PAYWALL_ENABLED ? currentTier : .pro
    }

    var canParse: Bool {
        guard PAYWALL_ENABLED else { return true }
        guard currentTier != .none else { return false }
        return monthlyParseCount < currentTier.parseLimit
    }

    var parsesRemaining: Int {
        guard PAYWALL_ENABLED else { return .max }
        return currentTier == .pro ? .max : max(0, currentTier.parseLimit - monthlyParseCount)
    }

    func incrementParseCount() {
        resetIfNewMonth()
        monthlyParseCount += 1
        UserDefaults.standard.set(monthlyParseCount, forKey: "sk_parseCount")
    }

    // MARK: — Private
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard case .verified(let tx) = result else { continue }
                // Pull JWS via a helper that takes the type explicitly — needed because
                // our SwiftData model is also named `Transaction` and shadows the StoreKit one.
                await self?.updateTier(from: tx)
                await self?.reportPurchase(jws: StoreKitManager.jwsString(of: tx))
                await tx.finish()
            }
        }
    }

    /// Small disambiguating helper. The parameter type is fully-qualified so the
    /// compiler can't accidentally resolve `.jwsRepresentation` against our model.
    nonisolated static func jwsString(of tx: StoreKit.Transaction) -> String {
        tx.jwsRepresentation
    }

    /// Instance-level convenience that delegates to the static helper.
    private func jws(of tx: StoreKit.Transaction) -> String {
        Self.jwsString(of: tx)
    }

    private func updateTier(from tx: StoreKit.Transaction) async {
        if tx.revocationDate != nil {
            await refreshSubscriptionStatus()
            return
        }
        if tx.productID == SubscriptionTier.pro.productId { currentTier = .pro }
        else if tx.productID == SubscriptionTier.basic.productId { currentTier = .basic }
    }

    /// Send signed JWS to backend so server validates with App Store Server API
    /// and writes `profiles.subscription_tier` itself. Client never writes the tier.
    private func reportPurchase(jws: String) async {
        guard let url = URL(string: "\(AppConfig.backendURL)/api/storekit/verify") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jws": jws])
        _ = try? await URLSession.shared.data(for: req)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let err): throw err
        case .verified(let item): return item
        }
    }

    private func loadParseCount() {
        resetIfNewMonth()
        monthlyParseCount = UserDefaults.standard.integer(forKey: "sk_parseCount")
    }

    /// Resets parse counter when the YYYY-MM tag changes. Year-aware so December rolls over correctly.
    private func resetIfNewMonth() {
        let now = Date.now
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: now)
        let tag = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
        let saved = UserDefaults.standard.string(forKey: "sk_parseMonthTag") ?? ""
        if saved != tag {
            monthlyParseCount = 0
            UserDefaults.standard.set(0, forKey: "sk_parseCount")
            UserDefaults.standard.set(tag, forKey: "sk_parseMonthTag")
        }
    }

    func product(for tier: SubscriptionTier) -> Product? {
        products.first { $0.id == tier.productId }
    }
}
