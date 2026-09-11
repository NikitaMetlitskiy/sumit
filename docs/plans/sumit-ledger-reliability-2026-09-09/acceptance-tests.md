# SumIt ledger reliability — acceptance tests and exact oracles

**Status:** test specification, not executed results. Every case below is required unless explicitly marked provider-access or device-gated; such a gate blocks the associated completion claim. All financial values/identifiers are synthetic. Use the existing five-model baseline and the new contracts from design.md.

## 1. Fixture definitions

| Symbol | Value |
|---|---|
| ownerA | Synthetic staging account created by the test runner; actual auth UUID captured at setup |
| ownerB | Another distinct synthetic staging account; never a production user's UUID |
| walletA | `40000000-0000-4000-8000-000000000001`, USD opening `1000` |
| walletB | `40000000-0000-4000-8000-000000000002`, USD opening `200` |
| walletEUR | `40000000-0000-4000-8000-000000000003`, EUR opening `500` |
| walletBTC | `40000000-0000-4000-8000-000000000004`, BTC opening `0.01` |
| expense | `30000000-0000-4000-8000-000000000001`, USD expense `12.5` from walletA |
| transfer | `30000000-0000-4000-8000-000000000002`, source walletA `100`, destination walletB `100` |
| Fixed event time | `2026-05-19T12:00:00Z` |
| Fixed test clock | `2026-09-09T12:00:00Z` |
| Synthetic EUR quote | USD per EUR `1.08`; date explicitly set by each test |
| Synthetic BTC quote | USD per BTC `100000`; never a production price assertion |

`LedgerIDs` in tests contains the static entity UUIDs and dynamically supplied staging owner IDs. Pure local tests may use fixed owner strings that pass UUID syntax; SQL/auth tests must use accounts actually created in the disposable test project. Fixture factories return typed drafts and **throw** on invalid decimal strings.

Canonical expected balances for the base scenario:

1. Opening A=1000, B=200; combined=1200.
2. Expense 12.5 from A → A=987.5, B=200; expenses=12.5.
3. Transfer 100 A→B → A=887.5, B=300; combined=1187.5; expenses remain 12.5; transfer counted once.
4. Edit expense to 10.25 → A=889.75, B=300; expenses=10.25.
5. Delete transfer → A=989.75, B=200; expenses=10.25.
6. Delete expense → A=1000, B=200; expenses=0.

Any different value is a failure unless a test explicitly describes another fixture. Compare Decimal/canonical strings, not formatted UI strings or Double epsilon.

## 2. Test structure and evidence

- **Pure:** money, segmentation, wallet effects, quote normalization; no networking.
- **Persistent local:** file-backed SwiftData store, close/reopen after mutation/failure; no success claims from memory-only tests.
- **Transport:** URLProtocol + injected ephemeral URLSession; capture requests without logging credentials.
- **SQL:** verified disposable/staging PostgreSQL, real RLS/JWT claims, transaction rollback for ordinary fixtures, two sessions for concurrency.
- **UI/device:** simulator and at least one actual device before release; app termination/relaunch and permissions as appropriate.
- **Provider:** bounded authorized latest/historical requests from intended backend, separate from mocked correctness tests.

A test record includes ID, source commit, environment, command, expected versus actual, pass/fail/blocked, and artifact location. No prechecked acceptance rows. A screenshot proves only displayed state; verify underlying data too. Do not execute destructive SQL or corrupt files against production.

## 3. Money and edit input (AMT, UIEDIT)

