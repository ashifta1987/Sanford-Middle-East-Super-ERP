-- 37_sana_gemini.sql · S2 · Gemini as Sana's provider (text + voice).
-- Decisions of 11 Nov 2026: Gemini is the single AI provider for text and voice; the Anthropic adapter stays as a fallback
-- chosen by the Supabase secret SANA_PROVIDER. Provider keys are Supabase secrets read only by the Edge Functions
-- (GEMINI_API_KEY, ANTHROPIC_API_KEY) and are NEVER stored in a table, a setting, a log or the browser.
--
-- What this file adds (CREATE OR REPLACE over 36_sana.sql; 36 itself is unchanged):
--   * sana_settings.voice_mode  'browser' (default: the browser's own speech, as in S1) | 'provider' (Gemini speech-to-text
--     and text-to-speech through the sana-voice Edge Function, e.g. for Malayalam on devices without a Malayalam voice).
--   * sana_usage.voice_calls    provider voice calls per user and day (speech-to-text + text-to-speech), counts only.
--   * sana_message.provider / model   which provider and model wrote an answer (NULL in basic mode).
--   * sana_status / sana_setup return voice_mode (and voice calls); sana_settings_save accepts voice_mode.
--   * sana_log takes p_provider, p_model, p_tokens (audit: provider, model, token counts — never the question).
--   * sana_voice_use: the sana-voice function records one provider voice call (checks + counter + metadata-only audit).
--     Audio is never stored or logged anywhere.
-- Nothing is seeded for any company (no row = voice_mode 'browser'). Safe to run twice.

-- ============ 1. Columns ============
ALTER TABLE erp.sana_settings ADD COLUMN IF NOT EXISTS voice_mode text NOT NULL DEFAULT 'browser'
  CONSTRAINT sana_settings_voice_mode_check CHECK (voice_mode IN ('browser', 'provider'));
ALTER TABLE erp.sana_usage ADD COLUMN IF NOT EXISTS voice_calls integer NOT NULL DEFAULT 0;
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS provider text;
ALTER TABLE erp.sana_message ADD COLUMN IF NOT EXISTS model text;
COMMENT ON COLUMN erp.sana_settings.voice_mode IS 'browser = Web Speech API in the browser; provider = Gemini STT/TTS through the sana-voice Edge Function (audio never stored).';
COMMENT ON COLUMN erp.sana_usage.voice_calls IS 'Provider voice calls (speech-to-text + text-to-speech) of the user that day. Counts only.';

