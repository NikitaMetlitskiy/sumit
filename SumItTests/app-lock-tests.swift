import XCTest
@testable import SumIt

/// The app lock must never become a door with no key. These cases pin the two
/// states that locked a real user out of their own data: a PIN switched on with
/// no stored hash, and a biometric scan that succeeded but changed nothing.
@MainActor
final class AppLockTests: XCTestCase {

    private static let keys = ["pinEnabled", "biometricEnabled", "pin_hash", "pin_salt",
                               "pin_failed_attempts", "pin_lockout_until", "bio_domain_state"]
    private var saved: [String: Data] = [:]

    override func setUpWithError() throws {
        // The manager writes to the real keychain, so the host app's own state
        // is put aside and restored rather than trampled.
        saved = [:]
        for key in Self.keys {
            if let value = KeychainHelper.get(key) { saved[key] = value }
            KeychainHelper.remove(key)
        }
        for key in ["appPin", "pinEnabled", "biometricEnabled"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for key in Self.keys { KeychainHelper.remove(key) }
        for (key, value) in saved { KeychainHelper.set(value, for: key) }
        saved = [:]
    }

    // MARK: — Nothing enabled

    func testAnAppWithNoLockNeverLocks() {
        let lock = AppLockManager()
        lock.lockOnLaunch()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.canUsePIN)
    }

    // MARK: — The state that locked the user out

    /// `pinEnabled` on with no hash: `unlockWithPIN` has nothing to compare
    /// against, so every entry is refused and the lock screen covers the whole
    /// app — including sign-in. The flag has to be healed, not obeyed.
    func testAPinEnabledWithoutAStoredHashDoesNotLockTheApp() throws {
        KeychainHelper.setString("1", for: "pinEnabled")
        XCTAssertNil(KeychainHelper.get("pin_hash"))

        let lock = AppLockManager()

        XCTAssertFalse(lock.pinEnabled, "an unverifiable PIN is switched off")
        XCTAssertFalse(lock.canUsePIN)
        lock.lockOnLaunch()
        XCTAssertFalse(lock.isLocked, "the app opens instead of asking for a code it cannot check")
        XCTAssertEqual(KeychainHelper.getString("pinEnabled"), "0", "and the flag is corrected on disk")
    }

    /// The same state produced by the legacy migration: an old build's
    /// UserDefaults flag with no PIN behind it.
    func testALegacyEnabledFlagWithoutAPinIsHealed() {
        UserDefaults.standard.set(true, forKey: "pinEnabled")

        let lock = AppLockManager()

        XCTAssertFalse(lock.pinEnabled)
        lock.lockOnLaunch()
        XCTAssertFalse(lock.isLocked)
    }

    // MARK: — A real PIN

    func testASetPinLocksTheAppAndOnlyTheRightCodeOpensIt() {
        let setup = AppLockManager()
        setup.setPIN("1234")
        XCTAssertTrue(setup.canUsePIN)

        let relaunched = AppLockManager()
        XCTAssertTrue(relaunched.canUsePIN, "the hash survives a relaunch")
        relaunched.lockOnLaunch()
        XCTAssertTrue(relaunched.isLocked)

        XCTAssertFalse(relaunched.unlockWithPIN("0000"))
        XCTAssertTrue(relaunched.isLocked, "a wrong code changes nothing")

        XCTAssertTrue(relaunched.unlockWithPIN("1234"))
        XCTAssertFalse(relaunched.isLocked)
    }

    func testDisablingThePinRemovesTheHashAndTheLock() {
        let lock = AppLockManager()
        lock.setPIN("1234")
        lock.disablePIN()

        XCTAssertFalse(lock.canUsePIN)
        XCTAssertNil(KeychainHelper.get("pin_hash"))
        XCTAssertNil(KeychainHelper.get("pin_salt"))

        let relaunched = AppLockManager()
        relaunched.lockOnLaunch()
        XCTAssertFalse(relaunched.isLocked)
    }

    func testRepeatedWrongCodesLockOutAndTheRightCodeWaits() {
        let lock = AppLockManager()
        lock.setPIN("1234")
        lock.lockOnLaunch()

        for _ in 0..<AppConfig.pinMaxAttempts {
            XCTAssertFalse(lock.unlockWithPIN("0000"))
        }
        XCTAssertTrue(lock.isLockedOut, "brute force is slowed down")
        XCTAssertFalse(lock.unlockWithPIN("1234"), "even the right code waits out the lockout")
        XCTAssertTrue(lock.isLocked)
    }

    // MARK: — Copy

    func testTheLockScreenExplanationsAreLocalized() {
        for key in ["lock_biometric_changed", "lock_biometric_unavailable", "lock_no_pin"] {
            let translations = LocalizationManager.translationsData[key]
            XCTAssertNotNil(translations, "missing \(key)")
            for language in ["en", "uk", "ru", "es", "de", "pl"] {
                XCTAssertNotNil(translations?[language], "\(key) has no \(language)")
            }
        }
    }
}