| ID | Input/action | Required oracle |
|---|---|---|
| AMT-01 | Canonical `12.50` | Normalize to `12.5`; numerical value unchanged |
| AMT-02 | Decimal `0.1 + 0.2` | Exactly `0.3` |
| AMT-03 | `12,50`, EUR, de-DE | `12.5` |
| AMT-04 | `12,50`, EUR, pl-PL/ru-RU/uk-UA | `12.5` in each supported locale |
| AMT-05 | `12.50`, USD, en-US | `12.5` |
| AMT-06 | `1,234.56`, USD, en-US | `1234.56` |
| AMT-07 | `1.234,56`, EUR, de-DE | `1234.56` |
| AMT-08 | `1 234,56`, including NBSP and narrow NBSP, pl-PL | `1234.56` for valid grouping |
| AMT-09 | `1,000`, en-US versus de-DE | `1000` versus `1`; normalized confirmation clearly shows chosen interpretation |
| AMT-10 | `1,23,456`, `12.3.4`, trailing `abc` | Validation failure; no prefix accepted |
| AMT-11 | Empty, whitespace, NaN, Infinity, `1e3` editor input | Validation failure; no fallback to old value/zero |
| AMT-12 | Expense `0`, `-1` | Reject; opening balance 0/-1 explicitly allowed in wallet context |
| AMT-13 | Fiat `12.345` | Reject new entry excess precision; do not round silently |
| AMT-14 | JPY `12.5` | Reject new entry; JPY `12` accepted |
| AMT-15 | BTC `0.00000001` | Preserved exactly through encode/save/wire/reopen |
| AMT-16 | ETH `0.000000000000000001` | Preserved exactly; not zero |
| AMT-17 | USDC/USDT six versus seven fractional digits | Six accepted; seven rejected for a new entry |
| AMT-18 | New amount >1e12 or arithmetic base >1e18 | Explicit out-of-range failure; no cap |
| AMT-19 | Negative zero input in wallet context | Canonical zero; no negative-zero display |
| AMT-20 | Half-even quantization: 1.005 and 1.015 to two digits | 1 and 1.02 respectively; exact prequantization decimals used |
| AMT-21 | Legacy fiat amount with three fractional digits | Metadata-only edit preserves it; monetary correction requires explicit new valid amount |
| AMT-22 | Malformed canonical wire decimal / invalid exponent | Decode rejection and no cursor advance |
| UIEDIT-01 | Open 12.50 expense editor, change merchant, Save | Amount still exactly 12.5 locally/remotely |
| UIEDIT-02 | Open 0.001 BTC editor, change date only | Amount remains 0.001; quote decision follows date-change rule |
| UIEDIT-03 | Open crypto wallet editor, change name | Opening balance unchanged at full precision |
| UIEDIT-04 | Edit fields, press Cancel | No entity, quote, queue or reply change |
| UIEDIT-05 | Choose no wallet on pending card then Save | walletID/effect cleared; no stale selected-wallet overwrite |
| UIEDIT-06 | Rapid double Save/Confirm | One entity identity and one intended creation, no duplicate financial effect |
| UIEDIT-07 | Local persistence fails on Save | Editor/card stays with draft, no success reply or dismissal |
| UIEDIT-08 | Device locale differs from app language | Parser/formatter consistently use chosen app locale, with canonical storage unchanged |

## 4. Segmentation and pending batches (SEG, BATCH)

| ID | Input/action | Required oracle |
|---|---|---|
| SEG-01 | `12,50 EUR coffee` | One unchanged segment |
| SEG-02 | `0,001 BTC` | One unchanged segment |
| SEG-03 | `1,000 USD rent` | One unchanged segment |
| SEG-04 | `10 coffee, 20 taxi` | Two ordered segments |
| SEG-05 | `10 coffee,20 taxi` | Two ordered segments |
| SEG-06 | `10 coffee; 20 taxi` | Two ordered segments |
| SEG-07 | `10 coffee` newline `20 taxi`, including CRLF | Two ordered segments before sanitization |
| SEG-08 | `10 coffee + 20 taxi` | Two ordered segments |
| SEG-09 | `ten dollars coffee; 20 taxi` | Both retained; first not discarded for no digit |
| SEG-10 | `10,20` | One segment; not two inferred operations |
| SEG-11 | Merchant text with comma | Preview exposes split ambiguity; user can correct; no hidden omission |
| SEG-12 | 21 nonempty segments | Reject before any API call; no partial billed batch |
| SEG-13 | 501-character segment | Explain limit; do not silently truncate |
| BATCH-01 | First segment succeeds, second fails, third succeeds | Two cards plus explicit failed second segment with its original index/text |
| BATCH-02 | Retry failed segment | Only that segment retried; existing confirmed rows unchanged |
| BATCH-03 | New text/photo while pending confirmations exist | No silent queue replacement; explicit discard required |
| BATCH-04 | App interrupted before confirmation | No saved transaction invented; retained draft behavior is explicit and visible |
| BATCH-05 | Cancel one card | Skip only that card; other pending outcomes remain ordered |
| BATCH-06 | Photo action during active send | No parallel state overwrite or wrong linked message |

