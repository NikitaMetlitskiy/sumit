// Route tests with every external dependency mocked: no network, no OpenAI
// call, no Supabase, and no package install needed to run them.
//
// Run with: npm test

import test, { mock } from "node:test";
import assert from "node:assert/strict";

const calls = { v1: [], v2: [], billed: [], rateLimited: 0 };
let nextModelResult = null;

function reset(result) {
  calls.v1 = [];
  calls.v2 = [];
  calls.billed = [];
  calls.rateLimited = 0;
  nextModelResult = result;
}

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

mock.module(new URL("../api/_lib/auth.js", import.meta.url).href, {
  namedExports: {
    HttpError,
    requireUser: async () => ({ userId: "user-1", anonymous: false }),
    sendError: (res, err) => res.status(err?.status || 500)
      .json({ error: err?.code || "internal_error", message: err?.message }),
  },
});

mock.module(new URL("../api/_lib/usage.js", import.meta.url).href, {
  namedExports: {
    enforceRateLimit: async () => { calls.rateLimited += 1; return { tier: "pro", used: 0 }; },
    incrementParseCount: async (userId) => { calls.billed.push(userId); },
  },
});

mock.module(new URL("../api/_lib/openai.js", import.meta.url).href, {
  namedExports: {
    parseText: async (args) => { calls.v1.push(args); return nextModelResult; },
    parseImage: async (args) => { calls.v1.push(args); return nextModelResult; },
    parseTextV2: async (args) => { calls.v2.push(args); return nextModelResult; },
    parseImageV2: async (args) => { calls.v2.push(args); return nextModelResult; },
  },
});

const { default: parseRoute } = await import("../api/parse.js");
const { default: parseImageRoute } = await import("../api/parse-image.js");

function response() {
  const res = { statusCode: null, body: null };
  res.status = (code) => { res.statusCode = code; return res; };
  res.json = (body) => { res.body = body; return res; };
  return res;
}

async function call(route, body) {
  const res = response();
  await route({ method: "POST", headers: { authorization: "Bearer t" }, body }, res);
  return res;
}

const context = { local_date: "2026-05-19", timezone: "Europe/Kyiv", locale: "uk-UA" };
const image = "data:image/jpeg;base64,AAAA";

const modelAnswer = Object.freeze({
  type: "expense", amount_decimal: "12.50", currency: "EUR", category: "Food",
  merchant: "Cafe", date: "2026-05-18", note: "", confidence: 0.9, wallet_name: "",
});

// MARK: — Version 1 is untouched

test("a legacy client gets the old shape through the old prompt", async () => {
  const legacy = { type: "expense", amount: 12.5, currency: "EUR", date: "2026-05-18" };
  reset(legacy);

  const res = await call(parseRoute, { text: "12,50 кава" });

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, legacy);
  assert.equal(calls.v1.length, 1);
  assert.equal(calls.v2.length, 0);
  assert.deepEqual(calls.billed, ["user-1"]);
});

// MARK: — Version 2

test("a v2 text request returns the exact amount and is billed once", async () => {
  reset(modelAnswer);

  const res = await call(parseRoute, { text: "вчора 12,50 кава", contract_version: 2,
                                       segment_index: 2, ...context });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.contract_version, 2);
  assert.equal(res.body.amount_decimal, "12.5");
  assert.equal(res.body.amount, 12.5);
  assert.equal(res.body.segment_index, 2, "the segment keeps its index for correction");
  assert.equal(calls.v2.length, 1);
  assert.deepEqual(calls.v2[0].context,
                   { localDate: "2026-05-19", timeZone: "Europe/Kyiv", locale: "uk-UA", segmentIndex: 2 });
  assert.deepEqual(calls.billed, ["user-1"]);
});

test("a malformed model amount is a 422, not a guess, and is not billed", async () => {
  reset({ ...modelAnswer, amount_decimal: 12.5 });

  const res = await call(parseRoute, { text: "12.50 coffee", contract_version: 2, ...context });

  assert.equal(res.statusCode, 422);
  assert.deepEqual(res.body, { contract_version: 2, error: "invalid_model_output",
                               reason: "amount_not_string" });
  assert.deepEqual(calls.billed, []);
});

test("an unknown type from the model is refused rather than recorded as an expense", async () => {
  reset({ ...modelAnswer, type: "refund" });
  const res = await call(parseRoute, { text: "refund 12.50", contract_version: 2, ...context });
  assert.equal(res.statusCode, 422);
  assert.equal(res.body.reason, "unknown_type");
});

test("unparseable model output is a 422", async () => {
  reset({ error: "invalid_json", message: "not json" });
  const res = await call(parseRoute, { text: "12.50 coffee", contract_version: 2, ...context });
  assert.equal(res.statusCode, 422);
  assert.equal(res.body.error, "invalid_model_output");
  assert.equal(res.body.message, undefined, "raw model text is not passed through");
});

test("'not a transaction' is a normal answer and is not billed", async () => {
  reset({ error: "not_a_transaction" });
  const res = await call(parseRoute, { text: "hello", contract_version: 2, ...context });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { contract_version: 2, error: "not_a_transaction" });
  assert.deepEqual(calls.billed, []);
});

test("bad context is refused before the rate limit and before any paid call", async () => {
  reset(modelAnswer);

  const res = await call(parseRoute, { text: "12.50 coffee", contract_version: 2,
                                       ...context, timezone: "Nowhere/Void" });

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, "invalid_timezone");
  assert.equal(calls.v2.length, 0, "the model was never called");
  assert.equal(calls.rateLimited, 0, "the user's quota was not touched");
});

test("a v2 request without context is refused", async () => {
  reset(modelAnswer);
  const res = await call(parseRoute, { text: "12.50 coffee", contract_version: 2 });
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, "invalid_local_date");
});

test("an unsupported contract version is refused", async () => {
  reset(modelAnswer);
  const res = await call(parseRoute, { text: "12.50 coffee", contract_version: 9, ...context });
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, "unsupported_contract_version");
  assert.equal(calls.v1.length + calls.v2.length, 0);
});

// MARK: — The photo route takes the same validator

test("a receipt goes through the same validation as text", async () => {
  reset({ ...modelAnswer, amount_decimal: "12.345" });

  const res = await call(parseImageRoute, { image, contract_version: 2, ...context });

  assert.equal(res.statusCode, 422);
  assert.equal(res.body.reason, "excess_precision");
  assert.deepEqual(calls.billed, []);
});

test("a valid receipt returns the exact total", async () => {
  reset({ ...modelAnswer, amount_decimal: "0.00000001", currency: "BTC" });

  const res = await call(parseImageRoute, { image, contract_version: 2, ...context });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.amount_decimal, "0.00000001");
  assert.equal(res.body.currency, "BTC");
  assert.equal(calls.v2.length, 1);
  assert.equal(calls.v2[0].dataUrl, image);
});

test("a legacy receipt request still gets the old shape", async () => {
  const legacy = { type: "expense", amount: 12.5, currency: "EUR" };
  reset(legacy);
  const res = await call(parseImageRoute, { image });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, legacy);
  assert.equal(calls.v1.length, 1);
});
