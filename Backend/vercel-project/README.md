# SumIt — Vercel backend

Stateless serverless functions that:

- Parse free-form expense text into structured transactions via OpenAI (`/api/parse`)
- Parse receipt photos via GPT-4o vision (`/api/parse-image`)
- Validate App Store receipts and update subscription tier (`/api/storekit/verify`)
- Receive Apple subscription notifications (`/api/storekit/notifications`, stub)
- Health probe (`/api/health`)

Every authenticated endpoint requires a valid Supabase JWT in the `Authorization` header.
Subscription tier and parse counts are stored server-side; the client cannot tamper with them.

## File layout

```
api/
├── _lib/
│   ├── auth.js          – Supabase JWT verification (jose + JWKS)
│   ├── supabase.js      – admin client (service_role key)
│   ├── usage.js         – tier gating + monthly parse counter
│   └── openai.js        – OpenAI client + parsing prompts
├── parse.js             – POST text → JSON transaction
├── parse-image.js       – POST image data URL → JSON transaction
├── storekit/
│   ├── verify.js        – POST JWS → validate with Apple, update profile
│   └── notifications.js – Apple webhook (stub)
└── health.js            – GET /api/health
```

## Env vars

See `.env.example`. Required on Vercel:

| Var | Required for | Where |
|---|---|---|
| `SUPABASE_URL` | all auth | Supabase Dashboard → Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | server writes | Supabase Dashboard → Settings → API → service_role (secret!) |
| `OPENAI_API_KEY` | parse endpoints | platform.openai.com → API keys |
| `APPSTORE_ISSUER_ID` | StoreKit verify | App Store Connect → Users and Access → Integrations |
| `APPSTORE_KEY_ID` | StoreKit verify | same |
| `APPSTORE_PRIVATE_KEY` | StoreKit verify | content of the `.p8` file (paste with line breaks) |
| `APPSTORE_BUNDLE_ID` | StoreKit verify | `com.mykyta.SumIt` (default) |
| `PARSE_LIMIT_BASIC` | rate limiting | default `100` |
| `ALLOW_ANONYMOUS_PARSE` | dev only | `false` in prod |
| `PAYWALL_ENABLED` | enforcement | `false` until products approved |

## Deploy

```bash
# Local dev
npm install
vercel dev          # http://localhost:3000

# Production deploy (Vercel will autodeploy on push to main if connected to GitHub)
vercel --prod
```

## Smoke tests

```bash
# 1. Health check (no auth)
curl https://sumit-backend-ten.vercel.app/api/health

# 2. Parse without auth → 401
curl -X POST https://sumit-backend-ten.vercel.app/api/parse \
  -H "Content-Type: application/json" \
  -d '{"text":"500 UAH taxi"}'

# 3. Parse with auth → 200
curl -X POST https://sumit-backend-ten.vercel.app/api/parse \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <supabase_jwt>" \
  -d '{"text":"500 UAH taxi"}'
```

## Security notes

- The Supabase service_role key bypasses RLS. Only ever read it from `process.env` —
  never log it, never return it in a response, never include it in iOS code.
- `enforceRateLimit` reads `profiles.subscription_tier` which is column-revoked
  from `authenticated` / `anon` roles (see `Backend/supabase_migration.sql`).
  So even if a client tries to PATCH it, RLS rejects.
- Every endpoint sets `response_format: json_object` so OpenAI can't return
  arbitrary text that breaks the iOS JSON decoder.
- Photo size cap is enforced both client-side (iOS, 2MB) and server-side (4MB request,
  3.5MB base64). Defense in depth.
