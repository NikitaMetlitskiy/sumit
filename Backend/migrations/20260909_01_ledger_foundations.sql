-- SumIt — Task 05: ledger foundations (additive only)
--
-- Adds exact monetary columns, the per-owner synchronization tables, the
-- immutable rate cache, the scoped executor role and the legacy-write gate.
-- It enables no new write route: the RPCs arrive in migrations 02 and 03.
--
-- Nothing here drops, renames, retypes or deletes anything. Legacy rows keep
-- their double precision values and stay readable and writable exactly as
-- before, because ledger_version defaults to 0 and the legacy gate defaults to
-- allowing writes for any account without a state row.

-- 1. Exact columns -----------------------------------------------------------
-- New references are uuid. Legacy `local_id` stays text and is NOT cast: an
-- existing text column may hold values that are not valid UUIDs, and a blind
-- cast would fail the migration or corrupt identity.

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS amount_exact                numeric(38,18),
  ADD COLUMN IF NOT EXISTS base_amount_exact           numeric(38,18),
  ADD COLUMN IF NOT EXISTS rate_exact                  numeric(38,18),
  ADD COLUMN IF NOT EXISTS wallet_local_id             uuid,
  ADD COLUMN IF NOT EXISTS destination_wallet_local_id uuid,
  ADD COLUMN IF NOT EXISTS wallet_amount_exact         numeric(38,18),
  ADD COLUMN IF NOT EXISTS destination_amount_exact    numeric(38,18),
  ADD COLUMN IF NOT EXISTS quote_metadata              jsonb,
  ADD COLUMN IF NOT EXISTS valuation_state             text,
  ADD COLUMN IF NOT EXISTS ledger_revision             bigint  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ledger_version              integer NOT NULL DEFAULT 0;

ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS opening_balance_exact numeric(38,18),
  ADD COLUMN IF NOT EXISTS ledger_revision       bigint  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ledger_version        integer NOT NULL DEFAULT 0;

ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS deleted_at      timestamptz,
  ADD COLUMN IF NOT EXISTS ledger_revision bigint  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ledger_version  integer NOT NULL DEFAULT 0;

-- Version-scoped validation: adopted (v1) rows must carry exact values and a
-- known valuation state; legacy (v0) rows are untouched by these checks.
ALTER TABLE public.transactions DROP CONSTRAINT IF EXISTS transactions_v1_requires_exact;
ALTER TABLE public.transactions ADD CONSTRAINT transactions_v1_requires_exact CHECK (
  ledger_version = 0 OR (
    amount_exact IS NOT NULL
    AND amount_exact > 0
    AND valuation_state IN ('unvalued','valued','legacy_unverified')
  )
) NOT VALID;

ALTER TABLE public.wallets DROP CONSTRAINT IF EXISTS wallets_v1_requires_opening;
ALTER TABLE public.wallets ADD CONSTRAINT wallets_v1_requires_opening CHECK (
  ledger_version = 0 OR opening_balance_exact IS NOT NULL
) NOT VALID;

-- 2. Per-owner synchronization state ----------------------------------------

CREATE TABLE IF NOT EXISTS public.ledger_sync_state (
  user_id              uuid PRIMARY KEY REFERENCES auth.users(id),
  cursor               bigint  NOT NULL DEFAULT 0 CHECK (cursor >= 0),
  protocol_version     integer NOT NULL DEFAULT 0,
  writes_paused        boolean NOT NULL DEFAULT false,
  adoption_manifest_id uuid,
  adoption_checksum    text,
  adopted_at           timestamptz
);

CREATE TABLE IF NOT EXISTS public.ledger_mutation_receipts (
  user_id         uuid NOT NULL REFERENCES auth.users(id),
  operation_id    uuid NOT NULL,
  request         jsonb NOT NULL,
  response        jsonb NOT NULL,
  accepted_cursor bigint NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.ledger_change_log (
  user_id         uuid NOT NULL REFERENCES auth.users(id),
  cursor          bigint NOT NULL,
  operation_id    uuid,
  entity_kind     text NOT NULL CHECK (entity_kind IN ('transaction','wallet','category')),
  entity_local_id uuid NOT NULL,
  snapshot        jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, cursor)
);

-- 3. Rate cache --------------------------------------------------------------
-- Quote rows are immutable: a refresh inserts a new row rather than rewriting
-- one that a saved transaction already points at.