-- ============ 2. Status (the panel and both Edge Functions read it with the user's own token) ============
CREATE OR REPLACE FUNCTION erp.sana_status(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); co varchar; s erp.sana_settings; used integer; vcalls integer;
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RETURN jsonb_build_object('profile', false, 'enabled', false);
  END IF;
  co := erp._sana_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = co;
  SELECT coalesce(sum(questions), 0), coalesce(sum(voice_calls), 0) INTO used, vcalls FROM erp.sana_usage WHERE user_id = uid AND day = erp._sana_today();
  RETURN jsonb_build_object('profile', true, 'company', co,
    'enabled', coalesce(s.enabled, true), 'voice_enabled', coalesce(s.voice_enabled, true),
    'voice_mode', coalesce(s.voice_mode, 'browser'),
    'daily_limit', coalesce(s.daily_limit, 200), 'used', used, 'voice_calls', vcalls,
    'languages', to_jsonb(coalesce(s.languages, '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[])));
END $$;

-- ============ 3. Log one question and answer (36's version + provider, model and token counts) ============
-- The 12-argument version of 36 is replaced (a call with the 12 named arguments still resolves to this one).
DROP FUNCTION IF EXISTS erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text, jsonb, boolean);
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
  IF v_mode NOT IN ('ai', 'basic') OR v_via NOT IN ('text', 'voice') THEN
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
    VALUES (co, uid, erp._sana_today(), 1, CASE WHEN p_denied THEN 1 ELSE 0 END, CASE WHEN v_via = 'voice' THEN 1 ELSE 0 END,
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

-- ============ 4. One provider voice call (called by the sana-voice Edge Function with the user's own token) ============
-- Checks the same rules as the function (profile, company, Sana on, voice on, voice mode 'provider', language allowed, daily
-- limits), counts the call and audits metadata only: mode (stt|tts), language, seconds of audio, provider, model, ok.
-- Limit: questions used today must be under the daily limit, and provider voice calls under twice the daily limit (one
-- speech-to-text and one text-to-speech per question).
CREATE OR REPLACE FUNCTION erp.sana_voice_use(p_company varchar, p_mode text, p_language text, p_seconds numeric,
                                              p_provider text, p_model text, p_ok boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE uid uuid := erp.current_user_id(); co varchar; s erp.sana_settings; used integer; vcalls integer; lim integer;
BEGIN
  IF uid IS NULL OR NOT EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = uid AND active) THEN
    RAISE EXCEPTION 'You need a Southfield profile to use Sana.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NOT NULL AND NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', p_company USING ERRCODE = '42501';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('stt', 'tts') THEN
    RAISE EXCEPTION 'Voice mode must be stt (speech to text) or tts (text to speech).' USING ERRCODE = 'P0001';
  END IF;
  IF p_provider IS NULL OR p_provider <> 'gemini' THEN
    RAISE EXCEPTION 'Provider voice uses Gemini.' USING ERRCODE = 'P0001';
  END IF;
  IF p_model IS NULL OR p_model !~ '^[A-Za-z0-9._:/-]{1,80}$' THEN
    RAISE EXCEPTION 'Model names use letters, digits and . _ : / - only (up to 80).' USING ERRCODE = 'P0001';
  END IF;
  IF p_seconds IS NOT NULL AND (p_seconds < 0 OR p_seconds > 600) THEN
    RAISE EXCEPTION 'Audio length must be from 0 to 600 seconds.' USING ERRCODE = 'P0001';
  END IF;
  co := erp._sana_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = co;
  IF NOT coalesce(s.enabled, true) THEN
    RAISE EXCEPTION 'Sana is switched off for %. Ask your system admin.', co USING ERRCODE = '42501';
  END IF;
  IF NOT coalesce(s.voice_enabled, true) THEN
    RAISE EXCEPTION 'Voice is switched off for your company. Type your question instead.' USING ERRCODE = '42501';
  END IF;
  IF coalesce(s.voice_mode, 'browser') <> 'provider' THEN
    RAISE EXCEPTION 'Provider voice is not switched on for %. The browser''s own voice is used.', co USING ERRCODE = '42501';
  END IF;
  IF p_language IS NULL OR NOT p_language = ANY (coalesce(s.languages, '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[])) THEN
    RAISE EXCEPTION 'That language is not switched on for Sana in %.', co USING ERRCODE = 'P0001';
  END IF;
  lim := coalesce(s.daily_limit, 200);
  SELECT coalesce(sum(questions), 0), coalesce(sum(voice_calls), 0) INTO used, vcalls FROM erp.sana_usage WHERE user_id = uid AND day = erp._sana_today();
  IF used >= lim OR vcalls >= 2 * lim THEN
    RAISE EXCEPTION 'You''ve reached today''s limit of % questions. It resets at midnight.', lim USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.sana_usage AS x (company_code, user_id, day, voice_calls) VALUES (co, uid, erp._sana_today(), 1)
  ON CONFLICT (company_code, user_id, day) DO UPDATE SET voice_calls = x.voice_calls + 1;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES ('ai:sana', co, 'sana.voice', 'sana_voice', p_mode,
            jsonb_build_object('user_id', uid, 'mode', p_mode, 'language', p_language, 'seconds', round(coalesce(p_seconds, 0), 1),
                               'provider', p_provider, 'model', p_model, 'ok', coalesce(p_ok, true)));
  RETURN jsonb_build_object('company', co, 'voice_calls', vcalls + 1, 'limit', 2 * lim);
END $$;

-- ============ 5. Administration › Add-Ons › AI Assistant (Sana) ============
CREATE OR REPLACE FUNCTION erp.sana_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE s erp.sana_settings;
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  SELECT * INTO s FROM erp.sana_settings WHERE company_code = p_company;
  RETURN jsonb_build_object('company', p_company,
    'settings', jsonb_build_object('enabled', coalesce(s.enabled, true), 'voice_enabled', coalesce(s.voice_enabled, true),
       'voice_mode', coalesce(s.voice_mode, 'browser'),
       'daily_limit', coalesce(s.daily_limit, 200), 'languages', to_jsonb(coalesce(s.languages, '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[])),
       'saved', s.company_code IS NOT NULL, 'updated_at', s.updated_at, 'updated_by', erp._adm_name(s.updated_by)),
    'all_languages', to_jsonb('{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}'::text[]),
    'voice_modes', to_jsonb('{browser,provider}'::text[]),
    'can_edit', erp.can_write('admin'),
    'usage', jsonb_build_object(
      'days', (SELECT coalesce(jsonb_agg(jsonb_build_object('day', day, 'questions', q, 'refused', r, 'voice', v, 'ai', a, 'basic', b, 'voice_calls', vc, 'users', n) ORDER BY day DESC), '[]')
                 FROM (SELECT day, sum(questions) q, sum(refused) r, sum(voice) v, sum(ai) a, sum(basic) b, sum(voice_calls) vc, count(DISTINCT user_id) n
                         FROM erp.sana_usage WHERE company_code = p_company AND day > erp._sana_today() - 30 GROUP BY day) d),
      'total_30_days', (SELECT jsonb_build_object('questions', coalesce(sum(questions), 0), 'refused', coalesce(sum(refused), 0),
                          'voice', coalesce(sum(voice), 0), 'ai', coalesce(sum(ai), 0), 'basic', coalesce(sum(basic), 0),
                          'fallback', coalesce(sum(fallback), 0), 'voice_calls', coalesce(sum(voice_calls), 0), 'users', count(DISTINCT user_id))
                          FROM erp.sana_usage WHERE company_code = p_company AND day > erp._sana_today() - 30),
      'feedback', (SELECT jsonb_build_object('up', count(*) FILTER (WHERE value = 1), 'down', count(*) FILTER (WHERE value = -1))
                     FROM erp.sana_feedback WHERE company_code = p_company AND at > now() - interval '30 days')));
END $$;

CREATE OR REPLACE FUNCTION erp.sana_settings_save(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE me erp.app_user := erp._adm_guard(true); old erp.sana_settings; k text;
        v_on boolean; v_voice boolean; v_lim integer; v_langs text[]; v_vmode text;
        all_langs text[] := '{en,ar,hi,ur,ml,ta,bn,tl,zh,fr,ru}';
BEGIN
  PERFORM erp._adm_company(p_company);
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the settings.' USING ERRCODE = 'P0001';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k ~* '(key|secret|token|password|credential)' THEN
      RAISE EXCEPTION 'API keys are never stored in the database. IT sets the Supabase secret GEMINI_API_KEY; only the Sana server functions read it.'
        USING ERRCODE = 'P0001';
    END IF;
    IF k NOT IN ('enabled', 'voice_enabled', 'voice_mode', 'daily_limit', 'languages') THEN
      RAISE EXCEPTION 'Unknown Sana setting %.', k USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  SELECT * INTO old FROM erp.sana_settings WHERE company_code = p_company FOR UPDATE;
  BEGIN
    v_on    := CASE WHEN p ? 'enabled' THEN (p ->> 'enabled')::boolean ELSE coalesce(old.enabled, true) END;
    v_voice := CASE WHEN p ? 'voice_enabled' THEN (p ->> 'voice_enabled')::boolean ELSE coalesce(old.voice_enabled, true) END;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Sana on/off and voice on/off must be yes or no.' USING ERRCODE = 'P0001';
  END;
  IF v_on IS NULL OR v_voice IS NULL THEN
    RAISE EXCEPTION 'Sana on/off and voice on/off must be yes or no.' USING ERRCODE = 'P0001';
  END IF;
  IF p ? 'voice_mode' THEN
    IF jsonb_typeof(p -> 'voice_mode') IS DISTINCT FROM 'string' OR (p ->> 'voice_mode') NOT IN ('browser', 'provider') THEN
      RAISE EXCEPTION 'Voice mode must be browser (the device''s own voice) or provider (Gemini voice through Southfield).' USING ERRCODE = 'P0001';
    END IF;
    v_vmode := p ->> 'voice_mode';
  ELSE
    v_vmode := coalesce(old.voice_mode, 'browser');
  END IF;
  IF p ? 'daily_limit' THEN
    IF coalesce(p ->> 'daily_limit', '') !~ '^\d{1,4}$' OR (p ->> 'daily_limit')::integer > 5000 THEN
      RAISE EXCEPTION 'Enter a daily limit from 0 to 5,000 questions per person.' USING ERRCODE = 'P0001';
    END IF;
    v_lim := (p ->> 'daily_limit')::integer;
  ELSE
    v_lim := coalesce(old.daily_limit, 200);
  END IF;
  IF p ? 'languages' THEN
    IF jsonb_typeof(p -> 'languages') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Choose at least one language.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT l ORDER BY l) INTO v_langs FROM jsonb_array_elements_text(p -> 'languages') l;
    IF v_langs IS NULL THEN
      RAISE EXCEPTION 'Choose at least one language.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_langs <@ all_langs THEN
      RAISE EXCEPTION 'Sana supports these languages: en, ar, hi, ur, ml, ta, bn, tl, zh, fr, ru.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(l ORDER BY array_position(all_langs, l)) INTO v_langs FROM unnest(v_langs) l;
  ELSE
    v_langs := coalesce(old.languages, all_langs);
  END IF;
  INSERT INTO erp.sana_settings (company_code, enabled, voice_enabled, voice_mode, daily_limit, languages, updated_by, updated_at)
  VALUES (p_company, v_on, v_voice, v_vmode, v_lim, v_langs, me.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET enabled = EXCLUDED.enabled, voice_enabled = EXCLUDED.voice_enabled, voice_mode = EXCLUDED.voice_mode,
    daily_limit = EXCLUDED.daily_limit, languages = EXCLUDED.languages, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'sana_settings_save', 'sana_settings', p_company,
          jsonb_build_object('from', CASE WHEN old.company_code IS NULL THEN NULL ELSE jsonb_build_object('enabled', old.enabled, 'voice_enabled', old.voice_enabled,
                               'voice_mode', old.voice_mode, 'daily_limit', old.daily_limit, 'languages', old.languages) END,
                             'to', jsonb_build_object('enabled', v_on, 'voice_enabled', v_voice, 'voice_mode', v_vmode, 'daily_limit', v_lim, 'languages', v_langs)));
  RETURN jsonb_build_object('company', p_company, 'enabled', v_on, 'voice_enabled', v_voice, 'voice_mode', v_vmode, 'daily_limit', v_lim, 'languages', to_jsonb(v_langs));
END $$;

-- ============ 6. System health (A14): copied from 36 + 37_sana_gemini.sql ============
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health'),
    ('30_numbering_company.sql', 'doc_series_save'), ('31_approvals.sql', 'approval_template_save'),
    ('32_gl_setup.sql', 'gl_setup'),
    ('33_multicurrency.sql', 'currency_rate'),
    ('34_open_items.sql', 'fx_revaluation_post'),
    ('35_final_items.sql', 'conversion_diff_post'),
    ('36_sana.sql', 'sana_settings_save'),
    ('37_sana_gemini.sql', 'sana_voice_use')
  ) AS v(file_name, object)
$$;
-- S2: + 37_sana_gemini.sql (marker sana_voice_use).

-- ============ 7. Grants ============
REVOKE ALL ON FUNCTION erp.sana_status(varchar),
  erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text, jsonb, boolean, text, text, jsonb),
  erp.sana_voice_use(varchar, text, text, numeric, text, text, boolean),
  erp.sana_setup(varchar), erp.sana_settings_save(varchar, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_status(varchar),
  erp.sana_log(uuid, varchar, text, text, text, jsonb, jsonb, boolean, text, text, jsonb, boolean, text, text, jsonb),
  erp.sana_voice_use(varchar, text, text, numeric, text, text, boolean),
  erp.sana_setup(varchar), erp.sana_settings_save(varchar, jsonb)
  TO authenticated;