## 5. Local atomicity and truthful state (LOC, ERR)

| ID | Setup/failure | Required oracle |
|---|---|---|
| LOC-01 | Successful new expense | Entity + linked saved reply + pending operation commit together |
| LOC-02 | Throw before context save | None of the three appear after reopen |
| LOC-03 | Disk/save failure after entity mutation in memory | Rollback restores prior entity and wallet-derived total; no queued partial write |
| LOC-04 | Edit failure | Old amount/date/quote/reply all intact |
| LOC-05 | Delete failure | Record remains active; no success or remote delete |
| LOC-06 | Delete success while offline | Tombstone and pending intent survive restart; active lists hide record |
| LOC-07 | Unrelated unsaved settings draft | Financial rollback does not lose unrelated user edits; context separation/commit policy tested |
| LOC-08 | Wallet/category save failure | No successful dismissal and no false synced state |
| LOC-09 | Success reply persistence would fail | Financial creation also rolls back; no disconnected “saved” record/reply pair |
| LOC-10 | Reopen after successful local save without network | Original operation/amount/queue identity preserved |
| ERR-01 | HTTP 400 validation | Pending blocked with field error; never marked synced |
| ERR-02 | HTTP 401, refresh succeeds | Same frozen operation retried once; no duplicate |
| ERR-03 | HTTP 401, refresh fails | Pause for sign-in; all local data/intent retained |
| ERR-04 | HTTP 403 | Access error; no infinite fast retry |
| ERR-05 | HTTP 408/429/500/503 | Durable retry; bounded backoff; Retry-After handled |
| ERR-06 | HTTP 200 with malformed/empty body | Unknown outcome; retry same operation ID |
| ERR-07 | Receipt wrong operation ID/entity/owner | Protocol failure; no ack mutation |
| ERR-08 | DNS/offline/timeout | Pending retained and visible; no conversion to empty remote dataset |
| ERR-09 | Invalid configured URL | Explicit configuration error; method does not return success |
| ERR-10 | Local acknowledgment save fails after server acceptance | Operation remains retryable; replay causes one server effect |

## 6. Wallet and transfer correctness (WAL)

| ID | Action | Required oracle |
|---|---|---|
| WAL-01 | Run full base scenario §1 | Every listed balance and expense total matches exactly |
| WAL-02 | Income 50 to A | A rises by 50; income rises by 50 |
| WAL-03 | Same-currency A→B transfer 100 | Combined balance unchanged; two effects in one record |
| WAL-04 | Cross-currency A USD→EUR, 100 sent/90 received | A falls by 100; EUR rises by 90; explicit quantities retained |
| WAL-05 | Edit transfer source amount/destination together | Both effects replaced once; no stale original effect |
| WAL-06 | Delete transfer | Both effects disappear together locally/remotely |
| WAL-07 | Same wallet as source/destination | Reject before persistence |
| WAL-08 | Wallet from another owner | Local and server reject |
| WAL-09 | Archived wallet as new destination | Reject; historical linked rows stay readable |
| WAL-10 | Rename source/destination | Balance/edit/delete unaffected because links use UUIDs |
| WAL-11 | Two wallets have same display name | Pickers distinguish them; selected UUID receives effect |
| WAL-12 | Change currency with linked rows | Block; never reinterpret stored balance |
| WAL-13 | Edit opening balance from 1000 to 900 | Current balance decreases by exactly 100; no invented income/expense |
| WAL-14 | Two devices independently create different expenses | Both effects included after pull; no absolute-balance last writer |
| WAL-15 | Different-currency expense with manual wallet effect | Native wallet balance uses confirmed exact effect, not today's FX |
| WAL-16 | Extra fee expense | Fee changes expense total once; transfer itself remains excluded |
| WAL-17 | Deleted/pending transaction iterations | Deleted gives zero; latest pending desired record gives one effect |
| WAL-18 | Legacy opening balance migration | Chosen before/after current balance identical; no double application |
| WAL-19 | Randomized insertion/edit/delete ordering, deterministic seed | Balance equals recomputation from final active records |
| WAL-20 | Same-currency transfer with unequal quantities | Reject; do not hide fee/spread in transfer |

## 7. Server idempotency, concurrency and access (RPC, CONC)

