import XCTest
import SwiftData
@testable import SumIt

/// ACC group. One device, two accounts: nothing belonging to one may be visible
/// or sendable under the other.
@MainActor
final class AccountScopeTests: XCTestCase {

    private var fixture: PersistentStoreFixture!
    private var context: ModelContext!

    private let ownerA = LedgerIDs.ownerA
    private let ownerB = LedgerIDs.ownerB

    override func setUpWithError() throws {
        fixture = try PersistentStoreFixture()
        context = ModelContext(fixture.container)
    }

    override func tearDownWithError() throws {
        context = nil
        try fixture?.destroy()
        fixture = nil
    }

    // MARK: — Visibility

    /// Account A signs out keeping its data, account B signs in. None of A's
    /// transactions may appear.
    func testTransactionsOfAnotherAccountAreNotVisible() {
        let mine = Transaction(userId: ownerA, originalAmount: 12.5, originalCurrency: "USD",
                               amountInBase: 12.5, rateAtTime: 1, categoryName: "Food", merchant: "Cafe")
        let theirs = Transaction(userId: ownerB, originalAmount: 99, originalCurrency: "USD",
                                 amountInBase: 99, rateAtTime: 1, categoryName: "Food", merchant: "Theirs")
        let all = [mine, theirs]

        XCTAssertEqual(LedgerScope.activeTransactions(all, ownerID: ownerA).map(\.merchant), ["Cafe"])
        XCTAssertEqual(LedgerScope.activeTransactions(all, ownerID: ownerB).map(\.merchant), ["Theirs"])
        XCTAssertTrue(LedgerScope.activeTransactions(all, ownerID: AccountScope.localOwnerID).isEmpty)
    }

    func testDeletedRowsAreHiddenButRetained() {
        let live = Transaction(userId: ownerA, originalAmount: 1, originalCurrency: "USD",
                               amountInBase: 1, rateAtTime: 1, categoryName: "Food", merchant: "Live")
        let gone = Transaction(userId: ownerA, originalAmount: 2, originalCurrency: "USD",
                               amountInBase: 2, rateAtTime: 1, categoryName: "Food", merchant: "Gone")
        gone.deletedAt = LedgerIDs.testClock

        let visible = LedgerScope.activeTransactions([live, gone], ownerID: ownerA)
        XCTAssertEqual(visible.map(\.merchant), ["Live"])
        XCTAssertNotNil(gone.deletedAt, "the tombstone is retained so the deletion can travel")
    }

    func testWalletsAreScopedAndArchivedOnesHidden() {
        let mine = Wallet(userId: ownerA, name: "Mine")
        let theirs = Wallet(userId: ownerB, name: "Theirs")
        let archived = Wallet(userId: ownerA, name: "Old")
        archived.deletedAt = LedgerIDs.testClock

        XCTAssertEqual(LedgerScope.activeWallets([mine, theirs, archived], ownerID: ownerA).map(\.name),
                       ["Mine"])
    }

    /// Bundled defaults are shared templates; a custom category belongs to one account.
    func testDefaultCategoriesAreSharedAndCustomOnesAreNot() {
        let bundled = SumIt.Category(name: "Food", icon: "fork.knife", colorHex: "FF6B6B", isDefault: true)
        let mine = SumIt.Category(name: "Coffee", icon: "cup", colorHex: "8B5E3C", ownerID: ownerA)
        let theirs = SumIt.Category(name: "Boats", icon: "ferry", colorHex: "112233", ownerID: ownerB)

        let forA = LedgerScope.activeCategories([bundled, mine, theirs], ownerID: ownerA).map(\.name)
        XCTAssertEqual(Set(forA), ["Food", "Coffee"])

        let forB = LedgerScope.activeCategories([bundled, mine, theirs], ownerID: ownerB).map(\.name)
        XCTAssertEqual(Set(forB), ["Food", "Boats"])
    }

