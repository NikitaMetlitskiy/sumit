import SwiftUI
import SwiftData

struct ConfirmationCard: View {
    @State var parsed: ParsedTransaction
    let store: AppStore
    let onConfirm: () -> Void
    let onEdit: (ParsedTransaction) -> Void
    let onCancel: () -> Void

    @Query(sort: \Wallet.createdAt) private var storedWallets: [Wallet]
    @ObservedObject private var auth: AuthService = .shared
    @State private var showEdit = false
    /// Guards the Save button. A second tap must not create a second
    /// transaction identity while the first one is still being written.
    @State private var isConfirming = false
    /// What the rate service answered for this card's currency and day.
    @State private var quoteState: QuoteAvailability?

    var wallets: [Wallet] { LedgerScope.activeWallets(storedWallets, ownerID: auth.userId) }

    var isLowConfidence: Bool { parsed.confidence < 0.7 }

    /// The exact amount as text: `amount_decimal` from the parser, or — for a
    /// response from a server that predates contract v2 — the shortest faithful
    /// reading of its Double.
    private var exactAmountText: String {
        if let exact = parsed.amountExact, !exact.isEmpty { return exact }
        return (try? MoneyCodec.encode((try? MoneyCodec.decode(String(parsed.amount))) ?? 0)) ?? "0"
    }

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
        .task(id: "\(parsed.currency.uppercased())|\(quoteDay ?? "current")") { await loadQuote() }
        .sheet(isPresented: $showEdit) {
            EditParsedView(parsed: $parsed, store: store) {
                showEdit = false
                onEdit(parsed)
            }
        }
        .onAppear {
            // A name is resolved to an identity once, here. Nothing downstream
            // matches wallets by name any more.
            if parsed.walletID == nil, !parsed.walletName.isEmpty {
                let matches = wallets.filter {
                    $0.name.compare(parsed.walletName, options: .caseInsensitive) == .orderedSame
                }
                if matches.count == 1 { parsed.walletID = matches[0].id }
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
                Text(Formatters.exactAmount(exactAmountText))
                    .font(.system(size: 36, weight: .semibold))
                    .accessibilityIdentifier("confirmation-amount")
                Text(parsed.currency)
                    .font(.system(size: 20)).foregroundColor(.secondary)
            }
            valuationLine
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var quoteDay: String? { RatePolicy.requestDay(for: parsed.occurredAt, now: Date()) }

    /// The USD value this entry will be booked at, or a plain statement that it
    /// will be saved without one. Shown before Save, so tapping Save is the
    /// confirmation of the rate too.
    @ViewBuilder
    private var valuationLine: some View {
        if parsed.currency.uppercased() != "USD" {
            HStack(spacing: 6) {
                if case .quoted(let quote)? = parsed.valuation {
                    Text(bookedPreview(quote)).font(.caption).foregroundColor(.secondary)
                } else if case .stale(let quote)? = quoteState {
                    Text(String(format: L("valuation_stale"), Formatters.shortDate(quote.effectiveAt)))
                        .font(.caption).foregroundColor(.orange)
                    Button(L("valuation_use_stale")) { parsed.valuation = .quoted(quote) }
                        .font(.caption)
                } else if quoteState == nil {
                    ProgressView().controlSize(.mini)
                    Text(L("valuation_loading")).font(.caption).foregroundColor(.secondary)
                } else {
                    Text(L("receipt_unconverted")).font(.caption).foregroundColor(.secondary)
                }
            }
            .accessibilityIdentifier("confirmation-valuation")
        }
    }

    private func bookedPreview(_ quote: RateQuote) -> String {
        guard let amount = try? MoneyCodec.decode(exactAmountText),
              let rate = try? MoneyCodec.decode(quote.usdPerUnit),
              let usd = try? MoneyCodec.quantize(amount * rate, scale: 2) else { return QuoteText.line(quote) }
        return "≈ \(Formatters.exactAmount(usd, currency: "USD")) · \(QuoteText.line(quote))"
    }

    private func loadQuote() async {
        let currency = parsed.currency.uppercased()
        guard currency != "USD" else { return }
        if case .quoted(let quote)? = parsed.valuation,
           quote.currency == currency, quote.requestedDate == quoteDay || quote.valuationKind == .manual {
            return
        }
        parsed.valuation = nil
        quoteState = nil
        guard let rateService = store.rateService else {
            quoteState = .unavailable(reason: "offline", retryable: true)
            return
        }
        let result = await rateService.availability(currency: currency, day: quoteDay)
        quoteState = result
        if case .fresh(let quote) = result { parsed.valuation = .quoted(quote) }
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
                    Picker("", selection: $parsed.walletID) {
                        Text(L("not_selected")).tag(nil as UUID?)
                        ForEach(wallets) { w in
                            Text("\(w.name) · \(w.currency)").tag(w.id as UUID?)
                        }
                    }
                    .accessibilityIdentifier("confirmation-wallet")
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
                guard !isConfirming else { return }
                // The parser can say "this is a transfer"; it cannot say which
                // two wallets. Until the user has picked both, Save opens the
                // editor instead of attempting a save that must be refused.
                if parsed.type == .transfer,
                   parsed.walletID == nil || parsed.destinationWalletID == nil {
                    showEdit = true
                    return
                }
                isConfirming = true
                // Clearing the wallet clears it: the old code only ever wrote a
                // name in, so deselecting left the previous one attached.
                parsed.walletName = parsed.walletID
                    .flatMap { id in wallets.first { $0.id == id }?.name } ?? ""
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
            .disabled(isConfirming)
            .accessibilityIdentifier("confirmation-save")
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

/// Edits a parsed transaction before it is saved.
///
/// It shares `TransactionFieldsForm` with the edit sheet, so the two editors
/// cannot drift apart, and it writes back the **exact** strings rather than a
/// Double reconstructed from what was typed.
struct EditParsedView: View {
    @Binding var parsed: ParsedTransaction
    let store: AppStore
    let onDone: () -> Void

    @Query(sort: \Wallet.createdAt) private var storedWallets: [Wallet]
    @ObservedObject private var auth: AuthService = .shared
    @State private var fields: TransactionEditorFields?

    private var wallets: [Wallet] { LedgerScope.activeWallets(storedWallets, ownerID: auth.userId) }

    private var problem: TransactionEditorProblem? {
        guard let fields else { return nil }
        return TransactionEditor.problem(in: fields, id: parsed.id, wallets: wallets,
                                         ownerID: auth.userId)
    }

    var body: some View {
        NavigationView {
            Group {
                if let binding = Binding($fields) {
                    TransactionFieldsForm(fields: binding, wallets: wallets,
                                          categories: store.allCategories, problem: problem,
                                          rateService: store.rateService)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L("edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("cancel")) { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("done")) { apply() }
                        .fontWeight(.semibold)
                        .disabled(problem != nil)
                        .accessibilityIdentifier("parsed-editor-done")
                }
            }
            .onAppear {
                if fields == nil {
                    fields = TransactionEditor.fields(from: parsed, wallets: wallets,
                                                      ownerID: auth.userId)
                }
            }
        }
    }

    /// Writes the edited values back onto the binding the card holds, so the
    /// card confirms exactly what is on screen.
    private func apply() {
        guard let fields,
              case .success(let draft) = TransactionEditor.draft(
                from: fields, id: parsed.id, wallets: wallets, ownerID: auth.userId) else { return }

        parsed.type = draft.type
        parsed.amountExact = try? MoneyCodec.encode(draft.amount)
        parsed.amount = NSDecimalNumber(decimal: draft.amount).doubleValue
        parsed.currency = draft.currency
        parsed.categoryName = draft.categoryName.isEmpty ? parsed.categoryName : draft.categoryName
        parsed.merchant = draft.merchant
        parsed.note = draft.note
        parsed.occurredAt = draft.occurredAt
        parsed.walletID = draft.walletID
        parsed.walletAmountExact = try? draft.walletAmount.map(MoneyCodec.encode)
        parsed.destinationWalletID = draft.destinationWalletID
        parsed.valuation = draft.valuation
        parsed.destinationAmountExact = try? draft.destinationAmount.map(MoneyCodec.encode)
        parsed.walletName = draft.walletID
            .flatMap { id in wallets.first { $0.id == id }?.name } ?? ""
        onDone()
    }
}
