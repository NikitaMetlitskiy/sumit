-- SumIt — Supabase schema hardening migration
-- Run in: Supabase Dashboard → SQL Editor (project mjhosrblavjdxirayvqt)
-- This migration:
--   • Adds unique index on local_id for idempotent client upserts
--   • Adds deleted_at columns for soft-delete tombstones
--   • Tightens RLS policies (denies "local" user_id writes from client)
--   • Locks profiles.subscription_tier from client writes (server-only)
--   • Forbids client from PATCHing user_id (no mass-claim of "local" rows)
--
-- Safe to re-run: uses IF NOT EXISTS / DROP POLICY IF EXISTS.

BEGIN;

----------------------------------------------------------------------
-- 1. Schema additions
----------------------------------------------------------------------

-- Soft delete tombstones (used by client to filter restored rows)
ALTER TABLE public.transactions
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE public.wallets
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- Unique constraint to power upsert (on_conflict=local_id) idempotency
CREATE UNIQUE INDEX IF NOT EXISTS transactions_local_id_user_uniq
    ON public.transactions (user_id, local_id);

CREATE UNIQUE INDEX IF NOT EXISTS wallets_local_id_user_uniq
    ON public.wallets (user_id, local_id);

CREATE UNIQUE INDEX IF NOT EXISTS categories_local_id_user_uniq
    ON public.categories (user_id, local_id);

----------------------------------------------------------------------
-- 2. Drop the dangerous "local" rows
----------------------------------------------------------------------

-- Anyone holding the anon key has been able to write rows with user_id='local'
-- and (more dangerously) PATCH every "local" row to claim them. Wipe those rows
-- now that the new client uploads everything under auth.uid().
DELETE FROM public.transactions WHERE user_id = 'local' OR user_id IS NULL;
DELETE FROM public.wallets      WHERE user_id = 'local' OR user_id IS NULL;
DELETE FROM public.categories   WHERE user_id = 'local' OR user_id IS NULL;

----------------------------------------------------------------------
-- 3. Row-Level Security
----------------------------------------------------------------------

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles     ENABLE ROW LEVEL SECURITY;

-- Helper: every policy below assumes `user_id` is a UUID-as-text matching auth.uid()::text

DROP POLICY IF EXISTS "tx_select_own" ON public.transactions;
CREATE POLICY "tx_select_own" ON public.transactions
    FOR SELECT
    USING (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "tx_insert_own" ON public.transactions;
CREATE POLICY "tx_insert_own" ON public.transactions
    FOR INSERT
    WITH CHECK (
        user_id = (auth.uid())::text
        AND user_id IS NOT NULL
        AND user_id <> 'local'
    );

DROP POLICY IF EXISTS "tx_update_own" ON public.transactions;
CREATE POLICY "tx_update_own" ON public.transactions
    FOR UPDATE
    USING (user_id = (auth.uid())::text)
    WITH CHECK (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "tx_delete_own" ON public.transactions;
CREATE POLICY "tx_delete_own" ON public.transactions
    FOR DELETE
    USING (user_id = (auth.uid())::text);

-- Same pattern for wallets and categories
DROP POLICY IF EXISTS "wallet_select_own" ON public.wallets;
CREATE POLICY "wallet_select_own" ON public.wallets
    FOR SELECT USING (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "wallet_insert_own" ON public.wallets;
CREATE POLICY "wallet_insert_own" ON public.wallets
    FOR INSERT WITH CHECK (user_id = (auth.uid())::text AND user_id <> 'local');

DROP POLICY IF EXISTS "wallet_update_own" ON public.wallets;
CREATE POLICY "wallet_update_own" ON public.wallets
    FOR UPDATE USING (user_id = (auth.uid())::text)
                WITH CHECK (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "wallet_delete_own" ON public.wallets;
CREATE POLICY "wallet_delete_own" ON public.wallets
    FOR DELETE USING (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "cat_select_own" ON public.categories;
CREATE POLICY "cat_select_own" ON public.categories
    FOR SELECT USING (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "cat_insert_own" ON public.categories;
CREATE POLICY "cat_insert_own" ON public.categories
    FOR INSERT WITH CHECK (user_id = (auth.uid())::text AND user_id <> 'local');

DROP POLICY IF EXISTS "cat_update_own" ON public.categories;
CREATE POLICY "cat_update_own" ON public.categories
    FOR UPDATE USING (user_id = (auth.uid())::text)
                WITH CHECK (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "cat_delete_own" ON public.categories;
CREATE POLICY "cat_delete_own" ON public.categories
    FOR DELETE USING (user_id = (auth.uid())::text);

----------------------------------------------------------------------
-- 4. Profiles: client may read/update its own row, but NEVER write
--    subscription_tier or subscription_expires_at — those are server-only.
----------------------------------------------------------------------

DROP POLICY IF EXISTS "profile_select_own" ON public.profiles;
CREATE POLICY "profile_select_own" ON public.profiles
    FOR SELECT USING (id = auth.uid());

DROP POLICY IF EXISTS "profile_update_own_safe_columns" ON public.profiles;
CREATE POLICY "profile_update_own_safe_columns" ON public.profiles
    FOR UPDATE USING (id = auth.uid())
                WITH CHECK (id = auth.uid());

-- Column-level revoke: only the service role can write subscription fields.
REVOKE UPDATE (subscription_tier, subscription_expires_at, monthly_parse_count, parse_count_reset_at)
    ON public.profiles FROM authenticated;
REVOKE UPDATE (subscription_tier, subscription_expires_at, monthly_parse_count, parse_count_reset_at)
    ON public.profiles FROM anon;

-- Grant minimal updates the client legitimately needs (e.g. full_name).
GRANT UPDATE (full_name, email) ON public.profiles TO authenticated;

----------------------------------------------------------------------
-- 5. Forbid user_id rewrites (defence-in-depth)
----------------------------------------------------------------------

-- Trigger: refuse to change user_id once a row is created.
CREATE OR REPLACE FUNCTION public.prevent_user_id_change()
RETURNS trigger AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'user_id is immutable';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tx_no_user_id_rewrite ON public.transactions;
CREATE TRIGGER tx_no_user_id_rewrite
    BEFORE UPDATE ON public.transactions
    FOR EACH ROW EXECUTE FUNCTION public.prevent_user_id_change();

DROP TRIGGER IF EXISTS wallet_no_user_id_rewrite ON public.wallets;
CREATE TRIGGER wallet_no_user_id_rewrite
    BEFORE UPDATE ON public.wallets
    FOR EACH ROW EXECUTE FUNCTION public.prevent_user_id_change();

DROP TRIGGER IF EXISTS cat_no_user_id_rewrite ON public.categories;
CREATE TRIGGER cat_no_user_id_rewrite
    BEFORE UPDATE ON public.categories
    FOR EACH ROW EXECUTE FUNCTION public.prevent_user_id_change();

COMMIT;