    /// Chat does not cross accounts, and pre-account chat stays with the
    /// signed-out device dataset rather than joining whoever signs in.
    func testChatIsScopedAndLegacyMessagesStayLocal() {
        let mine = ChatMessage(role: .user, content: "mine", ownerID: ownerA)
        let theirs = ChatMessage(role: .user, content: "theirs", ownerID: ownerB)
        let legacy = ChatMessage(role: .user, content: "before accounts")
        let all = [mine, theirs, legacy]

        XCTAssertEqual(LedgerScope.visibleMessages(all, ownerID: ownerA).map(\.content), ["mine"])
        XCTAssertEqual(LedgerScope.visibleMessages(all, ownerID: ownerB).map(\.content), ["theirs"])
        XCTAssertEqual(LedgerScope.visibleMessages(all, ownerID: AccountScope.localOwnerID).map(\.content),
                       ["before accounts"])
    }

    // MARK: — Writing

    /// A write naming another account's wallet is out of scope, whatever the
    /// row's own owner says.
    func testStoreRefusesAWriteReferencingAnotherAccountsWallet() throws {
        let store = LedgerStore(context: context)
        let scopeA = AccountScope(ownerID: ownerA, epoch: UUID())

        let foreign = Wallet(id: LedgerIDs.walletB, userId: ownerB, name: "Theirs",
                             type: .bank, currency: "USD", balance: 0)
        context.insert(foreign)
        try context.save()

        let draft = TransactionDraft(id: LedgerIDs.expense, type: .expense,
                                     amount: try MoneyCodec.decode("12.5"), currency: "USD",
                                     walletID: LedgerIDs.walletB,
                                     walletAmount: try MoneyCodec.decode("12.5"),
                                     destinationWalletID: nil, destinationAmount: nil,
                                     categoryName: "Food", merchant: "Cafe", note: "",
                                     occurredAt: LedgerIDs.eventTime, source: .manual,
                                     confidence: 1, rawInput: "",
                                     valuation: .quoted(.identity(at: LedgerIDs.eventTime)))

        XCTAssertThrowsError(try store.saveTransaction(draft, scope: scopeA)) { error in
            XCTAssertEqual(error as? LedgerWriteError, .wrongScope)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 0)
    }

