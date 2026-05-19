import SwiftUI
import SwiftData

/// "Statistics" report: period picker (1W/1M/6M/1Y), three metric cards
/// (Income / Spent / Saved with WoW deltas), and today's transactions grouped by category.
struct StatisticsView: View {
    @ObservedObject var store: AppStore
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var allTx: [Transaction]

    enum Period: String, CaseIterable {
        case w = "1W", m = "1M", sixM = "6M", y = "1Y"
        var days: Int {
            switch self {
            case .w: return 7
            case .m: return 30
            case .sixM: return 182
            case .y: return 365
            }
        }
    }
    @State private var period: Period = .w

    private var range: (Date, Date) {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -period.days, to: end) ?? end
        return (start, end)
    }

    private var previousRange: (Date, Date) {
        let (curStart, _) = range
        let prevEnd = curStart
        let prevStart = Calendar.current.date(byAdding: .day, value: -period.days, to: prevEnd) ?? prevEnd
        return (prevStart, prevEnd)
    }

    private func sum(_ filter: (Transaction) -> Bool, in r: (Date, Date)) -> Double {
        allTx.filter { $0.occurredAt >= r.0 && $0.occurredAt < r.1 && filter($0) }
            .reduce(0) { $0 + $1.amountInBase }
    }

    private var income: Double  { sum({ $0.type == .income },  in: range) }
    private var spent: Double   { sum({ $0.type == .expense }, in: range) }
    private var saved: Double   { income - spent }

    private var incomeDelta: Double { delta(income, sum({ $0.type == .income }, in: previousRange)) }
    private var spentDelta: Double  { delta(spent,  sum({ $0.type == .expense }, in: previousRange)) }

    private func delta(_ current: Double, _ prev: Double) -> Double {
        guard prev > 0 else { return 0 }
        return ((current - prev) / prev) * 100
    }

    private var todayTransactions: [Transaction] {
        let cal = Calendar.current
        return allTx.filter { cal.isDateInToday($0.occurredAt) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text(L("statistics"))
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, DS.Space.l)

                periodPicker

                metrics

                Text(L("today"))
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.top, DS.Space.s)

                todayList
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.xxl)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases, id: \.self) { p in
                Button { withAnimation(.easeInOut(duration: 0.15)) { period = p } } label: {
                    Text(p.rawValue)
                        .font(.system(size: 14, weight: period == p ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(period == p ? DS.Color.bg : .clear)
                                .opacity(period == p ? 1 : 0)
                                .dsComposerShadow()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(DS.Color.bgSecondary))
    }

    private var metrics: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                metricCard(title: L("incomes"), value: income, delta: incomeDelta, deltaUp: incomeDelta >= 0, isGood: true)
                metricCard(title: L("saved"), value: saved, delta: nil)
            }
            HStack(spacing: 10) {
                metricCard(title: L("spent"), value: spent, delta: spentDelta, deltaUp: spentDelta >= 0, isGood: false)
                Color.clear
            }
        }
    }

    private func metricCard(title: String, value: Double, delta: Double?, deltaUp: Bool = false, isGood: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14)).foregroundColor(.secondary)
            Text(Formatters.amount(value, currency: store.displayCurrency, fractionDigits: 0))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.primary)
            if let d = delta, abs(d) > 0.5 {
                HStack(spacing: 2) {
                    Image(systemName: deltaUp ? "triangle.fill" : "triangle.fill")
                        .rotationEffect(.degrees(deltaUp ? 0 : 180))
                        .font(.system(size: 8))
                    Text(Formatters.amount(abs(value - value * (1 - d/100)), fractionDigits: 0))
                    Text("(\(String(format: "%.1f", abs(d)))%)").font(.caption)
                }
                .font(.caption)
                .foregroundColor(deltaUp == isGood ? DS.Color.income : DS.Color.expense)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Color.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.Color.strokeSoft, lineWidth: 0.5)
        )
    }

    private var todayList: some View {
        VStack(spacing: 0) {
            if todayTransactions.isEmpty {
                Text(L("no_data"))
                    .foregroundColor(.secondary)
                    .padding(.vertical, DS.Space.l)
            } else {
                ForEach(todayTransactions) { tx in
                    HStack(spacing: 12) {
                        Circle().fill(store.color(for: tx.categoryName).opacity(0.15))
                            .frame(width: 38, height: 38)
                            .overlay(Image(systemName: store.icon(for: tx.categoryName))
                                .font(.system(size: 16))
                                .foregroundColor(store.color(for: tx.categoryName)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.displayCategoryName(tx.categoryName))
                                .font(.system(size: 15, weight: .medium))
                            if !tx.walletName.isEmpty {
                                Text(tx.walletName).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatters.amount(tx.originalAmount, currency: tx.originalCurrency, fractionDigits: 2))
                                .font(.system(size: 15, weight: .medium))
                            Text(store.display(amountUSD: tx.amountInBase))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                    DashedDivider()
                }
            }
        }
        .padding(.horizontal, 4)
    }
}
