# SumIt ledger reliability — design and execution contract

**Date:** 2026-09-09. **Baseline:** `202249998fae5e44f19bb420dbf7b3f58c070ef8`, current `main`.

**Status:** proposed design for the explicitly requested eight-issue implementation plan. Documentation only; not an authorization to deploy, migrate production, or repair user records. Read `implementation-plan.md`, `database-and-rollout.md`, and `acceptance-tests.md` alongside this document.

## 1. Exact scope

The eight numbers refer to the numbered problems in the previous audit response, not the first eight F-numbers in the full audit.

| User item | Problem | Audit finding | Required outcome |
|---|---|---|---|
| P1 | Restore creates duplicates | F02 | Stable identity and repeatable restore across restarts |
| P2 | Failed saves appear successful | F03 | Acknowledgments reflect durable local and remote outcomes |
| P3 | Editing removes fractional amounts | F05 | Exact money survives every edit, serialization and migration |
| P4 | Decimal commas split transactions | F06 | Amount punctuation never creates another transaction |
| P5 | Transfers debit only one wallet | F07 | One atomic transfer affects two explicitly selected wallets |
| P6 | Deletes and multi-device changes diverge | F04 | Durable retries, deletion records, revisions, conflicts and complete pull |
| P7 | FX/crypto rates are fixed constants | F08 | Attributed, dated, preserved quotes; explicit missing/stale behavior |
| P8 | Database-open failure uses volatile storage | F09 | Safe recovery surface with preserved store and disabled writes |

Necessary dependencies are included: account scoping, complete restore pagination, constraint/grant verification, repeatable test setup, access to restored records, and migration of existing data. They prevent a nominal fix of the eight issues from remaining incorrect. Subscription/payment work, PIN cryptography, a general UI redesign, bank integrations, analytics, privacy-policy authoring, budgeting and a new platform are outside this workstream. Their audit findings remain open.

## 2. Strategy and alternatives

**Chosen approach: retain SwiftUI, SwiftData, Supabase REST and the existing models; introduce exact monetary fields, one durable local mutation path, a bounded synchronization protocol, and a tested migration.** The existing views continue to operate through AppStore. A small LedgerStore owns financial writes; SupabaseService remains the HTTP transport. A LedgerSyncCoordinator serializes sync. Transfers remain one transaction record with two wallet references, avoiding half-written transfer pairs.

Alternatives considered:

| Approach | Benefit | Reason not selected |
|---|---|---|
| Patch UUID assignment, add HTTP checks and keep current sync | Quick initial fixes | Cannot resolve concurrent edit/delete, replay, persisted deletion and independent balance overwrites |
| Retain app and add a durable mutation/revision protocol | Fits current code and offline needs; testable lifecycle | More work than isolated fixes, but directly required by P1/P2/P5/P6 |
| Replace persistence/backend or adopt a third-party sync platform | Could supply parts of replication | Adds migration/dependency risk, credentials and architecture work unrelated to the eight fixes |

No generic repository framework, vendor plugin installation, queue service, Redis, scheduled worker or event-sourcing platform is proposed. The remote change feed is a synchronization record, not a second accounting ledger. New files listed in the plan have immediate responsibilities and tests.

## 3. Invariants (release requirements)

- **I01 Identity:** `(owner, entity kind, local UUID)` identifies an entity forever. Remote database primary keys are transport IDs, not replacement local UUIDs.
- **I02 Exact money:** amounts, wallet effects and rates have canonical decimal strings locally/on the wire and exact NUMERIC values in PostgreSQL. Double is permitted only in compatibility mirrors and chart rendering.
- **I03 Durable mutation:** entity change, related saved chat reply and queued sync intent commit together locally. Failure leaves all three unchanged.
- **I04 Truthful state:** “Saved on this device” requires a successful persistent save; “Synced” requires acknowledgment of the current generation plus successful local acknowledgment persistence.
- **I05 Replay:** retrying an operation ID with the same frozen payload returns the same acceptance; it creates neither another entity nor another balance effect. Different payload with that ID is rejected.
- **I06 Conflict:** an update/delete must match the last known server revision. Two devices never silently overwrite each other's accepted edits.
- **I07 Deletion:** delete intent persists before disappearance is confirmed. Remote deletion records reach other devices. Old edits never resurrect a deleted identity automatically.
- **I08 Wallet balance:** opening balance plus current, nondeleted transaction effects is the authoritative formula. A transaction does not upload a separately editable absolute wallet balance.
- **I09 Transfer:** source and destination reference different, active wallets belonging to the same owner. Both quantities are positive and committed in one record/mutation. Transfers do not inflate income/expense totals.
- **I10 FX provenance:** a saved conversion includes its rate, provider/manual source and effective time. Metadata-only edits never reprice it. Missing FX never becomes rate 1, amount 0 or an invisible omitted record.
- **I11 Scope:** each query, queued operation, response and sync checkpoint belongs to a captured account scope; responses from a previous scope cannot mutate the active scope.
- **I12 Recovery:** persistent-store failure never opens a writable in-memory substitute. Retry/export/recovery do not erase the original store.
- **I13 Complete pull:** all pages through a fixed server watermark are applied durably, including tombstones. Cursor and page changes commit together.
- **I14 Legacy preservation:** ambiguous old records are preserved and identified for reconciliation. Matching amount/date/merchant is not proof that two operations are duplicates.
- **I15 Offline:** a previously initialized account can save/edit/delete offline in its persistent store. Loss of networking or an expired token does not discard the mutation.

