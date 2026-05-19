import SwiftUI
import SwiftData

struct ConfirmationCard: View {
    @State var parsed: ParsedTransaction
    let store: AppStore
    let onConfirm: () -> Void
    let onEdit: (ParsedTransaction) -> Void
    let onCancel: () -> Void

    @Query(sort: \Wallet.createdAt) var wallets: [Wallet]
    @State private var showEdit = false
    @State private var selectedWalletId: UUID? = nil

    var isLowConfidence: Bool { parsed.confidence < 0.7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            amountBlock
            Divider()
            details
            walletPicker
            if isLowConfidence { lowConfidenceWarning }
            Divider()
            actions
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(.systemGray4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
        .sheet(isPresented: $showEdit) {
            EditParsedView(parsed: $parsed, store: store) {
                showEdit = false
                onEdit(parsed)
            }
        }
        .onAppear {
            if !parsed.walletName.isEmpty {
                selectedWalletId = wallets.first(where: {
                    $0.name.lowercased() == parsed.walletName.lowercased()
                })?.id
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: parsed.type == .income ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundColor(parsed.type == .income ? .green : .red)
            Text(parsed.type.label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            if isLowConfidence {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            }
            Text("AI · \(Int(parsed.confidence * 100))%")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var amountBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parsed.type == .income ? "+" : "-")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(parsed.type == .income ? .green : .primary)
                Text(Formatters.amount(parsed.amount, fractionDigits: 0))
                    .font(.system(size: 36, weight: .semibold))
                Text(parsed.currency)
                    .font(.system(size: 20)).foregroundColor(.secondary)
            }
            let usdAmount = parsed.amount * CurrencyService.toUSD(parsed.currency)
            let displayAmount = usdAmount * CurrencyService.usdTo(store.displayCurrency)
            if parsed.currency != store.displayCurrency {
                Text("≈ \(Formatters.amount(displayAmount, currency: store.displayCurrency, fractionDigits: 2))")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var details: some View {
        VStack(spacing: 0) {
            DetailRow(icon: store.icon(for: parsed.categoryName),
                      iconColor: store.color(for: parsed.categoryName),
                      label: L("category"), value: store.displayCategoryName(parsed.categoryName))
            DetailRow(icon: "storefront", iconColor: .blue,
                      label: L("merchant"), value: parsed.merchant == "Unknown" ? "" : parsed.merchant)
            DetailRow(icon: "calendar", iconColor: .orange,
                      label: L("date"), value: Formatters.shortDate(parsed.occurredAt))
            if !parsed.note.isEmpty {
                DetailRow(icon: "text.bubble", iconColor: .gray,
                          label: L("note"), value: parsed.note)
            }
        }
    }

    @ViewBuilder
    private var walletPicker: some View {
        if !wallets.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "wallet.pass.fill")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.purple)
                        .frame(width: 24)
                    Text(L("wallet")).font(.system(size: 14)).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $selectedWalletId) {
                        Text(L("not_selected")).tag(nil as UUID?)
                        ForEach(wallets) { w in
                            Text(w.name).tag(w.id as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider().padding(.leading, 52)
            }
        }
    }

    private var lowConfidenceWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange).font(.caption)
            Text(L("check_data"))
                .font(.caption).foregroundColor(.orange)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button(action: onCancel) {
                VStack(spacing: 3) {
                    Image(systemName: "xmark").font(.system(size: 15))
                    Text(L("cancel")).font(.system(size: 11))
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            }

            Divider().frame(height: 44)

            Button { showEdit = true } label: {
                VStack(spacing: 3) {
                    Image(systemName: "pencil").font(.system(size: 15))
                    Text(L("edit")).font(.system(size: 11))
                }
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            }

            Divider().frame(height: 44)

            Button {
                if let wId = selectedWalletId, let w = wallets.first(where: { $0.id == wId }) {
                    parsed.walletName = w.name
                }
                onEdit(parsed)
                onConfirm()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                    Text(L("save")).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(parsed.type == .income ? Color.green : Color.accentColor)
            }
        }
    }
}

struct DetailRow: View {
    let icon: String; let iconColor: Color; let label: String; let value: String
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                Text(label).font(.system(size: 14)).foregroundColor(.secondary)
                Spacer()
                Text(value).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().padding(.leading, 52)
        }
    }
}

struct EditParsedView: View {
    @Binding var parsed: ParsedTransaction
    let store: AppStore
    let onDone: () -> Void

    @Query(sort: \Wallet.createdAt) var wallets: [Wallet]
    @State private var amountStr: String = ""
    @State private var currency: String = "UAH"
    @State private var categoryName: String = ""
    @State private var merchant: String = ""
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var type: TransactionType = .expense
    @State private var walletName: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(L("type_label")) {
                    Picker(L("type_label"), selection: $type) {
                        ForEach(TransactionType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section(L("amount_currency")) {
                    HStack {
                        TextField("0", text: $amountStr)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 17, weight: .medium))
                        Spacer()
                        Picker(L("currency"), selection: $currency) {
                            ForEach(CurrencyService.supported, id: \.code) { c in
                                Text("\(c.flag) \(c.code)").tag(c.code)
                            }
                        }.pickerStyle(.menu)
                    }
                }
                Section(L("details")) {
                    TextField(L("merchant_store"), text: $merchant)
                    TextField(L("note"), text: $note)
                    DatePicker(L("date"), selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
                Section(L("category")) {
                    Picker(L("category"), selection: $categoryName) {
                        ForEach(store.allCategories, id: \.name) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat.name)
                        }
                    }
                }
                if !wallets.isEmpty {
                    Section(L("wallet")) {
                        Picker(L("wallet"), selection: $walletName) {
                            Text(L("not_selected")).tag("")
                            ForEach(wallets) { w in
                                Text(w.name).tag(w.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { onDone() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("done")) {
                        let newAmount = Double(amountStr.replacingOccurrences(of: ",", with: ".")) ?? parsed.amount
                        parsed = ParsedTransaction(
                            id: parsed.id,
                            type: type, amount: newAmount, currency: currency,
                            categoryName: categoryName.isEmpty ? parsed.categoryName : categoryName,
                            merchant: merchant,
                            note: note, occurredAt: date, confidence: parsed.confidence,
                            rawInput: parsed.rawInput, source: parsed.source,
                            walletName: walletName
                        )
                        onDone()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                amountStr = String(format: "%.0f", parsed.amount)
                currency = parsed.currency
                categoryName = parsed.categoryName
                merchant = parsed.merchant == "Unknown" ? "" : parsed.merchant
                note = parsed.note
                date = parsed.occurredAt
                type = parsed.type
                walletName = parsed.walletName
            }
        }
    }
}