    /// Rows recorded before signing in keep the `local` owner. Account A's
    /// queue must not pick them up.
    func testSignedOutRowsAreNotQueuedUnderAnAccount() throws {
        let store = LedgerStore(context: context)
        let localScope = AccountScope(ownerID: AccountScope.localOwnerID, epoch: UUID())
        try store.saveWallet(WalletDraft(id: LedgerIDs.walletA, name: "Cash", type: .cash,
                                         currency: "USD", openingBalance: 0, icon: ""),
                             scope: localScope)

        let queued = try context.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.ownerID, AccountScope.localOwnerID,
                       "the operation stays with the device dataset")
        XCTAssertTrue(LedgerScope.activeWallets(try context.fetch(FetchDescriptor<Wallet>()),
                                                ownerID: ownerA).isEmpty)
    }

    // MARK: — Epoch

    /// The epoch is what scoped views key on, and what an in-flight request
    /// compares itself against.
    func testEpochChangesOnSignOutAndScopeFollowsIt() {
        let auth = AuthService.shared
        let before = auth.scopeEpoch

        auth.signOut()

        XCTAssertNotEqual(auth.scopeEpoch, before, "signing out must invalidate every scoped view")
        XCTAssertEqual(auth.userId, AccountScope.localOwnerID)
        XCTAssertEqual(auth.currentScope.ownerID, AccountScope.localOwnerID)
        XCTAssertEqual(auth.currentScope.epoch, auth.scopeEpoch)
        XCTAssertTrue(auth.currentScope.isLocalOnly)
    }

    func testLocalScopeIsRecognisedAsDeviceOnly() {
        XCTAssertTrue(AccountScope(ownerID: AccountScope.localOwnerID, epoch: UUID()).isLocalOnly)
        XCTAssertFalse(AccountScope(ownerID: ownerA, epoch: UUID()).isLocalOnly)
    }

    // MARK: — Signing in does not adopt device data

    /// The behaviour this replaces rewrote every `local` row to the new owner
    /// and uploaded it. Now the rows stay put and an issue records that they
    /// are waiting for an explicit import.
    func testSigningInLeavesDeviceRowsAloneAndRecordsAnIssue() throws {
        let store = AppStore()
        store.setup(context: context)

        let local = Transaction(userId: AccountScope.localOwnerID, originalAmount: 5,
                                originalCurrency: "USD", amountInBase: 5, rateAtTime: 1,
                                categoryName: "Food", merchant: "Before sign-in")
        context.insert(local)
        try context.save()

        store.recordLocalDataAwaitingImport(ownerID: ownerA)

        XCTAssertEqual(local.userId, AccountScope.localOwnerID, "the owner was not rewritten")
        let issues = try context.fetch(FetchDescriptor<SyncIssue>())
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .legacyAmbiguity)
        XCTAssertEqual(issues.first?.reason, "local_data_awaiting_import")
        XCTAssertEqual(issues.first?.ownerID, ownerA)

        // Calling again must not pile up duplicates.
        store.recordLocalDataAwaitingImport(ownerID: ownerA)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncIssue>()), 1)
    }

    func testNoIssueIsRecordedWhenThereIsNoDeviceData() throws {
        let store = AppStore()
        store.setup(context: context)
        store.recordLocalDataAwaitingImport(ownerID: ownerA)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncIssue>()), 0)
    }

    // MARK: — A late answer for the previous account

    /// The case the plan names explicitly: account A's token refresh is still in
    /// flight when A signs out. When its answer finally arrives it must be
    /// discarded, not used to sign A back in over whoever is active now.
    func testARefreshAnsweredAfterSignOutDoesNotRestoreTheOldAccount() async throws {
        let auth = AuthService.shared
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        defer {
            StubURLProtocol.reset()
            URLProtocol.unregisterClass(StubURLProtocol.self)
            auth.signOut()
        }

        // The response is held until the test has signed out, which is exactly
        // the ordering the guard exists for.
        // Only the refresh is held. `signOut()` fires its own logout request on
        // the same shared session; blocking that one too would strand a loader
        // thread on a semaphore nothing signals again.
        let release = DispatchSemaphore(value: 0)
        StubURLProtocol.handler = { request in
            guard request.url?.absoluteString.contains("grant_type=refresh_token") == true else {
                return StubURLProtocol.Response()
            }
            release.wait()
            let body = """
            {"access_token":"fresh","refresh_token":"fresh-r","expires_in":3600,
             "user":{"id":"\(LedgerIDs.ownerA)"}}
            """
            return StubURLProtocol.Response(body: Data(body.utf8))
        }

        auth.installSessionForTesting(userId: ownerA, expiresAt: Date.now.addingTimeInterval(-10))
        XCTAssertEqual(auth.userId, ownerA)
        let epochAsA = auth.scopeEpoch

        async let refreshed = auth.refreshSessionIfNeeded()

        // Wait for the request to be in flight, then change the account under it.
        var waited = 0
        while !StubURLProtocol.requests().contains(where: {
            $0.url?.absoluteString.contains("grant_type=refresh_token") == true
        }) && waited < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertLessThan(waited, 200, "the refresh never reached the network")

        auth.signOut()
        XCTAssertNotEqual(auth.scopeEpoch, epochAsA)

        release.signal()
        let result = await refreshed

        XCTAssertFalse(result, "a refresh for a previous account does not report success")
        XCTAssertEqual(auth.userId, AccountScope.localOwnerID, "A was not signed back in")
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertEqual(auth.currentScope.ownerID, AccountScope.localOwnerID)
    }
}
