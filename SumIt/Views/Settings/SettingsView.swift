import SwiftUI
import SwiftData
import StoreKit
import UserNotifications

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var storeKit: StoreKitManager = .shared
    @ObservedObject var localization: LocalizationManager = .shared
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.modelContext) private var modelContext

    @State private var showCurrencyPicker = false
    @State private var showCategoryManager = false
    @State private var showPINSetup = false
    @State private var showProfileEdit = false
    @State private var showPaywallSheet = false
    @State private var showWalletManager = false
    @State private var dailyOn = true
    @State private var weeklyOn = UserDefaults.standard.object(forKey: "weeklyOn") as? Bool ?? true

    var body: some View {
        NavigationView {
            List {
                profileSection
                preferencesSection
                if PAYWALL_ENABLED { subscriptionSection }
                financeSection
                notificationsSection
                securitySection
                aboutSection
            }
            .navigationTitle(L("settings_title"))
            .onAppear { loadNotificationState() }
            .sheet(isPresented: $showCurrencyPicker) { CurrencyPickerSheet(store: store) }
            .sheet(isPresented: $showCategoryManager) { CategoryManagerSheet(store: store) }
            .sheet(isPresented: $showPINSetup) { PINSetupView().environmentObject(appLock) }
            .sheet(isPresented: $showProfileEdit) { ProfileEditView(store: store) }
            .sheet(isPresented: $showPaywallSheet) { PaywallView(isPresented: $showPaywallSheet) }
            .sheet(isPresented: $showWalletManager) { WalletManagerSheet(store: store) }
        }
    }

    // MARK: — Profile
    @ViewBuilder
    private var profileSection: some View {
        Section {
            Button { showProfileEdit = true } label: {
                HStack(spacing: 14) {
                    avatarView
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.userName.isEmpty ? L("user_default") : store.userName)
                            .font(.headline).foregroundColor(.primary)
                        Text(store.userName.isEmpty ? L("setup_profile") : L("edit_profile"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let img = store.userAvatar {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 52, height: 52).clipShape(Circle())
        } else if store.userName.isEmpty {
            Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 52, height: 52)
                .overlay(Image(systemName: "person.fill").font(.title3).foregroundColor(Color.accentColor))
        } else {
            Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 52, height: 52)
                .overlay(Text(String(store.userName.prefix(1)))
                    .font(.title2.weight(.semibold)).foregroundColor(Color.accentColor))
        }
    }

    // MARK: — Preferences
    @ViewBuilder
    private var preferencesSection: some View {
        Section(L("preferences")) {
            Button { showCurrencyPicker = true } label: {
                HStack {
                    Label(L("currency"), systemImage: "dollarsign.circle").foregroundColor(.primary)
                    Spacer()
                    Text(store.displayCurrency).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
            }
            Picker(selection: $localization.current) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text("\(lang.flag) \(lang.displayName)").tag(lang)
                }
            } label: {
                Label(L("language"), systemImage: "globe")
            }
            .onChange(of: localization.current) {
                localization.setLanguage(localization.current)
            }
        }
    }

    // MARK: — Subscription (only when paywall enabled)
    @ViewBuilder
    private var subscriptionSection: some View {
        Section(L("subscription")) {
            if storeKit.currentTier != .none {
                HStack {
                    Image(systemName: storeKit.currentTier == .pro ? "star.fill" : "star")
                        .foregroundColor(storeKit.currentTier == .pro ? .yellow : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SumIt \(storeKit.currentTier.label)")
                            .font(.system(size: 15, weight: .medium))
                        if storeKit.currentTier == .basic {
                            Text(String(format: L("parses_left_month"), storeKit.parsesRemaining))
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text(L("unlimited_access")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Text(L("active")).font(.caption).foregroundColor(.green)
                }
                if storeKit.currentTier == .basic {
                    Button { showPaywallSheet = true } label: {
                        HStack {
                            Label(L("upgrade_to_pro"), systemImage: "arrow.up.circle")
                                .foregroundColor(.accentColor)
                            Spacer()
                            if let price = storeKit.product(for: .pro)?.displayPrice {
                                Text("\(price) \(L("per_month"))").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else {
                Button { showPaywallSheet = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "crown.fill").foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("subscribe_plan"))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text(L("subscribe_subtitle"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: — Finance
    @ViewBuilder
    private var financeSection: some View {
        Section(L("finance")) {
            Button { showCategoryManager = true } label: {
                Label(L("categories"), systemImage: "tag").foregroundColor(.primary)
            }
            Button { showWalletManager = true } label: {
                Label(L("wallets"), systemImage: "creditcard").foregroundColor(.primary)
            }
        }
    }

    // MARK: — Notifications
    @ViewBuilder
    private var notificationsSection: some View {
        Section(L("notifications")) {
            Toggle(isOn: $dailyOn) {
                Label(L("daily_reminder"), systemImage: "bell.fill")
            }
            .onChange(of: dailyOn) {
                if dailyOn {
                    Task { _ = await NotificationManager.shared.requestAndScheduleDailyReminder() }
                } else {
                    NotificationManager.shared.cancelDailyReminder()
                }
            }
            Toggle(isOn: $weeklyOn) {
                Label(L("weekly_report"), systemImage: "chart.bar")
            }
            .onChange(of: weeklyOn) {
                UserDefaults.standard.set(weeklyOn, forKey: "weeklyOn")
            }
        }
    }

    // MARK: — Security
    @ViewBuilder
    private var securitySection: some View {
        Section(L("security")) {
            Toggle(isOn: $appLock.biometricEnabled) {
                Label(L("face_id"), systemImage: "faceid")
            }
            if appLock.pinIsSet {
                Button { showPINSetup = true } label: {
                    Label(L("change_pin"), systemImage: "lock.rotation").foregroundColor(.primary)
                }
                Button(role: .destructive) { appLock.disablePIN() } label: {
                    Label(L("disable_pin"), systemImage: "lock.open")
                }
            } else {
                Button { showPINSetup = true } label: {
                    Label(L("set_pin"), systemImage: "lock.fill").foregroundColor(.primary)
                }
            }
        }
    }

    // MARK: — About
    @ViewBuilder
    private var aboutSection: some View {
        Section(L("about")) {
            HStack {
                Label(L("version"), systemImage: "info.circle")
                Spacer()
                Text(versionString).foregroundColor(.secondary)
            }
            Button {} label: { Label(L("support"), systemImage: "questionmark.circle").foregroundColor(.primary) }
            Button {} label: { Label(L("privacy"), systemImage: "hand.raised").foregroundColor(.primary) }
        }
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "v\(v)"
    }

    private func loadNotificationState() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            DispatchQueue.main.async {
                dailyOn = requests.contains { $0.identifier == "sumit-daily" }
            }
        }
    }
}
