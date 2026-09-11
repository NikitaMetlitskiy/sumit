# SumIt ledger reliability — database protocol, migration and rollout

Read `design.md` for authoritative product semantics. All schema/function names below are **proposed additions**, except the four existing tables and their current fields explicitly visible in repository code. Nothing in this document has been applied.

## 1. Discovery before SQL changes

The repo does not contain CREATE TABLE definitions, all historical policies, actual column types or live grants. Execute these read-only queries through the already authorized database connection once the real project is known. Save sanitized output to a new dated report; do not export user records or credentials into this public repository. If no connection is available, code/testing with synthetic fixtures can proceed, but database migration and production qualification remain blocked.

```sql
SELECT table_name, column_name, data_type, udt_name,
       is_nullable, column_default, numeric_precision, numeric_scale
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('transactions', 'wallets', 'categories', 'profiles')
ORDER BY table_name, ordinal_position;

SELECT c.relname AS table_name, k.conname, k.contype,
       pg_get_constraintdef(k.oid) AS definition
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('transactions', 'wallets', 'categories', 'profiles')
ORDER BY c.relname, k.conname;

SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN ('transactions', 'wallets', 'categories', 'profiles')
ORDER BY tablename, indexname;

SELECT tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('transactions', 'wallets', 'categories', 'profiles')
ORDER BY tablename, policyname;

SELECT grantee, table_name, privilege_type
FROM information_schema.table_privileges
WHERE table_schema = 'public'
  AND table_name IN ('transactions', 'wallets', 'categories', 'profiles')
ORDER BY table_name, grantee, privilege_type;

SELECT grantee, table_name, column_name, privilege_type
FROM information_schema.column_privileges
WHERE table_schema = 'public'
  AND table_name IN ('transactions', 'wallets', 'categories', 'profiles')
ORDER BY table_name, grantee, column_name, privilege_type;

SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND NOT t.tgisinternal
  AND c.relname IN ('transactions', 'wallets', 'categories', 'profiles');

SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid),
       p.prosecdef, p.proconfig, p.proacl
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('public', 'auth')
  AND (p.proname LIKE '%profile%' OR p.proname LIKE '%user%'
       OR p.proname = 'increment_parse_count');
```

Inspect definitions of the returned application-owned auth/profile triggers and any function they call; function names are discovered, not assumed. Check grants inherited through role membership and PUBLIC as well as direct grants. Confirm actual PostgreSQL version and RLS flags. Query aggregate quality counts separately, after confirming the columns exist:

```sql
SELECT count(*) AS total,
       count(*) FILTER (WHERE local_id IS NULL) AS missing_local_id,
       count(*) FILTER (WHERE user_id IS NULL OR user_id::text = 'local') AS unowned,
       count(*) FILTER (WHERE deleted_at IS NOT NULL) AS deleted
FROM public.transactions;

SELECT count(*) AS duplicate_identity_groups
FROM (
  SELECT user_id, local_id FROM public.transactions
  GROUP BY user_id, local_id HAVING count(*) > 1
) d;
```

Repeat the appropriate aggregate checks for wallets/categories using confirmed column availability. Do not assume text accepts arbitrary enum values: inspect CHECK constraints and actual distinct values before establishing validation. Do not list personal descriptions/amounts in tool output. If duplicate/null identity groups exist, calculate counts and create a reviewed repair manifest for the affected account; no automated content-based deletion.

**Discovery acceptance:** a schema-only baseline, constraint/index list, all relevant policies/grants/triggers, aggregate quality counts, profile creation behavior, actual project identity and a staging restore procedure are recorded. Incompatible findings revise the migration before execution; do not hand-edit production to match a guessed schema.

## 2. Additive migration sequence

Proposed files use the existing Backend directory rather than creating a second unrelated Supabase layout:

