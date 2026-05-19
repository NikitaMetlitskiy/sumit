import SwiftUI
import SwiftData
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var pendingTransaction: ParsedTransaction? = nil
    @Published var pendingQueue: [ParsedTransaction] = []
    @Published var showImagePicker: Bool = false
    @Published var imagePickerSource: UIImagePickerController.SourceType = .photoLibrary
    @Published var scrollToBottom: UUID = UUID()
    @Published var showScrollButton: Bool = false
    @Published var showPaywall: Bool = false

    private var modelContext: ModelContext?
    private var store: AppStore?
    private var pendingUserMessageID: UUID? = nil

    func inject(context: ModelContext, store: AppStore) {
        self.modelContext = context
        self.store = store
    }

    // MARK: — Send text message
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isLoading else { return }
        guard let ctx = modelContext else { return }

        let skm = StoreKitManager.shared
        if PAYWALL_ENABLED {
            guard skm.hasActiveSubscription else { showSubscriptionRequired(ctx: ctx); return }
            guard skm.canParse else { showLimitReached(ctx: ctx); return }
        }

        inputText = ""
        pendingTransaction = nil
        pendingQueue = []
        isLoading = true
        await Task.yield()

        let userMsg = ChatMessage(role: .user, content: text)
        ctx.insert(userMsg)
        try? ctx.save()
        pendingUserMessageID = userMsg.id
        triggerScroll()

        let parts = splitTransactionInput(text)

        if parts.count <= 1 {
            await parseSingle(text, ctx: ctx)
        } else {
            var parsed: [ParsedTransaction] = []
            for part in parts {
                do {
                    let p = try await BackendService.shared.parseText(part, walletNames: getWalletNames())
                    parsed.append(p)
                    skm.incrementParseCount()
                } catch {
                    Log.warn("Could not parse part")
                }
            }

            if parsed.isEmpty {
                let msg = ChatMessage(role: .assistant, content: L("chat_parse_fail"))
                ctx.insert(msg); try? ctx.save(); triggerScroll()
            } else {
                let sysMsg = ChatMessage(role: .assistant,
                    content: String(format: L("chat_recognized_multi"), parsed.count),
                    isSystemMessage: true)
                ctx.insert(sysMsg); try? ctx.save()
                pendingQueue = Array(parsed.dropFirst())
                pendingTransaction = parsed.first
                triggerScroll()
            }
        }

        isLoading = false
    }

    private func parseSingle(_ text: String, ctx: ModelContext) async {
        do {
            let parsed = try await BackendService.shared.parseText(text, walletNames: getWalletNames())
            pendingTransaction = parsed
            StoreKitManager.shared.incrementParseCount()
            let sysMsg = ChatMessage(role: .assistant, content: L("chat_recognized"), isSystemMessage: true)
            ctx.insert(sysMsg); try? ctx.save(); triggerScroll()
        } catch {
            pendingTransaction = nil; pendingUserMessageID = nil
            let content: String
            if case BackendError.parseFailed = error {
                content = L("chat_im_assistant")
            } else if case BackendError.noAmount = error {
                content = L("chat_im_assistant")
            } else {
                content = error.localizedDescription
            }
            let msg = ChatMessage(role: .assistant, content: content)
            ctx.insert(msg); try? ctx.save(); triggerScroll()
        }
    }

    /// Split multi-transaction input. Conservative: only splits if every chunk
    /// contains a digit AND we get at least two such chunks. Keeps natural phrases intact.
    private func splitTransactionInput(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: " + ", with: ",")
            .replacingOccurrences(of: ";", with: ",")
        // Split on commas only — " и "/" and " is too dangerous (breaks merchant names).
        let parts = normalized.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return [text] }
        let withNumbers = parts.filter {
            regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        return withNumbers.count >= 2 ? withNumbers : [text]
    }

    // MARK: — Send image (EXIF stripped, downscaled, size-capped)
    func sendImage(_ image: UIImage) async {
        guard let ctx = modelContext else { return }

        let skm = StoreKitManager.shared
        if PAYWALL_ENABLED {
            guard skm.hasActiveSubscription else { showSubscriptionRequired(ctx: ctx); return }
            guard skm.canParse else { showLimitReached(ctx: ctx); return }
        }

        pendingTransaction = nil
        isLoading = true
        await Task.yield()

        let thumb = ImageProcessor.thumbnailJPEG(image)
        let userMsg = ChatMessage(role: .user, content: L("chat_photo_receipt"), imageData: thumb)
        ctx.insert(userMsg)
        pendingUserMessageID = userMsg.id

        let sysMsg = ChatMessage(role: .assistant, content: L("chat_analyzing"), isSystemMessage: true)
        ctx.insert(sysMsg)
        try? ctx.save()
        triggerScroll()

        do {
            guard let cleanData = ImageProcessor.sanitizedJPEG(image),
                  cleanData.count <= AppConfig.maxImageUploadBytes else {
                throw BackendError.imageTooLarge
            }
            let b64 = "data:image/jpeg;base64,\(cleanData.base64EncodedString())"
            let parsed = try await BackendService.shared.parseImage(dataURL: b64)
            pendingTransaction = parsed
            skm.incrementParseCount()

            let confirmMsg = ChatMessage(role: .assistant,
                content: L("chat_recognized_receipt"), isSystemMessage: true)
            ctx.insert(confirmMsg)
            try? ctx.save()
            triggerScroll()
        } catch {
            pendingTransaction = nil
            pendingUserMessageID = nil
            let msg = ChatMessage(role: .assistant, content: L("chat_receipt_fail"))
            ctx.insert(msg)
            try? ctx.save()
            triggerScroll()
        }

        isLoading = false
    }

    // MARK: — Confirm
    func confirmTransaction(_ parsed: ParsedTransaction, allMessages: [ChatMessage]) async {
        guard let store, let ctx = modelContext else { return }

        isLoading = true
        cleanupSystemMessages(ctx: ctx, allMessages: allMessages)
        pendingTransaction = nil
        await Task.yield()

        guard let tx = await store.saveConfirmed(parsed: parsed, linkedMessageID: pendingUserMessageID) else {
            // Unsupported currency or save failed — show error
            let msg = ChatMessage(role: .assistant, content: String(format: L("backend_unknown_currency"), parsed.currency))
            ctx.insert(msg); try? ctx.save(); triggerScroll()
            isLoading = false
            return
        }

        let reply = ChatMessage(
            role: .assistant,
            content: formatSavedReceipt(tx: tx, store: store),
            linkedTransactionID: tx.id
        )
        ctx.insert(reply)
        try? ctx.save()
        triggerScroll()

        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            pendingTransaction = next
            let sysMsg = ChatMessage(role: .assistant, content: L("chat_next_tx"), isSystemMessage: true)
            ctx.insert(sysMsg); try? ctx.save()
            triggerScroll()
        } else {
            pendingUserMessageID = nil
        }

        isLoading = false
    }

    /// Single source of truth for the "✅ Saved!" assistant bubble text.
    static func formatSavedReceipt(tx: Transaction, store: AppStore) -> String {
        let sign = tx.type == .income ? "+" : "-"
        let emoji = tx.type == .income ? "💰" : "✅"
        let display = store.display(amountUSD: tx.amountInBase)
        let walletSuffix = tx.walletName.isEmpty ? "" : "\n💼 → \(tx.walletName)"
        let merchantDisplay = (tx.merchant.isEmpty || tx.merchant == "Unknown") ? "" : "**\(tx.merchant)** · "
        let amount = Formatters.amount(tx.originalAmount, currency: tx.originalCurrency, fractionDigits: 0)
        return "\(emoji) \(L("chat_saved"))\n\(merchantDisplay)\(store.displayCategoryName(tx.categoryName))\n\(sign)\(amount) ≈ \(display)\n📅 \(Formatters.shortDate(tx.occurredAt))\(walletSuffix)"
    }

    private func formatSavedReceipt(tx: Transaction, store: AppStore) -> String {
        Self.formatSavedReceipt(tx: tx, store: store)
    }

    // MARK: — Cancel
    func cancelTransaction(allMessages: [ChatMessage]) {
        guard let ctx = modelContext else { return }
        cleanupSystemMessages(ctx: ctx, allMessages: allMessages)
        pendingTransaction = nil

        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            pendingTransaction = next
            let sysMsg = ChatMessage(role: .assistant, content: L("chat_skipped_next"), isSystemMessage: true)
            ctx.insert(sysMsg); try? ctx.save()
            triggerScroll()
            return
        }

        pendingUserMessageID = nil
        let msg = ChatMessage(role: .assistant, content: L("chat_cancelled"))
        ctx.insert(msg)
        try? ctx.save()
        triggerScroll()
    }

    // MARK: — Delete (caller handles confirmation dialog before invoking)
    func deleteMessage(_ message: ChatMessage, allMessages: [ChatMessage], allTx: [Transaction], deleteLinkedTx: Bool = true) {
        guard let ctx = modelContext, let store else { return }

        if deleteLinkedTx,
           let txID = message.linkedTransactionID,
           let tx = allTx.first(where: { $0.id == txID }) {
            store.deleteTransaction(tx, messages: allMessages)
        } else {
            ctx.delete(message)
            try? ctx.save()
        }
    }

    // MARK: — Private helpers
    private func cleanupSystemMessages(ctx: ModelContext, allMessages: [ChatMessage]) {
        let desc = FetchDescriptor<ChatMessage>()
        let all = (try? ctx.fetch(desc)) ?? allMessages
        let sysMsgs = all.filter { $0.isSystemMessage }
        sysMsgs.forEach { ctx.delete($0) }
        try? ctx.save()
    }

    private func triggerScroll() { scrollToBottom = UUID() }

    private func getWalletNames() -> [String] {
        guard let ctx = modelContext else { return [] }
        return (try? ctx.fetch(FetchDescriptor<Wallet>()))?.map { $0.name } ?? []
    }

    // MARK: — Subscription gating
    private func showSubscriptionRequired(ctx: ModelContext) {
        showPaywall = true
        let msg = ChatMessage(role: .assistant, content: L("chat_subscription_required"))
        ctx.insert(msg)
        try? ctx.save()
        triggerScroll()
    }

    private func showLimitReached(ctx: ModelContext) {
        let tier = StoreKitManager.shared.currentTier
        let msg = ChatMessage(role: .assistant, content: L("chat_limit_reached"))
        ctx.insert(msg)
        try? ctx.save()
        triggerScroll()
        if tier == .basic { showPaywall = true }
    }
}
