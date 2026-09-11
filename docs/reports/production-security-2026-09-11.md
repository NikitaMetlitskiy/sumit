# Production change — parse-count functions closed to the public API

**Date:** 2026-09-11. **Project:** `sumit` (`mjhosrblavjdxirayvqt`), status `ACTIVE_HEALTHY` before and after. **Approved by the owner** in chat on 2026-09-11.

## The hole

`public.increment_parse_count(uid uuid)` and `public.reset_monthly_parses()` are `SECURITY DEFINER` functions, and both were executable by `anon` and `authenticated` through `/rest/v1/rpc/<name>`. With only the public anon key embedded in the app, anyone could:

- call `increment_parse_count` with **any** user's id and exhaust that user's monthly parse quota, once the paywall is enabled, and
- call `reset_monthly_parses` to reset stale counters for everyone.

Both functions also had a role-mutable `search_path`, which is its own escalation route for a `SECURITY DEFINER` function.

## Callers checked before changing anything

| Function | Caller | Needs public access? |
|---|---|---|
| `increment_parse_count` | Vercel backend only, through the service-role client (`api/_lib/usage.js`) | No |
| `reset_monthly_parses` | None: not the iOS app, not the backend; `pg_cron` is not installed | No |

The iOS `StoreKitManager.incrementParseCount()` is a local counter and does not call either function.

## Change

Migration `Backend/migrations/20260911_07_revoke_public_parse_count_functions.sql`, applied as `20260911_07_revoke_public_parse_count_functions`:

- `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated` on both;
- `GRANT EXECUTE … TO service_role` on both;
- `SET search_path = public, pg_temp` on both.

## Verification, read back from production after applying

| Function | anon | authenticated | service_role | ACL | config |
|---|---|---|---|---|---|
| `increment_parse_count` | false | false | true | `{postgres=X, service_role=X}` | `search_path=public, pg_temp` |
| `reset_monthly_parses` | false | false | true | `{postgres=X, service_role=X}` | `search_path=public, pg_temp` |

The Supabase security advisor no longer lists either function under lint 0011, 0028 or 0029.

## Not changed, and why

The advisor still flags `increment_tx_count()`, `decrement_tx_count()` and `handle_new_user()` as `SECURITY DEFINER` with a mutable `search_path` and public `EXECUTE`. All three **return `trigger`** and are attached to triggers (`on_transaction_insert` / `on_transaction_delete` on `transactions`, `on_auth_user_created` on `auth.users`). Postgres refuses to call a trigger function directly, so the RPC route is not exploitable the way the two functions above were. Pinning their `search_path` is still worthwhile hardening, but it was not part of what was approved, so it was left for a separate decision.

The remaining advisor items are unchanged: RLS without policies on the `*_backup_2026_05_19` tables and `rate_refresh_leases` (intentional: server-only), `authenticated` access to the two ledger RPCs (intentional: they are the client API and scope by the caller's JWT), and leaked-password protection being disabled in Auth settings.
