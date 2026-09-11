-- SumIt — Task 06 part 2: the write RPC, reworked against the real schema.
-- Requires 20260910_04_ledger_mutation_rpc.sql (identity helper, snapshot
-- builders, relaxed NOT NULL columns) to be applied first.
--
-- See the header of file 04 for the three corrections the production discovery
-- forced. The one that shapes this file most is identity: `local_id` is text
-- holding mixed-case UUIDs (32 of 70 production rows are uppercase), while
-- PostgreSQL renders `uuid::text` lowercase. Every lookup below therefore goes
-- through `ledger_same_identity`, and two rows differing only by case are
-- refused as ambiguous rather than resolved by guessing.

CREATE OR REPLACE FUNCTION public.apply_ledger_mutation_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid          uuid := public.ledger_current_uid();
  v_owner        text;
  v_op           uuid;
  v_kind         text;
  v_entity       uuid;
  v_entity_text  text;
  v_action       text;
  v_expected     bigint;
  v_record       jsonb;
  v_receipt      record;
  v_state        record;
  v_cursor       bigint;
  v_tx           public.transactions%ROWTYPE;
  v_wallet       public.wallets%ROWTYPE;
  v_cat          public.categories%ROWTYPE;
  v_matches      int;
  v_exists       boolean;
  v_current_rev  bigint;
  v_deleted      timestamptz;
  v_snapshot     jsonb;
  v_response     jsonb;
  v_amount       numeric;
  v_base         numeric;
  v_rate         numeric;
  v_wallet_amt   numeric;
  v_dest_amt     numeric;
  v_wallet_id    uuid;
  v_dest_id      uuid;
  v_quote        jsonb;
  v_val_state    text;
  v_src_cur      text;
  v_dst_cur      text;
  v_now          timestamptz := now();
