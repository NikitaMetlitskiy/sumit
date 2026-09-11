import SwiftUI
import SwiftData
import Charts

struct ReportsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var storedTx: [Transaction]
    @ObservedObject private var auth = AuthService.shared

    var allTx: [Transaction] { LedgerScope.activeTransactions(storedTx, ownerID: auth.userId) }

    @State private var period: ReportPeriod = .month
    @State private var section: ReportSection = .overview
    @State private var conversion = DisplayConversion.usd()
    @State private var conversionIsStale = false

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
        let summary = ReportSummary.make(filtered)
        let money = ReportMoney(conversion: conversion, isStale: conversionIsStale)
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
                        case .overview:   OverviewSection(summary: summary, recent: Array(allTx.prefix(10)), store: store, money: money)
                        case .categories: CategoriesSection(summary: summary, store: store, money: money)
                        case .flow:       FlowSection(summary: summary, money: money)
                        case .charts:     ChartsSection(summary: summary, money: money)
                        case .wallets:    WalletsSection(store: store)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle(L("reports_title"))
            .task(id: store.displayCurrency) { await loadDisplayConversion() }
        }
    }

    /// A current quote for the display currency, used for display only. The
    /// booked USD values underneath never change when this does.
    private func loadDisplayConversion() async {
        let code = store.displayCurrency.uppercased()
        guard code != "USD" else {
            conversion = .usd()
            conversionIsStale = false
            return
        }
        guard let service = store.rateService else {
            conversion = DisplayConversion(currency: code, quote: nil)
            return
        }
        let result = await service.availability(currency: code, day: nil)
        conversion = DisplayConversion(currency: code, quote: result.quote)
        if case .stale = result { conversionIsStale = true } else { conversionIsStale = false }
    }
}

// MARK: — Formatting booked USD for display

/// Every USD figure on this screen goes through here, so the label saying which
/// rate converted it — or that nothing did — is never separated from the number.
struct ReportMoney {
    let conversion: DisplayConversion
    let isStale: Bool

    @MainActor
    func text(_ usd: Decimal) -> String {
        if let value = conversion.convert(usd) {
            return Formatters.exactAmount(value, currency: conversion.currency)
        }
        let shown = (try? MoneyCodec.quantize(usd, scale: 2)) ?? usd
        return Formatters.exactAmount(shown, currency: "USD")
    }

    func chartValue(_ usd: Decimal) -> Double {
        DisplayConversion.chartValue(conversion.convert(usd) ?? usd)
    }

    var unitLabel: String { conversion.isAvailable ? conversion.currency : "USD" }

    @MainActor
    var note: String? {
        guard conversion.currency != "USD" else { return nil }
        guard let quote = conversion.quote else {
            return String(format: L("report_display_unavailable"), conversion.currency)
        }
        let base = String(format: L("report_display_conversion"), conversion.currency,
                          Formatters.shortDate(quote.effectiveAt))
        return isStale ? "\(base) · \(L("report_display_stale"))" : base
    }
}

/// States what the totals do and do not contain.
struct ReportCompletenessNotes: View {
    let summary: ReportSummary
    let money: ReportMoney

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = money.note {
                Text(note)
            }
            if summary.unconvertedCount > 0 {
                Text(String(format: L("report_unconverted_count"), summary.unconvertedCount))
                    .foregroundColor(.orange)
            }
            if summary.legacyUnverifiedCount > 0 {
                Text(String(format: L("report_legacy_count"), summary.legacyUnverifiedCount))
            }
            if summary.unreadableCount > 0 {
                Text(String(format: L("report_unreadable_count"), summary.unreadableCount))
                    .foregroundColor(.orange)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("report-completeness")
    }
}

struct OverviewSection: View {
    let summary: ReportSummary
    let recent: [Transaction]
    let store: AppStore
    let money: ReportMoney

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCard(title: L("expenses"), text: money.text(summary.expenseUSD), color: .red)
                MetricCard(title: L("incomes"), text: money.text(summary.incomeUSD), color: .green)
                // The sign is part of the text: a negative balance is not only red.
                MetricCard(title: L("balance"), text: money.text(summary.netUSD),
                           color: summary.netUSD >= 0 ? .green : .red)
                MetricCard(title: L("transactions_count"), text: "\(summary.entryCount) \(L("pcs"))", color: .blue)
            }
            .padding(.horizontal)

            ReportCompletenessNotes(summary: summary, money: money).padding(.horizontal)

            if summary.entryCount == 0 {
                ReportsEmptyState()
            } else if let top = summary.expenseByCategory.first {
                HStack {
                    Image(systemName: store.icon(for: top.name)).foregroundColor(store.color(for: top.name))
                    Text("\(L("top")): \(store.displayCategoryName(top.name))")
                    Spacer()
                    Text(money.text(top.usd)).fontWeight(.medium)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
            }

            if !summary.nativeExpense.isEmpty || !summary.nativeIncome.isEmpty {
                NativeTotalsCard(summary: summary).padding(.horizontal)
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
}

/// Totals in the currencies the money actually moved in. These include records
/// with no USD value, which is why they are shown at all.
struct NativeTotalsCard: View {
    let summary: ReportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("report_native_totals")).font(.subheadline.weight(.medium))
            ForEach(summary.nativeExpense.keys.sorted(), id: \.self) { code in
                row(L("expenses"), "-" + Formatters.exactAmount(summary.nativeExpense[code] ?? 0, currency: code))
            }
            ForEach(summary.nativeIncome.keys.sorted(), id: \.self) { code in
                row(L("incomes"), "+" + Formatters.exactAmount(summary.nativeIncome[code] ?? 0, currency: code))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }
}

