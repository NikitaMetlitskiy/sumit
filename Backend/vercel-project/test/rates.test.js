import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  POLICY,
  RateRequestError,
  canonicalNumericText,
  loadRateQuotes,
  normalizeProviderNumber,
  reciprocal18,
  validateRateRequest,
} from "../api/_lib/rates.js";

const PROBES = new URL("./fixtures/rates/probes-2026-09-11/", import.meta.url);

// MARK: — Fixture dependencies (test support, not a vendor abstraction)

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => (typeof body === "string" ? JSON.parse(body) : body),
  };
}

function frankfurterRows(date, rates) {
  return Object.entries(rates).map(([quote, rate]) => ({
    date, base: "USD", quote, rate, providers: [{ key: "ECB", date, rate }],
  }));
}

const fixtureDependencies = {
  base({ now = "2026-05-19T12:00:00.000Z", respond = () => jsonResponse(503, {}), rows = [],
         coingeckoApiKey = "demo-key-for-tests", store = null } = {}) {
    const clock = { now: new Date(now) };
    const shared = store ?? { quotes: [...rows], leases: new Map() };
    const calls = { fetch: [], claims: [], releases: [], inserts: [] };
    return {
      calls,
      clock,
      store: shared,
      coingeckoApiKey,
      now: () => new Date(clock.now),
      fetch: async (url, init) => {
        calls.fetch.push({ url, headers: init?.headers ?? {} });
        return respond(url, init);
      },
      readQuotes: async () => shared.quotes.map((row) => ({ ...row })),
      claimRefresh: async (key, leaseUntil) => {
        calls.claims.push(key);
        const current = shared.leases.get(key);
        if (current && current > clock.now) return false;
        shared.leases.set(key, leaseUntil);
        return true;
      },
      insertQuote: async (quote) => {
        const row = { ...quote, id: randomUUID() };
        calls.inserts.push(row);
        shared.quotes.push(row);
        return row;
      },
      releaseRefresh: async (key) => {
        calls.releases.push(key);
        shared.leases.delete(key);
      },
    };
  },
  withFiatFailure(status) {
    return this.base({ respond: () => jsonResponse(status, {}) });
  },
  withFiat(rates, { date = "2026-05-19", ...options } = {}) {
    return this.base({ ...options, respond: () => jsonResponse(200, frankfurterRows(date, rates)) });
  },
};

// MARK: — The example the plan names

test("missing foreign rate never becomes one", async () => {
  const result = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" },
                                      fixtureDependencies.withFiatFailure(503));
  assert.equal(result.quotes.length, 0);
  assert.equal(result.unavailable[0].currency, "EUR");
});

// MARK: — Normalisation and inversion (FX-19)

test("provider numbers normalise to 15 significant digits without Number arithmetic", () => {
  assert.equal(normalizeProviderNumber(1.2345678901234567), "1.23456789012346");
  assert.equal(normalizeProviderNumber(0.8), "0.8");
  assert.equal(normalizeProviderNumber(77146), "77146");
  assert.equal(normalizeProviderNumber(1e-8), "0.00000001");
  assert.equal(normalizeProviderNumber(1.5e21), "1500000000000000000000");
  assert.equal(normalizeProviderNumber(0.999844), "0.999844");
  for (const bad of [0, -1, NaN, Infinity, "1.08", null, undefined]) {
    assert.throws(() => normalizeProviderNumber(bad), /invalid_quote/);
  }
});

test("reciprocals are exact to 18 places, half-even", () => {
  assert.equal(reciprocal18("0.8"), "1.25");
  assert.equal(reciprocal18("3"), "0.333333333333333333");
  assert.equal(reciprocal18("0.00000001"), "100000000");
  assert.equal(reciprocal18("1.5"), "0.666666666666666667");
  // Exact ties at the 19th digit: 1/4e17 = 2.5e-18 and 1/1.6e16 = 6.25e-17.
  // Half-even keeps 2 and 62; half-up would have given 3 and 63.
  assert.equal(reciprocal18("400000000000000000"), "0.000000000000000002");
  assert.equal(reciprocal18("16000000000000000"), "0.000000000000000062");
});

