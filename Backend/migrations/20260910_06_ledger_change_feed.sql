-- SumIt — Task 07: ordered, bounded, complete change reads
--
-- One RPC returning one bounded JSON page. The properties that matter:
--
--   • THE WATERMARK IS FIXED FOR THE WHOLE RUN. The first page reads the
--     owner's committed cursor and returns it as `through_cursor`; every later
--     page passes that same value back. Advancing the watermark to "now"
--     between pages is how a concurrently committed lower cursor gets skipped
--     forever, and cursor allocation happens under the per-owner state lock in
--     apply_ledger_mutation_v1 precisely so a visible high watermark cannot
--     hide an uncommitted lower one.
--
--   • ORDER IS BY CURSOR, NEVER BY TIME. Occurrence dates are user data and
--     arrive out of order; wall-clock timestamps tie. Only the cursor is
--     monotonic per owner.
--
--   • THE PAGE IS BOUNDED IN THE FUNCTION. `limit + 1` rows are fetched so
--     `has_more` is known without a second query, and the extra row is dropped.
--     Nothing here relies on PostgREST's default row cap.
--
--   • AN EMPTY PAGE STILL MOVES THE CURSOR. With no events left, `next_cursor`
--     is the watermark, so a caller that stores it does not re-ask forever.
--
-- Tombstones are ordinary events: a delete writes a change row whose snapshot
-- carries `deleted_at`, so other devices learn about it.

CREATE OR REPLACE FUNCTION public.read_ledger_changes_v1(
  p_after_cursor   bigint  DEFAULT 0,
  p_through_cursor bigint  DEFAULT NULL,
  p_limit          integer DEFAULT 250)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid      uuid := public.ledger_current_uid();
  v_through  bigint;
  v_limit    integer;
  v_changes  jsonb;
  v_next     bigint;
  v_has_more boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  v_limit := coalesce(p_limit, 250);
  IF v_limit < 1 OR v_limit > 250 THEN
    RAISE EXCEPTION 'invalid_limit' USING ERRCODE = '22023';
  END IF;
  IF p_after_cursor IS NULL OR p_after_cursor < 0 THEN
    RAISE EXCEPTION 'invalid_after_cursor' USING ERRCODE = '22023';
  END IF;

  -- The owner's committed cursor. A caller with no state row has nothing yet.
  SELECT coalesce(s.cursor, 0) INTO v_through
    FROM public.ledger_sync_state s
   WHERE s.user_id = v_uid;
  IF NOT FOUND THEN
    v_through := 0;
  END IF;

  -- A caller continuing a run supplies the watermark it started with. It may
  -- never exceed what is committed now.
  IF p_through_cursor IS NOT NULL THEN
    IF p_through_cursor < 0 OR p_through_cursor > v_through THEN
      RAISE EXCEPTION 'invalid_through_cursor' USING ERRCODE = '22023';
    END IF;
    v_through := p_through_cursor;
  END IF;

  IF p_after_cursor > v_through THEN
    RAISE EXCEPTION 'invalid_after_cursor' USING ERRCODE = '22023';
  END IF;

  WITH page AS (
    SELECT c.cursor, c.operation_id, c.entity_kind, c.entity_local_id, c.snapshot,
           row_number() OVER (ORDER BY c.cursor) AS rn
      FROM public.ledger_change_log c
     WHERE c.user_id = v_uid
       AND c.cursor > p_after_cursor
       AND c.cursor <= v_through
     ORDER BY c.cursor
     LIMIT v_limit + 1
  )
  SELECT
    coalesce(jsonb_agg(jsonb_build_object(
        'cursor',      cursor::text,
        'operation_id', to_jsonb(operation_id),
        'entity_kind',  entity_kind,
        'entity_id',    entity_local_id,
        'snapshot',     snapshot)
      ORDER BY cursor) FILTER (WHERE rn <= v_limit), '[]'::jsonb),
    max(cursor) FILTER (WHERE rn <= v_limit),
    count(*) > v_limit
  INTO v_changes, v_next, v_has_more
  FROM page;

  -- No events left in the window: the caller is caught up to the watermark.
  IF v_next IS NULL THEN
    v_next := v_through;
  END IF;

  RETURN jsonb_build_object(
    'through_cursor', v_through::text,
    'next_cursor',    v_next::text,
    'has_more',       coalesce(v_has_more, false),
    'changes',        v_changes);
END;
$fn$;

-- Same ownership rule as the write RPC: the function runs as the NOBYPASSRLS
-- executor, so its owner-scoped policies still apply. Installation rights are
-- granted for the transfer and withdrawn immediately.
GRANT sumit_ledger_executor TO postgres WITH INHERIT TRUE, SET TRUE;
GRANT CREATE ON SCHEMA public TO sumit_ledger_executor;

ALTER FUNCTION public.read_ledger_changes_v1(bigint, bigint, integer)
  OWNER TO sumit_ledger_executor;

REVOKE CREATE ON SCHEMA public FROM sumit_ledger_executor;

REVOKE EXECUTE ON FUNCTION public.read_ledger_changes_v1(bigint, bigint, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.read_ledger_changes_v1(bigint, bigint, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.read_ledger_changes_v1(bigint, bigint, integer) TO authenticated;
