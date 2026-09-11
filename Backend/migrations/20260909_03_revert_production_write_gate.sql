-- SumIt — revert the only live behaviour change made to production on 2026-09-09
--
-- NOT YET APPLIED. Awaiting the owner's decision.
--
-- Context: migrations 00 and 01 were applied to the production project while
-- acting on a misreading of its state (see the correction header in
-- 20260909_00_base_schema.sql). Almost everything they did is inert — added
-- nullable columns, new empty tables, a NOLOGIN role. The one exception is the
-- nine RESTRICTIVE write-gate policies, which sit in the live write path of
-- every authenticated user.
--
-- They currently permit every write: with no `ledger_sync_state` rows,
-- `ledger_legacy_writes_allowed_v1()` returns true, and this was verified for
-- all three real users. But machinery that gates production writes has no
-- business being there before the protocol it belongs to exists, so this file
-- removes it. It can be reintroduced by the adoption task when it is actually
-- needed and actually tested.
--
-- The additive columns, the ledger tables and the executor role are left alone:
-- they are unreferenced and removing them would be another unnecessary change
-- to a live database.

DROP POLICY IF EXISTS "tx_legacy_write_gate_insert"     ON public.transactions;
DROP POLICY IF EXISTS "tx_legacy_write_gate_update"     ON public.transactions;
DROP POLICY IF EXISTS "tx_legacy_write_gate_delete"     ON public.transactions;
DROP POLICY IF EXISTS "wallet_legacy_write_gate_insert" ON public.wallets;
DROP POLICY IF EXISTS "wallet_legacy_write_gate_update" ON public.wallets;
DROP POLICY IF EXISTS "wallet_legacy_write_gate_delete" ON public.wallets;
DROP POLICY IF EXISTS "cat_legacy_write_gate_insert"    ON public.categories;
DROP POLICY IF EXISTS "cat_legacy_write_gate_update"    ON public.categories;
DROP POLICY IF EXISTS "cat_legacy_write_gate_delete"    ON public.categories;
