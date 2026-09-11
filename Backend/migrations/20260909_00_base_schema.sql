-- SumIt — base application schema
--
-- ⚠️ CORRECTION (2026-09-09). An earlier version of this header claimed the
-- production database was empty and had never been provisioned. THAT WAS WRONG
-- and the claim has been removed.
--
-- What actually happened: production was read while the project was still in
-- status COMING_UP after being resumed from pause. A restoring database
-- reported zero tables and zero auth rows. That was a partially-restored view,
-- not the truth. Once the project reached ACTIVE_HEALTHY the real content was
-- there: 3 auth users, 3 profiles, 70 transactions, 2 categories, plus
-- *_backup_2026_05_19 tables, currency_rates, usage_log and baby_checklist.
--
-- Never read a Supabase project's schema until `get_project` reports
-- ACTIVE_HEALTHY. An empty result from a restoring database is indistinguishable
-- from a genuinely empty one.
--
-- The real production schema also differs from this file and from
-- Backend/supabase_migration.sql: `transactions` carries a `timestamp` column
-- that no document mentions, and `categories` has NO `created_at` column. This
-- file is therefore NOT an accurate description of production and must not be
-- treated as one. It remains only as the shape the staging reconstruction used.
--
-- DO NOT APPLY THIS FILE ANYWHERE until it has been rebuilt from a real
-- discovery pass against an ACTIVE_HEALTHY production database.

BEGIN;

CREATE TABLE IF NOT EXISTS public.profiles (
    id                      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email                   text,
    full_name               text,
    subscription_tier       text NOT NULL DEFAULT 'none',
    subscription_expires_at timestamptz,
    monthly_parse_count     integer NOT NULL DEFAULT 0,
    parse_count_reset_at    timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.transactions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           text NOT NULL,
    local_id          text,
    type              text NOT NULL,
    original_amount   double precision NOT NULL,
    original_currency text NOT NULL,
    amount_in_base    double precision,
    base_currency     text DEFAULT 'USD',
    rate_at_time      double precision,
    category_name     text,
    merchant          text,
    note              text,
    occurred_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    source            text,
    confidence        double precision,
    raw_input         text,
    wallet_name       text,
    deleted_at        timestamptz
);

CREATE TABLE IF NOT EXISTS public.wallets (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    text NOT NULL,
    local_id   text,
    name       text NOT NULL,
    type       text,
    currency   text,
    balance    double precision NOT NULL DEFAULT 0,
    icon       text,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.categories (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    text NOT NULL,
    local_id   text,
    name       text NOT NULL,
    icon       text,
    color_hex  text,
    type       text,
    is_default boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 99,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS transactions_local_id_user_uniq ON public.transactions (user_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS wallets_local_id_user_uniq      ON public.wallets (user_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS categories_local_id_user_uniq   ON public.categories (user_id, local_id);

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tx_select_own" ON public.transactions;
CREATE POLICY "tx_select_own" ON public.transactions
    FOR SELECT USING (user_id = (auth.uid())::text);
DROP POLICY IF EXISTS "tx_insert_own" ON public.transactions;
CREATE POLICY "tx_insert_own" ON public.transactions
    FOR INSERT WITH CHECK (user_id = (auth.uid())::text AND user_id IS NOT NULL AND user_id <> 'local');
DROP POLICY IF EXISTS "tx_update_own" ON public.transactions;
CREATE POLICY "tx_update_own" ON public.transactions
    FOR UPDATE USING (user_id = (auth.uid())::text) WITH CHECK (user_id = (auth.uid())::text);
DROP POLICY IF EXISTS "tx_delete_own" ON public.transactions;
CREATE POLICY "tx_delete_own" ON public.transactions
    FOR DELETE USING (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "wallet_select_own" ON public.wallets;
CREATE POLICY "wallet_select_own" ON public.wallets
    FOR SELECT USING (user_id = (auth.uid())::text);
DROP POLICY IF EXISTS "wallet_insert_own" ON public.wallets;
CREATE POLICY "wallet_insert_own" ON public.wallets
    FOR INSERT WITH CHECK (user_id = (auth.uid())::text AND user_id <> 'local');
DROP POLICY IF EXISTS "wallet_update_own" ON public.wallets;
CREATE POLICY "wallet_update_own" ON public.wallets
    FOR UPDATE USING (user_id = (auth.uid())::text) WITH CHECK (user_id = (auth.uid())::text);
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
    FOR UPDATE USING (user_id = (auth.uid())::text) WITH CHECK (user_id = (auth.uid())::text);
DROP POLICY IF EXISTS "cat_delete_own" ON public.categories;
CREATE POLICY "cat_delete_own" ON public.categories
    FOR DELETE USING (user_id = (auth.uid())::text);

DROP POLICY IF EXISTS "profile_select_own" ON public.profiles;
CREATE POLICY "profile_select_own" ON public.profiles
    FOR SELECT USING (id = auth.uid());
DROP POLICY IF EXISTS "profile_update_own_safe_columns" ON public.profiles;
CREATE POLICY "profile_update_own_safe_columns" ON public.profiles
    FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.transactions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wallets      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.categories   TO authenticated;
GRANT SELECT ON public.profiles TO authenticated;
GRANT UPDATE (full_name, email) ON public.profiles TO authenticated;
REVOKE UPDATE (subscription_tier, subscription_expires_at, monthly_parse_count, parse_count_reset_at)
    ON public.profiles FROM authenticated;

CREATE OR REPLACE FUNCTION public.prevent_user_id_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'user_id is immutable';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tx_no_user_id_rewrite ON public.transactions;
CREATE TRIGGER tx_no_user_id_rewrite BEFORE UPDATE ON public.transactions
    FOR EACH ROW EXECUTE FUNCTION public.prevent_user_id_change();
DROP TRIGGER IF EXISTS wallet_no_user_id_rewrite ON public.wallets;
CREATE TRIGGER wallet_no_user_id_rewrite BEFORE UPDATE ON public.wallets
    FOR EACH ROW EXECUTE FUNCTION public.prevent_user_id_change();
DROP TRIGGER IF EXISTS cat_no_user_id_rewrite ON public.categories;
CREATE TRIGGER cat_no_user_id_rewrite BEFORE UPDATE ON public.categories
    FOR EACH ROW EXECUTE FUNCTION public.prevent_user_id_change();

COMMIT;
