# Ledger reliability execution — Task 17 (frozen quotes in saves and reports, P7/P3/P5)

**Date:** 2026-09-11. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Suite | Result |
|---|---|
| `SumItTests` | Executed **282** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |
| Backend `npm test` | 66 tests, 66 pass (unchanged this task) |

New this task: `ValuationTests` 21 and `ReportValuationTests` 10.

## A defect this task found in Task 09's code

`LedgerStore.record(from:)` built every queued transaction mutation with **`baseAmount: nil`**. The write RPC requires base, rate and quote together for any valued record and refuses anything else as `valued_requires_base_rate_quote`. Every valued mutation would therefore have been rejected on its first push. Since Task 14 values every USD entry at identity, that means **every USD transaction** as well as every quoted foreign one.

It went unnoticed because the RPC was verified on production with hand-built payloads (Tasks 06/07), and the push tests used a fake transport that did not check a payload's valuation fields. The client and the real RPC have still never exchanged a request. `VAL-01` exposed it by asserting the queued payload instead of the stored row.

The mutation now carries the same booked base and rate that `apply` stores locally, derived by the same rule: the exact product rounded half-even to scale 18 for a quote, and the original stored numbers for a legacy valuation. Two regression tests assert the payload directly. As far as can be told from this working tree, no build containing the defect has been released — nothing has been committed or deployed.

## What this replaces

- **The static rate table is gone.** `CurrencyService.rates` priced BTC at a hard-coded $105,000, pinned USDC and USDT to exactly 1, and `toUSD` answered `1.0` for anything it did not know. `toUSD`, `usdTo` and `convert` are removed. `isSupported` remains as metadata only and says nothing about whether a rate exists.
- **Reports summed `amountInBase` as `Double`.** They counted every placeholder conversion as real, and could not say what was missing. They now aggregate in `Decimal` through `ReportSummary`.
- **Receipts baked in a display-currency conversion.** A chat message is stored, so "≈ €11.60" was frozen at whatever the table said that day. It now shows the booked USD value or "no USD conversion", and never a display currency.
- **The confirmation card's "≈" line used the static table.** It now shows the booked USD value this entry will actually be saved with, or a plain statement that it will be saved without one.
- **Editing an amount re-rated the entry.** Task 14's editor recomputed the valuation from today's table whenever the amount changed. It now keeps the confirmed quote and lets the store recompute the base (VAL-03).
- **Legacy restore invented a USD value.** Cloud rows with no stored base or rate defaulted to `amount_in_base ?? original_amount` and `rate_at_time ?? 1.0`. Those rows are now kept without a base and are counted as unconverted.

## Valuation rules

An editor holds a `ValuationChoice`: `automatic`, `keepExisting`, `quote`, `manual` or `unvalued`.

| Case | Rule | Test |
|---|---|---|
| VAL-01 | A quote books `amount × rate`, half-even to 18; the quote with its provider ID is stored and queued | ✓ |
| VAL-02 | Metadata-only edit: rate, base and quote are untouched | ✓ |
| VAL-03 | Amount edit: same quote, new base (12 × 1.08 = 12.96) | ✓ |
| VAL-04 | Currency or date change without a decision is refused as `valuation_decision_required`; keep-old-rate is allowed for a date change, not a currency change | ✓ |
| VAL-05 | Saved without a rate: original amount kept, base **absent** (not zero), state `unvalued` | ✓ |
| VAL-06 | A foreign wallet still requires the exact wallet-currency quantity (Task 14 rule, unchanged) | existing |
| VAL-07 | Filling in a valuation later is a new generation and a new queued operation | ✓ |
| VAL-08 | A refreshed or corrected quote reaches the cache and never a booked record | ✓ |
| VAL-09 | A legacy valuation keeps its original numbers; it cannot be scaled to a new amount without a decision | ✓ |
| VAL-11 | A manual rate whose product rounds to zero is refused, not booked as 0 USD | ✓ |

A new non-USD entry with no choice is **saved without conversion**, never at a guessed rate. When a fresh quote arrives it is applied and shown on the card before Save, so tapping Save confirms the rate too. A stale quote is offered with its date and applied only on an explicit tap. A manual rate uses the app locale's decimal separator, must be positive with at most 18 fractional digits, and is recorded with source `manual`, no quote ID and `confirmed_by_user: true`.

## The rate service

`RateService` asks `/api/rates` through a new checked GET in `BackendService`, which reuses its endpoint and authentication.

- **Its own `ModelContext`.** A cache write can neither commit nor roll back someone's pending ledger work, and it never touches a transaction.
- **Offline, it serves the newest cached quote for exactly that key.** A current quote is re-checked against the 96 h / 15 min window and offered as stale beyond it. A historical day only ever matches that day, and today's rate is never a substitute (the test caches a current quote, goes offline and asks for a past day: unavailable).
- **An answer of the wrong kind is refused**, for example a current quote when a day was asked for.
- **A reason this build does not know is still an unavailable state**, worded generically, never success.

## Reports

- **Exact and complete about gaps.** Totals are `Decimal`. A record with no USD value stays out of the USD total and is counted: "N entries have no USD value and are not in these totals". Legacy-rate records are included and counted as unverified, and an unreadable row is counted rather than skipped. The same notes appear on every section that shows a USD figure.
- **Native totals are always shown**, and they include the unconverted records.
- **Display currency is display only.** The booked USD value is converted with a separately fetched *current* quote and labelled with that quote's date, or with "older rate". Without a quote, the figure is shown in USD and says so. Switching the display currency cannot change a booked figure (REPORT-02).
- **Doubles appear only as chart coordinates and bar proportions**, after aggregation.
- **A negative net carries its sign in the text**, not only its colour (REPORT-04).
- **A transfer is neither income nor expense** and counts once (REPORT-03).
- **1,250 records of 0.01 sum to exactly 12.5** (REPORT-05).
- **Wallets are shown in their own currency** from the derived balance, never converted.

## What is not claimed

- **P7 is not complete.** The plan's own condition — "complete only with qualified automatic sources or an explicitly user-approved scope change" — is not met (see the Task 16 report).
- **In practice, every non-USD entry now saves without conversion.** `/api/rates` is not deployed, so the service answers unavailable. This is a visible change from Task 14, which gave such entries an unverified value from the static table: users will see "no USD conversion" on receipts and unconverted counts in reports until the backend is deployed and a provider qualified. That is the honest state — the old figure was invented — but it is a change users will notice.
- **No UI test drives the new valuation section, the card's valuation line or the reports.** The rules are tested at the model level, and the screens were compiled but not exercised or captured on a simulator.
- **The legacy restore path still has a server-side row cap** (Task 14). Adoption into the ledger is Task 18.
- **Crypto quotes remain unavailable** without a CoinGecko key (Task 16).
