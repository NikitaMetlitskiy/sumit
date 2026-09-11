-- 20260911_07 — close public access to the parse-count functions.
--
-- Found during Task 06 discovery and confirmed on 2026-09-11 by the Supabase
-- security advisor (lint 0028/0029): both functions are SECURITY DEFINER and
-- were executable by `anon` and `authenticated` through
-- /rest/v1/rpc/<name>. That meant anyone holding the public anon key could:
--
--   * call increment_parse_count(uid) with any user's id and burn through that
--     user's monthly parse quota, and
--   * call reset_monthly_parses() and wipe every stale counter.
--
-- Callers, checked before revoking:
--   * increment_parse_count — only the Vercel backend, via the service-role
--     client (api/_lib/usage.js). service_role keeps EXECUTE.
--   * reset_monthly_parses — no caller in the iOS app, the backend, or pg_cron
--     (pg_cron is not installed). increment_parse_count already resets the
--     counter when a new month starts.
--
-- Both functions also had a role-mutable search_path (lint 0011). For a
-- SECURITY DEFINER function that is its own escalation route, so it is pinned.
--
-- Approved by the owner on 2026-09-11. Reversible: re-GRANT EXECUTE to the
-- roles below and RESET search_path.

REVOKE EXECUTE ON FUNCTION public.increment_parse_count(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reset_monthly_parses()      FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.increment_parse_count(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.reset_monthly_parses()      TO service_role;

ALTER FUNCTION public.increment_parse_count(uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.reset_monthly_parses()      SET search_path = public, pg_temp;