struct WalletsSection: View {
    let store: AppStore
    @Query(sort: \Wallet.createdAt) private var storedWallets: [Wallet]
    @ObservedObject private var walletAuth = AuthService.shared

    var wallets: [Wallet] { LedgerScope.activeWallets(storedWallets, ownerID: walletAuth.userId) }
    @State private var showWalletManager = false

    var body: some View {
        let balances = store.walletBalances()
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
                    ManagedWalletCard(wallet: wallet, balance: balances[wallet.id])
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

/// A wallet in its own currency. Never converted: a wallet holds euros, not an
/// estimate of dollars.
struct ManagedWalletCard: View {
    let wallet: Wallet
    let balance: Decimal?

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
                    if let balance {
                        Text(Formatters.exactAmount(balance))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(balance >= 0 ? .primary : .red)
                    } else {
                        Text("—").font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary)
                    }
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
    let summary: ReportSummary
    let store: AppStore
    let money: ReportMoney

    var body: some View {
        let total = summary.expenseUSD
        VStack(spacing: 8) {
            if summary.expenseByCategory.isEmpty {
                ReportsEmptyState().padding()
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.expenseByCategory, id: \.name) { item in
                        // A share is a proportion for a bar, computed after exact aggregation.
                        let share = total > 0 ? DisplayConversion.chartValue(item.usd / total) : 0
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Circle().fill(store.color(for: item.name).opacity(0.15)).frame(width: 38, height: 38)
                                    .overlay(Image(systemName: store.icon(for: item.name))
                                        .font(.system(size: 14, weight: .light))
                                        .foregroundColor(store.color(for: item.name)))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.displayCategoryName(item.name)).font(.system(size: 15))
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2).fill(Color(.systemGray5)).frame(height: 4)
                                            RoundedRectangle(cornerRadius: 2).fill(store.color(for: item.name).opacity(0.7))
                                                .frame(width: geo.size.width * share, height: 4)
                                        }
                                    }.frame(height: 4)
                                }
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(money.text(item.usd)).font(.system(size: 14, weight: .medium))
                                    Text(String(format: "%.0f%%", share * 100)).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

                ReportCompletenessNotes(summary: summary, money: money).padding(.horizontal)
            }
        }
    }
}

struct FlowSection: View {
    let summary: ReportSummary
    let money: ReportMoney

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                flowRow(label: L("incomes"), icon: "arrow.down.circle.fill", text: "+" + money.text(summary.incomeUSD), color: .green)
                Divider().padding(.horizontal, 16)
                flowRow(label: L("expenses"), icon: "arrow.up.circle.fill", text: "-" + money.text(summary.expenseUSD), color: .red)
                Divider().padding(.horizontal, 16)
                let net = summary.netUSD
                flowRow(label: L("total"), icon: "equal.circle.fill",
                        text: (net > 0 ? "+" : "") + money.text(net),
                        color: net >= 0 ? .green : .red)
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)

            ReportCompletenessNotes(summary: summary, money: money).padding(.horizontal)
        }
    }

    @ViewBuilder
    func flowRow(label: String, icon: String, text: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(color)
            Text(label).foregroundColor(.primary)
            Spacer()
            Text(text).fontWeight(.semibold).foregroundColor(color)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct ChartsSection: View {
    let summary: ReportSummary
    let money: ReportMoney

    struct DayPoint: Identifiable { let id = UUID(); let date: Date; let amount: Double }

    /// Doubles appear only here, as chart coordinates, after the exact totals exist.
    var dailyData: [DayPoint] {
        summary.dailyExpense.map { DayPoint(date: $0.day, amount: money.chartValue($0.usd)) }
    }

    var body: some View {
        if summary.dailyExpense.isEmpty {
            ReportsEmptyState()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("expenses_by_day")).font(.headline).padding(.horizontal)
                Chart(dailyData) { p in
                    BarMark(x: .value(L("date"), p.date, unit: .day),
                            y: .value(money.unitLabel, p.amount))
                        .foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, dailyData.count/7))) {
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 200).padding(.horizontal)
                ReportCompletenessNotes(summary: summary, money: money).padding(.horizontal)
            }
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
        }
    }
}

struct MetricCard: View {
    let title: String
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 20, weight: .semibold)).foregroundColor(color)
                .minimumScaleFactor(0.6).lineLimit(1)
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
        let walletName = store.walletName(id: tx.walletID)
        HStack(spacing: 12) {
            Circle().fill(store.color(for: tx.categoryName).opacity(0.12)).frame(width: 36, height: 36)
                .overlay(Image(systemName: store.icon(for: tx.categoryName))
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(store.color(for: tx.categoryName)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.merchant).font(.system(size: 14, weight: .medium))
                HStack(spacing: 4) {
                    Text(store.displayCategoryName(tx.categoryName)).font(.caption).foregroundColor(.secondary)
                    if !walletName.isEmpty {
                        Text("· \(walletName)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(tx.type == .income ? .green : .primary)
                Text(Formatters.shortDate(tx.occurredAt))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var amountText: String {
        let sign: String
        switch tx.type {
        case .income:   sign = "+"
        case .expense:  sign = "-"
        case .transfer: sign = "⇄ "
        }
        let value = tx.amountExact.map { Formatters.exactAmount($0, currency: tx.originalCurrency) }
            ?? Formatters.amount(tx.originalAmount, currency: tx.originalCurrency, fractionDigits: 2)
        return sign + value
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
