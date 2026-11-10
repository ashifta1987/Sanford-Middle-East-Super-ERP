-- B2 · Approval Management (Approval Stages, Approval Templates, Approval Status Report). LOCAL STACK ONLY (sample company ZZ99 +
-- scripts/local-stack/test-users.sql). Run on a FRESH rebuild (sql-order.txt incl. 31_approvals.sql).
-- Everything happens inside one transaction that is rolled back. Prints PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE b2_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON b2_result TO authenticated;

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
  INSERT INTO b2_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.stage(p_user uuid, p jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.approval_stage_save(%L, %L::jsonb)', 'ZZ99', p))
$$;
CREATE FUNCTION pg_temp.tpl(p_user uuid, p jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.approval_template_save(%L, %L::jsonb)', 'ZZ99', p))
$$;
CREATE FUNCTION pg_temp.pay(p_user uuid, p_amount numeric, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.payment_submit(%L, %L, %L::jsonb, %L::jsonb, %L)', 'ZZ99', 'I',
    jsonb_build_object('card_code', 'C0011', 'doc_date', '2026-11-09', 'transfer', p_amount, 'transfer_bank', 'BNK-AED'), '[]', p_reason))
$$;
CREATE FUNCTION pg_temp.pdec(p_user uuid, p_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.payment_decide(%L, %s, %L, %L)', 'ZZ99', p_id, p_decision, p_note))
$$;
CREATE FUNCTION pg_temp.so(p_user uuid, p_disc numeric) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.sales_doc_checks(%L, 17, NULL, %L::jsonb, %L::jsonb)', 'ZZ99',
    '{"card_code":"C0011","doc_date":"2026-11-10","due_date":"2026-11-30","whs_code":"WH01"}',
    jsonb_build_array(jsonb_build_object('item_code', 'SMP-1010', 'qty', 1, 'tax_code', 'SR', 'discount_pct', p_disc))))
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  smgr   uuid := '00000000-0000-4000-8000-000000000007';
  fmgr   uuid := '00000000-0000-4000-8000-000000000008';
  it     uuid := '00000000-0000-4000-8000-000000000023';
  r jsonb; r2 jsonb;
  st_fm bigint; st_two bigint; st_tmp bigint; t_in bigint; t_disc bigint; t_co bigint; t_tmp bigint;
  p1 integer; p2 integer; p3 integer; v_n integer; v_ver integer; co_req bigint;
  deny_admin text := 'Only the system admin, IT and the owner can open Administration.';
  deny_write text := 'Only a system admin with full Administration access can change this.';
