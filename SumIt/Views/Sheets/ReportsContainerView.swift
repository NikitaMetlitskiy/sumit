import SwiftUI

/// Container for the redesigned reports screens. Two tabs: Overview (Total Wealth)
/// and Statistics. Bottom pill switcher per Figma. Edit / Share buttons on the right.
struct ReportsContainerView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    enum Tab { case overview, statistic }
    @State private var tab: Tab = .overview
    @State private var showShare = false
    @State private var showWalletManager = false

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
            bottomBar
                .padding(.bottom, DS.Space.l)
        }
        .background(DS.Color.bg.ignoresSafeArea())
        .sheet(isPresented: $showWalletManager) {
            WalletManagerSheet(store: store)
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: ["SumIt — Reports"])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:  TotalWealthView(store: store) { showWalletManager = true }
        case .statistic: StatisticsView(store: store)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: DS.Space.l) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(DS.Color.bgSecondary))
            }
            .buttonStyle(.plain)

            // Center pill toggle
            HStack(spacing: 4) {
                tabButton(.overview, label: L("overview"))
                tabButton(.statistic, label: L("statistic"))
            }
            .padding(4)
            .background(Capsule().fill(DS.Color.bgSecondary))

            Button {
                if tab == .overview { showWalletManager = true } else { showShare = true }
            } label: {
                Image(systemName: tab == .overview ? "pencil" : "square.and.arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(DS.Color.bgSecondary))
            }
            .buttonStyle(.plain)
        }
    }

    private func tabButton(_ value: Tab, label: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { tab = value } } label: {
            Text(label)
                .font(.system(size: 14, weight: tab == value ? .semibold : .regular))
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(tab == value ? DS.Color.bg : .clear)
                        .dsComposerShadow()
                        .opacity(tab == value ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}
