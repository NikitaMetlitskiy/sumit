# Ledger reliability execution — Task 14 (financial UI onto exact atomic commands, P2/P3/P4/P5/P6)

**Date:** 2026-09-11. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **232** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |

New this task: `UIWritePathTests` 21, covering UIEDIT-01…08 plus WAL-12/13 and the archive rules.

## What this replaces

Every financial write in the app used to happen in the view that displayed it. Concretely:

- **Opening an editor rounded the amount.** Both editors initialised their amount field with `String(format: "%.0f", …)`. Opening a €12.50 expense and pressing Save wrote **€12**. The confirmation card *displayed* it through `Formatters.amount(_:fractionDigits: 0)`, so the user was asked to confirm a number the app was not going to store.
- **Saving parsed a Double.** `Double(text.replacingOccurrences(of: ",", with: "."))` — permissive, locale-blind, and silently `?? 0` on failure.
- **Editors mutated the live record.** `store.editTransaction(tx) { tx in … }` changed fields on the stored object before anything was validated, so a rejected save left it half-changed and Cancel had already happened.
- **Wallets were matched by name and balances were nudged.** `applyWalletDelta` found a wallet by lowercased name, converted at whatever rate was loaded, and added a delta to a stored running total. Two wallets called "Cash" made it pick one arbitrarily; renaming one broke the link; and the stored total drifted away from the transactions it was supposed to summarise.
- **Deleting a transaction erased the row** and fired a best-effort remote delete.
- **Views uploaded to Supabase themselves**, in detached tasks whose failures were log lines.

All of that is gone. `AppStore` is now a thin façade over `LedgerStore`: `saveConfirmed`, `editTransaction`, `deleteTransaction`, `saveWallet`, `archiveWallet`, `saveCategory`, `archiveCategory`. Each returns a definite success or a machine code, and each queues a durable operation.

## The editor

`TransactionEditorFields` is plain text plus identities. Nothing reaches the store until `TransactionEditor.draft(…)` returns a complete, valid draft, which is also what disables Save — with the message under the field that is wrong, not one message for the form.

Decisions worth naming:

- **An untouched entry is not re-rated.** The valuation is carried over verbatim unless the amount or the currency actually changed. Editing a merchant used to recompute `rateAtTime` at today's rate and move the reported total of an entry nobody touched.
- **Same currency is not asked twice.** When the wallet's currency matches the transaction's, the wallet quantity *is* the amount; the field only appears when they differ, because that is the only case where a person knows something the app does not.
- **A different-currency wallet is never attached at an invented rate.** `ParsedTransactionDraft` returns no wallet in that case and the editor asks.
- **An ambiguous wallet name attaches nothing.** Two wallets named "Cash" means no wallet, not a coin flip. The transaction is still recorded — the wallet is what is left unset.
- **Transfers are complete or refused.** Source, destination, both quantities; equal currencies must move equal amounts, since a difference would be a fee hidden inside the transfer, and fees are their own entry.
- **Archiving, never deleting.** An archived wallet or category disappears from new entries and stays behind every record that points at it — and stays selectable in the editor of a record that already uses it.
- **A wallet with history keeps its currency.** Changing it would silently reinterpret every quantity recorded against it.
- **A second tap returns the first transaction.** `duplicateEntity` is answered with the existing record, not a new identity, and the Save button disables itself for the duration.

## Truthful copy

`LedgerErrorCopy` maps each machine code to one sentence, in all six languages, with a generic fallback — so a code added later shows a real sentence rather than `same_currency_effect_mismatch`. A test asserts every known code has wording and that none of them leaks a raw token.

The saved-receipt line now says **"Saved on this device"**, and adds **"Waiting to sync"** while the entity still has queued work. A local save is a real receipt; saying the server has it would not be.

## Two defects the tests found

- **Archiving a wallet wiped out every balance.** `walletBalances()` built its descriptor map from *active* wallets only, so a transaction pointing at an archived one made `effects` throw `unknownWallet` and the whole calculation returned empty — every wallet showed nothing. Archived wallets are now included in the calculation (which `WalletLedger.effects` explicitly supports) and excluded only from the display list.
- **The chat welcome message carried no owner.** Under Task 13's scoping a nil-owner message is visible only when signed out, so a signed-in user saw an empty chat and a new welcome row was inserted on every launch. Now stamped with the owner.

## The change I reverted, and why

I retired `restoreFromCloud` in favour of `pull`, then checked the claim against production before believing it:

```
transactions  rows 70  with_revision 70  min 0  max 0
categories    rows  2  with_revision  2  min 0  max 0
```

`read_ledger_changes_v1` selects `c.cursor > p_after_cursor`, and a first pull asks from 0. **Every existing production row has revision 0, so the feed returns none of them.** Retiring the legacy read would have made an existing user's entire history invisible on a new device.

So the legacy path stays, as `restoreLegacyRowsFromCloud`, with two fixes and one honest limitation:

- identity is compared as **UUID values**, not strings — Swift writes `uuidString` in uppercase and the server returns lowercase, which is why a restore used to create a second copy of the same transaction (32 of the 70 production rows are uppercase);
- rows the ledger already knows are left alone;
- the server-side row cap on that endpoint is **not** fixed here. A history larger than the cap is still not fully represented by this path.

Restored rows are marked `.legacy`, so they are excluded from exact calculations until Task 18 adopts them. This is the sequencing the plan already has: Task 18 owns adoption, and it has to land before the legacy path can go.

## What is not claimed

- **No adopted-row round trip against the real server.** The client speaks to `apply_ledger_mutation_v1` and `read_ledger_changes_v1`, both applied and functionally verified on production (Tasks 06/07) — but this client and those RPCs have still never exchanged a real request. The first ones will be created by this task's writes.
- **Legacy rows are still not in the ledger.** They display, and they are excluded from exact wallet balances and exact reporting because they have no exact amount. Until Task 18, a user with only legacy rows sees empty wallet balances rather than wrong ones.
- **The AI path still sends a Double.** `ParsedTransaction.amountExact` exists and the user-typed path fills it; the parser does not yet. Task 15 supplies `amount_decimal`, and until then an AI-parsed amount is read through the Double's shortest decimal description.
- **The reported USD value is unverified.** Anything that is not USD gets `.legacyUnverified` from the existing static table — recorded as unverified, never presented as a quote. Task 16 supplies real quotes.
- **No UI test drives the new editors.** The rules are tested directly at the model level; accessibility identifiers were added for the UI regressions but nothing uses them yet.
- **`ReportsView` and `Formatters.amount` still exist as Double display paths.** Reports were not rewritten in this task; the exact display helper (`Formatters.exactAmount`) is used where the number is the record's own amount.
