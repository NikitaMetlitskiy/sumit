# Ledger reliability execution — Task 12 (pull merge, P1/P6)

**Date:** 2026-09-10. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **187** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |

New this task: `LedgerRestoreTests` 16, covering REST-01…08 and REST-10.

## What this replaces

`AppStore.restoreFromCloud` fetched at most 1,000 rows, built a `Set` of local id **strings**, and constructed a brand-new `Transaction` for anything it did not recognise. Two consequences, both live in production data:

- Swift writes `UUID.uuidString` in uppercase; the server returns lowercase. A case-sensitive string comparison never matched, so a restore created a **second copy** of the same transaction. Production currently holds 32 of 70 rows in uppercase.
- The 1,000-row cap meant a large history could not be represented at all.

`pull(scope:)` replaces both. Identity is `(owner, kind, UUID)` compared as UUID **values**; a page and the cursor it advances commit together; and a remote row is never dropped for being inconvenient.

## What the sixteen cases prove

| Case | Result |
|---|---|
| REST-01/02 restore the same feed twice | byte-identical store snapshot; one transaction, one wallet, one category |
| REST-03 uppercase then lowercase identifier | **one row**, updated to revision 2 — not two |
| REST-04 missing `local_id` or `user_id` | decode failure; no generated UUID, no current-owner fallback |
| — snapshot owned by someone else | not adopted, and the cursor does not move |
| REST-05 fractional ISO timestamp | original instant preserved; explicitly not `.now` |
| REST-06 remote edit of a clean row | applied once, revision advances |
| — replayed older revision | row **not** rolled back |
| REST-07 our own accepted operation returns in the feed | zero conflicts — a device does not conflict with itself |
| — a different device's edit meets an unsent local edit | conflict recorded with **both** candidates, local value untouched, that entity's queue blocked |
| REST-08 remote delete | tombstone applied; replaying the feed does not resurrect it |
| REST-10 transaction referencing an unknown wallet | row kept **and** flagged `missing_wallet_reference` — visible, not silently dropped |
| 1,250 records over five pages | all applied, checkpoint 1250, watermark from page one carried on every later page |
| page commit fails | no rows, no cursor movement — the next attempt replays that page |
| resumed pull | asks from the stored checkpoint, not from zero |
| server moves its watermark mid-run | refused; the pages that already landed stay landed |
| signed-out scope | never pulls |

Every persistence claim is asserted after a real close-and-reopen.

## Decisions worth naming

- **The page and its checkpoint are one commit.** If they were separate, a crash between them would skip a page permanently. On failure the cursor still points before the page, so the next attempt replays it — which is safe precisely because applying is idempotent by identity.
- **An event at or below the row's acknowledged revision is history.** It is validated and skipped, never applied backwards.
- **Own operations are recognised by operation id.** Completed `PendingMutation` rows are retained for exactly this: without them a device reports a conflict against its own accepted write.
- **A conflict preserves both candidates and blocks that entity's queue.** Nothing is merged automatically and the local value stays visible until the owner chooses.
- **A reference that has not arrived yet is flagged, not fatal.** The transaction is applied and a `SyncIssue` makes the gap visible; dropping the row would be the silent data loss this work exists to remove.
- **One open issue per entity and reason.** A repeated pull must not pile duplicates in front of the user.

## A test bug worth recording

The 1,250-record case first failed reporting zero feed calls. The cause was mine: the assertion ran after `relaunch()`, which replaces the fake feed, so it was inspecting a fresh object. Fixed by capturing the calls before the relaunch. The production code was not at fault, and it was not changed.

## What is not claimed

- **Nothing calls `pull` in production.** Like the push side, it is wired but never triggered: `AppStore` still restores through the old path. Task 14 migrates the callers.
- **It has never spoken to the real feed RPC.** `read_ledger_changes_v1` is applied and verified on production (Task 07), and this client is verified against a fake — the two have not been connected.
- **REST-09 is not covered here.** "A new device without chat messages can still reach its transactions" needs the complete-history screen, which is Task 19.
- Two-device convergence is the Task 20 schedule, not this task.
- The old `restoreFromCloud` and its `limit=1000` are still present and still the live path until Task 14 retires them.