BEGIN
  -- 1. Envelope validation, before any lock or side effect
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  v_owner := v_uid::text;

  IF jsonb_typeof(p_request) <> 'object' THEN
    RAISE EXCEPTION 'request_not_object' USING ERRCODE = '22023';
  END IF;
  IF octet_length(p_request::text) > 65536 THEN
    RAISE EXCEPTION 'request_too_large' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_request) k
     WHERE k NOT IN ('protocol_version','operation_id','entity_kind','entity_id',
                     'action','expected_revision','record')
  ) THEN
    RAISE EXCEPTION 'unknown_request_field' USING ERRCODE = '22023';
  END IF;
  IF coalesce((p_request->>'protocol_version')::int, -1) <> 1 THEN
    RAISE EXCEPTION 'unsupported_protocol_version' USING ERRCODE = '22023';
  END IF;

  v_op          := (p_request->>'operation_id')::uuid;
  v_kind        := p_request->>'entity_kind';
  v_entity      := (p_request->>'entity_id')::uuid;
  v_entity_text := lower(v_entity::text);
  v_action      := p_request->>'action';

  IF v_kind NOT IN ('transaction','wallet','category') THEN
    RAISE EXCEPTION 'unknown_entity_kind' USING ERRCODE = '22023';
  END IF;
  IF v_action NOT IN ('put','delete') THEN
    RAISE EXCEPTION 'unknown_action' USING ERRCODE = '22023';
  END IF;
  IF (p_request->>'expected_revision') !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'malformed_expected_revision' USING ERRCODE = '22023';
  END IF;
  v_expected := (p_request->>'expected_revision')::bigint;

  v_record := p_request->'record';
  IF v_action = 'put' THEN
    IF v_record IS NULL OR jsonb_typeof(v_record) <> 'object' THEN
      RAISE EXCEPTION 'missing_record' USING ERRCODE = '22023';
    END IF;
  ELSIF v_record IS NOT NULL AND jsonb_typeof(v_record) <> 'null' THEN
    RAISE EXCEPTION 'delete_takes_no_record' USING ERRCODE = '22023';
  END IF;

  -- 2. Owner state row, locked. Cursor allocation serializes here.
  INSERT INTO public.ledger_sync_state(user_id) VALUES (v_uid)
    ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_state FROM public.ledger_sync_state
    WHERE user_id = v_uid FOR UPDATE;

  IF v_state.writes_paused THEN
    RAISE EXCEPTION 'writes_paused' USING ERRCODE = '55006';
  END IF;

  -- 3. Replay receipt, read after the lock so a concurrent replay serializes
  SELECT * INTO v_receipt FROM public.ledger_mutation_receipts
    WHERE user_id = v_uid AND operation_id = v_op;
  IF FOUND THEN
    IF v_receipt.request = p_request THEN
      RETURN v_receipt.response;
    END IF;
    RAISE EXCEPTION 'operation_payload_mismatch' USING ERRCODE = '22023';
  END IF;

  -- 4. Target entity, matched case-insensitively; an ambiguous match is refused
  IF v_kind = 'transaction' THEN
    SELECT count(*) INTO v_matches FROM public.transactions
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity);
    IF v_matches > 1 THEN
      RAISE EXCEPTION 'ambiguous_local_id' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_tx FROM public.transactions
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
      FOR UPDATE;
    v_exists := FOUND;
    v_current_rev := coalesce(v_tx.ledger_revision, 0);
    v_deleted := v_tx.deleted_at;
  ELSIF v_kind = 'wallet' THEN
    SELECT count(*) INTO v_matches FROM public.wallets
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity);
    IF v_matches > 1 THEN
      RAISE EXCEPTION 'ambiguous_local_id' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_wallet FROM public.wallets
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
      FOR UPDATE;
    v_exists := FOUND;
    v_current_rev := coalesce(v_wallet.ledger_revision, 0);
    v_deleted := v_wallet.deleted_at;
  ELSE
    SELECT count(*) INTO v_matches FROM public.categories
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity);
    IF v_matches > 1 THEN
      RAISE EXCEPTION 'ambiguous_local_id' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_cat FROM public.categories
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
      FOR UPDATE;
    v_exists := FOUND;
    v_current_rev := coalesce(v_cat.ledger_revision, 0);
    v_deleted := v_cat.deleted_at;
  END IF;

  -- 5. Conflicts return a full remote candidate and advance nothing
  IF v_exists AND v_deleted IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status','conflict','operation_id',v_op,'entity_id',v_entity,
      'expected_revision', v_expected::text, 'actual_revision', v_current_rev::text,
      'reason','deleted',
      'server_snapshot', CASE v_kind
        WHEN 'transaction' THEN public.ledger_transaction_snapshot(v_tx)
        WHEN 'wallet' THEN public.ledger_wallet_snapshot(v_wallet)
        ELSE public.ledger_category_snapshot(v_cat) END);
  END IF;

  IF NOT v_exists AND (v_action = 'delete' OR v_expected <> 0) THEN
    RETURN jsonb_build_object(
      'status','conflict','operation_id',v_op,'entity_id',v_entity,
      'expected_revision', v_expected::text, 'actual_revision','0',
      'reason','not_found', 'server_snapshot', NULL);
  END IF;

  -- A create (expected_revision = 0) over an existing identity is answered
  -- `already_exists`, not `revision_mismatch`: both are true, but only the
  -- former tells the client to stop rather than refetch and retry. Found by
  -- RPC-04 during the 2026-09-10 verification run.
  IF v_exists AND v_current_rev <> v_expected AND NOT (v_action = 'put' AND v_expected = 0) THEN
    RETURN jsonb_build_object(
      'status','conflict','operation_id',v_op,'entity_id',v_entity,
      'expected_revision', v_expected::text, 'actual_revision', v_current_rev::text,
      'reason','revision_mismatch',
      'server_snapshot', CASE v_kind
        WHEN 'transaction' THEN public.ledger_transaction_snapshot(v_tx)
        WHEN 'wallet' THEN public.ledger_wallet_snapshot(v_wallet)
        ELSE public.ledger_category_snapshot(v_cat) END);
  END IF;

  IF v_exists AND v_action = 'put' AND v_expected = 0 THEN
    RETURN jsonb_build_object(
      'status','conflict','operation_id',v_op,'entity_id',v_entity,
      'expected_revision','0','actual_revision', v_current_rev::text,
      'reason','already_exists',
      'server_snapshot', CASE v_kind
        WHEN 'transaction' THEN public.ledger_transaction_snapshot(v_tx)
        WHEN 'wallet' THEN public.ledger_wallet_snapshot(v_wallet)
        ELSE public.ledger_category_snapshot(v_cat) END);
  END IF;

  -- 6. Record validation, all of it before any write
  IF v_action = 'put' AND v_kind = 'transaction' THEN
    IF (v_record->>'type') NOT IN ('expense','income','transfer') THEN
      RAISE EXCEPTION 'invalid_type' USING ERRCODE = '22023';
    END IF;
    IF (v_record->>'source') NOT IN ('text','photo','manual') THEN
      RAISE EXCEPTION 'invalid_source' USING ERRCODE = '22023';
    END IF;
    IF coalesce(length(v_record->>'merchant'),0) > 256
       OR coalesce(length(v_record->>'note'),0) > 2000
       OR coalesce(length(v_record->>'raw_input'),0) > 10000
       OR coalesce(length(v_record->>'category_name'),0) > 128 THEN
      RAISE EXCEPTION 'field_too_long' USING ERRCODE = '22023';
    END IF;

    v_amount := public.ledger_parse_decimal(v_record->>'original_amount','original_amount');
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'amount_must_be_positive' USING ERRCODE = '22023';
    END IF;
    v_rate       := public.ledger_parse_decimal(v_record->>'usd_per_unit','usd_per_unit');
    v_base       := public.ledger_parse_decimal(v_record->>'base_amount','base_amount');
    v_wallet_amt := public.ledger_parse_decimal(v_record->>'wallet_amount','wallet_amount');
    v_dest_amt   := public.ledger_parse_decimal(v_record->>'destination_amount','destination_amount');
    v_wallet_id  := nullif(v_record->>'wallet_id','')::uuid;
    v_dest_id    := nullif(v_record->>'destination_wallet_id','')::uuid;
    v_val_state  := v_record->>'valuation_state';
    v_quote      := CASE WHEN jsonb_typeof(v_record->'quote') = 'object'
                         THEN v_record->'quote' ELSE NULL END;

    IF v_val_state NOT IN ('unvalued','valued','legacy_unverified') THEN
      RAISE EXCEPTION 'invalid_valuation_state' USING ERRCODE = '22023';
    END IF;
    IF (v_record->>'confidence') IS NOT NULL
       AND public.ledger_parse_decimal(v_record->>'confidence','confidence') NOT BETWEEN 0 AND 1 THEN
      RAISE EXCEPTION 'confidence_out_of_range' USING ERRCODE = '22023';
    END IF;

    IF v_val_state = 'unvalued' THEN
      IF v_base IS NOT NULL OR v_rate IS NOT NULL OR v_quote IS NOT NULL THEN
        RAISE EXCEPTION 'unvalued_must_have_no_valuation' USING ERRCODE = '22023';
      END IF;
    ELSIF v_val_state = 'valued' THEN
      IF v_base IS NULL OR v_rate IS NULL OR v_quote IS NULL THEN
        RAISE EXCEPTION 'valued_requires_base_rate_quote' USING ERRCODE = '22023';
      END IF;
      IF v_rate <= 0 THEN
        RAISE EXCEPTION 'rate_must_be_positive' USING ERRCODE = '22023';
      END IF;
      IF (v_quote->>'currency') IS DISTINCT FROM (v_record->>'original_currency') THEN
        RAISE EXCEPTION 'quote_currency_mismatch' USING ERRCODE = '22023';
      END IF;
      IF public.ledger_parse_decimal(v_quote->>'usd_per_unit','quote.usd_per_unit') <> v_rate THEN
        RAISE EXCEPTION 'quote_rate_mismatch' USING ERRCODE = '22023';
      END IF;
      -- The booked base is the exact product, half-even to scale 18: the same
      -- rule the client applies. A mismatch is rejected rather than corrected.
      IF v_base <> public.ledger_round_half_even(v_amount * v_rate, 18) THEN
        RAISE EXCEPTION 'base_amount_mismatch' USING ERRCODE = '22023';
      END IF;
      IF v_base <= 0 THEN
        RAISE EXCEPTION 'base_amount_rounds_to_zero' USING ERRCODE = '22023';
      END IF;

      IF (v_quote->>'valuation_kind') = 'identity' THEN
        IF (v_quote->>'currency') <> 'USD' OR v_rate <> 1 OR (v_quote->>'quote_id') IS NOT NULL THEN
          RAISE EXCEPTION 'invalid_identity_quote' USING ERRCODE = '22023';
        END IF;
      ELSIF (v_quote->>'valuation_kind') = 'manual' THEN
        IF (v_quote->>'quote_id') IS NOT NULL THEN
          RAISE EXCEPTION 'manual_quote_has_no_id' USING ERRCODE = '22023';
        END IF;
      ELSIF (v_quote->>'valuation_kind') IN ('current_reference','historical_reference') THEN
        -- A client's claim of provider provenance is never taken as proof.
        IF NOT EXISTS (
          SELECT 1 FROM public.rate_quotes q
           WHERE q.id = (v_quote->>'quote_id')::uuid
             AND q.currency = (v_quote->>'currency')
             AND q.usd_per_unit = v_rate
             AND q.valuation_kind = (v_quote->>'valuation_kind')
        ) THEN
          RAISE EXCEPTION 'unverified_provider_quote' USING ERRCODE = '22023';
        END IF;
      ELSE
        RAISE EXCEPTION 'invalid_valuation_kind' USING ERRCODE = '22023';
      END IF;
    END IF;

    IF (v_record->>'type') = 'transfer' THEN
      IF v_wallet_id IS NULL OR v_dest_id IS NULL THEN
        RAISE EXCEPTION 'transfer_requires_two_wallets' USING ERRCODE = '22023';
      END IF;
      IF v_wallet_id = v_dest_id THEN
        RAISE EXCEPTION 'transfer_to_same_wallet' USING ERRCODE = '22023';
      END IF;
      IF v_wallet_amt IS NULL OR v_dest_amt IS NULL OR v_wallet_amt <= 0 OR v_dest_amt <= 0 THEN
        RAISE EXCEPTION 'transfer_requires_two_positive_amounts' USING ERRCODE = '22023';
      END IF;
      SELECT currency INTO v_src_cur FROM public.wallets
        WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_wallet_id)
          AND deleted_at IS NULL;
      IF NOT FOUND THEN RAISE EXCEPTION 'unknown_source_wallet' USING ERRCODE = '23503'; END IF;
      SELECT currency INTO v_dst_cur FROM public.wallets
        WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_dest_id)
          AND deleted_at IS NULL;
      IF NOT FOUND THEN RAISE EXCEPTION 'unknown_destination_wallet' USING ERRCODE = '23503'; END IF;
      IF v_src_cur IS DISTINCT FROM (v_record->>'original_currency') THEN
        RAISE EXCEPTION 'transfer_currency_must_match_source_wallet' USING ERRCODE = '22023';
      END IF;
      IF v_wallet_amt <> v_amount THEN
        RAISE EXCEPTION 'transfer_source_amount_mismatch' USING ERRCODE = '22023';
      END IF;
      -- Equal currencies must move equal quantities; a difference would be a
      -- fee or spread hidden inside the transfer.
      IF v_src_cur = v_dst_cur AND v_wallet_amt <> v_dest_amt THEN
        RAISE EXCEPTION 'equal_currency_legs_must_match' USING ERRCODE = '22023';
      END IF;
    ELSE
      IF v_dest_id IS NOT NULL OR v_dest_amt IS NOT NULL THEN
        RAISE EXCEPTION 'non_transfer_has_no_destination' USING ERRCODE = '22023';
      END IF;
      IF v_wallet_id IS NULL THEN
        IF v_wallet_amt IS NOT NULL THEN
          RAISE EXCEPTION 'wallet_amount_without_wallet' USING ERRCODE = '22023';
        END IF;
      ELSE
        IF v_wallet_amt IS NULL OR v_wallet_amt <= 0 THEN
          RAISE EXCEPTION 'wallet_effect_must_be_positive' USING ERRCODE = '22023';
        END IF;
        SELECT currency INTO v_src_cur FROM public.wallets
          WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_wallet_id)
            AND deleted_at IS NULL;
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown_wallet' USING ERRCODE = '23503'; END IF;
        IF v_src_cur = (v_record->>'original_currency') AND v_wallet_amt <> v_amount THEN
          RAISE EXCEPTION 'same_currency_effect_must_equal_amount' USING ERRCODE = '22023';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_action = 'put' AND v_kind = 'wallet' THEN
    IF coalesce(length(v_record->>'name'),0) > 128 OR coalesce(length(v_record->>'icon'),0) > 128 THEN
      RAISE EXCEPTION 'field_too_long' USING ERRCODE = '22023';
    END IF;
    IF coalesce(v_record->>'name','') = '' THEN
      RAISE EXCEPTION 'wallet_name_required' USING ERRCODE = '22023';
    END IF;
    IF public.ledger_parse_decimal(v_record->>'opening_balance','opening_balance') IS NULL THEN
      RAISE EXCEPTION 'opening_balance_required' USING ERRCODE = '22023';
    END IF;
    IF v_exists AND v_wallet.currency IS DISTINCT FROM (v_record->>'currency')
       AND EXISTS (SELECT 1 FROM public.transactions t
                    WHERE t.user_id = v_owner
                      AND (t.wallet_local_id = v_entity OR t.destination_wallet_local_id = v_entity)) THEN
      RAISE EXCEPTION 'wallet_currency_is_locked' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_action = 'put' AND v_kind = 'category' THEN
    IF coalesce(length(v_record->>'name'),0) > 128 OR coalesce(length(v_record->>'icon'),0) > 128 THEN
      RAISE EXCEPTION 'field_too_long' USING ERRCODE = '22023';
    END IF;
    IF (v_record->>'color_hex') !~ '^[0-9A-Fa-f]{6}$' THEN
      RAISE EXCEPTION 'invalid_color_hex' USING ERRCODE = '22023';
    END IF;
    IF coalesce((v_record->>'sort_order')::int, -1) < 0 THEN
      RAISE EXCEPTION 'invalid_sort_order' USING ERRCODE = '22023';
    END IF;
    IF coalesce((v_record->>'is_default')::boolean, false) THEN
      RAISE EXCEPTION 'cannot_claim_default' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 7. Allocate the cursor under the held lock; the row's revision equals it
  UPDATE public.ledger_sync_state SET cursor = cursor + 1
   WHERE user_id = v_uid RETURNING cursor INTO v_cursor;

  -- 8. Apply exactly one entity change. New rows store local_id lowercase;
  --    existing rows keep the case they already have, so no identity is
  --    rewritten behind the owner's back.
  IF v_kind = 'transaction' THEN
    IF v_action = 'delete' THEN
      UPDATE public.transactions
         SET deleted_at = v_now, ledger_revision = v_cursor, ledger_version = 1
       WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
       RETURNING * INTO v_tx;
    ELSIF v_exists THEN
      UPDATE public.transactions SET
        type = v_record->>'type', amount_exact = v_amount,
        original_amount = v_amount::double precision,
        original_currency = v_record->>'original_currency',
        base_amount_exact = v_base, amount_in_base = v_base::double precision,
        rate_exact = v_rate, rate_at_time = v_rate::double precision,
        wallet_local_id = v_wallet_id, wallet_amount_exact = v_wallet_amt,
        destination_wallet_local_id = v_dest_id, destination_amount_exact = v_dest_amt,
        category_name = coalesce(v_record->>'category_name',''),
        merchant = coalesce(v_record->>'merchant',''),
        note = coalesce(v_record->>'note',''),
        occurred_at = (v_record->>'occurred_at')::timestamptz,
        source = v_record->>'source',
        confidence = coalesce((v_record->>'confidence')::double precision, 1),
        raw_input = coalesce(v_record->>'raw_input',''),
        quote_metadata = v_quote, valuation_state = v_val_state,
        ledger_revision = v_cursor, ledger_version = 1
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
      RETURNING * INTO v_tx;
    ELSE
      INSERT INTO public.transactions(
        user_id, local_id, type, amount_exact, original_amount, original_currency,
        base_amount_exact, amount_in_base, rate_exact, rate_at_time,
        wallet_local_id, wallet_amount_exact, destination_wallet_local_id, destination_amount_exact,
        category_name, merchant, note, occurred_at, source, confidence, raw_input,
        quote_metadata, valuation_state, ledger_revision, ledger_version, created_at)
      VALUES (
        v_owner, v_entity_text, v_record->>'type', v_amount, v_amount::double precision,
        v_record->>'original_currency', v_base, v_base::double precision, v_rate,
        v_rate::double precision, v_wallet_id, v_wallet_amt, v_dest_id, v_dest_amt,
        coalesce(v_record->>'category_name',''), coalesce(v_record->>'merchant',''),
        coalesce(v_record->>'note',''), (v_record->>'occurred_at')::timestamptz,
        v_record->>'source', coalesce((v_record->>'confidence')::double precision, 1),
        coalesce(v_record->>'raw_input',''), v_quote, v_val_state, v_cursor, 1, v_now)
      RETURNING * INTO v_tx;
    END IF;
    v_snapshot := public.ledger_transaction_snapshot(v_tx);

  ELSIF v_kind = 'wallet' THEN
    IF v_action = 'delete' THEN
      UPDATE public.wallets
         SET deleted_at = v_now, ledger_revision = v_cursor, ledger_version = 1
       WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
       RETURNING * INTO v_wallet;
    ELSIF v_exists THEN
      UPDATE public.wallets SET
        name = v_record->>'name', type = v_record->>'type',
        currency = v_record->>'currency',
        opening_balance_exact = (v_record->>'opening_balance')::numeric,
        icon = coalesce(v_record->>'icon',''),
        ledger_revision = v_cursor, ledger_version = 1
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
      RETURNING * INTO v_wallet;
    ELSE
      INSERT INTO public.wallets(user_id, local_id, name, type, currency, balance,
                                 opening_balance_exact, icon, ledger_revision, ledger_version, created_at)
      VALUES (v_owner, v_entity_text, v_record->>'name', v_record->>'type',
              v_record->>'currency', 0, (v_record->>'opening_balance')::numeric,
              coalesce(v_record->>'icon',''), v_cursor, 1, v_now)
      RETURNING * INTO v_wallet;
    END IF;
    v_snapshot := public.ledger_wallet_snapshot(v_wallet);

  ELSE
    IF v_action = 'delete' THEN
      UPDATE public.categories
         SET deleted_at = v_now, ledger_revision = v_cursor, ledger_version = 1
       WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
       RETURNING * INTO v_cat;
    ELSIF v_exists THEN
      UPDATE public.categories SET
        name = v_record->>'name', icon = coalesce(v_record->>'icon',''),
        color_hex = v_record->>'color_hex', type = v_record->>'type',
        sort_order = (v_record->>'sort_order')::int,
        ledger_revision = v_cursor, ledger_version = 1
      WHERE user_id = v_owner AND public.ledger_same_identity(local_id, v_entity)
      RETURNING * INTO v_cat;
    ELSE
      -- No created_at column exists on this table in production.
      INSERT INTO public.categories(user_id, local_id, name, icon, color_hex, type,
                                    sort_order, is_default, ledger_revision, ledger_version)
      VALUES (v_owner, v_entity_text, v_record->>'name', coalesce(v_record->>'icon',''),
              v_record->>'color_hex', v_record->>'type', (v_record->>'sort_order')::int,
              false, v_cursor, 1)
      RETURNING * INTO v_cat;
    END IF;
    v_snapshot := public.ledger_category_snapshot(v_cat);
  END IF;

  -- 9. Feed event, response and receipt, all inside this same transaction
  INSERT INTO public.ledger_change_log(user_id, cursor, operation_id, entity_kind,
                                       entity_local_id, snapshot)
  VALUES (v_uid, v_cursor, v_op, v_kind, v_entity, v_snapshot);

  v_response := jsonb_build_object(
    'status','accepted','operation_id',v_op,'entity_id',v_entity,
    'revision', v_cursor::text, 'cursor', v_cursor::text, 'snapshot', v_snapshot);

  INSERT INTO public.ledger_mutation_receipts(user_id, operation_id, request, response, accepted_cursor)
  VALUES (v_uid, v_op, p_request, v_response, v_cursor);

  RETURN v_response;
