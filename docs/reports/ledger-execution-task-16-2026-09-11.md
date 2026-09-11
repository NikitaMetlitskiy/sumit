# Ledger reliability execution — Task 16 (rate service and provider qualification, P7)

**Date:** 2026-09-11. **Toolchain:** Node 22.21.0; Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Suite | Result |
|---|---|
| Backend `npm test` | **66** tests, 66 pass, 0 fail |
| `SumItTests` | Executed **251** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |

New this task: `rates.test.js` 33 and `rates-route.test.js` 4. The iOS change is one attribution row in Settings and two strings.

## Gate G4 status: **not qualified**

Fiat is **qualified from a developer machine, not from the intended server**. Crypto is **not qualified**: it was probed without an account, and CoinGecko's storage terms are in tension with how the ledger keeps provenance. P7 stays open. Details below; nothing here should be read as "automatic FX works in production".

## Provider evidence

### What planning recorded, preserved

Both planning probes of Frankfurter v2 returned **HTTP 403, `error code: 1010`** (`docs/plans/…/rate-provider-probes.json`). That file is unchanged. No CoinGecko credential was tested during planning.

### What was probed on 2026-09-11

All requests are recorded with URL, UTC time, status, elapsed time and the raw body, saved **before** any interpretation, in `Backend/vercel-project/test/fixtures/rates/probes-2026-09-11/`. Every request came from the developer machine (macOS), **not** from Vercel.

| # | Request | Status | Elapsed | Result |
|---|---|---|---|---|
| 1 | Frankfurter `v2/rates?base=USD&quotes=<10 fiat>&expand=providers` | 200 | 8.20 s | all 10 codes; **labelled 2026-09-12** |
| 2 | same, `&date=2026-05-19` | 200 | 4.63 s | all 10 codes, each dated 2026-05-19 |
| 3 | Frankfurter `v2/currencies` | 200 | 1.76 s | 165 currencies; all 11 required codes present |
| 4 | same as 1 with `&date=2026-09-11` (today, UTC) | 200 | 0.60 s | all 10 codes, dated 2026-09-11, same rates as #1 |
| 5 | Frankfurter `v2/providers` | 200 | 0.40 s | 98 providers with keys, cadence, `terms_url` |
| 6 | CoinGecko `coins/list` (keyless) | 200 | 0.29 s | 21,084 rows; 135 kept (btc/eth/usdc/usdt symbols) |
| 7 | CoinGecko `simple/price` for 4 ids (keyless) | 200 | 0.27 s | 4 prices with `last_updated_at` |

Seven requests in total, no failures, no retries. No transaction amount, text, merchant, photo or wallet name was sent; the requests carry currency codes and a date only.

### Fiat: what the responses establish

- **All ten required codes are served**, current and historical: EUR, UAH, GBP, PLN, CZK, CAD, CHF, RUB, KZT, JPY.
- **Direction is verified, not assumed.** The shape is `[{date, base:"USD", quote, rate, providers:[{key,date,rate}]}]`, and `rate` is units of the quote currency per USD: EUR 0.86057, UAH 44.553, JPY 154.09, KZT 451.34. The ledger stores USD per unit, so fiat is inverted exactly once: EUR → 1.162…
- **No exponent notation** appeared in any number.
- **The undated `latest` aggregate was labelled a day ahead.** At 2026-09-11T18:30Z it said `2026-09-12`, because at least one constituent provider had already published a rate dated the 12th. Read as that day's start, it is 330 minutes in the future, so FX-07 has to refuse it. The same request **with `date=` set to today's UTC day** returned identical rates labelled 2026-09-11. The implementation therefore always sends a date, and a test runs the saved `latest` body through the loader to show it is refused.
- **The aggregate blends observations of different ages.** For UAH and KZT, constituents dated as far back as 2026-08-28 sat inside the rate labelled 2026-09-11. `effective_at` records Frankfurter's aggregate date. The constituent provider keys and dates are kept in `source_detail.providers`, so this stays visible, but the label is the aggregator's, not the oldest input's.
- **A cold request was slow.** The first one took 8.2 s against an 8 s provider timeout; later ones took under 1 s. A cold call in production can time out and be reported as `provider_failure` (retryable). This is recorded, not tuned away.

### Crypto: what the responses establish, and what they do not

- **Coin IDs are registry-derived.** Matching expected name *and* symbol against `coins/list` gave exactly one row each: `bitcoin` (Bitcoin), `ethereum` (Ethereum), `usd-coin` (USDC), `tether` (Tether). The symbols alone matched 12, 14, 60 and 49 rows, which is why a symbol is never used as an identity.
- **Stablecoins are not at 1.** USDC 0.999844 and USDT 0.999695 at probe time, which confirms the no-peg rule (FX-04) against real data.
- **Not qualified.** Both requests were keyless. The design specifies the Demo API with `x-cg-demo-api-key`, and no account exists for this project. Historical quotes (`/coins/{id}/history`, 365-day Demo window, 00:00 UTC snapshot published at 00:35 UTC) were **not** probed, because that needs an authorised account. No account was created and nothing paid was used.

