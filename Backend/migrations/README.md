# Ledger migrations

These files are the ledger-reliability work (September 2026). Migrations
applied before it (April–May 2026: profiles, wallets, category sync, hardening)
predate this directory; `Backend/supabase_migration.sql` is the earlier
reconstruction of that schema and is **not** an exact copy of production.

## What production has applied, and where it is in this directory

Versions are from `supabase_migrations.schema_migrations` on project
`mjhosrblavjdxirayvqt`, read on 2026-09-11.

| Applied version | Applied name | File |
|---|---|---|
| 20260909173057 | `base_schema` | `20260909_00_base_schema.sql` — applied in error; see `docs/reports/production-incident-2026-09-09.md` |
| 20260909173144 | `ledger_foundations` | `20260909_01_ledger_foundations.sql` |
| 20260910064936 | `revert_legacy_write_gate` | `20260909_03_revert_production_write_gate.sql` |
| 20260910065142 | `drop_redundant_duplicate_indexes` | `20260910_03a_drop_redundant_duplicate_indexes.sql` |
| 20260910065225 | `drop_orphan_legacy_write_gate_helper` | `20260910_03b_drop_orphan_legacy_write_gate_helper.sql` |
| 20260910071121 | `ledger_rpc_helpers_reworked` | `20260910_04_ledger_mutation_rpc.sql` |
| 20260910071849 | `ledger_current_uid_helper` | `20260910_04_ledger_mutation_rpc.sql` |
| 20260910071701 | `apply_ledger_mutation_v1_reworked` | `20260910_05_apply_ledger_mutation_rpc.sql` |
| 20260910071911 | `rpc_use_ledger_current_uid` | `20260910_05_apply_ledger_mutation_rpc.sql` |
| 20260910072120 | `rpc_already_exists_precedence` | `20260910_05_apply_ledger_mutation_rpc.sql` |
| 20260910094443 | `ledger_change_feed` | `20260910_06_ledger_change_feed.sql` |
| 20260911192119 | `20260911_07_revoke_public_parse_count_functions` | `20260911_07_revoke_public_parse_count_functions.sql` |

Files 04 and 05 hold the **final** state of their functions. On production they
were applied in several steps while defects were fixed (the executor could not
read `auth.uid()`, and `already_exists` had to take precedence over a revision
mismatch); each step is an idempotent `CREATE OR REPLACE`, so applying the file
once produces the same result as the sequence did.

`20260909_02_ledger_mutation_rpc.sql` is **superseded** and was never applied.

## Tests

`Backend/tests/*.sql` exercise these migrations with synthetic accounts. Each
file states whether and where it has been executed.
