import SwiftUI
import SwiftData
import Charts

struct ReportsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.occurredAt, order: .reverse) var allTx: [Transaction]

    @State private var period: ReportPeriod = .month
    @State private var section: ReportSection = .overview

    enum ReportSection: String, CaseIterable {
        case overview   = "overview"
        case categories = "categories"
        case flow       = "flow"
        case charts     = "charts"
        case wallets    = "wallets"
    }

    var filtered: [Transaction] {
        let (start, end) = period.dateRange
        return allTx.filter { $0.occurredAt >= start && $0.occurredAt <= end }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker(L("period"), selection: $period) {
                    ForEach(ReportPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ReportSection.allCases, id: \.self) { s in
                            Button { withAnimation { section = s } } label: {
                                Text(L(s.rawValue))
                                    .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(section == s ? Color.accentColor : Color(.secondarySystemBackground))
                                    .foregroundColor(section == s ? .white : .primary)
                                    .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }

                Divider()

                ScrollView {
                    VStack(spacing: 16) {
                        switch section {
                        case .overview:   OverviewSection(txs: filtered, allTx: allTx, store: store)
                        case .categories: CategoriesSection(txs: filtered, store: store)
                        case .flow:       FlowSection(txs: filtered, store: store)
                        case .charts:     ChartsSection(txs: filtered, store: store)
                        case .wallets:    WalletsSection(txs: allTx, store: store)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle(L("reports_title"))
        }
    }
}

struct OverviewSection: View {
    let txs: [Transaction]
    let allTx: [Transaction]
    let store: AppStore

    var expenses: Double { store.totalExpenses(txs) }
    var income: Double   { store.totalIncome(txs) }
    var net: Double      { income - expenses }

    var recent: [Transaction] { Array(allTx.prefix(10)) }

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCard(title: L("expenses"),    value: store.toDisplay(expenses), currency: store.displayCurrency, color: .red)
                MetricCard(title: L("incomes"),     value: store.toDisplay(income),   currency: store.displayCurrency, color: .green)
                MetricCard(title: L("balance"),     value: store.toDisplay(net),      currency: store.displayCurrency, color: net >= 0 ? .green : .red)
                MetricCard(title: L("transactions_count"), value: Double(txs.count),         currency: L("pcs"), color: .blue, isCount: true)
            }
            .padding(.horizontal)

            if txs.isEmpty {
                ReportsEmptyState()
            } else if let top = topCategory() {
                HStack {
                    Image(systemName: store.icon(for: top.0)).foregroundColor(store.color(for: top.0))
                    Text("\(L("top")): \(store.displayCategoryName(top.0))")
                    Spacer()
                    Text(store.display(amountUSD: top.1)).fontWeight(.medium)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
            }

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("recent")).font(.headline).padding(.horizontal)
                    ForEach(recent) { tx in
                        TxRow(tx: tx, store: store).padding(.horizontal)
                    }
                }
            }
        }
    }

    func topCategory() -> (String, Double)? {
        var map: [String: Double] = [:]
        txs.filter { $0.type == .expense }.forEach { map[$0.categoryName, default: 0] += $0.amountInBase }
        return map.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }
}

struct WalletsSection: View {
    let txs: [Transaction]
    let store: AppStore
    @Query(sort: \Wallet.createdAt) var wallets: [Wallet]
    @State private var showWalletManager = false

    var body: some View {
        VStack(spacing: 12) {
            if wallets.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "wallet.pass").font(.system(size: 44, weight: .ultraLight))
                        .foregroundColor(Color.accentColor.opacity(0.3))
                    Text(L("no_wallets")).font(.headline)
                    Text(L("add_bank_exchange"))
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button(L("add_wallet")) { showWalletManager = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity).padding(40)
            } else {
                ForEach(wallets) { wallet in
                    ManagedWalletCard(wallet: wallet, store: store)
                }
                .padding(.horizontal)

                Button { showWalletManager = true } label: {
                    Label(L("wallet_manage"), systemImage: "gearshape").font(.system(size: 14))
                }
                .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showWalletManager) { WalletManagerSheet(store: store) }
    }
}

