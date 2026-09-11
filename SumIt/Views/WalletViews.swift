import SwiftUI
import SwiftData

// MARK: — Wallet List (used in Settings and Reports)
struct WalletManagerSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Wallet.createdAt) private var storedWallets: [Wallet]
    @ObservedObject private var auth = AuthService.shared

    var wallets: [Wallet] { LedgerScope.activeWallets(storedWallets, ownerID: auth.userId) }
    @Environment(\.dismiss) var dismiss
    @State private var showAdd = false
    @State private var editingWallet: Wallet? = nil
    @State private var archiveError: String?

    /// Derived from opening balance plus the effects of the owner's entries.
    /// Never a stored running total that save and delete kept nudging.
    private var balances: [UUID: Decimal] { store.walletBalances() }

    var body: some View {
        NavigationView {
            List {
                if wallets.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "wallet.pass")
                            .font(.system(size: 44, weight: .ultraLight))
                            .foregroundColor(Color.accentColor.opacity(0.3))
                        Text(L("no_wallets")).font(.headline)
                        Text(L("add_bank_exchange"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(wallets) { wallet in
                        Button { editingWallet = wallet } label: {
                            WalletRow(wallet: wallet, balance: balances[wallet.id])
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                archive(wallet)
                            } label: {
                                Label(L("editor_archive_wallet"), systemImage: "archivebox")
                            }
                        }
                    }
                }
                if let archiveError {
                    Text(archiveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("wallet-error")
                }
            }
            .navigationTitle(L("wallets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) {
                EditWalletSheet(store: store, wallet: nil)
            }
            .sheet(item: $editingWallet) { wallet in
                EditWalletSheet(store: store, wallet: wallet)
            }
        }
    }

    /// Archives. Deleting the row would take every transaction that references
    /// this wallet with it, and would not reach the user's other devices.
    private func archive(_ wallet: Wallet) {
        guard !store.archiveWallet(id: wallet.id) else { return }
        archiveError = LedgerErrorCopy.text(for: store.lastWriteErrorCode)
    }
}

struct WalletRow: View {
    let wallet: Wallet
    /// `nil` only if the balance could not be derived, which is shown as such
    /// rather than as a confident zero.
    let balance: Decimal?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: wallet.icon)
                .font(.system(size: 20))
                .foregroundColor(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                Text(wallet.walletType.label).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let balance {
                    Text(Formatters.exactAmount(balance))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(balance >= 0 ? .primary : .red)
                        .accessibilityIdentifier("wallet-balance")
                } else {
                    Text("—")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                Text(wallet.currency).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Creates or edits one wallet.
///
/// The balance field is the **opening** balance — the amount the wallet started
/// from. The current balance is derived from it plus every entry, so it is
/// shown but never typed: an editable current balance is what let the stored
/// total drift away from the transactions it was supposed to summarise.
struct EditWalletSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let wallet: Wallet?

    @State private var name: String = ""
    @State private var type: WalletType = .bank
    @State private var currency: String = "USD"
    @State private var openingBalanceText: String = ""
    @State private var saveError: String?
    @State private var isSaving = false

    var isNew: Bool { wallet == nil }

    /// A wallet with history keeps its currency: changing it would silently
    /// reinterpret every quantity already recorded against it.
    private var currencyIsLocked: Bool {
        guard let wallet else { return false }
        return store.walletHasLinkedRecords(id: wallet.id)
    }

    private var openingBalanceProblem: String? {
        let trimmed = openingBalanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "invalid_amount" }
        do {
            _ = try AmountParser.parse(trimmed, currency: currency, locale: AppLocale.current,
                                       allowNegative: true, allowZero: true)
            return nil
        } catch let error as MoneyError {
            switch error {
            case .excessPrecision:     return "excess_precision"
            case .outOfRange:          return "amount_out_of_range"
            case .nonFinite:           return "non_finite_amount"
            case .unsupportedCurrency: return "unsupported_currency"
            case .arithmeticFailure:   return "arithmetic_failure"
            case .invalidSyntax:       return "invalid_amount"
            }
        } catch {
            return "invalid_amount"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && openingBalanceProblem == nil && !isSaving
    }

    var body: some View {
        NavigationView {
            Form {
                Section(L("name")) {
                    TextField(L("wallet_name_placeholder"), text: $name)
                        .accessibilityIdentifier("wallet-name")
                }
                Section(L("wallet_type")) {
                    Picker(L("wallet_type"), selection: $type) {
                        ForEach(WalletType.allCases, id: \.self) { item in
                            Label(item.label, systemImage: item.defaultIcon).tag(item)
                        }
                    }.pickerStyle(.menu)
                }
                Section {
                    HStack {
                        TextField("0", text: $openingBalanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(size: 17, weight: .medium))
                            .accessibilityIdentifier("wallet-opening-balance")
                        Spacer()
                        Picker("", selection: $currency) {
                            ForEach(CurrencyService.supported, id: \.code) { item in
                                Text("\(item.flag) \(item.code)").tag(item.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(currencyIsLocked)
                    }
                    if let problem = openingBalanceProblem, !openingBalanceText.isEmpty,
                       let text = LedgerErrorCopy.text(for: problem) {
                        Text(text).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("wallet-field-error")
                    }
                } header: {
                    Text(L("editor_opening_balance"))
                } footer: {
                    if currencyIsLocked { Text(L("editor_currency_locked")) }
                }

                if let wallet, let current = store.walletBalances()[wallet.id] {
                    Section(L("editor_current_balance")) {
                        HStack {
                            Text(L("editor_current_balance")).foregroundStyle(.secondary)
                            Spacer()
                            Text(Formatters.exactAmount(current, currency: wallet.currency))
                                .accessibilityIdentifier("wallet-current-balance")
                        }
                        .font(.subheadline)
                    }
                }

                if let saveError {
                    Section {
                        Text(saveError).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("wallet-save-error")
                    }
                }
            }
            .navigationTitle(isNew ? L("new_wallet") : L("edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? L("add") : L("save")) { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("wallet-save")
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let wallet else {
            currency = store.displayCurrency
            openingBalanceText = "0"
            return
        }
        name = wallet.name
        type = wallet.walletType
        currency = wallet.currency
        // The exact stored opening balance. Reformatting it through "%.2f"
        // would quietly round a crypto wallet on every visit.
        openingBalanceText = wallet.openingBalanceExact
            ?? (try? MoneyCodec.editString(wallet.openingBalance, locale: AppLocale.current)) ?? "0"
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        guard let opening = try? AmountParser.parse(
            openingBalanceText.trimmingCharacters(in: .whitespacesAndNewlines),
            currency: currency, locale: AppLocale.current, allowNegative: true, allowZero: true) else {
            saveError = LedgerErrorCopy.text(for: "invalid_amount")
            return
        }

        let draft = WalletDraft(id: wallet?.id ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                type: type,
                                currency: currency,
                                openingBalance: opening,
                                icon: type.defaultIcon)
        guard store.saveWallet(draft) else {
            saveError = LedgerErrorCopy.text(for: store.lastWriteErrorCode)
            return
        }
        dismiss()
    }
}