END;
$fn$;

-- Ownership matters here. SECURITY DEFINER executes as the function's owner,
-- and Supabase's `postgres` role carries BYPASSRLS — leaving the function owned
-- by the migration role would quietly defeat every owner check above. Taking
-- ownership requires role membership first; that membership is admin-side only
-- and is never given to `authenticated` or `anon`.
DO $ownership$
BEGIN
  IF NOT pg_has_role(current_user, 'sumit_ledger_executor', 'MEMBER') THEN
    EXECUTE format('GRANT sumit_ledger_executor TO %I', current_user);
  END IF;
END
$ownership$;

-- PostgreSQL requires an object's new owner to hold CREATE on its schema, and
-- `postgres` needs the SET privilege on the role to hand ownership over. Both
-- are installation-time rights and both are withdrawn below.
GRANT sumit_ledger_executor TO postgres WITH INHERIT TRUE, SET TRUE;
GRANT CREATE ON SCHEMA public TO sumit_ledger_executor;

ALTER FUNCTION public.apply_ledger_mutation_v1(jsonb) OWNER TO sumit_ledger_executor;

REVOKE CREATE ON SCHEMA public FROM sumit_ledger_executor;

-- Only signed-in callers. The discovery found several existing SECURITY DEFINER
-- functions in this database reachable by `anon` over /rest/v1/rpc/; this one
-- must not join them.
REVOKE EXECUTE ON FUNCTION public.apply_ledger_mutation_v1(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_ledger_mutation_v1(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.apply_ledger_mutation_v1(jsonb) TO authenticated;
