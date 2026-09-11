import XCTest

/// Task 01 / P8 acceptance: a store that fails to open must produce a recovery
/// screen instead of a working-looking app, and Retry must bring the real data
/// back exactly once.
final class LedgerLifecycleTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SumItUITest"] + arguments
        app.launch()
        return app
    }

    /// The whole P8 path in one run: failure → recovery surface → Retry →
    /// the seeded record is present, once, with its original merchant.
    func testStorageFailureShowsRecoveryAndRetryRestoresData() {
        let app = launch(["-SumItFailStorageOpenOnce", "-SumItSeedBaseline"])

        let retry = app.buttons["storage-recovery-retry"]
        if !retry.waitForExistence(timeout: 20) {
            XCTFail("a failed store open must show the recovery screen. Hierarchy:\n\(app.debugDescription)")
        }

        // No financial UI exists while storage is unavailable.
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "the tab bar must not be built on a failed store")

        retry.tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "Retry must open the app")
        XCTAssertFalse(app.buttons["storage-recovery-retry"].exists)

        // Reports tab: the seeded expense appears exactly once.
        tabBar.buttons.element(boundBy: 1).tap()
        let merchant = app.staticTexts["Cafe"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 10), "the seeded record must be reachable")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Cafe").count, 1,
                       "the record must appear once, not duplicated by the retry")
    }

    /// A healthy launch must never show the recovery surface.
    func testHealthyLaunchShowsTheApp() {
        let app = launch(["-SumItSeedBaseline"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["storage-recovery-retry"].exists)
    }
}
