# Handoff: SumIt eight-issue reliability execution plan

- **Date:** 2026-09-09.
- **Repository:** `/Users/max/General/side/Finhelper/sumit`.
- **Branch:** existing `main`.
- **Baseline HEAD:** `202249998fae5e44f19bb420dbf7b3f58c070ef8`.
- **Request completed here:** prepare an exceptionally detailed implementation plan for eight data-correctness problems; do not implement them yet.

## What is ready

The plan package is at `docs/plans/sumit-ledger-reliability-2026-09-09/README.md`. It contains design, 22 dependency-ordered tasks, schema/protocol/migration details, source map and exact acceptance cases. All execution steps remain unchecked. The earlier audit is at `docs/reports/sumit-audit-2026-09-09.md`.

The eight scope items are P1 restore duplicates, P2 false save success, P3 lost fractional amounts, P4 comma splitting, P5 incomplete transfers, P6 delete/multi-device divergence, P7 hardcoded FX, P8 memory-store fallback. Do not mistake them for audit F01–F08; the mapping is in design.md.

## First actions after the user authorizes execution

1. Read implementation-plan.md, design.md, database-and-rollout.md and acceptance-tests.md together.
2. Inspect actual Git status/HEAD. Earlier audit files and this plan are uncommitted documentation; preserve them. Do not include unrelated staged changes in a commit.
3. Execute Task 00: discover a compatible Xcode/simulator and create/verify baseline persistent fixtures. Do not claim a baseline build passed from this planning session.
4. Implement task by task with `superpowers:executing-plans`, recording actual evidence and updating checkboxes only when each gate passes. No automatic subagents or worktree creation.

## Key decisions to preserve

- Keep the existing stack. One checked local financial command creates entity change, saved reply and durable sync intent atomically.
- Exact amounts use canonical decimal strings / Foundation Decimal / PostgreSQL NUMERIC; rates carry explicit provenance and quote-resolution policy.
- Stable identity is owner + entity kind + original UUID. Restoring must never generate a replacement UUID.
- Balances derive from opening values and active record effects. Transfers are one transaction with source/destination UUIDs and two confirmed quantities.
- Server mutations have immutable operation IDs, expected revisions, replay receipts and an ordered owner-scoped change feed. Pull pages and local cursor commit together.
- Conflicts are explicit. A remote delete never silently resurrects from an old edit; a new copy requires a new UUID and user intent.
- Schema changes are additive. Existing ambiguous records require reconciliation, not fuzzy deduplication or automatic deletion.
- Storage failure disables financial activity while preserving files. No writable in-memory fallback or automatic reset.

## What is not established

Full iOS build/device behavior, live schema/constraints/grants, provider account qualification and production migration/pilot remain unverified. The audit found the configured Supabase host unresolved. Two Frankfurter probes in planning returned 403; no successful provider qualification is implied. CoinGecko credentials were not supplied or used. The Apple key is unrelated to these eight fixes and must not be used for them.

Gate failures must remain visible. Continue independent work but do not invent test passes, provider access, schema facts, historical missing amounts or a production rollout.

## Guardrails

Work on the current branch unless the user explicitly approves a branch/worktree. No PR unless requested. No production deployment/migration from the documentation-only request. During later authorized migration work, pair the local migration record with immediate application to the verified target and read back its state; never break active legacy readers. Upgrade every pilot device before per-account protocol adoption. After adoption, rollback means a forward fix with retained data, not restoring the old unsafe binary or dropping columns.

All new secrets follow the managed vibe-os workflow. No real database backups or financial payloads in this public repository. Use synthetic fixtures for fault injection and a verified staging project for RLS/concurrency tests.

## Completion standard

The acceptance matrix and two-device schedule are the completion contract. Record build/test commands, exact environments, applied schema identifiers, known issues and pilot outcome. Completion of the eight data fixes does not certify the independent StoreKit, privacy or PIN findings from the audit.
