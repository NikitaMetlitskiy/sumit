import SwiftUI
import SwiftData

/// The chevron-down sheet on the home screen: lists wallets, shows a month
/// snapshot (income / expenses / savings) with a prev/next month picker, and
/// surfaces Reports + Settings as floating circular actions at the bottom.
struct QuickSummarySheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appLock: AppLockManager
    @Query(sort: \Wallet.createdAt) private var wallets: [Wallet]
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var allTx: [Transaction]

    @State private var monthOffset: Int = 0
    @State private var showReports = false
    @State private var showSettings = false
    @State private var showWalletManager = false

    private var monthAnchor: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private var monthRange: (Date, Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        let start = cal.date(from: comps) ?? monthAnchor
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    private var monthIncome: Double {
        let (s, e) = monthRange
        return allTx.filter { $0.type == .income && $0.occurredAt >= s && $0.occurredAt < e }
            .reduce(0) { $0 + $1.amountInBase }
    }
    private var monthExpenses: Double {
        let (s, e) = monthRange
        return allTx.filter { $0.type == .expense && $0.occurredAt >= s && $0.occurredAt < e }
            .reduce(0) { $0 + $1.amountInBase }
    }
    private var monthSavings: Double { monthIncome - monthExpenses }

    var body: some View {
        ZStack {
            DS.Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                content
                Spacer()
                bottomBar
                    .padding(.bottom, DS.Space.l)
                Text(L("ai_powered_disclaimer"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, DS.Space.s)
            }
        }
        .sheet(isPresented: $showReports) {
            ReportsContainerView(store: store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store).environmentObject(appLock)
        }
        .sheet(isPresented: $showWalletManager) {
            WalletManagerSheet(store: store)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            walletsHeader
            ForEach(wallets) { w in
                walletRow(w)
            }
            if wallets.isEmpty {
                emptyWallets
            }

            monthHeader
                .padding(.top, DS.Space.l)

            metricRow(label: L("incomes"), value: monthIncome, color: DS.Color.income, isPrimary: false)
            metricRow(label: L("expenses"), value: monthExpenses, color: DS.Color.expense, isPrimary: false)
            savingsRow
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.s)
    }

    private var walletsHeader: some View {
        HStack {
            Text(L("wallets"))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button { showWalletManager = true } label: {
                HStack(spacing: 4) {
                    Text(L("wallet_manage_short"))
                        .font(.system(size: 14))
                    Image(systemName: "pencil").font(.system(size: 12))
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, DS.Space.s)
    }

    private func walletRow(_ wallet: Wallet) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                WalletBrandBadge(walletName: wallet.name, size: 28)
                Text(wallet.name)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
                Spacer()
                Text(Formatters.amount(wallet.balance, currency: wallet.currency, fractionDigits: 2))
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 14)
            DashedDivider()
        }
    }

    private var emptyWallets: some View {
        Button { showWalletManager = true } label: {
            HStack {
                Image(systemName: "plus.circle")
                Text(L("add_wallet"))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var monthHeader: some View {
        HStack {
            Text(monthAnchor.formatted(.dateTime.month(.wide).year()).capitalized)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button { monthOffset -= 1 } label: {
                Image(systemName: "chevron.left").foregroundColor(.secondary)
            }
            Button { monthOffset = min(0, monthOffset + 1) } label: {
                Image(systemName: "chevron.right")
                    .foregroundColor(monthOffset >= 0 ? .secondary.opacity(0.3) : .secondary)
            }
            .disabled(monthOffset >= 0)
        }
        .padding(.bottom, DS.Space.s)
    }

    private func metricRow(label: String, value: Double, color: Color, isPrimary: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 17))
                    .foregroundColor(.primary)
                Spacer()
                Text(Formatters.amount(value, currency: store.displayCurrency, fractionDigits: 2))
                    .font(.system(size: 17))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 14)
            DashedDivider()
        }
    }

    /// Highlighted savings row — dark capsule with green amount.
    private var savingsRow: some View {
        HStack {
            Text(L("savings"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text(Formatters.amount(monthSavings, currency: store.displayCurrency, fractionDigits: 2))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(monthSavings >= 0 ? DS.Color.savings : .red)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
        )
        .padding(.top, DS.Space.s)
    }

    private var bottomBar: some View {
        HStack(spacing: DS.Space.xxl) {
            VStack(spacing: 4) {
                Button { showReports = true } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(DS.Color.bgSecondary))
                }
                .buttonStyle(.plain)
                Text(L("reports_title")).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(DS.Color.bgSecondary))
            }
            .buttonStyle(.plain)
            VStack(spacing: 4) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(DS.Color.bgSecondary))
                }
                .buttonStyle(.plain)
                Text(L("settings_title")).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }
}
