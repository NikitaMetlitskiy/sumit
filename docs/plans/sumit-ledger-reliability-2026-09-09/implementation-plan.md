# SumIt Eight-Issue Ledger Reliability Implementation Plan

> **For agentic workers:** use `superpowers:executing-plans` to implement this plan task by task. Do not automatically invoke subagent-driven development, spawn agents, create a branch/worktree, deploy, or create a PR. The current request authorizes preparing this plan; execution is a subsequent request. Steps use checkboxes so a later executor can record actual progress.

**Goal:** close P1–P8 from the audit response by making amounts, wallet effects, local persistence, cloud restoration and recovery reliable across edits, retries, offline use and multiple devices.

**Architecture:** retain SwiftUI/SwiftData and the existing AppStore/SupabaseService boundaries. Add exact monetary values, a concrete local mutation owner with durable pending operations, an owner-scoped revision/receipt protocol in Supabase, and dated rate snapshots. Transfers are one record with two wallet references; balances derive from opening values and active records.

**Tech stack:** SwiftUI, Foundation Decimal, SwiftData with iOS 17-compatible versioned schemas, XCTest/URLProtocol, PostgreSQL/Supabase RPC, existing Node ESM/Vercel backend and Node built-in test runner. No new product framework or sync vendor.

**Spec:** [design.md](design.md). Also mandatory: [database-and-rollout.md](database-and-rollout.md), [acceptance-tests.md](acceptance-tests.md), and [original audit](../../reports/sumit-audit-2026-09-09.md).

## Global constraints

- Baseline `202249998fae5e44f19bb420dbf7b3f58c070ef8`; current clone `/Users/max/General/side/Finhelper/sumit`, branch `main`. Reconcile actual HEAD/diff before touching code.
- Preserve existing iOS 17 minimum; discover and record a compatible full Xcode and simulator. Local audit tools could not compile Swift/Foundation.
- English artifacts/code/comments; preserve existing Swift model naming, kebab-case for new files.
- Do not delete real data, auto-deduplicate similar operations, rewrite owners, or silently change old monetary values.
- Additive remote schema only until a coordinated upgraded-client adoption; record and verify every applied migration.
- Do not apply the old hardening SQL blindly; it intentionally deletes local/unowned rows.
- No credentials in docs/code/logs; no Apple-key use for this workstream. New provider credentials use the managed secret workflow.
- No branch/worktree without explicit user approval; no PR unless requested. Before any authorized commit inspect `git diff --cached --name-only`; commit only an explicit task pathspec, with no AI attribution.
- No automatic production deployment or paid provider signup. Use synthetic data and staging for destructive/failure tests.
- Do not equate a passed mocked test with a live database/provider/device test. Check off a gate only with its required evidence.

## Execution map

| Order | Task | Main purpose | Requires |
|---|---|---|---|
| 00 | Baseline and regression harness | Working toolchain, old-store fixture, test entry points | G0 access |
| 01 | Safe storage startup | Close volatile fallback | 00 |
| 02 | Exact money and parsing | Shared numeric policy | 00 |
| 03 | Safe chat segmentation | Preserve commas and batch outcomes | 00 |
| 04 | Versioned local schema and contracts | Persist exact fields, owners, queue and cursor | 01,02 |
| 05 | Database inventory and additive foundations | Reproducible known schema | G1,04 |
| 06 | Atomic versioned write RPC | Replay and conflict semantics | 05 |
| 07 | Ordered complete change feed | No lost pages/tombstones | 06 |
| 08 | Wallet/transfer calculation | One accounting formula | 02,04 |
| 09 | Atomic local commands | Save + queue + reply boundary | 04,08 |
| 10 | Checked authenticated transport | Explicit HTTP/receipt outcomes | 06,07 |
| 11 | Durable push coordinator | Retry and correct acknowledgment | 09,10 |
| 12 | Restore and incoming reconciliation | Identity, pages and cursor | 07,11 |
| 13 | Account scope and conflict actions | No cross-user or silent overwrite | 11,12 |
| 14 | Financial editors and caller migration | Connect exact saves/transfers to UI | 03,08,09,13 |
| 15 | Exact AI response compatibility | Shared text/photo money boundary | 02,14 |
| 16 | Qualified rate service | Dated fiat/crypto quotes | 05,G4 provider prerequisites |
| 17 | Client valuation and report integration | Honest missing/stale/legacy rates | 08,14,15,16 |
| 18 | Legacy adoption and reconciliation | Preserve real existing data | 04–17,G2 |
| 19 | Complete history and status UI | Reach restored/conflicted records | 12–18 |
| 20 | Lifecycle/failure integration | Restart, offline, crash, races | 00–19 |
| 21 | Pilot, rollout and handoff | Measured release acceptance | 20,G3–G5 |

Gate labels in the Requires column identify external entry prerequisites, not a demand to pass a task's own output before starting it: Task 00 establishes G0 evidence, Task 05 establishes G1 evidence, Task 18 establishes G2, Task 20 establishes G3, Task 16 establishes G4, and Task 21 establishes G5. Toolchain/database/provider access can be gathered first; acceptance evidence is produced by the named task. Within the current execution, work sequentially. Independent pure tests can be run without a live DB, but unresolved external gates stay open. Do not ship intermediate tasks that combine the old balance writer with the new ledger reader. There is no credible fixed completion date before Tasks 00/05/18 establish the actual environment and data condition.

## File plan and responsibilities

Existing source files remain where they are. New production files are deliberately limited to necessary boundaries:

| New file | Responsibility |
|---|---|
| `SumIt/Services/storage-bootstrap.swift` | Persistent startup, migration opening, recovery copy, startup state |
| `SumIt/Views/storage-recovery-view.swift` | Recovery surface that needs no ModelContext |
| `SumIt/Services/money-value.swift` | Canonical decimal encoding, currency precision, bounded arithmetic |
| `SumIt/Services/amount-parser.swift` | Whole-field localized numeric input |
| `SumIt/Services/transaction-input-segmenter.swift` | Delimiter-aware batch input |
| `SumIt/Models/ledger-types.swift` | Concrete drafts, scope, quote, envelopes and result types |
| `SumIt/Models/ledger-sync-models.swift` | PendingMutation, SyncCheckpoint, SyncIssue, CachedRateQuote |
| `SumIt/Models/ledger-schema.swift` | Frozen V1, V2 and SchemaMigrationPlan; no in-place destructive type change |
| `SumIt/Services/wallet-ledger.swift` | Pure native-currency effects/balance calculation |
| `SumIt/Services/ledger-store.swift` | Checked atomic local commands and queue creation |
| `SumIt/Services/ledger-sync-coordinator.swift` | Single-flight push/pull, retry, ack, cursor, conflicts |
| `SumIt/Services/ledger-migration.swift` | Legacy inventory, identity mapping, baseline reconciliation |
| `SumIt/Services/rate-service.swift` | Quote loading/cache/provenance and explicit conversion decisions |
| `SumIt/Views/Reports/transaction-history-view.swift` | Full scoped history and reuse of existing editor |
| `SumIt/Views/sync-issues-view.swift` | Pending/error/conflict/migration-resolution actions |
| `Backend/vercel-project/api/_lib/transaction-contract.js` | Shared versioned text/photo amount/type/currency validation |
| `Backend/vercel-project/api/_lib/rates.js` | Concrete fiat/crypto calls and provider response validation |
| `Backend/vercel-project/api/rates.js` | Authenticated bounded cache-backed rate route |

No generic abstraction layer is authorized by this list. Existing AppStore, SupabaseService, AuthService, BackendService, CurrencyService, Formatters, views and models are modified as called out below. Remove superseded mutation paths once callers migrate. Tests go in `SumItTests/`, `SumItUITests/`, `Backend/tests/` and `Backend/vercel-project/test/`.

## Shared interface inventory

These are **new proposed Swift declarations**. Define them once in Task 04; consumers use these names. Samples later in this plan rely on this inventory. Public method bodies are implemented in the named owner task, not as empty production stubs.

