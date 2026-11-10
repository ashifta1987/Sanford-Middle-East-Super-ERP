-- A10 · Administration tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run after base.txt (10–24 + test users) and 25_admin.sql, best on a FRESH rebuild. Everything happens inside one
-- transaction that is rolled back. Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a10_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a10_result TO authenticated, service_role;

-- Run one SQL expression as a user (RLS and grants apply) and return its jsonb result, or {error, message} if it raised.
CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL AND p_role <> 'service_role' THEN ''
                                                 ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
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
  INSERT INTO a10_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 160)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 200))
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  smgr   uuid := '00000000-0000-4000-8000-000000000007';
  finmgr uuid := '00000000-0000-4000-8000-000000000008';
  it     uuid := '00000000-0000-4000-8000-000000000023';
  newu   uuid := '00000000-0000-4000-8000-0000000000a1';
  r      jsonb;
  v_inv  bigint;
  v_rule bigint;
  v_req  bigint;
  d1     integer;
  d2     integer;
  big    jsonb := '[{"acct_code":"6200","debit":60000},{"acct_code":"1110","credit":60000}]';
  h      jsonb := '{"ref_date":"2026-11-09","memo":"A10 rule test"}';
  inv    jsonb := '{"email":"New.Person@Sample.test","display_name":"New Person","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"],"language":"ar"}';
  deny   text := 'Only a system admin with full Administration access can change this.';
