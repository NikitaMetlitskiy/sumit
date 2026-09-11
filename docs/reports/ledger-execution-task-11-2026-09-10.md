# Ledger reliability execution — Task 11 (durable push, P2/P6)

**Date:** 2026-09-10. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **171** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |

New this task: `LedgerPushTests` 15, covering PUSH-01…12.

## What this replaces

The old upload was a detached `Task` per save that called Supabase and, on success, flipped `isSynced`:

```swift
Task { [weak self] in
    do { try await SupabaseService.shared.saveTransaction(snap); await self?.markSynced(id: id) }
    catch { Log.warn("Supabase tx sync deferred") }
}
```

Nothing survived a relaunch, nothing retried, ordering was whatever the scheduler chose, and a failure was one log line. `LedgerSyncCoordinator` replaces all of it: the queue is on disk, the request bytes are frozen before dispatch, an acknowledgment is itself a durable write, and no operation is ever discarded because it failed too often.

## A real bug the tests found

`attemptCount` was incremented only when a request was **first** frozen. On every retry the coordinator returned the stored request without touching it, so the counter stayed at 1 — and the backoff ladder is indexed by that counter. Every retry would have waited the first rung's two seconds, forever, for an app that stayed offline for days.

Two tests caught it: PUSH-12 expected the count to reach 8 after eight days of attempts and saw 1, and the backoff test saw the delay shrink between attempts instead of growing. Fixed by counting every dispatch attempt, with a comment recording that it is a counter and never a limit.

## What the fifteen cases prove

| Case | Result |
|---|---|
| PUSH-01 offline before first send | queued, frozen payload intact, error code recorded |
| PUSH-02 relaunch after freezing | same operation id, same entity, then accepted |
| PUSH-03 server committed, answer lost | `unknownOutcome` stays retryable; replay reuses the same operation id; **one** completed operation and **one** wallet |
| PUSH-04 acknowledgment cannot be saved | operation is **not** completed — an acknowledgment that was not written down is not an acknowledgment |
| PUSH-05 edit while an older generation is in flight | newest local amount stands, acknowledged base revision recorded, row **not** marked synced, successor still pending |
| PUSH-06 three offline edits | predecessor chain `[nil, op1, op2]`, expected revisions `[0, 2, 3]`, server ends at the latest draft |
| PUSH-07 three overlapping triggers | 2 requests for 2 operations — one dispatcher, not one per trigger |
| PUSH-08 wallet creation pending | the referencing transaction is not even frozen, let alone sent |
| PUSH-09 conflict | that entity blocked, a `SyncIssue` recorded with both candidates, an independent transaction still completes |
| PUSH-10 account changed mid-request | nothing applied, revision still 0 |
| PUSH-11 `Retry-After: 300` | scheduled exactly 300s out, not deleted; a trigger before the deadline sends nothing |
| PUSH-12 eight days offline | still queued, attempt count 8, exactly one operation on disk |
| — signed-out scope | never dispatched at all |
| — explicit Retry | releases a blocked operation **without rewriting its frozen request** |
| — backoff | grows monotonically across attempts, never discards |

Every claim about persistence is asserted after a real close-and-reopen of the store.

## Decisions worth naming

- **Frozen before dispatch.** The request is encoded, stored and marked `inFlight` **and committed** before the network call. A crash between there and the response replays the same operation, which the server's receipt resolves.
- **Re-encoding on retry is safe, and here is why.** The server stores the request as `jsonb` and compares a replay with `=`, which is a value comparison, not a textual one. Byte-identity is therefore not required — content identity is, and a newer local edit cannot reach these bytes because it appends a new operation instead.
- **Generation-gated acknowledgment.** The accepted revision is always recorded as the entity's acknowledged base, but the row is marked synced only when its local generation still equals the one the server accepted. A newer edit keeps its own values and its pending status.
- **No background timer.** Retries are scheduled as a stored `nextAttemptAt` and picked up by the next trigger (startup, foreground, local commit, explicit Retry). Nothing runs indefinitely in the background and nothing expires.
- **A local persistence failure stops sync.** Continuing would mean sending operations whose answers we cannot record.
- **Blocking is per-entity.** A conflict blocks that entity and its successors; independent entities keep syncing.

## Honest note about a flake

The first full-suite run after this change reported both UI tests failing. Re-running the UI bundle alone passed, and a second full-suite run passed with 171 + 2 green. The cause was not identified. It is recorded here as a flake rather than dismissed: an intermittently failing UI test is a real signal, and if it recurs it should be investigated rather than re-run.

## What is not claimed

- **Nothing triggers the coordinator in production.** `AppStore.syncCoordinator` exists but is never started: the live save path still writes through `saveConfirmed`, which creates no `PendingMutation`, so the queue is always empty for a real user. Task 14 migrates the callers, and triggering starts there.
- **It has never spoken to the real RPC.** The transport is real code (Task 10) and the server RPC is real and verified (Task 06), but they have not been connected end to end. That needs a signed-in account against production.
- The pull side does not exist yet: merging remote pages is Task 12.
- Concurrency between two devices is untested; that is the two-device schedule in Task 20.