## 4. Identity, owner and local schema

### 4.1 Schema migration

Freeze the five current SwiftData model shapes as V1, including every original property and default. First prove that an actual store produced by the baseline app opens using the frozen version. Add V2 optional fields and the new local models through a SchemaMigrationPlan. Do not add a uniqueness constraint to existing dirty records before reconciliation. Do not require iOS 18 history APIs or newer macros: preserve the existing iOS 17 minimum unless the user explicitly changes it.

Keep the old Double properties during migration; new code writes compatibility mirrors from exact values, never the reverse after a row is upgraded. Persist exact numeric fields as strings to avoid opaque Decimal transformables in the SwiftData store. Parse into Foundation Decimal only at computation boundaries. Every persisted decimal string is canonical: dot separator, no grouping, no exponent, no leading plus, no unnecessary trailing fractional zeros, and zero represented as `0`.

Proposed additive fields (these are new design names, not claims about the live schema):

| Local model | Additions | Purpose |
|---|---|---|
| Transaction | `amountExact`, `baseAmountExact`, `rateExact`: String? | Original quantity, USD booked amount, USD per original unit |
| Transaction | `walletID`, `destinationWalletID`: UUID? | Stable wallet relationships |
| Transaction | `walletAmountExact`, `destinationAmountExact`: String? | Frozen effect quantities in each wallet's currency |
| Transaction | `quoteJSON`: Data?, `valuationStateRaw`: String | Quote provenance; valued / unvalued / legacyUnverified |
| Transaction | `serverRevision`: Int64 = 0, `localGeneration`: Int64 = 0, `deletedAt`: Date? | Version, current local generation, persistent deletion |
| Transaction | `migrationStateRaw`: String = `legacy` | Separates an old record from a validated new record |
| Wallet | `openingBalanceExact`: String?, `serverRevision`, `localGeneration`, `deletedAt`, `migrationStateRaw` | Derived balances and synchronization metadata |
| Category | `ownerID`: String?, `serverRevision`, `localGeneration`, `deletedAt` | User-owned custom categories; defaults remain local templates |
| ChatMessage | `ownerID`: String? | Prevents retained messages crossing accounts |
| AppSettings | No mandatory ownership migration | App preferences remain device-local; profile data stays separate |

`Transaction.userId` and `Wallet.userId` retain their existing names. Do not normalize unknown owner strings into the current user. The special old owner `local` is eligible for an explicit import into the account after sign-in; it is not a server owner.

New persisted models:

- **PendingMutation:** operation UUID; owner; entity kind; entity UUID; local generation; predecessor operation UUID if any; desired entity snapshot; frozen request JSON once dispatch begins; state; attempt count; next attempt time; last non-sensitive error code. The queue is durable, never a Task collection or UserDefaults list.
- **SyncCheckpoint:** owner; applied server cursor; migration/adoption version. Cursor starts at zero for a fresh synchronized dataset.
- **SyncIssue:** owner; entity key; kind (`conflict`, `legacyAmbiguity`, `invalidRemoteRow`); local candidate snapshot; remote candidate snapshot if present; reason; created time. This is the durable basis of recovery/conflict UI; it is not log telemetry.
- **CachedRateQuote:** exact rate, base/quote currencies, provider, provider timestamp, fetched time, requested valuation date, source metadata and expiry policy. One quote type also serves transaction provenance.

All new models must be explicitly included in the Xcode source phase and V2 schema. Default categories are not uploaded individually for every user. Custom categories are owner-scoped; deleting one archives its definition while historical transaction category text remains readable.

### 4.2 Import and UUID rules

Parse remote `local_id` into UUID and compare UUID values, not case-sensitive strings. Initialize models with that UUID. A missing/invalid remote `local_id` is a migration issue; do not generate a new one during every read or substitute the remote primary key without a persisted mapping.

