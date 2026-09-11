-- SumIt — Task 06 part 1, reworked against the real production schema.
--
-- Supersedes 20260909_02_ledger_mutation_rpc.sql, which was written against a
-- reconstruction. The 2026-09-10 discovery showed that reconstruction was wrong
-- in three ways that matter (see docs/reports/production-discovery-2026-09-10.md):
--
-- 1. IDENTITY. `transactions.local_id` is text holding UUIDs written by Swift's
--    `UUID.uuidString`, which is uppercase — 32 of 70 production rows are.
--    PostgreSQL renders `uuid::text` lowercase, so a `local_id = v_entity::text`
--    comparison finds 38 of 70 rows and treats the other 32 as absent, which on
--    the next write means a duplicate. That is P1 on the server. Identity is now
--    compared through `ledger_same_identity`, and an ambiguous match is refused.
--
-- 2. LEGACY NOT NULL. `amount_in_base` and `rate_at_time` are NOT NULL in
--    production, but an unvalued transaction has neither. Writing 0 would state
--    the transaction is worth zero dollars — a different claim from "not valued
--    yet", and exactly the kind of quiet falsehood this work exists to remove.
--    Dropping NOT NULL only widens what the column accepts, so the shipped
--    client, which always sends both values, is unaffected.
--
-- 3. CATEGORY SNAPSHOT. `public.categories` has no `created_at` column, and the
--    DTO inventory never listed one for category snapshots.
--
-- This file also carries the helpers and executor policies that were in the
-- superseded file's part 1. That part was applied to staging on 2026-09-09 but
-- never reached production, so production has none of it.
--
-- Everything here is additive: two relaxed constraints, several new functions,
-- and policies for a role no client can become. It enables no new write route
-- on its own — the RPC arrives in 20260910_05.

-- 1. Relax the legacy NOT NULL constraints -----------------------------------

ALTER TABLE public.transactions ALTER COLUMN amount_in_base DROP NOT NULL;
ALTER TABLE public.transactions ALTER COLUMN rate_at_time   DROP NOT NULL;

-- 2. Executor access ---------------------------------------------------------
-- RLS is enabled on the ledger tables with no client policies, which is correct
-- for clients but would equally block the NOBYPASSRLS executor role. These
-- policies are owner-scoped and target only that role; `authenticated` and
-- `anon` are never members of it.

-- The executor cannot use auth.uid(): schema `auth` is owned by supabase_admin
-- and `postgres` holds no grant option on it, so granting USAGE silently does
-- nothing (PostgreSQL warns instead of erroring). Rather than give up the
-- NOBYPASSRLS executor and run as a BYPASSRLS role, the owner id is read from
-- the same place auth.uid() reads it — the request's JWT claims — through a
-- helper in a schema we control. It returns NULL with no JWT, exactly as
-- auth.uid() does, and every caller treats NULL as unauthenticated.
CREATE OR REPLACE FUNCTION public.ledger_current_uid()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid;
$fn$;

GRANT EXECUTE ON FUNCTION public.ledger_current_uid() TO sumit_ledger_executor;

DROP POLICY IF EXISTS "state_executor_owner" ON public.ledger_sync_state;
CREATE POLICY "state_executor_owner" ON public.ledger_sync_state
  FOR ALL TO sumit_ledger_executor
  USING (user_id = public.ledger_current_uid())
  WITH CHECK (user_id = public.ledger_current_uid());

DROP POLICY IF EXISTS "receipts_executor_owner" ON public.ledger_mutation_receipts;
CREATE POLICY "receipts_executor_owner" ON public.ledger_mutation_receipts
  FOR ALL TO sumit_ledger_executor
  USING (user_id = public.ledger_current_uid())
  WITH CHECK (user_id = public.ledger_current_uid());

DROP POLICY IF EXISTS "feed_executor_owner" ON public.ledger_change_log;
CREATE POLICY "feed_executor_owner" ON public.ledger_change_log
  FOR ALL TO sumit_ledger_executor
  USING (user_id = public.ledger_current_uid())
  WITH CHECK (user_id = public.ledger_current_uid());

-- Quotes are shared reference data; the executor may only read them.
DROP POLICY IF EXISTS "quotes_executor_read" ON public.rate_quotes;
CREATE POLICY "quotes_executor_read" ON public.rate_quotes
  FOR SELECT TO sumit_ledger_executor USING (true);

DROP POLICY IF EXISTS "tx_executor_owner" ON public.transactions;
CREATE POLICY "tx_executor_owner" ON public.transactions
  FOR ALL TO sumit_ledger_executor
  USING (user_id = (public.ledger_current_uid())::text)
  WITH CHECK (user_id = (public.ledger_current_uid())::text);

DROP POLICY IF EXISTS "wallet_executor_owner" ON public.wallets;
CREATE POLICY "wallet_executor_owner" ON public.wallets
  FOR ALL TO sumit_ledger_executor
  USING (user_id = (public.ledger_current_uid())::text)
  WITH CHECK (user_id = (public.ledger_current_uid())::text);

DROP POLICY IF EXISTS "cat_executor_owner" ON public.categories;
CREATE POLICY "cat_executor_owner" ON public.categories
  FOR ALL TO sumit_ledger_executor
  USING (user_id = (public.ledger_current_uid())::text)
  WITH CHECK (user_id = (public.ledger_current_uid())::text);

