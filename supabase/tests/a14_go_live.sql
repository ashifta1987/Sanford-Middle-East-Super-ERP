-- A14 · Go-live checklist, hypercare issues, release log and system health tests.
-- LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql; fixture company ZZ98, no real data).
-- Run on a FRESH rebuild (base.txt incl. 29_go_live.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a14_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a14_result TO authenticated;

CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a14_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.step(p_user uuid, p_step integer, p_done boolean, p_note text DEFAULT NULL, p_ev text DEFAULT NULL, p_company text DEFAULT 'ZZ99')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.go_live_step_set(%L, %s, %L, %L, %L)', p_company, p_step, p_done, p_note, p_ev))
$$;
CREATE FUNCTION pg_temp.st(p_user uuid, p_step integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT (SELECT s FROM jsonb_array_elements(pg_temp.call(p_user, $q$SELECT erp.go_live_checklist('ZZ99')$q$)->'steps') s WHERE (s->>'step')::int = p_step)
$$;

-- fixture company ZZ98 (not visible to the admin) and a second admin-capable user for the "other user" rule
INSERT INTO sap._company (company_code, legal_name, country, currency, licence_type, sap_schema, in_scope)
VALUES ('ZZ98', 'Test Fixture Ninety-Eight (test data)', 'AE', 'AED', 'free_zone', 'SBO_ZZ98', false),
       ('ZZ99', 'Sample Trading LLC (test data)', 'AE', 'AED', 'free_zone', 'SBO_ZZ99', false) ON CONFLICT DO NOTHING;
INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema)
VALUES ('ZZ98', 'Test Fixture Ninety-Eight (test data)', 'ZZ98', 'AE', 'AED', 'free_zone', 'SBO_ZZ98') ON CONFLICT DO NOTHING;
-- clean slate for ZZ99 (e2e runs on the running DB may have left rows; this is all rolled back)
DELETE FROM erp.company_cutover WHERE company_code = 'ZZ99';
DELETE FROM erp.go_live_issue WHERE company_code = 'ZZ99';
DELETE FROM erp.go_live_step WHERE company_code = 'ZZ99';
UPDATE erp.migration_run SET status = 'needs_review' WHERE company_code = 'ZZ99' AND status = 'signed_off';
UPDATE erp.user_invite SET state = 'cancelled' WHERE company_code = 'ZZ99' AND state IN ('pending', 'sent') AND user_id IS NULL;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  r jsonb; v_run uuid; v_inv bigint; v_issue bigint; v_n integer; v_rel bigint;
BEGIN
  -- ---------- read access ----------
  r := pg_temp.call(sales, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.expect(r, 'Only the system admin, IT and the owner can open Administration.', 'sales user cannot open the go-live overview');
  PERFORM pg_temp.check(r->>'error' = '42501', 'refusal is 42501', r->>'error');
  r := pg_temp.call(fin, $q$SELECT erp.go_live_checklist('ZZ99')$q$);
  PERFORM pg_temp.expect(r, 'Only the system admin, IT and the owner can open Administration.', 'finance user cannot open the checklist');
  r := pg_temp.call(nobody, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.expect(r, 'Your account has no active profile. Ask the system admin.', 'user without a profile is refused');
  r := pg_temp.call(NULL, 'SELECT erp.go_live_overview()', 'anon');
  PERFORM pg_temp.check(r->>'error' = '42501', 'anon cannot call go_live_overview', r::text);
  r := pg_temp.call(admin, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.check(jsonb_typeof(r) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(r) e WHERE e->>'company_code' = 'ZZ99' AND (e->>'steps_done')::int = 0 AND (e->>'steps_total')::int = 7),
                        'admin overview lists ZZ99 with 0 of 7 steps', left(r::text, 300));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) e WHERE e->>'company_code' = 'ZZ98'), 'overview hides companies the user cannot see');
  r := pg_temp.call(admin, $q$SELECT erp.go_live_checklist('ZZ98')$q$);
  PERFORM pg_temp.expect(r, 'You don''t have access to company ZZ98.', 'checklist of an unseen company is refused');
  r := pg_temp.call(owner, $q$SELECT erp.go_live_checklist('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND jsonb_array_length(r->'steps') = 7 AND (r->>'can_write')::boolean = false AND (r->>'can_go_live')::boolean = true,
                        'owner reads the checklist (7 steps, read-only, may go live)', left(r::text, 300));
  r := pg_temp.call(admin, $q$SELECT erp.go_live_checklist('ZZ99')$q$);
  PERFORM pg_temp.check((r->>'can_write')::boolean AND (r->>'live')::boolean = false AND (r->'users'->>'active')::int >= 2,
                        'admin checklist: can write, not live, users counted', left(r::text, 200));
  PERFORM pg_temp.check((SELECT bool_and((s->>'auto')::boolean = (s->>'step')::int IN (1, 6)) FROM jsonb_array_elements(r->'steps') s),
                        'steps 1 and 6 are marked automatic');

  -- ---------- write access and step rules ----------
  r := pg_temp.step(owner, 2, true, NULL, 'email');
  PERFORM pg_temp.expect(r, 'Only a system admin with full Administration access can change this.', 'owner cannot tick a step');
  r := pg_temp.step(sales, 2, true, NULL, 'email');
  PERFORM pg_temp.expect(r, 'Only a system admin with full Administration access can change this.', 'sales user cannot tick a step');
  r := pg_temp.step(admin, 2, true, NULL, 'email', 'ZZ98');
  PERFORM pg_temp.expect(r, 'You don''t have access to company ZZ98.', 'admin cannot tick a step of an unseen company');
  r := pg_temp.step(admin, 1, true);
  PERFORM pg_temp.expect(r, 'Step 1 is worked out by the system and can''t be ticked by hand.', 'step 1 cannot be ticked by hand');
  r := pg_temp.step(admin, 6, true);
  PERFORM pg_temp.expect(r, 'Step 6 is worked out by the system and can''t be ticked by hand.', 'step 6 cannot be ticked by hand');
  r := pg_temp.step(admin, 9, true);
  PERFORM pg_temp.expect(r, 'There is no step 9. The checklist has steps 1 to 7.', 'unknown step is refused');
  r := pg_temp.step(admin, 2, true, NULL, 'email 10 Nov 2026');
  PERFORM pg_temp.expect(r, 'Finish step 1 first: Migration run signed off by Finance, IT and Business.', 'step 2 waits for a signed-off migration run');

  -- signed-off run (fixture; the console's sign-off flow is tested in 13/14)
  INSERT INTO erp.migration_run (company_code, kind, status, created_at, finished_at) VALUES ('ZZ99', 'full', 'signed_off', now(), now()) RETURNING run_id INTO v_run;
  INSERT INTO erp.migration_signoff (run_id, role, signed_by, decision) VALUES
    (v_run, 'finance', fin, 'approved'), (v_run, 'it', admin, 'approved'), (v_run, 'business', owner, 'approved');
  r := pg_temp.st(admin, 1);
  PERFORM pg_temp.check((r->>'done')::boolean, 'step 1 is done once a run is signed off', left(r::text, 200));
  r := pg_temp.call(admin, $q$SELECT erp.go_live_checklist('ZZ99')->'run'$q$);
  PERFORM pg_temp.check(r->>'status' = 'signed_off' AND jsonb_array_length(r->'signoffs') = 3, 'checklist shows the signed-off run and its 3 sign-offs', left(r::text, 300));

  r := pg_temp.step(admin, 3, true);
  PERFORM pg_temp.expect(r, 'Finish step 2 first: Ashif''s written approval to import production data.', 'steps go in order (3 before 2 refused)');
  r := pg_temp.step(admin, 2, true, 'ok', '  ');
  PERFORM pg_temp.expect(r, 'Add where Ashif''s written approval is kept (for example the email date and subject).', 'step 2 needs the approval reference');
  r := pg_temp.step(admin, 2, true, 'Approval for ZZ99 sample', 'Email 10 Nov 2026 "ZZ99 go-live approval"');
  PERFORM pg_temp.ok(r, 'admin records step 2 with the approval reference');
  r := pg_temp.step(admin, 2, true, NULL, 'again');
  PERFORM pg_temp.expect(r, 'Step 2 is already done.', 'a done step cannot be ticked again');
  r := pg_temp.st(admin, 2);
  PERFORM pg_temp.check((r->>'done')::boolean AND r->>'done_by' = 'QA Admin' AND r->>'evidence' LIKE 'Email 10 Nov%', 'step 2 shows who, when and the reference', left(r::text, 300));

  -- go-live refused while the checklist is incomplete
  r := pg_temp.call(owner, format('SELECT to_jsonb(erp.company_go_live(%L, %L))', 'ZZ99', v_run));
  PERFORM pg_temp.expect(r, 'Finish the go-live checklist first: step 3 (Users invited, positions and limits set, test sign-in done) is not done.',
                         'go-live is refused until the checklist is complete');
  r := pg_temp.call(fin, format('SELECT to_jsonb(erp.company_go_live(%L, %L))', 'ZZ99', v_run));
  PERFORM pg_temp.expect(r, 'only the business (CFO) signer can take a company live', 'only the CFO signer can go live (earlier rule kept)');

  -- step 3: pending invitations block it
  INSERT INTO erp.user_invite (email, display_name, position_code, company_code, companies, invited_by)
  VALUES ('qa.newhead@sample.test', 'QA New Head', 'QA_SALES', 'ZZ99', '{ZZ99}', admin) RETURNING invite_id INTO v_inv;
  r := pg_temp.step(admin, 3, true);
  PERFORM pg_temp.expect(r, '1 invitation(s) for ZZ99 are still waiting to be accepted. Wait for them or cancel them first.', 'step 3 waits for open invitations');
  UPDATE erp.user_invite SET state = 'cancelled', cancelled_at = now() WHERE invite_id = v_inv;
  r := pg_temp.step(admin, 3, true, 'Department heads signed in on 10 Nov');
  PERFORM pg_temp.ok(r, 'admin records step 3');
  r := pg_temp.step(admin, 4, true, 'Opening TB matches SAP');
  PERFORM pg_temp.ok(r, 'admin records step 4');
  r := pg_temp.step(admin, 5, true, 'SAP frozen');
  PERFORM pg_temp.expect(r, 'Add the final backup reference (backup name or time) before marking this step done.', 'step 5 needs the backup reference');
  r := pg_temp.step(admin, 5, true, 'SAP frozen 18:00', 'SBO_ZZ99_final_2026-11-10.bak');
  PERFORM pg_temp.ok(r, 'admin records step 5');

  -- reopen rules
  r := pg_temp.step(admin, 4, false, '  ');
  PERFORM pg_temp.expect(r, 'Say why this step is being reopened.', 'reopening needs a reason');
  r := pg_temp.step(admin, 4, false, 'Difference found');
  PERFORM pg_temp.expect(r, 'Reopen step 5 first: it comes after this one.', 'later steps must be reopened first');
  r := pg_temp.step(admin, 7, false, 'x');
  PERFORM pg_temp.expect(r, 'Step 7 is not done yet.', 'a step that is not done cannot be reopened');
  r := pg_temp.step(admin, 5, false, 'Backup file was incomplete');
  PERFORM pg_temp.ok(r, 'admin reopens step 5 with a reason');
  r := pg_temp.st(admin, 5);
  PERFORM pg_temp.check((r->>'done')::boolean = false AND r->>'note' = 'Backup file was incomplete', 'reopened step shows the reason', left(r::text, 200));
  r := pg_temp.step(admin, 5, true, 'SAP frozen 19:00', 'SBO_ZZ99_final_2026-11-10_2.bak');
  PERFORM pg_temp.ok(r, 'admin records step 5 again');

  -- hypercare before go-live
  r := pg_temp.step(admin, 7, true, 'done');
  PERFORM pg_temp.expect(r, 'Hypercare starts at go-live. ZZ99 is not live yet.', 'step 7 needs the company to be live');
  r := pg_temp.call(admin, $q$SELECT erp.go_live_issue_save('ZZ99', '{"title":"Invoice print shows old logo"}')$q$);
  PERFORM pg_temp.expect(r, 'Hypercare issues can be logged once ZZ99 is live. Before that, use the migration issue list.', 'issues need a live company');

  -- go live (CFO)
  r := pg_temp.call(owner, format('SELECT to_jsonb(erp.company_go_live(%L, %L))', 'ZZ99', v_run));
  PERFORM pg_temp.ok(r, 'CFO takes ZZ99 live once steps 1–5 are done');
  r := pg_temp.call(owner, format('SELECT to_jsonb(erp.company_go_live(%L, %L))', 'ZZ99', v_run));
  PERFORM pg_temp.expect(r, 'company ZZ99 is already live', 'second go-live refused (earlier rule kept)');
  r := pg_temp.st(admin, 6);
  PERFORM pg_temp.check((r->>'done')::boolean AND r->>'done_by' = 'QA Owner', 'step 6 is done and shows who took the company live', left(r::text, 200));
  r := pg_temp.call(admin, $q$SELECT erp.go_live_checklist('ZZ99')$q$);
  PERFORM pg_temp.check((r->>'live')::boolean AND (r->>'hypercare_until')::timestamptz = (r->>'go_live_at')::timestamptz + interval '14 days',
                        'hypercare runs 14 days from go-live', (r->>'go_live_at') || ' → ' || (r->>'hypercare_until'));

  -- locked after go-live
  r := pg_temp.step(admin, 5, false, 'try');
  PERFORM pg_temp.expect(r, 'ZZ99 is already live, so steps before go-live can no longer change.', 'steps 2–5 lock at go-live');
  r := pg_temp.step(admin, 7, true, 'done');
  PERFORM pg_temp.expect(r, 'Hypercare runs for 2 weeks after go-live, until ' || to_char((now() + interval '14 days') AT TIME ZONE 'Asia/Dubai', 'DD Mon YYYY') || '.',
                         'step 7 waits 2 weeks');

  -- hypercare issues
  r := pg_temp.call(admin, $q$SELECT erp.go_live_issue_save('ZZ99', '{"title":"  "}')$q$);
  PERFORM pg_temp.expect(r, 'Describe the issue in a few words.', 'issue needs a title');
  r := pg_temp.call(admin, $q$SELECT erp.go_live_issue_save('ZZ99', '{"title":"x","severity":"high"}')$q$);
  PERFORM pg_temp.expect(r, 'Severity must be critical or normal.', 'issue severity is checked');
  r := pg_temp.call(owner, $q$SELECT erp.go_live_issue_save('ZZ99', '{"title":"x"}')$q$);
  PERFORM pg_temp.expect(r, 'Only a system admin with full Administration access can change this.', 'owner cannot log issues');
  r := pg_temp.call(admin, $q$SELECT erp.go_live_issue_save('ZZ99', '{"title":"Invoice print shows old logo","severity":"critical"}')$q$);
  PERFORM pg_temp.ok(r, 'admin logs a hypercare issue');
  v_issue := (r->>'issue_id')::bigint;
  r := pg_temp.call(admin, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.check((SELECT (e->>'open_issues')::int FROM jsonb_array_elements(r) e WHERE e->>'company_code' = 'ZZ99') = 1
                        AND (SELECT (e->>'steps_done')::int FROM jsonb_array_elements(r) e WHERE e->>'company_code' = 'ZZ99') = 6,
                        'overview: 6 of 7 steps, 1 open issue', left(r::text, 300));
  UPDATE erp.company_cutover SET go_live_at = now() - interval '15 days' WHERE company_code = 'ZZ99';   -- jump past hypercare
  r := pg_temp.step(admin, 7, true, 'done');
  PERFORM pg_temp.expect(r, 'Close the 1 open hypercare issue(s) first.', 'step 7 waits for open issues');
  r := pg_temp.call(admin, format('SELECT erp.go_live_issue_close(%L, %s, %L)', 'ZZ99', v_issue, ' '));
  PERFORM pg_temp.expect(r, 'Say how the issue was fixed.', 'closing needs a note');
  r := pg_temp.call(admin, format('SELECT erp.go_live_issue_close(%L, %s, %L)', 'ZZ99', 999999, 'x'));
  PERFORM pg_temp.expect(r, 'Issue 999999 was not found for ZZ99.', 'unknown issue');
  r := pg_temp.call(admin, format('SELECT erp.go_live_issue_close(%L, %s, %L)', 'ZZ99', v_issue, 'New logo uploaded in Company Details'));
  PERFORM pg_temp.ok(r, 'admin closes the issue');
  r := pg_temp.call(admin, format('SELECT erp.go_live_issue_close(%L, %s, %L)', 'ZZ99', v_issue, 'again'));
  PERFORM pg_temp.expect(r, 'Issue ' || v_issue || ' is already closed.', 'closed issue cannot be closed again');
  r := pg_temp.step(admin, 7, true, 'Two weeks clean, daily reconciliation all matched');
  PERFORM pg_temp.ok(r, 'admin closes hypercare (step 7)');
  r := pg_temp.call(admin, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.check((SELECT (e->>'steps_done')::int FROM jsonb_array_elements(r) e WHERE e->>'company_code' = 'ZZ99') = 7, 'overview: 7 of 7 steps');
  r := pg_temp.call(admin, $q$SELECT erp.go_live_checklist('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'activity') >= 9 AND jsonb_array_length(r->'issues') = 1 AND r->'issues'->0->>'status' = 'fixed',
                        'checklist shows activity and the fixed issue', jsonb_array_length(r->'activity')::text);

  -- audit and grants
  SELECT count(*) INTO v_n FROM erp.audit_log WHERE company_code = 'ZZ99' AND action IN ('go_live_step_done', 'go_live_step_reopened', 'go_live_issue_raised', 'go_live_issue_fixed', 'company_go_live');
  PERFORM pg_temp.check(v_n = 10, 'every change writes erp.audit_log', v_n || ' rows');
  r := pg_temp.call(admin, $q$SELECT to_jsonb(has_table_privilege('erp.go_live_step', 'INSERT') OR has_table_privilege('erp.go_live_step', 'SELECT')
                                     OR has_table_privilege('erp.go_live_issue', 'UPDATE') OR has_table_privilege('erp.schema_release', 'SELECT'))$q$);
  PERFORM pg_temp.check(r::text = 'false', 'no direct table grants on the new tables', r::text);
  r := pg_temp.call(admin, $q$SELECT to_jsonb(has_function_privilege('erp._gl_done(varchar)', 'EXECUTE'))$q$);
  PERFORM pg_temp.check(r::text = 'false', 'internal helpers are not callable', r::text);

  -- release log
  r := pg_temp.call(admin, $q$SELECT to_jsonb(erp.schema_release_record('29_go_live.sql', 'branch', 'QA'))$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'signed-in users cannot write the release log', r::text);
  BEGIN
    PERFORM erp.schema_release_record('go live.sql', 'branch', 'QA');
    PERFORM pg_temp.check(false, 'bad file name refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.check(SQLERRM = 'Give the SQL file name as it is in supabase/sql, for example 29_go_live.sql.', 'bad file name refused', SQLERRM);
  END;
  BEGIN
    PERFORM erp.schema_release_record('29_go_live.sql', 'prod', 'QA');
    PERFORM pg_temp.check(false, 'bad environment refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.check(SQLERRM = 'Environment must be local, branch, test or live.', 'bad environment refused', SQLERRM);
  END;
  BEGIN
    PERFORM erp.schema_release_record('29_go_live.sql', 'branch', ' ');
    PERFORM pg_temp.check(false, 'release needs a name');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.check(SQLERRM = 'Say who applied the file.', 'release needs who applied it', SQLERRM);
  END;
  v_rel := erp.schema_release_record('29_go_live.sql', 'local', 'QA test', 'a14 test');
  PERFORM pg_temp.check(v_rel IS NOT NULL, 'the SQL editor / service role records a release');

  -- system health
  r := pg_temp.call(sales, 'SELECT erp.system_health()');
  PERFORM pg_temp.expect(r, 'Only the system admin, IT and the owner can open Administration.', 'sales user cannot open system health');
  r := pg_temp.call(admin, 'SELECT erp.system_health()');
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->>'server_time' IS NOT NULL AND r->'database'->>'version' IS NOT NULL, 'admin reads system health', left(r::text, 200));
  PERFORM pg_temp.check((SELECT bool_and((f->>'present')::boolean) AND count(*) = CASE WHEN to_regclass('erp.sales_doc_request') IS NULL THEN 17 ELSE 18 END FROM jsonb_array_elements(r->'files') f), 'every SQL file 14–29 (14–30 with B1) is present');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'releases') x WHERE x->>'file' = '29_go_live.sql' AND x->>'applied_by' = 'QA test'),
                        'health lists the recorded release');
  PERFORM pg_temp.check((SELECT e->>'status' FROM jsonb_array_elements(r->'checks') e WHERE e->>'key' = 'tables_without_rls') = 'ok', 'every erp table has RLS on');
  PERFORM pg_temp.check((SELECT e->>'status' FROM jsonb_array_elements(r->'checks') e WHERE e->>'key' = 'definer_without_search_path') = 'ok',
                        'every SECURITY DEFINER function sets search_path');
  PERFORM pg_temp.check((SELECT e->>'status' FROM jsonb_array_elements(r->'checks') e WHERE e->>'key' = 'definer_anon_execute') = 'ok',
                        'no SECURITY DEFINER function is executable by anon', (SELECT (e->'items')::text FROM jsonb_array_elements(r->'checks') e WHERE e->>'key' = 'definer_anon_execute'));
  PERFORM pg_temp.check((SELECT (e->>'count')::int FROM jsonb_array_elements(r->'checks') e WHERE e->>'key' = 'direct_write_grants') = 4,
                        'direct write grants: only the 4 RLS-guarded ones from 12 (warning)',
                        (SELECT (e->'items')::text FROM jsonb_array_elements(r->'checks') e WHERE e->>'key' = 'direct_write_grants'));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'companies') c WHERE c->>'company_code' = 'ZZ99' AND (c->>'checklist_done')::int = 7)
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'companies') c WHERE c->>'company_code' = 'ZZ98'),
                        'health companies: only visible ones, with checklist progress');
  r := pg_temp.call(owner, 'SELECT erp.system_health()->''status''');
  PERFORM pg_temp.check(r->>'error' IS NULL, 'owner can read system health', r::text);
  PERFORM pg_temp.check(NOT has_function_privilege('anon', 'erp.has_module(text)', 'EXECUTE') AND NOT has_function_privilege('anon', 'erp._sync_keep_own()', 'EXECUTE'),
                        'anon can no longer execute erp.has_module or the sync trigger helpers');
  r := pg_temp.call(sales, $q$SELECT to_jsonb(erp.has_module('sales'))$q$);
  PERFORM pg_temp.check(r::text = 'true', 'signed-in users still use erp.has_module', r::text);
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a14_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a14_result;
ROLLBACK;