During legacy adoption, take a complete remote snapshot and inventory local records before uploads begin. A local UUID matching a remote UUID is a strong identity match. A formerly restored local copy whose UUID differs cannot safely be deduplicated by content; surface a reconciliation issue and retain both snapshots. No automatic batch deletion, rewriting of owners, or aggressive fuzzy merge. Previously overwritten cents or never-persisted records cannot be reconstructed from absent evidence; use an actual backup/raw input plus explicit owner confirmation where available, and otherwise record the limitation.

Incoming data must explicitly include its owner. A missing or different owner is a decode/ownership failure, not a reason to fall back to `AuthService.shared.userId`. Remote dates must decode or produce an issue; do not replace malformed historic dates with `.now`.

### 4.3 Scope changes

Add `AccountScope(ownerID: String, epoch: UUID)`. AuthService publishes a new epoch for sign-in/sign-out/user change. A refresh of the same account keeps its epoch. Capture the epoch before refreshing; if it changes while the network call runs, discard that refresh result before saving a session or publishing signed-in state. A delayed refresh must not sign a previous user back in. LedgerStore rejects writes outside its scope; pending operations record the owner before any await.

Preserve the existing device-only `local` dataset as an explicit signed-out scope. New manual/draft-confirmed local entries may use the same exact persistent command path, but the coordinator never dispatches owner=`local` to Supabase and cannot claim cloud synchronization. Signing out does not expose the previous authenticated owner's retained history as the local dataset. A later explicit import inventories these local rows and creates owner-bound mutations after reconciliation; never rewrite the owner of an already-frozen request. Authenticated network-only AI/rates retain their actual auth requirement; manual/identity/unvalued paths provide offline functionality without inventing anonymous API access.

RootView rebuilds scoped child views when owner changes. Transactions, wallets, custom categories and chat queries filter owner and deletion status. Defaults are shared templates. On sign-out, stop the coordinator; a late response may only be applied after rechecking its owner/epoch. Keeping local data is allowed, but it is invisible under another account. Wipe checks pending writes and offers an explicit loss warning in the existing flow; it is never used to resolve a server conflict automatically.

## 5. Monetary semantics

### 5.1 Input and arithmetic

Extend existing Formatters and add a focused AmountParser; do not introduce a numeric dependency. An input amount must be finite, strictly positive, less than or equal to the current explicit product limit of `1e12`, and within currency precision. Zero is valid for opening balances; negative opening balances are valid debt balances. New invalid input is rejected rather than silently capped, made positive or replaced by the previous value.

Proposed entry precision: JPY 0; remaining supported fiat 2; USDC/USDT 6; BTC 8; ETH 18 fractional digits. These are application ledger precision decisions, not a claim of bank/exchange execution precision. Preserve legacy values outside the new precision unchanged until corrected; metadata edits are allowed without rounding them. Rates and USD base amounts retain up to 18 decimal places; calculate the booked base as amount × rate, explicitly half-even quantized to scale 18, and validate the submitted value against that result in the server RPC. PostgreSQL numeric round alone uses a different tie rule: implement/test the shared half-even rule with exact numeric quotient/remainder, not float casts. If a positive product quantizes to zero, require unvalued/manual correction instead of silently recording a zero valuation. All 18-scale bounds apply before persistence; final user-visible fiat rounding uses bankers' rounding. Validate arithmetic range before persistence and surface overflow; do not ignore NSDecimal calculation errors. Use NUMERIC(38,18) for new server quantities/rates and a consistent documented maximum absolute base amount of `1e18`.

`AmountParser.parse(text:currency:locale:allowNegative:allowZero:)` consumes the **whole string**. Never accept a prefix or delete arbitrary punctuation. Support ordinary space, nonbreaking space and narrow nonbreaking space only as validated digit grouping. Normalize digits only through an explicitly tested locale mapping; unsupported input yields a clear validation error.

- App locale decides ambiguous single separators: `1,000` in en-US is 1000; in de-DE it is 1. A confirmation UI always shows the normalized number before saving.
- `12,50` in de-DE/pl-PL/ru-RU/uk-UA and `12.50` in en-US parse as 12.5.
- Accept the alternative decimal separator only when it cannot be valid grouping for that locale; do not guess `1.000` when both interpretations are plausible.
- Grouping must be consistent: `1,234,567.89` (en-US), `1.234.567,89` (de-DE), `1 234,56` (pl-PL) valid; `1,23,456` invalid for these supported locales.
- Reject empty, whitespace-only, currency words inside an amount field, NaN/infinity, exponent notation in editable fields, malformed grouping, mixed unrecognized separators and trailing garbage.

