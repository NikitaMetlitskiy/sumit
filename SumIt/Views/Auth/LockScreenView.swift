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
                    Text(wrongAttempts > 0 ? L("wrong_code") : L("enter_code"))
                        .font(.caption)
                        .foregroundColor(wrongAttempts > 0 ? .red : .white.opacity(0.6))
                        .padding(.bottom, 40)
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
                                    .disabled(appLock.isLockedOut && key != "FaceID")
                                    .opacity((appLock.isLockedOut && key != "FaceID") ? 0.3 : 1)
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
