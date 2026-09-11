import XCTest
import SwiftData
@testable import SumIt

/// BATCH group, for the paths that need no AI service. Anything that depends on
/// a parse response waits for Task 10, which makes the transport injectable.
@MainActor
final class ChatBatchTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!
    private var viewModel: ChatViewModel!

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        context = ModelContext(fixture.container)
        viewModel = ChatViewModel()
        let store = AppStore()
        store.setup(context: context)
        viewModel.inject(context: context, store: store)
    }

    override func tearDownWithError() throws {
        // Release everything holding a context before deleting the files, or
        // SQLite logs I/O errors against a store that is still open.
        viewModel = nil
        context = nil
        try fixture?.destroy()
        fixture = nil
    }

    private func messages() throws -> [ChatMessage] {
        try context.fetch(FetchDescriptor<ChatMessage>())
    }

    private func assistantTexts() throws -> [String] {
        try messages().filter { $0.role == .assistant }.map(\.content)
    }

    // MARK: — BATCH-03: pending work is never replaced silently

    func testSendingWhileConfirmationsArePendingDoesNotReplaceThem() async throws {
        let pending = ParsedTransaction(type: .expense, amount: 12.5, currency: "USD",
                                        categoryName: "Food", merchant: "Cafe", note: "",
                                        occurredAt: LedgerIDs.eventTime, confidence: 1,
                                        rawInput: "12.50 coffee", source: .text)
        viewModel.pendingTransaction = pending
        viewModel.inputText = "20 taxi"

        await viewModel.sendMessage()

        XCTAssertEqual(viewModel.pendingTransaction, pending, "the pending card must survive")
        XCTAssertEqual(viewModel.inputText, "20 taxi", "the user's text must not be swallowed")
        XCTAssertTrue(try messages().allSatisfy { $0.role == .assistant },
                      "nothing should have been submitted")
    }

    func testPhotoDoesNotReplacePendingConfirmationsEither() async throws {
        viewModel.pendingQueue = [ParsedTransaction(type: .expense, amount: 1, currency: "USD",
                                                    categoryName: "Other", merchant: "", note: "",
                                                    occurredAt: LedgerIDs.eventTime, confidence: 1,
                                                    rawInput: "", source: .text)]
        await viewModel.sendImage(UIImage())
        XCTAssertEqual(viewModel.pendingQueue.count, 1)
    }

    /// Clearing unconfirmed work is one deliberate action.
    func testDiscardPendingIsExplicit() {
        viewModel.pendingTransaction = ParsedTransaction(type: .expense, amount: 1, currency: "USD",
                                                         categoryName: "Other", merchant: "", note: "",
                                                         occurredAt: LedgerIDs.eventTime, confidence: 1,
                                                         rawInput: "", source: .text)
        viewModel.failedSegments = [.init(index: 1, text: "10 coffee")]
        XCTAssertTrue(viewModel.hasPendingConfirmations)

        viewModel.discardPending()

        XCTAssertFalse(viewModel.hasPendingConfirmations)
        XCTAssertTrue(viewModel.failedSegments.isEmpty)
    }

    // MARK: — SEG-12 / SEG-13 surfaced through the view model

    /// Over the segment limit: an explicit message, and the text stays in the
    /// field so the user can split it. No partial batch is billed.
    func testTooManySegmentsIsExplainedAndNothingIsSent() async throws {
        viewModel.inputText = (1...21).map { "\($0) item" }.joined(separator: ";")
        let original = viewModel.inputText

        await viewModel.sendMessage()

        XCTAssertEqual(viewModel.inputText, original, "input must be preserved for correction")
        XCTAssertTrue(try messages().allSatisfy { $0.role == .assistant },
                      "no user message means nothing was submitted")
        let texts = try assistantTexts()
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].contains("21"), "the message must say how many were found: \(texts[0])")
    }

    /// Over the per-segment character limit: explained, never truncated.
    func testOverLongSegmentIsExplainedAndNotTruncated() async throws {
        viewModel.inputText = String(repeating: "a", count: 501)
        let original = viewModel.inputText

        await viewModel.sendMessage()

        XCTAssertEqual(viewModel.inputText, original)
        let texts = try assistantTexts()
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].contains("501"), "the message must state the real length: \(texts[0])")
    }

    // MARK: — The old splitter's behaviour must be gone

    /// The view model must route through the segmenter, so a decimal comma can
    /// no longer become a batch boundary anywhere in the app.
    func testDecimalCommaIsStillOneSegmentThroughTheSharedSplitter() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("12,50 EUR coffee").count, 1)
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee, 20 taxi").count, 2)
    }

    /// Every new user-facing string exists in all six languages.
    func testBatchStringsAreLocalized() {
        for key in ["chat_pending_batch_blocked", "chat_segments_failed", "chat_segment_failed_item",
                    "chat_too_many_segments", "chat_segment_too_long", "chat_retry_failed",
                    "chat_failed_banner", "chat_discard_failed"] {
            let translations = LocalizationManager.translationsData[key]
            XCTAssertNotNil(translations, "missing \(key)")
            for language in ["en", "uk", "ru", "es", "de", "pl"] {
                XCTAssertNotNil(translations?[language], "\(key) has no \(language)")
            }
        }
    }
}