1. `Backend/migrations/20260909_01_ledger_foundations.sql` — Task 05: optional exact fields/references, state/receipt/change tables, immutable quote cache and refresh leases, scoped executor role/grants, legacy-write helper and policies. No new ledger write route is enabled yet.
2. `Backend/migrations/20260909_02_ledger_mutation_rpc.sql` — Task 06: validated write RPC and its execute grants. All referenced tables, including rate_quotes, already exist from Task 05.
3. `Backend/migrations/20260909_03_ledger_change_feed.sql` — Task 07: bounded read RPC and grants.
4. Per-account adoption is a controlled data operation after the new client is verified; it is not an unconditional migration over all users. Task 18 produces and tests the administration script/manifest, with explicit adoption metadata.

Each migration is finalized, reviewed and applied once in its owning task. Do not apply a partial function stub or edit an already-applied migration file in a later task; a discovered correction gets a new forward migration and verified application. Task 16 consumes the existing rate schema and implements routes/qualification, not a late prerequisite of Task 06.

Dates are proposed filenames, not evidence of application. If execution occurs later or those names already exist, use an unused chronological migration identifier and record it in the execution log. Run through the project's verified migration mechanism; pair local record creation with application to the **verified target** during authorized execution. Do not leave app code deployed against a local-only schema change. Do not write to production merely because a plan file exists.

Suggested exact-column SQL, to be finalized against discovery:

```sql
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS amount_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS base_amount_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS rate_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS wallet_local_id uuid,
  ADD COLUMN IF NOT EXISTS destination_wallet_local_id uuid,
  ADD COLUMN IF NOT EXISTS wallet_amount_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS destination_amount_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS quote_metadata jsonb,
  ADD COLUMN IF NOT EXISTS valuation_state text,
  ADD COLUMN IF NOT EXISTS ledger_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ledger_version integer NOT NULL DEFAULT 0;

ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS opening_balance_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS ledger_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ledger_version integer NOT NULL DEFAULT 0;

ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS ledger_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ledger_version integer NOT NULL DEFAULT 0;
```

Verify/add transactions and wallets `deleted_at` only if absent. Confirm `(user_id, local_id)` uniqueness on each table and confirm the type of `local_id`. Do not silently cast an existing text field with invalid UUIDs to uuid. New references are UUIDs; the RPC can compare them to validated existing `local_id::text` without changing legacy storage type. Add a safe unique index only after duplicate-group checks and explicit reconciliation.

Strict v1 validation lives in the RPC and version-scoped CHECK constraints, with explicit legacy-versus-native validation branches. Valid legacy rows must remain readable. Do not impose new precision/type constraints on legacy values by automatic rounding. Mirror new amounts to old numeric columns only after checking their range/type; mirror values are for compatibility, never the new ledger's authority.

## 3. Supporting tables and owner isolation

The following is a concrete schema specification. The executor turns it into a reviewed migration, including idempotent policy creation and exact function bodies from the task plan.

```sql
CREATE TABLE IF NOT EXISTS public.ledger_sync_state (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id),
  cursor bigint NOT NULL DEFAULT 0 CHECK (cursor >= 0),
  protocol_version integer NOT NULL DEFAULT 0,
  writes_paused boolean NOT NULL DEFAULT false,
  adoption_manifest_id uuid,
  adoption_checksum text,
  adopted_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.ledger_mutation_receipts (
  user_id uuid NOT NULL REFERENCES auth.users(id),
  operation_id uuid NOT NULL,
  request jsonb NOT NULL,
  response jsonb NOT NULL,
  accepted_cursor bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.ledger_change_log (
  user_id uuid NOT NULL REFERENCES auth.users(id),
  cursor bigint NOT NULL,
  operation_id uuid,
  entity_kind text NOT NULL CHECK (entity_kind IN ('transaction','wallet','category')),
  entity_local_id uuid NOT NULL,
  snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, cursor)
);
```

RLS enabled on every new table. No direct client INSERT/UPDATE/DELETE on these tables. Revoke default PUBLIC function execution on the new RPCs; grant only authenticated. Service administration can operate through controlled migration tools. Users must not be able to edit their protocol version/cursor or operation receipts. Read through the scoped RPC; if direct SELECT is granted for diagnostics, it must include a strict owner policy.

