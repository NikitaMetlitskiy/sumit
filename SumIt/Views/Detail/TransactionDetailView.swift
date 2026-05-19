import SwiftUI
import SwiftData

/// Read-only detail screen shown when the user taps a saved transaction message.
/// Mirrors the "$ 4,900" Figma layout: pill-shaped date at top, huge amount,
/// dashed rows for Wallet / Category / Merchant / Note, and three circular actions at the bottom.
struct TransactionDetailView: View {
    let transaction: Transaction
    let store: AppStore
    let onEdit: () -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    private var convertedAmount: String? {
        guard transaction.originalCurrency != store.displayCurrency else { return nil }
        let inDisplay = transaction.amountInBase * CurrencyService.usdTo(store.displayCurrency)
        return Formatters.amount(inDisplay, currency: store.displayCurrency, fractionDigits: 0)
    }

    private var amountText: String {
        Formatters.amount(transaction.originalAmount, currency: transaction.originalCurrency, fractionDigits: 0)
    }

    private var typeColor: Color {
        switch transaction.type {
        case .income:   return DS.Color.income
        case .expense:  return DS.Color.expense
        case .transfer: return DS.Color.transfer
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Warm gradient backdrop behind the card
            ZStack {
                LinearGradient(
                    colors: [DS.Color.warmEnd.opacity(0.15), DS.Color.warmStart.opacity(0.08), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)

                VStack(spacing: DS.Space.l) {
                    datePill
                    card
                }
                .padding(.top, DS.Space.xxl)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Spacer(minLength: 0)

            actionsRow
                .padding(.bottom, DS.Space.xl)
        }
        .background(DS.Color.bg.ignoresSafeArea())
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
    }

    private var datePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.system(size: 12, weight: .regular))
            Text("\(Formatters.shortDate(transaction.occurredAt)), \(transaction.occurredAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 13, weight: .regular))
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(DS.Color.bg.opacity(0.9)))
        .overlay(Capsule().stroke(DS.Color.strokeSoft, lineWidth: 0.5))
    }

    private var card: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: transaction.type == .income ? "arrow.down" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(typeColor)
                    Text(transaction.type.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(currencySymbol(transaction.originalCurrency))
                        .font(.system(size: 36, weight: .regular))
                        .foregroundColor(.primary)
                    Text(amountText)
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.top, DS.Space.s)

                if let conv = convertedAmount {
                    Text("≈ \(conv)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.l)

            DashedDivider()

            if !transaction.walletName.isEmpty {
                detailRow(label: L("wallet")) {
                    HStack(spacing: 6) {
                        WalletBrandBadge(walletName: transaction.walletName, size: 20)
                        Text(transaction.walletName).font(.system(size: 14, weight: .medium))
                    }
                }
            }

            detailRow(label: L("category")) {
                HStack(spacing: 6) {
                    Image(systemName: store.icon(for: transaction.categoryName)).font(.system(size: 12))
                    Text(store.displayCategoryName(transaction.categoryName))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(store.color(for: transaction.categoryName)))
            }

            if !transaction.merchant.isEmpty && transaction.merchant != "Unknown" {
                detailRow(label: L("merchant")) {
                    Text(transaction.merchant)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(DS.Color.bgSecondary))
                }
            }

            if !transaction.note.isEmpty {
                detailRow(label: L("note")) {
                    Text(transaction.note)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.bottom, DS.Space.m)
        .background(DS.Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cardCorner, style: .continuous)
                .stroke(DS.Color.strokeSoft, lineWidth: 0.5)
        )
        .dsCardShadow()
        .padding(.horizontal, DS.Space.l)
    }

    private func detailRow<Trailing: View>(label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundColor(.secondary).font(.system(size: 15))
                Spacer()
                trailing()
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, 14)
            DashedDivider()
        }
    }

    private var actionsRow: some View {
        HStack(spacing: DS.Space.xxl) {
            // Edit
            VStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(DS.Color.bgSecondary))
                }
                .buttonStyle(.plain)
                Text(L("edit")).font(.system(size: 12)).foregroundColor(.secondary)
            }
            // Close
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(DS.Color.bgSecondary))
            }
            .buttonStyle(.plain)
            // Share
            VStack(spacing: 4) {
                Button {
                    showShare = true
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(DS.Color.bgSecondary))
                }
                .buttonStyle(.plain)
                Text(L("share")).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    private var shareText: String {
        let sign = transaction.type == .income ? "+" : "-"
        let amount = Formatters.amount(transaction.originalAmount,
                                       currency: transaction.originalCurrency,
                                       fractionDigits: 0)
        let date = Formatters.shortDate(transaction.occurredAt)
        var lines = ["\(sign)\(amount)", date]
        if !transaction.merchant.isEmpty { lines.append(transaction.merchant) }
        lines.append(store.displayCategoryName(transaction.categoryName))
        return lines.joined(separator: " · ")
    }

    private func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "USD", "USDC", "USDT": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "UAH": return "₴"
        case "JPY": return "¥"
        case "BTC": return "₿"
        case "ETH": return "Ξ"
        case "PLN": return "zł"
        default: return code
        }
    }
}

/// Dashed horizontal separator used across Detail / Edit screens.
struct DashedDivider: View {
    var color: Color = DS.Color.stroke
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 16, y: 0))
            path.addLine(to: CGPoint(x: UIScreen.main.bounds.width - 32, y: 0))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        .frame(height: 1)
    }
}

/// UIActivityViewController wrapper for the Share button.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
