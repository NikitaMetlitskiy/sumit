// The parse contract, version 2: one validator for the text and photo routes.
//
// Version 1 asked the model for `amount` as a JSON number and passed whatever
// came back straight to the client. A JSON number is a binary double by the
// time anything reads it, so 12.50 could only ever arrive as an approximation,
// and nothing checked the type, the currency or the precision. Version 2 asks
// for the digits as a string, checks them here without ever turning them into
// a float, and returns `amount_decimal` alongside a derived legacy `amount` for
// clients that have not moved.
//
// Nothing in this file uses floating-point arithmetic on money.

export const CONTRACT_VERSION = 2;

// Fractional digits accepted for a new entry, per currency. This mirrors
// `MoneyPrecision.entryScale` in the iOS client; the two must agree, and the
// test suite pins both tables.
export const ENTRY_SCALE = Object.freeze({
  USD: 2, EUR: 2, UAH: 2, GBP: 2, PLN: 2, CZK: 2,
  CAD: 2, CHF: 2, RUB: 2, KZT: 2,
  JPY: 0,
  USDC: 6, USDT: 6,
  BTC: 8,
  ETH: 18,
});

// Largest amount accepted for a new entry: 1e12, compared as digits.
const MAX_ENTRY_INTEGER_DIGITS = 13;
const MAX_ENTRY_AMOUNT = "1000000000000";

export const TRANSACTION_TYPES = Object.freeze(["expense", "income", "transfer"]);

const MAX_TEXT_FIELD = 200;
const MAX_WALLET_NAME = 128;
const MAX_SEGMENT_INDEX = 19;

export class TransactionContractError extends Error {
  constructor(code, message) {
    super(message || code);
    this.code = code;
  }
}

function fail(code, message) {
  throw new TransactionContractError(code, message);
}

// MARK: — Amounts

// `[digits][.digits]`, nothing else: no sign, no exponent, no grouping, no
// spaces, no currency symbol. A leading zero is only allowed as the integer
// part of a value below one.
const DECIMAL_GRAMMAR = /^(0|[1-9][0-9]*)(?:\.([0-9]+))?$/;

/// Canonical form of a positive decimal string: trailing fractional zeros and
/// a bare trailing point removed. Throws on anything that is not the grammar.
export function canonicalizeDecimal(text) {
  if (typeof text !== "string") fail("amount_not_string");
  const match = DECIMAL_GRAMMAR.exec(text);
  if (!match) fail("invalid_amount");
  const integer = match[1];
  const fraction = (match[2] || "").replace(/0+$/, "");
  return fraction ? `${integer}.${fraction}` : integer;
}

function isZero(canonical) {
  return canonical === "0";
}

function exceedsMaxEntry(canonical) {
  const [integer, fraction = ""] = canonical.split(".");
  if (integer.length !== MAX_ENTRY_INTEGER_DIGITS) {
    return integer.length > MAX_ENTRY_INTEGER_DIGITS;
  }
  // Same number of integer digits as 1e12: equal strings compare equal, and
  // any fractional part above exactly 1e12 exceeds it.
  if (integer > MAX_ENTRY_AMOUNT) return true;
  return integer === MAX_ENTRY_AMOUNT && fraction.length > 0;
}

/// Validates an entry amount for a currency and returns its canonical string.
export function validateEntryAmount(text, currency) {
  const scale = ENTRY_SCALE[currency];
  if (scale === undefined) fail("unsupported_currency");
  const canonical = canonicalizeDecimal(text);
  if (isZero(canonical)) fail("non_positive_amount");
  if (exceedsMaxEntry(canonical)) fail("amount_out_of_range");
  const fraction = canonical.split(".")[1] || "";
  if (fraction.length > scale) fail("excess_precision");
  return canonical;
}

// MARK: — Other fields

const ISO_DAY = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/;

