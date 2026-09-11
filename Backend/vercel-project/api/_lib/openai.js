// Thin wrapper over the OpenAI SDK. Holds the system prompt + JSON contract for parsing.

import OpenAI from "openai";

let cached = null;
function client() {
  if (cached) return cached;
  if (!process.env.OPENAI_API_KEY) throw new Error("OPENAI_API_KEY missing");
  cached = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  return cached;
}

// Allowed models. Pin so callers can't ask for arbitrary expensive ones.
const ALLOWED_MODELS = new Set(["gpt-4o-mini", "gpt-4o"]);

function pickModel(modelHint) {
  if (typeof modelHint === "string" && ALLOWED_MODELS.has(modelHint)) return modelHint;
  return "gpt-4o-mini";
}

const SYSTEM_PROMPT = `You are SumIt, a transaction-parsing assistant for a personal finance iOS app.
Extract ONE transaction from the user's free-form text in any language.

Return STRICT JSON with these keys (no extra commentary, no markdown):
{
  "type": "expense" | "income" | "transfer",
  "amount": number,
  "currency": "USD" | "EUR" | "UAH" | "GBP" | "PLN" | "CZK" | "CAD" | "CHF" | "RUB" | "KZT" | "JPY" | "USDC" | "USDT" | "BTC" | "ETH",
  "category": "Food" | "Transport" | "Shopping" | "Health" | "Entertainment" | "Education" | "Housing" | "Bills" | "Travel" | "Subscriptions" | "Salary" | "Freelance" | "Other",
  "merchant": string,
  "date": "YYYY-MM-DD",
  "note": string,
  "confidence": number,
  "wallet_name": string
}

Rules:
- "amount" is always positive (sign comes from "type").
- "merchant" is the place or counterparty; empty string if unknown.
- "date" defaults to today if the text doesn't mention a date.
- "wallet_name" picks the closest match from the optional wallet list passed by the user; "" if none match.
- "confidence" is your honest 0–1 estimate.
- If the text is NOT a transaction (e.g. a greeting or question), return { "error": "not_a_transaction" }.`;

const IMAGE_PROMPT = `${SYSTEM_PROMPT}

The input is a photo of a receipt. Extract the TOTAL paid (or single-item total if no grand total), the merchant name printed on the receipt, and the date if visible. Currency is whatever symbol/code is on the receipt.`;

/// Parse plain text. `walletNames` is an optional string like "Monobank, Binance, Cash".
export async function parseText({ text, model, walletNames }) {
  const userMsg = walletNames
    ? `User wallets: ${walletNames}\n\nText: ${text}`
    : text;
  const completion = await client().chat.completions.create({
    model: pickModel(model),
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userMsg },
    ],
    response_format: { type: "json_object" },
    temperature: 0.1,
    max_tokens: 400,
  });
  return safeParseJSON(completion.choices?.[0]?.message?.content);
}

/// Parse a base64 data URL image.
export async function parseImage({ dataUrl, model }) {
  const completion = await client().chat.completions.create({
    model: pickModel(model),
    messages: [
      { role: "system", content: IMAGE_PROMPT },
      {
        role: "user",
        content: [
          { type: "text", text: "Extract the transaction from this receipt." },
          { type: "image_url", image_url: { url: dataUrl, detail: "low" } },
        ],
      },
    ],
    response_format: { type: "json_object" },
    temperature: 0.1,
    max_tokens: 400,
  });
  return safeParseJSON(completion.choices?.[0]?.message?.content);
}

// MARK: — Contract version 2

// The amount comes back as a JSON **string** of digits. A JSON number is a
// binary double by the time any code reads it, so asking for one guarantees
// that 12.50 or 0.00000001 can only arrive approximately.
const SYSTEM_PROMPT_V2 = `You are SumIt, a transaction-parsing assistant for a personal finance iOS app.
Extract ONE transaction from the user's free-form text in any language.

Return STRICT JSON with these keys (no extra commentary, no markdown):
{
  "type": "expense" | "income" | "transfer",
  "amount_decimal": string,
  "currency": "USD" | "EUR" | "UAH" | "GBP" | "PLN" | "CZK" | "CAD" | "CHF" | "RUB" | "KZT" | "JPY" | "USDC" | "USDT" | "BTC" | "ETH",
  "category": "Food" | "Transport" | "Shopping" | "Health" | "Entertainment" | "Education" | "Housing" | "Bills" | "Travel" | "Subscriptions" | "Salary" | "Freelance" | "Other",
  "merchant": string,
  "date": "YYYY-MM-DD",
  "note": string,
  "confidence": number,
  "wallet_name": string
}

Rules for "amount_decimal":
- A JSON string containing only digits and at most one "." as the decimal point. Examples: "12.5", "1234.56", "0.00000001".
- Copy the exact digits the user wrote. Never round, never estimate, never convert currency.
- No thousands separators, no spaces, no currency symbols, no sign, no exponent.
- The user's locale is given below. Use it to decide whether "," or "." is the decimal separator in their text, then write the result with "." as the decimal point.
- Always positive; the sign comes from "type".

Other rules:
- "type" must be exactly one of the three values. For a move between the user's own wallets use "transfer".
- "merchant" is the place or counterparty; empty string if unknown.
- "date": resolve relative dates ("today", "yesterday", "вчера", "позавчера") against the user's local date given below. If no date is mentioned, use that local date.
- "wallet_name" picks the closest match from the optional wallet list; "" if none match. Never invent a wallet.
- "confidence" is your honest estimate between 0 and 1.
- If the text is NOT a transaction (e.g. a greeting or question), return { "error": "not_a_transaction" }.`;

const IMAGE_PROMPT_V2 = `${SYSTEM_PROMPT_V2}

The input is a photo of a receipt. Extract the TOTAL paid (or single-item total if no grand total), the merchant name printed on the receipt, and the date if visible. Copy the total's digits exactly as printed. Currency is whatever symbol/code is on the receipt.`;

/// The user's context as prompt text. Every value here has already been
/// checked by `validateParseContext`.
function contextBlock({ localDate, timeZone, locale }) {
  return `User's local date: ${localDate}\nUser's time zone: ${timeZone}\nUser's locale: ${locale}`;
}

export async function parseTextV2({ text, model, walletNames, context }) {
  const parts = [contextBlock(context)];
  if (walletNames) parts.push(`User wallets: ${walletNames}`);
  parts.push(`Text: ${text}`);
  const completion = await client().chat.completions.create({
    model: pickModel(model),
    messages: [
      { role: "system", content: SYSTEM_PROMPT_V2 },
      { role: "user", content: parts.join("\n\n") },
    ],
    response_format: { type: "json_object" },
    temperature: 0.1,
    max_tokens: 400,
  });
  return safeParseJSON(completion.choices?.[0]?.message?.content);
}

export async function parseImageV2({ dataUrl, model, context }) {
  const completion = await client().chat.completions.create({
    model: pickModel(model),
    messages: [
      { role: "system", content: IMAGE_PROMPT_V2 },
      {
        role: "user",
        content: [
          { type: "text", text: `${contextBlock(context)}\n\nExtract the transaction from this receipt.` },
          { type: "image_url", image_url: { url: dataUrl, detail: "low" } },
        ],
      },
    ],
    response_format: { type: "json_object" },
    temperature: 0.1,
    max_tokens: 400,
  });
  return safeParseJSON(completion.choices?.[0]?.message?.content);
}

function safeParseJSON(raw) {
  if (!raw) return { error: "empty_response" };
  try {
    return JSON.parse(raw);
  } catch {
    return { error: "invalid_json", message: raw.slice(0, 200) };
  }
}
