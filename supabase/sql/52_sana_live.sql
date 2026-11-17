-- 52 · Sana Live, M2 (S5): server-side Live sessions, a per-user daily minutes cap, the TTS cap in settings, via 'live'.
-- Rules: a Live session row is written by sana_live_start when sana-live-token mints a token (the caller's own JWT, SECURITY
-- DEFINER write, own rows only); sana-live-tool checks every tool call and turn against it (own session, not ended, token not
-- expired, tool in the list the token was minted with); sana_live_end closes it (user, silence, cap, hidden tab, expiry, error).
-- If the browser dies the row still has started_at; an unended session counts its minutes up to the token expiry.
-- Caps (per company, erp.sana_settings): live_minutes_daily (default 30), tts_daily_cap (default 10, was a constant in sana-voice).
-- Transcribed Live turns are logged like typed turns with via = 'live' (sana_log; sana_message.via allows 'live').
-- Safe to run twice. Branch first; live only on Ashif's go.

-- ============ 1. Settings: the two caps ============
ALTER TABLE erp.sana_settings ADD COLUMN IF NOT EXISTS live_minutes_daily integer NOT NULL DEFAULT 30 CHECK (live_minutes_daily BETWEEN 0 AND 600);
ALTER TABLE erp.sana_settings ADD COLUMN IF NOT EXISTS tts_daily_cap integer NOT NULL DEFAULT 10 CHECK (tts_daily_cap BETWEEN 0 AND 1000);

