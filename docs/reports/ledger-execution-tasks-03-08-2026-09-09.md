# Ledger reliability execution — Task 08 and the rest of Task 03

**Date:** 2026-09-09. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **117** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |
| Overall | `** TEST SUCCEEDED **` |

New this pass: `WalletLedgerTests` 23, `ChatBatchTests` 7.

## Task 08 — one wallet formula and atomic transfers (P5)

**Added:** `SumIt/Services/wallet-ledger.swift`, `SumItTests/wallet-ledger-tests.swift`.

The old code matched wallets **by name** and mutated a stored absolute balance by a delta on every save and delete. That is four bugs in one mechanism: two wallets called "Cash" were one wallet, renaming one silently moved its history, a failed sync left the delta applied anyway, and a transfer only ever debited one side because there was nowhere to put the other leg.

None of those are expressible now. Effects are keyed by wallet UUID, `WalletDescriptor` carries no name at all, and a balance is **derived**:

```
balance(W) = opening(W)
           + Σ income.walletAmount        where walletID == W
           − Σ expense.walletAmount       where walletID == W
           − Σ transfer.walletAmount      where walletID == W
           + Σ transfer.destinationAmount where destinationWalletID == W
```

The type switch is explicit. There is no "anything that is not income is a debit" shortcut — that shortcut is what made transfers behave like expenses.

Decisions worth naming:

- **Archived wallets calculate but cannot be newly referenced.** `effects(for:…)` accepts them, because archiving must never erase history that already points at a wallet; `validateForSave(_:…)` rejects them. Splitting calculation from validation is what makes both true at once.
- **A transfer between two same-currency wallets must move equal quantities.** A difference would be a fee or a spread hidden inside the transfer. Fees are ordinary separate expenses; nothing is inferred from a mismatch.
- **`reportingAmount` counts a transfer as zero** in both directions, so moving money between your own wallets cannot inflate spending.
- **Order independence is tested, not assumed**: 40 records, 20 deterministic shuffles, identical balances every time. A stored-delta implementation cannot promise that.

WAL-01 runs the canonical six-step scenario from `acceptance-tests.md` §1 and asserts every intermediate balance exactly: 1000/200 → 987.5/200 → 887.5/300 → 889.75/300 → 989.75/200 → 1000/200.

Covered: WAL-01…11, 13…17, 19, 20. Deferred with reasons: **WAL-12** (currency change with linked rows) is enforced in the write RPC and belongs to Task 14's editor; **WAL-18** (legacy opening-balance migration) is Task 18.

## Task 03 — segmenter wired in (P4)

**Modified:** `SumIt/ViewModels/ChatViewModel.swift`, `SumIt/Views/Chat/ChatComposer.swift`, `SumIt/Services/LocalizationManager.swift`. **Added:** `SumItTests/chat-batch-tests.swift`.

`splitTransactionInput` is **deleted**, not deprecated. `TransactionInputSegmenter` is now the only splitter in the app, so `12,50 EUR coffee` can no longer become two transactions anywhere.

What else changed in that flow:

- **Failed segments are kept.** The old loop caught a parse failure, wrote `Log.warn("Could not parse part")` and moved on — then announced "recognized N" with a smaller N and no explanation of the difference. Failures now retain their original index and text, appear as their own messages, and populate a `failedSegments` list with a Retry that re-sends only those segments.
- **Unconfirmed cards are never replaced silently.** `sendMessage` and `sendImage` both refuse while confirmations are pending and say so. Clearing them is one deliberate action (`discardPending()`). Previously typing anything wiped `pendingTransaction` and `pendingQueue` on the spot.
- **Limits are visible errors.** Over 20 segments or over 500 characters produces a message stating the actual numbers, leaves the text in the input field, and sends nothing — so no partial batch is billed and nothing is truncated.
- Eight new strings, all six languages, asserted by a test.

### What is tested and what is not

The tests here cover the paths that need no AI service: the pending-work guard for both text and photo, explicit discard, both limit errors with the input preserved, and localization. The per-segment success/failure fan-out **cannot be tested yet** — `BackendService` is a singleton with no injection point. Task 10 makes the transport injectable; BATCH-01, BATCH-02 and BATCH-05 belong there.

## Status of the eight problems

| | Problem | State |
|---|---|---|
| P1 | Restore duplicates | open (Task 12) |
| P2 | False save success | open (Task 09) |
| P3 | Lost fractional amounts | **code ready, not wired** — editors still use `Double(amountStr…)` and `%.2f` (Task 14) |
| P4 | Decimal commas split entries | **closed in the live path** |
| P5 | Incomplete transfers | **arithmetic closed**; UI selection and storage are Tasks 09/14 |
| P6 | Delete/multi-device divergence | open (Tasks 10–13) |
| P7 | Hardcoded rates | open (Tasks 16/17) |
| P8 | Volatile storage fallback | **closed** |

## Known untidiness

The test log carries `disk I/O error` lines from SwiftData: `PersistentStoreFixture.destroy()` removes its directory while the `ModelContainer` is still alive, and `ModelContainer` has no explicit close. No test fails and no assertion depends on it, but it is noise that could mask a real error later. Worth tightening when the fixture next needs changing.
