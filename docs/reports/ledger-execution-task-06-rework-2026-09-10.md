# Ledger reliability execution — Task 06 reworked against the real schema

**Date:** 2026-09-10. **Supersedes:** the 2026-09-09 attempt, which was written against a reconstruction.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **156** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |

## The measurement that justifies the rework

Run against production data inside a transaction that was rolled back:

| Check | Result |
|---|---|
| Transaction snapshots built by the new builder | **70 of 70** |
| Category snapshots built | **2 of 2** |
| Rows found by the new case-insensitive identity match | **70 of 70** |
| Rows a case-sensitive `local_id = uuid::text` would find | **38 of 70** |
| Rows whose `local_id` is uppercase | 32 |

The old comparison would have missed 32 real transactions — treated each as absent, and created a duplicate on the next write. That is P1, reproduced on the server side, measured rather than argued.

Rollback confirmed afterwards: the helper and the three builders do not exist in production, `amount_in_base` and `rate_at_time` are still `NOT NULL`, and the row counts are unchanged at 70 / 2 / 3.

## What changed from the 2026-09-09 version

**Superseded:** `Backend/migrations/20260909_02_ledger_mutation_rpc.sql`, marked at the top and not to be applied.
**New:** `20260910_04_ledger_mutation_rpc.sql` (identity helper, snapshot builders, NOT NULL relaxation) and `20260910_05_apply_ledger_mutation_rpc.sql` (the RPC itself).

### 1. Identity is matched case-insensitively

`transactions.local_id` is `text`, written by Swift's `UUID.uuidString`, which is uppercase. PostgreSQL renders `uuid::text` lowercase. Every lookup now goes through `ledger_same_identity(local_id, entity)`, new rows are stored lowercase, and pre-existing rows keep the case they already have — no identity is rewritten behind the owner's back.

Two rows differing only by case are refused as `ambiguous_local_id`. Production has none today, and the RPC will not be the thing that guesses if one ever appears.

### 2. Legacy `NOT NULL` columns are relaxed rather than filled with a lie

`amount_in_base` and `rate_at_time` are `NOT NULL` in production, and an unvalued transaction has neither. Writing `0` would state the transaction is worth zero dollars, which is a different claim from "not valued yet" — the exact class of quiet falsehood this whole workstream exists to remove. Dropping `NOT NULL` only widens what the column accepts, so the shipped client, which always sends both, is unaffected.

### 3. The category snapshot has no `created_at`

Production's `categories` has no such column, and the DTO inventory in `database-and-rollout.md` §6 never listed one for category snapshots — it lists `created_at` only for transaction and wallet. **The bug was in my Swift decoder,** which demanded it for all three. `CategorySnapshotV1.createdAt` is now optional, with two tests: a category snapshot decodes without it, and a wallet snapshot still fails without it.

### 4. `anon` is explicitly revoked

The discovery found several existing SECURITY DEFINER functions in this database reachable by `anon` through `/rest/v1/rpc/`. The new RPC revokes `anon` and `PUBLIC` explicitly and grants only `authenticated`.

## Recorded, not fixed: the transaction counter

`on_transaction_insert` fires `increment_tx_count()`; `on_transaction_delete` fires `decrement_tx_count()` **on DELETE only**. The RPC deletes by setting `deleted_at`, so `profiles.total_transaction_count` will keep counting deleted transactions — exactly as the shipped app already behaves. One of three production profiles has a drifted counter today.

Whether that counter should track active rows is a product decision. A migration is the wrong place to make it silently, so it is documented and left alone.

## What is not claimed

- **The RPC has never executed.** Only the SQL-language parts — the identity helper and the three snapshot builders — were compile-checked and exercised against real rows. A PL/pgSQL body is not validated at `CREATE FUNCTION` time, so the RPC's own column references are still unproven.
- **No RPC/CONC test has run.** `Backend/tests/ledger-write-tests.sql` specifies 21 write cases and 4 concurrency cases; every one is unexecuted.
- Neither migration file has been applied anywhere.
- Concurrency cannot be proved from one session, and production must not host destructive or two-session tests.

## What running the tests needs

A disposable target carrying production's real schema. The staging project is paused, and its base schema came from the reconstruction the discovery disproved — it lacks `transactions.timestamp`, invents `categories.created_at`, and has several nullability constraints backwards. It has to be rebuilt from `production-discovery-2026-09-10.md` first.

The organization's free plan allows two active projects; production and one unrelated project (`Babyline`) occupy both.
