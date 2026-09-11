# Ledger reliability execution — Tasks 02 and 03

**Date:** 2026-09-09. **Baseline:** `202249998fae5e44f19bb420dbf7b3f58c070ef8`. **Toolchain:** Xcode 26.6 via `DEVELOPER_DIR`; see `ledger-execution-baseline-2026-09-09.md`.

## Verification actually performed

Both tasks are verified twice, by different means.

**1. XCTest on a real simulator** — the harness the plan requires:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project SumIt.xcodeproj -scheme SumIt \
  -destination "platform=iOS Simulator,id=74ECEA49-B4BD-4248-B0BA-48AE85D2DADF" \
  -derivedDataPath /tmp/sumit-ledger-derived-data test
```

Observed output on 2026-09-09:

| Suite | Result |
|---|---|
| `AmountParserTests` | Executed 12 tests, 0 failures |
| `MoneyValueTests` | Executed 14 tests, 0 failures |
| `TransactionInputSegmenterTests` | Executed 11 tests, 0 failures |
| All tests | **Executed 37 tests, with 0 failures (0 unexpected)** — `** TEST SUCCEEDED **` |

The three new production files are registered in the `SumIt` app target and compile into the app under its real settings (Swift 5 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, iOS 17 minimum). `** BUILD SUCCEEDED **`.

**2. A standalone executable specification**, written first while the toolchain was still misconfigured. It compiles the same production sources with `swiftc -swift-version 6` and asserts the same acceptance cases (`passed: 81, failed: 0` for money/parser, `passed: 31, failed: 0` for the segmenter). It lives in this session's scratchpad, not the repository. Its residual value is that it proves the sources are clean under the **Swift 6** language mode as well, which the app target does not yet enable.

## Task 02 — exact money and whole-field numeric parsing (P3/P7)

**Added:** `SumIt/Services/money-value.swift`, `SumIt/Services/amount-parser.swift`.
**Modified:** `SumIt/Services/Formatters.swift` (added `nonisolated static func editAmount(_:locale:)` forwarding to `MoneyCodec.editString`).
**Tests authored:** `SumItTests/money-value-tests.swift`, `SumItTests/amount-parser-tests.swift`.

- [x] Parameterized cases covering the AMT table written before the implementation was finalized.
- [x] Canonical Decimal/string encoding with no Double anywhere in the path. `MoneyCodec.decode` validates a strict full-string grammar **before** calling `Decimal(string:)`, which was measured on this machine to accept `1e3` → 1000 and `12abc` → 12. `encode` re-validates its own output against the canonical grammar.
- [x] Half-even quantization via `NSDecimalRound(.bankers)`; measured `1.005 → 1`, `1.015 → 1.02`, `2.675 → 2.68`, matching AMT-20.
- [x] Zero normalization (`-0` → `0`) and explicit range failures at 1e12; no capping.
- [x] Locale-aware parser with a fully checked grammar; `NumberFormatter`'s permissive prefix parse is not used at all.
- [x] Edit formatter with no grouping and no precision loss; round-trips in all six app languages (`en, uk, ru, es, de, pl`).
- [x] Verified by XCTest on the simulator, not only by the interim harness.
- [ ] **Deferred to Task 14:** auditing and removing every `%.0f` / `%.2f` / permissive `Double` caller. The display helper `Formatters.amount(_:currency:fractionDigits:)` is intentionally left in place for existing callers, as the plan directs.

### Deviation recorded

`MoneyError` carries a sixth case, `unsupportedCurrency`, beyond the five the plan names. A currency with no declared ledger precision cannot be validated, and mapping that to `invalidSyntax` would misreport the cause. The five named cases are all present and unchanged.

### AMT coverage

AMT-01…AMT-22 are all expressed. Two of them are partly owned by later tasks: AMT-21 (legacy over-precision preserved) is proved at the codec level here, and its metadata-edit behaviour belongs to Task 14/17; AMT-09's "normalized confirmation clearly shows chosen interpretation" is UI and belongs to Task 14.

One test expectation written during this task was **wrong and was corrected against the design, not the code**: `12,5` in en-US is accepted as 12.5, because design §5.1 accepts the alternative decimal separator exactly when it cannot be valid grouping for the locale. The implementation was already right.

## Task 03 — preserve numeric punctuation and all batch outcomes (P4)

**Added:** `SumIt/Services/transaction-input-segmenter.swift`.
**Tests authored:** `SumItTests/transaction-input-segmenter-tests.swift`.

- [x] Cases for decimal commas, thousands separators, explicit separators, written numbers, CRLF, merchant commas and >20 segments.
- [x] One pass over characters. A comma is a boundary only when its immediate neighbours are not both ASCII digits; newline, semicolon and a spaced ` + ` are separate boundaries. Conjunctions are never boundaries.
- [x] The `withNumbers` filter is gone: a segment without digits (`ten dollars coffee`) is retained. A content check asserts no letters or digits disappear between input and segments.
- [x] Segmentation runs on the raw text before `BackendService.sanitize`, on normalized line endings.
- [x] Limits are visible errors: `tooManySegments` at 21, `segmentTooLong` at 501 characters with the offending index. No prefix truncation.
- [ ] **BLOCKED (G0):** replacing `ChatViewModel.splitTransactionInput`, retaining indexed segment outcomes with retry, and disabling conflicting photo/text submissions during a pending batch. `ChatViewModel.swift` and `ChatComposer.swift` import SwiftUI/SwiftData, which cannot be compiled on this machine; the batch-outcome surface is also UI work whose regressions (BATCH-01…06) cannot be run. Writing unverifiable changes into those files would risk leaving the project unbuildable for the owner.

The pure segmenter is therefore complete and verified, and **not yet wired into the app**. The old `splitTransactionInput` is still the live code path until that integration lands.

One test expectation was again corrected against the design: `"10 coffee,"` yields `["10 coffee,"]`, because design §5.2 requires the **original** input to be sent when there are fewer than two nonempty segments.

## What is not claimed

- **No behaviour visible to a user has changed yet.** The new money, parser and segmenter code compiles into the app but nothing calls it: `ChatViewModel.splitTransactionInput` and the `Double`-based editors are still the live paths. P3 and P4 are not closed until Tasks 03 (integration) and 14 land.
- Persistence, transport, sync and UI are untouched and untested by these suites.
- No UI test target exists yet, so BATCH-01…06 and UIEDIT-01…08 have no coverage.
- The app has been built and its unit tests run; it has **not** been launched and exercised by hand.
