# SumIt

AI-powered personal finance tracker for iOS. Talk to a chat in any language —
"500 грн такси", "$20 coffee yesterday", "100 USDC to Binance" — GPT parses
each line into a structured transaction, the user confirms via a card UI, and
everything syncs to Supabase.

## Repo layout

```
SumIt/                          – iOS app (SwiftUI + SwiftData, iOS 17+)
  SumItApp.swift
  Models/, Services/, Views/, ViewModels/
SumIt.xcodeproj/                – Xcode project
Backend/
  supabase_migration.sql        – RLS, indexes, triggers (apply via Supabase dashboard)
  vercel_changes.md             – walkthrough of backend changes
  vercel-project/               – ❗ deployable Vercel backend (Node, OpenAI, Supabase, StoreKit)
    api/                        – serverless functions
    package.json
    README.md
```

## Tech stack

| Layer | Tech |
|---|---|
| iOS | SwiftUI, SwiftData, StoreKit 2, Sign in with Apple, LocalAuthentication |
| Backend | Vercel (Node 20, ESM), `jose` JWKS, `@supabase/supabase-js`, `openai` |
| Data | Supabase Postgres with row-level security |
| Auth | Sign in with Apple → Supabase Auth → JWT in iOS Keychain |
| AI | GPT-4o-mini (Basic) / GPT-4o (Pro) |

## iOS build

1. Open `SumIt.xcodeproj` in Xcode 16+.
2. Select an iOS 17+ simulator or device, ⌘R.

For TestFlight: **Product → Archive** → Distribute → Upload.

Bundle ID `com.mykyta.SumIt`, Team `J98SU5UHZZ`.

## Backend deploy

1. Apply Supabase migration: paste `Backend/supabase_migration.sql` into Supabase
   Dashboard → SQL Editor. *(Already applied in production.)*
2. Push this repo to a Vercel project pointing at `Backend/vercel-project/`
   as the **Root Directory**.
3. In Vercel → Settings → Environment Variables, set:
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `OPENAI_API_KEY`
   (and `APPSTORE_*` when paywall goes live).
4. Trigger a deploy.

See `Backend/vercel-project/README.md` for full instructions.

## Security model

- iOS stores PIN as PBKDF2 (100k iter SHA256 + 16-byte salt) in Keychain.
- Supabase session lives in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Apple Sign-In uses a fresh `nonce` per request; Supabase verifies `sha256(nonce)` against the id_token claim.
- Row-level security on every Supabase table — `user_id = auth.uid()` only.
- `profiles.subscription_tier` is column-revoked from `authenticated`; only the
  service_role (i.e. the Vercel backend) can write it after App Store receipt validation.
- A trigger on transactions/wallets/categories forbids changing `user_id` once set.
