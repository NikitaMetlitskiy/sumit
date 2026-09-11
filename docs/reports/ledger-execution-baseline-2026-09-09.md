# Ledger reliability execution — baseline and toolchain record

**Task:** 00. **Date recorded:** 2026-09-09. **Executor:** local Claude Code session on the owner's Mac.

## 1. Repository baseline

| Item | Observed value |
|---|---|
| Clone path | `/Users/joker/Downloads/фин приложение/SumIt` |
| Plan-declared clone path | `/Users/max/General/side/Finhelper/sumit` (a different machine; the paths inside `source-map.md` are not local) |
| Remote | `git@github.com:NikitaMetlitskiy/sumit.git` |
| Branch | `main` |
| `git log -1` | `202249998fae5e44f19bb420dbf7b3f58c070ef8` — "Revert Figma redesign — restore TabView home, original confirmation card" |
| `origin/main` | identical SHA (`git ls-remote origin`) |
| `git status --short` before this task | clean |
| `git diff --cached --name-only` | empty |

HEAD equals the plan's declared baseline. No divergence to reconcile. All changes made by this execution are uncommitted and unstaged.

### 1.1 Source map reconciliation

`source-map.md` line anchors were spot-checked against this clone. All eight sampled anchors resolve to the described symbol:

| Reference | Line content here |
|---|---|
| `SumIt/Services/AppStore.swift:174` | `func restoreFromCloud() async {` |
| `SumIt/Services/AppStore.swift:83` | `func saveConfirmed(parsed: ParsedTransaction, linkedMessageID: UUID? = nil) async -> Transaction? {` |
| `SumIt/Services/AppStore.swift:130` | `private func applyWalletDelta(for tx: Transaction, sign: Double) {` |
| `SumIt/ViewModels/ChatViewModel.swift:107` | `private func splitTransactionInput(_ text: String) -> [String] {` |
| `SumIt/Views/Chat/ConfirmationCard.swift:267` | `let newAmount = Double(amountStr.replacingOccurrences(of: ",", with: ".")) ?? parsed.amount` |
| `SumIt/Views/WalletViews.swift:162` | `balanceStr = String(format: "%.2f", w.balance)` |
| `SumIt/Services/SupabaseService.swift:87` | `func fetchTransactions() async throws -> [RemoteTransaction] {` |
| `SumIt/SumItApp.swift:23` | `init() {` |

The source map is accurate for this clone. Line numbers move as tasks land; re-search by symbol.

## 2. Toolchain — G0 SATISFIED

The active developer directory was pointing at Command Line Tools, which made `xcodebuild`, `simctl`, XCTest and the SwiftData macro plugin all unavailable. **Xcode itself was already installed**; only the selection was wrong. Rather than change a global system setting on the owner's machine (which needs their password), every command in this workstream sets `DEVELOPER_DIR` for its own invocation:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Discovered environment:

| Item | Value |
|---|---|
| Xcode | 26.6, build 17F113, at `/Applications/Xcode.app` |
| `xcode-select -p` (global, unchanged) | `/Library/Developer/CommandLineTools` |
| Simulator SDK | `iphonesimulator26.5` |
| Test destination used | iPhone 17 Pro, iOS 26.5, UDID `74ECEA49-B4BD-4248-B0BA-48AE85D2DADF` |
| Project targets | `SumIt`, and `SumItTests` added by this task |
| Shared scheme | `SumIt` (created by this task, includes the test target) |
| Deployment target | `arm64-apple-ios17.0-simulator` — the iOS 17 minimum is preserved |
| Derived data | `/tmp/sumit-ledger-derived-data` |

### 2.1 Deviation from the plan's stated tech stack

The plan's header says the stack is "Swift 6". It is not. The project builds with:

```
SWIFT_VERSION = 5.0
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
SWIFT_APPROACHABLE_CONCURRENCY = YES
SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES
```

That is Swift 5 language mode with main-actor-by-default isolation and several upcoming features enabled — close to Swift 6 semantics, but not the Swift 6 language mode. Per the plan's own constraint ("do not silently change the app's language mode"), this was left exactly as found, and the new test target was configured to match it. Anything the plan says about Swift 6 concurrency should be read against this actual configuration.

