# Production discovery — the real schema (Task 05, redone)

**Date:** 2026-09-10. **Project:** `mjhosrblavjdxirayvqt` (`sumit`), status **ACTIVE_HEALTHY** (verified before every read this time). **Method:** read-only queries; aggregates only, no financial row printed.

## 1. Production restored to a clean state first

| Action | Result |
|---|---|
| `revert_legacy_write_gate` | 9 RESTRICTIVE write-gate policies dropped. Verified: 0 remain, 14 owner policies intact, a real user can still read their rows. |
| `drop_redundant_duplicate_indexes` | 3 duplicate unique indexes I created on 2026-09-09 dropped. |
| `drop_orphan_legacy_write_gate_helper` | `ledger_legacy_writes_allowed_v1()` dropped — no callers left after the revert, and an unused SECURITY DEFINER function reachable by `anon` is a liability. |

Data after all three: **70 transactions, 2 categories, 3 profiles, 3 users** — unchanged throughout.

### The duplicate-index mistake, explained

Production already had `transactions_user_local_id_uniq`, `wallets_user_local_id_uniq` and `categories_user_local_id_uniq` (oids 31624–31626) on exactly `(user_id, local_id)`. My migration used the names from `Backend/supabase_migration.sql` — `*_local_id_user_uniq` — which did not match, so `CREATE UNIQUE INDEX IF NOT EXISTS` did not skip and created a second identical index on each table (oids 33544–33546). Identified by OID ordering, so the originals were kept and only mine were dropped.

**This also settles a documentation question:** `supabase_migration.sql` was *not* what produced production. Its RLS policies match byte for byte, but its index names do not exist. The schema was built some other way, and the README's "Already applied in production" is not a reliable statement about this database.

## 2. What is left in production from the ledger work

Inert and unreferenced: nullable exact columns on transactions/wallets/categories (`numeric(38,18)`, confirmed), two `NOT VALID` CHECK constraints that apply only to `ledger_version <> 0` rows (no row qualifies), three empty `ledger_*` tables, `rate_quotes`, `rate_refresh_leases`, and the `sumit_ledger_executor` role. Nothing reads or writes any of it.

## 3. The real schema, versus what the repository claims

| Difference | Reality |
|---|---|
| `transactions.timestamp` | Exists, `timestamptz NOT NULL DEFAULT now()`. In no document. Sits alongside `occurred_at`. |
| `categories.created_at` | **Does not exist.** The DTO inventory assumes it — this is what made migration 02 fail. |
| `categories.user_id` | Nullable `text`, not `NOT NULL`. |
| `transactions.local_id` | `text DEFAULT ''` — an empty-string default, not null. |
| `transactions.amount_in_base`, `rate_at_time`, `category_name` | `NOT NULL` in production; my reconstruction had them nullable. |
| `profiles` | Far wider than documented: `apple_user_id` (UNIQUE), `avatar_url`, `display_currency`, `last_sign_in`, `total_transaction_count`, `original_transaction_id`. FK `id → auth.users(id) ON DELETE CASCADE`. |
| `currency_rates` | **Already exists** (`id, from_currency, rates jsonb, fetched_at`), world-readable. Task 16 planned to design a rate cache from scratch; one is already here. |
| `usage_log` | Exists (`id, user_id uuid, action, created_at`). Note `user_id` is **uuid** here while `transactions.user_id` is **text** — the project is not internally consistent about owner types. |
| `baby_checklist` | A different app's table living in this project. |

### Undocumented triggers with real side effects

```sql
on_transaction_insert AFTER INSERT → increment_tx_count()   -- profiles.total_transaction_count + 1
on_transaction_delete AFTER DELETE → decrement_tx_count()   -- GREATEST(0, count - 1)
```

Consequences the ledger design has to account for:

- **A soft delete does not decrement the counter.** The trigger fires on `DELETE`, not on an `UPDATE` that sets `deleted_at`. The app already soft-deletes, so `total_transaction_count` drifts upward by design. Measured: **1 of 3 profiles already has a drifted counter.**
- The planned write RPC applies deletes as `UPDATE`, so it inherits the same drift. Whether that counter should track active rows is a product decision to settle before Task 06 is finalized.