Keep the original exact string in edit state. Editing merchant/date/note without changing the amount field must preserve the stored amount byte-for-byte after canonicalization. Remove `%.0f`, wallet `%.2f` initialization, permissive Double parsing with old-value fallback, and silent caps from all financial editor paths. Decimal → Double conversion occurs only when supplying chart coordinates, never when saving.

### 5.2 Chat segmentation

A segment boundary is newline, semicolon, explicit spaced ` + `, or comma **not directly between two decimal digits**. Commas between digits remain inside a number token. The delimiter scan precedes sanitization, since current sanitization removes newlines. Do not split on `and`/language conjunctions.

Run segmentation on normalized line endings; trim outer whitespace; preserve each segment's original index. If there are fewer than two nonempty segments, send the original input. Do not discard a segment merely because it has no digit: `ten dollars coffee; 20 taxi` contains two intended segments. Each submitted segment gets a visible outcome, and failures retain text for retry.

`12,50 EUR coffee` and `1,000 USD rent` remain one segment. `10 coffee, 20 taxi` and `10 coffee; 20 taxi` become two. `10 coffee,20 taxi` also splits because the comma is not between two digits. `10,20` remains one ambiguous numeric input. If a comma in merchant text creates ambiguity, show the segmentation preview and allow correction rather than silently losing a chunk. Maximum segment count is 20; exceeding it is a validation error before any paid parse. Each segment retains the existing 500-character server limit; no silent truncation.

During a pending batch, text/photo input cannot replace the unconfirmed queue without explicit discard. Photo actions respect loading state. Bind ConfirmationCard to the current draft and ensure `selectedWalletId=nil` actually clears the selection. “Cancel edit” leaves the draft unchanged; saving uses the latest selection, not a stale captured value.

### 5.3 AI response compatibility

Add `contract_version=2` and locale/date/timezone context to new client parse requests. Server v2 requests require an exact amount string in model output and validate it. Respond with additive `amount_decimal` plus the legacy numeric `amount` field for old clients. New clients use `amount_decimal` as authoritative and reject a malformed v2 field; do not fall back to Double. Legacy responses remain supported only through an explicitly labeled import/compatibility conversion path.

Preserve the existing model allowlist and payment behavior; model-tier enforcement is a separate audit workstream. Both text and photo parsing must share the same amount/type/currency validation helper. Do not silently coerce unknown transaction types to expense. A transfer parser may suggest wallet names; the user must resolve source/destination IDs and both amounts before save. AI never invents a live exchange rate or a wallet opening balance.

## 6. Wallet and transfer accounting

### 6.1 One authoritative balance

For wallet W:

```text
balance(W) = openingBalance(W)
           + sum(income.walletAmount for income.walletID == W)
           - sum(expense.walletAmount for expense.walletID == W)
           - sum(transfer.walletAmount for transfer.walletID == W)
           + sum(transfer.destinationAmount for transfer.destinationWalletID == W)
```

Only active, same-owner records participate; pending local edits are included as the local desired record, not added again as queue events. Deletion removes the record's contribution. An edit replaces old effects with new effects by recomputation; there is no accumulating save/delete delta drift.

Retain `Wallet.balance` as a derived compatibility/display cache during migration only. Never enqueue a wallet update because a transaction changed its derived balance. Wallet revision protects metadata/opening balance, not the total. A pure calculation function is shared by reports, editors and reconciliation tests.

For a new wallet, the entered balance is its opening balance. For an existing wallet, expose “Opening balance” and computed “Current balance” separately. Correcting opening balance is a versioned wallet edit. Do not reinterpret a current balance as opening balance. Currency becomes immutable once linked transactions exist; offer creating another wallet instead. Names may duplicate; selections show enough currency/type context and use UUID tags. Renaming changes labels, not relationships.

Wallet deletion is archive semantics: hide it from new-entry choices, retain it and its historical effects. New edits cannot newly reference an archived wallet. Existing transactions remain inspectable and deletable. Changing historical metadata on an existing archived-wallet transaction is permitted without altering its stored effect. No cascading transaction deletion.

### 6.2 Transfers

One Transaction of type transfer stores `walletID` (source), `destinationWalletID`, positive `walletAmountExact`, positive `destinationAmountExact`, original currency/amount, date and provenance. For this type, original currency and amount equal the source wallet currency and source quantity. A transfer has a neutral category display and zero contribution to expense/income totals. Count it once.

