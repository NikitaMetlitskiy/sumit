import SwiftUI
import SwiftData

/// "Total wealth" report: title, a soft gradient orb showing total balance with
/// percentage markers around it, and a list of wallets with their balances.
struct TotalWealthView: View {
    @ObservedObject var store: AppStore
    let onManageWallets: () -> Void

    @Query(sort: \Wallet.createdAt) private var wallets: [Wallet]

    /// Each wallet's value converted to display currency.
    private var walletShares: [(wallet: Wallet, value: Double)] {
        wallets.map { ($0, CurrencyService.convert($0.balance, from: $0.currency, to: store.displayCurrency)) }
    }
    private var total: Double { walletShares.reduce(0) { $0 + $1.value } }
    /// Percentages as fractions of total. Caps at 3 markers shown around the orb.
    private var topPercents: [Double] {
        guard total > 0 else { return [] }
        return walletShares.map { $0.value / total }.sorted(by: >).prefix(3).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text(L("total_wealth"))
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, DS.Space.l)

                ZStack {
                    wealthOrb
                    Text(Formatters.amount(total, currency: store.displayCurrency, fractionDigits: 0))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
                .frame(height: 320)
                .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    ForEach(walletShares.sorted { $0.value > $1.value }, id: \.wallet.id) { item in
                        walletCard(item.wallet, value: item.value)
                    }
                    addWalletButton
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.xxl)
        }
    }

    private var wealthOrb: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.30, green: 0.45, blue: 1.0),   // blue
                            Color(red: 0.66, green: 0.42, blue: 1.0),   // violet
                            Color(red: 1.00, green: 0.50, blue: 0.40),  // coral
                            Color(red: 1.00, green: 0.78, blue: 0.20)   // amber
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )
                .blur(radius: 24)
                .frame(width: 260, height: 260)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            DS.Color.warmStart,
                            DS.Color.warmMid,
                            DS.Color.warmEnd,
                            DS.Color.payPalBlue,
                            DS.Color.monoPink,
                            DS.Color.warmStart
                        ],
                        center: .center
                    ),
                    lineWidth: 2
                )
                .frame(width: 260, height: 260)

            ForEach(Array(topPercents.enumerated()), id: \.offset) { idx, pct in
                let angle: Double = [-30, 90, 210][idx % 3]
                percentMarker(pct, at: Angle(degrees: angle))
            }
        }
    }

    private func percentMarker(_ fraction: Double, at angle: Angle) -> some View {
        let radius: CGFloat = 145
        let x = cos(CGFloat(angle.radians)) * radius
        let y = sin(CGFloat(angle.radians)) * radius
        return VStack(spacing: 2) {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Circle().fill(.white).frame(width: 6, height: 6)
                .overlay(Circle().stroke(.black, lineWidth: 1))
        }
        .offset(x: x, y: y)
    }

    private func walletCard(_ wallet: Wallet, value: Double) -> some View {
        HStack(spacing: 12) {
            WalletBrandBadge(walletName: wallet.name, size: 32)
            Text(wallet.name).font(.system(size: 17, weight: .medium))
            Spacer()
            Text(Formatters.amount(value, currency: store.displayCurrency, fractionDigits: 0))
                .font(.system(size: 17, weight: .medium))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Color.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DS.Color.strokeSoft, lineWidth: 0.5)
        )
    }

    private var addWalletButton: some View {
        Button(action: onManageWallets) {
            HStack {
                Image(systemName: "plus")
                Text(L("add_wallet")).font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(DS.Color.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .buttonStyle(.plain)
    }
}