## Terms and attribution obligations

**Frankfurter.** The docs say no key is needed, there are no quotas beyond abuse rate limiting, and commercial use is allowed; they also tell users to check the terms of the individual upstream providers. The `v2/providers` listing links `terms_url` per provider, and most of those links are null. No per-provider terms review was done.

**CoinGecko API terms.** Relevant sentences, quoted:

- Attribution: *"displaying prominently the message 'Powered by CoinGecko'"*, in line with their attribution guide.
- Caching: *"You should refresh the cache at least every 24 hours."*
- Storage: *"you are not allowed to duplicate, reproduce, copy, store, derive from or translate any Data"* except as expressly permitted, and on termination to *"promptly and permanently delete all Data"*.
- Redistribution: *"not permitted to … re-distribute or syndicate access"*.

**The conflict to resolve.** The ledger's design keeps every quote row **immutable and resolvable forever**, because a booked transaction points at it as provenance. That is hard to reconcile with a general no-storage clause and a delete-on-termination clause. This is a licensing question for the owner, not an engineering one, and it is the main reason crypto is recorded as not qualified.

**Surfaced in the app.** Settings → About now has an "Exchange rates" row: a Frankfurter link, "Powered by CoinGecko" linking to coingecko.com/en/api, and a note that these are reference rates, not the price paid. Localised in all six languages.

## Implementation

`api/_lib/rates.js`, entry point `loadRateQuotes(input, dependencies)`, served by authenticated `GET /api/rates`.

- **Fixed routing.** Ten fiat codes go to Frankfurter, four crypto codes to CoinGecko, and USD never leaves the process (`identity`, no `quote_id`). There is no vendor registry.
- **Numbers.** Each provider observation is normalised once with `toPrecision(15)`, with exponent notation expanded by moving the digit boundary. `reciprocal18` inverts with BigInt, half-even to 18 places, and refuses underflow and anything wider than `numeric(38,18)`. The plan's examples hold: `0.8 → 1.25`, `3 → 0.333333333333333333`, `0.00000001 → 100000000`, `1.2345678901234567 → 1.23456789012346`.
- **Every code accounted for.** Each requested code lands in exactly one of `quotes` or `unavailable`, in request order, and `unavailable` carries one of the eight planned reasons with a `retryable` flag.
- **Persisted or not returned.** A provider quote is returned only with the ID of the row it was stored as. If the insert fails, the answer is `cache_failure`, never an unverifiable quote. The write RPC from Task 05 already checks a claimed quote's ID, currency, rate and kind against that row.
- **Cache and leases.** Keys are `(source, currency, kind, requested_date)`. One refresher per key runs across instances: an insert, then a conditional takeover of an expired lease, which Postgres re-checks under the row lock. The lease is released in `finally`. A cached row must pass the same validation as a fresh one before it is served.
- **Freshness.** Fiat: refresh at 24 h, automatic use to 96 h, labelled `stale` after. Crypto: refresh at 5 min, automatic use to 15 min, stale after. Historical fiat accepts an observation up to seven days before the requested date and never after it. Historical crypto must be that exact day's snapshot and never falls back to today's price.
- **No credential, no crypto.** Without `COINGECKO_DEMO_API_KEY`, crypto is `provider_access` and nothing is requested. The key is sent only as a header, and the route logs error codes only.
- **Exact reads from Postgres.** PostgREST renders `numeric` as a JSON number, so the adapter selects `usd_per_unit::text` and canonicalises the padded scale (`1.250000000000000000` → `1.25`). It also refuses a stored value that differs from the validated one. Without this, every cached quote would have failed the canonical grammar and never been served.
- **No DDL.** `service_role` already holds full privileges on `rate_quotes` and `rate_refresh_leases`; checked read-only on production.

## Two things caught before they shipped

- **Padded numeric text from Postgres.** Described above. Found while writing the adapter, now covered by a test.
- **A test that could not fail the way it claimed.** The no-credential test passed `coingeckoApiKey: undefined`, and the fixture's default parameter quietly replaced it with a key, so the test failed for the wrong reason. It now passes `null`. The production code was not at fault.

## What is not claimed

- **Nothing is deployed.** `/api/rates` exists only in this working tree. No provider has been called from Vercel, so the planning 403 could still reproduce from Vercel's IP range, and this report cannot rule that out.
- **No CoinGecko account or key exists**, and none was added. Adding one needs your approval of their terms, specifically the storage clause, and goes through Vercel's managed secrets.
- **The iOS client does not call `/api/rates`.** Quote selection, manual rate, the unvalued choice and the removal of the static rate table are Task 17. Until then, new non-USD entries keep the `legacyUnverified` valuation from Task 14.
- **The lease SQL has not run against Postgres.** The loader's lease logic is tested with an in-memory store; the Supabase adapter's two-statement claim is reasoned, not executed. The same holds for the whole adapter — it has not issued a real query.
- **Rows accumulate.** Quote rows are immutable by design and nothing prunes them. With the key configured, crypto refreshes could add up to about 1,150 rows a day per currency set under sustained use. Retention is undecided, and it interacts with the CoinGecko storage question.
