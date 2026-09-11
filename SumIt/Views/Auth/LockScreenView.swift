import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @EnvironmentObject var appLock: AppLockManager
    @State private var enteredPIN = ""
    @State private var shake = false
    @State private var wrongAttempts = 0
    @State private var lockoutRemaining: TimeInterval = 0
    @State private var lockoutTimer: Timer? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.bottom, 8)

                Text("SumIt")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 48)

                HStack(spacing: 20) {
                    ForEach(0..<4) { i in
                        Circle()
                            .fill(i < enteredPIN.count ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.bottom, 8)
                .offset(x: shake ? -8 : 0)
                .animation(
                    .interpolatingSpring(stiffness: 400, damping: 8)
                    .repeatCount(shake ? 3 : 0),
                    value: shake
                )

                if appLock.isLockedOut {
                    Text(lockoutLabel)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.bottom, 40)
                } else {
                    // What this screen says has to match what it can actually
                    // check. Asking for a code that cannot be verified is how
                    // it turned into a dead end.
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsProblem ? .red : .white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 40)
                        .accessibilityIdentifier("lock-status")
                }

                let rows: [[String]] = [
                    ["1","2","3"],
                    ["4","5","6"],
                    ["7","8","9"],
                    ["⌫","0","FaceID"]
                ]
                VStack(spacing: 16) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 24) {
                            ForEach(row, id: \.self) { key in
                                PINButton(key: key) { handleKey(key) }
                                    .disabled(keyIsDisabled(key))
                                    .opacity(keyIsDisabled(key) ? 0.3 : 1)
                            }
                        }
                    }
                }

                Spacer()
            }
        }
        .onAppear(perform: startLockoutTickerIfNeeded)
        .onDisappear { lockoutTimer?.invalidate() }
        .onChange(of: appLock.lockoutUntil) { startLockoutTickerIfNeeded() }
    }

    /// Digits are pointless when there is no PIN to check them against.
    private func keyIsDisabled(_ key: String) -> Bool {
        guard key != "FaceID" else { return false }
        return appLock.isLockedOut || !appLock.canUsePIN
    }

    private var statusMessage: String {
        if appLock.needsBiometricReattestation { return L("lock_biometric_changed") }
        if !appLock.canUsePIN {
            return appLock.biometricUnavailable ? L("lock_biometric_unavailable") : L("lock_no_pin")
        }
        if wrongAttempts > 0 { return L("wrong_code") }
        return L("enter_code")
    }

    private var statusIsProblem: Bool {
        wrongAttempts > 0 || appLock.needsBiometricReattestation
            || appLock.biometricUnavailable || !appLock.canUsePIN
    }

    private var lockoutLabel: String {
        let seconds = Int(lockoutRemaining.rounded(.up))
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes > 0 {
            return String(format: L("pin_locked_min"), minutes, secs)
        }
        return String(format: L("pin_locked_sec"), secs)
    }

    private func startLockoutTickerIfNeeded() {
        lockoutTimer?.invalidate()
        guard let until = appLock.lockoutUntil else { lockoutRemaining = 0; return }
        lockoutRemaining = until.timeIntervalSinceNow
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            DispatchQueue.main.async {
                lockoutRemaining = until.timeIntervalSinceNow
                if lockoutRemaining <= 0 {
                    t.invalidate()
                    wrongAttempts = 0
                }
            }
        }
    }

    func handleKey(_ key: String) {
        switch key {
        case "⌫":
            if !enteredPIN.isEmpty { enteredPIN.removeLast() }

        case "FaceID":
            appLock.runBiometric()

        default:
            guard !appLock.isLockedOut else { return }
            guard enteredPIN.count < 4 else { return }
            enteredPIN += key
            if enteredPIN.count == 4 {
                let pin = enteredPIN
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    if appLock.unlockWithPIN(pin) {
                        // success — isLocked becomes false automatically
                    } else {
                        wrongAttempts += 1
                        shake = true
                        try? await Task.sleep(for: .milliseconds(500))
                        shake = false
                        enteredPIN = ""
                        startLockoutTickerIfNeeded()
                    }
                }
            }
        }
    }
}

// MARK: — PIN Button
struct PINButton: View {
    let key: String
    let action: () -> Void

    var isSymbol: Bool { key == "⌫" || key == "FaceID" }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isSymbol ? 0 : 0.1))
                    .frame(width: 72, height: 72)

                if key == "FaceID" {
                    Image(systemName: "faceid")
                        .font(.system(size: 26))
                        .foregroundColor(.white.opacity(0.8))
                } else if key == "⌫" {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.8))
                } else {
                    Text(key)
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
