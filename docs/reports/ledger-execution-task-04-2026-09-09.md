# Ledger reliability execution — Task 04 (versioned local schema and contract DTOs)

**Date:** 2026-09-09. **Baseline:** `202249998fae5e44f19bb420dbf7b3f58c070ef8`. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **87** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |
| Overall | `** TEST SUCCEEDED **` |

New this task: `LedgerSchemaMigrationTests` 9, `LedgerCodingTests` 17.

## What was added

**New files:** `SumIt/Models/ledger-types.swift`, `SumIt/Models/ledger-sync-models.swift`, `SumIt/Models/ledger-schema.swift`.
**Modified:** `Transaction.swift`, `Wallet.swift`, `Models.swift` (Category, ChatMessage), `Services/storage-bootstrap.swift`.
**Tests:** `SumItTests/ledger-schema-migration-tests.swift`, `SumItTests/ledger-coding-tests.swift`, plus `LedgerFixtures` in test support.

### Frozen V1 is a real frozen copy

`SumItSchemaV1` contains **duplicated definitions** of the five model shapes as the shipped app wrote them, nested inside the versioned schema. This is the part that makes the migration claim meaningful: a store created with today's model types has already migrated, so testing against one proves nothing. The fixture now writes a store using `SumItSchemaV1.Transaction`, `SumItSchemaV1.Wallet` and the rest, exactly as a real device did, and the test then opens those same files under V2 with the migration plan.

That approach was **verified, not assumed** — SwiftData matches the nested V1 entities to the live V2 entities by entity name, and the migration runs.

`SumItSchemaV2` is the live types plus the four synchronization models. The step between them is `.lightweight`, which is legitimate here because every V2 addition is optional or defaulted; nothing is renamed, retyped or dropped.

### Additive fields

Transaction gains `amountExact`, `baseAmountExact`, `rateExact`, `walletID`, `destinationWalletID`, `walletAmountExact`, `destinationAmountExact`, `quoteJSON`, `valuationStateRaw`, `serverRevision`, `localGeneration`, `deletedAt`, `migrationStateRaw`. Wallet gains `openingBalanceExact` and the same synchronization metadata. Category gains `ownerID`, revisions and `deletedAt`. ChatMessage gains `ownerID`. AppSettings is unchanged — preferences stay device-local.

Every old `Double` field is still there and still written. Exact strings are the new authority; the numeric fields survive as compatibility mirrors until Task 14 retires their callers.

### Identity-injecting initializers

`Transaction`, `Wallet`, `Category` and `ChatMessage` now take `id: UUID = UUID()`. Restoring a remote record supplies the identity; only a genuinely new user-created record gets a fresh one. This is the constructor-level half of P1 — the restore loop that used it is Task 12.

### Wire contract

`ledger-types.swift` implements the DTO inventory from `database-and-rollout.md` §4–§6: `LedgerMutationRequest`, `LedgerMutationResult` (accepted/conflict), `LedgerChangePage`, `LedgerChange`, the three record types, the tagged `LedgerSnapshot`, `RateQuote`, `AccountScope`, the three drafts, `LocalSaveReceipt`, `WalletDescriptor` and `WalletEffect`.

Decisions that the tests pin down:

- **Cursors and revisions are strings.** `LedgerCursor` decodes only a nonnegative ASCII-digit string and rejects `-1`, `4.1`, `+1`, whitespace-padded values, and a bare JSON number — the last one specifically, because a number would be coerced through a float somewhere along the path.
- **Monetary fields are validated on decode**, through the same `MoneyCodec` grammar the editors use. `1e3`, `12,5`, `+100`, `100.` and `" 100"` are all decode failures.
- **A malformed date is an error**, never `.now`. That substitution is how a historic transaction silently moves to today.
- **Unknown tags are errors.** An unrecognised `entity_kind`, `action` or response `status` throws. In particular an unknown status cannot be read as an acceptance, which is the exact path by which a failed write becomes a false "synced".
- **A provider quote without its persisted quote ID is rejected**, because there is nothing to verify it against.
- **`source_detail` stays JSON.** `RateQuote` uses a `JSONValue` tree rather than `Data`, so provider metadata round-trips as an object instead of silently becoming base64. A test re-encodes and asserts the field names are still there.
- **Conflicts are a domain outcome**, decoded from an HTTP success with `status: "conflict"`, carrying both revisions and the server's full snapshot.

### The four synchronization models

`PendingMutation` (durable queue entry with frozen request bytes, predecessor link, state, attempts and a **code-only** last error), `SyncCheckpoint` (applied cursor plus adoption version), `SyncIssue` (conflict / legacy ambiguity / invalid remote row, keeping both candidates), `CachedRateQuote` (immutable dated quote rows). A test writes one of each, closes the store, reopens it and reads them back.

`#Index` was **not** used: it requires iOS 18 and the project's minimum is iOS 17, which the plan says to preserve. Lookup fields are plain stored properties for now.

## What migration deliberately does not do

`testMigrationDoesNotDeriveLedgerValues` asserts that after the upgrade every transaction still has `amountExact`, `baseAmountExact`, `rateExact`, `walletID`, `quoteJSON` and `deletedAt` **nil**, revisions at 0, `valuationState == .legacyUnverified` and `migrationState == .legacy`; every wallet still has `openingBalanceExact` nil; no category has been given an owner.

That is the point. Converting a schema is mechanical. Deciding that a 12.50 `Double` is exactly 12.50, that a wallet's current balance can be read backwards into an opening balance, or that an inherited `rateAtTime` was a real quote — those are semantic judgements about someone's money, and they belong to Task 18's adoption flow with the owner involved, not to a silent migration on app launch.

## Checklist status

- [x] Frozen V1 proven to open a real V1 store before V2 was added.
- [x] Optional exact fields and metadata added with safe defaults; old fields, IDs, owners and dates preserved.
- [x] Four new local models added, explicitly included in the V2 schema and registered in the Xcode target. No iOS 18-only macros.
- [x] Full Codable DTO inventory; cursors as decimal strings mapped to bounded `Int64`; monetary values as canonical strings; unknown tags are decode errors.
- [x] Identity-injecting initializers on Transaction, Wallet, Category (and ChatMessage), with a default UUID only for new records.
- [x] Null handling for owner/date/quote tested; migration rerun proven idempotent on disk; records needing reconciliation stay in `legacy` state.
- [x] `LedgerFixtures` draft factories added, closing the last open Task 00 item.

## Still not claimed

- The migration is proven against the **synthetic** V1 baseline, not against a real user's device store. A device store may contain rows this fixture does not model (odd currencies, missing links, very large chat history); Task 18's inventory is where that is faced.
- No DTO has been exchanged with a real server. The SQL side (Tasks 05–07) does not exist yet, so these types are validated against the contract document only.
- Nothing calls the new drafts or the sync models yet. `AppStore` still saves the old way, and no behaviour visible to a user has changed in this task.
