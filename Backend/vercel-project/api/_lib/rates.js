// Exchange-rate quotes: two fixed providers, validated, persisted, never invented.
//
// A rate here is always "USD per one unit of currency". USD itself is exactly 1
// with source `identity` and never touches a provider. Every other currency
// either comes back as a quote with a persisted, server-issued `quote_id`, or
// comes back in `unavailable` with a reason. There is no fallback to 1, to 0,
// to yesterday's number, or to today's price for a historical crypto day.
//
// Provider numbers are reference observations, not user amounts. Each is
// normalised exactly once to 15 significant digits (`toPrecision(15)`, recorded
// in provenance), expanded to a plain decimal string, and from then on handled
// only as strings and BigInt. No JS Number arithmetic touches a rate.
//
// Evidence behind the choices below is in
// test/fixtures/rates/probes-2026-09-11 and the Task 16 execution report.

// MARK: — Currencies

export const FIAT_CURRENCIES = Object.freeze(["EUR", "UAH", "GBP", "PLN", "CZK", "CAD", "CHF", "RUB", "KZT", "JPY"]);

// Resolved on 2026-09-11 against CoinGecko's /coins/list by exact expected name
// AND symbol; each pair matched exactly one registry row (the symbols alone
// matched 12, 14, 60 and 49 rows). Registry-derived, not guessed.
export const CRYPTO_COIN_IDS = Object.freeze({
  BTC: "bitcoin",
  ETH: "ethereum",
  USDC: "usd-coin",
  USDT: "tether",
});

export const SUPPORTED_CURRENCIES = Object.freeze(["USD", ...FIAT_CURRENCIES, ...Object.keys(CRYPTO_COIN_IDS)]);

export const UNAVAILABLE_REASONS = Object.freeze([
  "provider_access", "provider_limit", "provider_failure", "missing_currency",
  "invalid_quote", "historical_unavailable", "cache_failure", "refresh_in_progress",
]);

// MARK: — Policy

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export const POLICY = Object.freeze({
  futureToleranceMs: 5 * MINUTE,
  fiat: { refreshAfterMs: 24 * HOUR, automaticUseMs: 96 * HOUR },
  crypto: { refreshAfterMs: 5 * MINUTE, automaticUseMs: 15 * MINUTE },
  historicalFiatMaxLagDays: 7,
  // CoinGecko: "Historical data via the Demo API is restricted to the past 365 days."
  historicalCryptoMaxAgeDays: 365,
  // CoinGecko: the last completed UTC day "becomes available 35 minutes after midnight".
  historicalCryptoPublishDelayMs: 35 * MINUTE,
  leaseMs: 30_000,
  providerTimeoutMs: 8_000,
});

const SOURCE_FIAT = "frankfurter";
const SOURCE_CRYPTO = "coingecko";
const NORMALIZATION = "toPrecision(15)";

const FRANKFURTER_RATES = "https://api.frankfurter.dev/v2/rates";
const COINGECKO_API = "https://api.coingecko.com/api/v3";

// numeric(38,18): at most 20 integer digits and 18 fractional digits.
const MAX_INTEGER_DIGITS = 20;
const MAX_FRACTION_DIGITS = 18;

// MARK: — Errors

export class RateRequestError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

class QuoteRejected extends Error {
  constructor(reason, retryable = false) {
    super(reason);
    this.reason = reason;
    this.retryable = retryable;
  }
}

function reject(reason, retryable = false) {
  throw new QuoteRejected(reason, retryable);
}

// MARK: — Exact decimal strings

const CANONICAL = /^(0|[1-9][0-9]*)(?:\.([0-9]*[1-9]))?$/;

function parseCanonical(text) {
  const match = typeof text === "string" ? CANONICAL.exec(text) : null;
  if (!match) reject("invalid_quote");
  const fraction = match[2] || "";
  return { digits: BigInt(match[1] + fraction), scale: fraction.length, integer: match[1], fraction };
}

function canonicalFromDigits(digits, pointIndex) {
  // `digits` is a string of decimal digits; the point sits `pointIndex` digits
  // from the left (it may be <= 0 or beyond the end).
  let integer;
  let fraction;
  if (pointIndex <= 0) {
    integer = "0";
    fraction = "0".repeat(-pointIndex) + digits;
  } else if (pointIndex >= digits.length) {
    integer = digits + "0".repeat(pointIndex - digits.length);
    fraction = "";
  } else {
    integer = digits.slice(0, pointIndex);
    fraction = digits.slice(pointIndex);
  }
  integer = integer.replace(/^0+(?=[0-9])/, "");
  fraction = fraction.replace(/0+$/, "");
  return fraction ? `${integer}.${fraction}` : integer;
}

