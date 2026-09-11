-- APPLIED to production 2026-09-10 as version 20260910065142
-- (`drop_redundant_duplicate_indexes`). Recorded here verbatim from
-- supabase_migrations.schema_migrations so the repository reproduces production.
--
-- Remove three redundant unique indexes created in error on 2026-09-09.
--
-- Production already had `transactions_user_local_id_uniq`,
-- `wallets_user_local_id_uniq` and `categories_user_local_id_uniq` on exactly
-- the same (user_id, local_id) columns (oids 31624-31626). The base_schema
-- migration used the names from Backend/supabase_migration.sql, which did not
-- match, so `CREATE UNIQUE INDEX IF NOT EXISTS` did not skip — it created a
-- second identical index on each table (oids 33544-33546).
--
-- Duplicates cost write time and storage and protect nothing extra. The
-- originals are kept; only the ones added by mistake are dropped.

DROP INDEX IF EXISTS public.transactions_local_id_user_uniq;
DROP INDEX IF EXISTS public.wallets_local_id_user_uniq;
DROP INDEX IF EXISTS public.categories_local_id_user_uniq;