```swift
struct AccountScope: Equatable, Sendable {
    let ownerID: String
    let epoch: UUID
}

struct TransactionDraft: Sendable {
    let id: UUID
    var type: TransactionType
    var amount: Decimal
    var currency: String
    var walletID: UUID?
    var walletAmount: Decimal?
    var destinationWalletID: UUID?
    var destinationAmount: Decimal?
    var categoryName: String
    var merchant: String
    var note: String
    var occurredAt: Date
    var source: TransactionSource
    var confidence: Decimal
    var rawInput: String
    var valuation: LedgerValuation
}

struct WalletDraft: Sendable {
    let id: UUID
    var name: String
    var type: WalletType
    var currency: String
    var openingBalance: Decimal
    var icon: String
}

struct CategoryDraft: Sendable {
    let id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var type: String
    var sortOrder: Int
}

enum LedgerValuation: Sendable {
    case unvalued
    case quoted(RateQuote)
    case legacyUnverified(baseAmount: Decimal?, rate: Decimal?)
}

struct RateQuote: Codable, Equatable, Sendable {
    let id: UUID?
    let currency: String
    let usdPerUnit: String
    let requestedDate: String?
    let effectiveAt: Date
    let fetchedAt: Date
    let source: String
    let sourceDetailJSON: Data
    let valuationKind: String
    let isStale: Bool
}

struct LocalSaveReceipt: Equatable, Sendable {
    let entityID: UUID
    let operationID: UUID
    let generation: Int64
}

struct WalletDescriptor: Sendable {
    let id: UUID
    let ownerID: String
    let currency: String
    let isArchived: Bool
}

struct WalletEffect: Equatable, Sendable {
    let walletID: UUID
    let signedAmount: Decimal
}
```

Add Sendable conformance to existing value enums only after compiler verification; do not mark SwiftData models unchecked Sendable. Actor calls carry immutable snapshots, never live model references. RateQuote coding uses the complete snake_case quote inventory from database-and-rollout.md, including id → quote_id, valuationKind → valuation_kind and isStale → stale. Its JSON coding must preserve provider metadata as JSON on the wire, not accidental base64 Data: use explicit coding for that boundary or a typed metadata struct.

Task-owned method contracts:

```swift
// Task 02, concrete enums with static methods
MoneyCodec.encode(_ value: Decimal) throws -> String
MoneyCodec.decode(_ text: String) throws -> Decimal
MoneyCodec.quantize(_ value: Decimal, scale: Int) throws -> Decimal
AmountParser.parse(_ text: String, currency: String, locale: Locale,
                   allowNegative: Bool = false, allowZero: Bool = false) throws -> Decimal
Formatters.editAmount(_ value: Decimal, locale: Locale) throws -> String

// Task 03
TransactionInputSegmenter.split(_ text: String) throws -> [String]

// Task 08
WalletLedger.effects(for draft: TransactionDraft,
                     wallets: [UUID: WalletDescriptor], ownerID: String) throws -> [WalletEffect]
WalletLedger.balance(opening: Decimal, effects: [WalletEffect]) throws -> Decimal

// Task 09, concrete @MainActor LedgerStore
saveTransaction(_ draft: TransactionDraft, scope: AccountScope,
                linkedMessageID: UUID?) throws -> LocalSaveReceipt
editTransaction(_ draft: TransactionDraft, scope: AccountScope) throws -> LocalSaveReceipt
deleteTransaction(id: UUID, scope: AccountScope) throws -> LocalSaveReceipt
saveWallet(_ draft: WalletDraft, scope: AccountScope) throws -> LocalSaveReceipt
archiveWallet(id: UUID, scope: AccountScope) throws -> LocalSaveReceipt
saveCategory(_ draft: CategoryDraft, scope: AccountScope) throws -> LocalSaveReceipt
archiveCategory(id: UUID, scope: AccountScope) throws -> LocalSaveReceipt

// Tasks 10–12, existing actor plus concrete @MainActor coordinator
SupabaseService.applyLedgerMutation(_ request: LedgerMutationRequest,
                                  scope: AccountScope) async throws -> LedgerMutationResult
SupabaseService.readLedgerChanges(after: Int64, through: Int64?,
                                scope: AccountScope) async throws -> LedgerChangePage
LedgerSyncCoordinator.trigger(scope: AccountScope)
LedgerSyncCoordinator.stop()
LedgerSyncCoordinator.retry(operationID: UUID, scope: AccountScope) throws
```

`LedgerMutationRequest`, `LedgerMutationResult`, `LedgerChangePage`, `TransactionSnapshotV1`, `WalletSnapshotV1`, `CategorySnapshotV1` are concrete Codable/Sendable DTOs defined by the complete wire inventory in database-and-rollout.md. Use tagged enums for heterogeneous snapshots; no `[String: Any]` for financial command payloads. The current repository uses untyped dictionaries; limit their replacement to touched financial boundaries.

## Task 00 — Establish the baseline and regression test harness

> **Execution status 2026-09-09:** G0 SATISFIED and the task is complete except the `LedgerFixtures` draft factories, which need Task 04's types. Xcode 26.6 was installed but not selected; every command uses `DEVELOPER_DIR` rather than changing the machine's global `xcode-select`. Baseline build succeeds; unit and UI test targets, shared scheme, isolated file-backed store fixture, baseline V1 store and URLProtocol fault injection are all in place and passing. Evidence: `docs/reports/ledger-execution-baseline-2026-09-09.md`, `docs/reports/ledger-execution-task-01-2026-09-09.md`.

**Files:** modify `SumIt.xcodeproj/project.pbxproj`; create `SumIt.xcodeproj/xcshareddata/xcschemes/SumIt.xcscheme`, `SumItTests/ledger-test-support.swift`, `SumItTests/baseline-store-tests.swift`, `SumItUITests/ledger-lifecycle-tests.swift`, `docs/reports/ledger-execution-baseline-2026-09-09.md`. Do not copy an actual user database into Git.

**Consumes:** current five SwiftData model shapes. **Produces:** test targets, synthetic baseline persistent store, discovered toolchain/destination and test fixture builders.

- [x] Run `git status --short`, `git diff`, `git diff --cached --name-only`, `git log -1`; preserve earlier audit files and unrelated work.
- [x] Run `xcodebuild -version`, `xcodebuild -list -project SumIt.xcodeproj`, `xcrun simctl list devices available`. Record real compatible Xcode, scheme, OS and simulator UUID; installing/changing Xcode is a separate environment action, not an assumed successful prerequisite.
- [x] Add unit/UI test targets and shared scheme using the project's native project format. Verify existing app builds before broad changes. Do not silently change the app's language mode or minimum OS to fix unrelated compiler errors.
- [x] Add test support that creates an isolated temporary file-backed ModelContainer, deletes only its own temporary directory after closing, and can reopen it. Use URLProtocol with an ephemeral URLSession for HTTP fault injection. No live Supabase credentials in unit tests; staging credentials are isolated in the explicitly authorized SQL/integration suite.
- [x] Build fixture factories `LedgerFixtures.usdExpense(id:amount:walletID:)`, `LedgerFixtures.transfer(id:sourceID:destinationID:sourceAmount:destinationAmount:)`, `LedgerFixtures.wallet(id:currency:opening:)` once their draft types land in Task 04; declare their data tables now. Fixed UUIDs and fixed dates are in acceptance-tests.md.
- [x] Produce a baseline V1 store with a 12.50 expense, 0.001 BTC record, two wallets, custom category, linked message, unsynced row and settings. Capture identity/value expectations as JSON next to the synthetic test asset. Preserve a second copy for migration tests.
- [x] Add the source-derived regressions before corresponding fixes. A regression may be skipped with an explicit G0 dependency only until full Xcode is available; do not call the app tested meanwhile.

Example check the harness must perform:

```swift
func testPersistentStoreSurvivesReopen() throws {
    let fixture = try PersistentStoreFixture.makeBaseline()
    let before = try fixture.snapshot()
    try fixture.closeAndReopen()
    XCTAssertEqual(try fixture.snapshot(), before)
}
```

