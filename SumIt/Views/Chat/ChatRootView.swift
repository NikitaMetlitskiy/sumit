import SwiftUI
import SwiftData

struct ChatRootView: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatMessage.timestamp, order: .forward) private var allMessages: [ChatMessage]
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var storedTx: [Transaction]
    @ObservedObject private var auth = AuthService.shared

    /// Only this account's rows, and only the ones that are not deleted.
    var messages: [ChatMessage] { LedgerScope.visibleMessages(allMessages, ownerID: auth.userId) }
    var allTx: [Transaction] { LedgerScope.activeTransactions(storedTx, ownerID: auth.userId) }
    @StateObject private var vm = ChatViewModel()
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var storeKit = StoreKitManager.shared
    @State private var showCurrencyPicker = false
    @State private var showScrollButton = false
    @State private var editingTransaction: Transaction? = nil
    @State private var messageToDelete: ChatMessage? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                if messages.isEmpty && !vm.isLoading {
                                    ChatEmptyState().padding(.top, 60)
                                }

                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                    if shouldShowDateDivider(at: index) {
                                        DateDividerView(date: msg.timestamp)
                                            .padding(.vertical, 8)
                                    }
                                    MessageBubbleView(message: msg, store: store)
                                        .id(msg.id)
                                        .contextMenu {
                                            if let txID = msg.linkedTransactionID,
                                               let tx = allTx.first(where: { $0.id == txID }) {
                                                Button {
                                                    editingTransaction = tx
                                                } label: {
                                                    Label(L("edit"), systemImage: "pencil")
                                                }
                                            }
                                            Button(role: .destructive) {
                                                if msg.linkedTransactionID != nil {
                                                    messageToDelete = msg
                                                } else {
                                                    vm.deleteMessage(msg, allMessages: messages, allTx: allTx, deleteLinkedTx: false)
                                                }
                                            } label: {
                                                Label(L("delete"), systemImage: "trash")
                                            }
                                        }
                                }

                                if let pending = vm.pendingTransaction {
                                    ConfirmationCard(
                                        parsed: pending, store: store,
                                        onConfirm: {
                                            guard let current = vm.pendingTransaction else { return }
                                            Task { await vm.confirmTransaction(current, allMessages: messages) }
                                        },
                                        onEdit: { edited in vm.pendingTransaction = edited },
                                        onCancel: { vm.cancelTransaction(allMessages: messages) }
                                    )
                                    .padding(.horizontal, 12)
                                    .id(pending.id)
                                }

                                if vm.isLoading { TypingIndicatorView().id("typing") }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .onTapGesture {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil)
                        }
                        .onChange(of: vm.scrollToBottom) {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(50))
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .onChange(of: vm.pendingTransaction != nil) {
                            if vm.pendingTransaction != nil {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(150))
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: vm.isLoading) {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(50))
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(100))
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }

                    if showScrollButton {
                        Button { showScrollButton = false } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(Color.accentColor)
                                .background(Color(.systemBackground).clipShape(Circle()))
                                .shadow(color: .black.opacity(0.15), radius: 4)
                        }
                        .padding(.trailing, 16).padding(.bottom, 8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }

                Divider()

                if vm.pendingTransaction == nil {
                    ChatComposer(vm: vm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color(.systemGroupedBackground))
            .animation(.easeInOut(duration: 0.2), value: vm.pendingTransaction != nil)
            .navigationTitle(L("app_name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if PAYWALL_ENABLED && storeKit.hasActiveSubscription && storeKit.currentTier == .basic {
                        Text(String(format: L("parses_left_chip"), storeKit.parsesRemaining))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCurrencyPicker = true } label: {
                        Text(store.displayCurrency)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
            .sheet(isPresented: $showCurrencyPicker) { CurrencyPickerSheet(store: store) }
            .sheet(isPresented: $vm.showPaywall) { PaywallView(isPresented: $vm.showPaywall) }
            .sheet(item: $editingTransaction) { tx in
                EditTransactionSheet(transaction: tx, store: store)
            }
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
        }
        .onAppear {
            vm.inject(context: modelContext, store: store)
            insertWelcomeIfNeeded()
        }
        .onChange(of: modelContext) { vm.inject(context: modelContext, store: store) }
    }

    private func shouldShowDateDivider(at index: Int) -> Bool {
        guard index < messages.count else { return false }
        let msg = messages[index]
        if index == 0 { return true }
        let prev = messages[index - 1]
        return !Calendar.current.isDate(msg.timestamp, inSameDayAs: prev.timestamp)
    }

    private func insertWelcomeIfNeeded() {
        guard messages.isEmpty else { return }
        // Stamped with the owner. Without this the welcome message is invisible
        // to a signed-in user and gets re-inserted on every launch.
        let w = ChatMessage(role: .assistant, content: L("chat_welcome"),
                            ownerID: AuthService.shared.userId)
        modelContext.insert(w)
        try? modelContext.save()
    }
}

