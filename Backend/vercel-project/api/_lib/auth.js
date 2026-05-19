// Supabase JWT verification — every authenticated endpoint must call requireUser()
// before doing anything else. Validates against Supabase's public JWKS and returns
// the user_id (UUID). Throws an HttpError if the token is missing, expired, or invalid.

import { createRemoteJWKSet, jwtVerify } from "jose";

const SUPABASE_URL = process.env.SUPABASE_URL;
if (!SUPABASE_URL) {
  console.warn("SUPABASE_URL is not set — auth will fail.");
}

// JWKS is cached by jose (10 min default). One module-level set is fine across cold starts.
const JWKS = SUPABASE_URL
  ? createRemoteJWKSet(new URL(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`))
  : null;

export class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export async function requireUser(req) {
  if (process.env.ALLOW_ANONYMOUS_PARSE === "true") {
    return { userId: null, anonymous: true };
  }

  const header = req.headers.authorization || req.headers.Authorization || "";
  if (!header.startsWith("Bearer ")) {
    throw new HttpError(401, "missing_token", "Authorization header missing");
  }
  if (!JWKS) {
    throw new HttpError(500, "auth_misconfigured", "SUPABASE_URL not set on server");
  }

  const token = header.slice(7).trim();
  try {
    const { payload } = await jwtVerify(token, JWKS, {
      audience: "authenticated",
      issuer: `${SUPABASE_URL}/auth/v1`,
    });
    if (!payload.sub) {
      throw new HttpError(401, "invalid_token", "Token has no subject");
    }
    return { userId: payload.sub, anonymous: false, email: payload.email };
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(401, "invalid_token", "Token verification failed");
  }
}

/// Helper to emit a structured JSON error response.
export function sendError(res, err) {
  const status = err?.status || 500;
  const code = err?.code || "internal_error";
  const message = err?.message || "Internal error";
  res.status(status).json({ error: code, message });
}
