//
//  SumItApp.swift
//  SumIt
//
//  Created by Mykyta Metlytskyi on 25.03.2026.
//

import SwiftUI
import SwiftData
@preconcurrency import LocalAuthentication  // pre-Swift-concurrency API; LAContext is not Sendable
import UserNotifications
import Combine

@main
struct SumItApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appLock = AppLockManager()
    @StateObject private var storage = StorageBootstrap.makeForLaunch()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                // The financial UI is built only for a real, persistent container.
                // A failed open gets a recovery surface with no ModelContext at all;
                // it never gets an in-memory substitute that silently accepts writes.
                switch storage.state {
                case .opening:
                    Color(.systemBackground)
                case .ready(let container):
                    RootView()
                        .modelContainer(container)
                        .environmentObject(appLock)
                case .failed(let failure):
                    StorageRecoveryView(
                        failure: failure,
                        onRetry: { storage.retry() },
                        makeCopy: { try storage.makeRecoveryCopy(into: Self.recoveryCopyDirectory()) })
                }

                // Lock screen — always rendered, visibility controlled by opacity.
                // It stays above the recovery surface too: a storage failure must not
                // become a way past the PIN.
                LockScreenView()
                    .environmentObject(appLock)
                    .zIndex(10)
                    .opacity(appLock.isLocked ? 1 : 0)
                    .allowsHitTesting(appLock.isLocked)

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showSplash)
            .onAppear {
                // Lock synchronously *before* splash dismisses so chat never peeks
                appLock.lockOnLaunch()
                storage.open()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showSplash = false }
                }
            }
            // Nothing that touches data or the network starts until the store is open.
            .onChange(of: storage.state.isReady, initial: true) {
                guard let container = storage.state.container else { return }
                #if DEBUG
                StorageBootstrap.UITestHooks.seedIfRequested(container)
                #endif
                NotificationManager.shared.scheduleDailyReminderIfAuthorized()
            }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                appLock.handleBackground()
            case .active:
                appLock.handleReturnFromBackground()
                guard storage.state.isReady else { return }
                Task { _ = await AuthService.shared.refreshSessionIfNeeded() }
            default: break
            }
        }
    }

    /// Destination for a user-requested copy of the database. A temporary
    /// directory, created only when the user taps the button — the app never
    /// exports the store on its own.
    private static func recoveryCopyDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SumIt-recovery-copy", isDirectory: true)
    }
}

// MARK: — AppLockManager
@MainActor
final class AppLockManager: ObservableObject {
    @Published var isLocked = false

    @Published var pinEnabled: Bool {
        didSet { KeychainHelper.setString(pinEnabled ? "1" : "0", for: "pinEnabled") }
    }
    @Published var biometricEnabled: Bool {
        didSet { KeychainHelper.setString(biometricEnabled ? "1" : "0", for: "biometricEnabled") }
    }

    /// PIN is stored as a salted hash in Keychain. The raw PIN never lives in memory beyond verification.
    @Published private(set) var pinIsSet: Bool = false

    /// Biometrics cannot be evaluated on this device right now (not enrolled,
    /// no hardware, or locked out by the system).
    @Published private(set) var biometricUnavailable = false
    /// The biometric enrollment changed since this app trusted it, so a
    /// successful scan is not accepted on its own any more.
    @Published private(set) var needsBiometricReattestation = false

    /// Whether a PIN can actually be checked. `pinEnabled` alone is not enough:
    /// the flag can be on with no stored hash, and then every entry is wrong.
    var canUsePIN: Bool { pinEnabled && pinIsSet }

    /// Whether anything at all can unlock the app.
    private var canVerify: Bool { canUsePIN || biometricEnabled }

    private var backgroundedAt: Date?
    private var launchLockDone = false
    private var biometricInProgress = false
    private let lockDelay: TimeInterval = 0  // lock immediately — finance data is sensitive

    // Brute-force protection
    private var failedAttempts: Int = 0
    @Published private(set) var lockoutUntil: Date? = nil
    private let attemptsKey = "pin_failed_attempts"
    private let lockoutKey  = "pin_lockout_until"

