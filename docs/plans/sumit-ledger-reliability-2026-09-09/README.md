# SumIt — eight-issue execution package

This package turns the eight numbered data-correctness problems from the audit response into a concrete, dependency-ordered implementation plan. It is documentation only: no product code, database, deployment, branch or credential configuration was changed.

Start with [implementation-plan.md](implementation-plan.md), then read its linked design and database contracts before execution. The eight issues are restore duplicates, false save success, lost fractional amounts, decimal-comma segmentation, incomplete transfers, divergent deletion/sync, hardcoded rates, and silent in-memory fallback after database failure.

## Read order

1. [Implementation plan](implementation-plan.md) — 22 tasks, 140 execution/review checkboxes, files/interfaces, concrete steps and review gates.
2. [Design contract](design.md) — invariants, money precision, wallet formula, transfer model, owner scope, retry/conflict semantics and rate behavior.
3. [Database and rollout](database-and-rollout.md) — read-only discovery SQL, additive schema, complete wire examples, RLS boundaries, adoption and rollback.
4. [Acceptance tests](acceptance-tests.md) — 218 required cases across 20 groups, exact synthetic values, failure cases, a 12-step two-device schedule and closure mapping for all eight issues.
5. [Current source map](source-map.md) — verified baseline file/line entry points and shared callers.
6. [Execution handoff](../../handoffs/sumit-ledger-reliability-plan-2026-09-09.md) — concise prompt/context for the next executor.
7. [Plan verification](planning-verification.md) — what was checked in this documentation pass and what remains an execution gate.

## Chosen scope

Preserve SwiftUI/SwiftData/Supabase and the current product. Use exact amounts, stable IDs, durable mutations, atomic revision checks, explicit conflicts and frozen dated quotes. Replace independent mutable wallet totals with opening balance plus active transaction effects. Preserve and reconcile existing records; do not wipe/recreate a financial history.

This work does not implement the audit's separate payment, PIN cryptography, privacy/legal, bank-connection or redesign findings. Necessary data-isolation/pagination/complete-history dependencies are included because the eight fixes would otherwise remain incomplete.

## External prerequisites are explicit

- Full compatible Xcode and a real simulator/device are needed. The audit machine's standalone Swift tooling failed before runtime.
- The real Supabase project and schema must be verified; the configured audit hostname did not resolve. Existing schema/grants are not guessed.
- Frankfurter fiat endpoints were checked against official docs; both planning probes returned 403. [Raw probe evidence](rate-provider-probes.json) is preserved. Runtime qualification from the intended backend is still required.
- CoinGecko Demo is a documented crypto candidate; no account key or paid request was used. Exact asset IDs, historical access and quotas must be verified against the authorized account.
- A coordinated upgraded-device pilot and explicit production authorization precede account adoption. Old offline binaries cannot participate safely in the new mutation protocol.

A blocked prerequisite does not prevent independent local implementation/testing, but it prevents declaring the dependent feature or rollout complete. No execution checkbox is prechecked.
