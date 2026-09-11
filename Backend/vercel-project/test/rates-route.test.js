import test, { mock } from "node:test";
import assert from "node:assert/strict";

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

let authFails = false;

mock.module(new URL("../api/_lib/auth.js", import.meta.url).href, {
  namedExports: {
    HttpError,
    requireUser: async () => {
      if (authFails) throw new HttpError(401, "missing_token", "Authorization header missing");
      return { userId: "user-1" };
    },
    sendError: (res, err) => res.status(err?.status || 500).json({ error: err?.code || "internal_error" }),
  },
});

// The real module imports @supabase/supabase-js, which these tests do not need.
mock.module(new URL("../api/_lib/supabase.js", import.meta.url).href, {
  namedExports: { supabaseAdmin: () => { throw new Error("not used in tests"); } },
});

const { createRatesHandler } = await import("../api/rates.js");

function response() {
  const res = { statusCode: null, body: null, headers: {} };
  res.status = (code) => { res.statusCode = code; return res; };
  res.json = (body) => { res.body = body; return res; };
  res.setHeader = (name, value) => { res.headers[name] = value; };
  return res;
}

function tracked() {
  const state = { built: 0 };
  const handler = createRatesHandler(() => {
    state.built += 1;
    return {
      fetch: async () => { throw new Error("no provider in this test"); },
      now: () => new Date(),
      readQuotes: async () => [],
      claimRefresh: async () => true,
      insertQuote: async () => { throw new Error("unused"); },
      releaseRefresh: async () => {},
    };
  });
  return { handler, state };
}

async function call(handler, { method = "GET", query = {} } = {}) {
  const res = response();
  await handler({ method, headers: { authorization: "Bearer t" }, query }, res);
  return res;
}

test("only GET is accepted", async () => {
  const { handler } = tracked();
  assert.equal((await call(handler, { method: "POST" })).statusCode, 405);
});

test("authentication is required", async () => {
  const { handler, state } = tracked();
  authFails = true;
  try {
    const res = await call(handler, { query: { currencies: "USD" } });
    assert.equal(res.statusCode, 401);
    assert.equal(state.built, 0);
  } finally {
    authFails = false;
  }
});

test("a bad query is refused before dependencies are built (FX-15)", async () => {
  const cases = [
    [{}, "missing_currencies"],
    [{ currencies: "EUR,XYZ" }, "unsupported_currency"],
    [{ currencies: "EUR", date: "yesterday" }, "invalid_date"],
    [{ currencies: "EUR", date: ["2026-05-19", "2026-05-20"] }, "invalid_date"],
    [{ currencies: "EUR", amount: "12.5" }, "unexpected_parameter"],
    [{ currencies: "EUR,".repeat(40) }, "too_many_currencies"],
  ];
  for (const [query, code] of cases) {
    const { handler, state } = tracked();
    const res = await call(handler, { query });
    assert.equal(res.statusCode, 400, JSON.stringify(query));
    assert.equal(res.body.error, code, JSON.stringify(query));
    assert.equal(state.built, 0, "no provider, cache or credential was touched");
  }
});

test("a valid request returns the quotes and is not cacheable by intermediaries", async () => {
  const { handler, state } = tracked();
  const res = await call(handler, { query: { currencies: "USD" } });
  assert.equal(res.statusCode, 200);
  assert.equal(state.built, 1);
  assert.equal(res.body.quotes[0].source, "identity");
  assert.deepEqual(res.body.unavailable, []);
  assert.equal(res.headers["Cache-Control"], "private, no-store");
});
