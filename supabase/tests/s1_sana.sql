-- S1 · Sana: status, logging, daily limit, private history, delete own conversation, feedback, admin settings and usage
-- (counts only), A10 ai_setting migration, system health, grants. Role matrix of the tools: sana_roles.sql.
-- LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql). Run on a FRESH rebuild (sql-order.txt incl. 36_sana.sql).
-- One transaction, rolled back. Prints PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE s1_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON s1_result TO authenticated;

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
  INSERT INTO s1_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
CREATE FUNCTION pg_temp.log(n integer, conv text, q text, denied boolean DEFAULT false, via text DEFAULT 'text', mode text DEFAULT 'basic', ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(pg_temp.u(n), format('SELECT erp.sana_log(%s, %L, %L, %L, %L, %L::jsonb, %L::jsonb, %L::boolean, %L, %L, %L::jsonb, false)',
    coalesce(quote_literal(conv) || '::uuid', 'NULL'), 'ZZ99', 'en', q, 'answer to ' || q, '[{"tool":"sana_documents","input":{"kind":"sales_order"}}]',
    '[{"label":"Open list","link":"/docs/sales_order"}]', denied, mode, via, ctx))
$$;

-- fresh counters for the test users (rolled back)
DELETE FROM erp.sana_usage WHERE user_id IN (pg_temp.u(1), pg_temp.u(2), pg_temp.u(4), pg_temp.u(5), pg_temp.u(23));
DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99';

DO $$
DECLARE r jsonb; r2 jsonb; c1 text; c2 text; m1 bigint; n integer; al erp.audit_log;
BEGIN
  -- ---------- status ----------
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'enabled')::boolean AND (r ->> 'voice_enabled')::boolean AND (r ->> 'daily_limit')::int = 200 AND (r ->> 'used')::int = 0
                        AND jsonb_array_length(r -> 'languages') = 11, 'status: no settings row = on, voice on, 200 a day, 11 languages', r::text);
  r := pg_temp.call(pg_temp.u(3), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check(r = '{"enabled": false, "profile": false}'::jsonb, 'status: no profile = not available', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''AE01'')');
  PERFORM pg_temp.check((r ->> 'company') = 'ZZ99', 'status: a company the user cannot see falls back to the home company', r::text);

  -- ---------- log: conversation, messages, ids, audit without question text ----------
  r := pg_temp.log(2, NULL, 'How many open sales orders?', false, 'voice', 'basic', '{"type":"document","kind":"sales_order","company":"ZZ99","number":"SO-1","evil":"x"}');
  PERFORM pg_temp.ok(r, 'log: sales logs a question');
  c1 := r ->> 'conversation_id'; m1 := (r ->> 'message_id')::bigint;
  PERFORM pg_temp.check(c1 IS NOT NULL AND m1 > (r ->> 'question_id')::bigint, 'log: returns conversation, question and answer ids', r::text);
  SELECT * INTO al FROM erp.audit_log WHERE action = 'sana.ask' AND object_ref = c1 ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.check(al.actor = 'ai:sana' AND al.detail ->> 'via' = 'voice' AND al.detail ->> 'mode' = 'basic' AND al.detail -> 'tools' = '["sana_documents"]'::jsonb
                        AND al.detail ->> 'context' = 'document' AND al.detail::text !~ 'open sales orders', 'log: audit row has tools, mode, voice, context type — not the question', al.detail::text);
  PERFORM pg_temp.check((SELECT context FROM erp.sana_message WHERE message_id = (r ->> 'question_id')::bigint) = '{"type":"document","kind":"sales_order","company":"ZZ99","number":"SO-1"}'::jsonb,
                        'log: page context keeps only the known keys', (SELECT context::text FROM erp.sana_message WHERE message_id = (r ->> 'question_id')::bigint));
  r := pg_temp.log(2, c1, 'And the overdue invoices?');
  PERFORM pg_temp.check(r ->> 'conversation_id' = c1, 'log: the next question continues the conversation', r::text);
  r := pg_temp.log(4, c1, 'finance writes into the sales user''s conversation');
  PERFORM pg_temp.check(r ->> 'conversation_id' <> c1, 'log: someone else''s conversation id starts a new conversation of their own', r::text);
  c2 := r ->> 'conversation_id';
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'used')::int = 2, 'status: used counts today''s questions', r::text);
  PERFORM pg_temp.check((SELECT questions = 2 AND voice = 1 AND basic = 2 FROM erp.sana_usage WHERE user_id = pg_temp.u(2) AND company_code = 'ZZ99'),
                        'usage: counters per company, user and day', (SELECT row_to_json(x)::text FROM erp.sana_usage x WHERE user_id = pg_temp.u(2)));

  -- refusals
  PERFORM pg_temp.expect(pg_temp.log(3, NULL, 'q'), 'You need a Southfield profile to use Sana.', 'log: no profile refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_log(NULL, ''AE01'', ''en'', ''q'', ''a'', ''[]'', ''[]'', false, ''basic'', ''text'')'),
                         'You don''t have access to company AE01.', 'log: a company the user cannot see is refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_log(NULL, ''ZZ99'', ''en'', ''  '', ''a'', ''[]'', ''[]'', false, ''basic'', ''text'')'),
                         'Type or say a question first.', 'log: empty question refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_log(NULL, ''ZZ99'', ''en'', ''q'', ''a'', ''[]'', ''[]'', false, ''gpt'', ''text'')'),
                         'Mode must be ai or basic, and via text or voice.', 'log: unknown mode refused');
  PERFORM pg_temp.check(NOT has_table_privilege('authenticated', 'erp.sana_message', 'INSERT') AND NOT has_table_privilege('authenticated', 'erp.sana_usage', 'SELECT')
                        AND NOT has_table_privilege('authenticated', 'erp.sana_feedback', 'SELECT') AND NOT has_table_privilege('authenticated', 'erp.sana_settings', 'UPDATE'),
                        'no direct writes; usage and feedback tables not readable');

  -- ---------- privacy and history ----------
  r := pg_temp.call(pg_temp.u(4), 'SELECT to_jsonb(count(*)) FROM erp.sana_message WHERE content LIKE ''How many open sales orders%''');
  PERFORM pg_temp.check(r = '0'::jsonb, 'privacy: finance reads none of the sales user''s messages (RLS)', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT to_jsonb(count(*)) FROM erp.sana_message WHERE content LIKE ''How many open sales orders%''');
  PERFORM pg_temp.check(r = '1'::jsonb, 'privacy: the sales user reads their own (RLS)', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_conversations()');
  PERFORM pg_temp.check(jsonb_array_length(r) = 1 AND r -> 0 ->> 'title' = 'How many open sales orders?' AND (r -> 0 ->> 'messages')::int = 4,
                        'history: my conversations with title and message count', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_messages(%L)', c1));
  PERFORM pg_temp.check(jsonb_array_length(r -> 'messages') = 4 AND r -> 'messages' -> 0 ->> 'role' = 'user' AND r -> 'messages' -> 1 ->> 'mode' = 'basic',
                        'history: messages of my conversation in order', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_messages(%L)', c1)), 'Conversation not found.', 'history: someone else''s conversation = not found');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_messages(%L)', gen_random_uuid())), 'Conversation not found.', 'history: a missing conversation = the same answer');

  -- ---------- feedback ----------
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_feedback_set(%s, 1, ''good'')', m1));
  PERFORM pg_temp.check((r ->> 'feedback')::int = 1, 'feedback: 👍 on my answer', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_feedback_set(%s, -1)', m1));
  PERFORM pg_temp.check((r ->> 'feedback')::int = -1 AND (SELECT value FROM erp.sana_feedback WHERE message_id = m1) = -1, 'feedback: 👎 replaces it', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_messages(%L)', c1));
  PERFORM pg_temp.check((r -> 'messages' -> 1 ->> 'feedback')::int = -1, 'feedback: shown with the message in history', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_feedback_set(%s, 1)', m1)), 'Answer not found.', 'feedback: not on someone else''s answer');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_feedback_set(%s, 1)', m1 - 1)), 'Answer not found.', 'feedback: not on a question');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_feedback_set(%s, 5)', m1)), 'Feedback is 1 (helpful) or -1 (not helpful).', 'feedback: only 1 / -1');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_feedback_set(%s, 1, %L)', m1, repeat('x', 501))), 'Keep the note under 500 characters.', 'feedback: note length');

  -- ---------- admin: settings and usage (counts only) ----------
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_setup(''ZZ99'')');
  PERFORM pg_temp.check((r -> 'usage' -> 'total_30_days' ->> 'questions')::int = 3 AND (r -> 'usage' -> 'total_30_days' ->> 'voice')::int = 1
                        AND (r -> 'usage' -> 'feedback' ->> 'down')::int = 1 AND (r ->> 'can_edit')::boolean AND NOT (r::text ~ 'open sales orders'),
                        'setup: admin sees counts (questions, voice, feedback) and never the question text', left(r::text, 300));
  r := pg_temp.call(pg_temp.u(23), 'SELECT erp.sana_setup(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'error') IS NULL AND NOT (r ->> 'can_edit')::boolean, 'setup: IT (Administration read-only) opens it read-only', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_setup(''ZZ99'')'), 'Only the system admin, IT and the owner can open Administration.', 'setup: sales refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(23), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"enabled": false}'')'),
                         'Only a system admin with full Administration access can change this.', 'save: IT (read-only) refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"anthropic_api_key": "sk-x"}'')'),
                         CASE WHEN EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '37_sana_gemini.sql')
                           THEN 'API keys are never stored in the database. IT sets the Supabase secret GEMINI_API_KEY; only the Sana server functions read it.'
                           ELSE 'API keys are never stored in the database. IT sets the Supabase secret ANTHROPIC_API_KEY; only the sana server function reads it.' END, 'save: keys refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"model": "x"}'')'), 'Unknown Sana setting model.', 'save: unknown setting refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"daily_limit": 6000}'')'),
                         'Enter a daily limit from 0 to 5,000 questions per person.', 'save: daily limit range');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"languages": []}'')'), 'Choose at least one language.', 'save: at least one language');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"languages": ["en","de"]}'')'),
                         'Sana supports these languages: en, ar, hi, ur, ml, ta, bn, tl, zh, fr, ru.', 'save: unknown language refused');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"enabled": "maybe"}'')'),
                         'Sana on/off and voice on/off must be yes or no.', 'save: on/off must be yes or no');
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''AE01'', ''{"enabled": false}'')'),
                         'You don''t have access to company AE01.', 'save: a company the admin cannot see');
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"daily_limit": 3, "voice_enabled": false, "languages": ["ar","en","ar"]}'')');
  PERFORM pg_temp.check((r ->> 'daily_limit')::int = 3 AND NOT (r ->> 'voice_enabled')::boolean AND r -> 'languages' = '["en", "ar"]'::jsonb AND (r ->> 'enabled')::boolean,
                        'save: limit, voice off, languages (deduplicated, in the standard order); left-out keys keep their value', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana_settings_save' AND company_code = 'ZZ99' AND detail -> 'to' ->> 'daily_limit' = '3'),
                        'save: audited with from / to');
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check(NOT (r ->> 'voice_enabled')::boolean AND (r ->> 'daily_limit')::int = 3 AND r -> 'languages' = '["en", "ar"]'::jsonb, 'status: follows the saved settings', r::text);
  r := pg_temp.log(2, c1, 'third question today');
  PERFORM pg_temp.ok(r, 'limit: the 3rd question of the day is allowed');
  PERFORM pg_temp.expect(pg_temp.log(2, c1, 'fourth question'), 'You''ve reached today''s limit of 3 questions. It resets at midnight.', 'limit: the 4th is refused');

  -- ---------- delete my conversation ----------
  PERFORM pg_temp.expect(pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_delete_conversation(%L)', c1)), 'Conversation not found.', 'delete: not someone else''s');
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_delete_conversation(%L)', c1));
  PERFORM pg_temp.check((r ->> 'deleted')::boolean AND (r ->> 'messages')::int = 6 AND NOT EXISTS (SELECT 1 FROM erp.sana_message WHERE conversation_id = c1::uuid)
                        AND NOT EXISTS (SELECT 1 FROM erp.sana_feedback WHERE message_id = m1), 'delete: my conversation, its messages and feedback are gone', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana.delete_conversation' AND object_ref = c1 AND detail = '{"messages": 6}'::jsonb), 'delete: audited without content');
  PERFORM pg_temp.expect(pg_temp.log(2, NULL, 'after delete'), 'You''ve reached today''s limit of 3 questions. It resets at midnight.', 'delete: does not reset today''s limit');

  -- ---------- switched off ----------
  PERFORM pg_temp.ok(pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_settings_save(''ZZ99'', ''{"enabled": false}'')'), 'save: switch Sana off for ZZ99');
  PERFORM pg_temp.expect(pg_temp.log(4, c2, 'q'), 'Sana is switched off for ZZ99. Ask your system admin.', 'log: refused while switched off');
  r := pg_temp.call(pg_temp.u(4), 'SELECT erp.sana_status(''ZZ99'')');
  PERFORM pg_temp.check(NOT (r ->> 'enabled')::boolean, 'status: says off', r::text);

  -- ---------- A10 ai_setting → sana_settings (runs once per company, never overwrites) ----------
  DELETE FROM erp.sana_settings WHERE company_code = 'ZZ99';
  INSERT INTO erp.ai_setting (company_code, enabled) VALUES ('ZZ99', false) ON CONFLICT (company_code) DO UPDATE SET enabled = false;
  INSERT INTO erp.sana_settings (company_code, enabled, updated_by, updated_at)
  SELECT a.company_code, a.enabled, a.updated_by, a.updated_at FROM erp.ai_setting a ON CONFLICT (company_code) DO NOTHING;   -- the statement in 36
  PERFORM pg_temp.check((SELECT NOT enabled AND daily_limit = 200 FROM erp.sana_settings WHERE company_code = 'ZZ99'), 'migration: the A10 on/off choice carries over');
  UPDATE erp.ai_setting SET enabled = true WHERE company_code = 'ZZ99';
  INSERT INTO erp.sana_settings (company_code, enabled, updated_by, updated_at)
  SELECT a.company_code, a.enabled, a.updated_by, a.updated_at FROM erp.ai_setting a ON CONFLICT (company_code) DO NOTHING;
  PERFORM pg_temp.check((SELECT NOT enabled FROM erp.sana_settings WHERE company_code = 'ZZ99'), 'migration: re-running never overwrites Sana''s own setting');

  -- ---------- health, grants, IT rule ----------
  PERFORM pg_temp.check((SELECT count(*) FROM erp._health_files()) = CASE WHEN to_regprocedure('erp.sana_voice_use(varchar,text,text,numeric,text,text,boolean)') IS NOT NULL THEN 25 ELSE 24 END
                          AND EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '36_sana.sql' AND object = 'sana_settings_save'),
                        'system health lists 36_sana.sql (24 files, 25 with S2)');
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.system_health()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'files') f WHERE f ->> 'file' = '36_sana.sql' OR f ->> 'file_name' = '36_sana.sql'),
                        'system health shows the file', left((r -> 'files')::text, 200));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.prosecdef AND (p.proname LIKE 'sana%' OR p.proname LIKE '\_sana%')
                                       AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=erp, pg_temp%', false))),
                        'SECURITY DEFINER Sana functions: search_path set, no anon execute');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.proname LIKE 'sana%' AND has_function_privilege('anon', p.oid, 'EXECUTE')),
                        'no Sana function is callable without signing in');
  PERFORM pg_temp.check(NOT has_function_privilege('authenticated', 'erp._sana_company(varchar)', 'EXECUTE'), 'internal helper _sana_company not callable by users');
  PERFORM pg_temp.check((SELECT bool_and(NOT p.prosecdef) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                          WHERE n.nspname = 'erp' AND p.proname IN ('sana_find','sana_document','sana_documents','sana_sales_summary','sana_purchase_summary',
                            'sana_inventory_summary','sana_partner','sana_stock','sana_receivables','sana_payables','sana_finance_summary','sana_banking',
                            'sana_alerts','sana_my_employee','sana_people','sana_my_approvals','sana_whoami')),
                        'every Sana tool runs with the user''s own rights (SECURITY INVOKER)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.proname LIKE 'sana\_%' AND NOT p.prosecdef AND pg_get_functiondef(p.oid) ~* '\m(insert|update|delete)\M'),
                        'no Sana tool writes data');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM s1_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM s1_result;
ROLLBACK;
