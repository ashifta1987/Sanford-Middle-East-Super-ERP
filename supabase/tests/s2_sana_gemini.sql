-- S2 · Sana on Gemini: voice mode per company (browser | provider), provider voice calls (sana_voice_use), provider / model /
-- token counts in the log and audit, no key anywhere in the database, system health, grants.
-- LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql). Run on a FRESH rebuild (sql-order.txt incl. 37).
-- One transaction, rolled back. Prints PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE s2_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON s2_result TO authenticated;

CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO s2_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
CREATE FUNCTION pg_temp.save(n integer, p text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(pg_temp.u(n), format('SELECT erp.sana_settings_save(%L, %L::jsonb)', 'ZZ99', p))
$$;
CREATE FUNCTION pg_temp.voice(n integer, mode text, lang text, secs numeric DEFAULT 3.5, provider text DEFAULT 'gemini', model text DEFAULT 'gemini-2.5-flash',
                              company text DEFAULT 'ZZ99') RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(pg_temp.u(n), format('SELECT erp.sana_voice_use(%L, %L, %L, %s, %L, %L, true)', company, mode, lang, coalesce(secs::text, 'NULL'), provider, model))
$$;

-- fresh counters and settings for the test users (rolled back)
DELETE FROM erp.sana_usage WHERE user_id IN (pg_temp.u(1), pg_temp.u(2), pg_temp.u(4), pg_temp.u(5), pg_temp.u(23));
DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99';

DO $$
DECLARE r jsonb; c1 text; m bigint; n0 integer; al erp.audit_log;
BEGIN
  -- ---------- schema ----------
  PERFORM pg_temp.check((SELECT column_default LIKE '''browser''%' AND is_nullable = 'NO' FROM information_schema.columns
                          WHERE table_schema = 'erp' AND table_name = 'sana_settings' AND column_name = 'voice_mode'),
                        'sana_settings.voice_mode: text NOT NULL DEFAULT ''browser''');
  BEGIN
    INSERT INTO erp.sana_settings (company_code, voice_mode) VALUES ('ZZ99', 'cloud');
    PERFORM pg_temp.check(false, 'voice_mode CHECK refuses other values');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.check(true, 'voice_mode CHECK refuses other values (browser / provider only)');
  END;
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.sana_settings WHERE company_code IN ('AE01','AE02','AE03','AE04','AE05')
                                      AND voice_mode <> 'browser'), 'nothing seeded for AE01–AE05 (no row or browser)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'erp' AND table_name LIKE 'sana%'
                                      AND column_name ~* '(key|secret|password|credential)'), 'no Sana table has a column for a key, secret or password');

  -- ---------- status and setup return voice_mode ----------
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check(r ->> 'voice_mode' = 'browser' AND (r ->> 'voice_calls')::int = 0, 'status: no row = voice mode browser, 0 voice calls', r::text);
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_setup(''ZZ99'')');
  PERFORM pg_temp.check(r -> 'settings' ->> 'voice_mode' = 'browser' AND r -> 'voice_modes' = '["browser", "provider"]'::jsonb
                          AND (r -> 'usage' -> 'total_30_days' ->> 'voice_calls')::int = 0, 'setup: voice mode browser, both choices, voice-call count', left(r::text, 300));

  -- ---------- save voice_mode: allowed, refused, bad value, non-admin ----------
  r := pg_temp.save(1, '{"voice_mode": "provider"}');
  PERFORM pg_temp.check(r ->> 'voice_mode' = 'provider' AND (r ->> 'enabled')::boolean AND (r ->> 'voice_enabled')::boolean AND (r ->> 'daily_limit')::int = 200,
                        'save: admin sets voice mode provider; other settings keep their defaults', r::text);
  PERFORM pg_temp.check((SELECT voice_mode FROM erp.sana_settings WHERE company_code = 'ZZ99') = 'provider', 'save: stored');
  SELECT * INTO al FROM erp.audit_log WHERE action = 'sana_settings_save' AND company_code = 'ZZ99' ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.check(al.detail -> 'to' ->> 'voice_mode' = 'provider' AND al.detail -> 'from' IS NULL OR al.detail -> 'from' = 'null'::jsonb,
                        'save: audited (to.voice_mode = provider)', al.detail::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check(r ->> 'voice_mode' = 'provider', 'status: sales sees voice mode provider', r::text);
  r := pg_temp.save(1, '{"daily_limit": 50}');
  PERFORM pg_temp.check(r ->> 'voice_mode' = 'provider' AND (r ->> 'daily_limit')::int = 50, 'save: a save without voice_mode keeps it', r::text);
  PERFORM pg_temp.expect(pg_temp.save(1, '{"voice_mode": "cloud"}'),
    'Voice mode must be browser (the device''s own voice) or provider (Gemini voice through Southfield).', 'save: bad voice mode value refused');
  PERFORM pg_temp.expect(pg_temp.save(1, '{"voice_mode": null}'),
    'Voice mode must be browser (the device''s own voice) or provider (Gemini voice through Southfield).', 'save: null voice mode refused');
  PERFORM pg_temp.expect(pg_temp.save(1, '{"voice_mode": true}'),
    'Voice mode must be browser (the device''s own voice) or provider (Gemini voice through Southfield).', 'save: non-text voice mode refused');
  PERFORM pg_temp.expect(pg_temp.save(1, '{"voice_mode": "Provider"}'),
    'Voice mode must be browser (the device''s own voice) or provider (Gemini voice through Southfield).', 'save: voice mode is exact (lower case)');
  PERFORM pg_temp.expect(pg_temp.save(2, '{"voice_mode": "browser"}'), 'Only a system admin with full Administration access can change this.', 'save: sales (non-admin) refused');
  PERFORM pg_temp.expect(pg_temp.save(4, '{"voice_mode": "browser"}'), 'Only a system admin with full Administration access can change this.', 'save: finance (non-admin) refused');
  PERFORM pg_temp.expect(pg_temp.save(23, '{"voice_mode": "browser"}'), 'Only a system admin with full Administration access can change this.', 'save: IT (Administration read-only) refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''AE01'', ''{"voice_mode": "provider"}'')'),
    'You don''t have access to company AE01.', 'save: a company the admin cannot see');
  PERFORM pg_temp.check((SELECT voice_mode FROM erp.sana_settings WHERE company_code = 'ZZ99') = 'provider', 'refused saves changed nothing');
  PERFORM pg_temp.expect(pg_temp.save(1, '{"gemini_api_key": "x"}'),
    'API keys are never stored in the database. IT sets the Supabase secret GEMINI_API_KEY; only the Sana server functions read it.', 'save: a key field is refused');
  PERFORM pg_temp.expect(pg_temp.save(1, '{"provider_token": "x"}'),
    'API keys are never stored in the database. IT sets the Supabase secret GEMINI_API_KEY; only the Sana server functions read it.', 'save: a token field is refused');
  PERFORM pg_temp.expect(pg_temp.save(1, '{"provider": "gemini"}'), 'Unknown Sana setting provider.', 'save: provider is a server secret, not a setting');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_setup(''ZZ99'')'), 'Only the system admin, IT and the owner can open Administration.', 'setup: sales refused');

  -- ---------- provider voice calls ----------
  r := pg_temp.voice(2, 'stt', 'ml', 4.2);
  PERFORM pg_temp.check((r ->> 'error') IS NULL AND (r ->> 'voice_calls')::int = 1 AND (r ->> 'limit')::int = 100, 'voice: speech-to-text in Malayalam allowed (provider mode), counted', r::text);
  SELECT * INTO al FROM erp.audit_log WHERE action = 'sana.voice' ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.check(al.actor = 'ai:sana' AND al.company_code = 'ZZ99' AND al.object_ref = 'stt'
                        AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(al.detail) k) = '{language,mode,model,ok,provider,seconds,user_id}'
                        AND al.detail ->> 'language' = 'ml' AND (al.detail ->> 'seconds')::numeric = 4.2 AND al.detail ->> 'provider' = 'gemini',
                        'voice: audit has metadata only (mode, language, seconds, provider, model, ok) — no audio, no text', al.detail::text);
  r := pg_temp.voice(2, 'tts', 'en', 9);
  PERFORM pg_temp.check((r ->> 'voice_calls')::int = 2, 'voice: text-to-speech in English allowed, counted', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'voice_calls')::int = 2 AND (r ->> 'used')::int = 0, 'status: 2 voice calls today; they are not questions', r::text);
  PERFORM pg_temp.expect(pg_temp.voice(2, 'record', 'en'), 'Voice mode must be stt (speech to text) or tts (text to speech).', 'voice: unknown mode refused');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'en', 3, 'anthropic'), 'Provider voice uses Gemini.', 'voice: only Gemini');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'en', 3, 'gemini', 'bad model!'), 'Model names use letters, digits and . _ : / - only (up to 80).', 'voice: bad model name refused');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'en', 900), 'Audio length must be from 0 to 600 seconds.', 'voice: audio length checked');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'de'), 'That language is not switched on for Sana in ZZ99.', 'voice: unknown language refused');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'en', 3, 'gemini', 'gemini-2.5-flash', 'AE01'), 'You don''t have access to company AE01.', 'voice: a company the user cannot see');
  PERFORM pg_temp.expect(pg_temp.voice(3, 'stt', 'en'), 'You need a Southfield profile to use Sana.', 'voice: no profile refused');
  r := pg_temp.call(NULL, 'SELECT erp.sana_voice_use(''ZZ99'', ''stt'', ''en'', 1, ''gemini'', ''m'', true)', 'anon');
  PERFORM pg_temp.check(r ->> 'error' = '42501' AND NOT has_function_privilege('anon', 'erp.sana_voice_use(varchar,text,text,numeric,text,text,boolean)', 'EXECUTE'),
                        'voice: not callable without signing in (anon refused)', r::text);
  PERFORM pg_temp.ok(pg_temp.save(1, '{"languages": ["en", "ar"]}'), 'save: languages en, ar');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'ml'), 'That language is not switched on for Sana in ZZ99.', 'voice: follows the company''s language list');
  PERFORM pg_temp.ok(pg_temp.save(1, '{"voice_mode": "browser", "languages": ["en", "ml", "ar"]}'), 'save: back to browser voice');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'stt', 'en'), 'Provider voice is not switched on for ZZ99. The browser''s own voice is used.', 'voice: refused in browser mode');
  PERFORM pg_temp.ok(pg_temp.save(1, '{"voice_mode": "provider", "voice_enabled": false}'), 'save: provider mode, voice off');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'tts', 'en'), 'Voice is switched off for your company. Type your question instead.', 'voice: refused while voice is off');
  PERFORM pg_temp.ok(pg_temp.save(1, '{"voice_enabled": true, "enabled": false}'), 'save: Sana off');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'tts', 'en'), 'Sana is switched off for ZZ99. Ask your system admin.', 'voice: refused while Sana is off');
  PERFORM pg_temp.ok(pg_temp.save(1, '{"enabled": true, "daily_limit": 1}'), 'save: Sana on, limit 1 question a day');
  PERFORM pg_temp.expect(pg_temp.voice(2, 'tts', 'en'), 'You''ve reached today''s limit of 1 questions. It resets at midnight.', 'voice: at most twice the daily limit of voice calls (2 used)');
  PERFORM pg_temp.ok(pg_temp.voice(4, 'stt', 'en'), 'voice: another user still has calls left');
  UPDATE erp.sana_usage SET questions = 1, voice_calls = 0 WHERE user_id = pg_temp.u(4) AND day = erp._sana_today();
  PERFORM pg_temp.expect(pg_temp.voice(4, 'stt', 'en'), 'You''ve reached today''s limit of 1 questions. It resets at midnight.', 'voice: refused once the questions of the day are used up');
  PERFORM pg_temp.ok(pg_temp.save(1, '{"daily_limit": 200}'), 'save: limit back to 200');

  -- ---------- sana_log: provider, model and token counts ----------
  SELECT count(*) INTO n0 FROM erp.audit_log WHERE action = 'sana.ask';
  r := pg_temp.call(pg_temp.u(2), $q$SELECT erp.sana_log(NULL, 'ZZ99', 'en', 'open sales orders', 'There are 3.', '[{"tool":"sana_documents"}]', '[]', false, 'ai', 'text',
                                     NULL, false, 'gemini', 'gemini-2.5-flash', '{"in": 2400, "out": 61, "secret": 5, "bad": "x"}')$q$);
  PERFORM pg_temp.ok(r, 'log: AI answer with provider gemini, model and tokens');
  c1 := r ->> 'conversation_id'; m := (r ->> 'message_id')::bigint;
  PERFORM pg_temp.check((SELECT provider = 'gemini' AND model = 'gemini-2.5-flash' FROM erp.sana_message WHERE message_id = m), 'log: the answer row keeps provider and model');
  SELECT * INTO al FROM erp.audit_log WHERE action = 'sana.ask' ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.check(al.detail ->> 'provider' = 'gemini' AND al.detail ->> 'model' = 'gemini-2.5-flash' AND al.detail -> 'tokens' = '{"in": 2400, "out": 61}'::jsonb
                        AND NOT (al.detail::text ~ 'open sales orders'), 'log: audit has provider, model and only in/out token counts (never the question)', al.detail::text);
  r := pg_temp.call(pg_temp.u(2), $q$SELECT erp.sana_log(NULL, 'ZZ99', 'en', 'q', 'a', '[]', '[]', false, 'ai', 'text', NULL, false, 'anthropic', 'claude-sonnet-5-5', NULL)$q$);
  PERFORM pg_temp.ok(r, 'log: the Anthropic fallback is accepted');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), $q$SELECT erp.sana_log(NULL, 'ZZ99', 'en', 'q', 'a', '[]', '[]', false, 'ai', 'text', NULL, false, 'openai', 'x', NULL)$q$),
    'Provider must be gemini or anthropic.', 'log: unknown provider refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), $q$SELECT erp.sana_log(NULL, 'ZZ99', 'en', 'q', 'a', '[]', '[]', false, 'ai', 'text', NULL, false, 'gemini', 'x y; drop', NULL)$q$),
    'Model names use letters, digits and . _ : / - only (up to 80).', 'log: bad model name refused');
  r := pg_temp.call(pg_temp.u(2), $q$SELECT erp.sana_log(NULL, 'ZZ99', 'en', 'q', 'a', '[]', '[]', false, 'basic', 'text', NULL, false)$q$);
  PERFORM pg_temp.ok(r, 'log: the 12-argument call of S1 still works (basic mode, provider NULL)');
  SELECT * INTO al FROM erp.audit_log WHERE action = 'sana.ask' ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.check(al.detail -> 'provider' = 'null'::jsonb AND al.detail -> 'tokens' = 'null'::jsonb, 'log: basic mode audits provider NULL', al.detail::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE action = 'sana.ask') = n0 + 3, 'log: one audit row per logged answer');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'erp' AND p.proname = 'sana_log') = 1,
                        'log: one sana_log function (the 12-argument version is replaced, no ambiguous overload)');

  -- ---------- health and grants ----------
  PERFORM pg_temp.check((SELECT count(*) FROM erp._health_files()) = 25 AND EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '37_sana_gemini.sql' AND object = 'sana_voice_use'),
                        'system health lists 37_sana_gemini.sql (25 files)');
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.system_health()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'files') f WHERE (f ->> 'file' = '37_sana_gemini.sql' OR f ->> 'file_name' = '37_sana_gemini.sql')),
                        'system health shows the file as present', left((r -> 'files')::text, 200));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.prosecdef AND p.proname IN ('sana_status', 'sana_log', 'sana_voice_use', 'sana_setup', 'sana_settings_save')
                                       AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=erp, pg_temp%', false))),
                        'S2 SECURITY DEFINER functions: search_path erp, pg_temp; no anon execute');
  PERFORM pg_temp.check(has_function_privilege('authenticated', 'erp.sana_voice_use(varchar,text,text,numeric,text,text,boolean)', 'EXECUTE')
                        AND has_function_privilege('authenticated', 'erp.sana_log(uuid,varchar,text,text,text,jsonb,jsonb,boolean,text,text,jsonb,boolean,text,text,jsonb)', 'EXECUTE'),
                        'signed-in users may call sana_voice_use and sana_log (each checks the user itself)');
  PERFORM pg_temp.check(NOT has_table_privilege('authenticated', 'erp.sana_settings', 'UPDATE') AND NOT has_table_privilege('authenticated', 'erp.sana_usage', 'INSERT'),
                        'no direct write grants on sana_settings / sana_usage');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM s2_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM s2_result;
ROLLBACK;