Same-currency transfer: destination amount must equal source amount. Cross-currency transfer: the actual source and received amounts are explicit and can define the executed exchange ratio; a market quote is only a dated suggestion. Never compute a destination silently from a current price after save. Fees are ordinary separate expense entries in this scope; do not infer a fee from unequal cross-currency legs or add an unrequested multi-leg fee subsystem.

For income/expense with no wallet, both wallet reference and wallet effect are null; destination fields are always null. In a wallet matching the original currency, the wallet effect equals the original amount exactly. For a non-transfer transaction in another currency than its wallet, `walletAmountExact` is the explicitly confirmed wallet-currency effect, with cross-rate provenance when suggested. A quote outage can still allow an exact wallet effect entered by the user. Editing transaction amount/currency or wallet selection requires reconfirming the affected wallet amount; editing only metadata preserves it.

Remote put validates both wallet references under the transaction owner's scope and commits the transfer row/change record/receipt atomically. Since both legs are in one row and balances are derived, there is no partial second-leg upload.

### 6.3 Existing balances and transfers

Do not set every opening balance to zero or replay old deltas on top of a stored current balance. After resolving identity and completeness, calculate the migration opening balance as the chosen observed current balance minus all imported known effects. Freeze that baseline with provenance. If device/cloud balances disagree, or the old currency/rename/transfer history prevents a unique interpretation, create a migration issue and ask the owner to reconcile; neither source is automatically authoritative.

Old one-sided transfers are preserved in the legacy working copy and a durable migration issue. Do not infer a destination from a merchant/name or create a second leg silently. The user can supply the missing destination and amounts in a repair flow. Until resolved, show the existing legacy balance baseline and a clear incomplete-history warning; keep canonical cloud adoption blocked for that account. Do not publish an invalid one-sided transfer into the v1 feed. Legacy rate uncertainty alone may remain `legacyUnverified` after adoption because it does not invalidate stable identities or native wallet effects.

## 7. Local writes and synchronization

### 7.1 Mutation boundary

`LedgerStore` is a concrete @MainActor service owning the financial ModelContext. Disable autosave on the shared financial context after routing every current direct save through explicit checked methods. Editors hold value drafts, not partially modified live SwiftData entities. Do not await networking while a local mutation is open.

A local command validates a captured scope and typed draft, fetches the current entity by owner and UUID, changes it, increments its local generation, creates a PendingMutation, and updates/inserts the saved reply in one `ModelContext.transaction` or explicitly tested save/rollback sequence. If persistence fails, rollback, keep the edit draft, and show a storage error. Do not attempt to save a “success” message in a second transaction after a failed first one. SwiftData rollback discards all pending context changes, so incidental unsaved settings/chat mutations must be isolated or explicitly committed before financial commands; unrelated pending edits must never share this boundary.

`AppStore` forwards view actions to LedgerStore and publishes totals/categories/sync state. Remove fire-and-forget Supabase mutation tasks from AppStore, WalletViews, CategoryManager and ProfileEditView. All writes use the same durable queue. Chat text not associated with a saved operation remains local and explicitly checked; full cloud chat backup is outside scope.

### 7.2 Queue and acknowledgment

Process one operation per owner at a time initially; no concurrency tuning knob. Multiple local edits to one entity append intents with predecessor links. Do not coalesce them in the first implementation. Referencing a newly created local wallet also adds a cross-entity dependency: the wallet creation must be durably acknowledged before the transaction dispatches. A failed/archived dependency blocks only dependent transactions and remains visible; it is never bypassed by name matching. Before first send, materialize `expected_revision` from the acknowledged predecessor/current baseline, freeze the JSON envelope, and persist `inFlight`. Retry always uses those exact bytes and operation ID. A newer local edit cannot mutate the frozen request.

An acknowledgment transaction removes/completes that exact operation, records the accepted server revision, and releases its successor. Only replace visible entity data with the accepted snapshot when its local generation still equals the acknowledged generation. Otherwise preserve the newer draft and pending status. Persist the acknowledgment before advancing the queue. If that save fails, retry the same remote operation; server receipt replay returns the acceptance again. Startup returns persisted `inFlight` operations to retry using their frozen envelope.

Queue triggers: local commit, first successful sign-in/adoption, app foreground, recovered network path and explicit Retry. Network monitoring is a trigger, not proof the internet works. Coalesce triggers into one task; `isRunning`/task identity is set before awaiting. No overlapping startup and sign-in restore loops.

### 7.3 Protocol

New server identifiers are proposed, versioned interfaces:

- `apply_ledger_mutation_v1(p_request jsonb) returns jsonb`
- `read_ledger_changes_v1(p_after_cursor bigint, p_through_cursor bigint default null, p_limit integer default 250) returns jsonb`
- Supporting `ledger_sync_state`, `ledger_mutation_receipts`, `ledger_change_log` tables; details in `database-and-rollout.md`.

