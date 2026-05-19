# Vercel backend changes for SumIt

These changes harden the `sumit-backend-ten.vercel.app` API so that:

1. `/api/parse` and `/api/parse-image` require a valid Supabase JWT (no anonymous calls draining OpenAI quota).
2. Per-user rate limits enforced server-side (client cannot reset its parse counter).
3. New `/api/storekit/verify` endpoint verifies App Store JWS server-side and writes `profiles.subscription_tier` — client never writes the tier.

---

## 1. Add Supabase JWT verification middleware

```js
// api/_lib/auth.js
import { createRemoteJWKSet, jwtVerify } from "jose";

const SUPABASE_URL = process.env.SUPABASE_URL;
const JWKS = createRemoteJWKSet(new URL(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`));

export async function requireUser(req) {
  const auth = req.headers.authorization || "";
  if (!auth.startsWith("Bearer ")) {
    throw Object.assign(new Error("Missing bearer token"), { status: 401 });
  }
  const token = auth.slice(7);
  try {
    const { payload } = await jwtVerify(token, JWKS, {
      audience: "authenticated",
      issuer: `${SUPABASE_URL}/auth/v1`,
    });
    return payload.sub; // Supabase user_id (UUID)
  } catch {
    throw Object.assign(new Error("Invalid token"), { status: 401 });
  }
}
```

Required env vars on Vercel:

| Key | Value |
|---|---|
| `SUPABASE_URL` | `https://mjhosrblavjdxirayvqt.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | (from Supabase dashboard — Settings → API → service_role) |
| `OPENAI_API_KEY` | OpenAI secret (keep server-side only) |

## 2. Wire auth into existing endpoints

```js
// api/parse.js
import { requireUser } from "./_lib/auth";
import { enforceRateLimit, incrementCount } from "./_lib/usage";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).end();
  let userId;
  try {
    userId = await requireUser(req);
  } catch (e) {
    return res.status(e.status || 401).json({ error: "unauthorized" });
  }

  try {
    await enforceRateLimit(userId);
  } catch (e) {
    return res.status(429).json({ error: "rate_limited", message: e.message });
  }

  // existing OpenAI call (unchanged)
  const result = await callOpenAI(req.body);
  await incrementCount(userId);
  return res.status(200).json(result);
}
```

## 3. Server-side rate limiting

```js
// api/_lib/usage.js
import { createClient } from "@supabase/supabase-js";

const sb = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

const LIMITS = { basic: 100, pro: Infinity };

export async function enforceRateLimit(userId) {
  const { data: profile } = await sb
    .from("profiles")
    .select("subscription_tier, monthly_parse_count, parse_count_reset_at")
    .eq("id", userId)
    .single();

  const tier = profile?.subscription_tier || "none";
  if (tier === "none") {
    const err = new Error("subscription_required");
    err.status = 403;
    throw err;
  }
  // Reset window every UTC month
  const now = new Date();
  const resetAt = profile?.parse_count_reset_at
    ? new Date(profile.parse_count_reset_at)
    : null;
  const expired =
    !resetAt ||
    resetAt.getUTCFullYear() !== now.getUTCFullYear() ||
    resetAt.getUTCMonth() !== now.getUTCMonth();
  let used = expired ? 0 : profile.monthly_parse_count || 0;
  if (used >= (LIMITS[tier] || 0)) {
    const err = new Error("monthly_limit_reached");
    err.status = 429;
    throw err;
  }
  return used;
}

export async function incrementCount(userId) {
  await sb.rpc("increment_parse_count", { uid: userId });
}
```

Run this in Supabase SQL too:

```sql
CREATE OR REPLACE FUNCTION public.increment_parse_count(uid uuid)
RETURNS void AS $$
DECLARE m timestamptz;
BEGIN
    SELECT parse_count_reset_at INTO m FROM public.profiles WHERE id = uid;
    IF m IS NULL
       OR date_trunc('month', m AT TIME ZONE 'UTC')
          <> date_trunc('month', now() AT TIME ZONE 'UTC') THEN
        UPDATE public.profiles
           SET monthly_parse_count = 1, parse_count_reset_at = now()
         WHERE id = uid;
    ELSE
        UPDATE public.profiles
           SET monthly_parse_count = monthly_parse_count + 1
         WHERE id = uid;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION public.increment_parse_count FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.increment_parse_count TO service_role;
```

## 4. App Store receipt validation endpoint

```js
// api/storekit/verify.js
import { requireUser } from "../_lib/auth";
import { SignJWT, importPKCS8 } from "jose";
import fetch from "node-fetch";
import { createClient } from "@supabase/supabase-js";

const sb = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

// Apple App Store Server API config
const ISSUER_ID    = process.env.APPSTORE_ISSUER_ID;
const KEY_ID       = process.env.APPSTORE_KEY_ID;
const BUNDLE_ID    = "com.mykyta.SumIt";
const PRIVATE_KEY  = process.env.APPSTORE_PRIVATE_KEY; // p8 contents

async function appStoreToken() {
  const key = await importPKCS8(PRIVATE_KEY, "ES256");
  return new SignJWT({ bid: BUNDLE_ID })
    .setProtectedHeader({ alg: "ES256", kid: KEY_ID, typ: "JWT" })
    .setIssuer(ISSUER_ID)
    .setAudience("appstoreconnect-v1")
    .setIssuedAt()
    .setExpirationTime("20m")
    .sign(key);
}

export default async function handler(req, res) {
  let userId;
  try { userId = await requireUser(req); }
  catch (e) { return res.status(401).json({ error: "unauthorized" }); }

  const { jws } = req.body || {};
  if (!jws) return res.status(400).json({ error: "missing_jws" });

  // Decode payload (we still verify by re-querying the App Store)
  const [, payloadB64] = jws.split(".");
  const payload = JSON.parse(Buffer.from(payloadB64, "base64url").toString());
  const txId   = payload.transactionId;
  const prodId = payload.productId;

  const token = await appStoreToken();
  const r = await fetch(
    `https://api.storekit.itunes.apple.com/inApps/v1/transactions/${txId}`,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  if (!r.ok) return res.status(400).json({ error: "verification_failed" });

  const tier =
    prodId === "com.mykyta.SumIt.pro.monthly"   ? "pro"   :
    prodId === "com.mykyta.SumIt.basic.monthly" ? "basic" : "none";

  const expiresAt = payload.expiresDate ? new Date(payload.expiresDate) : null;

  await sb.from("profiles").update({
    subscription_tier: tier,
    subscription_expires_at: expiresAt,
  }).eq("id", userId);

  return res.status(200).json({ ok: true, tier });
}
```

## 5. Optional: ATS pinning (iOS-side)

After the new build is live in TestFlight, consider adding `NSPinnedDomains` to `Info.plist` to pin the leaf cert hash of both `*.supabase.co` and `*.vercel.app`. This must be paired with a rotation plan — pinning gone wrong can brick the app on cert renewal. Defer until v2 unless you have a strong reason now.

## Smoke tests

1. Hit `/api/parse` without `Authorization` → expect 401.
2. Hit `/api/parse` with an expired JWT → expect 401.
3. Sign in, then PATCH `/rest/v1/profiles?id=eq.<your_uid>` with `subscription_tier=pro` → expect 403 (column revoke).
4. After 100 parses on Basic, hit `/api/parse` → expect 429.