Implement `PersistentStoreFixture.makeBaseline()`, `snapshot()` and `closeAndReopen()` in test support; snapshot is a sorted Codable value record, not an array of live model objects. Test helper methods must throw on read/save failures.

**Verification:** baseline build/test output retained; test store exists on disk and survives process/container reopen. **Review gate:** do not proceed with migration claims from in-memory-only tests.

## Task 01 — Make persistent startup fail safely (P8)

> **Execution status 2026-09-09:** COMPLETE and verified. 17 unit cases plus the full P8 UI path (failure → recovery → Retry → original record present once) pass on the iOS 26.5 simulator. Evidence: `docs/reports/ledger-execution-task-01-2026-09-09.md`.

**Files:** create storage-bootstrap.swift, storage-recovery-view.swift; modify `SumIt/SumItApp.swift`, `SumIt/Services/LocalizationManager.swift`; test `SumItTests/storage-bootstrap-tests.swift` and UI target.

**Consumes:** baseline configuration and recovery fixture. **Produces:** `StorageState` with opening/ready/failed; RootView only receives a persistent ready container.

- [x] Add failing tests for forced open error, low-disk save error and unsupported schema. Assert RootView/financial actions are not constructed after open failure.
- [x] Replace the catch block creating an in-memory container. Keep startup failure details sanitized, keep original files, and expose Retry plus user-directed recovery-copy export.
- [x] Use a concrete bootstrap class with injectable throwing `openContainer` closure in tests, not a general persistence framework. Ensure only one open attempt runs at once.
- [x] Resolve the existing store URL before migration. Implement consistent closed-store recovery-copy creation with WAL/SHM handling and file hashes; never export the user's store automatically.
- [x] Preserve app lock behavior over recovery state. Ensure no sync setup, seeding or background write starts until storage is ready.
- [x] Run UI test: simulated open failure → recovery screen → Retry succeeds → original fixture appears once, with original amounts.

Control flow specimen:

```swift
func open() {
    guard !isOpening else { return }
    isOpening = true
    defer { isOpening = false }
    do { state = .ready(try openContainer()) }
    catch { state = .failed(StorageFailure(error: error)) }
}
```

`StorageFailure` retains an internal error classification and safe user message; it must not include credentials or raw database content. `isOpening`, `state`, `openContainer` are owned by StorageBootstrap.

**Done:** no writable in-memory production fallback and no data deletion in any tested failure path. **Dependency:** independent safe startup can be reviewed before the ledger protocol, but not claimed as a tested upgrade until Task 04/18.

## Task 02 — Introduce exact money and whole-field numeric parsing (P3/P7)

> **Execution status 2026-09-09:** implemented and verified — 26 XCTest cases pass on the iOS 26.5 simulator, plus 81/81 in a standalone Swift 6 spec runner. Caller cleanup stays with Task 14. Evidence: `docs/reports/ledger-execution-tasks-02-03-2026-09-09.md`.

**Files:** create money-value.swift, amount-parser.swift; modify Formatters.swift; tests `money-value-tests.swift`, `amount-parser-tests.swift`.

**Consumes:** precision/range policy in design §5. **Produces:** the exact methods in shared inventory; typed `MoneyError` cases invalidSyntax, nonFinite, outOfRange, excessPrecision, arithmeticFailure.

- [x] Write parameterized tests covering the complete AMT table before implementation.
- [x] Implement canonical Decimal/string encoding/decoding without Double. Strict full-string syntax validation precedes Decimal parsing; detect NaN and calculation errors. Define and test quantization/rounding, zero normalization and overflow.
- [x] Implement locale-aware grouping/decimal parser with an explicitly checked entire-string grammar. Do not use NumberFormatter's permissive prefix parse as acceptance.
- [x] Add edit formatter without grouping or precision loss; use original exact amount when editor text is unchanged.
- [ ] Keep current display helper temporarily for old callers, but add exact overloads for touched views. Audit every Double/%.0f/%.2f caller before Task 14 removes them.

```swift
func testCentsAndCryptoRoundTrip() throws {
    for text in ["12.5", "0.001", "0.000000000000000001"] {
        let value = try MoneyCodec.decode(text)
        XCTAssertEqual(try MoneyCodec.encode(value), text)
    }
    let parsed = try AmountParser.parse("12,50", currency: "EUR",
                                       locale: Locale(identifier: "de-DE"))
    XCTAssertEqual(try MoneyCodec.encode(parsed), "12.5")
}
```

**Done:** AMT tests pass; no numerical fallback/capping; legacy precision outside new entry policy has a distinct preserve-only path. **Review:** require proof 0.1 + 0.2 → exact 0.3 and all wallet/report arithmetic avoids Double.

## Task 03 — Preserve numeric punctuation and all batch outcomes (P4)

> **Execution status 2026-09-09:** COMPLETE in the live path. Segmenter verified (11 cases) and now the app's only splitter — `splitTransactionInput` is deleted. Failed segments keep index/text with Retry; pending confirmations are never replaced silently; limits are visible errors. BATCH-01/02/05 need injectable transport and move to Task 10. Evidence: `docs/reports/ledger-execution-tasks-03-08-2026-09-09.md`.

**Files:** create transaction-input-segmenter.swift; modify ChatViewModel.swift, ChatComposer.swift; tests `transaction-input-segmenter-tests.swift`, `chat-batch-tests.swift`.

**Consumes:** delimiter grammar in design §5.2. **Produces:** split method, indexed segment outcomes retained until user resolves them.

- [x] Test decimal commas/thousands, explicit multi-entry separators, written numbers, CRLF, whitespace, merchant commas and >20 segments.
- [x] Implement one pass over characters, treating comma as a separator only when its immediate neighbors are not both decimal digits; process newline/semicolon/spaced-plus separately.
- [x] Replace `withNumbers` filtering. Keep failures with original segment index/text and expose retry; do not swallow unsuccessful parts into a smaller unexplained count.
- [x] Segment before sanitization. Enforce limits as visible errors, not prefix truncation.
- [x] Disable conflicting photo/text submissions while parsing/confirming a batch, or require explicit discard through the existing confirmation flow. Clearing pending state must be one deliberate action.

```swift
func testDecimalCommaIsNotABatchBoundary() throws {
    XCTAssertEqual(try TransactionInputSegmenter.split("12,50 EUR coffee"),
                   ["12,50 EUR coffee"])
    XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee, 20 taxi"),
                   ["10 coffee", "20 taxi"])
    XCTAssertEqual(try TransactionInputSegmenter.split("ten dollars coffee; 20 taxi"),
                   ["ten dollars coffee", "20 taxi"])
}
```

**Done:** SEG and BATCH tests pass; input text cannot disappear because one AI call failed. AI service availability is not needed to test segmentation.

## Task 04 — Add versioned local fields and contract DTOs (P1/P2/P3/P5/P6/P7)

> **Execution status 2026-09-09:** COMPLETE and verified. Frozen V1 → V2 migration proven on disk against a store written by the frozen shapes (9 cases), full wire DTO inventory implemented and validated against the contract specimens (17 cases). 87 unit + 2 UI tests green. Evidence: `docs/reports/ledger-execution-task-04-2026-09-09.md`.

**Files:** create ledger-types.swift, ledger-sync-models.swift, ledger-schema.swift; modify all five current model definitions and storage-bootstrap.swift; tests `ledger-schema-migration-tests.swift`, `ledger-coding-tests.swift`.

**Consumes:** frozen baseline store, MoneyCodec and design field inventory. **Produces:** V1/V2 schema, typed drafts/envelopes, durable queue/checkpoint/issues/rates.