Use authenticated Supabase RPC from the existing actor; no new ledger Vercel proxy or client service-role key. Derive owner from auth.uid(), not a client argument. Server functions validate every field, check wallet ownership, compare expected revision and return explicit receipts/conflicts. Security-definer functions require fixed search_path, schema-qualified objects, explicit authentication checks and restricted execute grants.

Per-owner sync-state row locking serializes revision allocation and mutation acceptance. Increment its cursor and write the entity, receipt and change event in the same SQL transaction. Do not use an unlocked sequence or client timestamp as a pull watermark: allocation is not commit order. A mutation's row revision equals its accepted owner cursor. A delete retains identity/revision and deletion timestamp. A new put on a tombstoned UUID is rejected.

Request, response and conflict examples are specified in the database document. Client-generated transaction ID is independent of operation ID: editing the same entity generates another operation, not another transaction UUID.

### 7.4 Error behavior

| Outcome | Required client behavior |
|---|---|
| DNS, no connection, timeout, HTTP 408/429/5xx | Retain operation; retry with jitter at 2s, 10s, 30s, 120s, then at most every 5 minutes while foreground; honor bounded Retry-After |
| 401 | One serialized session refresh, retry frozen operation once; if still unauthorized, pause and offer sign-in; preserve all local data |
| 403 | Block operation and show access problem; do not retry forever or mark synced |
| Malformed/empty response where a receipt is required | Treat as unknown outcome; preserve frozen operation and retry idempotently |
| Valid conflict result | Persist remote/local candidates; block this aggregate and dependent operations; continue independent aggregates |
| Validation rejection | Preserve draft/intention in SyncIssue, explain field, allow correction into a new operation |
| Duplicate operation ID, changed payload | Protocol error; retain evidence and stop that operation |
| Local commit/ack/cursor failure | Roll back local work; stop sync until persistent storage is usable |
| Scope changed during await | Discard active-scope application; keep old owner's durable queue for a later session |

A retry attempt cap is not a deletion policy. No unsynced intent is removed merely because it has failed many times. Generic “sync enabled” is replaced with accurate pending/conflict/offline state and counts. Log status/code/count/latency only; do not log receipts, merchant notes, account tokens or financial payloads.

### 7.5 Pull, conflicts and restore

A pull starts by obtaining a fixed `through_cursor`; each subsequent page carries it. Pages contain at most 250 change records in cursor order, including deletion records and full current-at-that-change entity snapshots. Wallet/category rows needed by a transaction must be applied or retained as deferred references; never silently drop the transaction. Commit each page and its next cursor together. On failure, replay the page. No hard limit of 1,000 on the complete run.

An event at or below the entity's durably acknowledged server revision is a known historical event: validate its envelope and advance the page cursor, but never roll the entity back. Persist completed operation IDs/revisions locally until the pull cursor has passed their events, so an own-operation event can be recognized after a process restart. Clean local entity + newer remote revision: apply remote. Same revision: no-op. Local pending changes + different remote revision: retain local candidate and create conflict, except an event known to be the client's own acknowledged operation. A remote delete wins visibility and blocks old updates, but the unsaved local candidate remains available for recovery.

Conflict UI presents actual changed fields and the remote/local amounts. “Use server version” cancels queued descendants for that entity and preserves the discarded candidate as a recoverable local draft until explicitly dismissed. “Keep my version” creates a new operation against the freshly read remote revision; it can conflict again if another write intervenes. Recreating a remotely deleted transaction requires an explicit “Save as new transaction” action with a new UUID. Do not auto-merge money fields or use client clocks as the tie-breaker.

Provide a simple complete transaction list in Reports using existing TxRow/editor patterns. It must reach restored records and their sync issues without relying on cloud chat history. This is a repair/recovery dependency, not a redesign.

## 8. Rate service and valuation

### 8.1 Recommended provider routing

Use one concrete fiat integration and one concrete crypto integration inside `Backend/vercel-project/api/_lib/rates.js`, exposed through authenticated `GET /api/rates`. RateService uses an added checked GET method in the existing BackendService actor, retaining its endpoint/auth configuration instead of inventing a second independent HTTP client. No generic provider factory. Existing Vercel/Supabase services handle authentication/cache; no new hosting product.