    init() {
        self.pinEnabled       = KeychainHelper.getString("pinEnabled") == "1"
        self.biometricEnabled = KeychainHelper.getString("biometricEnabled") == "1"
        self.pinIsSet         = KeychainHelper.get("pin_hash") != nil
        self.failedAttempts   = Int(KeychainHelper.getString(attemptsKey) ?? "") ?? 0
        if let s = KeychainHelper.getString(lockoutKey), let t = TimeInterval(s) {
            let until = Date(timeIntervalSince1970: t)
            if until > .now { self.lockoutUntil = until }
        }
        // Migrate legacy plaintext PIN from UserDefaults if present.
        migrateLegacyPIN()
        healUnverifiableLock()
    }

    /// A PIN switched on with no stored hash locks the app with a lock that has
    /// no key: `unlockWithPIN` refuses every entry because there is nothing to
    /// compare against, and the lock screen covers the whole app — including
    /// sign-in. That state was reachable through `migrateLegacyPIN`, which
    /// turned the flag on from a UserDefaults value without writing a hash.
    /// The flag is switched off rather than left guarding nothing.
    private func healUnverifiableLock() {
        guard pinEnabled, !pinIsSet else { return }
        pinEnabled = false
        Log.warn("PIN was enabled without a stored hash; disabled it")
    }

    func lockOnLaunch() {
        guard !launchLockDone else { return }
        launchLockDone = true
        guard canVerify else { return }
        isLocked = true
        if biometricEnabled { runBiometric() }
    }

    func handleBackground() {
        guard canVerify else { return }
        backgroundedAt = Date()
        isLocked = true
    }

    func handleReturnFromBackground() {
        guard launchLockDone else { return }
        guard canVerify else { return }
        guard let bg = backgroundedAt else { return }

        if lockDelay > 0 && Date().timeIntervalSince(bg) < lockDelay {
            isLocked = false
            backgroundedAt = nil
            return
        }

        backgroundedAt = nil
        if biometricEnabled { runBiometric() }
    }

    // MARK: — Biometric
    func runBiometric() {
        guard !biometricInProgress else { return }
        biometricInProgress = true

        let ctx = LAContext()
        var authError: NSError?

        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            biometricInProgress = false
            biometricUnavailable = true
            // Nothing else can verify the owner, so keeping the app shut would
            // lock them out of their own data instead of protecting it.
            if !canUsePIN { unlock() }
            return
        }
        biometricUnavailable = false