-- The caps for a company the caller may see (defaults when the company has no settings row).
CREATE OR REPLACE FUNCTION erp.sana_caps(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('company', co, 'live_minutes_daily', coalesce(s.live_minutes_daily, 30), 'tts_daily_cap', coalesce(s.tts_daily_cap, 10))
    FROM (SELECT erp._sana_company(p_company) AS co) c LEFT JOIN erp.sana_settings s ON s.company_code = c.co
   WHERE erp.current_user_id() IS NOT NULL
$$;

-- Admin (full Administration) changes the caps; audited like sana_settings_save.
CREATE OR REPLACE FUNCTION erp.sana_caps_save(p_company varchar, p_live_minutes integer DEFAULT NULL, p_tts_cap integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._adm_guard(true); old erp.sana_settings; new_row erp.sana_settings;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF p_live_minutes IS NOT NULL AND p_live_minutes NOT BETWEEN 0 AND 600 THEN RAISE EXCEPTION 'Live minutes per day must be 0 to 600.' USING ERRCODE = 'P0001'; END IF;
  IF p_tts_cap IS NOT NULL AND p_tts_cap NOT BETWEEN 0 AND 1000 THEN RAISE EXCEPTION 'Sana voice answers per day must be 0 to 1000.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO old FROM erp.sana_settings WHERE company_code = p_company;
  INSERT INTO erp.sana_settings (company_code, live_minutes_daily, tts_daily_cap, updated_by, updated_at)
    VALUES (p_company, coalesce(p_live_minutes, 30), coalesce(p_tts_cap, 10), me.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET live_minutes_daily = coalesce(p_live_minutes, erp.sana_settings.live_minutes_daily),
    tts_daily_cap = coalesce(p_tts_cap, erp.sana_settings.tts_daily_cap), updated_by = me.user_id, updated_at = now()
  RETURNING * INTO new_row;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (me.user_id::text, p_company, 'sana_caps_save', 'sana_settings', p_company,
            jsonb_build_object('before', jsonb_build_object('live_minutes_daily', old.live_minutes_daily, 'tts_daily_cap', old.tts_daily_cap),
                               'after', jsonb_build_object('live_minutes_daily', new_row.live_minutes_daily, 'tts_daily_cap', new_row.tts_daily_cap)));
  RETURN jsonb_build_object('company', p_company, 'live_minutes_daily', new_row.live_minutes_daily, 'tts_daily_cap', new_row.tts_daily_cap);
END $$;

-- ============ 2. Live sessions ============
CREATE TABLE IF NOT EXISTS erp.sana_live_session (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    company_code    varchar(8) NOT NULL REFERENCES erp.company,
    model           text NOT NULL CHECK (length(model) <= 80),
    language        text CHECK (length(language) <= 8),
    tools           text[] NOT NULL DEFAULT '{}',
    started_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    ended_at        timestamptz,
    seconds         integer CHECK (seconds BETWEEN 0 AND 86400),
    turns           integer NOT NULL DEFAULT 0,
    tool_calls      integer NOT NULL DEFAULT 0,
    ended_reason    text CHECK (ended_reason IN ('user', 'silence', 'cap', 'hidden', 'expired', 'error', 'server'))
);
CREATE INDEX IF NOT EXISTS sana_live_session_user_day ON erp.sana_live_session (user_id, started_at DESC);
ALTER TABLE erp.sana_live_session ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sana_live_session FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sana_live_session TO authenticated;
DROP POLICY IF EXISTS sana_live_session_read ON erp.sana_live_session;
CREATE POLICY sana_live_session_read ON erp.sana_live_session FOR SELECT TO authenticated
  USING (user_id = erp.current_user_id() OR (erp.can_see(company_code) AND (SELECT erp.module_level('business')) IS NOT NULL));

-- Seconds a session counts: closed → its seconds; open → up to now, never past the token expiry.
CREATE OR REPLACE FUNCTION erp._sana_live_seconds(s erp.sana_live_session) RETURNS integer
LANGUAGE sql STABLE SET search_path = erp, pg_temp AS $$
  SELECT coalesce(s.seconds, greatest(0, extract(epoch FROM least(now(), s.expires_at) - s.started_at))::integer)
$$;

-- Minutes used today (Dubai day) by the caller, the cap and what is left.
CREATE OR REPLACE FUNCTION erp.sana_live_usage_today(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); cap integer; used integer;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  cap := (erp.sana_caps(p_company) ->> 'live_minutes_daily')::integer;
  SELECT coalesce(sum(erp._sana_live_seconds(s)), 0) INTO used FROM erp.sana_live_session s
   WHERE s.user_id = uid AND (s.started_at AT TIME ZONE 'Asia/Dubai')::date = erp._sana_today();
  RETURN jsonb_build_object('seconds_used', used, 'minutes_used', round(used / 60.0, 1), 'minutes_cap', cap, 'seconds_left', greatest(0, cap * 60 - used));
END $$;

-- sana-live-token: start a session (refused at the cap). Returns the session id and the seconds left (the token never lasts longer).
CREATE OR REPLACE FUNCTION erp.sana_live_start(p_company varchar, p_model text, p_language text, p_tools text[], p_expires_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); u jsonb; sid uuid;
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RAISE EXCEPTION 'You need a Southfield profile to use Sana.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501'; END IF;
  IF p_model !~ '^[A-Za-z0-9._:/-]{1,80}$' THEN RAISE EXCEPTION 'Bad model name.' USING ERRCODE = 'P0001'; END IF;
  IF p_expires_at IS NULL OR p_expires_at > now() + interval '10 minutes 30 seconds' OR p_expires_at <= now() THEN
    RAISE EXCEPTION 'A Live token lasts at most 10 minutes.' USING ERRCODE = 'P0001';
  END IF;
  u := erp.sana_live_usage_today(p_company);
  IF (u ->> 'seconds_left')::integer <= 0 THEN
    RAISE EXCEPTION 'live minutes limit: % of % minutes used today', u ->> 'minutes_used', u ->> 'minutes_cap' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.sana_live_session (user_id, company_code, model, language, tools, expires_at)
    VALUES (uid, p_company, p_model, left(p_language, 8), coalesce(p_tools, '{}'),
            least(p_expires_at, now() + make_interval(secs => (u ->> 'seconds_left')::integer)))
    RETURNING id INTO sid;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', p_company, 'sana.live.start', 'sana_live_session', sid::text, jsonb_build_object('user_id', uid, 'model', p_model, 'language', p_language, 'tools', to_jsonb(coalesce(p_tools, '{}'))));
  RETURN jsonb_build_object('live_session_id', sid, 'seconds_left', (u ->> 'seconds_left')::integer,
                            'expires_at', (SELECT expires_at FROM erp.sana_live_session WHERE id = sid));
END $$;

-- sana-live-tool: the caller's own open session, or an error (not mine / ended / expired). p_tool must be in the minted list.
-- p_turn / p_tool_call count the turn and the tool call.
CREATE OR REPLACE FUNCTION erp.sana_live_check(p_session uuid, p_tool text DEFAULT NULL, p_turn boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); s erp.sana_live_session;
BEGIN
  SELECT * INTO s FROM erp.sana_live_session WHERE id = p_session AND user_id = uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live session not found.' USING ERRCODE = '42501'; END IF;
  IF s.ended_at IS NOT NULL THEN RAISE EXCEPTION 'This Live session has ended.' USING ERRCODE = '42501'; END IF;
  IF now() > s.expires_at + interval '30 seconds' THEN
    -- closed as expired and refused WITHOUT raising (an exception would roll the close back); the Edge handler answers 403
    UPDATE erp.sana_live_session SET ended_at = s.expires_at, seconds = erp._sana_live_seconds(s), ended_reason = 'expired' WHERE id = s.id;
    RETURN jsonb_build_object('refused', 'This Live session has expired.', 'reason', 'expired');
  END IF;
  IF p_tool IS NOT NULL AND NOT (p_tool = ANY (s.tools)) THEN RAISE EXCEPTION 'That lookup is not available in this session.' USING ERRCODE = '42501'; END IF;
  UPDATE erp.sana_live_session SET tool_calls = tool_calls + CASE WHEN p_tool IS NOT NULL THEN 1 ELSE 0 END,
                                   turns = turns + CASE WHEN p_turn THEN 1 ELSE 0 END WHERE id = s.id;
  RETURN jsonb_build_object('company', s.company_code, 'model', s.model, 'language', s.language, 'tools', to_jsonb(s.tools), 'expires_at', s.expires_at);
END $$;

-- End a session (once). Seconds are capped at the token expiry.
CREATE OR REPLACE FUNCTION erp.sana_live_end(p_session uuid, p_reason text DEFAULT 'user') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); s erp.sana_live_session; secs integer;
BEGIN
  IF p_reason NOT IN ('user', 'silence', 'cap', 'hidden', 'expired', 'error', 'server') THEN RAISE EXCEPTION 'Unknown end reason.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO s FROM erp.sana_live_session WHERE id = p_session AND user_id = uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live session not found.' USING ERRCODE = '42501'; END IF;
  IF s.ended_at IS NOT NULL THEN RETURN jsonb_build_object('live_session_id', s.id, 'seconds', s.seconds, 'already_ended', true); END IF;
  secs := erp._sana_live_seconds(s);
  UPDATE erp.sana_live_session SET ended_at = least(now(), s.expires_at), seconds = secs, ended_reason = p_reason WHERE id = s.id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', s.company_code, 'sana.live.end', 'sana_live_session', s.id::text,
            jsonb_build_object('user_id', uid, 'seconds', secs, 'turns', s.turns, 'tool_calls', s.tool_calls, 'reason', p_reason));
  RETURN jsonb_build_object('live_session_id', s.id, 'seconds', secs);
END $$;

-- ============ 3. Typed-turn logging for Live (via = 'live') ============
ALTER TABLE erp.sana_message DROP CONSTRAINT IF EXISTS sana_message_via_check;
ALTER TABLE erp.sana_message ADD CONSTRAINT sana_message_via_check CHECK (via IN ('text', 'voice', 'live'));

-- 37's sana_log, unchanged except: via may be 'live' (counted with voice in the daily usage row).
CREATE OR REPLACE FUNCTION erp.sana_log(p_conversation uuid, p_company varchar, p_language text, p_question text, p_answer text,
                                        p_tools jsonb, p_sources jsonb, p_denied boolean, p_mode text, p_via text,
                                        p_context jsonb DEFAULT NULL, p_fallback boolean DEFAULT false,
                                        p_provider text DEFAULT NULL, p_model text DEFAULT NULL, p_tokens jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); cid uuid := p_conversation; co varchar; s erp.sana_settings; used integer;
        mid bigint; qid bigint; ctx jsonb; v_via text := coalesce(p_via, 'text'); v_mode text := coalesce(p_mode, 'basic');
        v_tokens jsonb;
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RAISE EXCEPTION 'You need a Southfield profile to use Sana.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NOT NULL AND NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', p_company USING ERRCODE = '42501';
  END IF;
  IF btrim(coalesce(p_question, '')) = '' THEN
    RAISE EXCEPTION 'Type or say a question first.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mode NOT IN ('ai', 'basic') OR v_via NOT IN ('text', 'voice', 'live') THEN
    RAISE EXCEPTION 'Mode must be ai or basic, and via text or voice.' USING ERRCODE = 'P0001';
  END IF;
  IF p_provider IS NOT NULL AND p_provider NOT IN ('gemini', 'anthropic') THEN
    RAISE EXCEPTION 'Provider must be gemini or anthropic.' USING ERRCODE = 'P0001';
  END IF;
  IF p_model IS NOT NULL AND p_model !~ '^[A-Za-z0-9._:/-]{1,80}$' THEN
    RAISE EXCEPTION 'Model names use letters, digits and . _ : / - only (up to 80).' USING ERRCODE = 'P0001';
  END IF;
  -- token counts: only whole numbers under the keys in / out (the provider's usage report), nothing else is kept
  IF jsonb_typeof(p_tokens) = 'object' THEN
    SELECT nullif(jsonb_object_agg(key, (p_tokens ->> key)::bigint), '{}') INTO v_tokens FROM jsonb_object_keys(p_tokens) key
     WHERE key IN ('in', 'out') AND jsonb_typeof(p_tokens -> key) = 'number' AND (p_tokens ->> key) ~ '^\d{1,9}$';
  END IF;
  co := erp._sana_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = co;
  IF NOT coalesce(s.enabled, true) THEN
    RAISE EXCEPTION 'Sana is switched off for %. Ask your system admin.', co USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(sum(questions), 0) INTO used FROM erp.sana_usage WHERE user_id = uid AND day = erp._sana_today();
  IF used >= coalesce(s.daily_limit, 200) THEN
    RAISE EXCEPTION 'You''ve reached today''s limit of % questions. It resets at midnight.', coalesce(s.daily_limit, 200) USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_context) = 'object' THEN
    SELECT nullif(jsonb_object_agg(key, left(p_context ->> key, 60)), '{}') INTO ctx FROM jsonb_object_keys(p_context) key
     WHERE key IN ('type', 'kind', 'company', 'number', 'code', 'label') AND jsonb_typeof(p_context -> key) IN ('string', 'number');
  END IF;
  IF cid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.sana_conversation WHERE conversation_id = cid AND user_id = uid) THEN
    INSERT INTO erp.sana_conversation (user_id, company_code, title, language) VALUES (uid, co, left(btrim(p_question), 80), p_language)
    RETURNING conversation_id INTO cid;
  ELSE
    UPDATE erp.sana_conversation SET last_at = now() WHERE conversation_id = cid;
  END IF;
  INSERT INTO erp.sana_message (conversation_id, role, content, via, language, context)
    VALUES (cid, 'user', left(p_question, 4000), v_via, p_language, ctx) RETURNING message_id INTO qid;
  INSERT INTO erp.sana_message (conversation_id, role, content, tools, sources, denied, mode, language, fallback, provider, model)
    VALUES (cid, 'assistant', left(coalesce(p_answer, ''), 8000), coalesce(p_tools, '[]'), coalesce(p_sources, '[]'), coalesce(p_denied, false), v_mode,
            p_language, coalesce(p_fallback, false), p_provider, p_model)
    RETURNING message_id INTO mid;
  INSERT INTO erp.sana_usage AS x (company_code, user_id, day, questions, refused, voice, ai, basic, fallback)
    VALUES (co, uid, erp._sana_today(), 1, CASE WHEN p_denied THEN 1 ELSE 0 END, CASE WHEN v_via IN ('voice', 'live') THEN 1 ELSE 0 END,
            CASE WHEN v_mode = 'ai' THEN 1 ELSE 0 END, CASE WHEN v_mode = 'basic' THEN 1 ELSE 0 END, CASE WHEN p_fallback THEN 1 ELSE 0 END)
  ON CONFLICT (company_code, user_id, day) DO UPDATE SET questions = x.questions + 1, refused = x.refused + EXCLUDED.refused,
    voice = x.voice + EXCLUDED.voice, ai = x.ai + EXCLUDED.ai, basic = x.basic + EXCLUDED.basic, fallback = x.fallback + EXCLUDED.fallback;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', co, 'sana.ask', 'sana_conversation', cid::text,
            jsonb_build_object('user_id', uid,
              'tools', (SELECT coalesce(jsonb_agg(DISTINCT t ->> 'tool'), '[]') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_tools) = 'array' THEN p_tools ELSE '[]' END) t),
              'denied', coalesce(p_denied, false), 'mode', v_mode, 'fallback', coalesce(p_fallback, false), 'via', v_via, 'language', p_language,
              'context', ctx ->> 'type', 'provider', p_provider, 'model', p_model, 'tokens', v_tokens));
  RETURN jsonb_build_object('conversation_id', cid, 'message_id', mid, 'question_id', qid);