| ID | Request/schedule | Required oracle |
|---|---|---|
| RPC-01 | Valid create expected_revision 0 | One accepted identity/revision/receipt/feed event |
| RPC-02 | Replay identical request/operation ID | Same acceptance; no cursor/entity/balance increment |
| RPC-03 | Same operation ID with modified payload | Reject operation_payload_mismatch |
| RPC-04 | Update with old revision | Conflict containing full current snapshot; no write |
| RPC-05 | Delete with current revision | Server tombstone and change event accepted atomically |
| RPC-06 | Put to tombstoned ID | Rejected/conflict deleted; no resurrection |
| RPC-07 | Update nonexistent row | Conflict/missing; not implicit creation |
| RPC-08 | Client user_id or extra mutable column | Reject unknown field; derive owner from auth.uid() |
| RPC-09 | Anonymous caller / forged owner / other-owner refs | Reject; no cross-owner information leak |
| RPC-10 | Malformed UUID/decimal/unsupported type/overlarge payload | Reject before side effects |
| RPC-11 | Force failure after row change but before receipt | Whole SQL transaction rolls back |
| RPC-12 | Direct write to new support tables | RLS/grants deny authenticated and anon |
| RPC-13 | Adopted account legacy direct financial PATCH | Denied; unadopted test account retains intended legacy behavior |
| RPC-14 | New v1 transaction misses required exact field | Reject; no SQL NULL-check loophole |
| CONC-01 | Two concurrent identical creates | One acceptance plus same replay; one effect |
| CONC-02 | Two different edits based on revision R | Exactly one accepted; other conflicts |
| CONC-03 | Delete and edit based on same revision | One accepted; other conflicts; no partial/hybrid row |
| CONC-04 | First transaction holds owner lock then commits | Second waits; cursor ordering follows committed serial order |
| CONC-05 | First owner transaction rolls back | No phantom feed/receipt or skipped committed change |
| CONC-06 | Two unrelated owners mutate | Correct owner isolation; no unnecessary shared account lock |
| CONC-07 | Unauthorized caller tries state/protocol-version update | Denied; cannot self-authorize adoption |

## 8. Durable push and acknowledgments (PUSH)

| ID | Failure window | Required oracle |
|---|---|---|
| PUSH-01 | Network down before first send | Queued operation persisted; no frozen payload corruption |
| PUSH-02 | App killed after freezing request, before send | Restart retries same operation and bytes |
| PUSH-03 | Server committed, response dropped | Retry returns stored receipt; no duplicate |
| PUSH-04 | Ack arrived, local save fails | Pending survives; remote replay safe |
| PUSH-05 | User edits amount while previous generation is in flight | Old ack never overwrites latest amount; successor remains pending |
| PUSH-06 | Three edits while offline | Ordered predecessor chain; final server equals latest draft; no lost intermediate acceptance bookkeeping |
| PUSH-07 | Trigger from startup + foreground + local commit together | One dispatcher; each pending operation handled once per attempt |
| PUSH-08 | Parent wallet creation pending | Referencing transaction waits for dependency |
| PUSH-09 | Conflict blocks one transaction | Its descendants pause; independent transaction can sync |
| PUSH-10 | Account epoch changes during request | Response not applied to active different account |
| PUSH-11 | Retry-After invalid/very large | Bounded safe scheduling; operation not deleted |
| PUSH-12 | App remains offline for days | No intent expiry; user sees waiting state on reopen |

## 9. Complete restore, deletion and cursor behavior (PULL, REST)