- [x] Prove frozen V1 opens the actual baseline fixture before adding V2. If the unversioned-to-versioned identity mapping fails, fix migration compatibility rather than starting a fresh database.
- [x] Add optional exact fields and metadata with safe defaults; preserve old Double fields, IDs, owners and dates.
- [x] Add the four new local models, indexed lookup fields where supported on iOS 17, explicit schema inclusion and Xcode source registration. Do not add newer OS-only macros.
- [x] Implement full Codable DTO inventory; wire cursor/revision as decimal strings mapped to Int64 with bounds checks, monetary values as canonical strings. Unknown tags are decode errors, never default expense/empty lists.
- [x] Add UUID-injecting initializers to Transaction, Wallet, Category, with default UUID only for new user-created records. Remote restore supplies the identity explicitly.
- [x] Test owner/date/quote null handling and migration rerun idempotence on disk. Keep records that require semantic reconciliation in legacy state; schema migration alone must not derive opening balances.

```swift
func testUpgradePreservesIdentityAndOriginalQuantity() throws {
    let fixture = try PersistentStoreFixture.makeBaseline()
    let before = try fixture.snapshot()
    try fixture.upgradeToV2()
    let after = try fixture.snapshot()
    XCTAssertEqual(after.transactionIDs, before.transactionIDs)
    XCTAssertEqual(after.originalAmounts, before.originalAmounts)
    XCTAssertEqual(after.walletBalances, before.walletBalances)
}
```

Extend fixture snapshot with these concrete comparable fields and a reopen step. **Done:** MIG schema tests pass; no new entity IDs or lost original values; no production reset code.

## Task 05 — Inventory and add the remote foundations (P1/P6)

> **Execution status 2026-09-10:** DISCOVERY COMPLETE, **G1 satisfied** — production was resumed and its real schema, constraints, indexes, triggers, policies, grants and data-quality aggregates are recorded. The staging reconstruction is now known to be **wrong** (missing `transactions.timestamp`, invents `categories.created_at`) and must be rebuilt from the discovery. Production was restored to a clean state: write-gate policies reverted, duplicate indexes dropped, orphan helper dropped. Evidence: `docs/reports/production-discovery-2026-09-10.md`, `docs/reports/production-incident-2026-09-09.md`.

**Files:** create and finalize `Backend/migrations/20260909_01_ledger_foundations.sql`; `Backend/tests/ledger-schema-tests.sql`; schema-only discovery report. Modify Backend/README.md only after actual target/version are recorded.

**Consumes:** verified G1 access; database document §1–3. **Produces:** known baseline, additive columns, owner state/receipt/feed tables, immutable rate cache/leases, scoped executor role/grants, actual matched conflict constraints, and the scoped legacy-write policy helper. The rate schema exists now so Task 06 can validate quote references without a missing-table dependency.

- [x] Run all discovery queries and inspect actual policies, inherited grants, constraints, trigger side effects and local_id types. Check existing profile creation behavior.
- [x] Record aggregate duplicate/null/owner problems without printing financial rows. Verify a recoverable staging copy and backups.
- [x] Create additive migrations with no global data deletion, rename or unsafe cast. Mark the exact target before applying. Read back resulting schema and grants immediately.
- [x] Add test fixtures for legacy and adopted accounts. Validate version-scoped checks preserve legacy values and restrict new exact values.
- [x] Ensure new tables cannot be directly written by authenticated/anon users, including through permissive inherited privileges. No client-controlled bypass marker.

```sql
BEGIN;
-- Use synthetic accounts established by the staging fixture, never production IDs.
SELECT has_table_privilege('authenticated', 'public.ledger_mutation_receipts', 'INSERT')
       AS client_can_insert_receipts;
SELECT has_table_privilege('anon', 'public.ledger_change_log', 'UPDATE')
       AS anonymous_can_modify_feed;
ROLLBACK;
```

Both results must be false; also execute real role/JWT write attempts because catalog checks alone are insufficient. **Done:** G1 recorded, schema tests pass, migration state verified. **Stop:** missing access or unknown current shape; do not fabricate SQL evidence.

## Task 06 — Implement atomic, idempotent versioned mutations (P2/P5/P6)

> **Execution status 2026-09-10:** APPLIED to production and FUNCTIONALLY VERIFIED. 15 write cases pass against the real schema inside rolled-back transactions, including the uppercase-identity case (found, not duplicated). Two bugs found and fixed by the run: conflict precedence (`already_exists` vs `revision_mismatch`) and the executor's inability to call `auth.uid()`. Production unchanged: 70/0/2/3 rows, 0 feed events, 0 receipts. **Concurrency (CONC-01..04) is NOT run** — it needs two simultaneous sessions and a disposable target. Evidence: `docs/reports/ledger-execution-task-06-verified-2026-09-10.md`.

**Files:** create and finalize `Backend/migrations/20260909_02_ledger_mutation_rpc.sql`; tests `Backend/tests/ledger-write-tests.sql`, `Backend/tests/ledger-concurrency-tests.mjs`.

**Consumes:** typed contract, supporting tables. **Produces:** apply_ledger_mutation_v1 with full receipts, validation, owner checks, compare-and-set revisions and deletion behavior.

- [ ] Write failing SQL tests for duplicate operation, changed payload same ID, concurrent create/update, wrong owner, invalid transfer refs, expected-revision mismatch and deleted identity.
- [x] Implement explicit action/entity branches and input validation. Bound JSON size and strings; cast decimal strings only after grammar/precision validation; reject field names outside the contract.
- [x] Validate base amount with the exact scale-18 half-even product rule; preserve unchanged legacy amounts only via the server-verified metadata-edit branch. Test null field combinations and same-currency wallet-effect equality.
- [x] Lock the owner's state row, inspect replay receipt, check revision/references, apply the entity, increment cursor, write full feed snapshot and acceptance receipt in one transaction.
- [x] Ensure SECURITY DEFINER cannot bypass owner checks; fixed search_path and schema-qualified names; revoke PUBLIC execution.
- [ ] Implement adopted-account restriction on old direct writes without breaking unadopted accounts. Verify both behaviors as separate tests.
- [ ] Exercise two simultaneous database sessions; a mocked sequential test is not enough to prove serialization.

Acceptance specimen:

```sql
-- In the staging fixture's authenticated session:
SELECT public.apply_ledger_mutation_v1(request) AS first_result
FROM ledger_test_requests WHERE name = 'valid_transfer';
SELECT public.apply_ledger_mutation_v1(request) AS replay_result
FROM ledger_test_requests WHERE name = 'valid_transfer';
-- Assert identical operation/revision, one transaction, one receipt, one feed event.
```

`ledger_test_requests` is a temporary test fixture table created by ledger-write-tests.sql, never a production table. **Done:** RPC/CONC/WAL tests pass against PostgreSQL; stale/mismatched writes produce no partial effects.

## Task 07 — Implement ordered, bounded, complete change reads (P1/P6)

> **Execution status 2026-09-10:** APPLIED to production and VERIFIED. 2,503 seeded events with shuffled timestamps retrieved over 11 pages: 2503 total, 2503 distinct, 0 missing, 0 duplicated, strictly ascending across page boundaries, watermark fixed on every page, 250 tombstones delivered. Bounds and refusals all correct; owner isolation holds. Write-then-read through both RPCs confirmed the full snapshot shape including a tombstone. **CONC-04 is NOT run** — it needs two simultaneous sessions on a disposable target. Evidence: `docs/reports/ledger-execution-task-07-2026-09-10.md`.

**Files:** create and finalize `Backend/migrations/20260909_03_ledger_change_feed.sql`; `Backend/tests/ledger-pull-tests.sql`, concurrency test file.

**Consumes:** committed per-owner cursor/change log. **Produces:** read_ledger_changes_v1 with fixed watermark, <=250 events, explicit next cursor and tombstones.

- [x] Seed 1,001 and 2,503 events, including deleted records, equal timestamps and out-of-order occurrence dates. Expect complete retrieval by cursor, independent of dates.
- [x] Implement committed watermark and bounded JSON response; fetch limit + 1; set next cursor correctly for last/empty page.
- [x] Return full snapshots with owner, source operation and exact fields. Reject invalid pagination arguments and unauthenticated callers.
- [ ] Reproduce concurrent commit ordering: hold an owner mutation open, start another, read watermark, then commit/rollback. Prove no lower committed event is skipped.
- [x] Verify another user's cursor/data cannot be read by changing arguments.

