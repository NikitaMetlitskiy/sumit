# Ledger reliability execution — Task 07 (change feed) applied and verified

**Date:** 2026-09-10. **Target:** production `mjhosrblavjdxirayvqt`, `ACTIVE_HEALTHY` confirmed before every read and write.

## Result

`read_ledger_changes_v1` is applied and executed. All pull cases pass against the real schema inside rolled-back transactions.

Production unchanged afterwards: **70 transactions, 0 wallets, 2 categories, 3 profiles, 3 users**, 0 feed events, 0 receipts, 0 sync-state rows, 0 rows with `ledger_version <> 0`. `anon` cannot call the function; `authenticated` can; the function is owned by `sumit_ledger_executor`, and the installation-time `CREATE` on schema `public` was withdrawn again.

## Completeness, measured

A feed of **2,503 events** was seeded with deliberately shuffled `created_at` values — many rows sharing a timestamp — so that any ordering which is not by cursor shows up as a gap or a duplicate. Every tenth event was a tombstone. A second owner got five events that must never appear.

Paging through with `limit = 250`:

| Measure | Result |
|---|---|
| Pages | 11 (ten of 250, one of 3) |
| Retrieved total | **2503** |
| Retrieved distinct | **2503** |
| Missing | **0** |
| Unexpected | **0** |
| Duplicated | **0** |
| Strictly ascending across page boundaries | **true** |
| Tombstones delivered | 250 |
| Watermark on every page | 2503, unchanged |

The watermark check is not cosmetic. Advancing `through_cursor` to "now" between pages is exactly how a concurrently committed lower cursor gets skipped forever, so the loop raises immediately if page *n* reports a different watermark from page 1.

## Bounds and refusals

| Case | Result |
|---|---|
| Empty follow-up page | 0 changes, `next_cursor` = watermark, `has_more` false — a caller that stores it stops asking |
| `limit = 0` and `limit = 251` | `invalid_limit` |
| `after_cursor = -1` | `invalid_after_cursor` |
| `through_cursor` beyond what is committed | `invalid_through_cursor` |
| Owner B reading | its own 5 events only |
| Owner B asking for owner A's window | `invalid_through_cursor` |

Bounding happens inside the function: `limit + 1` rows are fetched so `has_more` is known without a second query, and the extra row is dropped. Nothing depends on PostgREST's default row cap — the cap that produced the old client's `limit=1000` truncation.

## The two RPCs together

A wallet create, a transaction create and a delete were written through `apply_ledger_mutation_v1`, then read back through the feed:

- 3 events, watermark 3.
- Event 1 — wallet snapshot, `opening_balance` `1000`.
- Event 2 — transaction snapshot: `original_amount` `12.5`, `base_amount` `12.5`, `quote.valuation_kind` `identity`, correct `user_id`, `local_id` stored lowercase.
- Event 3 — the tombstone: `deleted_at` set, `ledger_revision` 3, identity retained.

So a delete does reach other devices as an event rather than as a silent disappearance, which is the P6 half of this task.

## What is not claimed

- **CONC-04 has not run.** Proving that a concurrently committed lower cursor is never skipped requires holding a mutation open in one session while another reads the watermark. A single rolled-back transaction cannot demonstrate serialization, and this must not run against production. It needs a disposable target.
- **Nothing in the app calls this.** `SupabaseService.readLedgerChanges` from Task 10 has never spoken to it; the pull merge is Task 12.
- The seeded snapshots in the completeness run were stubs. Full DTO shape was verified separately in the write-then-read check above, not across all 2,503 rows.
- No production row was read into an assertion or modified.