**Blocking bypass on adopted accounts:** new versioned rows cannot be changed by old direct-REST code after migration. Use a reviewed restrictive RLS write policy conditioned on an unadopted, unpaused owner state for existing direct client writes, backed by complete existing-policy inventory. The dedicated SECURITY DEFINER ledger functions perform their own owner and version checks. Use a proposed `sumit_ledger_executor` NOLOGIN, NOBYPASSRLS role with no authenticated/anon membership, only required table/function privileges, and explicit owner-filtered policies `TO sumit_ledger_executor` on the involved tables. The legacy restrictive policies are `TO authenticated`, not PUBLIC, so the executor's checked writes are not accidentally rejected by the same legacy gate. The executor has owner-scoped access to state/receipts/feed and read-only access to public reference quotes; it cannot rewrite another owner's rows. Authenticated/anon must never be granted membership or SET ROLE into the executor. If the live project requires a different established ownership pattern, record and test its equivalent properties before changing the proposed grants; SECURITY DEFINER by itself does not bypass RLS. Function ownership transfers and schema CREATE rights during installation use the controlled migration identity, with unnecessary installation rights revoked afterward. Do not grant new client write columns and hope callers use the RPC. Do not use a client-settable request flag or custom GUC as proof that a write came through the RPC.

The restrictive policy must not read a table the invoking client cannot select. Supply a narrowly scoped helper `public.ledger_legacy_writes_allowed_v1() returns boolean`, SECURITY DEFINER with fixed search_path, which reads only the current auth.uid() state and returns false for missing auth, otherwise true only when the state row is absent, or protocol_version=0 and writes_paused=false. An absent state row means a known authenticated legacy account; it must not accidentally block all existing users. The mutation RPC rejects financial writes while writes_paused=true. Grant only its execution to authenticated. Use separate restrictive INSERT/UPDATE/DELETE policies so ordinary SELECT remains governed by existing owner policies. Test permission evaluation itself; do not assume a nested policy subquery bypasses table grants.

This is a coordinated, per-account activation: legacy-only accounts remain unaffected until adoption; adopted accounts require the upgraded app. Old direct writes may be rejected, and the old app may ignore those errors, so **all devices in the pilot must be upgraded before adoption**. The protocol cannot protect unsynced edits made later inside an old offline binary. Explicitly record this release limitation rather than promising mixed-client correctness.

No production-wide grant revocation before a compatible client exists. The exact restricted policies depend on discovered owner column types and existing policies; their tests must prove cross-user isolation and legacy-account compatibility.

## 4. Write RPC contract

All decimal values and cursor/revision fields on the wire are **strings**, avoiding JS floating-point coercion. UUIDs are UUID strings. Dates are ISO 8601 with explicit timezone; calendar occurrence date/timezone are additionally preserved in quote context. Owner is derived from auth.uid(); any user_id supplied by a caller is rejected as an unknown field rather than trusted.

Synthetic transfer request (the request, accepted, conflict and feed examples are independent contract specimens, not a sequential fixture script):

```json
{
  "protocol_version": 1,
  "operation_id": "20000000-0000-4000-8000-000000000001",
  "entity_kind": "transaction",
  "entity_id": "30000000-0000-4000-8000-000000000001",
  "action": "put",
  "expected_revision": "0",
  "record": {
    "type": "transfer",
    "original_amount": "100",
    "original_currency": "USD",
    "wallet_id": "40000000-0000-4000-8000-000000000001",
    "wallet_amount": "100",
    "destination_wallet_id": "40000000-0000-4000-8000-000000000003",
    "destination_amount": "90",
    "category_name": "Other",
    "merchant": "",
    "note": "Synthetic transfer fixture",
    "occurred_at": "2026-05-19T12:00:00Z",
    "source": "manual",
    "confidence": "1",
    "raw_input": "",
    "base_amount": "100",
    "usd_per_unit": "1",
    "valuation_state": "valued",
    "quote": {
      "quote_id": null,
      "currency": "USD",
      "usd_per_unit": "1",
      "requested_date": "2026-05-19",
      "effective_at": "2026-05-19T12:00:00Z",
      "fetched_at": "2026-05-19T12:00:00Z",
      "source": "identity",
      "source_detail": {},
      "valuation_kind": "identity",
      "stale": false
    }
  }
}
```

