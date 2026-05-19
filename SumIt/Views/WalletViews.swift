import SwiftUI
import SwiftData

// MARK: — Wallet List (used in Settings and Reports)
struct WalletManagerSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Wallet.createdAt) var wallets: [Wallet]
    @Environment(\.dismiss) var dismiss
    @State private var showAdd = false
    @State private var editingWallet: Wallet? = nil

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
                            WalletRow(wallet: wallet, store: store)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteWallet(wallet)
                            } label: {
                                Label(L("delete"), systemImage: "trash")
                            }
                        }
                    }
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

    private func deleteWallet(_ wallet: Wallet) {
        let localId = wallet.id.uuidString
        modelContext.delete(wallet)
        try? modelContext.save()

        Task { try? await SupabaseService.shared.deleteWallet(localId: localId) }
    }
}

struct WalletRow: View {
    let wallet: Wallet
    let store: AppStore

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
                Text(Formatters.amount(wallet.balance, fractionDigits: 2))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(wallet.balance >= 0 ? .primary : .red)
                Text(wallet.currency).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EditWalletSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss

    let wallet: Wallet?

    @State private var name: String = ""
    @State private var type: WalletType = .bank
    @State private var currency: String = "UAH"
    @State private var balanceStr: String = ""

    var isNew: Bool { wallet == nil }

    var body: some View {
        NavigationView {
            Form {
                Section(L("name")) {
                    TextField(L("wallet_name_placeholder"), text: $name)
                }
                Section(L("wallet_type")) {
                    Picker(L("wallet_type"), selection: $type) {
                        ForEach(WalletType.allCases, id: \.self) { t in
                            Label(t.label, systemImage: t.defaultIcon).tag(t)
                        }
                    }.pickerStyle(.menu)
                }
                Section(L("balance")) {
                    HStack {
                        TextField("0", text: $balanceStr)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 17, weight: .medium))
                        Spacer()
                        Picker("", selection: $currency) {
                            ForEach(CurrencyService.supported, id: \.code) { c in
                                Text("\(c.flag) \(c.code)").tag(c.code)
                            }
                        }.pickerStyle(.menu)
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
                        .disabled(name.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let w = wallet {
                    name = w.name
                    type = w.walletType
                    currency = w.currency
                    balanceStr = String(format: "%.2f", w.balance)
                }
            }
        }
    }

    private func save() {
        let balance = Double(balanceStr.replacingOccurrences(of: ",", with: ".")) ?? 0

        let saved: Wallet
        if let w = wallet {
            w.name = name
            w.walletType = type
            w.currency = currency
            w.balance = balance
            w.icon = type.defaultIcon
            w.isSynced = false
            saved = w
        } else {
            let w = Wallet(
                userId: AuthService.shared.userId,
                name: name,
                type: type,
                currency: currency,
                balance: balance
            )
            modelContext.insert(w)
            saved = w
        }

        try? modelContext.save()

        let snap = saved.snapshot()
        let id = saved.id
        let store = self.store
        Task {
            do {
                try await SupabaseService.shared.saveWallet(snap)
                await MainActor.run {
                    guard let ctx = store.modelContext else { return }
                    let desc = FetchDescriptor<Wallet>(predicate: #Predicate { $0.id == id })
                    if let row = try? ctx.fetch(desc).first {
                        row.isSynced = true
                        try? ctx.save()
                    }
                }
            } catch {
                Log.warn("Wallet sync deferred")  // AppStore.syncPendingWallets() will retry on next launch
            }
        }

        dismiss()
    }
}