## 4. Data quality (aggregates only)

| Measure | Value |
|---|---|
| Transactions | 70, of which soft-deleted: 0 |
| Missing or empty `local_id` | 0 |
| `local_id` not a valid UUID | 0 |
| **`local_id` written in UPPERCASE** | **32 of 70** |
| Case-insensitive duplicate identities | 0 |
| Rows with `user_id = 'local'` | 0 |
| Distinct owners / orphaned owners | 3 / 0 |
| Transfers | 2 |
| Rows naming a wallet | 5, across 3 distinct names |
| **Wallets in the database** | **0** |
| Amounts with more than 2 decimals | 0 |
| Currencies in use | EUR, UAH, USD |
| Profiles with a drifted transaction counter | 1 of 3 |

Three of these matter a great deal:

1. **32 of 70 `local_id` values are uppercase.** Swift's `UUID.uuidString` is uppercase, and the restore path compared identity as *strings*. Mixed case in one table is exactly the condition under which a case-sensitive comparison produces duplicate records. There are no duplicates *yet* — the design's rule to parse into `UUID` and compare values, never strings, is confirmed as necessary rather than theoretical.

2. **Two transfers exist and there are zero wallets.** Both transfers are one-sided *and* reference wallets that do not exist remotely. P5 is not a hypothetical in this data.

3. **Wallet sync has never worked.** Five transactions carry a wallet name, three distinct names, and the `wallets` table is empty. That is consistent with `SupabaseService.saveWallet` discarding its response entirely (`_ = try await URLSession.shared.data(for: req)`), so every failure was invisible — audit finding F04/P6, observed in production.

## 5. Security findings in production (pre-existing, not introduced by this work)

From the Supabase security advisors, confirmed against the catalog:

**Serious — `anon` can call SECURITY DEFINER functions over the public REST API:**

- `public.reset_monthly_parses()` — callable unauthenticated via `/rest/v1/rpc/reset_monthly_parses`. It resets parse quotas. Anyone on the internet who knows the project URL and the anon key (which ships inside the app, by design) can reset billing quotas.
- `public.increment_parse_count(uid uuid)` — callable unauthenticated, and it takes the **user id as an argument**. Anyone can inflate any user's monthly parse counter and exhaust their quota.
- `increment_tx_count()`, `decrement_tx_count()`, `handle_new_user()` — also anon-executable, though as trigger functions they should fail without a trigger context.

**Also flagged:** all five of those functions are SECURITY DEFINER with a **mutable `search_path`**, a standard privilege-escalation vector.

**Wide grants:** `anon` and `authenticated` hold `INSERT/UPDATE/DELETE/TRUNCATE` on `transactions`, `wallets`, `categories` and `profiles`. RLS covers the DML — but **`TRUNCATE` is not subject to RLS**. This is Supabase's default grant set rather than something anyone chose, and PostgREST does not expose TRUNCATE, so it is not reachable today; it is still more privilege than these roles need.

**`public.baby_checklist`** has a policy `Allow all access [ALL] true / true` — fully open to anyone with the anon key.

None of this is in scope for the eight data-correctness problems, and none of it was touched. It is reported because it was found while looking at something else, and the quota functions are exploitable right now.

## 6. Consequences for the plan

- **Task 05 is now genuinely done for discovery.** G1 is satisfied: the real schema, constraints, indexes, triggers, policies and grants are recorded above.
- **The staging reconstruction is wrong and must be rebuilt** from this document, not from the repository's files. It is missing `transactions.timestamp`, invents `categories.created_at`, and gets several nullability constraints backwards.
- **Task 06 needs rework** before it is applied anywhere: the snapshot builders must match the real columns, and the `total_transaction_count` trigger interaction must be decided.
- **Task 16 changes shape.** A rate cache already exists in production (`currency_rates`, jsonb keyed by base currency). Whether to adopt, migrate or replace it is now a real decision with real data behind it, not a greenfield design.
- The `user_id` type split (`text` in the financial tables, `uuid` in `usage_log`, `uuid` in the ledger tables I added) should be settled deliberately rather than papered over with casts.