test("a reciprocal that underflows or overflows the ledger scale is refused", () => {
  assert.throws(() => reciprocal18("10000000000000000000000"), /invalid_quote/);   // 1e-22 rounds to 0
  assert.throws(() => reciprocal18("0.000000000000000000001"), /invalid_quote/);   // 1e21: 22 integer digits
  assert.throws(() => reciprocal18("0"), /invalid_quote/);
  assert.throws(() => reciprocal18("1e3"), /invalid_quote/);
  assert.throws(() => reciprocal18("1.250"), /invalid_quote/, "non-canonical input is refused");
});

test("numeric text read back from Postgres is canonicalised", () => {
  assert.equal(canonicalNumericText("1.250000000000000000"), "1.25");
  assert.equal(canonicalNumericText("77146.000000000000000000"), "77146");
  assert.equal(canonicalNumericText("0.000000010000000000"), "0.00000001");
  assert.equal(canonicalNumericText("1"), "1");
  assert.throws(() => canonicalNumericText("-1.0"), /invalid_quote/);
  assert.throws(() => canonicalNumericText(1.25), /invalid_quote/);
});

// MARK: — Identity (FX-01)

test("USD is the identity quote and calls no provider", async () => {
  const deps = fixtureDependencies.base();
  const result = await loadRateQuotes({ currencies: ["USD"], date: null }, deps);
  assert.equal(deps.calls.fetch.length, 0);
  assert.equal(deps.calls.claims.length, 0);
  assert.deepEqual(result.unavailable, []);
  const [quote] = result.quotes;
  assert.equal(quote.usd_per_unit, "1");
  assert.equal(quote.source, "identity");
  assert.equal(quote.valuation_kind, "identity");
  assert.equal(quote.quote_id, null);
});

// MARK: — Direction (FX-02, FX-03, FX-04)

test("a fiat rate is inverted exactly once and persisted with its identity", async () => {
  const deps = fixtureDependencies.withFiat({ EUR: 0.8 });
  const result = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, deps);

  const [quote] = result.quotes;
  assert.equal(quote.usd_per_unit, "1.25", "1 USD = 0.8 EUR is 1.25 USD per EUR");
  assert.equal(quote.source, "frankfurter");
  assert.equal(quote.valuation_kind, "historical_reference");
  assert.equal(quote.requested_date, "2026-05-19");
  assert.match(quote.quote_id, /^[0-9a-f-]{36}$/);
  assert.equal(deps.calls.inserts.length, 1);
  assert.equal(deps.calls.inserts[0].id, quote.quote_id, "the returned ID is the persisted row's");
  assert.equal(quote.source_detail.provider_rate, "0.8");
  assert.equal(quote.source_detail.inverted, true);
  assert.equal(quote.source_detail.normalization, "toPrecision(15)");
});

function cryptoDeps(prices, { now = "2026-05-19T12:00:00.000Z", updatedAt, ...options } = {}) {
  const stamp = updatedAt ?? Math.floor(new Date(now).getTime() / 1000) - 60;
  return fixtureDependencies.base({
    now,
    ...options,
    respond: (url) => {
      if (!url.includes("/simple/price")) return jsonResponse(500, {});
      const body = {};
      for (const [id, usd] of Object.entries(prices)) body[id] = { usd, last_updated_at: stamp };
      return jsonResponse(200, body);
    },
  });
}

test("a crypto price is already USD per unit and is not inverted", async () => {
  const deps = cryptoDeps({ bitcoin: 77146 });
  const result = await loadRateQuotes({ currencies: ["BTC"], date: null }, deps);
  assert.equal(result.quotes[0].usd_per_unit, "77146");
  assert.equal(result.quotes[0].source_detail.inverted, false);
});