The destination UUID is walletEUR from acceptance-tests.md and its currency is EUR. If it is USD, the unequal amounts must fail validation. These UUIDs are synthetic fixtures, never live account identifiers.

Accepted response:

```json
{
  "status": "accepted",
  "operation_id": "20000000-0000-4000-8000-000000000001",
  "entity_id": "30000000-0000-4000-8000-000000000001",
  "revision": "41",
  "cursor": "41",
  "snapshot": {
    "entity_kind": "transaction",
    "local_id": "30000000-0000-4000-8000-000000000001",
    "user_id": "10000000-0000-4000-8000-000000000001",
    "ledger_revision": "41",
    "deleted_at": null,
    "ledger_version": 1,
    "type": "transfer",
    "original_amount": "100",
    "original_currency": "USD",
    "wallet_id": "40000000-0000-4000-8000-000000000001",
    "wallet_amount": "100",
    "destination_wallet_id": "40000000-0000-4000-8000-000000000003",
    "destination_amount": "90",
    "category_name": "Other",
    "merchant": "",
    "note": "Synthetic transfer fixture",
    "occurred_at": "2026-05-19T12:00:00Z",
    "source": "manual",
    "confidence": "1",
    "raw_input": "",
    "base_amount": "100",
    "usd_per_unit": "1",
    "valuation_state": "valued",
    "quote": {
      "quote_id": null,
      "currency": "USD",
      "usd_per_unit": "1",
      "requested_date": "2026-05-19",
      "effective_at": "2026-05-19T12:00:00Z",
      "fetched_at": "2026-05-19T12:00:00Z",
      "source": "identity",
      "source_detail": {},
      "valuation_kind": "identity",
      "stale": false
    },
    "created_at": "2026-05-19T12:00:00Z"
  }
}
```

The complete synthetic snapshot above is the shape required for transaction materialization. The owner UUID is a pure fixture value, not a live account identifier. The full DTO field inventory is in section 6.

Conflict response uses the same HTTP-success JSON transport for an expected domain conflict:

```json
{
  "status": "conflict",
  "operation_id": "20000000-0000-4000-8000-000000000001",
  "entity_id": "30000000-0000-4000-8000-000000000001",
  "expected_revision": "40",
  "actual_revision": "41",
  "reason": "revision_mismatch",
  "server_snapshot": {
    "entity_kind": "transaction",
    "local_id": "30000000-0000-4000-8000-000000000001",
    "user_id": "10000000-0000-4000-8000-000000000001",
    "ledger_revision": "41",
    "deleted_at": null,
    "ledger_version": 1,
    "type": "transfer",
    "original_amount": "100",
    "original_currency": "USD",
    "wallet_id": "40000000-0000-4000-8000-000000000001",
    "wallet_amount": "100",
    "destination_wallet_id": "40000000-0000-4000-8000-000000000003",
    "destination_amount": "90",
    "category_name": "Other",
    "merchant": "",
    "note": "Synthetic transfer fixture",
    "occurred_at": "2026-05-19T12:00:00Z",
    "source": "manual",
    "confidence": "1",
    "raw_input": "",
    "base_amount": "100",
    "usd_per_unit": "1",
    "valuation_state": "valued",
    "quote": {
      "quote_id": null,
      "currency": "USD",
      "usd_per_unit": "1",
      "requested_date": "2026-05-19",
      "effective_at": "2026-05-19T12:00:00Z",
      "fetched_at": "2026-05-19T12:00:00Z",
      "source": "identity",
      "source_detail": {},
      "valuation_kind": "identity",
      "stale": false
    },
    "created_at": "2026-05-19T12:00:00Z"
  }
}
```

