# Ledger reliability execution — Task 13 (account scope and explicit conflict resolution, P1/P6)

**Date:** 2026-09-11. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`, iPhone 17 Pro / iOS 26.5.

## Test results

| Bundle | Result |
|---|---|
| `SumItTests` | Executed **211** tests, 0 failures |
| `SumItUITests` | Executed **2** tests, 0 failures |

New this task: `AccountScopeTests` 12, `LedgerConflictTests` 12. The previous total was 187 unit tests.

## What this replaces

Three separate behaviours, each of which could show one person another person's money:

- **`@Query` returned every row in the store.** Six query sites — chat, reports, wallets, category management — fetched `Transaction`, `Wallet`, `Category` and `ChatMessage` with no owner predicate. On a device where a second account signed in, the first account's data was simply on screen. A database policy does not help here: the rows are already local.
- **Signing in rewrote the device's data to the new owner.** `ProfileEditView` walked every row whose `userId` was `local` and set it to the newly signed-in uid, then uploaded it. Whoever signed in on a shared or resold device inherited — and published to their own account — someone else's history. That block is gone; `AppStore.recordLocalDataAwaitingImport(ownerID:)` records a `SyncIssue` instead, and the rows keep the `local` owner until Task 18's explicit import.
- **A token refresh could sign a previous account back in.** `refreshSessionIfNeeded` captured no identity, so a slow response for account A, arriving after A signed out, applied its session. `scopeEpoch` is now captured before the request and checked twice after it — once before acting on the status code and once before saving.

## Scope

`AccountScope(ownerID:epoch:)` is the unit everything keys on. `scopeEpoch` changes on sign-in, sign-out and user switch, and deliberately **not** on a same-account token refresh — churning it there would rebuild every view and discard in-flight work for nothing. `RootView` carries `.id(auth.scopeEpoch)`, so a switch rebuilds the scoped view tree rather than leaving a stale one holding the old owner's results.

`LedgerScope` holds the four filters. Two details worth naming:

- **Bundled default categories are shared templates and belong to no account**; a custom category belongs to whoever created it. Filtering those identically would either hide everyone's defaults or leak everyone's custom categories.
- **Chat written before accounts existed carries no owner.** It stays with the signed-out device dataset rather than joining whichever account signs in next. This is the same principle as the removed adoption block, applied to the one entity that has no `userId` column at all.

Deleted rows are filtered here too: the tombstone is retained so the deletion can still reach other devices, and hidden so it reads as deleted.

## Conflict resolution

`ConflictResolution` has exactly three outcomes, and none of them merges a money field:

| Choice | What happens |
|---|---|
| **useServer** | The remote snapshot is materialized; that entity's queued work is cancelled; the local candidate stays inside the issue until dismissed |
| **keepLocal** | The row's acknowledged revision is set to what the server actually holds, the stale operation is cancelled, and a **new** `PendingMutation` is queued — never a retry of the blocked one |
| **saveAsNew** | Only where it means something: the server deleted the record and the owner wants their version. It is recorded under a **new** identity; the original keeps the server's tombstone |

`dismiss` is a separate, explicit step that refuses to run on an unresolved issue, because it is what destroys the discarded candidate.

## The UI

`sync-issues-view.swift` uses the existing `Form`/`Section` patterns — no design overhaul, as the plan requires.

- Amounts are rendered from the **exact stored strings**. A currency formatter would show the user a rounded number that neither version contains, which is precisely the class of defect this plan exists to remove.
- Each side shows amount, currency, wallet, place, date and revision. The local side shows "not sent yet" where a revision would be, because it has never been accepted by one.
- **Save-as-new only appears when the server version is a tombstone.** Offering it otherwise would mean offering to duplicate a live record.
- Issues that are not two-version conflicts — a missing wallet reference, a legacy dataset awaiting import — get an explanation and no button, rather than an action that would not do what it says.
- Wording is keyed on the machine reason. An unrecognised reason falls back to a generic sentence; the raw token is never presented as prose.
- The Settings row appears only while something is open, with a count. A conflict the user never sees is a conflict that resolves itself by being ignored.

32 new strings, all six languages, asserted by test.

## The delayed-response case

The plan's Done criterion names it specifically, so it is tested end to end rather than argued: `StubURLProtocol` is registered on the shared session and holds the response; the test waits until the request is genuinely in flight, signs out, then releases it. The refresh reports failure, `userId` is back to `local`, and A is not signed back in. Reaching that ordering needed a `#if DEBUG` seam (`installSessionForTesting`) to place a known expired session without going through Apple.

## Decisions worth naming

- **`recordLocalDataAwaitingImport` records nothing when there is no device data**, and never records a second copy of the same open issue. An issue list that grows on every sign-in is one the user stops reading.
- **Resolving an already-resolved issue is a no-op, not an error.** Two taps on a slow screen must not queue two operations.
- **Resolving an issue belonging to another account fails as `missingEntity`.** The scope predicate is part of the lookup, not a check after it.
- **A further remote edit after keepLocal conflicts again.** Tested. The alternative — retrying until it lands — is silent last-write-wins with extra steps.

## What is not claimed

- **Nothing on this screen is reachable from a real conflict yet**, because nothing calls `pull` in production. `AppStore` still restores through the old path; Task 14 migrates the callers. The UI is verified against issues created by the pull merge in tests, not by a live server.
- **`saveAsNew` covers transactions only.** Wallets and categories fall back to `cannot_save_as_new`. A resurrected wallet would need its whole balance history reconstructed, which is not this task's work.
- **No UI test drives the conflict screen.** The presentation logic is tested directly (`SyncIssuePresentation`); the SwiftUI rendering of it is not, and the accessibility identifiers were added in anticipation of Task 14's UI regressions rather than used by a test today.
- **The `local` → account import path does not exist yet.** Signing in now records an issue that explains the situation and offers nothing to press. That is deliberate — Task 18 owns the import — but it is a visible loose end until then.
- **CONC-01…04 remain unrun.** They need two simultaneous authenticated sessions against a disposable backend; the free plan's two project slots are occupied.

## Noise, not failure

Tearing down the file-backed fixture logs `SQLite error code:6922` from CoreData: the store files are removed while the container still holds an open context, so background work finds them gone. It appears after the assertions have already passed and has been present since Task 02. It is noise from the test harness, not a product defect — but it is also the reason the test log has to be read for the `Executed N tests` line rather than for the absence of the word "error".