test("a stablecoin keeps the observed price; it is never pegged to 1", async () => {
  const deps = cryptoDeps({ "usd-coin": 0.999844, tether: 0.999695 });
  const result = await loadRateQuotes({ currencies: ["USDC", "USDT"], date: null }, deps);
  assert.deepEqual(result.quotes.map((q) => q.usd_per_unit), ["0.999844", "0.999695"]);
});

// MARK: — Provider failures (FX-05)

test("provider failures map to explicit, typed unavailability", async () => {
  const cases = [[403, "provider_access", false], [401, "provider_access", false],
                 [429, "provider_limit", true], [500, "provider_failure", true], [503, "provider_failure", true]];
  for (const [status, reason, retryable] of cases) {
    const result = await loadRateQuotes({ currencies: ["EUR", "JPY"], date: "2026-05-19" },
                                        fixtureDependencies.withFiatFailure(status));
    assert.deepEqual(result.quotes, [], `HTTP ${status}`);
    assert.deepEqual(result.unavailable, [
      { currency: "EUR", reason, retryable }, { currency: "JPY", reason, retryable },
    ], `HTTP ${status}`);
  }
});

test("a network error or non-JSON body is a provider failure", async () => {
  const thrown = fixtureDependencies.base({ respond: () => { throw new Error("socket hang up"); } });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: null }, thrown)).unavailable[0].reason,
               "provider_failure");

  const garbage = fixtureDependencies.base({ respond: () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError(); } }) });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: null }, garbage)).unavailable[0].reason,
               "provider_failure");
});

test("without a CoinGecko credential, crypto is unavailable and nothing is requested", async () => {
  // `null`, not `undefined`: an undefined option would pick up the fixture's default key.
  const deps = cryptoDeps({ bitcoin: 77146 }, { coingeckoApiKey: null });
  const result = await loadRateQuotes({ currencies: ["BTC"], date: null }, deps);
  assert.deepEqual(result.unavailable, [{ currency: "BTC", reason: "provider_access", retryable: false }]);
  assert.equal(deps.calls.fetch.length, 0);
});

test("a currency the provider left out is missing, not defaulted", async () => {
  const deps = fixtureDependencies.withFiat({ EUR: 0.8 });
  const result = await loadRateQuotes({ currencies: ["EUR", "KZT"], date: "2026-05-19" }, deps);
  assert.equal(result.quotes.length, 1);
  assert.deepEqual(result.unavailable, [{ currency: "KZT", reason: "missing_currency", retryable: false }]);
});

// MARK: — Bad observations (FX-06, FX-07)

test("zero, negative, non-numeric and wrong-base observations are refused", async () => {
  for (const rate of [0, -0.8, "0.8", null]) {
    const result = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" },
                                        fixtureDependencies.withFiat({ EUR: rate }));
    assert.equal(result.unavailable[0]?.reason, "invalid_quote", `rate ${rate}`);
  }
  const wrongBase = fixtureDependencies.base({
    respond: () => jsonResponse(200, [{ date: "2026-05-19", base: "EUR", quote: "EUR", rate: 1 }]),
  });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, wrongBase)).unavailable[0].reason,
               "invalid_quote");
});

test("a crypto observation more than five minutes in the future is refused", async () => {
  const now = "2026-05-19T12:00:00.000Z";
  const at = (ms) => Math.floor((new Date(now).getTime() + ms) / 1000);

  const ahead = cryptoDeps({ bitcoin: 77146 }, { now, updatedAt: at(6 * 60_000) });
  assert.equal((await loadRateQuotes({ currencies: ["BTC"], date: null }, ahead)).unavailable[0].reason, "invalid_quote");

  const withinTolerance = cryptoDeps({ bitcoin: 77146 }, { now, updatedAt: at(4 * 60_000) });
  assert.equal((await loadRateQuotes({ currencies: ["BTC"], date: null }, withinTolerance)).quotes.length, 1);
});

// MARK: — Freshness (FX-08, FX-09)