/// A provider's numeric observation as a canonical decimal string, normalised
/// once to 15 significant digits. Exponent notation is expanded by moving the
/// digit boundary — never by multiplying.
export function normalizeProviderNumber(value) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) reject("invalid_quote");
  const text = value.toPrecision(15);
  const match = /^([0-9]+)(?:\.([0-9]+))?(?:e([+-][0-9]+))?$/.exec(text);
  if (!match) reject("invalid_quote");
  const integer = match[1];
  const fraction = match[2] || "";
  const exponent = match[3] ? Number.parseInt(match[3], 10) : 0;
  const canonical = canonicalFromDigits(integer + fraction, integer.length + exponent);
  if (canonical === "0") reject("invalid_quote");
  return canonical;
}

/// Postgres renders `numeric(38,18)::text` with every scale digit
/// (`1.250000000000000000`). The ledger's canonical form has none of them.
export function canonicalNumericText(text) {
  const match = typeof text === "string" ? /^([0-9]+)(?:\.([0-9]+))?$/.exec(text) : null;
  if (!match) reject("invalid_quote");
  return canonicalFromDigits(match[1] + (match[2] || ""), match[1].length);
}

function fitsLedgerRate(canonical) {
  const { integer, fraction } = parseCanonical(canonical);
  return integer.length <= MAX_INTEGER_DIGITS && fraction.length <= MAX_FRACTION_DIGITS;
}

/// 1 / value, rounded half-even to 18 fractional digits, with BigInt only.
/// For value = n / 10^s the result is 10^(s+18) / n scaled by 10^-18.
export function reciprocal18(canonical) {
  const { digits: n, scale: s } = parseCanonical(canonical);
  if (n === 0n) reject("invalid_quote");
  const numerator = 10n ** BigInt(s + MAX_FRACTION_DIGITS);
  let quotient = numerator / n;
  const twice = (numerator % n) * 2n;
  if (twice > n || (twice === n && quotient % 2n === 1n)) quotient += 1n;
  if (quotient === 0n) reject("invalid_quote");   // underflows the ledger's scale

  const padded = quotient.toString().padStart(MAX_FRACTION_DIGITS + 1, "0");
  const result = canonicalFromDigits(padded, padded.length - MAX_FRACTION_DIGITS);
  if (!fitsLedgerRate(result)) reject("invalid_quote");  // overflows numeric(38,18)
  return result;
}

// MARK: — Dates

const ISO_DAY = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/;

function isCalendarDay(text) {
  const match = typeof text === "string" ? ISO_DAY.exec(text) : null;
  if (!match) return false;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const probe = new Date(Date.UTC(year, month - 1, day));
  return probe.getUTCFullYear() === year && probe.getUTCMonth() === month - 1 && probe.getUTCDate() === day;
}

function dayStart(isoDay) {
  return new Date(`${isoDay}T00:00:00.000Z`);
}

function utcDay(date) {
  return date.toISOString().slice(0, 10);
}

function addDays(isoDay, days) {
  return utcDay(new Date(dayStart(isoDay).getTime() + days * DAY));
}

// MARK: — Request

/// Checks a quote request before anything else happens: at most one date, only
/// supported codes, no duplicates, nothing else. A rejected request never
/// reaches a provider or the cache.
export function validateRateRequest(input, now) {
  const currencies = input?.currencies;
  if (!Array.isArray(currencies) || currencies.length === 0) throw new RateRequestError("missing_currencies");
  if (currencies.length > SUPPORTED_CURRENCIES.length) throw new RateRequestError("too_many_currencies");

  const normalized = [];
  for (const code of currencies) {
    if (typeof code !== "string") throw new RateRequestError("unsupported_currency");
    const upper = code.trim().toUpperCase();
    if (!SUPPORTED_CURRENCIES.includes(upper)) throw new RateRequestError("unsupported_currency");
    if (normalized.includes(upper)) throw new RateRequestError("duplicate_currency");
    normalized.push(upper);
  }

  const date = input?.date ?? null;
  if (date !== null) {
    if (!isCalendarDay(date)) throw new RateRequestError("invalid_date");
    // A user east of UTC can be a calendar day ahead of the server; anything
    // later than that is a future date and has no observation.
    if (date > addDays(utcDay(now), 1)) throw new RateRequestError("future_date");
  }
  return { currencies: normalized, date };
}

