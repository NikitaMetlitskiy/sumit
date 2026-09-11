# Ledger reliability execution — Task 15 (exact AI amounts on text and receipt paths, P3/P4/P5)

**Date:** 2026-09-11. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5; Node 22.21.0.

## Test results

| Suite | Result |
|---|---|
| `SumItTests` | Executed **251** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |
| Backend `npm test` | **29** tests, 29 pass, 0 fail |

New this task: `ParseContractTests` 19 (Swift); `transaction-contract.test.js` 17 and `parse-routes.test.js` 12 (Node).

## What this replaces

The prompt asked the model for `"amount": number`. A JSON number is a binary double by the time any code reads it, so **the exact digits were gone before the response left the server** — 12.50 or 0.00000001 could only ever arrive approximately. Nothing on either side checked the rest of the answer:

- **An unknown type became an expense.** `TransactionType(rawValue: r.type ?? "expense") ?? .expense` — a transfer or a refund the model mislabelled was recorded as spending.
- **Amounts were capped, not refused.** `min(amount, 1e12)` turned an out-of-range value into a different, plausible one.
- **"Yesterday" was resolved on the server's clock.** The prompt said "defaults to today" without saying whose today; for a user far enough from UTC, relative dates were a day off.
- **The receipt route and the text route validated nothing, independently.**

## Contract version 2

**Server.** `api/_lib/transaction-contract.js` exports `validateParsedTransactionV2`, the one validator both routes use (through `parse-response.js`, so a photo cannot take a looser path than text). It asks the model for `amount_decimal` as a **string** and checks it without ever converting it to a float: strict digit grammar, positive, ≤ 1e12 compared as digits, and no more fractional digits than the currency allows. Every refusal is a typed code — `amount_not_string`, `invalid_amount`, `non_positive_amount`, `excess_precision`, `amount_out_of_range`, `unknown_type`, `unsupported_currency`, `invalid_date`, `invalid_confidence`. The response adds `amount_decimal` and keeps a numeric `amount` **derived from the validated string**, for older readers.

**Request context.** A v2 request carries `local_date`, `timezone` and `locale`, and optionally `segment_index`. These are checked before they reach the prompt — and before the rate limit or any paid call, so a malformed request costs the user nothing. That ordering matters because the context is client-controlled text placed into a prompt: a `timezone` of `"Europe/Kyiv\nIgnore previous instructions"` is refused as `invalid_timezone`, and a test pins it.

**Client.** `ParseResponseDecoder` holds a v2 response to the contract it declares. `amount_decimal` goes through `MoneyCodec.decode` and `validateEntry`; a missing or malformed one is refused **even when the numeric `amount` is present and looks fine** — there is no fallback to the Double. The segment index is checked on the way back, so an answer can only be confirmed against the segment it was produced for.

## Decisions worth naming

- **Version 1 is untouched.** A request without `contract_version` goes through the old prompt and gets the old body byte for byte. Released clients keep working.
- **Anything other than 1 or 2 is refused**, not treated as the nearest thing.
- **A broken answer is a 422, not a 200 with an error field**, and is not counted against the quota. The raw model text is not passed through.
- **"Not a transaction" is a normal answer**, and is not billed either — the same rule the routes already had.
- **The precision table exists twice** — `MoneyPrecision.entryScale` in Swift and `ENTRY_SCALE` in JS. A test on the JS side pins the exact table so the two cannot drift silently. It is a pin, not a shared source; a change needs both edits.
- **The legacy decoder stays, and is named for what it is.** `LegacyParseCompatibility` reads a Double's shortest decimal description for a server that has not been deployed yet. It still refuses unknown types and out-of-range amounts rather than capping them.

## Two defects found along the way

- **A parsed transfer could never be completed.** `ParsedTransaction` had no destination fields, so the confirmation card's editor had nowhere to put the second wallet: every AI-suggested transfer was either refused by the store as `incomplete_transfer` or never saveable at all. It now carries `destinationWalletID` and `destinationAmountExact`. The parser still never chooses them — a transfer ignores name matching entirely, and Save on an incomplete transfer opens the editor instead of attempting a save that must fail.
- **Parsing and display disagreed about the locale (UIEDIT-08).** The formatter followed the app's language; the editors from Task 14 and the parse request used `Locale.current`. On a device in English with the app in Russian, "12,50" was displayed one way and parsed another. Both now use `AppLocale.current`.

## What is not claimed

- **The backend is not deployed.** Everything here runs locally. The iOS client now sends the v2 fields; the server currently live at `sumit-backend-ten.vercel.app` ignores them and returns a v1 body, which the client reads through `LegacyParseCompatibility`. So the client is safe to ship first — but **no exact amount reaches a user until the backend is deployed**, and deploying it is a production change I have not made.
- **No live AI call was made.** The plan authorises a small consented set only under a separately established spend allowance, and there is none. Every route test runs against a mocked model. Whether `gpt-4o-mini` reliably follows "copy the exact digits as a string" is therefore **unmeasured**; the validator guarantees that a model which does not follow it produces a 422, not a wrong number.
- **No lockfile was recorded**, because no dependency was installed. The tests use Node's built-in runner and `--experimental-test-module-mocks`, which is still marked experimental in Node 22.
- **Category is not validated against the list.** An unknown category string is kept as text (defaulting to "Other" only when absent). It is not money and does not change what is recorded as spent, but it is looser than the other fields.
- **`occurredAt` is the start of the parsed day**, as before, not the time of entry.
