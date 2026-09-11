import SwiftUI
import SwiftData

/// Edits one saved transaction.
///
/// Everything typed lives in a `TransactionEditorFields` value. The stored
/// record is not touched until Save produces a complete, valid draft, so
/// Cancel really cancels and a rejected save leaves the record as it was.
struct EditTransactionSheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction
    let store: AppStore

    @Query private var storedWallets: [Wallet]
    @ObservedObject private var auth: AuthService = .shared

    @State private var fields: TransactionEditorFields?
    @State private var saveError: String?
    @State private var isSaving = false

    private var wallets: [Wallet] {
        LedgerScope.activeWallets(storedWallets, ownerID: auth.userId)
    }

    /// Archiving hides a wallet from new entries but must not erase history, so
    /// the wallet this record already points at stays selectable.
    private var selectableWallets: [Wallet] {
        let current = storedWallets.filter {
            $0.userId == auth.userId
                && ($0.id == transaction.walletID || $0.id == transaction.destinationWalletID)
        }
        return (wallets + current.filter { wallet in !wallets.contains { $0.id == wallet.id } })
    }

    private var problem: TransactionEditorProblem? {
        guard let fields else { return nil }
        return TransactionEditor.problem(in: fields, id: transaction.id, wallets: selectableWallets,
                                         ownerID: auth.userId, previous: transaction)
    }

    var body: some View {
        NavigationView {
            Group {
                if let binding = Binding($fields) {
                    TransactionFieldsForm(fields: binding,
                                          wallets: selectableWallets,
                                          categories: store.allCategories,
                                          problem: problem,
                                          footer: saveError,
                                          rateService: store.rateService,
                                          autoApplyFreshQuote: false,
                                          canKeepExisting: transaction.valuationState == .valued)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L("edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) { save() }
                        .fontWeight(.semibold)
                        .disabled(problem != nil || isSaving)
                        .accessibilityIdentifier("editor-save")
                }
            }
            .onAppear {
                if fields == nil { fields = TransactionEditor.fields(from: transaction) }
            }
        }
    }

    private func save() {
        guard let fields, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        switch TransactionEditor.draft(from: fields, id: transaction.id, wallets: selectableWallets,
                                       ownerID: auth.userId, previous: transaction) {
        case .failure(let problem):
            saveError = LedgerErrorCopy.text(for: problem.code)
        case .success(let draft):
            guard store.editTransaction(draft) else {
                // The sheet stays open with everything the user typed still in
                // it. Dismissing here would discard the edit and imply it landed.
                saveError = LedgerErrorCopy.text(for: store.lastWriteErrorCode)
                return
            }
            refreshLinkedMessage()
            dismiss()
        }
    }

    /// The chat bubble quotes the amount, so it is rewritten from the stored
    /// record after the record has actually changed — never before.
    private func refreshLinkedMessage() {
        let id = transaction.id
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { $0.linkedTransactionID == id })
        guard let message = try? modelContext.fetch(descriptor).first else { return }
        message.content = ChatViewModel.formatSavedReceipt(tx: transaction, store: store)
        do { try modelContext.save() } catch { Log.warn("Chat bubble refresh failed") }
    }
}

// MARK: — The shared form

/// The fields themselves, used by the edit sheet and by the confirmation card's
/// editor so the two cannot drift apart.
struct TransactionFieldsForm: View {

    @Binding var fields: TransactionEditorFields
    let wallets: [Wallet]
    let categories: [Category]
    let problem: TransactionEditorProblem?
    var footer: String?
    /// Source of dated quotes. `nil` still allows a manual rate or no conversion.
    var rateService: RateService? = nil
    /// A new entry takes a fresh quote as soon as it arrives; an existing
    /// record never has its rate replaced without the user choosing.
    var autoApplyFreshQuote: Bool = true
    /// Whether "keep the current rate" is a meaningful option.
    var canKeepExisting: Bool = false

    @State private var quoteState: QuoteAvailability?
    @State private var isLoadingQuote = false

    private func wallet(_ id: UUID?) -> Wallet? {
        id.flatMap { wid in wallets.first { $0.id == wid } }
    }

    private var sourceNeedsOwnAmount: Bool {
        guard let source = wallet(fields.walletID) else { return false }
        return source.currency.uppercased() != fields.currency.uppercased()
    }