// MARK: — Quotes

function leaseKey({ source, currency, kind, requestedDate }) {
  return `${source}|${currency}|${kind}|${requestedDate ?? ""}`;
}

function wireQuote(row, stale) {
  return {
    quote_id: row.id ?? null,
    currency: row.currency,
    usd_per_unit: row.usd_per_unit,
    requested_date: row.requested_date ?? null,
    effective_at: new Date(row.effective_at).toISOString(),
    fetched_at: new Date(row.fetched_at).toISOString(),
    source: row.source,
    source_detail: row.source_detail ?? {},
    valuation_kind: row.valuation_kind,
    stale,
  };
}

function identityQuote(now) {
  const at = now.toISOString();
  return {
    quote_id: null, currency: "USD", usd_per_unit: "1", requested_date: null,
    effective_at: at, fetched_at: at, source: "identity", source_detail: {},
    valuation_kind: "identity", stale: false,
  };
}

/// Checks a candidate quote against the request and the clock. Returns the
/// `stale` flag for a usable quote; throws `QuoteRejected` otherwise.
export function validateQuote(quote, request, clock) {
  const now = clock();
  if (quote?.currency !== request.currency) reject("invalid_quote");
  if (quote.valuation_kind !== request.kind) reject("invalid_quote");
  const rate = parseCanonical(quote.usd_per_unit);
  if (rate.digits === 0n || !fitsLedgerRate(quote.usd_per_unit)) reject("invalid_quote");

  const effective = new Date(quote.effective_at);
  if (Number.isNaN(effective.getTime())) reject("invalid_quote");
  if (effective.getTime() > now.getTime() + POLICY.futureToleranceMs) reject("invalid_quote");

  const isCrypto = request.source === SOURCE_CRYPTO;
  if (request.kind === "historical_reference") {
    const effectiveDay = utcDay(effective);
    if (effectiveDay > request.requestedDate) reject("historical_unavailable");
    if (isCrypto) {
      // A 00:00 UTC snapshot of exactly that day, or nothing.
      if (effectiveDay !== request.requestedDate) reject("historical_unavailable");
    } else if (effectiveDay < addDays(request.requestedDate, -POLICY.historicalFiatMaxLagDays)) {
      reject("historical_unavailable");
    }
    return false;
  }

  const window = isCrypto ? POLICY.crypto.automaticUseMs : POLICY.fiat.automaticUseMs;
  return now.getTime() - effective.getTime() > window;
}

// MARK: — Providers

function classifyHttpStatus(status) {
  if (status === 401 || status === 403) return new QuoteRejected("provider_access", false);
  if (status === 429) return new QuoteRejected("provider_limit", true);
  return new QuoteRejected("provider_failure", true);
}

async function getJSON(deps, url, headers = {}) {
  let response;
  try {
    response = await deps.fetch(url, {
      method: "GET",
      headers: { Accept: "application/json", ...headers },
      signal: AbortSignal.timeout(POLICY.providerTimeoutMs),
    });
  } catch {
    throw new QuoteRejected("provider_failure", true);
  }
  if (!response.ok) throw classifyHttpStatus(response.status);
  try {
    return await response.json();
  } catch {
    throw new QuoteRejected("provider_failure", true);
  }
}

/// Frankfurter v2, base USD. A current request is sent **with today's UTC date**:
/// the undated `latest` aggregate was observed labelled a day ahead of the
/// request (2026-09-12 at 2026-09-11T18:30Z), which the future-date rule has to
/// refuse. Dated, it returned the same rates labelled with the day asked for.
async function fetchFiat(deps, currencies, requestedDate) {
  const params = new URLSearchParams({
    base: "USD",
    quotes: currencies.join(","),
    date: requestedDate ?? utcDay(deps.now()),
    expand: "providers",
  });
  const body = await getJSON(deps, `${FRANKFURTER_RATES}?${params}`);
  if (!Array.isArray(body)) throw new QuoteRejected("invalid_quote", false);

  const byCurrency = new Map();
  for (const row of body) {
    if (row && typeof row.quote === "string") byCurrency.set(row.quote, row);
  }

  const results = new Map();
  for (const currency of currencies) {
    const row = byCurrency.get(currency);
    try {
      if (!row) reject("missing_currency");
      if (row.base !== "USD" || !isCalendarDay(row.date)) reject("invalid_quote");
      // 1 USD = X currency; the ledger stores USD per unit, so this is the one
      // place a fiat observation is inverted.
      const providerRate = normalizeProviderNumber(row.rate);
      results.set(currency, {
        currency,
        usd_per_unit: reciprocal18(providerRate),
        requested_date: requestedDate,
        effective_at: dayStart(row.date).toISOString(),
        source: SOURCE_FIAT,
        source_detail: {
          base: "USD",
          quote: currency,
          provider_rate: providerRate,
          provider_date: row.date,
          inverted: true,
          normalization: NORMALIZATION,
          providers: Array.isArray(row.providers)
            ? row.providers.filter((p) => p && typeof p.key === "string")
                           .map((p) => ({ key: p.key, date: p.date ?? null }))
            : [],
        },
        valuation_kind: requestedDate ? "historical_reference" : "current_reference",
      });
    } catch (err) {
      results.set(currency, err);
    }
  }
  return results;
}