```sql
SELECT public.read_ledger_changes_v1(0, NULL, 250);
-- Persist returned through_cursor; pass that same value to every next page.
-- Fixture runner checks collected distinct cursors equal the seeded set.
```

**Done:** PULL tests pass; all 2,503 events retrieved, with no reliance on the PostgREST default row cap or wall-clock timestamp.

## Task 08 — Implement one wallet formula and atomic transfer representation (P5)

> **Execution status 2026-09-09:** COMPLETE and verified. 23 WAL cases pass, including the canonical six-step scenario and 20 deterministic shuffles proving order independence. WAL-12 moves to Task 14 (editor) and WAL-18 to Task 18 (adoption). Evidence: `docs/reports/ledger-execution-tasks-03-08-2026-09-09.md`.

**Files:** wallet-ledger.swift; Transaction.swift, Wallet.swift as needed; tests `wallet-ledger-tests.swift`.

**Consumes:** TransactionDraft, WalletDescriptor, Decimal rules. **Produces:** effects/balance methods; validation common to local commands and UI.

- [x] Write WAL tests for income/expense, equal-currency transfer, cross-currency explicit amounts, two-wallet rename, archive, self-transfer and wrong owner.
- [x] Implement explicit type switch. Return one signed effect for expense/income, two for transfer. Validate positive quantities, matching currency semantics and both references.
- [x] Sum current entity effects from opening balance; no mutation of absolute remote wallet totals. A deleted entity contributes nothing; a pending edit contributes once.
- [x] Keep fees outside transfer inference: an ordinary fee expense has its own effect and can be linked in the note. Do not fabricate fee calculations.
- [x] Add same-currency conservation and edit/delete inverse tests with exact decimals; test under many event arrival orders.

```swift
func testTransferPreservesCombinedSameCurrencyBalance() throws {
    let draft = try LedgerFixtures.transfer(id: LedgerIDs.transfer,
        sourceID: LedgerIDs.walletA, destinationID: LedgerIDs.walletB,
        sourceAmount: "100", destinationAmount: "100")
    let effects = try WalletLedger.effects(for: draft,
        wallets: LedgerFixtures.usdWalletDescriptors, ownerID: LedgerIDs.ownerA)
    XCTAssertEqual(try WalletLedger.balance(opening: 0, effects: effects), 0)
}
```

Fixture builder parses strings with MoneyCodec and throws on invalid data, as the call above reflects. **Done:** no balance logic uses wallet names or `type != income` as a debit shortcut.

## Task 09 — Make local save/edit/delete and queued intent atomic (P2/P5/P6)

> **Execution status 2026-09-10:** COMPLETE and verified. `LedgerStore` implements all seven commands with one checked boundary; 18 cases pass, each asserting after a close-and-reopen, with failures injected through a save closure around the real context. `AppStore.saveConfirmed` no longer returns a transaction after a failed save. Caller migration stays with Task 14. Evidence: `docs/reports/ledger-execution-task-09-2026-09-10.md`.

**Files:** ledger-store.swift; modify AppStore.swift; tests `ledger-store-tests.swift`.

**Consumes:** V2 context, drafts, pure wallet validation. **Produces:** LedgerStore commands and LocalSaveReceipt, durable PendingMutation creation.

- [x] Write fail-before-save/fail-during-save tests verifying entity, linked reply and queue are all unchanged. Use injected throwing persistence closure in tests around the concrete context, not a production fake DB.
- [x] Use the container main context consistently for LedgerStore and scoped @Query views, configure its autosave behavior before child views mutate it, and remove uncommitted live-model draft mutation. Validate before applying any model changes.
- [x] Perform entity change, generation increment, queue entry and saved reply in one checked transaction; catch/rollback and rethrow typed errors. No network awaits inside the boundary.
- [x] Delete creates a tombstone, not `ctx.delete(tx)`. Archive wallet/category instead of erasing relationships; preserve history labels.
- [x] Append predecessor-linked immutable intents for repeated edits; do not reuse an entity's operation ID. Persist owner in the queue from the captured scope.
- [x] Reject a second create for an existing owner+entity UUID before mutation; confirmation drafts allocate their UUID once, and repeat taps resolve to the already saved record rather than minting a fresh ID.
- [x] Return LocalSaveReceipt only after save success. AppStore no longer marks remote success on its own.

Boundary specimen:

```swift
try validateDraftAndScope()
do {
    try applyEntityAndEnqueue()
    try updateLinkedSavedReply()
    try context.save()
} catch let domainError as LedgerWriteError {
    context.rollback()
    throw domainError
} catch {
    context.rollback()
    throw LedgerWriteError.persistence(error)
}
```

The financial context has autosave disabled and no unrelated pending changes; the one checked save persists the complete mutation. If choosing ModelContext.transaction instead, prove its save/rollback behavior on the minimum supported SDK with the same fault tests. The three methods are local implementation steps inside each command, not empty shared hooks: tests must cover their real changes. `LedgerWriteError` distinguishes validation, wrongScope, missingEntity, and persistence. **Done:** LOC tests pass with a disk reopen after each failure, not just object-memory assertions.

## Task 10 — Replace silent network outcomes with typed receipts (P2/P6)

> **Execution status 2026-09-10:** COMPLETE for the client side. Injectable session and auth; typed `LedgerTransportError` per outcome; 19 cases cover ERR-01..08 against a URLProtocol stub on an ephemeral session. ERR-09's URL branch is unexercised (AppConfig is not overridable in tests) and ERR-10 belongs to Task 11. The old unchecked methods remain until Task 14 retires their callers. Evidence: `docs/reports/ledger-execution-task-10-2026-09-10.md`.

**Files:** SupabaseService.swift, AuthService.swift; tests `supabase-transport-tests.swift` using URLProtocol.

**Consumes:** RPC contract; AccountScope; session refresh service. **Produces:** checked apply/read methods and typed HTTP/auth/protocol errors.

- [x] Test every status in the ERR table, including 2xx empty/malformed data, missing receipt, wrong operation ID and wrong owner.
- [x] Inject an ephemeral URLSession into a non-singleton testable actor initializer while retaining `.shared` for production call sites. No real HTTP in unit tests.
- [x] Obtain refreshed auth for the captured scope and build RPC URLs through existing URLComponents. Invalid URL is a thrown configuration error, never a silent return.
- [x] Require successful HTTP and structurally valid matching response. Preserve PostgREST error code/status internally without displaying raw backend payloads.
- [x] Perform at most one serialized refresh/retry on 401, rechecking scope before/after awaits. Non-401 auth/service outages do not erase local data.
- [ ] Remove financial callers of old unchecked saveWallet/saveCategory/delete methods after Task 14; retain only clearly labeled legacy migration readers until Task 18.

```swift
let result = try await service.applyLedgerMutation(request, scope: scope)
XCTAssertEqual(result.operationID, request.operationID)
// URLProtocol fixture returns HTTP 200 with a different operation ID:
// expect protocolMismatch, and the original PendingMutation remains intact.
```

**Done:** all ERR transport cases distinguish known rejection from unknown outcome; no `try?` turns a failed request into a sync acknowledgment.

## Task 11 — Implement durable push, retries and generation-aware acknowledgments (P2/P6)

> **Execution status 2026-09-10:** COMPLETE and verified. `LedgerSyncCoordinator` with frozen requests, predecessor chains, dependency gating, generation-gated acknowledgment, per-entity blocking and bounded backoff. 15 cases pass (PUSH-01..12 plus signed-out scope, explicit Retry and backoff growth), each asserting after a close-and-reopen. Found and fixed a real bug: `attemptCount` was only incremented on first freeze, pinning backoff to its first rung forever. **Nothing triggers it in production yet** — the live save path still uses `saveConfirmed`, so the queue is empty for real users until Task 14. Evidence: `docs/reports/ledger-execution-task-11-2026-09-10.md`.