function cachedRow(overrides) {
  return {
    id: randomUUID(), currency: "EUR", usd_per_unit: "1.08", requested_date: null,
    effective_at: "2026-05-19T00:00:00.000Z", fetched_at: "2026-05-19T00:00:00.000Z",
    source: "frankfurter", source_detail: {}, valuation_kind: "current_reference",
    ...overrides,
  };
}

test("fiat: served from cache under 24h, refreshed at 24h", async () => {
  const row = cachedRow({ fetched_at: "2026-05-18T13:00:00.000Z", effective_at: "2026-05-18T00:00:00.000Z" });

  const young = fixtureDependencies.withFiat({ EUR: 0.9 }, { rows: [row], now: "2026-05-19T12:59:00.000Z" });
  const cached = await loadRateQuotes({ currencies: ["EUR"], date: null }, young);
  assert.equal(young.calls.fetch.length, 0);
  assert.equal(cached.quotes[0].quote_id, row.id);

  const due = fixtureDependencies.withFiat({ EUR: 0.9 }, { rows: [row], now: "2026-05-19T13:00:00.000Z",
                                                          date: "2026-05-19" });
  const refreshed = await loadRateQuotes({ currencies: ["EUR"], date: null }, due);
  assert.equal(due.calls.fetch.length, 1);
  assert.notEqual(refreshed.quotes[0].quote_id, row.id);
  assert.match(due.calls.fetch[0].url, /date=2026-05-19/, "a current fiat request is dated with today's UTC day");
});

test("fiat: usable automatically up to 96h old, labelled stale after", async () => {
  const effective = "2026-05-15T00:00:00.000Z";
  const row = cachedRow({ effective_at: effective, fetched_at: effective });
  const hours = (h) => new Date(new Date(effective).getTime() + h * 3_600_000).toISOString();

  // The provider is down, so the cache is all there is.
  const at96 = fixtureDependencies.base({ rows: [row], now: hours(96), respond: () => jsonResponse(503, {}) });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: null }, at96)).quotes[0].stale, false);

  const at97 = fixtureDependencies.base({ rows: [row], now: hours(97), respond: () => jsonResponse(503, {}) });
  const stale = await loadRateQuotes({ currencies: ["EUR"], date: null }, at97);
  assert.equal(stale.quotes[0].stale, true, "older than 96h needs explicit confirmation");
  assert.equal(stale.quotes[0].quote_id, row.id);
});

test("crypto: refresh due at 5m, automatic to 15m, stale at 16m", async () => {
  const effective = "2026-05-19T12:00:00.000Z";
  const row = cachedRow({ currency: "BTC", usd_per_unit: "77146", source: "coingecko",
                          effective_at: effective, fetched_at: effective });
  const minutes = (m) => new Date(new Date(effective).getTime() + m * 60_000).toISOString();

  const at4 = fixtureDependencies.base({ rows: [row], now: minutes(4) });
  await loadRateQuotes({ currencies: ["BTC"], date: null }, at4);
  assert.equal(at4.calls.fetch.length, 0, "under five minutes: cache");

  const at15 = fixtureDependencies.base({ rows: [row], now: minutes(15), respond: () => jsonResponse(503, {}) });
  const r15 = await loadRateQuotes({ currencies: ["BTC"], date: null }, at15);
  assert.equal(at15.calls.fetch.length, 1, "past five minutes: refresh attempted");
  assert.equal(r15.quotes[0].stale, false);

  const at16 = fixtureDependencies.base({ rows: [row], now: minutes(16), respond: () => jsonResponse(503, {}) });
  assert.equal((await loadRateQuotes({ currencies: ["BTC"], date: null }, at16)).quotes[0].stale, true);
});

// MARK: — Historical (FX-10, FX-11, FX-12)

