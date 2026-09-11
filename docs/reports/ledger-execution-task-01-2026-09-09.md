# Ledger reliability execution — Task 01 (P8) and the rest of Task 00

**Date:** 2026-09-09. **Baseline:** `202249998fae5e44f19bb420dbf7b3f58c070ef8`. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`.

## Test results

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project SumIt.xcodeproj -scheme SumIt \
  -destination "platform=iOS Simulator,id=74ECEA49-B4BD-4248-B0BA-48AE85D2DADF" \
  -derivedDataPath /tmp/sumit-ledger-derived-data test
```

| Bundle | Result |
|---|---|
| `SumItTests` (unit) | Executed **61** tests, 0 failures |
| `SumItUITests` (UI, simulator) | Executed **2** tests, 0 failures |
| Overall | `** TEST SUCCEEDED **` |

Unit suites: `AmountParserTests` 12, `MoneyValueTests` 14, `TransactionInputSegmenterTests` 11, `StorageBootstrapTests` 17, `BaselineStoreTests` 7.

## Task 00 — completed items

**Added:** `SumItTests/ledger-test-support.swift`, `SumItTests/baseline-store-tests.swift`, `SumItUITests/` target.

- [x] **Isolated file-backed store fixture.** `PersistentStoreFixture` creates its own temporary directory, opens a real on-disk `ModelContainer`, and can `closeAndReopen()`. `destroy()` removes only that directory — a test proves the temporary root survives. File-backed rather than in-memory on purpose: every claim in this plan is about what survives a reopen, and an in-memory container cannot demonstrate that.
- [x] **`StoreSnapshot`** is a sorted, `Codable`, `Equatable` value record — never an array of live model objects. Monetary fields are compared as decimal **text**, so a Double epsilon cannot hide a change. A test deliberately mutates one amount and asserts the snapshot notices.
- [x] **Baseline V1 store** with the exact content the plan lists: a 12.50 USD expense, a 0.001 BTC record, two wallets, a custom category, a linked chat message, an unsynced row and settings. Fixed UUIDs and the fixed event time come from acceptance-tests.md §1.
- [x] **HTTP fault injection.** `StubURLProtocol` + `makeSession()` on an **ephemeral** configuration, so a unit test cannot reach the network or a real credential. It records requests for later assertions.
- [x] **UI test target** `SumItUITests` added and wired into the shared scheme.
- [ ] **Still open:** `LedgerFixtures.*` draft factories. Their types (`TransactionDraft`, `WalletDescriptor`) are defined by Task 04; the fixed data they will use is already pinned in `LedgerIDs`.

## Task 01 — make persistent startup fail safely (P8)

**Added:** `SumIt/Services/storage-bootstrap.swift`, `SumIt/Views/storage-recovery-view.swift`, `SumItTests/storage-bootstrap-tests.swift`, `SumItUITests/ledger-lifecycle-tests.swift`.
**Modified:** `SumIt/SumItApp.swift`, `SumIt/Services/LocalizationManager.swift`.

### What the code did before

```swift
} catch {
    Log.error("SwiftData open failed")
    let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    container = try! ModelContainer(for: schema, configurations: memConfig)
}
```

The comment above it claimed the user would see a recovery screen. No recovery screen existed. The app built its normal `RootView` on a **writable in-memory container**, so the user could add transactions all day and lose every one of them on quit — with a green "saved" reply for each. The fallback also used `try!`.

### What it does now

- `StorageBootstrap` owns the single open attempt and exposes `StorageState` = `opening` / `ready(ModelContainer)` / `failed(StorageFailure)`. There is **no** writable substitute in any path.
- `SumItApp` switches on that state. `RootView` and its `.modelContainer(_:)` are constructed only in the `ready` case; a failure gets `StorageRecoveryView`, which receives no `ModelContext` and offers no way to record a transaction.
- The open attempt is guarded by `isOpening`, so overlapping calls cannot run two migrations against the same files. A test proves a reentrant call inside an in-flight attempt is ignored.
- `StorageFailure` classifies disk-full, permissions, incompatible-schema and unknown, following `NSUnderlyingErrorKey` one level down, and carries a localization key plus a diagnostic of **domain and code only**. A test feeds it an error whose userInfo contains a file path and a merchant name, and asserts neither reaches the diagnostic.
- The store URL is resolved **before** any migration attempt, so a failed open still knows which files to copy.
- `makeRecoveryCopy(into:)` copies the store together with its `-wal` and `-shm` sidecars and returns a SHA-256 and byte count per file. It **refuses to run while a container is open** (`StorageRecoveryError.storeIsOpen`), because copying an open SQLite store with an uncheckpointed write-ahead log yields a copy that is not the data. It never moves, renames or deletes an original, and it only ever runs from an explicit button tap.
- App lock is preserved over the recovery state: `LockScreenView` still sits above it, so a storage failure is not a way past the PIN.
- Nothing that touches data or the network starts before the store is ready: notification scheduling and the `scenePhase` session refresh are both gated on `storage.state.isReady`, and category seeding cannot run because `RootView` does not exist yet.
- Nine recovery strings added to `LocalizationManager` in all six app languages; a test asserts every key has all six.

### UI acceptance

`SumItUITests/ledger-lifecycle-tests.swift` runs the whole P8 path on the simulator: launch with a forced first-open failure → the recovery screen appears **and no tab bar exists** → tap Retry → the app opens → the seeded record is present in Reports **exactly once**, with its original merchant. A second test asserts a healthy launch never shows the recovery surface.

The Debug-only hooks that make this possible (`-SumItUITest`, `-SumItFailStorageOpenOnce`, `-SumItSeedBaseline`) live behind `#if DEBUG` and use a throwaway store in the temporary directory, so a shipping build has no way to be told to fail its own database and a UI test can never touch real user data.

### Bug found and fixed during the UI test

The first UI run could not find the Retry button. The hierarchy dump showed why: an `.accessibilityIdentifier` on the outer container **propagates to every descendant and overwrites theirs** — the buttons and all the labels were reporting `storage-recovery-screen`. The container-level identifier was removed. This was a real defect in the view, not a test artifact: it would have flattened identifiers for any later automation or accessibility tooling.

### Manual confirmation

The recovery screen was also launched by hand through `simctl` with the failure argument and screenshotted: it renders correctly, fully localized (Russian on this simulator), with the sanitized `NSCocoaErrorDomain 257` diagnostic at the foot.

## Checklist status

- [x] Failing tests for forced open error, permission/disk/schema classification, and the absence of `RootView`/financial actions after a failure.
- [x] In-memory fallback removed; failure details sanitized; original files untouched; Retry and a user-directed recovery copy exposed.
- [x] Concrete bootstrap class with an injectable throwing `openContainer` closure; one attempt at a time.
- [x] Store URL resolved before migration; recovery copy handles WAL/SHM and hashes files; never automatic.
- [x] App lock preserved over recovery state; no sync setup, seeding or background write before ready.
- [x] UI test: simulated open failure → recovery screen → Retry succeeds → the original record appears once with its original data.

**Done:** no writable in-memory production fallback, and no tested failure path deletes data.

**Dependency, per the plan:** this is safe startup reviewed on its own. It is not a claim about migration; that stays with Tasks 04 and 18.

## Still not claimed

- The store's real migration behaviour is untested — Task 04 owns it.
- `StorageFailure` classification covers the Cocoa codes SwiftData surfaces today; a code it does not recognise falls to `.unknown`, which still fails safely rather than guessing.
- No behaviour in the chat, editors, sync or reports has changed. P3 and P4 remain open pending the Task 03 integration and Task 14.