function coingeckoHeaders(deps) {
  // Header only. The key never appears in a URL, where it would be logged.
  return { "x-cg-demo-api-key": deps.coingeckoApiKey };
}

async function fetchCryptoCurrent(deps, currencies) {
  const ids = currencies.map((code) => CRYPTO_COIN_IDS[code]);
  const params = new URLSearchParams({ ids: ids.join(","), vs_currencies: "usd", include_last_updated_at: "true" });
  const body = await getJSON(deps, `${COINGECKO_API}/simple/price?${params}`, coingeckoHeaders(deps));
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new QuoteRejected("invalid_quote", false);

  const results = new Map();
  for (const currency of currencies) {
    const id = CRYPTO_COIN_IDS[currency];
    try {
      const row = body[id];
      if (!row) reject("missing_currency");
      if (!Number.isInteger(row.last_updated_at) || row.last_updated_at <= 0) reject("invalid_quote");
      // `/simple/price` already reports USD per unit. Not inverted — and a
      // stablecoin keeps whatever the provider observed, never a forced 1.
      const price = normalizeProviderNumber(row.usd);
      results.set(currency, {
        currency,
        usd_per_unit: price,
        requested_date: null,
        effective_at: new Date(row.last_updated_at * 1000).toISOString(),
        source: SOURCE_CRYPTO,
        source_detail: {
          coin_id: id, vs_currency: "usd", provider_price: price,
          last_updated_at: row.last_updated_at, inverted: false, normalization: NORMALIZATION,
        },
        valuation_kind: "current_reference",
      });
    } catch (err) {
      results.set(currency, err);
    }
  }
  return results;
}

async function fetchCryptoHistorical(deps, currencies, requestedDate) {
  const now = deps.now();
  const results = new Map();
  const [year, month, day] = requestedDate.split("-");

  for (const currency of currencies) {
    const id = CRYPTO_COIN_IDS[currency];
    try {
      if (requestedDate < addDays(utcDay(now), -POLICY.historicalCryptoMaxAgeDays)) {
        reject("historical_unavailable", false);
      }
      if (now.getTime() < dayStart(requestedDate).getTime() + POLICY.historicalCryptoPublishDelayMs) {
        // Not published yet. Today's live price is not a substitute.
        reject("historical_unavailable", true);
      }
      const params = new URLSearchParams({ date: `${day}-${month}-${year}`, localization: "false" });
      const body = await getJSON(deps, `${COINGECKO_API}/coins/${id}/history?${params}`, coingeckoHeaders(deps));
      const usd = body?.market_data?.current_price?.usd;
      if (usd === undefined || usd === null) reject("historical_unavailable", false);
      const price = normalizeProviderNumber(usd);
      results.set(currency, {
        currency,
        usd_per_unit: price,
        requested_date: requestedDate,
        effective_at: dayStart(requestedDate).toISOString(),
        source: SOURCE_CRYPTO,
        source_detail: {
          coin_id: id, vs_currency: "usd", provider_price: price,
          snapshot: "00:00:00 UTC", inverted: false, normalization: NORMALIZATION,
        },
        valuation_kind: "historical_reference",
      });
    } catch (err) {
      if (!(err instanceof QuoteRejected)) throw err;
      results.set(currency, err);
    }
  }
  return results;
}

// MARK: — Loading

function unavailable(currency, reason, retryable) {
  return { currency, reason, retryable };
}

function newestFor(rows, key) {
  const wanted = leaseKey(key);
  let best = null;
  for (const row of rows) {
    const rowKey = leaseKey({ source: row.source, currency: row.currency,
                              kind: row.valuation_kind, requestedDate: row.requested_date ?? null });
    if (rowKey !== wanted) continue;
    if (!best || new Date(row.fetched_at) > new Date(best.fetched_at)) best = row;
  }
  return best;
}

