-- SumIt — Task 06 write RPC tests
--
-- STATUS: NOT YET EXECUTED. There is currently no environment where these may
-- run: production must not host destructive or two-session concurrency tests,
-- and the staging project is paused and was built from a reconstruction now
-- known to be wrong. See the end of this file for what running them needs.
--
-- Everything below assumes migrations 20260910_04 and 20260910_05 are applied
-- to the target, and uses two synthetic accounts. Wrap the whole file in a
-- transaction and ROLLBACK unless it is running against a disposable project.

\set ON_ERROR_STOP on

BEGIN;

-- Fixture accounts ----------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
 ('11111111-0000-4000-8000-00000000000a','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-a@staging.invalid','x', now(), now()),
 ('11111111-0000-4000-8000-00000000000b','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-b@staging.invalid','x', now(), now())
on conflict (id) do nothing;

create temporary table ledger_test_requests(name text primary key, request jsonb);

-- Helper: run as owner A ----------------------------------------------------
create or replace function pg_temp.as_owner_a() returns void language plpgsql as $$
begin
  perform set_config('role','authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub','11111111-0000-4000-8000-00000000000a','role','authenticated')::text, true);
end;
$$;

create or replace function pg_temp.as_owner_b() returns void language plpgsql as $$
begin
  perform set_config('role','authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub','11111111-0000-4000-8000-00000000000b','role','authenticated')::text, true);
end;
$$;

-- RPC-01  A wallet create is accepted and produces one receipt and one event.
-- RPC-02  Replaying the identical request returns the identical response and
--         creates no second entity, receipt or feed event.
-- RPC-03  Replaying the same operation_id with a different payload is refused
--         with operation_payload_mismatch and mutates nothing.
-- RPC-04  A create against an identity that already exists is a conflict
--         (already_exists), not an overwrite.
-- RPC-05  An update whose expected_revision is stale is a conflict
--         (revision_mismatch) carrying the server's full snapshot.
-- RPC-06  An update to an entity that does not exist is a conflict
--         (not_found), never an implicit create.
-- RPC-07  A put or delete against a tombstoned identity is a conflict
--         (deleted) carrying the tombstone.
-- RPC-08  Owner B cannot read, write or conflict with owner A's entities: the
--         RPC sees only auth.uid()'s own rows.
-- RPC-09  A transaction referencing another owner's wallet is refused.
-- RPC-10  A transfer with two positive legs and two distinct same-owner wallets
--         is accepted as ONE row carrying both references and both quantities.
-- RPC-11  A same-currency transfer with unequal legs is refused
--         (equal_currency_legs_must_match).
-- RPC-12  base_amount must equal the exact product half-even to scale 18;
--         a value off by 1e-18 is refused (base_amount_mismatch).
-- RPC-13  A quote claiming provider provenance without a matching rate_quotes
--         row is refused (unverified_provider_quote).
-- RPC-14  An identity quote is accepted only for USD at rate exactly 1.
-- RPC-15  valuation_state='unvalued' with any of base/rate/quote present is
--         refused; with all three null it is accepted and the original quantity
--         is still recorded.
-- RPC-16  Unknown top-level request fields, an unsupported protocol_version, a
--         non-object request and a >64 KiB request are all refused before any
--         lock is taken.
-- RPC-17  A delete sets deleted_at, keeps the row and its identity, and
--         allocates a revision.
-- RPC-18  writes_paused = true refuses every financial write for that owner.
--
-- IDENTITY (the case bug that discovery found in production)
-- RPC-19  An existing row whose local_id is UPPERCASE is found, updated and
--         versioned by a request carrying the lowercase UUID — no duplicate row
--         is created. Measured on production data: a case-sensitive comparison
--         finds 38 of 70 rows; the case-insensitive one finds 70 of 70.
-- RPC-20  Two rows differing only by the case of local_id are refused as
--         ambiguous_local_id rather than resolved by guessing which is meant.
-- RPC-21  A row created by the RPC stores local_id lowercase; a pre-existing
--         row keeps whatever case it already had (no silent identity rewrite).
--
-- CONCURRENCY (requires two real sessions; a single-session rollback proves
-- nothing about serialization)
-- CONC-01 Two sessions creating different entities for one owner both succeed
--         and receive distinct, consecutive cursors.
-- CONC-02 Two sessions updating the same entity from the same expected_revision:
--         exactly one is accepted, the other receives revision_mismatch.
-- CONC-03 Two sessions replaying the same operation_id concurrently produce one
--         entity, one receipt and one feed event.
-- CONC-04 A mutation held open in session 1 blocks session 2's cursor
--         allocation for the same owner, and does not block a different owner.
--
-- FEED
-- WAL-01  Every accepted mutation writes exactly one ledger_change_log row whose
--         cursor equals the entity's new ledger_revision and whose snapshot
--         round-trips through the client's LedgerSnapshot decoder.

ROLLBACK;

-- WHAT RUNNING THIS NEEDS
--
-- A disposable PostgreSQL target with production's real schema. The staging
-- project (cfdqzcauzlcsztfrkygi) is paused and its base schema came from a
-- reconstruction that the 2026-09-10 discovery disproved — it is missing
-- transactions.timestamp, invents categories.created_at, and has several
-- nullability constraints backwards. It has to be rebuilt from
-- docs/reports/production-discovery-2026-09-10.md before it is worth anything.
--
-- The organization's free plan allows two active projects, and production plus
-- one unrelated project already occupy both slots.