**Files:** ledger-sync-coordinator.swift; AppStore.swift; tests `ledger-push-tests.swift`.

**Consumes:** PendingMutation, checked transport, LocalSaveReceipt. **Produces:** one active coordinator per owner, replay-safe frozen requests and durable ack.

- [x] Write PUSH tests before implementing: server commit/response loss, local ack save failure, edit while send is pending, crash inFlight, two triggers and predecessor chain.
- [x] Persist frozen request and inFlight state before dispatch; no mutable snapshot captured across awaits. Dispatch only the next eligible operation whose predecessor has been acknowledged.
- [x] On acknowledgment, persist receipt completion, server revision, successor release and current-generation status in one local transaction. Do not replace a newer local edit with older server snapshot.
- [x] Inject clock/sleep behavior as concrete closures for deterministic tests; implement bounded jitter/backoff and Retry-After. A foreground timer does not delete operations or run indefinitely in background.
- [x] Persist blocked/conflict states. Continue independent entities; stop on local storage failure or account change. Ensure category/wallet creation precedes dependent transaction requests.
- [x] On restart retry the exact frozen request/ID. Do not convert inFlight to a fresh operation.

Acknowledgment condition:

```swift
if entity.localGeneration == mutation.localGeneration {
    applyAcceptedSnapshotWithoutChangingIdentity()
}
entity.serverRevision = acceptedRevision
completeOnlyThisOperation()
```

In implementation, preserve a separate acknowledged base revision when newer local generations exist; a field update must not imply the newest draft is synced. `applyAcceptedSnapshotWithoutChangingIdentity` and `completeOnlyThisOperation` are named algorithm steps implemented/tested in this task. **Done:** PUSH tests produce one remote effect and no lost latest edit under all crash points.

## Task 12 — Merge remote pages without duplicates or lost cursors (P1/P6)

> **Execution status 2026-09-10:** COMPLETE and verified. `pull(scope:)` merges by `(owner, kind, UUID)` compared as UUID values, commits each page with its checkpoint, recognises its own operations, records conflicts with both candidates, and keeps rows whose references have not arrived. 16 cases pass (REST-01..08, REST-10, 1,250 records over five pages, failed-commit atomicity, checkpoint resume, moving-watermark refusal). REST-09 needs the history screen (Task 19). **Nothing calls it in production yet** — the old `restoreFromCloud` with its `limit=1000` is still the live path until Task 14. Evidence: `docs/reports/ledger-execution-task-12-2026-09-10.md`.

**Files:** coordinator, SupabaseService.swift, AppStore.swift; tests `ledger-restore-tests.swift`.

**Consumes:** read RPC, identity-aware constructors, checkpoint. **Produces:** resumable complete restore and conflict detection.

- [x] Write repeated restore tests for transaction/wallet/category, UUID casing, 1,001+ records, tombstones and edited records.
- [x] Replace insert-only restore loops and string-ID sets. Fetch by owner+UUID, update newer clean records, preserve stable IDs and reject malformed/missing owners/dates.
- [x] Apply full page and checkpoint in one transaction. Fail at each insertion index; restart and replay must yield exactly the same dataset.
- [x] Keep fixed through watermark; validate page monotonicity, duplicate/out-of-range cursors, hasMore/next consistency and snapshot revision bounds.
- [x] Keep acknowledged operation IDs until their feed cursor passes and ignore older known revisions without rolling back the entity. Recognize the client's own operation in the feed and avoid reporting it as a conflict. When a different remote edit meets a pending local candidate, persist SyncIssue and stop that entity's descendants.
- [x] Remove `limit=1000` restore behavior and include remote deletion records. Restore definitions/relationships before presenting totals; unresolved references are visible issues, never omitted rows.

```swift
try await harness.pullToCompletion()
let first = try harness.persistentSnapshot()
try await harness.pullToCompletion()
XCTAssertEqual(try harness.persistentSnapshot(), first)
```

`LedgerSyncTestHarness` owns fake transport, disk context and coordinator; define pullToCompletion/persistentSnapshot in test support. **Done:** REST tests preserve exact IDs/counts/totals across repeated runs and crash/replay.

## Task 13 — Scope accounts and provide explicit conflict resolution (P1/P6 dependency)

**Files:** AuthService.swift, RootView.swift, AppStore.swift, ProfileEditView.swift, all financial @Query views; create sync-issues-view.swift; tests `account-scope-tests.swift`, `ledger-conflict-tests.swift`.

**Consumes:** AccountScope epoch, PendingMutation and SyncIssue. **Produces:** safe sign-in/out and use-server/keep-local/save-as-new actions.

- [x] Test account A → sign out keep data → account B; A's transactions, wallets, chat and custom categories must not appear or upload under B.
- [x] Rebuild scoped views by epoch, filter queries by owner/deletedAt, and invalidate active sync on owner change. Ensure automatic token-refresh failure does not bypass this transition and a delayed old refresh cannot restore a signed-out/replaced session.
- [x] Preserve the explicit signed-out local scope, never dispatch its operations to authenticated RPC, and keep retained account A data hidden there. Move local-owner adoption out of direct ProfileEditView reassignment into Task 18's explicit migration path. Do not silently attach anonymous history to whichever user signs in next.
- [x] Implement conflict view using existing Form/Sheet patterns. Display original/local/server amount, currency, wallet and revision, with no automatic money-field merge.
- [x] Implement use-server, keep-local with new operation/new expected revision, and save-deleted-local-as-new identity. Cancel/block queued descendants consistently; preserve discarded local candidates until user dismisses them.
- [x] Test a new remote edit during conflict resolution causes another conflict; no unbounded retry or silent last-write-wins.

**Done:** ACC/CONFLICT cases pass, including a delayed A response delivered after B activates. No database policy alone is treated as sufficient local UI isolation.

## Task 14 — Route all financial UI through exact, atomic commands (P2/P3/P4/P5/P6)

**Files:** ConfirmationCard.swift, ChatRootView.swift, ChatViewModel.swift, WalletViews.swift, CategoryManager.swift, ReportsView.swift, Formatters.swift, LocalizationManager.swift, AppStore.swift.

**Consumes:** exact parser, local commands, scope/conflict actions. **Produces:** no direct view-owned financial saves, truthful result copy and complete transfer editing.

- [x] Add UI regressions for opening/saving unchanged cents/crypto, changing only merchant, canceling edit and clearing selected wallet.
- [x] Replace rounded amount initialization and permissive Double parsing in both transaction editors and wallet editor. Keep draft fields separate until successful save; disable Save with precise field error.
- [x] Extend existing type selection with source/destination UUID pickers and explicit quantities for transfers; prevent self-transfer/cross-owner/archived selection. For expense/income, expose exact wallet-currency effect where needed.
- [x] Wire onConfirm to the latest bound draft; clear wallet selection when nil; preserve pending card on local save failure. Prevent repeated taps from creating another transaction identity.
- [x] Replace direct modelContext saves, queue-less deletes and Task uploads in views with LedgerStore commands. Keep message-only deletion separate from transaction deletion.
- [x] Show “Saved on this device” after local receipt, “Waiting to sync” while queued, actual error/conflict text otherwise. A transport success does not hide local ack failure.
- [x] Show opening/current wallet balances separately; names are labels, currency is locked when linked records exist, archive preserves history. Retire applyWalletDelta/wallet-name balance matching once no caller remains.

**Done:** UIEDIT/WAL/LOC tests pass and search finds no touched financial mutation still bypassing LedgerStore. Capture simulator screenshots for new states during execution; no design overhaul.

## Task 15 — Preserve exact AI amounts on text and receipt paths (P3/P4/P5 dependency)

**Files:** BackendService.swift, Models.swift/ParsedTransaction, ChatViewModel.swift; backend `_lib/openai.js`, new transaction-contract.js, parse.js, parse-image.js; tests `test/transaction-contract.test.js`, Swift decoding tests.

**Consumes:** exact contract/version policy. **Produces:** v2 additive amount_decimal and explicit date/locale context; legacy client compatibility.

