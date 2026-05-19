import SwiftUI

/// Top of the chat home: small downward chevron that opens the QuickSummarySheet,
/// plus "Total Balance: $500,00" line. The chevron faces DOWN (per Figma) to indicate
/// pulling down on a hidden summary.
struct HomeHeader: View {
    let totalBalance: Double
    let currencyCode: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
                HStack(spacing: 6) {
                    Text(L("home_total_balance"))
                        .foregroundColor(.secondary)
                    Text(Formatters.amount(totalBalance, currency: currencyCode, fractionDigits: 2))
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 13, weight: .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