test("a weekend day uses the previous observation and says which day it is", async () => {
  // 2026-05-17 is a Sunday.
  const deps = fixtureDependencies.withFiat({ EUR: 0.8 }, { date: "2026-05-15", now: "2026-05-19T12:00:00.000Z" });
  const [quote] = (await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-17" }, deps)).quotes;
  assert.equal(quote.requested_date, "2026-05-17");
  assert.equal(quote.effective_at, "2026-05-15T00:00:00.000Z", "the actual day, not the requested one");
});

test("a historical observation later than asked, or more than seven days earlier, is unavailable", async () => {
  const later = fixtureDependencies.withFiat({ EUR: 0.8 }, { date: "2026-05-18", now: "2026-05-19T12:00:00.000Z" });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-17" }, later)).unavailable[0].reason,
               "historical_unavailable");

  const tooOld = fixtureDependencies.withFiat({ EUR: 0.8 }, { date: "2026-05-09", now: "2026-05-19T12:00:00.000Z" });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-17" }, tooOld)).unavailable[0].reason,
               "historical_unavailable");

  const sevenDays = fixtureDependencies.withFiat({ EUR: 0.8 }, { date: "2026-05-10", now: "2026-05-19T12:00:00.000Z" });
  assert.equal((await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-17" }, sevenDays)).quotes.length, 1);
});

test("historical crypto never falls back to today's price", async () => {
  const history = (usd) => fixtureDependencies.base({
    now: "2026-05-19T12:00:00.000Z",
    respond: (url) => url.includes("/simple/price")
      ? jsonResponse(200, { bitcoin: { usd: 99999, last_updated_at: 1 } })
      : jsonResponse(200, usd === undefined ? { id: "bitcoin" } : { market_data: { current_price: { usd } } }),
  });

  const ok = history(65000.5);
  const [quote] = (await loadRateQuotes({ currencies: ["BTC"], date: "2026-05-10" }, ok)).quotes;
  assert.equal(quote.usd_per_unit, "65000.5");
  assert.equal(quote.effective_at, "2026-05-10T00:00:00.000Z");
  assert.match(ok.calls.fetch[0].url, /\/coins\/bitcoin\/history\?date=10-05-2026/);

  const noData = history(undefined);
  const missing = await loadRateQuotes({ currencies: ["BTC"], date: "2026-05-10" }, noData);
  assert.equal(missing.unavailable[0].reason, "historical_unavailable");
  assert.ok(noData.calls.fetch.every((c) => !c.url.includes("/simple/price")), "never asked for today's price");

  const tooOld = history(65000.5);
  assert.equal((await loadRateQuotes({ currencies: ["BTC"], date: "2025-05-18" }, tooOld)).unavailable[0].reason,
               "historical_unavailable");
  assert.equal(tooOld.calls.fetch.length, 0, "outside the Demo window: not even asked");

  const notYetPublished = fixtureDependencies.base({ now: "2026-05-19T00:20:00.000Z" });
  const early = await loadRateQuotes({ currencies: ["BTC"], date: "2026-05-19" }, notYetPublished);
  assert.deepEqual(early.unavailable, [{ currency: "BTC", reason: "historical_unavailable", retryable: true }]);
});

// MARK: — Concurrency and cache (FX-13, FX-14, FX-18, FX-20)

test("concurrent misses share one provider request through the lease", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const store = { quotes: [], leases: new Map() };
  let providerCalls = 0;
  const respond = async () => {
    providerCalls += 1;
    await gate;
    return jsonResponse(200, frankfurterRows("2026-05-19", { EUR: 0.8 }));
  };
  const first = fixtureDependencies.base({ store, respond });
  const second = fixtureDependencies.base({ store, respond });

  const a = loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, first);
  await new Promise((resolve) => setImmediate(resolve));
  const b = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, second);
  release();
  const resultA = await a;

  assert.equal(providerCalls, 1);
  assert.equal(resultA.quotes.length, 1);
  assert.deepEqual(b.unavailable, [{ currency: "EUR", reason: "refresh_in_progress", retryable: true }]);
  assert.equal(store.leases.size, 0, "the lease is released");
});

