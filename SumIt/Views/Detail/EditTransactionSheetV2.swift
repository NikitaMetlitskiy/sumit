import SwiftUI
import SwiftData

/// Dark full-screen modal for editing a saved transaction, matching the Figma
/// "Cancel editing" screen. Shows a big amount input, type selector, wallet/category/merchant
/// pickers, date, note, and a black "Save" CTA at the bottom.
struct EditTransactionSheetV2: View {
    let transaction: Transaction
    let store: AppStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Wallet.createdAt) private var wallets: [Wallet]

    @State private var amountStr: String = ""
    @State private var currency: String = "UAH"
    @State private var type: TransactionType = .expense
    @State private var walletName: String = ""
    @State private var categoryName: String = ""
    @State private var merchant: String = ""
    @State private var date: Date = .now
    @State private var note: String = ""

    @State private var showWalletPicker = false
    @State private var showCategoryPicker = false
    @State private var showDatePicker = false

    private var convertedAmount: String? {
        let value = Double(amountStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard currency != store.displayCurrency else { return nil }
        let inDisplay = value * CurrencyService.toUSD(currency) * CurrencyService.usdTo(store.displayCurrency)
        return Formatters.amount(inDisplay, currency: store.displayCurrency, fractionDigits: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    amountBlock
                        .padding(.top, DS.Space.l)
                        .padding(.bottom, DS.Space.xl)

                    typeRow
                    Spacer(minLength: DS.Space.l)
                    fieldsCard
                    Spacer(minLength: DS.Space.xl)
                }
            }
            saveButton
        }
        .background(DS.Color.bg.ignoresSafeArea())
        .onAppear { loadTransaction() }
        .sheet(isPresented: $showWalletPicker) {
            pickerSheet(title: L("wallet")) {
                ForEach(wallets) { w in
                    pickerRow(label: w.name, isSelected: walletName == w.name) {
                        walletName = w.name; showWalletPicker = false
                    }
                }
            }
        }
        .sheet(isPresented: $showCategoryPicker) {
            pickerSheet(title: L("category")) {
                ForEach(store.allCategories, id: \.name) { cat in
                    pickerRow(label: cat.displayName, isSelected: categoryName == cat.name) {
                        categoryName = cat.name; showCategoryPicker = false
                    }
                }
            }
        }
    }

    // MARK: — Pieces

    private var header: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Text(L("cancel_editing"))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.s)
        .overlay(alignment: .top) {
            Capsule().fill(Color.secondary.opacity(0.3))
                .frame(width: DS.Size.modalGrabberWidth, height: 4)
                .padding(.top, DS.Space.xs)
        }
    }

    private var amountBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(currencySymbol(currency))
                .font(.system(size: 36, weight: .regular))
                .foregroundColor(.primary)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .offset(y: 6)
                }
            Spacer()
            TextField("0", text: $amountStr)
                .keyboardType(.decimalPad)
                .font(.system(size: 48, weight: .semibold))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DS.Space.xl)
        .overlay(alignment: .bottomTrailing) {
            if let conv = convertedAmount {
                Text("≈ \(conv)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .padding(.trailing, DS.Space.xl)
                    .padding(.bottom, -DS.Space.l)
            }
        }
    }

    private var typeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TransactionType.allCases, id: \.self) { t in
                Button { type = t } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(typeColor(t).opacity(0.16)).frame(width: 20, height: 20)
                            Image(systemName: iconFor(t))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(typeColor(t))
                        }
                        Text(t.label)
                            .font(.system(size: 17, weight: type == t ? .semibold : .regular))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.xl)
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            rowButton(label: L("wallet"),
                      value: walletName.isEmpty ? L("not_selected") : walletName,
                      chevron: true) {
                showWalletPicker = true
            }
            DashedDivider().padding(.horizontal, DS.Space.l)

            rowButton(label: L("category"),
                      value: categoryName.isEmpty ? L("not_selected") : store.displayCategoryName(categoryName),
                      chevron: false,
                      valueIsChip: true,
                      chipColor: store.color(for: categoryName)) {
                showCategoryPicker = true
            }
            DashedDivider().padding(.horizontal, DS.Space.l)

            HStack {
                Text(L("merchant")).foregroundColor(.secondary).font(.system(size: 15))
                Spacer()
                TextField(L("add"), text: $merchant)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, 14)
            DashedDivider().padding(.horizontal, DS.Space.l)

            HStack {
                Text(L("date")).foregroundColor(.secondary).font(.system(size: 15))
                Spacer()
                DatePicker("", selection: $date)
                    .labelsHidden()
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, 8)
            DashedDivider().padding(.horizontal, DS.Space.l)

            HStack(alignment: .top) {
                Text(L("note")).foregroundColor(.secondary).font(.system(size: 15))
                Spacer()
                TextField(L("note_optional"), text: $note, axis: .vertical)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14))
                    .lineLimit(1...3)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, 14)
        }
    }

    private func rowButton(label: String, value: String, chevron: Bool,
                           valueIsChip: Bool = false, chipColor: Color = .clear,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundColor(.secondary).font(.system(size: 15))
                Spacer()
                if valueIsChip {
                    HStack(spacing: 6) {
                        Image(systemName: store.icon(for: categoryName)).font(.system(size: 11))
                        Text(value).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(chipColor))
                } else {
                    Text(value).font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        VStack(spacing: 8) {
            Button(action: save) {
                Text(L("save"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule(style: .continuous).fill(Color.black))
            }
            .buttonStyle(.plain)
            Text(L("home_composer_footer"))
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.l)
    }

    // MARK: — Helpers

    private func loadTransaction() {
        amountStr = String(format: "%.0f", transaction.originalAmount)
        currency = transaction.originalCurrency
        type = transaction.type
        walletName = transaction.walletName
        categoryName = transaction.categoryName
        merchant = transaction.merchant == "Unknown" ? "" : transaction.merchant
        date = transaction.occurredAt
        note = transaction.note
    }

    private func save() {
        let newAmount = Double(amountStr.replacingOccurrences(of: ",", with: ".")) ?? transaction.originalAmount
        store.editTransaction(transaction) { tx in
            tx.typeRaw = type.rawValue
            tx.originalAmount = newAmount
            tx.originalCurrency = currency
            tx.walletName = walletName
            tx.categoryName = categoryName.isEmpty ? tx.categoryName : categoryName
            tx.merchant = merchant
            tx.occurredAt = date
            tx.note = note
        }
        // Update linked chat bubble using the canonical formatter.
        let desc = FetchDescriptor<ChatMessage>()
        if let msgs = try? modelContext.fetch(desc),
           let msg = msgs.first(where: { $0.linkedTransactionID == transaction.id }) {
            msg.content = ChatViewModel.formatSavedReceipt(tx: transaction, store: store)
            try? modelContext.save()
        }
        dismiss()
    }

    private func typeColor(_ t: TransactionType) -> Color {
        switch t {
        case .income: return DS.Color.income
        case .expense: return DS.Color.expense
        case .transfer: return DS.Color.transfer
        }
    }

    private func iconFor(_ t: TransactionType) -> String {
        switch t {
        case .income:   return "arrow.down"
        case .expense:  return "arrow.up"
        case .transfer: return "arrow.left.arrow.right"
        }
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

    // MARK: — Reusable picker sheet

    @ViewBuilder
    private func pickerSheet<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
        NavigationView {
            List { rows() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pickerRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundColor(.primary)
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
        }
    }
}