BEGIN
  -- ================= 1. Migration of the A2–B1 rules =================
  PERFORM pg_temp.check((SELECT count(*) FROM erp.apr_template WHERE company_code = 'ZZ99' AND legacy_key IS NOT NULL) =
                        (SELECT count(*) FROM (SELECT DISTINCT obj_type, rule_code, position_code FROM erp.approval_rule WHERE company_code = 'ZZ99') x),
                        'one template per ZZ99 rule chain (company, document, rule, requester position)',
                        (SELECT count(*) FROM erp.apr_template WHERE company_code = 'ZZ99')::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.apr_template WHERE company_code = 'ZZ99' AND legacy_key IS NOT NULL AND legacy_sync AND version = 1 AND source = 'sample') = 16,
                        '16 migrated SAMPLE templates, still following approval_rule, version 1');
  PERFORM pg_temp.check((SELECT string_agg(s.name, ' → ' ORDER BY ts.seq) FROM erp.apr_template t JOIN erp.apr_template_stage ts ON ts.template_id = t.template_id
                           JOIN erp.apr_stage s ON s.stage_id = ts.stage_id WHERE t.company_code = 'ZZ99' AND t.kind = 'bank_change')
                        = 'Approval by QA · finance manager → Approval by QA · owner (business)', 'bank change: two ordered stages (finance manager, then owner)');
  PERFORM pg_temp.check((SELECT c.field || ' ' || c.op || ' ' || trim_scale(c.value1) FROM erp.apr_template t JOIN erp.apr_template_condition c ON c.template_id = t.template_id
                           JOIN erp.apr_template_originator o ON o.template_id = t.template_id
                          WHERE t.company_code = 'ZZ99' AND t.kind = 'discount_pct' AND o.position_code = 'QA_SALES') = 'discount_pct gt 10',
                        'discount template for QA_SALES: originator QA_SALES, condition discount % > 10');
  PERFORM pg_temp.check((SELECT c.field || ' ' || c.op || ' ' || trim_scale(c.value1) FROM erp.apr_template t JOIN erp.apr_template_condition c ON c.template_id = t.template_id
                          WHERE t.company_code = 'ZZ99' AND t.kind = 'bank_change') = 'days_since_change le 30', 'bank change: days since the change ≤ 30');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.apr_template_originator o JOIN erp.apr_template t ON t.template_id = o.template_id
                                     WHERE t.company_code = 'ZZ99' AND t.kind IN ('credit_limit', 'below_cost', 'bank_change')),
                        'rules for every position became templates without originators (everyone)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.apr_template WHERE company_code LIKE 'AE%') AND NOT EXISTS (SELECT 1 FROM erp.apr_stage WHERE company_code LIKE 'AE%'),
                        'AE01–AE05: no templates and no stages (entered later by Sanford)');
  PERFORM pg_temp.check((SELECT NOT active AND source = 'sample' FROM erp.apr_template WHERE company_code = 'ZZ99' AND kind = 'incoming_payment'),
                        'ZZ99 SAMPLE incoming payment template exists and is inactive');
  v_n := (SELECT count(*) FROM erp.apr_template_version);
  PERFORM erp._apr_sync_legacy(x.company_code, x.obj_type, x.rule_code, x.position_code, NULL)
     FROM (SELECT DISTINCT company_code, obj_type, rule_code, position_code FROM erp.approval_rule) x;
  PERFORM pg_temp.check((SELECT count(*) FROM erp.apr_template_version) = v_n AND (SELECT count(*) FROM erp.apr_template WHERE company_code = 'ZZ99') = 17,
                        'migration runs twice without new templates or versions');
  st_fm := (SELECT stage_id FROM erp.apr_stage WHERE company_code = 'ZZ99' AND legacy_key = 'pos:QA_FIN_MGR');

  -- ================= 2. Access =================
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.approval_setup('ZZ99')$q$), deny_admin, 'sales user can''t open Approval Process');
  r := pg_temp.call(it, $q$SELECT erp.approval_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'can_write')::boolean = false AND jsonb_array_length(r->'templates') = 17 AND jsonb_array_length(r->'kinds') = 17,
                        'IT reads the setup (17 kinds incl. built-in leave, 17 templates), read-only', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.stage(it, '{"name":"X","authorizers":[{"position_code":"QA_FIN_MGR"}]}'), deny_write, 'IT (read-only) can''t save a stage');
  PERFORM pg_temp.expect(pg_temp.tpl(sales, '{"name":"X"}'), deny_write, 'sales can''t save a template');
  r := pg_temp.call(NULL, $q$SELECT erp.approval_setup('ZZ99')$q$, 'anon');
  PERFORM pg_temp.check(r->>'error' = '42501', 'anon can''t call the API', r::text);
  r := pg_temp.call(admin, $q$WITH x AS (INSERT INTO erp.apr_template (company_code, name, kind, obj_type) VALUES ('ZZ99', 'direct', 'po_amount', 22) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct INSERT on erp.apr_template refused', r::text);
  r := pg_temp.call(admin, $q$WITH x AS (UPDATE erp.apr_stage SET required_approvals = 5 RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct UPDATE on erp.apr_stage refused', r::text);
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.approval_setup('AE05')$q$), 'You don''t have access to company AE05.', 'other company refused');

  -- ================= 3. Approval Stages =================
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":" ","authorizers":[{"position_code":"QA_FIN_MGR"}]}'), 'Enter the stage name.', 'stage name required');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"approval by qa · finance manager","authorizers":[{"position_code":"QA_FIN_MGR"}]}'),
    'A stage named "approval by qa · finance manager" already exists in ZZ99. Choose another name.', 'duplicate stage name refused (any case)');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 empty","authorizers":[]}'), 'Add at least one authorizer (a position or a user).', 'stage without authorizers refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","authorizers":[{"position_code":"NOPE"}]}'), 'Position NOPE does not exist. Check the position code.', 'unknown position refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","authorizers":[{"user_id":"00000000-0000-4000-8000-0000000000ff"}]}'),
    'User 00000000-0000-4000-8000-0000000000ff can''t be an authorizer: they have no active access to ZZ99.', 'user without access to the company refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","authorizers":[{"position_code":"QA_FIN_MGR","user_id":"00000000-0000-4000-8000-000000000005"}]}'),
    'Each authorizer is either a position or a user.', 'position and user in one entry refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","authorizers":[{"position_code":"QA_FIN_MGR"},{"position_code":"QA_FIN_MGR"}]}'),
    'QA · finance manager is listed twice.', 'same authorizer twice refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","required_approvals":0,"authorizers":[{"position_code":"QA_FIN_MGR"}]}'),
    'Required approvals must be between 1 and 20.', 'zero approvals refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","required_rejections":21,"authorizers":[{"position_code":"QA_FIN_MGR"}]}'),
    'Required rejections must be between 1 and 20.', 'too many rejections refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","required_approvals":"two","authorizers":[{"position_code":"QA_FIN_MGR"}]}'),
    'Enter the number of approvals and rejections as whole numbers.', 'non-numeric approvals refused');
  PERFORM pg_temp.expect(pg_temp.stage(admin, '{"name":"B2 bad","required_approvals":2,"authorizers":[{"user_id":"00000000-0000-4000-8000-000000000005"}]}'),
    'This stage needs 2 approvals but lists only 1 user(s). Add authorizers or lower the number.', 'more approvals than listed users refused');
  r := pg_temp.stage(admin, '{"name":"B2 Two approvers","description":"Finance manager and the owner","required_approvals":2,"authorizers":[{"position_code":"QA_FIN_MGR"},{"user_id":"00000000-0000-4000-8000-000000000005"}]}');
  st_two := (r->>'stage_id')::bigint;
  PERFORM pg_temp.check(st_two IS NOT NULL AND (SELECT count(*) FROM erp.apr_stage_authorizer WHERE stage_id = st_two) = 2,
                        'stage with a position and a user, 2 approvals needed', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_stage_create' AND object_ref = st_two::text), 'stage creation audited');
  PERFORM pg_temp.check(erp._apr_stage_who(st_two) = 'QA · finance manager or QA Owner', 'stage authorizers read "QA · finance manager or QA Owner"', erp._apr_stage_who(st_two));

  -- ================= 4. Approval Templates: validation =================
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"","kind":"incoming_payment","stages":[1]}'), 'Enter the template name.', 'template name required');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"B2 x","stages":[1]}'), 'Choose the document the template applies to.', 'kind required');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"B2 x","kind":"magic","stages":[1]}'), 'Approval kind magic is not known.', 'unknown kind refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"B2 x","kind":"leave","stages":[1]}'),
    'Leave approvals follow the line manager, the HR approver and the owner set in HR Setup. Change them there.', 'leave stays built-in');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"B2 x","kind":"stock_doc_amount","obj_type":17,"stages":[1]}'),
    'This template applies to document type 59 or 60 only.', 'wrong document type refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"B2 x","kind":"incoming_payment","stages":[]}'), 'Add at least one approval stage.', 'template without stages refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s,%s]}', st_fm, st_fm)::jsonb),
    'Stage "Approval by QA · finance manager" is listed twice. Each stage can be used once per template.', 'same stage twice refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, '{"name":"B2 x","kind":"incoming_payment","stages":[999999]}'),
    'Stage 999999 was not found in ZZ99. Choose a stage from the list.', 'unknown stage refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"conditions":[{"field":"discount_pct","op":"gt","value1":5}]}', st_fm)::jsonb),
    'The condition "discount_pct" can''t be used for Incoming payment. Choose one of: amount.', 'condition the kind does not support refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"conditions":[{"field":"amount","op":"bigger","value1":5}]}', st_fm)::jsonb),
    'Choose how to compare amount (greater than, less than, between …).', 'unknown operator refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"conditions":[{"field":"amount","op":"gt"}]}', st_fm)::jsonb),
    'Enter the value for amount.', 'missing value refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"conditions":[{"field":"amount","op":"gt","value1":"lots"}]}', st_fm)::jsonb),
    'Enter amount as a number.', 'non-numeric value refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"conditions":[{"field":"amount","op":"between","value1":500,"value2":100}]}', st_fm)::jsonb),
    'For "between", enter a "to" value greater than or equal to the "from" value.', 'between with to < from refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"conditions":[{"field":"amount","op":"gt","value1":-1}]}', st_fm)::jsonb),
    'The amount can''t be negative.', 'negative amount refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"discount_pct","stages":[%s],"conditions":[{"field":"discount_pct","op":"gt","value1":120}]}', st_fm)::jsonb),
    'Enter a percentage between 0 and 100.', 'discount over 100 % refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"bank_change","stages":[%s],"conditions":[{"field":"days_since_change","op":"le","value1":2.5}]}', st_fm)::jsonb),
    'Enter whole days between 1 and 365.', 'fractional days refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"bp_bank_detail","stages":[%s],"conditions":[{"field":"amount","op":"gt","value1":1}]}', st_fm)::jsonb),
    'Business partner bank details change has no conditions: the template applies to every request from its originators.', 'conditions on a kind without fields refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"B2 x","kind":"incoming_payment","stages":[%s],"originators":[{"position_code":"NOPE"}]}', st_fm)::jsonb),
    'Position NOPE does not exist. Check the position code.', 'unknown originator position refused');
  PERFORM pg_temp.expect(pg_temp.tpl(admin, format('{"name":"journal entry · qa · finance","kind":"incoming_payment","stages":[%s]}', st_fm)::jsonb),
    'A template named "journal entry · qa · finance" already exists in ZZ99. Choose another name.', 'duplicate template name refused');

  -- ================= 5. Incoming payment approval (NEW) =================
  r := pg_temp.pay(fin, 1500);
  PERFORM pg_temp.check(r->>'state' = 'posted', 'no active incoming-payment template: the payment posts at once (as before)', left(r::text, 200));
  r := pg_temp.tpl(admin, format('{"name":"B2 Incoming over 1,000","kind":"incoming_payment","stages":[%s],"originators":[{"user_id":"%s"}],"conditions":[{"field":"amount","op":"gt","value1":1000}]}', st_fm, sales)::jsonb);
  t_in := (r->>'template_id')::bigint;
  PERFORM pg_temp.check(t_in IS NOT NULL AND (r->>'version')::integer = 1, 'incoming-payment template created (originator: a user)', r::text);
  r := pg_temp.pay(fin, 1500);
  PERFORM pg_temp.check(r->>'state' = 'posted', 'finance user is not an originator: posts at once', left(r::text, 200));
  r := pg_temp.tpl(admin, format('{"template_id":%s,"name":"B2 Incoming over 1,000","kind":"incoming_payment","stages":[%s],"originators":[{"user_id":"%s"},{"position_code":"QA_FINANCE"}],"conditions":[{"field":"amount","op":"gt","value1":1000}]}', t_in, st_fm, sales)::jsonb);
  PERFORM pg_temp.check((r->>'version')::integer = 2, 'originator position QA_FINANCE added (version 2)', r::text);
  r := pg_temp.call(fin, $q$SELECT erp.payment_setup('ZZ99', 'I')$q$);
  PERFORM pg_temp.check((r->>'needs_approval')::boolean AND (r->>'my_limit')::numeric = 1000, 'payment form: incoming payments need approval above 1,000', left(r::text, 300));
  r := pg_temp.pay(fin, 800);
  PERFORM pg_temp.check(r->>'state' = 'posted', 'incoming payment 800 (not above 1,000): posts at once', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.pay(fin, 1500), 'This payment needs approval. Add a reason for the approver.', 'above 1,000 without a reason refused');
  r := pg_temp.pay(fin, 1500, 'B2 large receipt');
  p1 := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND p1 IS NOT NULL
                        AND r->'checks'->0->>'message' = 'Incoming payment 1,500.00 AED: needs approval under template "B2 Incoming over 1,000" (amount > 1000).',
                        'above 1,000: waits for approval before posting', left(r::text, 400));
  PERFORM pg_temp.check((SELECT template_id = t_in AND template_version = 2 AND stage_id = st_fm AND stage_name = 'Approval by QA · finance manager' AND need_approvals = 1
                           AND approver_position = 'QA_FIN_MGR' AND rule_code = 'incoming_payment'
                           FROM erp.approval WHERE object = 'payment' AND object_ref = p1::text), 'the waiting row keeps template (v2) and stage');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'I' AND total = 1500 AND doc_date = '2026-11-09'
                                     AND trans_id IS NOT NULL AND doc_entry = (SELECT doc_entry FROM erp.payment_draft WHERE draft_id = p1)),
                        'nothing posted while it waits');
  r := pg_temp.call(fmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'payment' AND w->>'doc_no' = p1::text
                                  AND w->>'template_name' = 'B2 Incoming over 1,000' AND w->>'stage_name' = 'Approval by QA · finance manager' AND (w->>'stages')::int = 1),
                        'inbox: finance manager sees it with template and stage', left(r->>'waiting', 300));
  r := pg_temp.call(fin, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sent') w WHERE w->>'doc_no' = p1::text AND w->>'template_name' = 'B2 Incoming over 1,000'),
                        'inbox: the requester sees it under sent with the template');
  PERFORM pg_temp.expect(pg_temp.pdec(admin, p1, 'approved'),
    'This payment is waiting for approval from QA · finance manager. Your position can''t decide it.', 'another position can''t decide');
  r := pg_temp.call(fmgr, format('SELECT erp.payment_draft_info(%L, %s)', 'ZZ99', p1));
  PERFORM pg_temp.check((r->>'can_decide')::boolean AND r->'approvals'->0->>'template_name' = 'B2 Incoming over 1,000' AND r->'approvals'->0->>'stage_name' = 'Approval by QA · finance manager',
                        'payment draft page: template and stage, finance manager may decide', left(r->>'approvals', 300));
  r := pg_temp.pdec(fmgr, p1, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'posted' AND r->>'doc_no' IS NOT NULL, 'finance manager approves: the incoming payment posts', r::text);

  -- ================= 6. Two approvals in one stage, live authorizers =================
  r := pg_temp.tpl(admin, format('{"template_id":%s,"name":"B2 Incoming over 1,000","kind":"incoming_payment","stages":[%s],"originators":[{"position_code":"QA_FINANCE"}],"conditions":[{"field":"amount","op":"gt","value1":1000}]}', t_in, st_two)::jsonb);
  PERFORM pg_temp.check((r->>'version')::integer = 3, 'template now uses the two-approver stage (version 3); originator user removed', r::text);
  r := pg_temp.pay(fin, 2000, 'B2 two approvals'); p2 := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (SELECT need_approvals FROM erp.approval WHERE object = 'payment' AND object_ref = p2::text) = 2,
                        'waits at a stage that needs 2 approvals', left(r::text, 200));
  r := pg_temp.pdec(fmgr, p2, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'first approval: still waiting (1 of 2)', r::text);
  PERFORM pg_temp.expect(pg_temp.pdec(fmgr, p2, 'approved'),
    'This payment is waiting for approval from QA · finance manager or QA Owner. Your position can''t decide it.', 'the same person can''t approve twice');
  PERFORM pg_temp.expect(pg_temp.pdec(admin, p2, 'approved'),
    'This payment is waiting for approval from QA · finance manager or QA Owner. Your position can''t decide it.', 'not an authorizer of the stage: refused');
  r := pg_temp.stage(admin, format('{"stage_id":%s,"name":"B2 Two approvers","required_approvals":2,"authorizers":[{"position_code":"QA_FIN_MGR"},{"user_id":"%s"},{"position_code":"QA_ALL"}]}', st_two, owner)::jsonb);
  PERFORM pg_temp.check((r->>'pending')::integer = 1, 'adding an authorizer: the stage reports 1 request waiting (it follows the change)', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_stage_change' AND object_ref = st_two::text), 'stage change audited');
  r := pg_temp.pdec(admin, p2, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'posted', 'the newly added authorizer gives the 2nd approval: posted', r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.approval_vote v JOIN erp.approval a ON a.approval_id = v.approval_id WHERE a.object = 'payment' AND a.object_ref = p2::text) = 2
                        AND (SELECT decision FROM erp.approval WHERE object = 'payment' AND object_ref = p2::text) = 'approved', 'two votes kept, the row is approved');
  r := pg_temp.pay(fin, 2100, 'B2 remove'); p3 := (r->>'draft_id')::integer;
  r := pg_temp.stage(admin, format('{"stage_id":%s,"name":"B2 Two approvers","required_approvals":2,"authorizers":[{"position_code":"QA_FIN_MGR"},{"user_id":"%s"}]}', st_two, owner)::jsonb);
  PERFORM pg_temp.expect(pg_temp.pdec(admin, p3, 'approved'),
    'This payment is waiting for approval from QA · finance manager or QA Owner. Your position can''t decide it.', 'removing an authorizer: they can no longer decide waiting requests');
  PERFORM pg_temp.expect(pg_temp.pdec(fmgr, p3, 'rejected'), 'Add a note saying why you are rejecting this payment.', 'reject needs a note');
  r := pg_temp.pdec(fmgr, p3, 'rejected', 'B2 not expected');
  PERFORM pg_temp.check(r->>'state' = 'rejected', 'one rejection (required 1) rejects the payment', r::text);
  r := pg_temp.call(fmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'decided') w WHERE w->>'doc_no' = p2::text),
                        'inbox: a vote that did not close the stage still shows under decided');

  -- ================= 7. Deactivate, history, delete =================
  r := pg_temp.call(admin, format('SELECT erp.approval_template_set_active(%L, %s, false)', 'ZZ99', t_in));
  PERFORM pg_temp.check((r->>'active')::boolean = false AND (r->>'version')::integer = 4, 'template deactivated (version 4)', r::text);
  r := pg_temp.pay(fin, 5000);
  PERFORM pg_temp.check(r->>'state' = 'posted', 'inactive template: incoming payments post at once again', left(r::text, 200));
  r := pg_temp.call(it, format('SELECT erp.approval_template_history(%L, %s)', 'ZZ99', t_in));
  PERFORM pg_temp.check(jsonb_array_length(r) = 4 AND r->0->>'action' = 'deactivated' AND r->3->>'action' = 'created'
                        AND r->2->'snapshot'->'originators' @> '[{"position_code":"QA_FINANCE"}]', 'history keeps every version (created … deactivated)', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.approval_template_delete(%L, %s)', 'ZZ99', t_in)),
    'Template "B2 Incoming over 1,000" was used by 3 request(s). Deactivate it instead, so its history is kept.', 'used template can''t be deleted');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.approval_stage_delete(%L, %s)', 'ZZ99', st_two)),
    'Stage "B2 Two approvers" is used in template(s) B2 Incoming over 1,000. Remove it from those templates first.', 'stage used by a template can''t be deleted');
  r := pg_temp.stage(admin, format('{"stage_id":%s,"name":"Approval by QA · finance manager","active":false,"authorizers":[{"position_code":"QA_FIN_MGR"}]}', st_fm)::jsonb);
  PERFORM pg_temp.check(r->>'message' LIKE 'Stage "Approval by QA · finance manager" is used by active template(s) %. Remove it from those templates first.',
                        'stage used by active templates can''t be deactivated', r->>'message');
  r := pg_temp.stage(admin, '{"name":"B2 Spare","authorizers":[{"position_code":"QA_OWNER"}]}'); st_tmp := (r->>'stage_id')::bigint;
  r := pg_temp.tpl(admin, format('{"name":"B2 Unused","kind":"po_amount","stages":[%s],"active":false}', st_tmp)::jsonb); t_tmp := (r->>'template_id')::bigint;
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_template_delete(%L, %s)', 'ZZ99', t_tmp)), 'unused template deleted');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_stage_delete(%L, %s)', 'ZZ99', st_tmp)), 'unused stage deleted');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.approval_template_delete(%L, %s)', 'ZZ99',
                           (SELECT template_id FROM erp.apr_template WHERE company_code = 'ZZ99' AND kind = 'journal_amount'))),
    'Template "Journal entry · QA · finance" was created from the earlier approval rules. Deactivate it instead, so its history is kept.', 'migrated template can''t be deleted');

  -- ================= 8. Existing rules keep working through the templates =================
  r := pg_temp.so(sales, 12);
  PERFORM pg_temp.check(r->'checks'->0->>'message' = 'Line 1: Discount 12% is above your limit of 10%. Submit it for approval or lower the discount.'
                        AND r->'checks'->0->>'template_name' = 'Sales discount · QA · sales only', 'sales discount 12 %: the classic message, from the migrated template', left(r->>'checks', 300));
  r := pg_temp.call(sales, $q$SELECT erp.sales_doc_setup('ZZ99', 17)$q$);
  PERFORM pg_temp.check((r->>'my_discount_limit')::numeric = 10, 'order form: my discount limit 10 % (from the template)', r->>'my_discount_limit');
  r := pg_temp.call(fin, $q$SELECT erp.journal_setup('ZZ99')$q$);
  PERFORM pg_temp.check((r->>'my_limit')::numeric = 50000, 'journal form: my limit 50,000 (from the template)', r->>'my_limit');
  t_disc := (SELECT t.template_id FROM erp.apr_template t JOIN erp.apr_template_originator o ON o.template_id = t.template_id
              WHERE t.company_code = 'ZZ99' AND t.kind = 'discount_pct' AND o.position_code = 'QA_SALES');
  r := pg_temp.tpl(admin, format('{"template_id":%s,"name":"Sales discount · QA · sales only","kind":"discount_pct","stages":[%s],"originators":[{"position_code":"QA_SALES"}],"conditions":[{"field":"discount_pct","op":"ge","value1":15}]}',
         t_disc, (SELECT stage_id FROM erp.apr_stage WHERE company_code = 'ZZ99' AND legacy_key = 'pos:QA_SALES_MGR'))::jsonb);
  PERFORM pg_temp.check((SELECT NOT legacy_sync AND version = 2 FROM erp.apr_template WHERE template_id = t_disc), 'editing a migrated template detaches it from approval_rule', r::text);
  r := pg_temp.so(sales, 12);
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 0, 'discount 12 % is now fine (template: discount ≥ 15)', left(r->>'checks', 300));
  r := pg_temp.so(sales, 15);
  PERFORM pg_temp.check(r->'checks'->0->>'message' = 'Line 1: Discount 15%: needs approval under template "Sales discount · QA · sales only" (discount % ≥ 15).',
                        'discount 15 %: template message with its condition', left(r->>'checks', 300));
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.approval_rule_save(%L, %L::jsonb)', 'ZZ99',
                           jsonb_build_object('rule_id', (SELECT rule_id FROM erp.approval_rule WHERE company_code = 'ZZ99' AND rule_code = 'discount_pct' AND position_code = 'QA_SALES'),
                                              'position_code', 'QA_SALES', 'limit_value', 20, 'approver_position', 'QA_SALES_MGR'))),
    'This rule is now managed in Approval Templates (template "Sales discount · QA · sales only"). Change it there.', 'legacy save refused once the template is managed here');
  r := pg_temp.call(admin, format('SELECT erp.approval_rule_save(%L, %L::jsonb)', 'ZZ99',
         '{"rule_code":"po_amount","position_code":"QA_SALES","approver_position":"QA_PURCH_MGR","limit_value":1000,"step":1}'));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.apr_template t JOIN erp.apr_template_condition c ON c.template_id = t.template_id
                                 WHERE t.company_code = 'ZZ99' AND t.legacy_key = 'rule:22|po_amount|QA_SALES' AND t.legacy_sync AND c.value1 = 1000),
                        'legacy approval_rule_save still works: it creates the matching template', r::text);
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_rule_delete(%L, %s)', 'ZZ99', r->>'rule_id')), 'legacy approval_rule_delete still works');
  PERFORM pg_temp.check((SELECT NOT active FROM erp.apr_template WHERE company_code = 'ZZ99' AND legacy_key = 'rule:22|po_amount|QA_SALES'),
                        'deleting the legacy rule deactivates its template (history kept)');

  -- Journal: a user (not a position) as the only authorizer, two ordered stages, conditions with "between".
  r := pg_temp.stage(admin, format('{"name":"B2 Admin user only","authorizers":[{"user_id":"%s"}]}', admin)::jsonb); st_tmp := (r->>'stage_id')::bigint;
  r := pg_temp.call(admin, format('SELECT erp.approval_template_set_active(%L, %s, false)', 'ZZ99',
         (SELECT template_id FROM erp.apr_template WHERE company_code = 'ZZ99' AND kind = 'journal_amount' AND legacy_key IS NOT NULL)));
  PERFORM pg_temp.check((r->>'active')::boolean = false, 'migrated journal template deactivated', r::text);
  r := pg_temp.tpl(admin, format('{"name":"B2 Journals 10k-100k","kind":"journal_amount","stages":[%s,%s],"originators":[{"user_id":"%s"}],"conditions":[{"field":"amount","op":"between","value1":10000,"value2":100000}]}',
         st_fm, st_tmp, fin)::jsonb);
  PERFORM pg_temp.ok(r, 'journal template: finance manager, then one named user; originator: one user; amount between 10,000 and 100,000');
  r := pg_temp.call(fin, format('SELECT erp.journal_draft_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', '{"ref_date":"2026-11-09","memo":"B2 small"}',
         '[{"acct_code":"6200","debit":5000},{"acct_code":"1110","credit":5000}]'));
  r := pg_temp.call(fin, format('SELECT erp.journal_submit(%L, %s, NULL)', 'ZZ99', r->>'draft_id'));
  PERFORM pg_temp.check(r->>'state' = 'posted', 'journal 5,000 (outside 10,000–100,000) posts at once', left(r::text, 200));
  r := pg_temp.call(fin, format('SELECT erp.journal_draft_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', '{"ref_date":"2026-11-09","memo":"B2 big"}',
         '[{"acct_code":"6200","debit":60000},{"acct_code":"1110","credit":60000}]'));
  v_n := (r->>'draft_id')::integer;
  r := pg_temp.call(fin, format('SELECT erp.journal_submit(%L, %s, %L)', 'ZZ99', v_n, 'B2 journal'));
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND jsonb_array_length(r->'checks') = 2
                        AND r->'checks'->1->>'approver_name' = 'QA Admin', 'journal 60,000: two stages (finance manager, then the named user)', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.journal_decide(%L, %s, %L, NULL)', 'ZZ99', v_n, 'approved')),
    'This journal is waiting for approval from QA · finance manager. Your position can''t decide it.', 'stage 2 can''t decide before stage 1');
  PERFORM pg_temp.ok(pg_temp.call(fmgr, format('SELECT erp.journal_decide(%L, %s, %L, NULL)', 'ZZ99', v_n, 'approved')), 'stage 1: finance manager approves');
  r := pg_temp.call(admin, format('SELECT erp.journal_draft_info(%L, %s)', 'ZZ99', v_n));
  PERFORM pg_temp.check((r->>'can_decide')::boolean AND (SELECT a->>'stage_name' FROM jsonb_array_elements(r->'approvals') a WHERE (a->>'current')::boolean) = 'B2 Admin user only',
                        'journal page: the named user may decide stage 2', left(r->>'approvals', 300));
  PERFORM pg_temp.expect(pg_temp.call(fmgr, format('SELECT erp.journal_decide(%L, %s, %L, NULL)', 'ZZ99', v_n, 'approved')),
    'This journal is waiting for approval from QA Admin. Your position can''t decide it.', 'stage 2 belongs to the named user only');
  r := pg_temp.call(admin, format('SELECT erp.journal_decide(%L, %s, %L, NULL)', 'ZZ99', v_n, 'approved'));
  PERFORM pg_temp.check(r->>'state' = 'posted', 'stage 2: the named user approves, the journal posts', r::text);

  -- ================= 9. Company details through a template =================
  PERFORM pg_temp.ok(pg_temp.tpl(admin, format('{"name":"B2 Company details","kind":"company_details","stages":[%s]}', st_fm)::jsonb), 'company details template (finance manager stage)');
  r := pg_temp.call(admin, $q$SELECT erp.company_details_submit('ZZ99', '{"phone":"+971 4 222 3333"}'::jsonb, 'B2 test')$q$);
  co_req := (r->>'request_id')::bigint;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (SELECT stage_id FROM erp.approval WHERE object = 'company_details' AND object_ref = co_req::text) = st_fm,
                        'company details change goes to the template''s stage', r::text);
  PERFORM pg_temp.expect(pg_temp.call(owner, format('SELECT erp.company_details_decide(%L, %s, %L, NULL)', 'ZZ99', co_req, 'approved')),
    'This change is waiting for approval from QA · finance manager. Your position can''t decide it.', 'the owner is not the stage''s authorizer now');
  r := pg_temp.call(admin, $q$SELECT erp.company_details_info('ZZ99')$q$);
  PERFORM pg_temp.check(r->'pending'->'approvals'->0->>'template_name' = 'B2 Company details' AND r->'pending'->'approvals'->0->>'stage_name' = 'Approval by QA · finance manager',
                        'company details page shows template and stage', left(r->>'pending', 300));
  r := pg_temp.call(fmgr, format('SELECT erp.company_details_decide(%L, %s, %L, NULL)', 'ZZ99', co_req, 'approved'));
  PERFORM pg_temp.check(r->>'state' = 'approved' AND (SELECT phone FROM erp.company_profile WHERE company_code = 'ZZ99') = '+971 4 222 3333',
                        'finance manager approves: the change applies', r::text);

  -- ================= 10. Approval Status Report =================
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.approval_status_report('ZZ99', '{}')$q$), deny_admin, 'sales can''t open the status report');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.approval_status_report('ZZ99', '{"status":"late"}')$q$),
    'Choose a status: waiting, approved, rejected, cancelled or all.', 'unknown status refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.approval_status_report('ZZ99', '{"from":"2026-11-10","to":"2026-11-01"}')$q$),
    'The "to" date is before the "from" date.', 'to before from refused');
  r := pg_temp.call(it, format('SELECT erp.approval_status_report(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('template_id', t_in)));
  PERFORM pg_temp.check(jsonb_array_length(r->'rows') = 3
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'doc_no' = p2::text AND x->>'status' = 'approved'
                                      AND x->>'templates' = 'B2 Incoming over 1,000' AND (x->'trail'->0->>'approvals')::int = 2)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'doc_no' = p3::text AND x->>'status' = 'rejected'),
                        'report by template: 3 requests (approved with 2 votes, rejected …)', left(r::text, 400));
  r := pg_temp.call(it, $q$SELECT erp.approval_status_report('ZZ99', '{"status":"pending","kind":"payment"}')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'status' <> 'pending'),
                        'report filtered on waiting payments', left(r::text, 200));

  -- ================= 11. Positions used by templates =================
  PERFORM pg_temp.ok(pg_temp.call(admin, $q$SELECT erp.position_save('QA_B2_TMP', 'QA · B2 temporary', true)$q$), 'temporary position created');
  PERFORM pg_temp.ok(pg_temp.stage(admin, '{"name":"B2 Temp stage","authorizers":[{"position_code":"QA_B2_TMP"}]}'), 'stage with the temporary position');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.position_delete('QA_B2_TMP')$q$),
    'Position QA_B2_TMP is used in 1 approval template(s) or stage(s). Change those first.', 'position used by a stage can''t be deleted');
  r := pg_temp.call(admin, 'SELECT erp.admin_positions()');
  PERFORM pg_temp.check((SELECT (p->>'rules')::int FROM jsonb_array_elements(r->'positions') p WHERE p->>'position_code' = 'QA_B2_TMP') = 1,
                        'Authorizations matrix counts template / stage use');

  -- ================= 12. System health =================
  r := pg_temp.call(admin, 'SELECT erp.system_health()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'files') f WHERE f->>'file' = '31_approvals.sql' AND (f->>'present')::boolean)
                        OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'files') f WHERE f->>'file_name' = '31_approvals.sql' AND (f->>'present')::boolean),
                        'system health knows 31_approvals.sql', left(r->>'files', 200));
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM b2_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM b2_result;
ROLLBACK;
