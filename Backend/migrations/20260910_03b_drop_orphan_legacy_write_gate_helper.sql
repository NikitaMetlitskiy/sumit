-- APPLIED to production 2026-09-10 as version 20260910065225
-- (`drop_orphan_legacy_write_gate_helper`). Recorded here verbatim from
-- supabase_migrations.schema_migrations so the repository reproduces production.
--
-- The write-gate policies were reverted, so this helper has no callers left.
-- An unused SECURITY DEFINER function that `anon` can reach through
-- /rest/v1/rpc/ is exactly the kind of leftover that becomes a problem later,
-- so it goes with the policies it served. The adoption task reintroduces both
-- together when they are actually needed.

DROP FUNCTION IF EXISTS public.ledger_legacy_writes_allowed_v1();