        ctx.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: L("app_name")
        ) { success, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.biometricInProgress = false
                if success {
                    // Compare biometric enrollment fingerprint with the one we trusted on setup.
                    if let stored = KeychainHelper.get("bio_domain_state"),
                       let current = ctx.evaluatedPolicyDomainState,
                       stored != current {
                        // The enrollment changed, so this scan proves less than
                        // it seems. Previously this returned silently: the scan
                        // succeeded, the screen said nothing, and the app stayed
                        // shut. Now it says so, and falls back to the PIN — or
                        // opens if there is no PIN to fall back to.
                        self.needsBiometricReattestation = true
                        if !self.canUsePIN { self.unlock() }
                        return
                    }
                    if let domainState = ctx.evaluatedPolicyDomainState {
                        KeychainHelper.set(domainState, for: "bio_domain_state")
                    }
                    self.unlock()
                }
            }
        }
    }

    /// Opens the app and clears the lock-screen explanations.
    private func unlock() {
        isLocked = false
        needsBiometricReattestation = false
        biometricUnavailable = false
    }

    // MARK: — PIN
    func setPIN(_ pin: String) {
        let salt = SecurityHelper.randomSalt()
        let hash = SecurityHelper.hashPIN(pin, salt: salt)
        KeychainHelper.set(salt, for: "pin_salt")
        KeychainHelper.set(hash, for: "pin_hash")
        pinIsSet = true
        pinEnabled = true
        clearFailedAttempts()
    }

    func disablePIN() {
        KeychainHelper.remove("pin_salt")
        KeychainHelper.remove("pin_hash")
        pinIsSet = false
        pinEnabled = false
        clearFailedAttempts()
    }

    var isLockedOut: Bool {
        guard let until = lockoutUntil else { return false }
        if until <= .now {
            lockoutUntil = nil
            KeychainHelper.remove(lockoutKey)
            return false
        }
        return true
    }

    func unlockWithPIN(_ entered: String) -> Bool {
        if isLockedOut { return false }
        guard let salt = KeychainHelper.get("pin_salt"),
              let storedHash = KeychainHelper.get("pin_hash") else { return false }
        let attempt = SecurityHelper.hashPIN(entered, salt: salt)
        // Constant-time compare to avoid timing leaks (matters less here but cheap).
        guard constantTimeEqual(attempt, storedHash) else {
            recordFailedAttempt()
            return false
        }
        clearFailedAttempts()
        unlock()
        return true
    }

    private func recordFailedAttempt() {
        failedAttempts += 1
        KeychainHelper.setString("\(failedAttempts)", for: attemptsKey)
        if failedAttempts >= AppConfig.pinMaxAttempts {
            let tierIndex = min(failedAttempts - AppConfig.pinMaxAttempts, AppConfig.pinLockoutSeconds.count - 1)
            let lockoutSec = AppConfig.pinLockoutSeconds[max(0, tierIndex)]
            let until = Date.now.addingTimeInterval(lockoutSec)
            lockoutUntil = until
            KeychainHelper.setString("\(until.timeIntervalSince1970)", for: lockoutKey)
        }
    }

    private func clearFailedAttempts() {
        failedAttempts = 0
        KeychainHelper.remove(attemptsKey)
        KeychainHelper.remove(lockoutKey)
        lockoutUntil = nil
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func migrateLegacyPIN() {
        // If a plaintext PIN exists in UserDefaults from older builds, migrate to hashed Keychain storage.
        if let legacy = UserDefaults.standard.string(forKey: "appPin"), !legacy.isEmpty,
           KeychainHelper.get("pin_hash") == nil {
            setPIN(legacy)
            UserDefaults.standard.removeObject(forKey: "appPin")
            Log.info("Migrated legacy PIN")
        }
        // Migrate enable flags from UserDefaults.
        let legacyPinEnabled = UserDefaults.standard.bool(forKey: "pinEnabled")
        let legacyBioEnabled = UserDefaults.standard.bool(forKey: "biometricEnabled")
        if KeychainHelper.getString("pinEnabled") == nil && legacyPinEnabled { pinEnabled = true }
        if KeychainHelper.getString("biometricEnabled") == nil && legacyBioEnabled { biometricEnabled = true }
        UserDefaults.standard.removeObject(forKey: "pinEnabled")
        UserDefaults.standard.removeObject(forKey: "biometricEnabled")
    }
}

// MARK: — Splash
struct SplashView: View {
    @State private var progress: Double = 0
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("SumIt").font(.system(size: 32, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text(L("financial_assistant")).font(.subheadline).foregroundColor(.white.opacity(0.6))
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.15)).frame(height: 3)
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                }
                .frame(height: 3).padding(.horizontal, 60).padding(.bottom, 60)
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.3)) { progress = 1.0 } }
    }
}

// MARK: — Notifications
final class NotificationManager {
    static let shared = NotificationManager()

    /// Schedules the daily reminder only if the user has already granted notification permission.
    /// Permission is requested explicitly when the user toggles "Daily reminder" in Settings.
    func scheduleDailyReminderIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            self.installDailyRequest()
        }
    }

    /// Requests permission (if not yet decided) and schedules the reminder.
    func requestAndScheduleDailyReminder() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return false }
            } catch { return false }
        } else if settings.authorizationStatus == .denied {
            return false
        }
        installDailyRequest()
        return true
    }

    func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sumit-daily"])
    }

    private func installDailyRequest() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["sumit-daily"])
        let c = UNMutableNotificationContent()
        c.title = L("notif_title")
        c.body = L("notif_body")
        c.sound = .default
        var dc = DateComponents(); dc.hour = 10; dc.minute = 0
        center.add(
            UNNotificationRequest(
                identifier: "sumit-daily",
                content: c,
                trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
            )
        )
    }
}