The server_snapshot is a full typed entity envelope. If deleted, use reason `deleted` and include its tombstone. Not-found on an update is a conflict, not an implicit create. New create requires expected revision 0 and absent identity. Retrying a previously accepted create checks the receipt first.

Server procedure, in order:

1. Verify auth.uid() is non-null, adopted protocol is supported, JSON object type, allowed top-level keys, payload byte cap of 64 KiB, UUIDs/action/entity kind and exact-string revision syntax/range. Reject malformed requests before mutation.
2. Ensure/read owner state and acquire `SELECT cursor FROM public.ledger_sync_state WHERE user_id = auth.uid() FOR UPDATE` on that user's state row. No cross-user lock or client-selected lock key.
3. Read `(owner, operation_id)` receipt. If present and request JSONB equals original request, return recorded response. If different, return `operation_payload_mismatch` without mutation. Receipt lookup follows the lock to handle concurrent replay.
4. Lock/read the target entity in the owner's scope. Check expected revision, tombstone rules and all referenced wallets/categories. The actor may only write its own rows. Compare decimal precision and range without routing through float.
5. On conflict return a full typed remote candidate without accepting a mutation or advancing cursor. Client creates a new operation ID if it retries a resolved conflict.
6. Validate the complete put record, or existing delete target. A quote claiming provider provenance must reference an existing rate_quotes.id and match its currency/rate/effective time; source identity is valid only for USD with rate 1, and manual quotes are explicitly labeled manual. Do not trust a client-provided provider label as verification. Apply one entity record; transaction transfer legs live together. A category reorder is separate versioned puts per category in this scope; order is not a financial atomicity guarantee.
7. Allocate the next owner cursor by updating the locked state row. Set that entity's revision to cursor. A delete sets server deletion time but retains identity and historical fields.
8. Write full entity snapshot to change log; include source operation ID. Insert receipt with the exact validated request and accepted response. All writes participate in the same database transaction.
9. Return acceptance. If commit/connection outcome is unknown to the client, replay resolves it through the receipt.

Allowed record fields for transaction/wallet/category are fixed in section 6. Do not accept arbitrary JSON keys to dynamically PATCH columns. No dynamic SQL interpolation from entity_kind or JSON keys; use explicit branches with fixed schema-qualified table names.

## 5. Pull RPC contract

```json
{
  "through_cursor": "87",
  "next_cursor": "42",
  "has_more": true,
  "changes": [
    {
      "cursor": "42",
      "operation_id": "20000000-0000-4000-8000-000000000002",
      "entity_kind": "transaction",
      "entity_id": "30000000-0000-4000-8000-000000000001",
      "snapshot": {
        "entity_kind": "transaction",
        "local_id": "30000000-0000-4000-8000-000000000001",
        "user_id": "10000000-0000-4000-8000-000000000001",
        "ledger_revision": "42",
        "deleted_at": "2026-05-20T12:00:00Z",
        "ledger_version": 1,
        "type": "transfer",
        "original_amount": "100",
        "original_currency": "USD",
        "wallet_id": "40000000-0000-4000-8000-000000000001",
        "wallet_amount": "100",
        "destination_wallet_id": "40000000-0000-4000-8000-000000000003",
        "destination_amount": "90",
        "category_name": "Other",
        "merchant": "",
        "note": "Synthetic transfer fixture",
        "occurred_at": "2026-05-19T12:00:00Z",
        "source": "manual",
        "confidence": "1",
        "raw_input": "",
        "base_amount": "100",
        "usd_per_unit": "1",
        "valuation_state": "valued",
        "quote": {
          "quote_id": null,
          "currency": "USD",
          "usd_per_unit": "1",
          "requested_date": "2026-05-19",
          "effective_at": "2026-05-19T12:00:00Z",
          "fetched_at": "2026-05-19T12:00:00Z",
          "source": "identity",
          "source_detail": {},
          "valuation_kind": "identity",
          "stale": false
        },
        "created_at": "2026-05-19T12:00:00Z"
      }
    }
  ]
}
```

