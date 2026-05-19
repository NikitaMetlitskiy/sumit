import SwiftUI

struct PINSetupView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.dismiss) var dismiss
    @State private var step = 1
    @State private var first = ""
    @State private var second = ""
    @State private var mismatch = false

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundColor(Color.accentColor)
                Text(step == 1 ? L("enter_new_pin") : L("repeat_pin")).font(.title3.weight(.semibold))
                HStack(spacing: 20) {
                    let cur = step == 1 ? first : second
                    ForEach(0..<4) { i in
                        Circle()
                            .fill(i < cur.count ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 14, height: 14)
                    }
                }
                if mismatch {
                    Text(L("pins_mismatch")).font(.caption).foregroundColor(.red)
                }
                numpad
                Spacer()
            }
            .navigationTitle(L("pin_code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
            }
        }
    }

    var numpad: some View {
        let rows: [[String]] = [["1","2","3"],["4","5","6"],["7","8","9"],["⌫","0",""]]
        return VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Spacer().frame(width: 72, height: 72)
                        } else {
                            PINButton(key: key) { tap(key) }
                        }
                    }
                }
            }
        }
    }

    func tap(_ key: String) {
        var cur = step == 1 ? first : second
        if key == "⌫" { if !cur.isEmpty { cur.removeLast() } }
        else if cur.count < 4 { cur += key }
        if step == 1 { first = cur } else { second = cur }

        guard (step == 1 ? first : second).count == 4 else { return }
        if step == 1 { step = 2 }
        else {
            if first == second {
                appLock.setPIN(first)
                dismiss()
            } else {
                mismatch = true; second = ""
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    step = 1; first = ""; mismatch = false
                }
            }
        }
    }
}
