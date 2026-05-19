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

function safeParseJSON(raw) {
  if (!raw) return { error: "empty_response" };
  try {
    return JSON.parse(raw);
  } catch {
    return { error: "invalid_json", message: raw.slice(0, 200) };
  }
}