Snapshots are full typed records, including tombstones. Execute one bounded JSON-returning RPC, not unbounded SETOF rows. Enforce limit 1..250 and after/through 0..current cursor. On first page, read committed state cursor to determine through. Query that owner's events where `cursor > after AND cursor <= through`, order ascending, limit + 1 to compute has_more. Set next_cursor to last included event, or through if no events remain. Subsequent pages keep through fixed. Never advance through to “now” between pages.

Because cursor allocation and changes commit under the same per-owner state lock, a visible high watermark cannot include an uncommitted lower cursor that would be skipped forever. Receipt and change rows are retained for the initial reliability release; no TTL/compaction job is introduced. Future pruning requires a new snapshot/checkpoint protocol and is not part of these eight fixes.

Validate entire page before committing locally. Decode failures, missing mandatory exact fields on a v1 record or unknown entity kind do not advance cursor. Show recoverable sync issue; do not silently turn an error body into an empty dataset.

## 6. Full snapshot DTO inventory

Every snapshot: `entity_kind`, `local_id`, `user_id`, `ledger_revision` string, `deleted_at` nullable ISO timestamp, `ledger_version` integer.

Transaction adds: `type`, `original_amount` canonical string, `original_currency`, `base_amount` nullable canonical string, `usd_per_unit` nullable canonical string, `valuation_state`, `quote` nullable object, `wallet_id` nullable UUID, `wallet_amount` nullable canonical string, `destination_wallet_id` nullable UUID, `destination_amount` nullable canonical string, `category_name`, `merchant`, `note`, `occurred_at`, `created_at`, `source`, `confidence` canonical string, `raw_input`. Preserve `wallet_name` as legacy display provenance during migration only. Validate strings: merchant <=256 Unicode scalars, note <=2000, raw_input <=10000 for imported legacy text and <=500 per new parse segment, category name <=128. Larger existing values remain legacy until reviewed, never silently truncated.

Wallet adds: `name` <=128, `type`, `currency`, `opening_balance` canonical signed string, `icon` <=128, `created_at`. No authoritative current-balance field in new protocol.

Category adds: `name` <=128, `icon` <=128, `color_hex` validated six hexadecimal digits, `type`, `sort_order` nonnegative integer, `is_default=false`. For a migrated adopted row, a metadata-only put may preserve an existing amount outside new-entry fractional precision only if all financial fields match the persisted row exactly; changing any monetary field invokes current entry validation. The RPC never accepts a client claim of legacy status as a bypass. Default definitions remain bundled templates; a user cannot claim a custom row is a global default.

Quote objects use the same full shape locally, in `/api/rates` and in snapshots: `quote_id` nullable UUID, `currency`, `usd_per_unit` canonical string, `requested_date` nullable ISO day, `effective_at` and `fetched_at` ISO instants, `source`, `source_detail` JSON object, `valuation_kind`, `stale` boolean. A provider source requires a persisted quote ID and equality with the immutable cache row for its financial/provenance fields. Identity and manual quotes have no provider ID; manual provenance records confirmation time and source_detail, identity uses USD/rate 1 and valuation_kind=identity. Allowed valuation kinds are identity, manual, current_reference and historical_reference. Preserve the occurrence's chosen calendar day/timezone in source_detail when needed; do not infer the original day again from a later device timezone. Stale acceptance is a saved user decision, not authorization to falsify effective_at.

| Transaction state | Required field relationships |
|---|---|
| Unvalued | base_amount, usd_per_unit, quote are all null; original exact quantity remains present |
| Valued | All three present; quote currency/rate match the transaction; base equals the exact product half-even rounded to scale 18; no positive value silently rounded to zero |
| Legacy unverified | Only migration/server-established legacy data can enter this state; retain original numeric fields and explicit uncertainty, no client-supplied precision bypass |
| Income/expense, no wallet | wallet_id and wallet_amount both null; both destination fields null |
| Income/expense, wallet | Same-owner wallet exists; effect positive, and equal to original_amount if currencies match; destination fields null |
| Transfer | Two distinct same-owner wallet IDs and two positive quantities; original currency/amount equal source wallet currency/quantity; equal-currency legs equal |
| Existing archived-wallet record | Metadata-only preservation and deletion allowed; adding a new archived reference or changing its financial effect rejected |

