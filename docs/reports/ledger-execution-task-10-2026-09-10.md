# Ledger reliability execution — Task 10 (checked transport, P2/P6)

**Date:** 2026-09-10. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **154** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |
| Overall | `** TEST SUCCEEDED **` |

New this task: `SupabaseTransportTests` 19.

## The defect this closes, confirmed in production

`SupabaseService.saveWallet` and `saveCategory` ended with:

```swift
_ = try await URLSession.shared.data(for: req)
```

The response was discarded entirely. An HTTP 404 against a missing table, a 401, a 500 — all looked exactly like a successful save. The production discovery on 2026-09-10 shows what that produced: **five transactions naming three distinct wallets, and zero wallets on the server.** Wallet sync had never worked and nothing ever said so.

## What was added

`SupabaseService` gained an injectable `URLSession` and an injectable `LedgerAuth`. Production keeps `.shared` and `.live`, so no production call site changed and no unit test can reach the network or a real credential.

Two checked methods:

- `applyLedgerMutation(_:scope:)` → `LedgerMutationResult`
- `readLedgerChanges(after:through:limit:scope:)` → `LedgerChangePage`

And `LedgerTransportError` with a distinct case per outcome: `configuration`, `notAuthenticated`, `accessDenied`, `validationRejected(code:)`, `retryable(status:retryAfter:)`, `unreachable`, `unknownOutcome`, `protocolMismatch`, `scopeChanged`.

The distinctions that matter:

- **A 2xx with an empty or unparseable body is `unknownOutcome`, not success and not an empty dataset.** The server may have committed. The operation stays retryable, and replay resolves it through the receipt.
- **The answer must match the question.** A receipt naming another operation, another entity or another owner is `protocolMismatch` — never an acknowledgment. Three separate tests.
- **A 400 keeps the server's machine code and discards its prose.** A test feeds back `{"message":"Cafe — 12.50 <script>"}` and asserts neither the amount nor the markup survives into the code.
- **Exactly one refresh, then one retry of the same bytes, on 401.** Tested for both the success and the still-401 path: two requests total, one refresh, never a loop.
- **`Retry-After` is honoured but bounded** to 300s. A server does not get to send the app to sleep for a day.
- **A transport failure is `unreachable`,** which is explicitly *not* "the remote dataset is empty" — the distinction that turns a lost connection into a wiped list.
- **The account is checked on both sides of every await.** A response arriving after the user switched accounts is `scopeChanged`, and nothing is even sent when the current owner already differs.

Feed pages are validated before they can be applied: cursors strictly ascending, inside the page's own watermark, above the caller's position, every row belonging to the scope owner, and `local_id` matching the change's `entity_id`. Any violation is `protocolMismatch`.

## Coverage against the ERR table

| Case | Covered |
|---|---|
| ERR-01 HTTP 400 validation | yes, including code sanitization |
| ERR-02 401 then refresh succeeds | yes — one refresh, one retry |
| ERR-03 401 then refresh fails | yes |
| ERR-04 403 | yes |
| ERR-05 408/429/500/503 with Retry-After | yes, all four statuses |
| ERR-06 2xx malformed or empty | yes, four body shapes |
| ERR-07 receipt wrong operation/entity/owner | yes, three tests |
| ERR-08 DNS/offline/timeout | yes, for both methods |
| ERR-09 invalid configured URL | partially — the code path throws `.configuration`, but `AppConfig.supabaseURL` cannot be overridden in a test yet, so the URL-building branch is unexercised |
| ERR-10 local ack save fails after acceptance | not here — belongs to Task 11 |

## What is not claimed

- **Nothing calls these methods yet.** The push coordinator that dispatches `PendingMutation` is Task 11; the pull merge is Task 12.
- **The server side does not exist.** `apply_ledger_mutation_v1` was never successfully applied anywhere, and the discovery showed the snapshot builders assume columns production does not have. These client methods are validated against the contract document and a stub, never against a live RPC.
- The old unchecked `saveWallet` / `saveCategory` / `deleteWallet` methods **are still present and still used** by the current app. Task 14 retires their callers; removing them now would break the live path.
- ERR-09's URL branch is untested, as noted above.
