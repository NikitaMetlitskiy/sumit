# SumIt — Backend deployment guide

This directory contains backend artefacts that ship alongside the iOS app but
need to be applied to your Supabase + Vercel infrastructure separately.

## Files

| File | Purpose |
|---|---|
| `supabase_migration.sql` | One-shot SQL migration for Supabase: RLS policies, soft-delete columns, unique indexes for upsert idempotency, trigger to forbid `user_id` rewrites, column-level revoke on `profiles.subscription_tier`. |
| `vercel_changes.md` | Code changes for the `sumit-backend-ten.vercel.app` Vercel project: Supabase JWT auth middleware, server-side rate limiting, StoreKit receipt validation endpoint. |

## Apply order

1. **Take a Supabase backup** (Dashboard → Database → Backups → Create).
2. Run `supabase_migration.sql` in the SQL Editor.
   - Note: the migration deletes every row whose `user_id = 'local'`. These
     records were created by clients sharing the anon key and are not safely
     attributable to a single user. Customers who never signed in lose
     their local backups — but locally cached SwiftData rows remain on each
     device and will re-sync once they sign in (now under their `auth.uid()`).
3. Deploy the Vercel changes in `vercel_changes.md`. Add the new env vars
   (`SUPABASE_SERVICE_ROLE_KEY`, `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`,
   `APPSTORE_PRIVATE_KEY`).
4. Ship the new iOS build to TestFlight. The client expects:
   - All write endpoints to be JWT-authenticated.
   - `transactions.deleted_at` and `wallets.deleted_at` columns to exist.
   - `local_id` to be UNIQUE per `(user_id, local_id)`.

## Apple credentials for receipt validation

In App Store Connect:
1. Users & Access → Integrations → App Store Connect API
2. Generate an API key with **App Manager** role. Save the `.p8` file (you can
   download it only once) and note the Key ID + Issuer ID.
3. The local file `Downloads/фин приложение/AuthKey_RPVK5CX7YM.p8` is the
   **Sign in with Apple** service key, NOT the App Store Server API key. Don't
   confuse them — they live in different sections of App Store Connect.
4. Set Vercel env vars:
   - `APPSTORE_KEY_ID` — e.g. `ABCDE12345`
   - `APPSTORE_ISSUER_ID` — UUID from App Store Connect
   - `APPSTORE_PRIVATE_KEY` — contents of the new `.p8` file (PEM block, multi-line)

## Verifying the lockdown

After applying the SQL migration, try this from any anon-key client:

```bash
curl -X PATCH "https://mjhosrblavjdxirayvqt.supabase.co/rest/v1/transactions?user_id=eq.local" \
  -H "apikey: <anon_key>" \
  -H "Authorization: Bearer <anon_key>" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"some-other-uid"}'
```

Expected response: **403 / no rows updated** (RLS denies and the trigger
rejects user_id rewrites). Pre-migration this PATCH succeeded.

## App Store Connect setup checklist (for PAYWALL_ENABLED = true)

1. **Subscriptions group** — create one (e.g. "SumIt Premium")
2. **Subscription products**:
   - `com.mykyta.SumIt.basic.monthly` — $2.99 / month
   - `com.mykyta.SumIt.pro.monthly` — $5.99 / month
3. **Subscription metadata**: localized display name + description in all 6
   languages (en, uk, ru, es, de, pl).
4. **Server URL** for App Store Server Notifications V2: point to
   `https://sumit-backend-ten.vercel.app/api/storekit/notifications`
   (implement this endpoint to handle renewals/refunds/cancellations).
5. Once products are **Approved**, flip `AppConfig.paywallEnabled = true` in
   the iOS code and ship a new TestFlight build.