The server generates created_at on create, preserves it on edit, and generates deleted_at on delete. A delete request has no record body; it targets an existing entity/revision. Cursor/revision are bounded nonnegative Int64 strings, confidence lies in [0,1], and action/type/source values must be validated against the explicit supported contract. Never route arbitrary JSON field names into SQL.

All put fields must be validated before SQL side effects. Amount/currency/type/valuation/ref rules come from design.md. External currency strings in legacy rows are inventoried rather than coerced to a new supported code. Snapshots can carry `ledger_version=0` only during explicit migration; the normal v1 feed requires successfully adopted rows or a typed migration issue, never partial silent conversion.

## 7. Per-account adoption and data repair

1. Owner verifies all devices that will use this account can upgrade. Record the minimum supported build from the actual release artifact, not an invented version number.
2. Save a server backup and a consistent local recovery bundle. Confirm backup restoration on staging before touching production data.
3. Freeze legacy cloud financial writes for the selected migration account in a controlled window. In a short administration transaction, acquire `SHARE ROW EXCLUSIVE` locks on transactions, wallets and categories in a fixed order to drain already-running legacy financial writes, then create/update only the selected owner's state to writes_paused=true with the manifest ID and commit. Set lock/statement timeouts and measure the brief all-writer delay on staging; abort the freeze if timeouts are reached, never leave an unknown partial state. The restrictive helper makes subsequent selected-account legacy writes fail. Other accounts retain their policies/data and resume after the brief lock. Do not claim an owner flag alone drains a request that already passed RLS. The new app preserves local drafts and stops sync while adoption is pending.
4. Fetch the complete legacy dataset with stable keyset pagination using verified keys, including all deleted records. Enumerate local records, pending `isSynced=false` data, and current balances. No automatic upload first.
5. Normalize valid UUIDs without changing identity. Match exact owner+UUID. List invalid/missing IDs, duplicate identities, ambiguous formerly-restored copies, unknown wallet name matches, invalid dates and orphan references. Create a repair manifest without deleting source rows.
6. Resolve only provable cases automatically. If one name maps to one wallet and historical currency/effect are known, retain that link with provenance. Otherwise require a recorded owner choice. Never infer a transfer destination or decide that two equal coffee purchases are duplicates.
7. Establish each wallet opening baseline from a chosen observed balance and complete known effects; show before/after balance equality. Unresolved one-sided transfers, identities and wallet-effect ambiguities block canonical activation and remain preserved in the legacy working copy. Historical placeholder valuations can survive as legacyUnverified when identity and native wallet effects are reconciled; this distinction must be visible in totals.
8. In one controlled server transaction per account, write additive canonical values, initialize revisions/change events for wallets/categories then transactions, establish sync state, and set adopted protocol version plus writes_paused=false, preserving the manifest ID/checksum. A large account can stage a manifest in advance, but activation is atomic; never expose a half-seeded feed. Size/lock duration is measured on staging before production.
9. New client pulls the seeded feed into a working copy, reconciles retained local changes through the same durable mutation mechanism and swaps to ready state only after persistent verification. Cursor and active migration version commit together.
10. Re-run adoption with the same manifest identifier: it must be a no-op or report already adopted. Retry after an interrupted staging step resumes without new entity UUIDs. Store an adoption manifest ID and checksums in the dated execution report and controlled server metadata.
11. Verify canonical identity counts, per-currency sums, wallet balances, deleted counts, pending count and unresolved issue count. Record every intentional delta; unexplained change is a stop condition.

