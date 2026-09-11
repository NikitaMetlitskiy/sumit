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

# 3. Parse with auth → 200 (contract v1: legacy numeric `amount`)
curl -X POST https://sumit-backend-ten.vercel.app/api/parse \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <supabase_jwt>" \
  -d '{"text":"500 UAH taxi"}'

# 4. Parse with contract v2 → 200 with exact `amount_decimal`
curl -X POST https://sumit-backend-ten.vercel.app/api/parse \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <supabase_jwt>" \
  -d '{"text":"вчора 12,50 EUR кава","contract_version":2,
       "local_date":"2026-05-19","timezone":"Europe/Kyiv","locale":"uk"}'
```

## Parse contract

A request without `contract_version` is **v1** and gets exactly the response it
always got. A request with `"contract_version": 2` must also send `local_date`
(`YYYY-MM-DD`), `timezone` (IANA) and `locale` (BCP-47), and may send
`segment_index` (0…19), which is echoed back. Bad context is a `400` before any
model call or quota check.

A v2 response carries `amount_decimal` — the exact amount as a string of digits
— plus a derived numeric `amount` for older readers. Both routes validate the
model's answer through `api/_lib/transaction-contract.js`
(`validateParsedTransactionV2`). An answer that breaks the contract (a numeric
amount, an unknown type, too many decimal places for the currency, an
impossible date) is a `422` with `{ "error": "invalid_model_output", "reason": <code> }`
and is not counted against the user's quota. Nothing is repaired or rounded.

## Exchange rates

`GET /api/rates?currencies=EUR,BTC&date=YYYY-MM-DD` (authenticated; `date` optional)
returns `{ quotes, unavailable }`. Each requested code appears in exactly one of the two.

- A rate is **USD per one unit** of the currency. USD is `identity` and never calls a provider.
- Fiat comes from Frankfurter v2 (no key), always requested with an explicit date — the undated
  aggregate has been observed labelled a day ahead. Crypto comes from CoinGecko and needs
  `COINGECKO_DEMO_API_KEY`; without it, crypto is `unavailable` with reason `provider_access`.
- A provider quote is returned only after it has been stored in `rate_quotes`, with that row's
  `quote_id`. The ledger write RPC verifies quotes against those rows.
- Nothing falls back to 1, to 0, or to today's price for a historical day.
- Attribution: the app shows "Powered by CoinGecko" (required by CoinGecko's API terms) and links
  Frankfurter. See `docs/reports/ledger-execution-task-16-2026-09-11.md` for the terms review.

## Tests

```bash
npm test
```

Uses Node's built-in test runner and module mocks — no install, no network, no
OpenAI or Supabase calls. Requires Node 22+.

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