- Fiat: Frankfurter v2, official documented `GET https://api.frankfurter.dev/v2/rates?base=USD&quotes=EUR,UAH,GBP,PLN,CZK,CAD,CHF,RUB,KZT,JPY`, optional `date=YYYY-MM-DD`, `expand=providers`. Documentation describes current and historical fiat rates without an API key. Public probes during planning returned HTTP 403 / error 1010 for both latest and historical requests; this provider is **documented but not runtime-qualified**. The execution task must verify it from the intended server environment and verify all ten non-USD fiat codes. Do not claim that the endpoint works based on this plan.
- Crypto and stablecoins: CoinGecko Demo `/simple/price`, USD quote, `include_last_updated_at=true`, exact coin IDs resolved against `/coins/list` by expected name and symbol. Demo authentication is `x-cg-demo-api-key`; none was supplied or used. `/coins/{id}/history` date availability and account limits must be probed with the owner's allowed account before historical crypto quotes are promised. Do not pin a stablecoin to USD=1. Coin IDs are registry-derived execution outputs, not guessed constants in this plan. Historical crypto uses the documented dd-mm-yyyy date format and represents a 00:00 UTC snapshot, not a purchase execution price; qualify its actual account-specific date range.

Provider registration, paid upgrades or access purchases are not authorized by this planning request. If the selected provider cannot be qualified, the executor completes the defined manual/unvalued workflow and reports the automatic-quote acceptance gate as blocked; it must not substitute another vendor or mark P7 fully finished. The earlier ExchangeRate-API research was considered but not selected because this design needs historical fiat values as well as current rates.

### 8.2 Contract and cache

Each provider quote has a server-issued quote_id persisted in the rate cache; manual/identity quotes have no provider ID. The write RPC verifies referenced provider quote values against that row. A rate is `USD per one unit of currency`. USD is exactly 1 with source `identity`; other currencies have no fallback 1. Normalize fiat provider `1 USD = X currency` to `1/X`; crypto `/simple/price` already reports USD per unit. Do not invert twice. Date ranges and current data are separate cache keys.

```json
{
  "quote_id": "50000000-0000-4000-8000-000000000001",
  "currency": "EUR",
  "usd_per_unit": "1.08",
  "requested_date": "2026-05-19",
  "effective_at": "2026-05-19T00:00:00Z",
  "fetched_at": "2026-09-09T12:00:00Z",
  "source": "frankfurter",
  "source_detail": {"base":"USD","quote":"EUR","providers":[]},
  "valuation_kind": "historical_reference",
  "stale": false
}
```

Numbers and timestamps above are synthetic contract examples, not actual market values. `source_detail.providers` contains provider-returned identifiers when available; the empty array in this synthetic example invents no provider ID.

Validate base/quote identity, positive finite rate, range, requested/effective dates, future timestamps (maximum five-minute clock tolerance), and provider response structure. An HTTP 200 is not enough. Monetary amounts never pass through JS Number. Provider JSON prices are reference observations: normalize a finite positive numeric quote once to 15 significant digits using Number.toPrecision(15), record this normalization in provenance, expand exponent notation to a canonical decimal string, and do all reciprocal/rate arithmetic with scaled BigInt strings. This deliberate quote-resolution policy is separate from exact user amounts (including 18-digit ETH quantities); it does not claim to preserve every digit of a provider numeric literal. Never use JS Number arithmetic to calculate a ledger amount. Rates cache writes are server-only, bounded to the 15 supported currencies and single requested date per call. Requests include currencies/date only, never transaction text, merchant, amount, photos or wallet names.

Cache policy: current fiat refresh target 24 hours; automatically usable up to 96 hours of provider age to tolerate weekends, with actual timestamp shown. Current crypto refresh target 5 minutes; automatically usable up to 15 minutes. Older cached quotes require explicit user confirmation and are labeled stale. Historical fiat may use the provider's previous business-day observation only if it is no later than the requested date and no more than seven calendar days earlier; show its actual effective date. Never fill missing historical crypto from today's price. Rate quote rows are immutable. A corrected historical observation produces a new quote ID while the old row remains resolvable; cache lookup may select the newer observation for a new draft, but a later provider correction does not rewrite booked records.

### 8.3 Saving without a quote

USD entries need no remote rate. For another currency, offer: a validated dated quote; an explicitly entered manual rate; or save the original amount with `valuationState=unvalued`. The third option requires an exact wallet effect if the wallet uses another currency; otherwise leave the operation unassigned to a wallet. A transfer's two actual wallet amounts remain sufficient even if USD valuation is unavailable.

Reports show original-currency totals plus a clear incomplete-conversion count. Never silently omit unvalued entries while labeling the USD total as complete. Metadata-only edits preserve the rate snapshot; changing amount can reuse the same confirmed quote and recompute base amount; changing date/currency requires an explicit keep-old-rate or obtain-new-rate decision. Manual rate is positive and records user confirmation. Filling an unvalued record is a new versioned edit, not a hidden background mutation.