BEGIN
  -- ---------- 1. A non-admin is refused everywhere ----------
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.admin_users()'), 'Only the system admin, IT and the owner can open Administration.', 'sales user cannot list users');
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.admin_positions()'), 'Only the system admin, IT and the owner can open Administration.', 'finance user cannot open the matrix');
  PERFORM pg_temp.expect(pg_temp.call(nobody, 'SELECT erp.admin_users()'), 'Your account has no active profile. Ask the system admin.', 'user without profile refused');
  PERFORM pg_temp.check((pg_temp.call(NULL, 'SELECT erp.admin_users()', 'anon'))->>'error' = '42501', 'anon cannot execute admin_users', '');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales, '{}')), deny, 'sales cannot save a user');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.admin_invite_create(%L::jsonb)', inv)), deny, 'sales cannot invite');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.position_access_save(''QA_SALES'', ''{"finance":"full"}''::jsonb)'), deny, 'sales cannot change the matrix');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.position_save(''QA_X'', ''X'', true)'), deny, 'sales cannot create a position');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"credit_limit","approver_position":"QA_SALES"}''::jsonb)'), deny, 'sales cannot add an approval rule');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.number_series_save(''ZZ99'', 17, ''SO-26-'', 99, 5, true)'), deny, 'sales cannot change numbering');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.company_details_submit(''ZZ99'', ''{"phone":"+971 4 000 0000"}''::jsonb, NULL)'), deny, 'sales cannot change company details');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"enabled":false}''::jsonb)'), deny, 'sales cannot change AI settings');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.fx_rate_save(''ZZ99'', ''2026-11-09'', ''USD'', 3.6725)'), 'Only Finance or a system admin with full access can enter exchange rates.', 'sales cannot enter rates');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.admin_setting_save(''ZZ99'', ''{}''::jsonb)'), deny, 'sales cannot change admin settings');
  -- IT reads, can't change
  PERFORM pg_temp.ok(pg_temp.call(it, 'SELECT erp.admin_users()'), 'IT can list users');
  PERFORM pg_temp.check((pg_temp.call(it, 'SELECT erp.admin_users()'))->>'can_write' = 'false', 'IT sees users read-only', '');
  PERFORM pg_temp.expect(pg_temp.call(it, 'SELECT erp.position_access_save(''QA_IT'', ''{"admin":"full"}''::jsonb)'), deny, 'IT cannot give itself Administration');
  PERFORM pg_temp.expect(pg_temp.call(it, format('SELECT erp.admin_invite_create(%L::jsonb)', inv)), deny, 'IT cannot invite');
  -- Owner reads (approves company details)
  PERFORM pg_temp.ok(pg_temp.call(owner, 'SELECT erp.company_details_info(''ZZ99'')'), 'owner can open company details');

  -- ---------- 2. Users ----------
  r := pg_temp.call(admin, 'SELECT erp.admin_users()');
  PERFORM pg_temp.check(jsonb_array_length(r->'users') >= 20 AND (r->>'can_write')::boolean, 'admin lists users with write access', (jsonb_array_length(r->'users'))::text);
  PERFORM pg_temp.check((SELECT bool_and(u ? 'last_sign_in_at') FROM jsonb_array_elements(r->'users') u), 'user list has last sign-in', '');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', admin,
    '{"display_name":"QA Admin","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"]}')),
    'You can''t change your own position. Ask another system admin.', 'admin cannot change own position');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', admin,
    '{"display_name":"QA Admin","position_code":"QA_ALL","company_code":"ZZ99","companies":["ZZ99"],"active":false}')),
    'You can''t deactivate your own account. Ask another system admin.', 'admin cannot deactivate self');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"NOPE","company_code":"ZZ99","companies":["ZZ99"]}')),
    'Position NOPE does not exist. Check the position code.', 'unknown position refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":[]}')),
    'Choose at least one company.', 'no company refused');
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type) VALUES ('ZZ98', 'Other test co', 'Other', 'AE', 'AED', 'mainland');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99","ZZ98"]}')),
    'You can only give access to companies you can see yourself. You don''t have ZZ98.', 'cannot grant a company the admin cannot see');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ98","companies":["ZZ99"]}')),
    'The home company ZZ98 must be one of the user''s companies.', 'home company must be in the list');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"],"emp_id":6}')),
    'Employee 6 is already linked to QA Staff (Faisal).', 'employee linked to another user refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"],"emp_id":99999}')),
    'Employee 99999 is not in ZZ99. Link an employee of the home company.', 'unknown employee refused');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"],"emp_id":1,"language":"ar"}')),
    'admin links an employee and sets Arabic');
  PERFORM pg_temp.check((SELECT emp_id = 1 AND language = 'ar' FROM erp.app_user WHERE user_id = sales), 'user change saved', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'user_save' AND object_ref = sales::text), 'user change audited', '');
  -- deactivate → loses everything on the next request
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.can_see(''ZZ99''))'))::text = 'true', 'sales sees ZZ99 while active', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"],"active":false}')), 'admin deactivates sales');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.can_see(''ZZ99''))'))::text = 'false', 'deactivated user sees no company', '');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.item'))::text = '0', 'deactivated user reads no items', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'user_deactivate' AND object_ref = sales::text), 'deactivation audited', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.admin_user_save(%L, %L::jsonb)', sales,
    '{"display_name":"QA Sales","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"],"active":true,"emp_id":null,"language":"en"}')), 'admin re-activates sales');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.can_see(''ZZ99''))'))::text = 'true', 're-activated user sees ZZ99 again', '');

  -- ---------- 3. Invite flow (test inbox = the service step the Edge Function runs) ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.admin_invite_create(''{"email":"bad","display_name":"X","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"]}''::jsonb)'),
    'Enter a valid email address, for example name@company.com.', 'invalid email refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.admin_invite_create(''{"email":"qa.sales@sample.test","display_name":"X","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"]}''::jsonb)'),
    'A user with qa.sales@sample.test already exists. Change that user instead.', 'existing user email refused');
  r := pg_temp.call(admin, format('SELECT erp.admin_invite_create(%L::jsonb)', inv));
  v_inv := (r->>'invite_id')::bigint;
  PERFORM pg_temp.check(v_inv IS NOT NULL AND r->>'email' = 'new.person@sample.test', 'admin creates an invitation (email lower-cased)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.admin_invite_create(%L::jsonb)', inv)),
    'An invitation to new.person@sample.test is already waiting. Cancel it first to send a new one.', 'duplicate invitation refused');
  PERFORM pg_temp.check((pg_temp.call(admin, format('SELECT erp.admin_invite_link(%s, %L)', v_inv, newu)))->>'error' = '42501', 'browser (authenticated) cannot link an invitation', '');
  PERFORM pg_temp.check((pg_temp.call(NULL, format('SELECT erp.admin_invite_link(%s, %L)', v_inv, newu), 'anon'))->>'error' = '42501', 'anon cannot link an invitation', '');
  r := pg_temp.call(NULL, format('SELECT erp.admin_invite_link(%s, %L)', v_inv, newu), 'service_role');
  PERFORM pg_temp.check(r->>'state' = 'sent', 'service role links the invitation (Edge Function step)', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = newu AND position_code = 'QA_SALES' AND language = 'ar' AND active)
                        AND EXISTS (SELECT 1 FROM erp.user_company WHERE user_id = newu AND company_code = 'ZZ99'), 'invited user gets profile and company', '');
  PERFORM pg_temp.check((pg_temp.call(newu, 'SELECT to_jsonb(erp.can_write(''sales''))'))::text = 'true', 'invited user has the position''s access', '');
  PERFORM pg_temp.expect(pg_temp.call(NULL, format('SELECT erp.admin_invite_link(%s, %L)', v_inv, newu), 'service_role'),
    'Invitation ' || v_inv || ' is not waiting to be sent.', 'invitation links only once');
  r := pg_temp.call(admin, 'SELECT erp.admin_invite_create(''{"email":"later@sample.test","display_name":"Later","position_code":"QA_SALES","company_code":"ZZ99","companies":["ZZ99"]}''::jsonb)');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.admin_invite_cancel(%s)', r->>'invite_id')), 'admin cancels a waiting invitation');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'user_invite_sent' AND actor = 'system:invite-user'), 'invite link audited', '');

  -- ---------- 4. Positions and the matrix ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_save(''bad code'', ''X'', true)'),
    'Use 2 to 30 capital letters, digits or _ for the position code, for example SALES_MGR.', 'bad position code refused');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.position_save(''QA_TMP'', ''Temp position'', true)'), 'admin creates a position');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_save(''QA_TMP'', ''Temp'', true)'), 'Position QA_TMP already exists.', 'duplicate position refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_delete(''QA_SALES'')'), 'Position QA_SALES still has 2 user(s). Move them to another position first.', 'position with users cannot be deleted');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_delete(''QA_SALES_MGR'')'), 'Position QA_SALES_MGR still has 1 user(s). Move them to another position first.', 'position with users cannot be deleted (2)');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.position_delete(''QA_TMP'')'), 'admin deletes an unused position');
  r := pg_temp.call(admin, 'SELECT erp.position_access_preview(''QA_SALES'', ''{"sales":"read","finance":"read","hr":"none"}''::jsonb)');
  PERFORM pg_temp.check(jsonb_array_length(r->'changes') = 2 AND jsonb_array_length(r->'gain') = 1 AND jsonb_array_length(r->'lose') = 1
                        AND r->'lose'->0->>'module' = 'sales' AND jsonb_array_length(r->'users') = 2, 'preview: finance gained, sales lowered, 2 users affected', r::text);
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_access_preview(''QA_SALES'', ''{"sales":"write"}''::jsonb)'), 'Access level must be Full, Read or None.', 'bad level refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_access_preview(''QA_SALES'', ''{"crm":"read"}''::jsonb)'), 'Module crm is not a known module.', 'unknown module refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_access_save(''QA_ALL'', ''{"admin":"read"}''::jsonb)'),
    'You can''t remove your own Administration access. Ask another system admin.', 'admin cannot lower own Administration access');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.position_access_save(''QA_SALES'', ''{"sales":"full"}''::jsonb)'), 'Nothing changed.', 'no change refused');
  -- takes effect on the next request
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.can_write(''sales''))'))::text = 'true', 'sales has sales full before', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.position_access_save(''QA_SALES'', ''{"sales":"read"}''::jsonb)'), 'admin lowers sales to read');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.can_write(''sales''))'))::text = 'false'
                        AND (pg_temp.call(sales, 'SELECT to_jsonb(erp.can_read(''sales''))'))::text = 'true', 'next request: sales is read-only', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.position_access_save(''QA_SALES'', ''{"sales":"none"}''::jsonb)'), 'admin removes sales');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.document WHERE obj_type = 17'))::text = '0', 'next request: no sales documents readable', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.position_access_save(''QA_SALES'', ''{"sales":"full"}''::jsonb)'), 'admin restores sales full');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.can_write(''sales''))'))::text = 'true', 'sales full again', '');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE action = 'set_position_module' AND object_ref = 'QA_SALES') >= 3
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'position_access_save'), 'matrix changes audited', '');
  r := pg_temp.call(admin, 'SELECT erp.admin_positions()');
  PERFORM pg_temp.check((SELECT p->'levels'->>'sales' FROM jsonb_array_elements(r->'positions') p WHERE p->>'position_code' = 'QA_SALES_READ') = 'read',
                        'matrix shows read level from position_module', '');

  -- ---------- 5. Approval templates (new documents only) ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"discount_pct","approver_position":"QA_SALES_MGR","limit_value":5}''::jsonb)'),
    'This limit is set per position. Choose the requester''s position.', 'discount rule needs a position');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"discount_pct","position_code":"QA_SALES_READ","approver_position":"QA_SALES_MGR","limit_value":150}''::jsonb)'),
    'Enter a percentage between 0 and 100.', 'discount over 100 refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"po_amount","obj_type":17,"approver_position":"QA_PURCH_MGR","limit_value":1}''::jsonb)'),
    'This rule applies to document type 22 only.', 'wrong document type refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"bank_change","approver_position":"QA_FIN_MGR","limit_value":2.5,"step":3}''::jsonb)'),
    'Enter whole days between 1 and 365.', 'fractional days refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"po_amount","approver_position":"QA_PURCH_MGR"}''::jsonb)'),
    'Enter the limit for this rule.', 'missing limit refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"credit_limit","approver_position":"QA_SALES_MGR"}''::jsonb)'),
    'This rule already exists for that position and step. Change the existing rule instead.', 'duplicate rule refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"magic","approver_position":"QA_SALES_MGR"}''::jsonb)'),
    'Rule magic is not a known approval rule.', 'unknown rule refused');
  -- a journal waiting on the current template
  r := pg_temp.call(fin, format('SELECT erp.journal_draft_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', h, big));
  d1 := (r->>'draft_id')::integer;
  r := pg_temp.call(fin, format('SELECT erp.journal_submit(%L, %s, %L)', 'ZZ99', d1, 'A10 test'));
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'journal above limit waits for approval', r::text);
  PERFORM pg_temp.check((SELECT approver_position FROM erp.approval WHERE object = 'journal' AND object_ref = d1::text AND decision IS NULL) = 'QA_FIN_MGR', 'old journal waits for QA_FIN_MGR', '');
  SELECT rule_id INTO v_rule FROM erp.approval_rule WHERE company_code = 'ZZ99' AND rule_code = 'journal_amount';
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_rule_save(%L, %L::jsonb)', 'ZZ99',
    jsonb_build_object('rule_id', v_rule, 'position_code', 'QA_FINANCE', 'limit_value', 50000, 'approver_position', 'QA_OWNER'))), 'admin changes the journal approver to the owner');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_rule_change' AND object_ref = v_rule::text), 'rule change audited', '');
  PERFORM pg_temp.check((SELECT approver_position FROM erp.approval WHERE object = 'journal' AND object_ref = d1::text AND decision IS NULL) = 'QA_FIN_MGR', 'waiting journal keeps its approver', '');
  r := pg_temp.call(fin, format('SELECT erp.journal_draft_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', h, big));
  d2 := (r->>'draft_id')::integer;
  r := pg_temp.call(fin, format('SELECT erp.journal_submit(%L, %s, %L)', 'ZZ99', d2, 'A10 test 2'));
  PERFORM pg_temp.check((SELECT approver_position FROM erp.approval WHERE object = 'journal' AND object_ref = d2::text AND decision IS NULL) = 'QA_OWNER', 'new journal goes to the new approver', r::text);
  r := pg_temp.call(finmgr, format('SELECT erp.journal_decide(%L, %s, %L, %L)', 'ZZ99', d1, 'approved', NULL));
  PERFORM pg_temp.check(r->>'error' IS NULL, 'old approver can still decide the waiting journal', r::text);
  r := pg_temp.call(admin, 'SELECT erp.approval_rule_save(''ZZ99'', ''{"rule_code":"po_amount","position_code":"QA_SALES","approver_position":"QA_PURCH_MGR","limit_value":1000,"step":2}''::jsonb)');
  PERFORM pg_temp.ok(r, 'admin adds a rule');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_rule_delete(%L, %s)', 'ZZ99', r->>'rule_id')), 'admin deletes a rule');
  r := pg_temp.call(admin, 'SELECT erp.approval_template_setup(''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r->'catalogue') = 13 AND jsonb_array_length(r->'rules') >= 10, 'template setup lists 13 rule kinds and the ZZ99 rules', jsonb_array_length(r->'rules')::text);

  -- ---------- 6. Numbering ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 17, ''PO-26-'', 900, 5, true)'),
    'Prefix PO-26- is already used by Purchase Order. Choose a different prefix.', 'prefix used by another document refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 17, ''SO 26'', 900, 5, true)'),
    'Use letters, digits, - / or _ in the prefix (1 to 20 characters).', 'bad prefix refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 17, ''SO-26-'', 123456, 5, true)'),
    'The next number 123456 has more digits than the 5 set. Add digits or lower the number.', 'number longer than digits refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 99, ''XX-'', 1, 5, true)'),
    'Document type 99 has no numbering in Super ERP.', 'unknown document type refused');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 17, ''SO-26-'', 500, 5, true)'), 'admin moves the next number forward');
  PERFORM pg_temp.check((SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 17) = 500
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'number_series_save' AND object_ref = '17'), 'numbering saved and audited', '');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 17, ''SO-26-'', 499, 5, true)'),
    'Numbers only move forward: Sales Order has already reached SO-26-00500. Use a higher number or a new prefix.', 'numbers cannot go back');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.number_series_save(''ZZ99'', 17, ''SO-27-'', 1, 5, true)'), 'new prefix may restart at 1');
  r := pg_temp.call(admin, 'SELECT erp.number_series_setup(''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r->'series') >= 24, 'numbering lists at least 24 document types (A13 adds 3)', '');

  -- ---------- 7. Company details need the owner ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.company_details_submit(''ZZ99'', ''{"tax_id":"123"}''::jsonb, NULL)'),
    'A UAE TRN has 15 digits. Check the number on the VAT certificate.', 'short TRN refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.company_details_submit(''ZZ99'', ''{"currency":"USD"}''::jsonb, NULL)'),
    'Field currency can''t be changed here.', 'unknown field refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.company_details_submit(''ZZ99'', ''{"logo_path":"ZZ98/logo.png"}''::jsonb, NULL)'),
    'The logo must be stored under ZZ99/ in the branding bucket.', 'logo outside the company folder refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.company_details_submit(''ZZ99'', ''{}''::jsonb, NULL)'), 'Nothing changed.', 'no change refused');
  r := pg_temp.call(admin, 'SELECT erp.company_details_submit(''ZZ99'', ''{"address":"DWC, Dubai","phone":"+971 4 000 0000"}''::jsonb, ''New office'')');
  v_req := (r->>'request_id')::bigint;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND r->>'approver_position' = 'QA_OWNER', 'change waits for the owner', r::text);
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT erp.company_print_info(''ZZ99'')'))->>'address' IS NULL, 'print details unchanged while waiting', '');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.company_details_submit(''ZZ99'', ''{"address":"Other"}''::jsonb, NULL)'),
    'A change to ZZ99 is already waiting for the owner''s approval. Wait for it or withdraw it first.', 'second change refused while one waits');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.company_details_decide(%L, %s, %L, NULL)', 'ZZ99', v_req, 'approved')),
    'Only the owner position (QA_OWNER) can approve company detail changes.', 'admin cannot approve');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements((pg_temp.call(owner, 'SELECT erp.approval_inbox()'))->'waiting') w
                                 WHERE w->>'kind' = 'company_details' AND w->>'doc_no' = v_req::text), 'owner sees the change in the inbox', '');
  PERFORM pg_temp.expect(pg_temp.call(owner, format('SELECT erp.company_details_decide(%L, %s, %L, NULL)', 'ZZ99', v_req, 'rejected')),
    'Add a note saying why you reject the change.', 'reject needs a note');
  PERFORM pg_temp.ok(pg_temp.call(owner, format('SELECT erp.company_details_decide(%L, %s, %L, NULL)', 'ZZ99', v_req, 'approved')), 'owner approves');
  r := pg_temp.call(sales, 'SELECT erp.company_print_info(''ZZ99'')');
  PERFORM pg_temp.check(r->>'address' = 'DWC, Dubai' AND r->>'legal_name' = 'Sample Trading LLC (test data)', 'approved details used for printing', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'company_details_approved' AND object_ref = v_req::text), 'approval audited', '');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.admin_setting_save(''ZZ99'', ''{"owner_position":"QA_SALES"}''::jsonb)'),
    'Position QA_SALES has no Owner (Business) access, so it can''t approve company changes.', 'owner position must have owner access');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.admin_setting_save(''ZZ99'', ''{"fx_currencies":["USD","AED"]}''::jsonb)'),
    'AED is the company currency. The rates table lists the other currencies.', 'company currency not a rate currency');

  -- ---------- 8. Exchange rates ----------
  INSERT INTO erp.fx_rate (company_code, rate_date, currency, rate) VALUES ('ZZ99', '2026-11-08', 'USD', 3.6725);
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.fx_rate_save(''ZZ99'', ''2026-11-08'', ''USD'', 3.67)'),
    'SAP already has a USD rate for 08 Nov 2026. Change it in SAP until ZZ99 goes live on Super ERP.', 'SAP rate cannot be overwritten');
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.fx_rate_save(''ZZ99'', ''2026-11-09'', ''JPY'', 0.02)'),
    'Currency JPY is not in the rates list for ZZ99 (USD, SAR, CNY, EUR).', 'currency outside the list refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.fx_rate_save(''ZZ99'', ''2026-11-09'', ''USD'', 0)'), 'Enter a rate above 0 (AED per 1 USD).', 'zero rate refused');
  PERFORM pg_temp.ok(pg_temp.call(fin, 'SELECT erp.fx_rate_save(''ZZ99'', ''2026-11-09'', ''usd'', 3.6725)'), 'finance enters a rate');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.fx_rate_save(''ZZ99'', ''2026-11-09'', ''CNY'', 0.5161)'), 'admin enters a rate');
  r := pg_temp.call(fin, 'SELECT erp.fx_rate_import(''ZZ99'', ''[{"date":"2026-11-10","currency":"USD","rate":"3.6725"},{"date":"2026-11-10","currency":"EUR","rate":"x"},{"date":"2026-11-08","currency":"USD","rate":"3.6"}]''::jsonb)');
  PERFORM pg_temp.check((r->>'saved')::int = 0 AND jsonb_array_length(r->'errors') = 2 AND r->'errors'->0->>'row' = '2', 'import with problems saves nothing and names the rows', r::text);
  r := pg_temp.call(fin, 'SELECT erp.fx_rate_import(''ZZ99'', ''[{"date":"2026-11-10","currency":"USD","rate":"3.6725"},{"date":"2026-11-10","currency":"SAR","rate":"0.9793"}]''::jsonb)');
  PERFORM pg_temp.check((r->>'saved')::int = 2, 'clean import saves all rows', r::text);
  PERFORM pg_temp.check((pg_temp.call(fin, 'SELECT to_jsonb(count(*)) FROM erp.fx_rate_list WHERE company_code = ''ZZ99'''))::text = '5', 'rates list shows SAP + Super ERP rates', '');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.fx_rate_list'))::text = '0', 'sales cannot read rates', '');
  PERFORM pg_temp.check((SELECT rate FROM erp.fx_rate WHERE company_code = 'ZZ99' AND rate_date = '2026-11-08' AND currency = 'USD') = 3.6725, 'SAP rate untouched', '');

  -- ---------- 9. AI Assistant: settings only, the key never in a table ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"api_key":"sk-test-123"}''::jsonb)'),
    'API keys are never stored in the database. Add the key as the Supabase secret AI_API_KEY; only the AI Assistant server function reads it.', 'API key refused');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'erp'
                                     AND (column_name ~* '(api_key|secret|password|access_token)')), 'no erp column can hold a key or secret', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.audit_log WHERE detail::text LIKE '%sk-test-123%'), 'refused key not written anywhere', '');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"enabled":true}''::jsonb)'),
    'Choose a chat provider and a monthly limit before switching the assistant on.', 'cannot switch on without provider and limit');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"allowed_tables":["sap.OINV"]}''::jsonb)'),
    'The AI Assistant never reads the raw SAP copy (schema sap).', 'sap tables refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"allowed_tables":["employee_pay"]}''::jsonb)'),
    'Salary data is never available to the AI Assistant (employee_pay).', 'salary tables refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"allowed_tables":["audit_log"]}''::jsonb)'),
    'Table audit_log can''t be read by the AI Assistant.', 'admin tables refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"chat_provider":"acme"}''::jsonb)'), 'Chat provider acme is not supported.', 'unknown provider refused');
  PERFORM pg_temp.check(NOT ('employee_pay' = ANY (erp._ai_tables())) AND NOT ('hr_pay' = ANY (erp._ai_tables())) AND 'item' = ANY (erp._ai_tables()), 'AI table catalogue excludes salary', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.ai_setting_save(''ZZ99'', ''{"enabled":true,"chat_provider":"google","chat_model":"gemini-2.5-flash","allowed_modules":["sales","inventory"],"allowed_tables":["item","erp.stock_balance"],"monthly_limit":1000}''::jsonb)'),
    'admin switches the assistant on');
  r := pg_temp.call(sales, 'SELECT erp.ai_request_check(''ZZ99'')');
  PERFORM pg_temp.check(r->>'chat_provider' = 'google' AND (r->>'remaining')::int = 1000 AND r->'modules' = '["sales"]'::jsonb, 'request check limits modules to the user''s own', r::text);
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.ai_setting'))::text = '0', 'non-admin cannot read AI settings', '');
  PERFORM pg_temp.check((pg_temp.call(admin, 'SELECT erp.ai_usage_record(''ZZ99'', 1, 10)'))->>'error' = '42501', 'browser cannot record AI usage', '');
  PERFORM pg_temp.call(NULL, 'SELECT to_jsonb(erp.ai_usage_record(''ZZ99'', 1000, 10))', 'service_role');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.ai_request_check(''ZZ99'')'),
    'This month''s AI Assistant limit for ZZ99 is used up (1000 requests).', 'monthly limit enforced');

  -- ---------- 10. Audit view ----------
  r := pg_temp.call(admin, 'SELECT erp.admin_audit_recent(ARRAY[''position'', ''app_user''], 50)');
  PERFORM pg_temp.check(jsonb_array_length(r) >= 5, 'recent administration changes listed (incl. company-less rows)', jsonb_array_length(r)::text);
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.admin_audit_recent(ARRAY[''position''], 5)'), 'Only the system admin, IT and the owner can open Administration.', 'sales cannot read the admin audit');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a10_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a10_result;
ROLLBACK;
