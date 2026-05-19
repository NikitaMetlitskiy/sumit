import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = AppStore()
    @ObservedObject private var storeKit = StoreKitManager.shared
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var selectedTab = 0
    @State private var showPaywall = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatRootView(store: store)
                .tabItem { Label(L("tab_chat"), systemImage: "bubble.left.and.bubble.right") }
                .tag(0)

            ReportsView(store: store)
                .tabItem { Label(L("tab_reports"), systemImage: "chart.bar.xaxis") }
                .tag(1)

            SettingsView(store: store)
                .tabItem { Label(L("tab_settings"), systemImage: "gearshape") }
                .tag(2)
        }
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