// MARK: — Date divider (uses Formatters for locale-aware output)
struct DateDividerView: View {
    let date: Date
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Text(Formatters.dayDivider(date))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground).opacity(0.8))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .id(localization.current)  // re-render on language change
    }
}

struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundColor(Color.accentColor.opacity(0.4))
            Text(L("chat_empty_title")).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Label(L("example_taxi"), systemImage: "car.fill").foregroundColor(.secondary).font(.subheadline)
                Label(L("example_coffee"), systemImage: "cup.and.saucer.fill").foregroundColor(.secondary).font(.subheadline)
                Label(L("example_salary"), systemImage: "banknote.fill").foregroundColor(.secondary).font(.subheadline)
                Label(L("example_crypto"), systemImage: "bitcoinsign.circle").foregroundColor(.secondary).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity).padding(24)
    }
}

struct MessageBubbleView: View {
    let message: ChatMessage
    var store: AppStore? = nil
    var isUser: Bool { message.role == .user }
    private var avatar: UIImage? { store?.userAvatar }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 50) }
            if !isUser {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 28, height: 28)
                    .overlay(
                        Image("SplashLogo")
                            .resizable().scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                    )
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 4) {
                    if let imgData = message.imageData, let uiImg = UIImage(data: imgData) {
                        Image(uiImage: uiImg)
                            .resizable().scaledToFill()
                            .frame(maxWidth: 200, maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    // User-typed content rendered as plain text (avoids accidental localization
                    // of user input and unintended markdown). Assistant content keeps markdown.
                    if isUser {
                        Text(message.content).font(.system(size: 15))
                    } else {
                        Text(LocalizedStringKey(message.content)).font(.system(size: 15))
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if isUser {
                if let img = avatar {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                } else {
                    Circle().fill(Color(.tertiarySystemFill)).frame(width: 28, height: 28)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 12)).foregroundColor(.secondary))
                }
            }
        }
    }
}

struct TypingIndicatorView: View {
    @State private var animated = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 28, height: 28)
                .overlay(
                    Image("SplashLogo")
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                )
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        .offset(y: animated ? -4 : 0)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: animated)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 50)
        }
        .onAppear { animated = true }
    }
}

// MARK: — Currency Picker
struct CurrencyPickerSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            List {
                ForEach(CurrencyService.supported, id: \.code) { item in
                    Button {
                        store.displayCurrency = item.code
                        store.saveSettings(displayCurrency: item.code)
                        dismiss()
                    } label: {
                        HStack {
                            Text(item.flag).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.code).font(.system(size: 15, weight: .medium))
                                Text(item.name).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if store.displayCurrency == item.code {
                                Image(systemName: "checkmark").foregroundColor(Color.accentColor).fontWeight(.semibold)
                            }
                        }.foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle(L("currency"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } } }
        }
    }
}
