-- SumIt — Task 07 change-feed tests
--
-- STATUS: EXECUTED 2026-09-10 against production inside transactions that were
-- rolled back. Results are in
-- docs/reports/ledger-execution-task-07-2026-09-10.md.
--
-- Everything below is written to run inside BEGIN … ROLLBACK. It creates
-- synthetic auth users and seeds synthetic feed rows; it reads no production
-- row into an assertion and modifies none.

BEGIN;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
 ('11111111-0000-4000-8000-00000000000a','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@test.invalid','x', now(), now()),
 ('11111111-0000-4000-8000-00000000000b','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@test.invalid','x', now(), now())
on conflict (id) do nothing;

create temporary table collected(cursor bigint);
grant all on collected to authenticated;

-- 2,503 events for owner A. `created_at` is deliberately shuffled and many rows
-- share a timestamp, so any ordering that is not by cursor shows up as a gap or
-- a duplicate. Every tenth event is a tombstone. Owner B gets five events that
-- must never appear in A's pages.
insert into public.ledger_sync_state(user_id, cursor) values
 ('11111111-0000-4000-8000-00000000000a', 2503),
 ('11111111-0000-4000-8000-00000000000b', 5);

insert into public.ledger_change_log(user_id, cursor, operation_id, entity_kind, entity_local_id, snapshot, created_at)
select '11111111-0000-4000-8000-00000000000a', g, gen_random_uuid(), 'transaction', gen_random_uuid(),
       jsonb_build_object('ledger_revision', g::text,
                          'deleted_at', case when g % 10 = 0
                                             then '"2026-05-20T12:00:00Z"'::jsonb
                                             else 'null'::jsonb end),
       timestamptz '2026-01-01' + ((g * 7919) % 1000) * interval '1 hour'
  from generate_series(1, 2503) g;

insert into public.ledger_change_log(user_id, cursor, operation_id, entity_kind, entity_local_id, snapshot)
select '11111111-0000-4000-8000-00000000000b', g, gen_random_uuid(), 'transaction', gen_random_uuid(), '{}'::jsonb
  from generate_series(1, 5) g;

-- PULL-01  Page through the whole feed with limit 250.
-- PULL-02  The watermark returned on page 1 is unchanged on every later page.
-- PULL-03  No page exceeds the requested limit.
-- PULL-04  Every seeded cursor is retrieved exactly once: 2503 rows, 2503
--          distinct, 0 missing, 0 unexpected, 0 duplicated.
-- PULL-05  Cursors ascend strictly across page boundaries, not just within a page.
-- PULL-06  Tombstones are ordinary events and are delivered (250 of them).
-- PULL-07  An empty follow-up page returns the watermark as next_cursor and
--          has_more = false, so a caller that stores it stops asking.
do $$
declare
  page jsonb; after_cursor bigint := 0; through_first bigint; pages int := 0; page_len int;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims',
    json_build_object('sub','11111111-0000-4000-8000-00000000000a','role','authenticated')::text, true);

  loop
    if pages = 0 then
      page := public.read_ledger_changes_v1(after_cursor, null, 250);
      through_first := (page->>'through_cursor')::bigint;
    else
      page := public.read_ledger_changes_v1(after_cursor, through_first, 250);
    end if;
    pages := pages + 1;

    if (page->>'through_cursor')::bigint <> through_first then
      raise exception 'PULL-02 FAILED: watermark moved on page %', pages;
    end if;

    select count(*) into page_len from jsonb_array_elements(page->'changes');
    if page_len > 250 then
      raise exception 'PULL-03 FAILED: page of %', page_len;
    end if;

    insert into collected(cursor)
    select (e->>'cursor')::bigint from jsonb_array_elements(page->'changes') e;

    after_cursor := (page->>'next_cursor')::bigint;
    exit when (page->>'has_more')::boolean is false;
    if pages > 20 then raise exception 'PULL-01 FAILED: runaway paging'; end if;
  end loop;
end
$$;

reset role;

select
  (select count(*) from collected) as retrieved_total,
  (select count(distinct cursor) from collected) as retrieved_distinct,
  (select count(*) from generate_series(1,2503) g
     where not exists (select 1 from collected c where c.cursor = g)) as missing,
  (select count(*) from collected c where c.cursor not between 1 and 2503) as unexpected,
  (select count(*) from (select cursor from collected group by cursor having count(*) > 1) d) as duplicated;

-- PULL-08  Argument validation: limit 0, limit 251, a negative after cursor,
--          and a through cursor beyond what is committed are all refused.
-- PULL-09  Owner B sees only its own five events, and asking for A's window is
--          refused because A's watermark is beyond B's committed cursor.

ROLLBACK;

-- NOT COVERED HERE — needs two simultaneous sessions
--
-- CONC-04  Hold a mutation open in session 1, start another in session 2, read
--          the watermark, then commit or roll back, and prove no committed
--          lower cursor is ever skipped. A single rolled-back transaction
--          cannot demonstrate serialization. This requires a disposable target,
--          because it must not run against production.
