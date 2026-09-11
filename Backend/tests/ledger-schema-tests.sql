-- SumIt — Task 05 schema tests
--
-- Run against the STAGING project only. Uses two synthetic auth users; never a
-- production account identifier.
--
-- These assertions exist because catalog privilege checks are not proof: a role
-- can still reach a table through an inherited grant, and a RESTRICTIVE policy
-- can be written so that it never actually fires. Every check below performs a
-- real SET ROLE + JWT claim and attempts the real statement.

\set owner_a '11111111-0000-4000-8000-00000000000a'
\set owner_b '11111111-0000-4000-8000-00000000000b'

-- Fixture accounts -----------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
 ('11111111-0000-4000-8000-00000000000a','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-a@staging.invalid','x', now(), now()),
 ('11111111-0000-4000-8000-00000000000b','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-b@staging.invalid','x', now(), now())
on conflict (id) do nothing;

-- 1. Catalog-level expectations ----------------------------------------------
do $$
begin
  if has_table_privilege('authenticated','public.ledger_mutation_receipts','INSERT') then
    raise exception 'FAIL: authenticated holds INSERT on ledger_mutation_receipts';
  end if;
  if has_table_privilege('anon','public.ledger_change_log','UPDATE') then
    raise exception 'FAIL: anon holds UPDATE on ledger_change_log';
  end if;
  if (select rolbypassrls from pg_roles where rolname = 'sumit_ledger_executor') then
    raise exception 'FAIL: the executor role bypasses RLS';
  end if;
  if (select rolcanlogin from pg_roles where rolname = 'sumit_ledger_executor') then
    raise exception 'FAIL: the executor role can log in';
  end if;
  if exists (select 1
               from pg_auth_members m
               join pg_roles r on r.oid = m.roleid
               join pg_roles g on g.oid = m.member
              where r.rolname = 'sumit_ledger_executor'
                and g.rolname in ('authenticated','anon')) then
    raise exception 'FAIL: a client role is a member of the executor role';
  end if;
end
$$;

-- 2. Real role + JWT attempts ------------------------------------------------
do $$
declare
  owner_a constant text := '11111111-0000-4000-8000-00000000000a';
  ok boolean;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', owner_a, 'role', 'authenticated')::text, true);

  begin
    perform 1 from public.ledger_sync_state limit 1;
    raise exception 'FAIL: authenticated could SELECT ledger_sync_state';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.ledger_change_log(user_id, cursor, entity_kind, entity_local_id, snapshot)
    values (owner_a::uuid, 1, 'transaction', gen_random_uuid(), '{}'::jsonb);
    raise exception 'FAIL: authenticated could INSERT into ledger_change_log';
  exception when insufficient_privilege then null;
  end;

  begin
    perform 1 from public.rate_quotes limit 1;
    raise exception 'FAIL: authenticated could SELECT rate_quotes';
  exception when insufficient_privilege then null;
  end;

  -- A legacy account has no state row and must keep working unchanged.
  select public.ledger_legacy_writes_allowed_v1() into ok;
  if ok is not true then
    raise exception 'FAIL: a legacy account with no state row was blocked';
  end if;

  insert into public.transactions(user_id, local_id, type, original_amount, original_currency, occurred_at)
  values (owner_a, '30000000-0000-4000-8000-000000000001', 'expense', 12.5, 'USD', now())
  on conflict (user_id, local_id) do nothing;

  reset role;
end
$$;

-- 3. Adopted account: writes refused, reads preserved, neighbours unaffected --
insert into public.ledger_sync_state(user_id, cursor, protocol_version, writes_paused)
values ('11111111-0000-4000-8000-00000000000a', 0, 1, false)
on conflict (user_id) do update set protocol_version = 1, writes_paused = false;

do $$
declare
  owner_a constant text := '11111111-0000-4000-8000-00000000000a';
  owner_b constant text := '11111111-0000-4000-8000-00000000000b';
  visible int;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', owner_a, 'role', 'authenticated')::text, true);

  if public.ledger_legacy_writes_allowed_v1() is not false then
    raise exception 'FAIL: an adopted account still reports legacy writes allowed';
  end if;

  begin
    insert into public.transactions(user_id, local_id, type, original_amount, original_currency, occurred_at)
    values (owner_a, '30000000-0000-4000-8000-000000000002', 'expense', 1, 'USD', now());
    raise exception 'FAIL: an adopted account accepted a direct legacy INSERT';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.transactions set merchant = 'changed' where user_id = owner_a;
    if found then raise exception 'FAIL: an adopted account accepted a direct legacy UPDATE'; end if;
  exception when insufficient_privilege then null;
  end;

  -- An adopted account on an old client must still be able to READ its data.
  select count(*) into visible from public.transactions;
  if visible <> 1 then
    raise exception 'FAIL: an adopted account can no longer read its own rows (got %)', visible;
  end if;

  -- Cross-user isolation.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', owner_b, 'role', 'authenticated')::text, true);
  select count(*) into visible from public.transactions;
  if visible <> 0 then
    raise exception 'FAIL: owner B can see owner A rows (got %)', visible;
  end if;

  -- One account's adoption must not block a different, unadopted account.
  if public.ledger_legacy_writes_allowed_v1() is not true then
    raise exception 'FAIL: unadopted owner B was blocked by owner A''s adoption';
  end if;

  reset role;
end
$$;

-- Leave the fixture unadopted for the following tasks.
update public.ledger_sync_state set protocol_version = 0
 where user_id = '11111111-0000-4000-8000-00000000000a';

select 'ledger-schema-tests: all assertions passed' as result;