CREATE TABLE IF NOT EXISTS public.rate_quotes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  currency       text NOT NULL,
  usd_per_unit   numeric(38,18) NOT NULL CHECK (usd_per_unit > 0),
  requested_date date,
  effective_at   timestamptz NOT NULL,
  fetched_at     timestamptz NOT NULL DEFAULT now(),
  source         text NOT NULL,
  source_detail  jsonb NOT NULL DEFAULT '{}'::jsonb,
  valuation_kind text NOT NULL CHECK (valuation_kind IN
                   ('identity','manual','current_reference','historical_reference')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS rate_quotes_lookup
  ON public.rate_quotes (source, currency, valuation_kind, requested_date, effective_at DESC);

CREATE TABLE IF NOT EXISTS public.rate_refresh_leases (
  source         text NOT NULL,
  currency       text NOT NULL,
  quote_kind     text NOT NULL,
  requested_date text NOT NULL,   -- '' for a current quote; never null, so the key is total
  lease_until    timestamptz NOT NULL,
  PRIMARY KEY (source, currency, quote_kind, requested_date)
);

-- 4. Owner isolation ---------------------------------------------------------
-- RLS is enabled and NO policy is created for authenticated/anon, so these
-- tables are unreachable from a client even if a grant is inherited from
-- somewhere. Reads happen through the scoped RPCs only.

ALTER TABLE public.ledger_sync_state        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_mutation_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_change_log        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rate_quotes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rate_refresh_leases      ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.ledger_sync_state        FROM PUBLIC, authenticated, anon;
REVOKE ALL ON public.ledger_mutation_receipts FROM PUBLIC, authenticated, anon;
REVOKE ALL ON public.ledger_change_log        FROM PUBLIC, authenticated, anon;
REVOKE ALL ON public.rate_quotes              FROM PUBLIC, authenticated, anon;
REVOKE ALL ON public.rate_refresh_leases      FROM PUBLIC, authenticated, anon;

-- 5. Scoped executor role ----------------------------------------------------
-- NOLOGIN and NOBYPASSRLS: owning the ledger functions must not become a way
-- around row-level security. authenticated and anon are never granted
-- membership, so no client can SET ROLE into it.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sumit_ledger_executor') THEN
    CREATE ROLE sumit_ledger_executor NOLOGIN NOBYPASSRLS;
  END IF;
END
$$;

GRANT SELECT, INSERT, UPDATE ON public.ledger_sync_state        TO sumit_ledger_executor;
GRANT SELECT, INSERT          ON public.ledger_mutation_receipts TO sumit_ledger_executor;
GRANT SELECT, INSERT          ON public.ledger_change_log        TO sumit_ledger_executor;
GRANT SELECT, INSERT          ON public.rate_quotes              TO sumit_ledger_executor;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.rate_refresh_leases TO sumit_ledger_executor;
GRANT SELECT, INSERT, UPDATE  ON public.transactions TO sumit_ledger_executor;
GRANT SELECT, INSERT, UPDATE  ON public.wallets      TO sumit_ledger_executor;
GRANT SELECT, INSERT, UPDATE  ON public.categories   TO sumit_ledger_executor;
GRANT USAGE ON SCHEMA public TO sumit_ledger_executor;

-- 6. Legacy direct-write gate ------------------------------------------------
-- An adopted account must not be writable by an old binary going straight to
-- PostgREST. The helper is SECURITY DEFINER because a client cannot select
-- ledger_sync_state at all; it reads only the caller's own row.
--
-- An ABSENT state row means an ordinary legacy account and returns true. That
-- default matters: the opposite would lock out every existing user the moment
-- this migration lands.

CREATE OR REPLACE FUNCTION public.ledger_legacy_writes_allowed_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    ELSE COALESCE(
      (SELECT s.protocol_version = 0 AND s.writes_paused = false
         FROM public.ledger_sync_state s
        WHERE s.user_id = auth.uid()),
      true)
  END;
$$;

REVOKE EXECUTE ON FUNCTION public.ledger_legacy_writes_allowed_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ledger_legacy_writes_allowed_v1() TO authenticated;

-- Restrictive policies gate writes only. SELECT stays governed by the existing
-- owner policies, so an adopted account can still read its data with an old
-- client even while its direct writes are refused.

DROP POLICY IF EXISTS "tx_legacy_write_gate_insert" ON public.transactions;
CREATE POLICY "tx_legacy_write_gate_insert" ON public.transactions
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.ledger_legacy_writes_allowed_v1());
DROP POLICY IF EXISTS "tx_legacy_write_gate_update" ON public.transactions;
CREATE POLICY "tx_legacy_write_gate_update" ON public.transactions
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.ledger_legacy_writes_allowed_v1())
  WITH CHECK (public.ledger_legacy_writes_allowed_v1());
DROP POLICY IF EXISTS "tx_legacy_write_gate_delete" ON public.transactions;
CREATE POLICY "tx_legacy_write_gate_delete" ON public.transactions
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.ledger_legacy_writes_allowed_v1());

DROP POLICY IF EXISTS "wallet_legacy_write_gate_insert" ON public.wallets;
CREATE POLICY "wallet_legacy_write_gate_insert" ON public.wallets
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.ledger_legacy_writes_allowed_v1());
DROP POLICY IF EXISTS "wallet_legacy_write_gate_update" ON public.wallets;
CREATE POLICY "wallet_legacy_write_gate_update" ON public.wallets
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.ledger_legacy_writes_allowed_v1())
  WITH CHECK (public.ledger_legacy_writes_allowed_v1());
DROP POLICY IF EXISTS "wallet_legacy_write_gate_delete" ON public.wallets;
CREATE POLICY "wallet_legacy_write_gate_delete" ON public.wallets
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.ledger_legacy_writes_allowed_v1());

DROP POLICY IF EXISTS "cat_legacy_write_gate_insert" ON public.categories;
CREATE POLICY "cat_legacy_write_gate_insert" ON public.categories
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.ledger_legacy_writes_allowed_v1());
DROP POLICY IF EXISTS "cat_legacy_write_gate_update" ON public.categories;
CREATE POLICY "cat_legacy_write_gate_update" ON public.categories
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.ledger_legacy_writes_allowed_v1())
  WITH CHECK (public.ledger_legacy_writes_allowed_v1());
DROP POLICY IF EXISTS "cat_legacy_write_gate_delete" ON public.categories;
CREATE POLICY "cat_legacy_write_gate_delete" ON public.categories
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.ledger_legacy_writes_allowed_v1());
