// POST /api/storekit/verify — validate App Store transaction JWS and update profiles.subscription_tier
// Headers: Authorization: Bearer <supabase_jwt>
// Body: { jws: string }
//
// PAYWALL_ENABLED=false on iOS means this endpoint won't be called in production yet.
// It returns 503 until the required env vars (APPSTORE_*) are present so misconfig is loud.

import { SignJWT, importPKCS8 } from "jose";
import { requireUser, sendError, HttpError } from "../_lib/auth.js";
import { supabaseAdmin } from "../_lib/supabase.js";

const PRODUCT_TO_TIER = {
  "com.mykyta.SumIt.basic.monthly": "basic",
  "com.mykyta.SumIt.pro.monthly": "pro",
};

function isConfigured() {
  return Boolean(
    process.env.APPSTORE_ISSUER_ID &&
    process.env.APPSTORE_KEY_ID &&
    process.env.APPSTORE_PRIVATE_KEY
  );
}

async function appStoreToken() {
  const key = await importPKCS8(process.env.APPSTORE_PRIVATE_KEY, "ES256");
  return new SignJWT({ bid: process.env.APPSTORE_BUNDLE_ID || "com.mykyta.SumIt" })
    .setProtectedHeader({ alg: "ES256", kid: process.env.APPSTORE_KEY_ID, typ: "JWT" })
    .setIssuer(process.env.APPSTORE_ISSUER_ID)
    .setAudience("appstoreconnect-v1")
    .setIssuedAt()
    .setExpirationTime("20m")
    .sign(key);
}

function decodeJWSPayload(jws) {
  const [, payloadB64] = jws.split(".");
  if (!payloadB64) throw new HttpError(400, "invalid_jws", "JWS missing payload segment");
  return JSON.parse(Buffer.from(payloadB64, "base64url").toString("utf8"));
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  try {
    if (!isConfigured()) {
      throw new HttpError(503, "storekit_not_configured",
        "App Store Server API credentials not set in Vercel env");
    }

    const { userId } = await requireUser(req);
    if (!userId) throw new HttpError(401, "auth_required", "Sign-in required");

    const { jws } = req.body || {};
    if (typeof jws !== "string" || jws.length < 10) {
      throw new HttpError(400, "missing_jws", "`jws` is required");
    }

    // Decode the client-provided JWS to discover transactionId, then re-fetch from Apple
    // to confirm it really exists and hasn't been revoked. We never trust the client copy alone.
    const payload = decodeJWSPayload(jws);
    const txId = payload.transactionId;
    if (!txId) throw new HttpError(400, "invalid_jws", "transactionId missing");

    const token = await appStoreToken();
    const fetchUrl = `https://api.storekit.itunes.apple.com/inApps/v1/transactions/${txId}`;
    const apple = await fetch(fetchUrl, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!apple.ok) {
      throw new HttpError(400, "apple_verification_failed",
        `App Store returned ${apple.status}`);
    }
    const appleBody = await apple.json();
    const verifiedPayload = appleBody.signedTransactionInfo
      ? decodeJWSPayload(appleBody.signedTransactionInfo)
      : payload;

    const productId = verifiedPayload.productId || payload.productId;
    const tier = PRODUCT_TO_TIER[productId] || "none";
    const expiresAt = verifiedPayload.expiresDate
      ? new Date(verifiedPayload.expiresDate).toISOString()
      : null;
    const revoked = Boolean(verifiedPayload.revocationDate);

    const finalTier = revoked || (expiresAt && new Date(expiresAt) < new Date()) ? "none" : tier;

    const sb = supabaseAdmin();
    const { error } = await sb
      .from("profiles")
      .update({
        subscription_tier: finalTier,
        subscription_expires_at: expiresAt,
        original_transaction_id: verifiedPayload.originalTransactionId || null,
      })
      .eq("id", userId);

    if (error) throw new HttpError(500, "profile_update_failed", error.message);

    return res.status(200).json({ ok: true, tier: finalTier, expiresAt });
  } catch (err) {
    console.error("/api/storekit/verify error:", err?.code || err?.message);
    return sendError(res, err);
  }
}
