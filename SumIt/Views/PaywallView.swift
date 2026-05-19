import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject var storeKit: StoreKitManager = .shared
    @Binding var isPresented: Bool
    @State private var selectedTier: SubscriptionTier = .pro
    @State private var isPurchasing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: "1a1a2e") ?? .black, .accentColor],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 72, height: 72)
                            .overlay(
                                Image("SplashLogo")
                                    .resizable().scaledToFit()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            )

                        Text("SumIt")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text(L("choose_plan"))
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 50)
                    .padding(.bottom, 32)

                    // Plan cards
                    VStack(spacing: 12) {
                        PlanCard(
                            tier: .basic,
                            price: storeKit.product(for: .basic)?.displayPrice ?? "$2.99",
                            features: [
                                ("cpu", L("feat_gpt_mini")),
                                ("number", L("feat_100_parses")),
                                ("tray.full", L("feat_500_tx")),
                                ("chart.bar", L("feat_basic_reports")),
                                ("icloud", L("feat_sync"))
                            ],
                            isSelected: selectedTier == .basic,
                            onTap: { selectedTier = .basic }
                        )

                        PlanCard(
                            tier: .pro,
                            price: storeKit.product(for: .pro)?.displayPrice ?? "$5.99",
                            features: [
                                ("cpu.fill", L("feat_gpt_pro")),
                                ("infinity", L("feat_unlimited_parses")),
                                ("infinity", L("feat_unlimited_tx")),
                                ("chart.bar.xaxis", L("feat_analytics")),
                                ("square.and.arrow.up", L("feat_export"))
                            ],
                            isSelected: selectedTier == .pro,
                            isBest: true,
                            onTap: { selectedTier = .pro }
                        )
                    }
                    .padding(.horizontal, 20)

                    // Error
                    if let err = storeKit.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 12)
                    }

                    // Subscribe button
                    Button {
                        Task { await subscribe() }
                    } label: {
                        Group {
                            if isPurchasing {
                                ProgressView().tint(.white)
                            } else {
                                Text("\(L("subscribe_btn")) — \(selectedPrice)")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isPurchasing)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                    // Restore + legal
                    VStack(spacing: 8) {
                        Button(L("restore_purchases")) {
                            Task { await storeKit.restorePurchases() }
                        }
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))

                        Text(L("auto_renew_note"))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    var selectedPrice: String {
        if let displayPrice = storeKit.product(for: selectedTier)?.displayPrice {
            return "\(displayPrice) \(L("per_month"))"
        }
        // Fallback before StoreKit products load (TestFlight / first launch).
        let fallback = selectedTier == .pro ? "$5.99" : "$2.99"
        return "\(fallback) \(L("per_month"))"
    }

    func subscribe() async {
        guard let product = storeKit.product(for: selectedTier) else {
            storeKit.errorMessage = L("product_unavailable")
            return
        }
        isPurchasing = true
        let success = await storeKit.purchase(product)
        isPurchasing = false
        if success { isPresented = false }
    }
}

// MARK: — Plan Card
struct PlanCard: View {
    let tier: SubscriptionTier
    let price: String
    let features: [(String, String)]
    let isSelected: Bool
    var isBest: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Badge + Title
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if isBest {
                            Text(L("best_choice"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Text(tier.label)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(price)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                        Text(L("per_month"))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.bottom, 14)

                // Features
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(features, id: \.1) { icon, text in
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .font(.system(size: 13))
                                .foregroundColor(isSelected ? .accentColor : .white.opacity(0.5))
                                .frame(width: 20)
                            Text(text)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