/// A real calendar day in `YYYY-MM-DD`. `2026-02-30` is not one.
export function isCalendarDay(text) {
  if (typeof text !== "string") return false;
  const match = ISO_DAY.exec(text);
  if (!match) return false;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  if (month < 1 || month > 12 || day < 1) return false;
  const probe = new Date(Date.UTC(year, month - 1, day));
  return probe.getUTCFullYear() === year
    && probe.getUTCMonth() === month - 1
    && probe.getUTCDate() === day;
}

function optionalText(value, field, max) {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") fail(`invalid_${field}`);
  return value.trim().slice(0, max);
}

// MARK: — The model's answer

/// Validates one parsed transaction from the model and returns the response
/// body for a version-2 client. Throws `TransactionContractError` with a
/// stable machine code; nothing is coerced into a different meaning.
export function validateParsedTransactionV2(raw) {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    fail("invalid_model_output");
  }

  // An unknown type is an error. Defaulting it to "expense" is how a transfer
  // or a refund used to be recorded as spending.
  if (!TRANSACTION_TYPES.includes(raw.type)) fail("unknown_type");

  if (typeof raw.currency !== "string") fail("unsupported_currency");
  const currency = raw.currency.trim().toUpperCase();

  const amountDecimal = validateEntryAmount(raw.amount_decimal, currency);

  if (!isCalendarDay(raw.date)) fail("invalid_date");

  let confidence = raw.confidence;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)
      || confidence < 0 || confidence > 1) {
    fail("invalid_confidence");
  }

  const category = optionalText(raw.category, "category", MAX_TEXT_FIELD) || "Other";

  return {
    contract_version: CONTRACT_VERSION,
    type: raw.type,
    amount_decimal: amountDecimal,
    // For clients that still read `amount`. Derived from the validated string,
    // never the other way round; a version-2 client ignores it.
    amount: Number(amountDecimal),
    currency,
    category,
    merchant: optionalText(raw.merchant, "merchant", MAX_TEXT_FIELD),
    date: raw.date,
    note: optionalText(raw.note, "note", MAX_TEXT_FIELD),
    confidence,
    wallet_name: optionalText(raw.wallet_name, "wallet_name", MAX_WALLET_NAME),
  };
}

// MARK: — The request

/// Which contract the client speaks. Absent means version 1, the shape every
/// released client already sends; anything other than 1 or 2 is refused rather
/// than guessed.
export function readContractVersion(body) {
  const value = body?.contract_version;
  if (value === undefined || value === null) return 1;
  if (value === 1 || value === "1") return 1;
  if (value === 2 || value === "2") return 2;
  fail("unsupported_contract_version");
}

function isTimeZone(identifier) {
  if (typeof identifier !== "string" || identifier.length === 0 || identifier.length > 64) {
    return false;
  }
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: identifier });
    return true;
  } catch {
    return false;
  }
}

function canonicalLocale(identifier) {
  if (typeof identifier !== "string" || identifier.length === 0 || identifier.length > 35) {
    return null;
  }
  try {
    const [canonical] = Intl.getCanonicalLocales(identifier);
    return canonical || null;
  } catch {
    return null;
  }
}

/// The user's own "today", timezone and app locale. Checked before any of it
/// is placed into a prompt: this is text a client controls, and it decides how
/// "yesterday" and "12,50" are read.
export function validateParseContext(body) {
  const localDate = body?.local_date;
  if (!isCalendarDay(localDate)) fail("invalid_local_date");
  const timeZone = body?.timezone;
  if (!isTimeZone(timeZone)) fail("invalid_timezone");
  const locale = canonicalLocale(body?.locale);
  if (!locale) fail("invalid_locale");

  let segmentIndex = null;
  if (body?.segment_index !== undefined && body?.segment_index !== null) {
    const value = body.segment_index;
    if (!Number.isInteger(value) || value < 0 || value > MAX_SEGMENT_INDEX) {
      fail("invalid_segment_index");
    }
    segmentIndex = value;
  }

  return { localDate, timeZone, locale, segmentIndex };
}