END $$;

-- ============ 4. Item codes as heard (S5: "SF5160-IC/KC", "sf5160ickc" → SF5160IC KC) ============
-- Spoken codes come back with other spaces, dashes, slashes and case. A code now also matches when only those differ. Key-only
-- definer helper (allowed category, see docs/sana-agent.md): item keys from the caller's own companies, at most 10; the rows are
-- then read by the caller under RLS. Same rule for Ask and Live (sana_find and sana_stock from 50, with this one extra condition).
CREATE INDEX IF NOT EXISTS item_code_normalised_idx ON erp.item (company_code, (upper(regexp_replace(item_code, '[^A-Za-z0-9]', '', 'g'))));
CREATE OR REPLACE FUNCTION erp._sana_item_keys(p_cos varchar[], p_text text)
RETURNS TABLE (company_code varchar, code text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT i.company_code, i.item_code::text FROM erp.item i
   WHERE i.company_code = ANY (ARRAY(SELECT unnest(p_cos) INTERSECT SELECT uc.company_code FROM erp.user_company uc WHERE uc.user_id = erp.current_user_id()))
     AND length(regexp_replace(coalesce(p_text, ''), '[^A-Za-z0-9]', '', 'g')) >= 3
     AND upper(regexp_replace(i.item_code, '[^A-Za-z0-9]', '', 'g')) = upper(regexp_replace(p_text, '[^A-Za-z0-9]', '', 'g'))
   LIMIT 10
$$;
-- Near misses for a spoken code ("SF6180SL CL" for SF6180SLC LC): up to 3 codes by pg_trgm similarity of the normalised code,
-- offered back as did_you_mean so Sana can ask which one was meant. Key-only, the caller's companies only.
CREATE INDEX IF NOT EXISTS item_code_normalised_trgm ON erp.item USING gin ((upper(regexp_replace(item_code, '[^A-Za-z0-9]', '', 'g'))) extensions.gin_trgm_ops);
CREATE OR REPLACE FUNCTION erp._sana_item_similar(p_cos varchar[], p_text text)
RETURNS TABLE (company_code varchar, code text, score real)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, extensions, pg_temp AS $$
  SELECT i.company_code, i.item_code::text, similarity(upper(regexp_replace(i.item_code, '[^A-Za-z0-9]', '', 'g')), upper(regexp_replace(p_text, '[^A-Za-z0-9]', '', 'g')))
    FROM erp.item i
   WHERE i.company_code = ANY (ARRAY(SELECT unnest(p_cos) INTERSECT SELECT uc.company_code FROM erp.user_company uc WHERE uc.user_id = erp.current_user_id()))
     AND length(regexp_replace(coalesce(p_text, ''), '[^A-Za-z0-9]', '', 'g')) >= 5
     AND upper(regexp_replace(i.item_code, '[^A-Za-z0-9]', '', 'g')) % upper(regexp_replace(p_text, '[^A-Za-z0-9]', '', 'g'))
   ORDER BY 3 DESC LIMIT 3
$$;
REVOKE ALL ON FUNCTION erp._sana_item_keys(varchar[], text), erp._sana_item_similar(varchar[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._sana_item_keys(varchar[], text), erp._sana_item_similar(varchar[], text) TO authenticated;

-- 50's sana_find, plus the normalised item code in the exact step.
CREATE OR REPLACE FUNCTION erp.sana_find(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, extensions, pg_temp AS $$
DECLARE t text := btrim(left(coalesce(p_query, ''), 80));
        q text := '%' || replace(replace(replace(left(btrim(coalesce(p_query, '')), 80), '\', ''), '%', ''), '_', '\_') || '%';
        prefix text := replace(replace(replace(lower(btrim(left(coalesce(p_query, ''), 80))), '\', ''), '%', ''), '_', '\_') || '%';
        num integer := CASE WHEN btrim(coalesce(p_query, '')) ~ '^[0-9]{1,9}$' THEN btrim(p_query)::integer END;
        cos varchar[] := erp._sana_search_companies(p_company);
        started timestamptz := clock_timestamp();
        see_p boolean := erp.sana_has('sales', 'purchase', 'finance', 'bp');
        see_i boolean := erp.sana_has('inventory', 'sales', 'purchase');
        -- role rules worked out ONCE (not per row): which partner kinds and document kinds this caller may see
        see_c boolean := erp.sana_has('sales', 'finance', 'bp');
        see_s boolean := erp.sana_has('purchase', 'finance', 'bp');
        kinds text[] := (SELECT coalesce(array_agg(k), '{}') FROM unnest(ARRAY['sales_quotation','sales_order','delivery','sales_return','ar_down_payment','ar_invoice',
                           'ar_credit_note','purchase_request','purchase_quotation','purchase_order','goods_receipt_po','goods_return','ap_down_payment','ap_invoice',
                           'ap_credit_note','transfer_request','inventory_transfer','goods_receipt','goods_issue']) k WHERE erp.sana_doc_allowed(k));
        partners jsonb := '[]'; items jsonb := '[]'; docs jsonb := '[]';
        -- normalised item-code keys worked out ONCE up front (an OR with a sub-select per row made the planner scan every item
        -- under RLS: 2 s on AE05 in the 52 dry run); then a plain = ANY on the (company_code, item_code) key
        ikeys text[] := CASE WHEN see_i THEN ARRAY(SELECT k.code FROM erp._sana_item_keys(cos, left(coalesce(p_query, ''), 80)) k) ELSE '{}' END;
BEGIN
  -- same shape as 36: 'partners' / 'items' only for roles that may see them, 'documents' always
  IF length(t) < 2 THEN RETURN jsonb_build_object('error', 'Search text is too short'); END IF;
  IF cardinality(cos) = 0 THEN RETURN erp._sana_find_out(see_p, see_i, partners, items, docs); END IF;

  -- 1. exact: codes, barcodes, document numbers, partner name prefix (all indexed)
  IF see_p THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO partners FROM (
      SELECT b.company_code AS company, b.card_code AS code, b.name, b.kind, '/bp/' || b.company_code || '/' || b.card_code AS link
        FROM erp.business_partner b
       WHERE b.company_code = ANY (cos)
         AND (b.card_code IN (t, upper(t))
              OR (b.company_code, b.card_code) IN (SELECT k.company_code, k.code FROM erp._sana_text_keys('partner_prefix', cos, t) k))
         AND (b.kind <> 'customer' OR see_c) AND (b.kind <> 'supplier' OR see_s)
       ORDER BY (b.card_code IN (t, upper(t))) DESC, b.name LIMIT 8) x;
  END IF;
  IF see_i THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO items FROM (
      SELECT i.company_code AS company, i.item_code AS code, i.name, '/items/' || i.company_code || '/' || i.item_code AS link
        FROM erp.item i WHERE i.company_code = ANY (cos) AND (i.item_code = ANY (ARRAY[t, upper(t)] || ikeys) OR i.barcode = t)
       ORDER BY i.item_code LIMIT 8) x;
  END IF;
  -- documents: SAP number (company_code, doc_num index) or Southfield number (doc_workflow (company_code, upper(doc_no)) index)
  SELECT coalesce(jsonb_agg(x), '[]') INTO docs FROM (
    WITH c AS MATERIALIZED (
      SELECT d.* FROM erp.document d WHERE num IS NOT NULL AND d.company_code = ANY (cos) AND d.doc_num = num
      UNION
      SELECT d.* FROM erp.doc_workflow w JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE w.company_code = ANY (cos) AND upper(w.doc_no) = upper(t)
      LIMIT 50)
    SELECT c.company_code AS company, c.doc_kind AS kind, erp._sana_doc_no(c.company_code, c.obj_type, c.doc_entry, c.doc_num) AS number,
           c.card_name AS partner, c.doc_date AS date, c.status, c.total, c.currency, erp._doc_link(c.company_code, c.obj_type, c.doc_entry) AS link
      FROM c WHERE c.doc_kind = ANY (kinds)
     ORDER BY c.doc_date DESC LIMIT 8) x;
  IF jsonb_array_length(partners) + jsonb_array_length(items) + jsonb_array_length(docs) > 0 THEN
    RETURN erp._sana_find_out(see_p, see_i, partners, items, docs);
  END IF;

  -- 2. text search (pg_trgm), at most 50 candidates per list, only within the time budget and for 3+ characters
  IF length(t) < 3 OR clock_timestamp() - started > interval '2.5 seconds' THEN
    RETURN erp._sana_find_out(see_p, see_i, partners, items, docs);
  END IF;
  IF see_p THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO partners FROM (
      WITH c AS MATERIALIZED (SELECT b.* FROM erp.business_partner b
                               WHERE (b.company_code, b.card_code) IN (SELECT k.company_code, k.code FROM erp._sana_text_keys('partner', cos, t) k))
      SELECT c.company_code AS company, c.card_code AS code, c.name, c.kind, '/bp/' || c.company_code || '/' || c.card_code AS link FROM c
       WHERE (c.kind <> 'customer' OR see_c) AND (c.kind <> 'supplier' OR see_s)
       ORDER BY c.name LIMIT 8) x;
  END IF;
  IF see_i AND clock_timestamp() - started <= interval '2.5 seconds' THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO items FROM (
      WITH c AS MATERIALIZED (SELECT i.* FROM erp.item i WHERE (i.company_code, i.item_code) IN (SELECT k.company_code, k.code FROM erp._sana_text_keys('item', cos, t) k))
      SELECT c.company_code AS company, c.item_code AS code, c.name, '/items/' || c.company_code || '/' || c.item_code AS link FROM c ORDER BY c.item_code LIMIT 8) x;
  END IF;
  IF clock_timestamp() - started <= interval '2.5 seconds' THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO docs FROM (
      WITH c AS MATERIALIZED (SELECT d.* FROM erp.document d
                               WHERE (d.company_code, d.obj_type, d.doc_entry) IN (SELECT k.company_code, k.obj_type, k.doc_entry FROM erp._sana_text_keys('document', cos, t, kinds) k))
      SELECT c.company_code AS company, c.doc_kind AS kind, erp._sana_doc_no(c.company_code, c.obj_type, c.doc_entry, c.doc_num) AS number,
             c.card_name AS partner, c.doc_date AS date, c.status, c.total, c.currency, erp._doc_link(c.company_code, c.obj_type, c.doc_entry) AS link
        FROM c ORDER BY c.doc_date DESC LIMIT 8) x;
  END IF;
  RETURN erp._sana_find_out(see_p, see_i, partners, items, docs);
END $$;

-- 50's sana_stock, plus the normalised item code in the exact step.
CREATE OR REPLACE FUNCTION erp.sana_stock(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, extensions, pg_temp AS $$
DECLARE cost boolean := erp.sana_has('finance', 'purchase', 'inventory'); t text := btrim(left(coalesce(p_query, ''), 80));
        q text := '%' || replace(replace(replace(left(btrim(coalesce(p_query, '')), 80), '\', ''), '%', ''), '_', '\_') || '%';
        cos varchar[] := erp._sana_search_companies(p_company); comps varchar[]; codes text[]; ikeys text[];
BEGIN
  IF NOT erp.sana_has('inventory', 'sales', 'purchase') THEN RETURN erp.sana_denied('inventory'); END IF;
  IF length(t) < 2 OR cardinality(cos) = 0 THEN RETURN jsonb_build_object('items', '[]'::jsonb, 'cost_visible', cost); END IF;
  ikeys := ARRAY(SELECT k.code FROM erp._sana_item_keys(cos, t) k);   -- once, up front (see sana_find)
  SELECT array_agg(i.company_code), array_agg(i.item_code::text) INTO comps, codes FROM (
    SELECT company_code, item_code FROM erp.item WHERE company_code = ANY (cos) AND (item_code = ANY (ARRAY[t, upper(t)] || ikeys) OR barcode = t) LIMIT 5) i;
  IF codes IS NULL AND length(t) >= 3 THEN
    SELECT array_agg(i.company_code), array_agg(i.item_code::text) INTO comps, codes FROM (
      SELECT k.company_code, k.code AS item_code FROM erp._sana_text_keys('item', cos, t) k ORDER BY k.code LIMIT 5) i;
  END IF;
  IF codes IS NULL THEN   -- nothing found: offer up to 3 close codes (spoken codes come back slightly wrong)
    RETURN jsonb_build_object('items', '[]'::jsonb, 'cost_visible', cost,
      'did_you_mean', (SELECT coalesce(jsonb_agg(k.code ORDER BY k.score DESC), '[]') FROM erp._sana_item_similar(cos, t) k WHERE k.score >= 0.4));
  END IF;
  RETURN jsonb_build_object('items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
    SELECT i.company_code AS company, i.item_code AS code, i.name, i.inventory_uom AS unit, '/items/' || i.company_code || '/' || i.item_code AS link,
           (SELECT coalesce(jsonb_agg(jsonb_build_object('warehouse', s.whs_code, 'on_hand', s.on_hand, 'committed', s.committed, 'ordered', s.on_order,
                    'available', s.on_hand - s.committed, 'below_minimum', s.min_stock > 0 AND s.on_hand < s.min_stock) ORDER BY s.whs_code), '[]')
              FROM erp.stock_balance s WHERE s.company_code = i.company_code AND s.item_code = i.item_code) AS warehouses,
           CASE WHEN cost THEN i.avg_cost END AS average_cost
      FROM erp.item i
     WHERE (i.company_code, i.item_code) IN (SELECT u.c, u.i FROM unnest(comps, codes) AS u(c, i))
     ORDER BY i.item_code LIMIT 5) x), 'cost_visible', cost);
END $$;

REVOKE ALL ON FUNCTION erp._sana_live_seconds(erp.sana_live_session) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.sana_caps(varchar), erp.sana_caps_save(varchar, integer, integer), erp.sana_live_usage_today(varchar),
  erp.sana_live_start(varchar, text, text, text[], timestamptz), erp.sana_live_check(uuid, text, boolean), erp.sana_live_end(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_caps(varchar), erp.sana_caps_save(varchar, integer, integer), erp.sana_live_usage_today(varchar),
  erp.sana_live_start(varchar, text, text, text[], timestamptz), erp.sana_live_check(uuid, text, boolean), erp.sana_live_end(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