Before activation, a canceled/failed adoption may clear writes_paused in a verified administration transaction and resume the original legacy cloud dataset, provided no canonical activation committed. After activation, protocol_version never silently returns to zero. Resuming must verify manifest/status and preserve local offline drafts.

A corrupted old history cannot be made true by a deterministic migration alone. The plan promises preservation, visible ambiguity and a repair workflow, not invented historical facts.

## 8. Rate cache

Add immutable `public.rate_quotes` rows with a server-generated UUID `id`, source, currency, quote_kind (current/historical), requested_date (null only for current), effective_at, fetched_at, usd_per_unit numeric(38,18), provider metadata and a positive-rate check. Index `(source, currency, quote_kind, requested_date, effective_at, fetched_at)` for lookup; do not impose uniqueness that prevents a provider from correcting a historical observation. A correction gets a new UUID and retained old quote row. Add `public.rate_refresh_leases(cache_key text primary key, lease_until timestamptz)` with server-only writes; its canonical key encodes source/currency/kind/requested-date and never account or transaction data. Current and historical lookups cannot share a key. A lease is acquired with one atomic conditional upsert/update, expires after a short tested timeout, and is released on completion/failure; it is not a permanent lock.

Only service-side Vercel code writes rate rows; authenticated clients use `/api/rates`, not arbitrary inserts. Return only public quote fields. The route accepts a bounded list of supported currency codes and optional ISO date, verifies auth, caps payload, and makes at most one fiat batch request and one current-crypto batch request per required cache miss. Historical crypto has a per-coin endpoint, so allow at most four single-coin history requests for the four supported assets, with concurrency at most two; use the actual authorized provider quota. Persist a provider quote successfully before returning its quote_id. If cache persistence fails, return unavailable for that quote and offer the already defined manual/unvalued choices; do not return a provider-attributed quote the write RPC cannot verify. Apply the explicit 15-significant-digit reference-quote normalization policy from design.md, retain the original raw response in bounded non-user provider fixtures, and use scaled BigInt for reciprocal conversion. User monetary amounts never pass through this normalization. Provider quote rows referenced by transactions are retained; do not expire them with the current-refresh lease.

Missing crypto credentials, unsupported historical access and provider 403/429/5xx are tested route results. Do not add a timer/cron dependency; refresh on demand with server-side cache and bounded concurrency. Use the defined short refresh lease to prevent a cross-instance stampede; one atomic database conditional update is sufficient, with no queue service. Lease timeout must be bounded and released on failure. Treat this as necessary provider-cost protection, not an externally adjustable config surface.

## 9. Rollout, rollback and stop conditions

Before release: G0..G4 pass; existing audit blockers outside this scope remain separately tracked. Complete these eight fixes does **not** certify subscriptions, App Store legal readiness or product-market fit.

Pilot order: synthetic local tests → staging migration from representative old stores → two-user/two-device staging → one explicitly selected owner account → small coordinated upgraded group. Do not enable adoption automatically for every account on first launch.

Stop immediately for unexplained balance/count changes, a cross-owner read/write, duplicate acceptance of one operation, inability to restore a backup, loss of pending intent, partial transfer visibility, unexpected provider bills or a new storage crash. Preserve evidence and halt adoption; do not wipe affected datasets.

Rollback has two meanings:

- **Before adoption:** disable new code entry points for the pilot and leave additive columns/tables in place. Legacy accounts remain usable. No destructive schema rollback is needed.
- **After adoption/new writes:** never downgrade the app to the old mutable-balance client or drop new columns. Stop cloud dispatch, keep local persistent writes/drafts according to storage health, and ship a forward fix. Restore a backup only through a reconciliation plan that accounts for writes since the backup; replay validated accepted operations from retained receipts/feed. Blindly restoring an earlier database loses later financial data.

The execution report must identify deployed app/backend revisions, migration identifiers and verified project, accepted gates, actual test artifacts, pilot owner approval, start/end counts, remaining issues and exact rollback action. No production change is considered completed until the applied state has been read back and verified.
