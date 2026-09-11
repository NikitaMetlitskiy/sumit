# Ledger reliability execution — Task 06 applied and functionally verified

**Date:** 2026-09-10. **Target:** production `mjhosrblavjdxirayvqt`, confirmed `ACTIVE_HEALTHY` before every read and write.

## Result

The write RPC is applied to production and **has executed**. Fifteen functional cases were exercised against the real schema inside transactions that were rolled back; every one passes.

Production is unchanged: **70 transactions, 0 wallets, 2 categories, 3 profiles, 3 users**, 0 feed events, 0 receipts, 0 sync-state rows, 0 tombstones, 0 rows with `ledger_version <> 0`. The tests left nothing behind.

## Applied migrations

| Migration | Contents |
|---|---|
| `ledger_rpc_helpers_reworked` | Relaxed `amount_in_base` / `rate_at_time` NOT NULL; executor policies; half-even rounding, canonical text, strict decimal parse, case-insensitive identity helper; three snapshot builders matching the real columns |
| `ledger_current_uid_helper` | `public.ledger_current_uid()` plus policies rewritten onto it |
| `apply_ledger_mutation_v1_reworked` | The RPC, owned by the executor, `anon` revoked |
| `rpc_use_ledger_current_uid` | Pointed the RPC at the helper |
| `rpc_already_exists_precedence` | Fixed a conflict-precedence bug the tests found |

## Three obstacles, and what each one taught

**1. `must be able to SET ROLE`.** Ownership had to move to `sumit_ledger_executor`, but `postgres` held membership with `set_option = false`. It does hold ADMIN OPTION on the role it created, so it re-granted the membership to itself `WITH INHERIT TRUE, SET TRUE`.

**2. `permission denied for schema public`.** PostgreSQL requires an object's new owner to hold `CREATE` on its schema. Granted for the installation and **revoked immediately afterwards** — verified: `executor_still_has_create = false`.

**3. `permission denied for schema auth`.** This one changed the design. Schema `auth` is owned by `supabase_admin`, and `postgres` holds no grant option on it, so `GRANT USAGE ON SCHEMA auth TO sumit_ledger_executor` silently did nothing — PostgreSQL *warns* rather than errors when the grantor lacks the right, which is why the earlier migration reported success while granting nothing.

The tempting fix was to let the function be owned by `postgres`, which can call `auth.uid()`. That role carries `BYPASSRLS`, so every row-level policy inside the function would have become decorative — precisely what the plan warns against ("SECURITY DEFINER by itself does not bypass RLS"). Instead, `public.ledger_current_uid()` reads the owner id from the same place `auth.uid()` reads it, the request's JWT claims, in a schema we control. The `NOBYPASSRLS` executor is kept, and one cross-schema dependency leaves the write path.

## A real bug the tests found

**RPC-04.** A create (`expected_revision = 0`) against an identity that already exists answered `revision_mismatch`, because the revision check ran before the existence check. Both statements are true, but they tell the client to do opposite things: "your base is stale" invites a refetch and retry, while "this identity is taken" is the answer that stops a duplicate being minted. Fixed; retested; now `already_exists`.

## What the fifteen cases proved

| Case | Result |
|---|---|
| RPC-01 create a wallet | accepted, revision 1, opening balance `1000` |
| RPC-02 identical replay | byte-identical response; still 1 wallet, 1 feed event, 1 receipt |
| RPC-03 same operation id, different payload | `operation_payload_mismatch`, nothing mutated |
| RPC-04 create over an existing identity | `already_exists` |
| RPC-07 put onto a tombstone | `deleted` |
| RPC-08 owner B targets owner A's wallet | `not_found`; B ends with 0 wallets |
| RPC-10 transfer | **one row** carrying both wallet references and both quantities |
| RPC-11 same-currency transfer, unequal legs | `equal_currency_legs_must_match` |
| RPC-12 `base_amount` off by 0.1 | `base_amount_mismatch` |
| RPC-13 provider quote with no cache row | `unverified_provider_quote` |
| RPC-15 unvalued expense | accepted; amount `12.5` kept; `base_amount` null |
| RPC-17 delete | accepted, tombstoned, row retained |
| RPC-19 **uppercase legacy identity** | **found, not duplicated** |

### RPC-19 is the one that matters

A row was inserted with `local_id = '…00000000000F'` — uppercase, exactly as the shipped app writes it, and the shape 32 of 70 production rows already have. A request carrying the lowercase UUID **found that row**: it answered `already_exists` and left exactly **one** row, with its original case untouched and its original merchant intact.

Under the previous case-sensitive comparison the row would not have been found, and a second row would have been created for the same transaction. Measured earlier on production data: case-sensitive matching finds 38 of 70 rows; the current matching finds 70 of 70.

## Discovered constraint for Task 18

A legacy row has `ledger_revision = 0`, and `expected_revision = 0` means "create". So **the RPC can never update a legacy row** — it will always answer `already_exists`. That is consistent with the plan, which has adoption seed remote revisions before the protocol takes over, but it is now a measured constraint rather than an assumption: adoption must assign revisions, or no legacy transaction is reachable through the new write path.

## What is still not claimed

- **No concurrency case has run.** CONC-01…04 need two simultaneous sessions; a single rolled-back transaction proves nothing about serialization, and production must not host that test.
- **The pull RPC does not exist.** `read_ledger_changes_v1` is Task 07.
- **Nothing in the app calls this.** The client transport from Task 10 has never spoken to it; that is Task 11's push loop.
- Everything above was verified against synthetic rows created and rolled back. No production row was read into a test assertion or modified.