/// Loads one provider's currencies through the cache.
async function loadGroup(deps, source, currencies, requestedDate, settle) {
  const kind = requestedDate ? "historical_reference" : "current_reference";
  const policy = source === SOURCE_CRYPTO ? POLICY.crypto : POLICY.fiat;
  const keys = currencies.map((currency) => ({ source, currency, kind, requestedDate }));
  const now = deps.now();

  let cachedRows;
  try {
    cachedRows = await deps.readQuotes(keys);
  } catch {
    for (const currency of currencies) settle(unavailable(currency, "cache_failure", true));
    return;
  }

  // A cached row is used only after it passes the same validation as a fresh one.
  const cached = new Map();
  for (const key of keys) {
    const row = newestFor(cachedRows ?? [], key);
    if (!row) continue;
    try {
      cached.set(key.currency, { row, stale: validateQuote(row, key, deps.now) });
    } catch {
      // An invalid cached row is ignored, never served.
    }
  }

  const needRefresh = [];
  for (const key of keys) {
    const hit = cached.get(key.currency);
    const fresh = hit && (kind === "historical_reference"
      || now.getTime() - new Date(hit.row.fetched_at).getTime() < policy.refreshAfterMs);
    if (fresh) settle(wireQuote(hit.row, hit.stale));
    else needRefresh.push(key);
  }
  if (needRefresh.length === 0) return;

  // Served from cache if a usable row exists, otherwise unavailable.
  const fallback = (key, reason, retryable) => {
    const hit = cached.get(key.currency);
    settle(hit ? wireQuote(hit.row, hit.stale) : unavailable(key.currency, reason, retryable));
  };

  if (source === SOURCE_CRYPTO && !deps.coingeckoApiKey) {
    for (const key of needRefresh) fallback(key, "provider_access", false);
    return;
  }

  // One refresher per key across every instance. Losing the claim means
  // someone else is already asking the provider.
  const claimed = [];
  const leaseUntil = new Date(now.getTime() + POLICY.leaseMs);
  for (const key of needRefresh) {
    try {
      if (await deps.claimRefresh(leaseKey(key), leaseUntil)) claimed.push(key);
      else fallback(key, "refresh_in_progress", true);
    } catch {
      fallback(key, "cache_failure", true);
    }
  }
  if (claimed.length === 0) return;

  try {
    const codes = claimed.map((key) => key.currency);
    let fetched;
    try {
      if (source === SOURCE_FIAT) fetched = await fetchFiat(deps, codes, requestedDate);
      else if (requestedDate) fetched = await fetchCryptoHistorical(deps, codes, requestedDate);
      else fetched = await fetchCryptoCurrent(deps, codes);
    } catch (err) {
      if (!(err instanceof QuoteRejected)) throw err;
      for (const key of claimed) fallback(key, err.reason, err.retryable);
      return;
    }

    for (const key of claimed) {
      const candidate = fetched.get(key.currency);
      if (candidate instanceof QuoteRejected || !candidate) {
        fallback(key, candidate?.reason ?? "missing_currency", candidate?.retryable ?? false);
        continue;
      }
      let stale;
      try {
        stale = validateQuote({ ...candidate, fetched_at: now.toISOString() }, key, deps.now);
      } catch (err) {
        fallback(key, err.reason ?? "invalid_quote", err.retryable ?? false);
        continue;
      }
      // Only a persisted row has an identity the write RPC can verify. A quote
      // that could not be stored is not returned.
      let persisted;
      try {
        persisted = await deps.insertQuote({ ...candidate, fetched_at: now.toISOString() });
      } catch {
        fallback(key, "cache_failure", true);
        continue;
      }
      if (!persisted?.id) {
        fallback(key, "cache_failure", true);
        continue;
      }
      settle(wireQuote(persisted, stale));
    }
  } finally {
    for (const key of claimed) {
      try { await deps.releaseRefresh(leaseKey(key)); } catch { /* the lease expires on its own */ }
    }
  }
}