| ID | Data/schedule | Required oracle |
|---|---|---|
| PULL-01 | 1,001 changes | All retrieved, no 1,000 cutoff |
| PULL-02 | 2,503 mixed entity/tombstone events | Exact cursor set retrieved through fixed watermark |
| PULL-03 | No more changes | Empty valid page; next cursor correct; no false fetch failure |
| PULL-04 | New server writes during paged pull | Current run stops at original watermark; next run gets later events |
| PULL-05 | Malformed row/page | No checkpoint advance; visible issue |
| PULL-06 | Repeated or out-of-order cursor | Reject invalid page or idempotent known replay; never skip unknown events |
| PULL-07 | Tombstone for locally active clean entity | Entity disappears from active totals; identity retained |
| PULL-08 | Interrupted save midpage | After reopen checkpoint and entities reflect either whole committed page or prior state |
| PULL-09 | Older feed event arrives after newer push acknowledgment | Page cursor advances but entity never rolls back or falsely conflicts |
| PULL-10 | Own accepted operation after restart, with newer local successor | Retained operation identity prevents false conflict; latest local desired amount remains |
| REST-01 | Restore same remote transaction twice | Same UUID and one row |
| REST-02 | Restore same wallet/category twice | Same UUID and one definition |
| REST-03 | Upper/lowercase UUID representation | Same identity |
| REST-04 | Missing/invalid local_id or owner | Migration/protocol issue; no generated UUID/current-owner fallback |
| REST-05 | Valid fractional ISO timestamp | Original instant preserved; no `.now` replacement |
| REST-06 | Remote edit of clean local row | Updated exact values appear once |
| REST-07 | Own accepted operation appears in feed | No false conflict and no duplicate effect |
| REST-08 | Remote delete after offline local delete retry | Converges deleted; no resurrection |
| REST-09 | New device without chat messages | Transactions still reachable through complete history |
| REST-10 | Referenced wallet not yet locally materialized | Dependency deferred visibly; transaction is not silently dropped |

## 10. Accounts and conflict resolution (ACC, CONFLICT)

| ID | Action | Required oracle |
|---|---|---|
| ACC-01 | A sign-out keep-data, B sign-in | No A transaction/wallet/category/chat in B views |
| ACC-02 | Delayed A response arrives under B | No B changes; A's pending state retained for A |
| ACC-03 | A returns later | A's preserved dataset/queue available and scoped correctly |
| ACC-04 | Automatic token failure | Same isolation policy as explicit sign-out; no data deletion |
| ACC-05 | Local unowned records before sign-in | Explicit adoption, no silent ownership assignment |
| ACC-06 | Local wipe with pending operations | User is told about unsynced data; no implicit wipe to resolve sync failure |
| ACC-07 | Delayed old session refresh completes after B sign-in | B remains active; old result never overwrites Keychain/session state |
| CONFLICT-01 | Local/remote change same amount differently | Show both; no automatic sum/last-write-wins |
| CONFLICT-02 | Use server version | Server values active; local candidate retained for recovery; descendants canceled coherently |
| CONFLICT-03 | Keep local version | New operation ID with fresh base revision; no reusing old accepted payload |
| CONFLICT-04 | Remote changes again during resolution | New conflict; no silent overwrite |
| CONFLICT-05 | Remote deleted, local edited | Deleted identity stays deleted; candidate recoverable |
| CONFLICT-06 | Explicit Save as new from deleted candidate | New transaction UUID and deliberate new effect |

## 11. Rates, valuation and reports (FX, VAL, REPORT)