test("a cache read failure is reported and nothing is fetched", async () => {
  const deps = fixtureDependencies.withFiat({ EUR: 0.8 });
  deps.readQuotes = async () => { throw new Error("connection reset"); };
  const result = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, deps);
  assert.deepEqual(result.unavailable, [{ currency: "EUR", reason: "cache_failure", retryable: true }]);
  assert.equal(deps.calls.fetch.length, 0);
});

test("a quote that could not be persisted is not returned", async () => {
  const deps = fixtureDependencies.withFiat({ EUR: 0.8 });
  deps.insertQuote = async () => { throw new Error("insert failed"); };
  const result = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, deps);
  assert.deepEqual(result.quotes, [], "no quote without a verifiable identity");
  assert.equal(result.unavailable[0].reason, "cache_failure");
  assert.deepEqual(deps.calls.releases, ["frankfurter|EUR|historical_reference|2026-05-19"]);
});

test("an invalid cached row is never served", async () => {
  const bad = cachedRow({ requested_date: "2026-05-19", valuation_kind: "historical_reference", usd_per_unit: "0" });
  const deps = fixtureDependencies.base({ rows: [bad], respond: () => jsonResponse(503, {}) });
  const result = await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-19" }, deps);
  assert.deepEqual(result.quotes, []);
});

test("a corrected observation is a new row; the booked one is untouched", async () => {
  const booked = cachedRow({ requested_date: "2026-05-10", valuation_kind: "historical_reference",
                             effective_at: "2026-05-10T00:00:00.000Z", fetched_at: "2026-05-11T00:00:00.000Z" });
  const store = { quotes: [booked], leases: new Map() };
  const before = JSON.stringify(booked);

  // Simulate the correction arriving as a newer persisted row for the same key.
  const correction = { ...booked, id: randomUUID(), usd_per_unit: "1.09", fetched_at: "2026-05-12T00:00:00.000Z" };
  store.quotes.push(correction);

  const deps = fixtureDependencies.base({ store });
  const [quote] = (await loadRateQuotes({ currencies: ["EUR"], date: "2026-05-10" }, deps)).quotes;
  assert.equal(quote.quote_id, correction.id, "a new draft may take the newer observation");
  assert.equal(JSON.stringify(store.quotes[0]), before, "the booked row is unchanged and still resolvable");
});

// MARK: — Request validation (FX-15)

test("a bad request is refused before any provider or cache call", async () => {
  const now = new Date("2026-05-19T12:00:00.000Z");
  const cases = [
    [{ currencies: [] }, "missing_currencies"],
    [{ currencies: ["XYZ"] }, "unsupported_currency"],
    [{ currencies: ["EUR", "eur"] }, "duplicate_currency"],
    [{ currencies: new Array(16).fill("EUR") }, "too_many_currencies"],
    [{ currencies: ["EUR"], date: "2026-02-30" }, "invalid_date"],
    [{ currencies: ["EUR"], date: "2026-05-21" }, "future_date"],
  ];
  for (const [input, code] of cases) {
    assert.throws(() => validateRateRequest(input, now), (err) => err instanceof RateRequestError && err.code === code);
    const deps = fixtureDependencies.base();
    await assert.rejects(loadRateQuotes(input, deps), (err) => err.code === code);
    assert.equal(deps.calls.fetch.length + deps.calls.claims.length, 0);
  }
  // One day ahead of UTC is a real local "today" east of Greenwich.
  assert.deepEqual(validateRateRequest({ currencies: ["eur"], date: "2026-05-20" }, now),
                   { currencies: ["EUR"], date: "2026-05-20" });
});

test("each requested currency appears exactly once, in request order", async () => {
  const deps = fixtureDependencies.withFiat({ EUR: 0.8 });
  const result = await loadRateQuotes({ currencies: ["JPY", "USD", "EUR"], date: "2026-05-19" }, deps);
  const seen = [...result.quotes, ...result.unavailable].map((entry) => entry.currency);
  assert.deepEqual(seen.sort(), ["EUR", "JPY", "USD"]);
  assert.equal(new Set(seen).size, 3);
  assert.deepEqual(result.quotes.map((q) => q.currency), ["USD", "EUR"]);
});