struct ManagedWalletCard: View {
    let wallet: Wallet
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: wallet.icon)
                    .font(.system(size: 20))
                    .foregroundColor(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallet.name).font(.headline)
                    Text(wallet.walletType.label)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatters.amount(wallet.balance, fractionDigits: 2))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(wallet.balance >= 0 ? .primary : .red)
                    Text(wallet.currency)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CategoriesSection: View {
    let txs: [Transaction]; let store: AppStore
    var byCategory: [(String, Double)] {
        var map: [String: Double] = [:]
        txs.filter { $0.type == .expense }.forEach { map[$0.categoryName, default: 0] += $0.amountInBase }
        return map.sorted { $0.value > $1.value }
    }
    var total: Double { byCategory.reduce(0) { $0 + $1.1 } }

    var body: some View {
        VStack(spacing: 0) {
            if byCategory.isEmpty {
                ReportsEmptyState().padding()
            } else {
                ForEach(byCategory, id: \.0) { name, amount in
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Circle().fill(store.color(for: name).opacity(0.15)).frame(width: 38, height: 38)
                                .overlay(Image(systemName: store.icon(for: name))
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundColor(store.color(for: name)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.displayCategoryName(name)).font(.system(size: 15))
                                if total > 0 {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2).fill(Color(.systemGray5)).frame(height: 4)
                                            RoundedRectangle(cornerRadius: 2).fill(store.color(for: name).opacity(0.7))
                                                .frame(width: geo.size.width * (amount/total), height: 4)
                                        }
                                    }.frame(height: 4)
                                }
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(store.display(amountUSD: amount)).font(.system(size: 14, weight: .medium))
                                if total > 0 {
                                    Text(String(format: "%.0f%%", amount/total*100)).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        Divider().padding(.leading, 66)
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
            }
        }
    }
}

struct FlowSection: View {
    let txs: [Transaction]; let store: AppStore
    var expenses: Double { store.totalExpenses(txs) }
    var income: Double   { store.totalIncome(txs) }

    var body: some View {
        VStack(spacing: 0) {
            flowRow(label: L("incomes"), icon: "arrow.down.circle.fill", amount: income, color: .green, prefix: "+")
            Divider().padding(.horizontal, 16)
            flowRow(label: L("expenses"), icon: "arrow.up.circle.fill", amount: expenses, color: .red, prefix: "-")
            Divider().padding(.horizontal, 16)
            let net = income - expenses
            flowRow(label: L("total"), icon: "equal.circle.fill", amount: net, color: net >= 0 ? .green : .red, prefix: net >= 0 ? "+" : "-")
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
    }

    @ViewBuilder
    func flowRow(label: String, icon: String, amount: Double, color: Color, prefix: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(color)
            Text(label).foregroundColor(.primary)
            Spacer()
            Text("\(prefix) \(Formatters.amount(store.toDisplay(abs(amount)), currency: store.displayCurrency, fractionDigits: 2))")
                .fontWeight(.semibold).foregroundColor(color)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct ChartsSection: View {
    let txs: [Transaction]; let store: AppStore
    struct DayPoint: Identifiable { let id = UUID(); let date: Date; let amount: Double }
    var dailyData: [DayPoint] {
        let cal = Calendar.current
        var map: [Date: Double] = [:]
        txs.filter { $0.type == .expense }.forEach {
            map[cal.startOfDay(for: $0.occurredAt), default: 0] += $0.amountInBase
        }
        return map.sorted { $0.key < $1.key }.map { DayPoint(date: $0.key, amount: $0.value) }
    }

    var body: some View {
        if txs.isEmpty {
            ReportsEmptyState()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("expenses_by_day")).font(.headline).padding(.horizontal)
                Chart(dailyData) { p in
                    BarMark(x: .value(L("date"), p.date, unit: .day),
                            y: .value(store.displayCurrency, store.toDisplay(p.amount)))
                        .foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, dailyData.count/7))) {
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 200).padding(.horizontal)
            }
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
        }
    }
}

struct MetricCard: View {
    let title: String; let value: Double; let currency: String; let color: Color
    var isCount: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            if isCount {
                Text("\(Int(value)) \(currency)").font(.system(size: 20, weight: .semibold)).foregroundColor(color)
            } else {
                Text(Formatters.amount(abs(value), currency: currency, fractionDigits: 0))
                    .font(.system(size: 20, weight: .semibold)).foregroundColor(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TxRow: View {
    let tx: Transaction; let store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(store.color(for: tx.categoryName).opacity(0.12)).frame(width: 36, height: 36)
                .overlay(Image(systemName: store.icon(for: tx.categoryName))
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(store.color(for: tx.categoryName)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.merchant).font(.system(size: 14, weight: .medium))
                HStack(spacing: 4) {
                    Text(store.displayCategoryName(tx.categoryName)).font(.caption).foregroundColor(.secondary)
                    if !tx.walletName.isEmpty {
                        Text("· \(tx.walletName)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(tx.type == .income ? "+" : "-")\(Formatters.amount(tx.originalAmount, currency: tx.originalCurrency, fractionDigits: 0))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(tx.type == .income ? .green : .primary)
                Text(Formatters.shortDate(tx.occurredAt))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

struct ReportsEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(Color.accentColor.opacity(0.3))
            Text(L("no_data")).font(.headline)
            Text(L("add_expenses_chat")).font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(40)
    }
}
