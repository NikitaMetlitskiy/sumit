import SwiftUI
import SwiftData

/// Redesigned confirmation card matching the Figma layout:
///   • Header: arrow icon + type label + timestamp pill
///   • Big amount with converted-to-display side note
///   • Category row with colored chip
///   • Merchant row with "+ Add" affordance when empty
///   • Wallet section at the bottom — either selected wallet or an "Add Wallet to Save" CTA
///   • Below the card: hint text + pencil-edit button + checkmark-save button
struct ConfirmationCard: View {
    @State var parsed: ParsedTransaction
    let store: AppStore
    let onConfirm: () -> Void
    let onEdit: (ParsedTransaction) -> Void
    let onCancel: () -> Void

    @Query(sort: \Wallet.createdAt) private var wallets: [Wallet]
    @State private var showEdit = false
    @State private var showAddWallet = false
    @State private var showWalletPicker = false
    @State private var selectedWalletId: UUID? = nil

    private var selectedWallet: Wallet? {
        if let id = selectedWalletId { return wallets.first { $0.id == id } }
        return wallets.first { $0.name.lowercased() == parsed.walletName.lowercased() }
    }

    private var hasWalletSet: Bool { selectedWallet != nil || !wallets.isEmpty }

    private var displayAmount: String {
        Formatters.amount(parsed.amount, currency: parsed.currency, fractionDigits: 0)
    }

    private var convertedAmount: String? {
        guard parsed.currency != store.displayCurrency else { return nil }
        let inUSD = parsed.amount * CurrencyService.toUSD(parsed.currency)
        let inDisplay = inUSD * CurrencyService.usdTo(store.displayCurrency)
        return Formatters.amount(inDisplay, currency: store.displayCurrency, fractionDigits: 0)
    }

    var body: some View {
        VStack(spacing: DS.Space.s) {
            card
            footerHint
        }
        .sheet(isPresented: $showEdit) {
            EditParsedView(parsed: $parsed, store: store) {
                showEdit = false
                onEdit(parsed)
            }
        }
        .sheet(isPresented: $showAddWallet) {
            EditWalletSheet(store: store, wallet: nil)
        }
        .sheet(isPresented: $showWalletPicker) {
            walletPickerSheet
        }
        .onAppear {
            if !parsed.walletName.isEmpty {
                selectedWalletId = wallets.first(where: {
                    $0.name.lowercased() == parsed.walletName.lowercased()
                })?.id
            }
        }
    }

    // MARK: — Card body

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            amountBlock
            Divider().padding(.horizontal, DS.Space.l)
            detailRow(label: L("category")) { categoryChip }
            detailRow(label: L("merchant")) { merchantTrailing }
            walletSection
        }
        .background(DS.Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cardCorner, style: .continuous)
                .stroke(DS.Color.strokeSoft, lineWidth: 0.5)
        )
        .dsCardShadow()
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(typeColor.opacity(0.15)).frame(width: 22, height: 22)
                Image(systemName: parsed.type == .income ? "arrow.down" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(typeColor)
            }
            Text(parsed.type.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
            Text(Formatters.shortDate(parsed.occurredAt))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(parsed.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.l)
        .padding(.bottom, 10)
    }

    private var amountBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parsed.type == .income ? "+" : "-")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(.primary)
            Text(displayAmount)
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.primary)
            Text(parsed.currency)
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .padding(.leading, 2)
            if let conv = convertedAmount {
                Text("≈ \(conv)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .padding(.leading, 6)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    private func detailRow<Trailing: View>(label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                Spacer()
                trailing()
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, 12)
            Divider().padding(.horizontal, DS.Space.l)
        }
    }

    private var categoryChip: some View {
        let name = parsed.categoryName
        return HStack(spacing: 6) {
            Image(systemName: store.icon(for: name))
                .font(.system(size: 12, weight: .regular))
            Text(store.displayCategoryName(name))
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(store.color(for: name)))
    }

    @ViewBuilder
    private var merchantTrailing: some View {
        if parsed.merchant.isEmpty || parsed.merchant == "Unknown" {
            Button { showEdit = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text(L("add"))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            Text(parsed.merchant)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
        }
    }

    @ViewBuilder
    private var walletSection: some View {
        if wallets.isEmpty {
            // No wallets at all — primary CTA inside the card
            Button { showAddWallet = true } label: {
                HStack {
                    Image(systemName: "wallet.pass")
                    Text(L("add_wallet_to_save"))
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            DS.Color.stroke,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                )
                .padding(DS.Space.m)
            }
            .buttonStyle(.plain)
        } else {
            Button { showWalletPicker = true } label: {
                HStack(spacing: 10) {
                    WalletBrandBadge(walletName: selectedWallet?.name ?? wallets[0].name, size: 22)
                    Text(selectedWallet?.name ?? wallets[0].name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: — Footer hint row

    private var footerHint: some View {
        HStack(spacing: 8) {
            Text(L("tx_all_correct"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            // Edit pencil
            Button { showEdit = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DS.Color.bg))
                    .overlay(Circle().stroke(DS.Color.strokeSoft, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Save — only when wallet is set (or no wallet system enabled yet)
            if !wallets.isEmpty {
                Button {
                    if let w = selectedWallet { parsed.walletName = w.name }
                    onEdit(parsed)
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.l)
    }

    private var typeColor: Color {
        switch parsed.type {
        case .income:   return DS.Color.income
        case .expense:  return DS.Color.expense
        case .transfer: return DS.Color.transfer
        }
    }

    private var walletPickerSheet: some View {
        NavigationView {
            List {
                ForEach(wallets) { w in
                    Button {
                        selectedWalletId = w.id
                        parsed.walletName = w.name
                        onEdit(parsed)
                        showWalletPicker = false
                    } label: {
                        HStack(spacing: 12) {
                            WalletBrandBadge(walletName: w.name, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.name).font(.system(size: 15, weight: .medium))
                                Text(w.walletType.label).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedWalletId == w.id {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }.foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle(L("wallet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("close")) { showWalletPicker = false }
                }
            }
        }
    }
}

// MARK: — EditParsedView (sheet)

/// Lightweight edit form used by the inline pencil. The full-screen detail-edit modal
/// (dark theme) lives in EditTransactionSheetV2 and is used on saved transactions.
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
