import SwiftUI
import SwiftData
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var pendingTransaction: ParsedTransaction? = nil
    @Published var pendingQueue: [ParsedTransaction] = []
    /// Segments the user submitted that did not come back as a transaction.
    /// They keep their original index and text so nothing the user typed can
    /// vanish because one AI call failed.
    @Published var failedSegments: [FailedSegment] = []

    struct FailedSegment: Identifiable, Equatable {
        let id = UUID()
        /// Position in the original submission, 1-based for display.
        let index: Int
        let text: String
    }

    /// True while cards are waiting for the user to confirm or cancel them.
    var hasPendingConfirmations: Bool { pendingTransaction != nil || !pendingQueue.isEmpty }
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

        // Unconfirmed cards are not replaced silently. Clearing them is one
        // deliberate action by the user, not a side effect of typing again.
        guard !hasPendingConfirmations else {
            postAssistant(L("chat_pending_batch_blocked"), ctx: ctx, isSystem: true)
            return
        }

        let skm = StoreKitManager.shared
        if PAYWALL_ENABLED {
            guard skm.hasActiveSubscription else { showSubscriptionRequired(ctx: ctx); return }
            guard skm.canParse else { showLimitReached(ctx: ctx); return }
        }

        // Segmentation runs on the raw submission, before sanitization removes
        // the newlines that carry intent. A limit is a visible error here, never
        // a silent truncation.
        let segments: [String]
        do {
            segments = try TransactionInputSegmenter.split(text)
        } catch let error as SegmentationError {
            postAssistant(message(for: error), ctx: ctx)
            return          // the user's text stays in the field, ready to fix
        } catch {
            postAssistant(L("chat_parse_fail"), ctx: ctx)
            return
        }

        inputText = ""
        failedSegments = []
        isLoading = true
        await Task.yield()

        let userMsg = ChatMessage(role: .user, content: text, ownerID: AuthService.shared.userId)
        ctx.insert(userMsg)
        try? ctx.save()
        pendingUserMessageID = userMsg.id
        triggerScroll()

        if segments.count <= 1 {
            await parseSingle(segments.first ?? text, ctx: ctx)
        } else {
            await parseBatch(segments, ctx: ctx, skm: skm)
        }

        isLoading = false
    }

    /// Parses each segment and reports **every** outcome. A failure keeps its
    /// original index and text; it is never dropped into a smaller,
    /// unexplained "recognized N" count.
    private func parseBatch(_ segments: [String], ctx: ModelContext, skm: StoreKitManager) async {
        var parsed: [ParsedTransaction] = []
        var failures: [FailedSegment] = []

        for (offset, segment) in segments.enumerated() {
            do {
                let result = try await BackendService.shared.parseText(segment, walletNames: getWalletNames(),
                                                                       segmentIndex: offset)
                parsed.append(result)
                skm.incrementParseCount()
            } catch {
                failures.append(FailedSegment(index: offset + 1, text: segment))
            }
        }

        failedSegments = failures

        if !parsed.isEmpty {
            postAssistant(String(format: L("chat_recognized_multi"), parsed.count),
                          ctx: ctx, isSystem: true)
            pendingQueue = Array(parsed.dropFirst())
            pendingTransaction = parsed.first
        }

        if !failures.isEmpty {
            postAssistant(String(format: L("chat_segments_failed"), failures.count),
                          ctx: ctx, isSystem: true)
            for failure in failures {
                postAssistant(String(format: L("chat_segment_failed_item"), failure.index, failure.text),
                              ctx: ctx)
            }
        }

        if parsed.isEmpty && failures.isEmpty {
            postAssistant(L("chat_parse_fail"), ctx: ctx)
        }
        triggerScroll()
    }

    /// Re-sends only the segments that failed. Confirmed cards are untouched.
    func retryFailedSegments() async {
        guard !failedSegments.isEmpty, !isLoading, let ctx = modelContext else { return }
        let retrying = failedSegments.map(\.text)
        failedSegments = []
        isLoading = true
        await Task.yield()
        await parseBatch(retrying, ctx: ctx, skm: StoreKitManager.shared)
        isLoading = false
    }

    /// The one deliberate way to clear unconfirmed work.
    func discardPending() {
        pendingTransaction = nil
        pendingQueue = []
        failedSegments = []
    }

    private func postAssistant(_ content: String, ctx: ModelContext, isSystem: Bool = false) {
        let message = ChatMessage(role: .assistant, content: content, isSystemMessage: isSystem, ownerID: AuthService.shared.userId)
        ctx.insert(message)
        try? ctx.save()
        triggerScroll()
    }

    private func message(for error: SegmentationError) -> String {
        switch error {
        case .empty:
            return L("chat_parse_fail")
        case .tooManySegments(let count):
            return String(format: L("chat_too_many_segments"), count, TransactionInputSegmenter.maxSegments)
        case .segmentTooLong(let index, let length, let limit):
            return String(format: L("chat_segment_too_long"), index + 1, length, limit)
        }
    }

    private func parseSingle(_ text: String, ctx: ModelContext) async {
        do {
            let parsed = try await BackendService.shared.parseText(text, walletNames: getWalletNames())
            pendingTransaction = parsed
            StoreKitManager.shared.incrementParseCount()
            let sysMsg = ChatMessage(role: .assistant, content: L("chat_recognized"), isSystemMessage: true, ownerID: AuthService.shared.userId)
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
            let msg = ChatMessage(role: .assistant, content: content, ownerID: AuthService.shared.userId)
            ctx.insert(msg); try? ctx.save(); triggerScroll()
        }
    }

    // MARK: — Send image (EXIF stripped, downscaled, size-capped)
    func sendImage(_ image: UIImage) async {
        guard let ctx = modelContext else { return }
        guard !isLoading else { return }
        // A photo must not replace unconfirmed cards either.
        guard !hasPendingConfirmations else {
            postAssistant(L("chat_pending_batch_blocked"), ctx: ctx, isSystem: true)
            return
        }

        let skm = StoreKitManager.shared
        if PAYWALL_ENABLED {
            guard skm.hasActiveSubscription else { showSubscriptionRequired(ctx: ctx); return }
            guard skm.canParse else { showLimitReached(ctx: ctx); return }
        }

        failedSegments = []
        isLoading = true
        await Task.yield()

        let thumb = ImageProcessor.thumbnailJPEG(image)
        let userMsg = ChatMessage(role: .user, content: L("chat_photo_receipt"), imageData: thumb, ownerID: AuthService.shared.userId)
        ctx.insert(userMsg)
        pendingUserMessageID = userMsg.id

        let sysMsg = ChatMessage(role: .assistant, content: L("chat_analyzing"), isSystemMessage: true, ownerID: AuthService.shared.userId)
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
                content: L("chat_recognized_receipt"), isSystemMessage: true, ownerID: AuthService.shared.userId)
            ctx.insert(confirmMsg)
            try? ctx.save()
            triggerScroll()
        } catch {
            pendingTransaction = nil
            pendingUserMessageID = nil
            let msg = ChatMessage(role: .assistant, content: L("chat_receipt_fail"), ownerID: AuthService.shared.userId)
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
            // Say which failure it actually was. Reporting a storage error as
            // "unknown currency" sends the user to fix the wrong thing.
            // Say which failure it actually was, using the same code-to-copy
            // mapping every other write path uses.
            let content = store.lastWriteErrorCode == "unsupported_currency"
                ? String(format: L("backend_unknown_currency"), parsed.currency)
                : (LedgerErrorCopy.text(for: store.lastWriteErrorCode) ?? L("chat_save_failed"))
            // The card stays: the user's entry is not lost because a save failed.
            pendingTransaction = parsed
            postAssistant(content, ctx: ctx)
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
            let sysMsg = ChatMessage(role: .assistant, content: L("chat_next_tx"), isSystemMessage: true, ownerID: AuthService.shared.userId)
            ctx.insert(sysMsg); try? ctx.save()
            triggerScroll()
        } else {
            pendingUserMessageID = nil
        }

        isLoading = false
    }

    /// Single source of truth for the "✅ Saved!" assistant bubble text.
    /// The receipt shown after a save.
    ///
    /// Two things changed here. The amount is the **exact** stored string, not
    /// `Formatters.amount(_:fractionDigits: 0)`, which printed €12.50 as "13".
    /// And the last line says what actually happened: the entry is on this
    /// device, and separately whether it is still waiting to reach the server.
    /// Claiming it is synced when only the local write succeeded is the class
    /// of lie this plan exists to remove.
    static func formatSavedReceipt(tx: Transaction, store: AppStore) -> String {
        let sign = tx.type == .income ? "+" : "-"
        let emoji = tx.type == .income ? "💰" : "✅"
        // The booked USD value, if there is one. A receipt is a stored message,
        // so it must not bake in a display-currency conversion at today's rate.
        let booked: String
        if tx.valuationState != .unvalued, let baseText = tx.baseAmountExact,
           let base = try? MoneyCodec.decode(baseText), let shown = try? MoneyCodec.quantize(base, scale: 2) {
            let usd = "≈ " + Formatters.exactAmount(shown, currency: "USD")
            booked = tx.valuationState == .legacyUnverified ? "\(usd) · \(L("valuation_legacy_short"))" : usd
        } else {
            booked = L("receipt_unconverted")
        }
        let walletName = store.walletName(id: tx.walletID)
        let walletSuffix = walletName.isEmpty ? "" : "\n💼 → \(walletName)"
        let merchantDisplay = (tx.merchant.isEmpty || tx.merchant == "Unknown") ? "" : "**\(tx.merchant)** · "
        let amount = tx.amountExact.map { Formatters.exactAmount($0, currency: tx.originalCurrency) }
            ?? Formatters.amount(tx.originalAmount, currency: tx.originalCurrency, fractionDigits: 2)
        let status = store.isAwaitingSync(entityID: tx.id)
            ? "\n\(L("status_saved_on_device")) · \(L("status_waiting_to_sync"))"
            : "\n\(L("status_saved_on_device"))"
        return "\(emoji) \(L("chat_saved"))\n\(merchantDisplay)\(store.displayCategoryName(tx.categoryName))\n\(sign)\(amount) · \(booked)\n📅 \(Formatters.shortDate(tx.occurredAt))\(walletSuffix)\(status)"
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
            let sysMsg = ChatMessage(role: .assistant, content: L("chat_skipped_next"), isSystemMessage: true, ownerID: AuthService.shared.userId)
            ctx.insert(sysMsg); try? ctx.save()
            triggerScroll()
            return
        }

        pendingUserMessageID = nil
        let msg = ChatMessage(role: .assistant, content: L("chat_cancelled"), ownerID: AuthService.shared.userId)
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
        let msg = ChatMessage(role: .assistant, content: L("chat_subscription_required"), ownerID: AuthService.shared.userId)
        ctx.insert(msg)
        try? ctx.save()
        triggerScroll()
    }

    private func showLimitReached(ctx: ModelContext) {
        let tier = StoreKitManager.shared.currentTier
        let msg = ChatMessage(role: .assistant, content: L("chat_limit_reached"), ownerID: AuthService.shared.userId)
        ctx.insert(msg)
        try? ctx.save()
        triggerScroll()
        if tier == .basic { showPaywall = true }
    }
}
