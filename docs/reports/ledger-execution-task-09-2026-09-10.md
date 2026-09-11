# Ledger reliability execution — Task 09 (atomic local commands, P2)

**Date:** 2026-09-10. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **135** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |
| Overall | `** TEST SUCCEEDED **` |

New this task: `LedgerStoreTests` 18.

## The defect, in the code

`AppStore.saveConfirmed` ended like this:

```swift
do { try ctx.save() } catch { Log.error("Tx save failed"); return tx }
```

A failed save returned the transaction object anyway. `ChatViewModel.confirmTransaction` treated any non-nil result as success and printed a receipt, so a transaction that never reached the disk produced a confirmation in the chat. That is P2 exactly, and it was one line.

The second half of the same problem: the financial row was saved in one `ctx.save()`, and the "saved" chat reply in a **separate** unchecked `try? ctx.save()` afterwards. Either one could fail alone.

## What was added

**`SumIt/Services/ledger-store.swift`** — the only place financial data is written locally. Seven commands: `saveTransaction`, `editTransaction`, `deleteTransaction`, `saveWallet`, `archiveWallet`, `saveCategory`, `archiveCategory`.

Each one validates first, then applies the entity change, the queued sync intent and the linked chat reply, then commits **once**. Any failure rolls the context back and throws a typed `LedgerWriteError`; a `LocalSaveReceipt` exists only on the far side of a successful save, so a caller cannot mistake a failure for a success by accident.

Decisions worth naming:

- **Autosave is disabled on the financial context.** Autosave would commit a half-applied command behind the boundary's back.
- **Unrelated pending work is committed before the boundary opens.** SwiftData's `rollback()` discards *every* pending change in the context, not just this command's. Without that step, a failed expense would take an unsaved settings edit or chat draft down with it. Tested: LOC-07 leaves the unrelated edit intact while the financial write does not land.
- **Delete is a tombstone**, never `context.delete`. The row survives with `deletedAt` set, the generation bumped and a delete intent queued — so the intent outlives this launch and other devices can learn about it.
- **Wallets and categories archive.** Their history stays readable and, per Task 08, still calculable.
- **Repeated edits append predecessor-linked intents.** They are not coalesced and never reuse an operation ID: `[nil, op1, op2]` with generations `[1, 2, 3]`, asserted after a reopen.
- **A second create for an existing owner+UUID is rejected** before any mutation, so a double tap resolves to the record already saved instead of minting a new identity.
- **The booked USD base is the exact product, half-even to scale 18** — the same rule the server RPC re-derives and rejects a mismatch on.
- **`LedgerWriteError` carries stable machine codes**, not sentences. They can be asserted, stored as `PendingMutation.lastErrorCode`, and localized — without a merchant name or an amount ever entering a log.

Every one of the 18 tests asserts **after closing and reopening the store**, because the claim is about what reached the disk. Failures are injected through a save closure wrapped around the real `ModelContext`, not a fake database.

## What changed in the live path

`AppStore.saveConfirmed` no longer returns a transaction after a failed save: it rolls back, records a machine code in the new `lastWriteErrorCode`, and returns nil. `ChatViewModel` now distinguishes the causes — reporting a storage failure as "unknown currency" sent the user to fix the wrong thing — and **keeps the pending card** so the entry is not lost when a save fails. One new string, six languages.

`AppStore.ledger` exposes the new `LedgerStore`. Nothing calls it yet.

## What is not claimed

- **The live save path is still the old one.** `saveConfirmed` continues to write through `applyWalletDelta` and the fire-and-forget Supabase upload. Task 14 migrates the callers; only then does P2 close end to end.
- The fire-and-forget upload still sets `isSynced` from `AppStore`. Durable acknowledgment belongs to the coordinator in Task 11; this task deliberately did not half-replace it.
- No queued `PendingMutation` is ever dispatched yet — Tasks 10 and 11 own transport and the push loop.
- `LedgerStore` has no test for a `beginBoundary` failure path against a genuinely full disk; the injected closure simulates the throw, which proves the rollback logic but not the OS behaviour.

## Status of the eight problems

| | Problem | State |
|---|---|---|
| P4 | Decimal commas split entries | closed in the live path |
| P8 | Volatile storage fallback | closed |
| P5 | Incomplete transfers | arithmetic closed (Task 08); storage now expressible (Task 09); UI is Task 14 |
| P2 | False save success | **the false-success return is fixed**; the atomic command path exists and is tested, but the live caller migrates in Task 14 |
| P3 | Lost fractional amounts | code ready, editors not migrated |
| P1, P6, P7 | | open |