-- 3. Numeric helpers ---------------------------------------------------------

-- PostgreSQL's round() on numeric is half-up. The client quantizes half-even
-- (NSDecimalRound .bankers). Left implicit the two sides disagree on exact ties
-- such as 1.005, so the shared rule is written out.
CREATE OR REPLACE FUNCTION public.ledger_round_half_even(p_value numeric, p_scale integer)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
DECLARE
  factor    numeric := power(10::numeric, p_scale);
  scaled    numeric;
  low       numeric;
  remainder numeric;
BEGIN
  IF p_value IS NULL THEN RETURN NULL; END IF;
  scaled := p_value * factor;
  low := floor(scaled);
  remainder := scaled - low;
  IF remainder > 0.5 THEN
    low := low + 1;
  ELSIF remainder = 0.5 THEN
    IF (low - 2 * floor(low / 2)) <> 0 THEN   -- low is odd
      low := low + 1;
    END IF;
  END IF;
  RETURN low / factor;
END;
$fn$;

-- Canonical decimal text: dot separator, no grouping, no exponent, no trailing
-- fractional zeros. The same form the client's MoneyCodec emits.
CREATE OR REPLACE FUNCTION public.ledger_canonical_text(p_value numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT CASE WHEN p_value IS NULL THEN NULL ELSE trim_scale(p_value)::text END;
$fn$;

-- Strict full-string decimal parse: no exponents, no sign beyond a leading
-- minus, no grouping, no trailing characters. Nothing malformed reaches a cast.
CREATE OR REPLACE FUNCTION public.ledger_parse_decimal(p_text text, p_field text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF p_text IS NULL THEN RETURN NULL; END IF;
  IF p_text !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    RAISE EXCEPTION 'malformed_decimal:%', p_field USING ERRCODE = '22P02';
  END IF;
  RETURN p_text::numeric;
END;
$fn$;

-- 4. Identity matching -------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ledger_same_identity(p_local_id text, p_entity uuid)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT p_local_id IS NOT NULL AND lower(p_local_id) = lower(p_entity::text);
$fn$;

-- 5. Snapshot builders, matching the real columns ----------------------------

CREATE OR REPLACE FUNCTION public.ledger_transaction_snapshot(p_row public.transactions)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'entity_kind', 'transaction',
    'local_id', lower(p_row.local_id),
    'user_id', p_row.user_id,
    'ledger_revision', p_row.ledger_revision::text,
    'deleted_at', to_jsonb(p_row.deleted_at),
    'ledger_version', p_row.ledger_version,
    'type', p_row.type,
    'original_amount', public.ledger_canonical_text(p_row.amount_exact),
    'original_currency', p_row.original_currency,
    'wallet_id', to_jsonb(p_row.wallet_local_id),
    'wallet_amount', public.ledger_canonical_text(p_row.wallet_amount_exact),
    'destination_wallet_id', to_jsonb(p_row.destination_wallet_local_id),
    'destination_amount', public.ledger_canonical_text(p_row.destination_amount_exact),
    'category_name', coalesce(p_row.category_name, ''),
    'merchant', coalesce(p_row.merchant, ''),
    'note', coalesce(p_row.note, ''),
    'occurred_at', to_jsonb(p_row.occurred_at),
    'source', coalesce(p_row.source, 'manual'),
    'confidence', public.ledger_canonical_text(p_row.confidence::numeric),
    'raw_input', coalesce(p_row.raw_input, ''),
    'base_amount', public.ledger_canonical_text(p_row.base_amount_exact),
    'usd_per_unit', public.ledger_canonical_text(p_row.rate_exact),
    'valuation_state', p_row.valuation_state,
    'quote', coalesce(p_row.quote_metadata, 'null'::jsonb),
    'created_at', to_jsonb(p_row.created_at),
    'wallet_name', to_jsonb(p_row.wallet_name)
  );
$fn$;

CREATE OR REPLACE FUNCTION public.ledger_wallet_snapshot(p_row public.wallets)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'entity_kind', 'wallet',
    'local_id', lower(p_row.local_id),
    'user_id', p_row.user_id,
    'ledger_revision', p_row.ledger_revision::text,
    'deleted_at', to_jsonb(p_row.deleted_at),
    'ledger_version', p_row.ledger_version,
    'name', p_row.name,
    'type', coalesce(p_row.type, 'bank'),
    'currency', coalesce(p_row.currency, 'USD'),
    'opening_balance', public.ledger_canonical_text(p_row.opening_balance_exact),
    'icon', coalesce(p_row.icon, ''),
    'created_at', to_jsonb(p_row.created_at)
  );
$fn$;

-- No created_at: production's categories table has no such column.
CREATE OR REPLACE FUNCTION public.ledger_category_snapshot(p_row public.categories)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'entity_kind', 'category',
    'local_id', lower(p_row.local_id),
    'user_id', p_row.user_id,
    'ledger_revision', p_row.ledger_revision::text,
    'deleted_at', to_jsonb(p_row.deleted_at),
    'ledger_version', p_row.ledger_version,
    'name', p_row.name,
    'icon', coalesce(p_row.icon, ''),
    'color_hex', coalesce(p_row.color_hex, '000000'),
    'type', coalesce(p_row.type, 'expense'),
    'sort_order', coalesce(p_row.sort_order, 99),
    'is_default', coalesce(p_row.is_default, false)
  );
$fn$;