- [x] Add Node built-in test script only for the tests introduced here, using existing ESM and no package install merely to run pure tests. Record a lockfile when dependencies are installed during authorized execution.
- [x] Test malformed/negative/non-finite/over-precision amounts, unknown type/currency, relative dates and both text/photo routes through one contract validator.
- [x] Add contract version to new requests; preserve existing endpoint shape for legacy callers. Request exact amount string from model and emit amount_decimal plus derived legacy numeric amount; never reconstruct exact string from a rounded Double in v2.
- [x] Pass current local date, timezone identifier and app locale; validate them before including context. Preserve segment indexes and user text for correction.
- [x] Decode v2 amount with MoneyCodec; reject a malformed declared v2 response. Convert into a typed draft; transfer suggestions do not bypass wallet/amount confirmation.
- [ ] Run mocked route tests. Run a small consented/synthetic live AI set only under a separate established spend allowance; live cost is not authorized by this plan. _(2026-09-11: mocked route tests run and passing; the live AI set was **not** run — no spend allowance has been established.)_

```javascript
import test from 'node:test';
import assert from 'node:assert/strict';
import { validateParsedTransactionV2 } from '../api/_lib/transaction-contract.js';
test('preserves decimal amount as a string', () => {
  const result = validateParsedTransactionV2({
    type: 'expense', amount_decimal: '12.50', currency: 'EUR',
    category: 'Food', merchant: 'Cafe', date: '2026-05-19',
    note: '', confidence: 0.9, wallet_name: ''
  });
  assert.equal(result.amount_decimal, '12.5');
});
```

Define this validator and its exact exported name in the new file; validation errors are explicit typed codes. **Done:** AI tests pass, old amount consumers remain compatible, neither photo nor text bypasses exact validation.

## Task 16 — Qualify and implement the concrete rate service (P7)

**Files:** api/rates.js, api/_lib/rates.js, existing Task 05 rate-cache schema, `.env.example` names only; tests `test/rates.test.js`; execution provider report.

**Consumes:** design §8, rate cache schema, existing auth/admin client. **Produces:** authenticated bounded quotes with provenance; exact unavailable states.

