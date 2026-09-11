# Ledger reliability execution — Task 06 (write RPC), interrupted

**Date:** 2026-09-09. **Status: INCOMPLETE — no database is currently reachable.**

## What happened to the environment

The organization is on the free plan with a limit of **2 active projects**. The three projects are:

| Project | Ref | Status now |
|---|---|---|
| `Babyline` (unrelated) | `nxnpwjgfahrngncmwcll` | ACTIVE_HEALTHY |
| `sumit` (production) | `mjhosrblavjdxirayvqt` | INACTIVE (paused) |
| `sumit-ledger-staging` | `cfdqzcauzlcsztfrkygi` | **PAUSED by this session** |

The staging project created for Task 05 was occupying the slot that `sumit` needed in order to resume, so it was paused as soon as that became clear. Production data and the real schema matter more than a sandbox.

The production project's own dashboard confirms the important part: **all data, including backups and storage objects, remains safe**, and the project is resumable from the dashboard **until 18 Jul 2027**. It is paused, not lost.

Resuming it is a dashboard action the owner has to take: this session's attempt to call `restore_project` was refused by the environment's permission policy, and that refusal was not worked around.

## What was completed before the interruption

`Backend/migrations/20260909_02_ledger_mutation_rpc.sql` is written in full, and its **first half is applied and verified on staging** (as migration `ledger_executor_policies_and_helpers`):

- Owner-scoped policies `TO sumit_ledger_executor` on the five ledger tables plus read-only access to `rate_quotes`. This also closes a real gap left by Task 05: RLS had been enabled on those tables with **no** policies, which correctly blocks clients but would equally have blocked the `NOBYPASSRLS` executor. It is fixed by a forward migration rather than by editing the already-applied file.
- `ledger_round_half_even(numeric, integer)` — PostgreSQL's `round()` on numeric is half-up, while the client quantizes half-even via `NSDecimalRound(.bankers)`. Left implicit, the two sides would disagree on exact ties such as 1.005, so the shared rule is written out explicitly.
- `ledger_canonical_text(numeric)` and a strict `ledger_parse_decimal(text, text)` that rejects exponents, signs, grouping and trailing characters before any numeric cast.
- The three snapshot builders producing the DTO shape from `database-and-rollout.md` §6.

`apply_ledger_mutation_v1(jsonb)` itself is **written but not applied**. Its first application attempt failed with:

```
ERROR: 42501: must be able to SET ROLE "sumit_ledger_executor"
```

That is a genuine finding, not a transient error. The function must be **owned by** the executor role, because `SECURITY DEFINER` executes as the owner and Supabase's `postgres` role carries `BYPASSRLS` — leaving the function owned by the migration role would have quietly defeated every row-level check inside it. Taking ownership requires the migration role to be a member of the target role first. The migration now grants that membership explicitly before the `ALTER FUNCTION ... OWNER TO`, with a comment recording why. Membership is admin-side only; `authenticated` and `anon` are never granted it.

**This fix is unverified.** It has not been applied or executed anywhere.

## Not claimed

- `apply_ledger_mutation_v1` has never run. No RPC, concurrency, replay or conflict test from Task 06 has been executed.
- The ownership fix above is reasoning about the error message, not a tested result.
- Task 05's G1 remains open: production has still never been read, so the staging schema remains a documented reconstruction.

## Resume path

1. The owner presses **Resume project** on `sumit` in the Supabase dashboard. The staging slot is already free.
2. Read the real production schema — the Task 05 discovery step that has been blocked from the start.
3. Reconcile the reconstruction against what production actually contains, and correct the migrations where they differ.
4. Only then apply anything, and only with explicit authorization for the production target.

Staging can be resumed later for the destructive and two-session concurrency tests that must not run against production, but only when a project slot is free.