Booked financial reports sum saved USD valuations; changing display currency uses a separately labeled current display quote. Wallet balances remain in native currency. Market movement must not rewrite historical income/expense. Legacy placeholder valuations remain `legacyUnverified` with their original stored numeric values until explicitly revalued; do not silently “correct” past reports en masse.

## 9. Storage bootstrap and failure recovery

StorageBootstrap owns startup state: `opening`, `ready(ModelContainer)`, or `failed(StorageFailure)`. Build RootView only in ready. A failure screen does not depend on a ModelContext and can appear under the existing privacy lock. It offers Retry and Export recovery copy, with clear copy: “We could not open your saved data. Your files have been kept. New entries are disabled.” No reset/delete button is introduced by this workstream.

Resolve and record the existing SwiftData configuration/store location rather than constructing a new empty path that appears to lose data. Before attempting a schema migration, preserve a consistent recovery copy of the complete store bundle, including WAL/SHM when present; never copy only the main SQLite file or make a live, inconsistent copy. Prefer a closed store and an atomic sibling directory copy, or a verified supported backup mechanism. Record the source path, timestamp, schema version and file hashes locally without uploading it. Backups contain sensitive data; use file protection and explicit user-selected export destination. Do not attach real backup files to this public repository.

If the user chooses export while the store is inaccessible, export raw recovery files without claiming a readable transaction export. On retry do not schedule sync or reopen a second competing container. Low disk, permission errors, unsupported schema and deliberate corruption have separate test fixtures. No automatic reset, overwrite, downgrade of schema, or upload of an empty replacement dataset.

## 10. Execution constraints and readiness gates

- Remain on the current branch. New branches/worktrees require the user's explicit confirmation. Do not create a PR unless asked.
- Use `superpowers:executing-plans` for later execution. Do not invoke subagent-driven development or spawn agents without explicit authorization.
- English in artifacts/code/comments. Preserve existing Swift naming where consistency wins; use kebab-case for new file names.
- No production migration is executed from this planning package. During authorized execution, record additive migrations and apply them to the verified target immediately as a paired operation; never apply a shape-breaking change to active legacy clients.
- Do not run `Backend/supabase_migration.sql` as a bootstrap/repair script: it deletes rows and is not a full schema.
- No secrets in code/docs/logs. New API keys follow the vibe-os credential workflow; the supplied Apple key is irrelevant to these eight fixes.
- No new formatter, unreviewed plugin/skill/MCP, general framework or automatic paid service signup.
- Preserve old data and current offline state before cutover. Never “repair” duplicates by matching similar content alone.
- Gate G0: compatible full Xcode, discovered simulator, baseline store fixture and build evidence.
- Gate G1: live schema/grants/constraints inventory and known test account; current Supabase address was unavailable in the audit.
- Gate G2: verified legacy import and rollback/recovery copies; no unexplained balance deltas.
- Gate G3: all ledger acceptance tests pass locally and on staging with two accounts/devices.
- Gate G4: intended rate providers qualified and credential/terms conditions met; otherwise automatic FX remains explicitly incomplete.
- Gate G5: coordinated upgraded-client pilot, tested backup restore and forward-fix rollback procedure before production adoption.

## 11. Primary references checked during planning

- [Apple ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext): autosave, save and rollback scope.
- [Apple save/transaction APIs](https://developer.apple.com/documentation/swiftdata/modelcontext/save()): persistence is explicit and throwing.
- [Apple versioned schemas and migration](https://developer.apple.com/videos/play/wwdc2025/291/): freeze schema versions; verify API availability against iOS 17.
- [PostgreSQL explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html): transaction locks for serialization.
- [PostgreSQL GRANT](https://www.postgresql.org/docs/current/sql-grant.html): table grants survive column revokes.
- [PostgREST upsert](https://docs.postgrest.org/en/v12/references/api/tables_views.html#on-conflict): conflict target matches a real unique constraint.
- [Frankfurter v2](https://frankfurter.dev/): documented fiat endpoints; runtime probes are in `rate-provider-probes.json`.
- [CoinGecko historical snapshot](https://docs.coingecko.com/demo/reference/coins-id-history): documented daily snapshot/date semantics; actual account access unverified.
- [CoinGecko Demo price](https://docs.coingecko.com/demo/reference/simple-price), [coin registry](https://docs.coingecko.com/demo/reference/coins-list): authentication, IDs, USD quotes and update times.

These references establish API semantics, not a successful SumIt build or production qualification. Recheck provider terms/limits and SDK availability at execution time.
