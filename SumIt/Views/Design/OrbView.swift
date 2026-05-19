import SwiftUI

/// The warm gradient orb used as the brand mark on the empty home screen and reports.
/// Pure SwiftUI — no asset required. Replace with an Image(...) if a higher-fidelity PNG ships.
struct OrbView: View {
    var diameter: CGFloat = DS.Size.orbDiameter
    /// Subtle continuous animation. Disable in previews to keep them snappier.
    var animated: Bool = true

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Soft warm glow behind the orb
            Circle()
                .fill(DS.Color.warmMid.opacity(0.25))
                .blur(radius: diameter * 0.35)
                .frame(width: diameter * 1.6, height: diameter * 1.6)
                .scaleEffect(pulse ? 1.05 : 1.0)

            // Base orb body — radial gradient anchored to top-trailing for the highlight
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.9),       location: 0.0),
                            .init(color: DS.Color.warmStart,        location: 0.18),
                            .init(color: DS.Color.warmMid,          location: 0.55),
                            .init(color: DS.Color.warmEnd,          location: 1.0)
                        ]),
                        center: UnitPoint(x: 0.72, y: 0.32),
                        startRadius: diameter * 0.04,
                        endRadius:   diameter * 0.62
                    )
                )

            // Highlight crescent on top-left for the wet-plastic look
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.0),  location: 0.00),
                            .init(color: .white.opacity(0.45), location: 0.18),
                            .init(color: .white.opacity(0.0),  location: 0.30),
                            .init(color: .white.opacity(0.0),  location: 1.00)
                        ]),
                        center: .center,
                        angle: .degrees(-90)
                    )
                )
                .blendMode(.screen)
                .opacity(0.85)
                .scaleEffect(0.92)

            // Subtle inner ring for depth
            Circle()
                .stroke(DS.Color.warmEnd.opacity(0.22), lineWidth: 1)
                .scaleEffect(0.98)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: DS.Color.warmMid.opacity(0.35),
                radius: diameter * 0.18, x: 0, y: diameter * 0.08)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: — Wallet brand chip used in summary lists / quick summary
/// Small circular badge that mimics the brand color of common wallets until real logos ship.
struct WalletBrandBadge: View {
    let walletName: String
    var size: CGFloat = 28

    var body: some View {
        let palette = palette(for: walletName)
        ZStack {
            Circle().fill(palette.bg)
            Text(palette.letter)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }

    private func palette(for name: String) -> (bg: Color, letter: String) {
        let lower = name.lowercased()
        if lower.contains("mono") {
            return (DS.Color.monoPink, "m")
        }
        if lower.contains("binance") {
            return (DS.Color.binanceGold, "◈")
        }
        if lower.contains("paypal") {
            return (DS.Color.payPalBlue, "P")
        }
        if lower.contains("cash") || lower.contains("налич") || lower.contains("готів") {
            return (.green, "$")
        }
        if lower.contains("privat") {
            return (Color(red: 0.0, green: 0.5, blue: 0.0), "P")
        }
        // Generic fallback — first letter on accent
        let first = String(name.first.map(String.init) ?? "•").uppercased()
        return (Color.accentColor, first)
    }
}

#Preview("Orb") {
    VStack(spacing: 24) {
        OrbView()
        WalletBrandBadge(walletName: "Monobank")
        WalletBrandBadge(walletName: "Binance")
        WalletBrandBadge(walletName: "PayPal")
    }
    .padding()
    .background(Color(.systemBackground))
}