/// The concrete rates entry point.
///
/// `input` is `{ currencies: string[], date: "YYYY-MM-DD" | null }`.
/// `deps` supplies `fetch`, `now()`, `readQuotes(keys)`, `claimRefresh(key, leaseUntil)`,
/// `insertQuote(quoteWithoutID)`, `releaseRefresh(key)` and, for crypto,
/// `coingeckoApiKey`.
///
/// Result: `{ quotes, unavailable }`. Every requested currency appears in
/// exactly one of the two, in request order.
export async function loadRateQuotes(input, deps) {
  const request = validateRateRequest(input, deps.now());
  const settled = new Map();
  const settle = (entry) => {
    if (!settled.has(entry.currency)) settled.set(entry.currency, entry);
  };

  for (const currency of request.currencies) {
    if (currency === "USD") settle(identityQuote(deps.now()));
  }

  const fiat = request.currencies.filter((code) => FIAT_CURRENCIES.includes(code));
  const crypto = request.currencies.filter((code) => code in CRYPTO_COIN_IDS);
  if (fiat.length) await loadGroup(deps, SOURCE_FIAT, fiat, request.date, settle);
  if (crypto.length) await loadGroup(deps, SOURCE_CRYPTO, crypto, request.date, settle);

  const quotes = [];
  const missing = [];
  for (const currency of request.currencies) {
    const entry = settled.get(currency) ?? unavailable(currency, "provider_failure", true);
    if ("reason" in entry) missing.push(entry);
    else quotes.push(entry);
  }
  return { quotes, unavailable: missing };
}

// MARK: — Supabase cache

const QUOTE_COLUMNS = [
  "id", "currency", "usd_per_unit:usd_per_unit::text", "requested_date", "effective_at",
  "fetched_at", "source", "source_detail", "valuation_kind",
].join(",");

function splitLeaseKey(key) {
  const [source, currency, quoteKind, requestedDate] = key.split("|");
  return { source, currency, quote_kind: quoteKind, requested_date: requestedDate ?? "" };
}

function fromDatabase(row) {
  return { ...row, usd_per_unit: canonicalNumericText(row.usd_per_unit) };
}

/// The production cache over the service-role client. `usd_per_unit` is read
/// back cast to text: PostgREST renders `numeric` as a JSON number, which a JS
/// client would parse into a double. The text is then canonicalised.
export function createSupabaseRateCache(client, now = () => new Date()) {
  return {
    async readQuotes(keys) {
      const rows = await Promise.all(keys.map(async (key) => {
        let query = client.from("rate_quotes").select(QUOTE_COLUMNS)
          .eq("source", key.source).eq("currency", key.currency).eq("valuation_kind", key.kind)
          .order("fetched_at", { ascending: false }).limit(1);
        query = key.requestedDate ? query.eq("requested_date", key.requestedDate) : query.is("requested_date", null);
        const { data, error } = await query;
        if (error) throw new Error("rate_cache_read_failed");
        return (data ?? []).map(fromDatabase);
      }));
      return rows.flat();
    },

    async claimRefresh(key, leaseUntil) {
      const row = { ...splitLeaseKey(key), lease_until: leaseUntil.toISOString() };
      const inserted = await client.from("rate_refresh_leases").insert(row);
      if (!inserted.error) return true;
      if (inserted.error.code !== "23505") throw new Error("rate_lease_failed");
      // The row exists. Take it over only if it has expired; the WHERE clause is
      // re-checked under the row lock, so two instances cannot both win.
      const { data, error } = await client.from("rate_refresh_leases")
        .update({ lease_until: row.lease_until })
        .match(splitLeaseKey(key))
        .lt("lease_until", now().toISOString())
        .select("source");
      if (error) throw new Error("rate_lease_failed");
      return (data?.length ?? 0) === 1;
    },

    async insertQuote(quote) {
      const { data, error } = await client.from("rate_quotes").insert({
        currency: quote.currency,
        usd_per_unit: quote.usd_per_unit,     // sent as a string; cast exactly by Postgres
        requested_date: quote.requested_date,
        effective_at: quote.effective_at,
        fetched_at: quote.fetched_at,
        source: quote.source,
        source_detail: quote.source_detail,
        valuation_kind: quote.valuation_kind,
      }).select(QUOTE_COLUMNS).single();
      if (error || !data) throw new Error("rate_cache_write_failed");
      const persisted = fromDatabase(data);
      // What was stored must be what was validated. Anything else is not a
      // quote the write RPC will later be able to match.
      if (persisted.usd_per_unit !== quote.usd_per_unit) throw new Error("rate_cache_write_mismatch");
      return persisted;
    },

    async releaseRefresh(key) {
      const { error } = await client.from("rate_refresh_leases").delete().match(splitLeaseKey(key));
      if (error) throw new Error("rate_lease_release_failed");
    },
  };
}