## 3. Baseline build and test harness

- **Pristine baseline build:** `** BUILD SUCCEEDED **` against the untouched working tree, before any source registration. The app compiles as delivered.
- **Test target:** `SumItTests` added to `SumIt.xcodeproj` by hand-editing `project.pbxproj` (objectVersion 77, classic groups — the project does not use file-system-synchronized groups). Product type `com.apple.product-type.bundle.unit-test`, `TEST_HOST`/`BUNDLE_LOADER` pointed at `SumIt.app`, bundle id `com.mykyta.SumIt.tests`, build settings matched to the app target. `@testable import SumIt` works because Debug already builds with `-enable-testing`.
- **Every pbxproj edit was validated** with `plutil -lint` and then by a real build; the pre-edit file is backed up at `/tmp/project.pbxproj.backup` for this session.
- **Shared scheme:** `SumIt.xcodeproj/xcshareddata/xcschemes/SumIt.xcscheme`, with `SumItTests` as a testable reference, so `xcodebuild ... test` works from the command line and the scheme is under version control rather than in `xcuserdata`.

Verified test command:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project SumIt.xcodeproj -scheme SumIt \
  -destination "platform=iOS Simulator,id=74ECEA49-B4BD-4248-B0BA-48AE85D2DADF" \
  -derivedDataPath /tmp/sumit-ledger-derived-data test
```

Result on 2026-09-09: `Executed 37 tests, with 0 failures (0 unexpected)` — `** TEST SUCCEEDED **`.

### 3.1 Incidental P8 evidence

While the test host launched, its log carried repeated `CoreData: error: Failed to stat path ... default.store` and `Sandbox access to file-write-create denied` lines, and the app continued running regardless. This is exactly the P8 shape: a persistent-store open failure that does not stop the app. It is anecdotal here (a test-host sandbox, not a user device) and is **not** counted as a P8 acceptance case; Task 01 must reproduce it deliberately with injected failures.

## 4. Task 00 checklist status

- [x] `git status --short`, `git diff`, `git diff --cached --name-only`, `git log -1` run; baseline matches the plan; audit and plan documentation preserved untracked.
- [x] `xcodebuild -version`, `xcodebuild -list -project SumIt.xcodeproj`, `xcrun simctl list devices available` run; real Xcode, scheme, OS and simulator UUID recorded above. The developer directory is selected per-invocation via `DEVELOPER_DIR`; the machine's global `xcode-select` setting was deliberately left untouched.
- [x] Unit test target and shared scheme added in the project's native format. Existing app verified to build **before** the changes. Language mode and minimum OS unchanged.
- [ ] **Open:** test support with an isolated file-backed `ModelContainer` (create, close, reopen, delete only its own temporary directory) and URLProtocol fault injection on an ephemeral `URLSession`. Not needed by Tasks 02/03, which are pure; required before Task 01 and everything downstream.
- [ ] **Open:** fixture factories `LedgerFixtures.*`. Their draft types land in Task 04.
- [ ] **Open:** baseline V1 persistent store with the 12.50 expense, 0.001 BTC record, two wallets, custom category, linked message, unsynced row and settings, plus its JSON expectation file and a second copy for migration tests.
- [x] Source-derived regressions added before their fixes, for the tasks executed so far (02 and 03). Their results are real, not inferred.

Task 00 is **partially complete**: the toolchain, project harness and test entry point are established and proven; the persistent-store fixture work remains and is the immediate prerequisite for Task 01.

## 5. Notes for the next executor

- Always export `DEVELOPER_DIR` before `xcodebuild`/`xcrun`; the machine's global selection still points at Command Line Tools.
- Without it, `swift`/`swiftc` still work for pure Foundation code, but SwiftData macros, XCTest and simulators do not.
- The UI test target (`SumItUITests`) from the plan's Task 00 file list has **not** been created yet; add it when Task 01 needs its recovery-screen test.