    private var destinationNeedsOwnAmount: Bool {
        guard fields.type == .transfer,
              let source = wallet(fields.walletID),
              let destination = wallet(fields.destinationWalletID) else { return false }
        return source.currency.uppercased() != destination.currency.uppercased()
    }

    var body: some View {
        Form {
            Section(L("type_label")) {
                Picker(L("type_label"), selection: $fields.type) {
                    ForEach(TransactionType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("editor-type")
            }

            Section(L("amount_currency")) {
                HStack {
                    TextField("0", text: $fields.amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17, weight: .medium))
                        .accessibilityIdentifier("editor-amount")
                    Spacer()
                    Picker("", selection: $fields.currency) {
                        ForEach(CurrencyService.supported, id: \.code) { item in
                            Text("\(item.flag) \(item.code)").tag(item.code)
                        }
                    }
                    .pickerStyle(.menu)
                }
                message(for: .amount(""))
            }

            valuationSection

            walletSection

            Section(L("details")) {
                TextField(L("merchant_store"), text: $fields.merchant)
                    .accessibilityIdentifier("editor-merchant")
                TextField(L("note_optional"), text: $fields.note)
                DatePicker(L("date"), selection: $fields.occurredAt, displayedComponents: [.date])
            }

            if fields.type != .transfer {
                Section(L("category")) {
                    Picker(L("category"), selection: $fields.categoryName) {
                        ForEach(categories, id: \.name) { category in
                            Label(category.displayName, systemImage: category.icon).tag(category.name)
                        }
                    }
                }
            }

            if let text = formProblemText ?? footer {
                Section {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("editor-error")
                }
            }
        }
    }

    @ViewBuilder
    private var walletSection: some View {
        Section(fields.type == .transfer ? L("editor_transfer") : L("wallets")) {
            Picker(fields.type == .transfer ? L("editor_wallet_source") : L("wallet"),
                   selection: $fields.walletID) {
                Text(L("editor_wallet_none")).tag(UUID?.none)
                ForEach(wallets, id: \.id) { wallet in
                    Text(walletLabel(wallet)).tag(UUID?.some(wallet.id))
                }
            }
            .accessibilityIdentifier("editor-wallet")

            if sourceNeedsOwnAmount, let source = wallet(fields.walletID) {
                // Two currencies: only the person entering it knows the exact
                // quantity that left the wallet. Nothing here invents a rate.
                HStack {
                    Text(String(format: L("editor_amount_in"), source.currency))
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", text: $fields.walletAmountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("editor-wallet-amount")
                }
                message(for: .walletAmount(""))
            }

            if fields.type == .transfer {
                Picker(L("editor_wallet_destination"), selection: $fields.destinationWalletID) {
                    Text(L("editor_wallet_none")).tag(UUID?.none)
                    ForEach(wallets, id: \.id) { wallet in
                        Text(walletLabel(wallet)).tag(UUID?.some(wallet.id))
                    }
                }
                .accessibilityIdentifier("editor-destination-wallet")

                if destinationNeedsOwnAmount, let destination = wallet(fields.destinationWalletID) {
                    HStack {
                        Text(String(format: L("editor_amount_in"), destination.currency))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", text: $fields.destinationAmountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("editor-destination-amount")
                    }
                    message(for: .destinationAmount(""))
                }
            }
        }
    }

    // MARK: — Valuation

    private var requestDay: String? {
        RatePolicy.requestDay(for: fields.occurredAt, now: Date())
    }

    private var quoteKey: String {
        "\(fields.currency.uppercased())|\(requestDay ?? "current")"
    }

    private var manualRateText: Binding<String> {
        Binding(
            get: { if case .manual(let text) = fields.valuation { return text } else { return "" } },
            set: { fields.valuation = .manual($0) })
    }

    @ViewBuilder
    private var valuationSection: some View {
        Section(L("valuation_section")) {
            if fields.currency.uppercased() == "USD" {
                Text(L("valuation_usd_native")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                chosenValuation
                quoteOffer
                if case .manual = fields.valuation {
                    TextField(String(format: L("valuation_manual_placeholder"), fields.currency),
                              text: manualRateText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("editor-manual-rate")
                } else {
                    Button(L("valuation_enter_manual")) { fields.valuation = .manual("") }
                        .accessibilityIdentifier("editor-valuation-manual")
                }
                if fields.valuation != .unvalued {
                    Button(L("valuation_save_unvalued")) { fields.valuation = .unvalued }
                        .accessibilityIdentifier("editor-valuation-unvalued")
                }
                if canKeepExisting, fields.valuation != .keepExisting {
                    Button(L("valuation_keep_existing")) { fields.valuation = .keepExisting }
                        .accessibilityIdentifier("editor-valuation-keep")
                }
            }
        }
        .task(id: quoteKey) { await loadQuote() }
    }

    @ViewBuilder
    private var chosenValuation: some View {
        switch fields.valuation {
        case .quote(let quote):
            Label(QuoteText.line(quote), systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(.green)
        case .manual:
            Text(L("valuation_using_manual")).font(.subheadline)
        case .unvalued:
            Text(L("valuation_chosen_unvalued")).font(.subheadline).foregroundStyle(.secondary)
        case .keepExisting:
            Text(L("valuation_keep_existing")).font(.subheadline)
        case .automatic:
            Text(canKeepExisting || !autoApplyFreshQuote ? L("valuation_unchanged") : L("valuation_chosen_unvalued"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var quoteOffer: some View {
        if isLoadingQuote {
            HStack(spacing: 8) {
                ProgressView()
                Text(L("valuation_loading")).font(.caption).foregroundStyle(.secondary)
            }
        } else if let quoteState {
            switch quoteState {
            case .identity:
                EmptyView()
            case .fresh(let quote):
                if fields.valuation != .quote(quote) {
                    Button(L("valuation_use_quote") + " — " + QuoteText.line(quote)) {
                        fields.valuation = .quote(quote)
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("editor-valuation-use-quote")
                }
            case .stale(let quote):
                if fields.valuation != .quote(quote) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: L("valuation_stale"), Formatters.shortDate(quote.effectiveAt)))
                            .font(.caption).foregroundStyle(.orange)
                        // Older than the automatic window: offered, never applied.
                        Button(L("valuation_use_stale") + " — " + QuoteText.line(quote)) {
                            fields.valuation = .quote(quote)
                        }
                        .font(.footnote)
                        .accessibilityIdentifier("editor-valuation-use-stale")
                    }
                }
            case .unavailable(let reason, _):
                Text(String(format: L("valuation_unavailable"), QuoteText.reason(reason)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadQuote() async {
        let currency = fields.currency.uppercased()
        // A quote chosen for a different currency or day no longer applies.
        if case .quote(let quote) = fields.valuation,
           quote.currency != currency || (quote.valuationKind != .identity && quote.requestedDate != requestDay) {
            fields.valuation = .automatic
        }
        guard currency != "USD" else { quoteState = nil; return }
        guard let rateService else {
            quoteState = .unavailable(reason: "offline", retryable: true)
            return
        }
        isLoadingQuote = true
        let result = await rateService.availability(currency: currency, day: requestDay)
        isLoadingQuote = false
        quoteState = result
        if autoApplyFreshQuote, fields.valuation == .automatic, case .fresh(let quote) = result {
            fields.valuation = .quote(quote)
        }
    }

    private func walletLabel(_ wallet: Wallet) -> String {
        wallet.isArchived ? "\(wallet.name) · \(L("editor_wallet_archived"))"
                          : "\(wallet.name) · \(wallet.currency)"
    }

    private var formProblemText: String? {
        guard case .form(let code)? = problem else { return nil }
        return LedgerErrorCopy.text(for: code)
    }

    /// Shows the message under the field it belongs to. The empty associated
    /// value is only a tag for which field this is.
    @ViewBuilder
    private func message(for kind: TransactionEditorProblem) -> some View {
        if let problem, sameField(problem, kind), let text = LedgerErrorCopy.text(for: problem.code) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("editor-field-error")
        }
    }

    private func sameField(_ lhs: TransactionEditorProblem, _ rhs: TransactionEditorProblem) -> Bool {
        switch (lhs, rhs) {
        case (.amount, .amount), (.walletAmount, .walletAmount),
             (.destinationAmount, .destinationAmount), (.form, .form): return true
        default: return false
        }
    }
}