| ID | Quote/action | Required oracle |
|---|---|---|
| FX-01 | USD→USD | Exact identity 1 with source identity, no provider call |
| FX-02 | Fiat provider returns 1 USD = 0.8 EUR | Stored USD/EUR rate exactly normalized 1.25 |
| FX-03 | Crypto provider returns USD per BTC | No reciprocal inversion |
| FX-04 | USDC/USDT returned price differs from 1 | Preserve normalized quote; never force peg |
| FX-05 | Provider403/429/500, missing key or missing currency | Explicit unavailable, no fabricated rate |
| FX-06 | Zero/negative/non-finite/out-of-range price | Reject quote |
| FX-07 | Provider timestamp beyond five-minute tolerance | Reject future quote |
| FX-08 | Fiat age 24h/96h/97h | Refresh due at 24h; automatic use <=96h; >96h needs explicit stale confirmation |
| FX-09 | Crypto age 5m/15m/16m | Refresh due at 5m; automatic use <=15m; >15m needs confirmation |
| FX-10 | Weekend historical fiat observation <=7 days earlier | Preserve/show actual date; no pretending it is requested day |
| FX-11 | Historical result later than requested or >7 days earlier | Unavailable for automatic historical valuation |
| FX-12 | Historical crypto outside allowed access | Unavailable/manual; never today's price |
| FX-13 | Concurrent cache misses | Bounded provider requests with expiring refresh lease; no cross-instance stampede |
| FX-14 | Cache write/read failure | Ledger intact; no invalid cached quote or silent base amount |
| FX-15 | Unknown requested currency/date/payload excess | Route rejects before provider calls |
| FX-16 | Provider contract coverage qualification | All 10 required non-USD fiat codes and four crypto identities actually verified, or G4 blocked |
| FX-17 | Client modifies rate/provider label for a real quote ID | Write RPC rejects mismatch; manual rate must use manual source |
| FX-18 | Provider cache persistence fails | No unverifiable provider quote returned; unavailable/manual/unvalued path |
| FX-19 | Normalize 1.2345678901234567 and invert 3 | 1.23456789012346 and 0.333333333333333333; explicit quote-resolution policy |
| FX-20 | Provider corrects an already booked historical observation | New quote ID; old ID remains resolvable and booked transaction unchanged |
| VAL-01 | Save 10 EUR at quote 1.08 | Booked USD 10.8, exact rate/provenance persisted |
| VAL-02 | Change merchant only | Original amount/rate/base unchanged |
| VAL-03 | Change amount to 12 with retained confirmed quote | USD base 12.96 |
| VAL-04 | Change date/currency | Explicit keep/requote decision; no hidden current-rate replacement |
| VAL-05 | Save without rate | Original amount retained; base null/unvalued, not zero |
| VAL-06 | Foreign wallet with unavailable conversion | Require exact manual wallet effect or no wallet; do not guess |
| VAL-07 | Fill missing valuation later | Versioned explicit edit, replay safe |
| VAL-08 | Provider later revises historical value | Saved transaction unchanged unless explicit revaluation |
| VAL-09 | Legacy hardcoded conversion | Original stored base/rate preserved and labeled unverified |
| VAL-10 | Client base differs from exact scale-18 half-even product | RPC rejects mismatch, no accepted inconsistent valuation |
| VAL-11 | Positive product becomes zero at allowed scale | Explicit underflow/unvalued choice, no silent zero booked value |
| REPORT-01 | Mixed valued and unvalued records | Partial totals labeled, missing-conversion count shown |
| REPORT-02 | Switch display currency | Booked USD and native-wallet quantities unchanged |
| REPORT-03 | Transfer in same/cross currency | No false income/expense; count one |
| REPORT-04 | Negative period net | Explicit negative sign, not color alone |
| REPORT-05 | More than 1,000 restored operations | Totals/list reflect complete dataset |

## 12. Migration, storage and recovery (MIG, ADOPT, STORE)

| ID | Fixture/failure | Required oracle |
|---|---|---|
| MIG-01 | Actual baseline V1 file store → V2 | Original IDs/owners/amounts/messages/settings preserved |
| MIG-02 | Repeat schema open/upgrade | No new IDs/duplicates or repeated transformation |
| MIG-03 | Legacy amount outside new entry precision | Preserved, not silently rounded |
| MIG-04 | Formerly-restored copy with different UUID | Flag ambiguous; do not auto-delete by matching content |
| MIG-05 | Two legitimate equal-value coffee records | Both preserved |
| MIG-06 | Invalid UUID/date, orphan wallet name | Visible repair issue; no fallback identity/date/wallet |
| MIG-07 | Wallet current-balance baseline | Opening = selected balance minus known effects; resulting current balance equal to selected original |
| MIG-08 | Different device/cloud balances | Explicit source/reconciliation choice; no silent preference |
| MIG-09 | Old one-sided transfer | Preserve raw record; missing destination blocks reconciled activation until resolved |
| MIG-10 | Old wallet rename/currency ambiguity | Preserve original and require resolution; no inferred historical effect |
| ADOPT-01 | Freeze and seed full account | Atomic protocol activation; no half-seeded feed visible |
| ADOPT-02 | Kill before activation | Legacy data usable/preserved; resumable manifest |
| ADOPT-03 | Kill after activation before local completion | Resume pull with same identities and retained local queue |
| ADOPT-04 | Same manifest applied twice | No-op/already-adopted, no duplicate feed baseline |
| ADOPT-05 | Another user's account during migration | No data or policy behavior change for unrelated account |
| ADOPT-06 | Old client attempts write after adoption | Denied; pilot procedure explicitly requires all upgraded devices |
| ADOPT-07 | Local unsynced data exists at upgrade | Inventoried before any upload; reconciled and submitted once |
| ADOPT-08 | Legacy request is in flight when freeze begins | It drains before freeze completes; frozen snapshot excludes any later untracked write |
| ADOPT-09 | Freeze lock timeout / cancel before activation | Transaction aborts cleanly or verified unpause restores legacy access; no half activation |
| STORE-01 | Persistent open throws | Recovery screen; no writable memory database or RootView |
| STORE-02 | Disk full during save | Prior persisted state intact; draft recoverable, no success |
| STORE-03 | Unsupported newer schema | Preserve files; no reset/downgrade/empty store |
| STORE-04 | Deliberate fixture corruption | Recovery copy includes source files; no destructive repair |
| STORE-05 | Retry open succeeds | Original data appears once; only one container/sync loop |
| STORE-06 | Recovery copy with SQLite WAL/SHM | Consistent complete copy; independently opened/verified where possible |
| STORE-07 | Recovery while app lock enabled | Financial diagnostics/data remain protected |
| STORE-08 | Export requested | User-directed destination only; raw backup clearly identified, no automatic upload |

