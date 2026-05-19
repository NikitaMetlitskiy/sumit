import SwiftUI
import SwiftData

/// Single-screen home for the redesigned app. No TabView — Reports/Settings/Wallets
/// are reached via the QuickSummarySheet (opened by tapping the chevron at the top).
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = AppStore()
    @ObservedObject private var storeKit = StoreKitManager.shared
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var showPaywall = false

    var body: some View {
        HomeView(store: store)
            .environment(\.locale, Locale(identifier: localization.current.rawValue))
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear {
                store.setup(context: modelContext)
                Task { await storeKit.setup() }
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall)
            }
            .onChange(of: auth.isSignedIn) { checkPaywall() }
            .onChange(of: storeKit.currentTier) { checkPaywall() }
    }

    private func checkPaywall() {
        guard PAYWALL_ENABLED else { return }
        if auth.isSignedIn && !storeKit.hasActiveSubscription {
            showPaywall = true
        } else {
            showPaywall = false
        }
    }
}