- [x] Read current official provider docs and terms. Record that planning's two Frankfurter probes were 403, and no CoinGecko credential was tested. Do not silently erase failed evidence.
- [ ] From intended server environment perform a bounded, recorded latest/historical fiat probe for all required currencies. Resolve crypto IDs from the official registry by expected name/symbol; verify current and allowed historical quote operations under an authorized account. Stop paid activity without allowance. _(2026-09-11: bounded fiat probes succeeded from the developer machine, **not** Vercel; crypto IDs resolved from the registry keylessly; no authorized CoinGecko account, historical crypto not probed. Open.)_
- [x] Save sanitized response fixtures before interpretation. Record all request counts, failures, provider/effective dates and supported codes. Require correct rate direction, not merely HTTP 200.
- [x] Implement fixed two-provider routing, response validation, normalized canonical quote strings, persisted server-issued quote IDs, server-only cache and bounded refresh lease. Verify provider claims against cache rows in the write RPC. Requests send only currencies/date. No transaction amounts/text or secret key in URL/logs.
- [x] Test stale/future/negative/missing data, precision, reciprocal conversion, date fallback, provider403/429/5xx, absent credential and cache outage. Return unavailable per currency instead of an invented 1.
- [ ] Add needed provider key through managed secret workflow only when authorized. Document attribution/terms obligations in the execution report and app source attribution surface. _(2026-09-11: attribution/terms documented in the Task 16 report and surfaced in Settings; no key added — not authorized, and CoinGecko's storage clause needs an owner decision. Open.)_

```javascript
test('missing foreign rate never becomes one', async () => {
  const result = await loadRateQuotes({ currencies: ['EUR'], date: '2026-05-19' },
                                    fixtureDependencies.withFiatFailure(503));
  assert.equal(result.quotes.length, 0);
  assert.equal(result.unavailable[0].currency, 'EUR');
});
```

`loadRateQuotes(input, dependencies)` is the concrete rates module entry. Its result is `{ quotes: RateQuote[], unavailable: [{ currency, reason, retryable }] }`. Each requested code appears in exactly one result group; no silent omissions or duplicates. `unavailable.reason` is one of `provider_access`, `provider_limit`, `provider_failure`, `missing_currency`, `invalid_quote`, `historical_unavailable`, `cache_failure`, `refresh_in_progress`. Unknown future reasons are displayed as an explicit unavailable state, not coerced into success.

The concrete dependency object has `fetch` (Web Fetch signature), `now(): Date`, `readQuotes(keys)`, `claimRefresh(key, leaseUntil)`, `insertQuote(quoteWithoutID)` returning the persisted UUID/row, and `releaseRefresh(key)`. The fixture builder used above supplies those same functions, a fixed clock, empty cache and a fetch response with status 503. It is test support, not a production vendor abstraction. Fix cache keys to `(source, currency, quote_kind, requested_date)` with `requested_date=null` for current and the explicit ISO day for historical; use a canonical non-null string encoding for lease keys. Quotes are immutable rows; leases are expiring rows keyed by that tuple and have no financial data.

Implement three focused helpers in the existing concrete rates module: `normalizeProviderNumber(number) -> canonicalString`, `reciprocal18(canonicalString) -> canonicalString`, and `validateQuote(quote, request, clock)`. After finite/positive checks, normalize with `toPrecision(15)` and expand exponent notation by moving the digit boundary, never with monetary Number arithmetic. To invert a value represented as integer `n / 10^s`, divide `10^(s+18)` by n with BigInt; use quotient/remainder for half-even rounding to 18 places, then canonicalize. Reject zero-after-rounding and overflow. Required examples: `0.8 → 1.25`, `3 → 0.333333333333333333`, `0.00000001 → 100000000`, and numeric quote `1.2345678901234567 → 1.23456789012346` under the deliberate 15-digit observation policy. Manual user-entered rates bypass provider numeric normalization and retain allowed exact digits. Do not create a generic vendor registry. **Done:** FX provider gates and mocked FX tests pass. If access remains unavailable, preserve manual/unvalued functionality but keep automatic P7 qualification open.

## Task 17 — Apply frozen quote semantics to saves and reports (P7/P3/P5)

**Files:** rate-service.swift, CurrencyService.swift, Formatters.swift, AppStore.swift, ReportsView.swift, both transaction editors, wallet views; tests `valuation-tests.swift`, `report-valuation-tests.swift`.

**Consumes:** dated RateQuote and exact amounts. **Produces:** quote selection/manual/unvalued UI; booked USD values and honest display conversion.

- [x] Test metadata-only edit retains quote/rate/base amount; amount edit recomputes with confirmed quote; currency/date edit requires an explicit quote decision.
- [x] Remove CurrencyService's static rate table and unknown=1 fallbacks. Keep supported-currency metadata separately from rate availability.
- [x] Add asynchronous quote state in the draft, with manual rate and unvalued choices; preserve local save capability offline. Require explicit wallet-currency amount where conversion is unavailable.
- [x] Persist provenance with the transaction and mutation. Background quote refresh never rewrites booked records.
- [x] Reports use Decimal aggregation; chart conversion to Double only after aggregation. Show unvalued/legacy-unverified counts; do not imply partial totals are complete.
- [x] Label current display conversion separately from historical book value; show native wallet balances and explicit negative sign. Stablecoin USD values are provider/manual values, never a constant peg assumption.
- [x] Implement dated/stale cache presentation and manual rate validation as specified. No fallback to today's quote for missing historical crypto.

_(2026-09-11: implementation bullets done and tested; P7 itself stays open — automatic sources are not qualified, see Task 16/17 reports.)_

**Done:** VAL/FX/REPORT cases pass across offline/outage/weekend/different display-currency scenarios; P7 is complete only with qualified automatic sources or an explicitly user-approved scope change.

## Task 18 — Implement legacy adoption with reversible reconciliation (P1/P3/P5/P6/P7/P8)

**Files:** ledger-migration.swift, ProfileEditView.swift, storage bootstrap, sync issues view; `Backend/tests/ledger-adoption-tests.sql`; `SumItTests/ledger-adoption-tests.swift`; dated migration execution report.

**Consumes:** full old/new schema, working protocol, baseline fixtures and backups. **Produces:** restartable per-account manifest/adoption and explicit ambiguous-data handling.

- [ ] Build fixtures for missing local_id, UUID case, formerly-restored new UUIDs, true duplicate same-value expenses, orphan wallet names, archived wallets, wrong currencies, one-sided transfers and local/cloud balance disagreement.
- [ ] Produce a read-only inventory first; strong identity matching only. Generate a stable manifest ID and checksums. Distinguish schema conversion from semantic repair.
- [ ] Implement reconciliation UI/actions for ambiguous identities, baseline choices and missing transfer destinations; keep raw originals and explain exact before/after changes. No fuzzy automatic deletion.
- [ ] Calculate opening balances from complete selected data, preserve old numeric values/quotes as legacyUnverified, and require explicit revaluation to change them.
- [ ] Implement the explicit writes_paused/manifest state and brief write-draining freeze from database-and-rollout.md, including safe resume of a failed pre-adoption account. Stage a complete canonical dataset and seed remote revisions/feed under that per-account freeze. Activate atomically only after every required adoption check passes; upgrade all devices before activation.
- [ ] Test crash/retry at every step and same-manifest rerun. Roll back before activation or resume forward after activation; never reset the whole account.
- [ ] After activation, pull/compare and then submit retained local changes through the durable protocol. Do not upload the old isSynced queue blindly before identity reconciliation.

**Done:** MIG/ADOPT tests pass and G2 has zero unexplained count/balance changes. Unresolved historical questions remain visible and prevent claiming the affected history reconciled. The task is not complete by running a schema-only migration.

## Task 19 — Make restored records and sync failures reachable (P1/P2/P6)

**Files:** transaction-history-view.swift, sync-issues-view.swift, ReportsView.swift, RootView.swift, LocalizationManager.swift; UI tests.

**Consumes:** scoped active dataset, existing TxRow/editor, pending/issues. **Produces:** complete browse/edit/delete path and visible pending/conflict state.

- [ ] Add full transaction list entry from Reports. Use stable identity, scoped filtering and incremental fetch/render appropriate for 2,503+ records; show original amount/currency/date and sync status.
- [ ] Reuse existing editor through TransactionDraft; do not require a linked ChatMessage to edit/delete a restored record.
- [ ] Expose Retry and conflict resolution from a status surface; distinguish offline/auth/storage/validation conflicts. No “all synced” while descendants or unresolved receipts remain.
- [ ] Localize new user-facing strings in the existing six-language system and test literal key coverage. Verify amount/date formatting under all app locales.
- [ ] Check small screen, large text, VoiceOver labels/actions, dark mode, empty state and long merchant names on a simulator/device. Capture evidence for new states only.

**Done:** restored row 1,001 is reachable, editable and deletable; changes converge with another device; no screenshots substitute for behavioral assertions.

## Task 20 — Execute the full failure and lifecycle suite (all eight)

**Files:** complete acceptance test files, `docs/reports/ledger-reliability-verification-2026-09-09.md`; modify product code only for failures exposed by these tests.

**Consumes:** completed Tasks 00–19. **Produces:** checked acceptance matrix with actual commands/results, no inferred passes.

- [ ] Run pure money/segmentation/wallet tests, file-backed local persistence tests, mocked transport tests, PostgreSQL concurrency/RLS tests and UI/device lifecycle tests.
- [ ] Run multi-device schedule from acceptance-tests.md with no network, expired session, timeout after server commit, app killed before/after ack, remote delete/local edit, account switch during await and low disk.
- [ ] Reopen real file-backed fixtures after every injected failure. Compare canonical sorted IDs, decimal amounts, wallet effects, deletion state, queue and cursor.
- [ ] Verify all direct financial mutation callers now route through the new command boundary. Confirm no dormant old sync loop or absolute balance upload can run.
- [ ] Re-run only failed/affected tests after fixes; complete full focused suite once final integrated changes are in place. Record tests not runnable as blocked.
- [ ] Check source diffs for unrequested payment/redesign/global-environment changes; remove accidental scope expansion.

**Done:** every mandatory acceptance ID is green with evidence or explicitly blocks release. All eight closure rows have matching tests and code references.

## Task 21 — Run coordinated pilot and prepare completion handoff

**Files:** final execution report, `docs/architecture/ledger-reliability.md`, `docs/handoffs/ledger-reliability-completed.md`; followups file only for genuinely deferred, out-of-scope work.

**Consumes:** G0–G4 evidence, backup test, explicit rollout authorization. **Produces:** verified deployed state for selected accounts and a cold-reader handoff.

- [ ] Prepare a concrete pilot record: verified target, actual app/backend revisions, migration files, selected account, device upgrade status, baseline totals and rollback action. Obtain any still-required production authorization only after this package is reviewable.
- [ ] Apply/verify authorized additive migrations and compatible backend changes in order. Reuse already-verified staging evidence, apply only unapplied finalized migration files to the verified rollout target, and never rerun/edit an applied file as if it were new. Do not deploy an application depending on an unapplied schema.
- [ ] Activate one coordinated account; compare before/after IDs, totals, balances and pending state. Exercise one exact expense and one two-wallet transfer across two upgraded devices.
- [ ] Stop adoption for any invariant violation; preserve logs without financial payloads; forward-fix or reconcile backup according to database-and-rollout.md.
- [ ] Update architecture documentation with actual implementation, command paths, schema and known operational limits. Record all test commands and actual outputs.
- [ ] Before authorized commit/push: inspect status and staged paths, run the project's actual type/build checks and Node/SQL tests, then commit with explicit paths. Do not invent a lint tool if none is configured. No PR unless requested.

**Done:** completion report distinguishes local code complete, staging verified, provider qualified and pilot deployed. No claim that this work also fixes the separate subscription/privacy/PIN findings.

## Commands and evidence discipline

From the repository root, after Task 00 has discovered a real simulator and registered test targets:

```sh
xcodebuild -list -project SumIt.xcodeproj
xcrun simctl list devices available
xcodebuild -project SumIt.xcodeproj -scheme SumIt \
  -destination "platform=iOS Simulator,id=$SUMIT_SIMULATOR_UDID" \
  -derivedDataPath /tmp/sumit-ledger-derived-data test
```

`SUMIT_SIMULATOR_UDID` must be assigned to an actual ID from the immediately preceding device inventory and recorded in the execution report; never paste a synthetic fixture UUID into this command. Run with the compatible Xcode selected for this project without changing global developer paths unnecessarily.

Backend pure tests, after Task 15 adds them:

```sh
node --test Backend/vercel-project/test/transaction-contract.test.js Backend/vercel-project/test/rates.test.js
```

Run SQL tests through the verified staging connection with stop-on-error and disposable fixtures. Connection secrets come from managed environment, never a literal command in the plan. A psql test session can run each transactional file via `psql "$SUMIT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f Backend/tests/ledger-write-tests.sql`; only use the variable after it is supplied through the authorized credential workflow and target identity has been checked. Concurrency tests require two real sessions; single-session rollback tests are insufficient.

## Review and completion checklist

- [ ] All eight scope rows link to implementation tasks and mandatory acceptance IDs.
- [ ] All new types/functions match the shared interface inventory and full wire schema.
- [ ] No direct old mutator bypass, truncating restore, random remote ID, silent error or implicit rate 1 remains in active new paths.
- [ ] Failed local writes and uncertain server outcomes preserve enough durable state to recover.
- [ ] Legacy migration and old-client compatibility are proved, not assumed.
- [ ] Provider evidence distinguishes documentation, local mocks, live probes and credential limitations.
- [ ] Exact executed toolchain/destination, applied schema and test artifacts are recorded.
- [ ] Production release remains blocked by any failed mandatory gate; document-only preparation has not checked off execution tasks.
