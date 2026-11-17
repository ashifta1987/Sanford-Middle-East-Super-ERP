-- Sana Live M2 (52_sana_live.sql). LOCAL STACK or a Supabase BRANCH with ZZ99 + test users — never live. One transaction, rolled back.
-- qa.admin 1 (all modules), qa.sales 2, qa.finance 4.
BEGIN;
CREATE TEMP TABLE sr_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON sr_result TO authenticated;
CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO sr_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;

DO $$
DECLARE r jsonb; sid uuid; sid2 uuid; ev0 bigint; n integer; exp timestamptz;
BEGIN
  SELECT count(*) INTO ev0 FROM erp.sana_event_log;
  -- caps
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_caps(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'live_minutes_daily')::integer = 30 AND (r ->> 'tts_daily_cap')::integer = 10, 'caps: defaults 30 Live minutes and 10 Sana voice answers a day', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_caps_save(''ZZ99'', 60, 20)');
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'caps: sales cannot change them', r::text);
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_caps_save(''ZZ99'', 45, 12)');
  PERFORM pg_temp.check((r ->> 'live_minutes_daily')::integer = 45 AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana_caps_save' AND company_code = 'ZZ99'), 'caps: admin changes them, audited', r::text);

  -- start / check / tools / other user
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_start(''ZZ99'', ''gemini-3.1-flash-live-preview'', ''ml'', ARRAY[''get_stock'',''find_records''], %L)', now() + interval '10 minutes'));
  sid := (r ->> 'live_session_id')::uuid;
  PERFORM pg_temp.check(sid IS NOT NULL AND (r ->> 'seconds_left')::integer = 45 * 60 AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana.live.start' AND object_ref = sid::text),
                        'start: a session row and an audit row; minutes left = the cap', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_start(''ZZ99'', ''m'', ''en'', ''{}'', %L)', now() + interval '20 minutes'));
  PERFORM pg_temp.check(r ->> 'error' = 'P0001', 'start: a token may not last more than 10 minutes', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_check(%L, ''get_stock'')', sid));
  PERFORM pg_temp.check(r ->> 'company' = 'ZZ99' AND (SELECT tool_calls FROM erp.sana_live_session WHERE id = sid) = 1, 'check: a tool in the minted list passes and is counted', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_check(%L, ''payables'')', sid));
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'check: a tool that was not minted for the role is refused', r::text);
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_live_check(%L, ''get_stock'')', sid));
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'check: another user cannot use my session', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_check(%L, NULL, true)', sid));
  PERFORM pg_temp.check((SELECT turns FROM erp.sana_live_session WHERE id = sid) = 1, 'check: a logged turn is counted', r::text);

  -- typed-turn logging with via live
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_log(NULL, ''ZZ99'', ''ml'', ''SMP-1010 സ്റ്റോക്ക്?'', ''861 എണ്ണം ലഭ്യമാണ്.'', ''[{"tool":"get_stock"}]'', ''[]'', false, ''ai'', ''live'', ''{"type":"page","label":"live"}'', false, ''gemini'', ''gemini-3.1-flash-live-preview'', NULL)');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.sana_message m WHERE m.conversation_id = (r ->> 'conversation_id')::uuid AND m.via = 'live') >= 1
                    AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana.ask' AND object_ref = r ->> 'conversation_id' AND detail ->> 'via' = 'live'),
                        'log_turn: a Live turn is stored like a typed turn with via live, with its audit row', r::text);

  -- expiry, end
  UPDATE erp.sana_live_session SET started_at = now() - interval '12 minutes', expires_at = now() - interval '2 minutes' WHERE id = sid;
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_check(%L, ''get_stock'')', sid));
  PERFORM pg_temp.check(r ->> 'reason' = 'expired' AND r ->> 'refused' ILIKE '%expired%' AND r ->> 'company' IS NULL, 'expiry: an expired session is refused (no company, no tool)', r::text);
  PERFORM pg_temp.check((SELECT ended_reason = 'expired' AND seconds = 600 FROM erp.sana_live_session WHERE id = sid),
                        'expiry: the session is closed as expired, seconds stop at the token expiry (10 min), not at now');
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_end(%L, ''user'')', sid));
  PERFORM pg_temp.check((r ->> 'already_ended')::boolean AND (r ->> 'seconds')::integer = 600, 'end: after expiry a second end changes nothing', r::text);

  -- minutes cap
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_live_usage_today(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'seconds_used')::integer = 600 AND (r ->> 'seconds_left')::integer = 45 * 60 - 600, 'usage: today''s seconds and what is left', r::text);
  PERFORM pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_caps_save(''ZZ99'', 12, NULL)');
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_start(''ZZ99'', ''gemini-3.1-flash-live-preview'', ''en'', ''{}'', %L)', now() + interval '10 minutes'));
  sid2 := (r ->> 'live_session_id')::uuid;
  SELECT expires_at INTO exp FROM erp.sana_live_session WHERE id = sid2;
  PERFORM pg_temp.check(sid2 IS NOT NULL AND exp <= now() + interval '2 minutes 5 seconds', 'cap: with 2 minutes left the session (and token) lasts 2 minutes', r::text);
  PERFORM pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_caps_save(''ZZ99'', 0, NULL)');
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_live_start(''ZZ99'', ''gemini-3.1-flash-live-preview'', ''en'', ''{}'', %L)', now() + interval '10 minutes'));
  PERFORM pg_temp.check(r ->> 'error' = 'P0001' AND r ->> 'message' ILIKE '%live minutes limit%', 'cap: at the daily minutes cap a new session is refused', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(id), ''[]'') FROM erp.sana_live_session');
  PERFORM pg_temp.check(jsonb_array_length(r) = 0, 'RLS: finance does not see the sales user''s sessions', r::text);

  -- item codes as heard
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_stock(''smp 1010'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'items' -> 0 ->> 'code' = 'SMP-1010', 'codes: "smp 1010" finds SMP-1010 (spaces, dashes, case ignored)', left(r::text, 120));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_stock(''SMP/10-10'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'items' -> 0 ->> 'code' = 'SMP-1010', 'codes: "SMP/10-10" finds SMP-1010', left(r::text, 120));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''smp1010'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'items' -> 0 ->> 'code' = 'SMP-1010', 'codes: find_records takes the normalised code too (Ask and Live)', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_stock(''SMP-1019'', ''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r -> 'items') = 0 AND jsonb_array_length(coalesce(r -> 'did_you_mean', '[]')) >= 1, 'codes: a near miss is not found but offers did_you_mean', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT coalesce(jsonb_agg(k), ''[]'') FROM erp._sana_item_keys(''{AE05}'', ''SMP1010'') k');
  PERFORM pg_temp.check(r = '[]'::jsonb, 'codes: the helper gives nothing from companies the user cannot see', r::text);

  SELECT count(*) INTO n FROM erp.sana_event_log;
  PERFORM pg_temp.check(n = ev0, 'append-only event log unchanged by Live', format('%s → %s', ev0, n));
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM sr_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM sr_result;
ROLLBACK;
