import SwiftUI
import SwiftData

/// The new chat-first home screen replacing ChatRootView. Composes:
///   • HomeHeader (chevron + total balance) → taps open QuickSummarySheet
///   • Body: orb empty state OR scrollable chat history with confirmation card
///   • Suggestion chips strip above the composer
///   • Composer with voice / scan / send
struct HomeView: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatMessage.timestamp, order: .forward) private var messages: [ChatMessage]
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var allTx: [Transaction]
    @Query(sort: \Wallet.createdAt) private var wallets: [Wallet]
    @StateObject private var vm = ChatViewModel()
    @State private var showQuickSummary = false
    @State private var editingTransaction: Transaction? = nil
    @State private var detailTransaction: Transaction? = nil
    @State private var messageToDelete: ChatMessage? = nil

    private var hasHistory: Bool { !messages.isEmpty || vm.pendingTransaction != nil || vm.isLoading }

    private var totalBalanceInDisplayCurrency: Double {
        wallets.reduce(0) { acc, w in
            acc + CurrencyService.convert(w.balance, from: w.currency, to: store.displayCurrency)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mainStack
        }
        .background(DS.Color.bgSecondary.ignoresSafeArea())
        .sheet(isPresented: $showQuickSummary) {
            QuickSummarySheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingTransaction) { tx in
            EditTransactionSheetV2(transaction: tx, store: store)
        }
        .sheet(item: $detailTransaction) { tx in
            TransactionDetailView(
                transaction: tx,
                store: store,
                onEdit: { detailTransaction = nil; editingTransaction = tx },
                onClose: { detailTransaction = nil }
            )
        }
        .sheet(isPresented: $vm.showPaywall) { PaywallView(isPresented: $vm.showPaywall) }
        .confirmationDialog(
            L("delete_tx_q"),
            isPresented: Binding(get: { messageToDelete != nil },
                                 set: { if !$0 { messageToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("delete_tx_yes"), role: .destructive) {
                if let m = messageToDelete {
                    vm.deleteMessage(m, allMessages: messages, allTx: allTx, deleteLinkedTx: true)
                }
                messageToDelete = nil
            }
            Button(L("delete_msg_only")) {
                if let m = messageToDelete {
                    vm.deleteMessage(m, allMessages: messages, allTx: allTx, deleteLinkedTx: false)
                }
                messageToDelete = nil
            }
            Button(L("cancel"), role: .cancel) { messageToDelete = nil }
        } message: {
            Text(L("delete_tx_msg"))
        }
        .onAppear {
            vm.inject(context: modelContext, store: store)
        }
        .onChange(of: modelContext) {
            vm.inject(context: modelContext, store: store)
        }
    }

    // MARK: — Layout

    private var mainStack: some View {
        VStack(spacing: 0) {
            HomeHeader(
                totalBalance: totalBalanceInDisplayCurrency,
                currencyCode: store.displayCurrency,
                onTap: { showQuickSummary = true }
            )

            if hasHistory {
                chatBody
            } else {
                EmptyHomeView(userName: store.userName)
                    .padding(.bottom, DS.Space.s)
            }

            SuggestionChipsBar(suggestions: SuggestionChipsBar.defaults()) { chip in
                vm.inputText = chip
            }
            .padding(.bottom, DS.Space.s)

            HomeComposer(vm: vm)
                .padding(.bottom, DS.Space.s)
        }
    }

    // MARK: — Chat history

    private var chatBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DS.Space.s) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        if shouldShowDateDivider(at: index) {
                            DateDividerView(date: msg.timestamp).padding(.vertical, 6)
                        }
                        chatRow(for: msg)
                    }

                    if let pending = vm.pendingTransaction {
                        ConfirmationCard(
                            parsed: pending, store: store,
                            onConfirm: {
                                guard let current = vm.pendingTransaction else { return }
                                Task { await vm.confirmTransaction(current, allMessages: messages) }
                            },
                            onEdit: { vm.pendingTransaction = $0 },
                            onCancel: { vm.cancelTransaction(allMessages: messages) }
                        )
                        .padding(.horizontal, DS.Space.l)
                        .id(pending.id)
                    }

                    if vm.isLoading {
                        TypingIndicatorView().id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.s)
            }
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
            .onChange(of: vm.scrollToBottom) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func chatRow(for msg: ChatMessage) -> some View {
        MessageBubbleView(message: msg, store: store)
            .contextMenu {
                if let txID = msg.linkedTransactionID,
                   let tx = allTx.first(where: { $0.id == txID }) {
                    Button {
                        detailTransaction = tx
                    } label: { Label(L("details"), systemImage: "info.circle") }
                    Button {
                        editingTransaction = tx
                    } label: { Label(L("edit"), systemImage: "pencil") }
                }
                Button(role: .destructive) {
                    if msg.linkedTransactionID != nil {
                        messageToDelete = msg
                    } else {
                        vm.deleteMessage(msg, allMessages: messages, allTx: allTx, deleteLinkedTx: false)
                    }
                } label: { Label(L("delete"), systemImage: "trash") }
            }
            .onTapGesture {
                if let txID = msg.linkedTransactionID,
                   let tx = allTx.first(where: { $0.id == txID }) {
                    detailTransaction = tx
                }
            }
    }

    private func shouldShowDateDivider(at index: Int) -> Bool {
        guard index < messages.count else { return false }
        let msg = messages[index]
        if index == 0 { return true }
        let prev = messages[index - 1]
        return !Calendar.current.isDate(msg.timestamp, inSameDayAs: prev.timestamp)
    }
}