## 13. End-to-end two-device schedule

Run this once on staging with two upgraded clients A1/A2 on ownerA, plus another account ownerB on a third isolated client/session. Disable AI dependency by using typed manual/synthetic drafts; this schedule measures ledger correctness, not AI quality.

1. Initialize wallets A/B with the opening balances in §1. Pull on A2; compare identical UUIDs and openings.
2. On A1 create the 12.5 expense. Immediately cut response delivery after server commit. Restart A1 and retry; there is one expense, one accepted operation receipt and one effect.
3. Pull on A2. On A1 edit to 10.25 while A2 edits same record to 11 from the old revision. Synchronize both. Exactly one edit wins acceptance; the other exposes a conflict.
4. Resolve explicitly to 10.25. Pull both. Compare amount 10.25 and A balance 989.75.
5. Create the 100 transfer A→B offline on A1. Restart without internet. A1 shows A=889.75/B=300 pending; A2 remains at pretransfer balances until delivery.
6. Restore networking and sync. Both show A=889.75/B=300 and expenses=10.25. Transfer is one record with both references; no independent wallet-total overwrites.
7. Delete the transfer offline on A2; simultaneously edit its note on A1. Sync in both possible orders. Explicit conflict/deletion policy applies, and the identity is never silently resurrected.
8. Delete the expense and converge. A/B return to 1000/200 when both entries are finally deleted.
9. Kill A1 after receiving a pull page but before local cursor save; relaunch and repeat. IDs/counts/balances remain unchanged.
10. Start a pending request under ownerA, sign out keeping data, sign in ownerB, then deliver the old response. B remains empty; A data stays hidden and retained.
11. On a fresh A3 install restore a 2,503-event expanded fixture. Reach, edit and delete an operation older than the newest 1,000 using the transaction history. Observe convergence on A1/A2.
12. Force store-open failure on a disposable copied fixture. Recovery surface appears, no save/parse/sync can run, and exporting/retrying preserves the copy.

Repeat schedules 3 and 7 with reversed network ordering. Record server receipts/revisions and canonical local snapshots, not only UI screenshots. The report must note which steps ran on simulator versus real device.

## 14. Eight-issue closure matrix

| User item | Implementation tasks | Mandatory evidence |
|---|---|---|
| P1 duplicates/restore | 04,07,12,18,19 | REST-01..10, PULL-01..10, MIG-01..06, ADOPT-01..09 |
| P2 false save success | 01,09,10,11,14 | LOC-01..10, ERR-01..10, PUSH-03..05, UIEDIT-07 |
| P3 lost fractional money | 02,04,14,15,17 | AMT-01..22, UIEDIT-01..08, VAL-01..04, MIG-03 |
| P4 comma split | 03,14,15 | SEG-01..13, BATCH-01..06 |
| P5 incomplete transfers | 08,09,14,18 | WAL-01..20, RPC-10..11, CONC-03, MIG-07..10 |
| P6 divergence/deletion | 05–13,18–20 | RPC/CONC/PUSH/PULL/REST/ACC/CONFLICT suites and two-device schedule |
| P7 hardcoded FX | 02,15–18 | FX-01..20 with live provider qualification; VAL/REPORT suites |
| P8 memory fallback | 01,04,18,20 | STORE-01..08, LOC-02..05, migration backup restore |

A case is not waived because its helper or environment is difficult to build. If a necessary owner decision, provider credential, live database or device is unavailable, keep the affected gate open, finish independent work, and report exactly what remains before execution can be called complete.