test("provider requests carry only codes and dates; the key travels in a header", async () => {
  const fiat = fixtureDependencies.withFiat({ EUR: 0.8, JPY: 150 });
  await loadRateQuotes({ currencies: ["EUR", "JPY"], date: "2026-05-19" }, fiat);
  const url = new URL(fiat.calls.fetch[0].url);
  assert.deepEqual([...url.searchParams.keys()].sort(), ["base", "date", "expand", "quotes"]);

  const crypto = cryptoDeps({ bitcoin: 77146 });
  await loadRateQuotes({ currencies: ["BTC"], date: null }, crypto);
  assert.ok(!crypto.calls.fetch[0].url.includes("demo-key-for-tests"), "never in the URL");
  assert.equal(crypto.calls.fetch[0].headers["x-cg-demo-api-key"], "demo-key-for-tests");
});

// MARK: — Against the real responses saved on 2026-09-11

test("the saved historical Frankfurter response yields all ten fiat quotes", async () => {
  const body = readFileSync(new URL("frankfurter-v2-historical-2026-05-19.body.txt", PROBES), "utf8");
  const deps = fixtureDependencies.base({ now: "2026-09-11T18:30:28.000Z", respond: () => jsonResponse(200, body) });
  const codes = ["EUR", "UAH", "GBP", "PLN", "CZK", "CAD", "CHF", "RUB", "KZT", "JPY"];

  const result = await loadRateQuotes({ currencies: codes, date: "2026-05-19" }, deps);

  assert.deepEqual(result.unavailable, []);
  assert.equal(result.quotes.length, 10);
  const eur = result.quotes.find((q) => q.currency === "EUR");
  assert.equal(eur.source_detail.provider_rate, "0.85971");
  assert.equal(eur.usd_per_unit, reciprocal18("0.85971"));
  assert.ok(Math.abs(Number(eur.usd_per_unit) - 1 / 0.85971) < 1e-12, "direction: USD per EUR");
  assert.ok(eur.source_detail.providers.length > 0);
  assert.ok(result.quotes.every((q) => q.effective_at === "2026-05-19T00:00:00.000Z"));
});

test("the saved undated 'latest' response, labelled a day ahead, is refused as future-dated", async () => {
  const body = readFileSync(new URL("frankfurter-v2-latest.body.txt", PROBES), "utf8");
  const deps = fixtureDependencies.base({ now: "2026-09-11T18:30:20.000Z", respond: () => jsonResponse(200, body) });
  const result = await loadRateQuotes({ currencies: ["EUR", "UAH"], date: null }, deps);
  assert.deepEqual(result.quotes, []);
  assert.ok(result.unavailable.every((u) => u.reason === "invalid_quote"));
});

test("the saved dated-today response is accepted as the current quote", async () => {
  const body = readFileSync(new URL("frankfurter-v2-dated-today-utc.body.txt", PROBES), "utf8");
  const deps = fixtureDependencies.base({ now: "2026-09-11T18:31:00.000Z", respond: () => jsonResponse(200, body) });
  const result = await loadRateQuotes({ currencies: ["EUR", "UAH", "KZT"], date: null }, deps);
  assert.deepEqual(result.unavailable, []);
  assert.ok(result.quotes.every((q) => q.valuation_kind === "current_reference" && q.stale === false));
});

test("the policy numbers are the design's", () => {
  assert.equal(POLICY.fiat.refreshAfterMs, 24 * 3_600_000);
  assert.equal(POLICY.fiat.automaticUseMs, 96 * 3_600_000);
  assert.equal(POLICY.crypto.refreshAfterMs, 5 * 60_000);
  assert.equal(POLICY.crypto.automaticUseMs, 15 * 60_000);
  assert.equal(POLICY.futureToleranceMs, 5 * 60_000);
  assert.equal(POLICY.historicalFiatMaxLagDays, 7);
});
