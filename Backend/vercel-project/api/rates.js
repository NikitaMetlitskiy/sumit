// GET /api/rates — dated exchange-rate quotes with provenance.
// Headers: Authorization: Bearer <supabase_jwt>
// Query:   currencies=EUR,BTC   (1…15 supported codes)
//          date=YYYY-MM-DD      (optional; absent means a current quote)
// Response: { quotes: RateQuote[], unavailable: [{ currency, reason, retryable }] }
//
// The request carries currency codes and a date, nothing else — never an
// amount, a merchant, a photo or a wallet name.

import { requireUser, sendError, HttpError } from "./_lib/auth.js";
import { supabaseAdmin } from "./_lib/supabase.js";
import {
  RateRequestError,
  createSupabaseRateCache,
  loadRateQuotes,
  validateRateRequest,
} from "./_lib/rates.js";

const ALLOWED_PARAMETERS = new Set(["currencies", "date"]);
const MAX_CURRENCIES_PARAM = 120;

function readQuery(req) {
  if (req.query && typeof req.query === "object") return req.query;
  const url = new URL(req.url || "/", "http://localhost");
  return Object.fromEntries(url.searchParams.entries());
}

/// Parses and validates the query. Throws `HttpError(400)` before any provider,
/// cache or credential is touched.
export function parseRatesQuery(query, now) {
  for (const name of Object.keys(query)) {
    if (!ALLOWED_PARAMETERS.has(name)) throw new HttpError(400, "unexpected_parameter", name);
  }
  const { currencies, date } = query;
  if (typeof currencies !== "string" || currencies.length === 0) {
    throw new HttpError(400, "missing_currencies", "`currencies` is required");
  }
  if (currencies.length > MAX_CURRENCIES_PARAM) {
    throw new HttpError(400, "too_many_currencies", "`currencies` is too long");
  }
  if (date !== undefined && typeof date !== "string") {
    throw new HttpError(400, "invalid_date", "`date` must be one YYYY-MM-DD value");
  }
  try {
    return validateRateRequest({ currencies: currencies.split(","), date: date || null }, now);
  } catch (err) {
    if (err instanceof RateRequestError) throw new HttpError(400, err.code, err.code);
    throw err;
  }
}

export function createRatesHandler(makeDependencies) {
  return async function handler(req, res) {
    if (req.method !== "GET") {
      return res.status(405).json({ error: "method_not_allowed" });
    }
    try {
      await requireUser(req);
      const input = parseRatesQuery(readQuery(req), new Date());
      const deps = makeDependencies();
      const result = await loadRateQuotes(input, deps);
      res.setHeader?.("Cache-Control", "private, no-store");
      return res.status(200).json(result);
    } catch (err) {
      // Codes only. A provider URL, a response body or a credential is never logged.
      console.error("/api/rates error:", err?.code || "internal_error");
      return sendError(res, err);
    }
  };
}

export default createRatesHandler(() => {
  const now = () => new Date();
  return {
    fetch: (url, init) => globalThis.fetch(url, init),
    now,
    // Optional. Without it crypto quotes are reported as `provider_access`.
    coingeckoApiKey: process.env.COINGECKO_DEMO_API_KEY || undefined,
    ...createSupabaseRateCache(supabaseAdmin(), now),
  };
});
