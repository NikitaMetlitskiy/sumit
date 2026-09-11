# Ledger reliability execution — Task 05 (remote foundations)

**Date:** 2026-09-09. **Baseline:** `202249998fae5e44f19bb420dbf7b3f58c070ef8`.

## G1 — what access actually exists

| Project | Ref | Region | Status |
|---|---|---|---|
| `sumit` (production) | `mjhosrblavjdxirayvqt` | eu-central-1 | **INACTIVE** |
| `Babyline` (unrelated) | `nxnpwjgfahrngncmwcll` | eu-west-1 | ACTIVE_HEALTHY |
| `sumit-ledger-staging` (created by this task) | `cfdqzcauzlcsztfrkygi` | eu-central-1 | ACTIVE_HEALTHY |

**The production database is paused.** That is the explanation for the audit's finding that the configured Supabase host did not resolve — it was not a misconfigured hostname. While it stays paused, the shipped app cannot sync at all: `AppConfig.supabaseURL` points at a project that is not serving. This is a live operational fact, separate from the eight data-correctness problems, and it is the owner's decision whether to restore it.

Consequences for this task, stated plainly:

- The **discovery step against the real production schema is BLOCKED** and is not claimed. Nothing here describes what production actually contains.
- The staging project was created at the owner's explicit instruction, in the same region as production. `get_cost` reported **$0/month** before creation and the cost was confirmed through the provider's own confirmation step.
- Production was **not** read, written, restored or modified in any way by this task.

## The staging baseline is a reconstruction, and is labelled as one

`Backend/migrations/20260909_00_staging_legacy_baseline.sql` recreates the pre-ledger schema on staging. Because production could not be read, it is derived from two sources inside this repository: the column names the iOS client actually sends and reads in `SumIt/Services/SupabaseService.swift`, and `Backend/supabase_migration.sql`.

It is faithful to the legacy shape on purpose — `double precision` money columns, `text` `user_id` and `local_id`. A staging copy that quietly "improved" those would make every test built on it meaningless, since migrating away from exactly those choices is the work.

The `DELETE` statements from `supabase_migration.sql` section 2 are **not** reproduced. The plan forbids running them as an assumed prerequisite, and a fixture that starts by deleting rows teaches nothing.

That file must never be applied to production, and says so at the top.

## What Task 05 added

`Backend/migrations/20260909_01_ledger_foundations.sql`, applied to staging as migration `ledger_foundations`:

- **Exact columns**, all nullable or defaulted: `amount_exact`, `base_amount_exact`, `rate_exact`, `wallet_local_id`, `destination_wallet_local_id`, `wallet_amount_exact`, `destination_amount_exact`, `quote_metadata`, `valuation_state`, `ledger_revision`, `ledger_version` on transactions; `opening_balance_exact` and versioning on wallets; `deleted_at` and versioning on categories.
- **Version-scoped CHECK constraints** (`NOT VALID`, so existing rows are not retroactively judged) requiring adopted `ledger_version = 1` rows to carry exact values. Legacy `ledger_version = 0` rows are untouched.
- **`ledger_sync_state`, `ledger_mutation_receipts`, `ledger_change_log`** exactly as specified in `database-and-rollout.md` §3.
- **`rate_quotes`** (immutable rows, positive-rate check, lookup index) and **`rate_refresh_leases`**, so Task 06 can validate a quote reference without a missing-table dependency, and Task 16 has its cache waiting.
- **`sumit_ledger_executor`**, a `NOLOGIN NOBYPASSRLS` role with only the table privileges it needs.
- **`ledger_legacy_writes_allowed_v1()`**, a `SECURITY DEFINER` helper with a fixed `search_path`, plus nine RESTRICTIVE write policies across the three tables.

`local_id` was deliberately **not** cast from `text` to `uuid`. An existing text column can hold values that are not valid UUIDs, and a blind cast either fails the migration or destroys identity. New references are `uuid`; the RPC will compare them to a validated `local_id::text`.

## Verification — read back, then actually attempted

Catalog read-back after applying:

| Check | Result |
|---|---|
| New transaction columns present | 11 of 11 |
| New tables present | 5 of 5 |
| `sumit_ledger_executor` exists | yes |
| …bypasses RLS | **false** |
| …can log in | **false** |
| …has `authenticated`/`anon` members | **0** |
| `authenticated` can INSERT receipts | **false** |
| `anon` can UPDATE the change feed | **false** |
| `authenticated` can SELECT sync state | **false** |
| `authenticated` can SELECT rate quotes | **false** |
| Legacy write-gate policies | 9 |

Catalog checks alone are not proof — an inherited grant can still let a role through, and a RESTRICTIVE policy can be written so it never fires. So `Backend/tests/ledger-schema-tests.sql` performs real `SET ROLE authenticated` + JWT-claim attempts. Every one of these was executed on staging and passed:

- `SELECT` on `ledger_sync_state`, `INSERT` into `ledger_change_log`, `SELECT` on `rate_quotes` → all refused with `insufficient_privilege`.
- A **legacy account with no state row can still write.** This is the one that matters most: the opposite default would lock out every existing user the moment the migration landed.
- An **adopted account** (`protocol_version = 1`) has its direct `INSERT` and `UPDATE` refused…
- …while still being able to **read** its own rows, so an old client is not bricked, only prevented from writing behind the protocol's back.
- **Cross-user isolation**: owner B sees zero of owner A's rows.
- **One account's adoption does not block another**: unadopted owner B still writes normally.

## Checklist status

- [ ] **BLOCKED:** run the discovery queries against the real target and inspect its actual policies, grants, constraints, trigger side effects and `local_id` type. Production is paused. Everything below was proven against a documented reconstruction, not against production.
- [ ] **BLOCKED:** record aggregate duplicate/null/owner problems and verify a recoverable backup. Same reason. No production data was inspected or copied.
- [x] Additive migrations created with no deletion, rename or unsafe cast; target recorded before applying; schema and grants read back immediately afterwards.
- [x] Fixtures for a legacy account and an adopted account; version-scoped checks preserve legacy values and constrain new ones.
- [x] New tables unreachable by `authenticated`/`anon`, proven by real role attempts and not only by catalog privileges. No client-controlled bypass marker exists.

**Not done:** G1 is **not** recorded as satisfied. The migrations are verified on staging; whether production's real shape matches this reconstruction is unknown and must be checked before any of this is applied there.

## Consequences for later tasks

Tasks 06 and 07 can now be built and tested on staging against a realistic schema. Task 18's adoption work and any production rollout stay blocked until production is reachable and its true schema is inventoried — the reconstruction is a development surface, not evidence about the live system.
