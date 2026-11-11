-- B5 · Open items: substitute authorizers, landed costs in a foreign currency, credit memos across rates, foreign-currency
-- list views, period-end exchange rate revaluation. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (sql-order.txt incl. 34_open_items.sql). Everything happens in one transaction that is rolled back.
-- Prints PASS/FAIL · name · detail, then a TOTAL row.
--
-- Rates used (entered by QA Finance below): USD 10 Nov 3.6725 · 12 Nov 3.68 · 15 Nov 3.65 · 20 Nov 3.70 · 30 Nov 3.75 · 15 Dec 3.75.
-- Fixture (rolled back): customer C0013 trades in USD. Supplier S0001 trades in USD (sample data).
BEGIN;

CREATE TEMP TABLE b5_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON b5_result TO authenticated;

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
  INSERT INTO b5_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.ssave(u uuid, obj integer, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_save(%L, %s, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', obj, h, l))
$$;
CREATE FUNCTION pg_temp.ssubmit(u uuid, obj integer, e integer, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_submit(%L, %s, %s, %L)', 'ZZ99', obj, e, reason))
$$;
CREATE FUNCTION pg_temp.psave(u uuid, obj integer, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.purchase_doc_save(%L, %s, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', obj, h, l))
$$;
CREATE FUNCTION pg_temp.psubmit(u uuid, obj integer, e integer, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.purchase_doc_submit(%L, %s, %s, %L)', 'ZZ99', obj, e, reason))
$$;
CREATE FUNCTION pg_temp.pay(u uuid, dir text, h jsonb, l jsonb, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.payment_submit(%L, %L, %L::jsonb, %L::jsonb, %L)', 'ZZ99', dir, h, l, reason))
$$;
CREATE FUNCTION pg_temp.sub(u uuid, j jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.approval_substitute_save(%L, %L::jsonb)', 'ZZ99', j))
$$;
CREATE FUNCTION pg_temp.fxr(u uuid, fn text, j jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.fx_revaluation_%s(%L, %L::jsonb)', fn, 'ZZ99', j))
$$;
CREATE FUNCTION pg_temp.journal(u uuid, amount numeric, memo text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r jsonb; d integer;
BEGIN
  r := pg_temp.call(u, format('SELECT erp.journal_draft_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', json_build_object('ref_date', '2026-11-09', 'memo', memo),
                             json_build_array(json_build_object('acct_code', '6200', 'debit', amount), json_build_object('acct_code', '1110', 'credit', amount))));
  d := (r->>'draft_id')::integer;
  PERFORM pg_temp.call(u, format('SELECT erp.journal_submit(%L, %s, %L)', 'ZZ99', d, 'B5 test'));
  RETURN d;
END $$;
CREATE FUNCTION pg_temp.jdecide(u uuid, d integer, p_dec text DEFAULT 'approved') RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.journal_decide(%L, %s, %L, %L)', 'ZZ99', d, p_dec, CASE WHEN p_dec = 'rejected' THEN 'B5 no' END))
$$;
CREATE FUNCTION pg_temp.doc(obj integer, e integer) RETURNS erp.document LANGUAGE sql AS $$
  SELECT * FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = obj AND doc_entry = e
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.balanced(p_trans integer) RETURNS boolean LANGUAGE sql AS $$
  SELECT sum(debit) = sum(credit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;

UPDATE erp.business_partner SET currency = 'USD' WHERE company_code = 'ZZ99' AND card_code = 'C0013';

-- ======================================================================= 1. Substitute authorizers
DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  smgr   uuid := '00000000-0000-4000-8000-000000000007';
  fmgr   uuid := '00000000-0000-4000-8000-000000000008';
  r jsonb; st bigint; st2 bigint; s1 bigint; s2 bigint; d1 integer; d2 integer; d3 integer; d4 integer; ap bigint;
  today date := current_date;
BEGIN
  -- Stages: the finance manager alone; and a stage needing two approvals (finance manager + owner).
  PERFORM pg_temp.call(admin, format('SELECT erp.approval_template_set_active(%L, %s, false)', 'ZZ99',
          (SELECT template_id FROM erp.apr_template WHERE company_code = 'ZZ99' AND kind = 'journal_amount' AND legacy_key IS NOT NULL)));
  r := pg_temp.call(admin, format('SELECT erp.approval_stage_save(%L, %L::jsonb)', 'ZZ99', format('{"name":"B5 Finance manager","authorizers":[{"user_id":"%s"}]}', fmgr)));
  st := (r->>'stage_id')::bigint;
  r := pg_temp.call(admin, format('SELECT erp.approval_stage_save(%L, %L::jsonb)', 'ZZ99',
         format('{"name":"B5 Two approvals","required_approvals":2,"authorizers":[{"user_id":"%s"},{"user_id":"%s"}]}', fmgr, owner)));
  st2 := (r->>'stage_id')::bigint;
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_template_save(%L, %L::jsonb)', 'ZZ99',
          format('{"name":"B5 Journals","kind":"journal_amount","stages":[%s],"originators":[{"user_id":"%s"}],"conditions":[{"field":"amount","op":"between","value1":10000,"value2":100000}]}', st, fin))),
    'fixture: journal template 10,000–100,000 → stage "B5 Finance manager"');
  PERFORM pg_temp.ok(pg_temp.call(admin, format('SELECT erp.approval_template_save(%L, %L::jsonb)', 'ZZ99',
          format('{"name":"B5 Big journals","kind":"journal_amount","stages":[%s],"originators":[{"user_id":"%s"}],"conditions":[{"field":"amount","op":"between","value1":200000,"value2":300000}]}', st2, fin))),
    'fixture: journal template 200,000–300,000 → stage "B5 Two approvals"');

  -- ---- who may name a substitute, and the rules
  PERFORM pg_temp.expect(pg_temp.sub(NULL, '{}'), 'Sign in first.', 'anonymous refused');
  PERFORM pg_temp.expect(pg_temp.sub(nobody, '{}'), 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.', 'no profile refused');
  PERFORM pg_temp.expect(pg_temp.sub(sales, format('{"user_id":"%s","substitute_id":"%s","from_date":"%s","to_date":"%s"}', fmgr, admin, today, today + 5)::jsonb),
    'Only Administration (full access) can name a substitute for someone else. You can set your own substitute.', 'a user can''t name a substitute for someone else');
  PERFORM pg_temp.expect(pg_temp.sub(sales, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s"}', admin, today, today + 5)::jsonb),
    'QA Sales is not an authorizer of any approval stage in ZZ99, so there is nothing to hand over.', 'only stage authorizers can hand over');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s"}', fmgr, today, today + 5)::jsonb),
    'An authorizer can''t be their own substitute. Choose someone else.', 'own substitute refused');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"from_date":"%s","to_date":"%s"}', today, today + 5)::jsonb), 'Choose the substitute.', 'substitute required');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s"}', nobody, today, today + 5)::jsonb),
    '00000000-0000-4000-8000-000000000003 has no active access to ZZ99, so they can''t be a substitute.', 'substitute without access to the company refused');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s"}', admin)::jsonb), 'Enter the start and end dates.', 'dates required');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"soon","to_date":"%s"}', admin, today)::jsonb), 'Enter the dates as YYYY-MM-DD.', 'bad date refused');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s"}', admin, today + 3, today + 1)::jsonb),
    'The end date is before the start date.', 'end before start refused');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s"}', admin, today - 5, today - 1)::jsonb),
    'The end date has already passed. Choose an end date from today on.', 'a range in the past refused');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s"}', admin, today, today + 400)::jsonb),
    'A substitution can last up to one year. Split longer absences.', 'more than a year refused');

  r := pg_temp.sub(fmgr, format('{"substitute_id":"%s","from_date":"%s","to_date":"%s","note":"Annual leave"}', admin, today, today + 7)::jsonb);
  s1 := (r->>'sub_id')::bigint;
  PERFORM pg_temp.check(r->>'status' = 'active' AND r->>'substitute_name' = 'QA Admin', 'the authorizer names their own substitute (active from today)', left(r::text, 300));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_substitute_create' AND object_ref = s1::text AND (detail->>'own')::boolean),
    'audit: approval_substitute_create (own)');
  PERFORM pg_temp.expect(pg_temp.sub(admin, format('{"user_id":"%s","substitute_id":"%s","from_date":"%s","to_date":"%s"}', fmgr, owner, today + 2, today + 9)::jsonb),
    format('QA Finance Manager already has a substitute from %s to %s (QA Admin). Change or end that one first.', erp._day(today), erp._day(today + 7)), 'overlapping substitution refused');
  r := pg_temp.sub(admin, format('{"user_id":"%s","substitute_id":"%s","from_date":"%s","to_date":"%s"}', fmgr, sales, today + 10, today + 12)::jsonb);
  s2 := (r->>'sub_id')::bigint;
  PERFORM pg_temp.check(r->>'status' = 'planned', 'Administration names a substitute for someone else (planned, later dates)', left(r::text, 300));
  PERFORM pg_temp.check(jsonb_array_length(pg_temp.call(fmgr, $q$SELECT erp.approval_substitute_list('ZZ99')$q$)->'rows') = 2
                        AND jsonb_array_length(pg_temp.call(sales, $q$SELECT erp.approval_substitute_list('ZZ99')$q$)->'rows') = 1
                        AND jsonb_array_length(pg_temp.call(admin, $q$SELECT erp.approval_substitute_list('ZZ99')$q$)->'rows') = 2
                        AND jsonb_array_length(pg_temp.call(owner, $q$SELECT erp.approval_substitute_list('ZZ99')$q$)->'rows') = 2
                        AND jsonb_array_length(pg_temp.call(smgr, $q$SELECT erp.approval_substitute_list('ZZ99')$q$)->'rows') = 0,
    'list: the authorizer sees theirs, a substitute theirs, Administration / owner (A10 read) all, others none');
  PERFORM pg_temp.check(pg_temp.call(smgr, $q$SELECT to_jsonb(count(*)) FROM erp.apr_substitute$q$) = '0'::jsonb
                        AND pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.apr_substitute$q$) = '1'::jsonb, 'table read follows the same rule (RLS)');
  PERFORM pg_temp.check(pg_temp.call(fmgr, $q$UPDATE erp.apr_substitute SET to_date = to_date + 1 RETURNING 1$q$)->>'error' = '42501', 'no direct writes');

  -- ---- allowed: the active substitute decides, on behalf of the authorizer
  d1 := pg_temp.journal(fin, 60000, 'B5 sub 1');
  PERFORM pg_temp.check((SELECT state FROM erp.journal_draft WHERE draft_id = d1) = 'pending_approval', 'journal 60,000 waits for stage "B5 Finance manager"');
  r := pg_temp.call(admin, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check((r->>'is_approver')::boolean AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w
                           WHERE w->>'kind' = 'journal' AND (w->>'doc_entry')::integer = d1 AND w->>'on_behalf_of_name' = 'QA Finance Manager'),
    'the substitute''s inbox lists it "on behalf of QA Finance Manager"', left(r->>'waiting', 300));
  PERFORM pg_temp.check((pg_temp.call(admin, format('SELECT erp.journal_draft_info(%L, %s)', 'ZZ99', d1))->>'can_decide')::boolean, 'journal page: the substitute may decide');
  r := pg_temp.jdecide(admin, d1);
  PERFORM pg_temp.check(r->>'state' = 'posted', 'the substitute approves: the journal posts', r::text);
  ap := (SELECT approval_id FROM erp.approval WHERE object = 'journal' AND object_ref = d1::text);
  PERFORM pg_temp.check((SELECT on_behalf_of = fmgr FROM erp.approval_vote WHERE approval_id = ap AND user_id = admin)
                        AND (SELECT on_behalf_of = fmgr AND approver_user = admin FROM erp.approval WHERE approval_id = ap),
    'the vote and the decision record "on behalf of" the finance manager');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_vote_on_behalf' AND object_ref = ap::text AND detail->>'on_behalf_of_name' = 'QA Finance Manager'),
    'audit: approval_vote_on_behalf');
  r := pg_temp.call(admin, format('SELECT erp.journal_draft_info(%L, %s)', 'ZZ99', d1));
  PERFORM pg_temp.check(r->'approvals'->0->'votes'->0->>'on_behalf_of_name' = 'QA Finance Manager'
                        AND erp._apr_trail('ZZ99', 'journal', d1::text)->0->>'decided_on_behalf_of_name' = 'QA Finance Manager',
    'the journal page and the approval trail show "on behalf of"', left(r->>'approvals', 300));

  -- ---- refused: the authorizer can't vote again after their substitute (one person, one vote)
  d2 := pg_temp.journal(fin, 250000, 'B5 sub 2');
  r := pg_temp.jdecide(admin, d2);
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'two-approval stage: the substitute''s vote counts once (1 of 2)', r::text);
  PERFORM pg_temp.check(NOT erp._apr_is_mine((SELECT approval_id FROM erp.approval WHERE object = 'journal' AND object_ref = d2::text), (SELECT u FROM erp.app_user u WHERE user_id = fmgr)),
    'the finance manager can''t vote on top of their substitute');
  PERFORM pg_temp.expect(pg_temp.jdecide(fmgr, d2), 'This journal is waiting for approval from QA Finance Manager or QA Owner. Your position can''t decide it.',
    'the authorizer''s second vote is refused');

  -- ---- refused: a planned substitution (not started) and an expired one
  UPDATE erp.apr_substitute SET from_date = today + 1 WHERE sub_id = s1;   -- fixture: starts tomorrow
  d3 := pg_temp.journal(fin, 61000, 'B5 sub 3');
  PERFORM pg_temp.expect(pg_temp.jdecide(admin, d3), 'This journal is waiting for approval from QA Finance Manager. Your position can''t decide it.',
    'a substitution that starts tomorrow does not work today');
  UPDATE erp.apr_substitute SET from_date = today - 10, to_date = today - 1 WHERE sub_id = s1;   -- fixture: ended yesterday
  PERFORM pg_temp.expect(pg_temp.jdecide(admin, d3), 'This journal is waiting for approval from QA Finance Manager. Your position can''t decide it.',
    'an expired substitution stops working');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.call(admin, 'SELECT erp.approval_inbox()')->'waiting') w WHERE w->>'kind' = 'journal' AND (w->>'doc_entry')::integer = d3)
                        AND (SELECT r2->>'status' FROM jsonb_array_elements(pg_temp.call(fmgr, $q$SELECT erp.approval_substitute_list('ZZ99')$q$)->'rows') r2
                              WHERE (r2->>'sub_id')::bigint = s1) = 'expired',
    'expired: the request leaves the substitute''s inbox; the list says expired');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"sub_id":%s,"substitute_id":"%s","from_date":"%s","to_date":"%s"}', s1, admin, today, today + 3)::jsonb),
    'This substitution has expired. Add a new one instead.', 'an expired substitution can''t be edited');
  UPDATE erp.apr_substitute SET from_date = today, to_date = today + 7 WHERE sub_id = s1;
  PERFORM pg_temp.check(pg_temp.jdecide(admin, d3)->>'state' = 'posted', 'active again: the substitute decides');

  -- ---- end early
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.approval_substitute_end(%L, %s)', 'ZZ99', s1)),
    'Only Administration (full access) can end someone else''s substitution.', 'others can''t end it');
  PERFORM pg_temp.check(pg_temp.call(fmgr, format('SELECT erp.approval_substitute_end(%L, %s)', 'ZZ99', s1))->>'status' = 'ended', 'the authorizer ends it early');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_substitute_end' AND object_ref = s1::text), 'audit: approval_substitute_end');
  d4 := pg_temp.journal(fin, 62000, 'B5 sub 4');
  PERFORM pg_temp.expect(pg_temp.jdecide(admin, d4), 'This journal is waiting for approval from QA Finance Manager. Your position can''t decide it.',
    'an ended substitution stops at once');
  PERFORM pg_temp.expect(pg_temp.call(fmgr, format('SELECT erp.approval_substitute_end(%L, %s)', 'ZZ99', s1)), 'This substitution has already ended.', 'ending twice refused');
  PERFORM pg_temp.expect(pg_temp.sub(fmgr, format('{"sub_id":%s,"substitute_id":"%s","from_date":"%s","to_date":"%s"}', s1, admin, today, today + 3)::jsonb),
    'This substitution has ended. Add a new one instead.', 'an ended substitution can''t be edited');
  PERFORM pg_temp.check(pg_temp.jdecide(fmgr, d4)->>'state' = 'posted', 'the authorizer still decides their own requests');
  r := pg_temp.sub(admin, format('{"sub_id":%s,"substitute_id":"%s","from_date":"%s","to_date":"%s"}', s2, admin, today + 10, today + 14)::jsonb);
  PERFORM pg_temp.check(r->>'substitute_name' = 'QA Admin' AND (r->>'to_date')::date = today + 14
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'approval_substitute_change' AND object_ref = s2::text),
    'Administration changes a planned substitution (audited)', left(r::text, 200));
END $$;

-- ======================================================================= 2. Credit memo across rates
DO $$
DECLARE
  sales uuid := '00000000-0000-4000-8000-000000000002';
  fin   uuid := '00000000-0000-4000-8000-000000000004';
  r jsonb; d erp.document; so integer; dl1 integer; dl2 integer; inv1 integer; inv2 integer; cm integer; t integer;
BEGIN
  PERFORM pg_temp.ok(pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-10', 'USD', 3.6725)$q$), 'rates: USD 10 Nov');
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-12', 'USD', 3.68)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-15', 'USD', 3.65)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-20', 'USD', 3.70)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-30', 'USD', 3.75)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-12-15', 'USD', 3.75)$q$);

  r := pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":4,"price":40}]');
  so := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ssubmit(sales, 17, so);
  dl1 := (pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":2}]')$q$, so))->>'doc_entry')::integer;
  dl2 := (pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":2}]')$q$, so))->>'doc_entry')::integer;
  inv1 := (pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":2}]')$q$, dl1))->>'doc_entry')::integer;
  inv2 := (pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":2}]')$q$, dl2))->>'doc_entry')::integer;
  PERFORM pg_temp.check((pg_temp.doc(13, inv1)).fx_rate = 3.65 AND (pg_temp.doc(13, inv1)).total = 306.60 AND (pg_temp.doc(13, inv2)).fx_rate = 3.70 AND (pg_temp.doc(13, inv2)).total = 310.80,
    'two USD invoices: 84 USD at 3.65 = 306.60 AED, 84 USD at 3.70 = 310.80 AED');

  -- one credit memo copying both invoices (B4 refused this), with a typed rate that copied lines don't use
  r := pg_temp.call(sales, format($q$SELECT erp.sales_credit_memo_create('ZZ99', '{"doc_date":"2026-11-20","fx_rate":3.5}', '[{"base_doc_entry":%s,"base_line":0,"qty":2},{"base_doc_entry":%s,"base_line":0,"qty":2}]')$q$, inv1, inv2));
  cm := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(cm IS NOT NULL, 'a credit memo may copy invoices with different rates (and a typed rate is no longer refused)', left(r::text, 300));
  d := pg_temp.doc(14, cm);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.total_fc = 168 AND d.total = 617.40 AND d.fx_rate = 3.675,
    'credit memo: 168 USD = 617.40 AED (each line at its invoice''s rate); header shows the average 3.675', format('%s %s %s %s', d.currency, d.total_fc, d.total, d.fx_rate));
  PERFORM pg_temp.check((SELECT string_agg(trim_scale(line_total) || '+' || trim_scale(vat), ' ' ORDER BY line_num) FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 14 AND doc_entry = cm) = '292+14.6 296+14.8',
    'lines: 80 USD at 3.65 = 292.00 (+14.60 VAT), 80 USD at 3.70 = 296.00 (+14.80 VAT)');
  PERFORM pg_temp.check(erp._bk_doc_open('ZZ99', 13, inv1) = 0 AND erp._bk_doc_open('ZZ99', 13, inv2) = 0 AND erp._bk_doc_open_fc('ZZ99', 13, inv1) = 0 AND erp._bk_doc_open_fc('ZZ99', 13, inv2) = 0,
    'both invoices net to exactly 0 in AED and USD');
  t := (SELECT trans_id FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 14 AND doc_entry = cm);
  PERFORM pg_temp.check(pg_temp.balanced(t) AND (SELECT credit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t AND short_name = 'C0013') = 617.40,
    'credit memo journal: A/R credited 617.40 (the two invoices'' AED), balanced', pg_temp.jl(t));

  -- one invoice, a typed rate: the invoice's rate is kept
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":1,"price":100}]');
  so := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ssubmit(sales, 17, so);
  dl1 := (pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, so))->>'doc_entry')::integer;
  inv1 := (pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, dl1))->>'doc_entry')::integer;
  r := pg_temp.call(sales, format($q$SELECT erp.sales_credit_memo_create('ZZ99', '{"doc_date":"2026-11-30","fx_rate":3.9}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, inv1));
  d := pg_temp.doc(14, (r->>'doc_entry')::integer);
  PERFORM pg_temp.check(d.fx_rate = 3.65 AND d.total = 383.25 AND (r->>'fx_rate')::numeric = 3.65 AND erp._bk_doc_open('ZZ99', 13, inv1) = 0,
    'credit memo dated 30 Nov (rate 3.75) keeps the invoice rate 3.65: 105 USD = 383.25 AED, invoice nets to 0', format('%s %s', d.fx_rate, d.total));
END $$;

-- ======================================================================= 3. Landed costs in a foreign currency
DO $$
DECLARE
  purch uuid := '00000000-0000-4000-8000-000000000010';
  fin   uuid := '00000000-0000-4000-8000-000000000004';
  r jsonb; po integer; gr integer; ap integer; lc integer; t integer; v_ap text;
  h jsonb; ln jsonb;
BEGIN
  r := pg_temp.psave(purch, 22, '{"card_code":"S0001","doc_date":"2026-11-10","due_date":"2026-12-31","whs_code":"WH01"}', '[{"item_code":"SMP-1140","qty":100,"price":10}]');
  po := (r->>'doc_entry')::integer;
  PERFORM pg_temp.psubmit(purch, 22, po);
  gr := (pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, po))->>'doc_entry')::integer;
  ap := (pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-15","customer_ref":"B5-AP"}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, gr))->>'doc_entry')::integer;
  v_ap := erp._sd_no('ZZ99', 18, ap);
  PERFORM pg_temp.check((pg_temp.doc(18, ap)).total_fc = 1050 AND (pg_temp.doc(18, ap)).fx_rate = 3.65, 'fixture: USD goods receipt (3.6725) and the supplier''s A/P invoice 1,050 USD at 3.65');
  h := '{"doc_date":"2026-11-20","card_code":"S0001","reference":"B5 duty"}';
  ln := format('[{"grpo_entry":%s,"grpo_line":0}]', gr)::jsonb;

  -- preview in USD at the landed cost date's rate (20 Nov 3.70); value split on the receipt's AED value
  r := pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"DUTY","amount":100,"currency":"USD"}]'));
  PERFORM pg_temp.check((r->'charges'->0->>'amount')::numeric = 370 AND (r->'charges'->0->>'amount_fc')::numeric = 100 AND (r->'charges'->0->>'fx_rate')::numeric = 3.70
                        AND r->'charges'->0->>'currency' = 'USD' AND (r->'lines'->0->>'value')::numeric = 3672.50 AND (r->'totals'->>'total')::numeric = 370,
    'charge 100 USD at 3.70 = 370.00 AED; the receipt''s value basis is its AED value 3,672.50', left(r::text, 400));
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"DUTY","amount":100,"currency":"EUR"}]')),
    'Landed cost 1 (Customs duty): There is no exchange rate for EUR on 20 Nov 2026. Enter it in Administration › Exchange Rates, then try again.', 'a charge currency without a rate refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"DUTY","amount":100,"currency":"JPY"}]')),
    'Landed cost 1 (Customs duty): Currency JPY is not in the rates list of ZZ99 (USD, SAR, CNY, EUR).', 'a currency outside the rates list refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"DUTY","amount":100,"currency":"USD","fx_rate":3.8}]')),
    'Landed cost 1 (Customs duty): Only Financials can change the exchange rate. The rate for USD on 20 Nov 2026 is 3.7.', 'Purchasing can''t type another rate');
  r := pg_temp.call(fin, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"DUTY","amount":100,"currency":"USD","fx_rate":3.8}]'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->'charges'->0->>'amount')::numeric = 380, 'Financials may type another rate (100 USD at 3.80 = 380.00)', left(r::text, 200));

  -- linked broker invoice: wrong currency, wrong supplier, too much
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, format('[{"code":"DUTY","amount":100,"ap_invoice_entry":%s}]', ap))),
    format('Landed cost 1 (Customs duty): A/P invoice %s is in USD, but this charge is in AED. Enter the charge in the invoice''s currency.', v_ap), 'linked invoice in another currency refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', '{"doc_date":"2026-11-20","card_code":"S0009"}', ln,
                                                    format('[{"code":"DUTY","amount":100,"currency":"USD","ap_invoice_entry":%s}]', ap))),
    format('Landed cost 1 (Customs duty): A/P invoice %s is from S0001, not from the broker S0009.', v_ap), 'linked invoice of another supplier refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, format('[{"code":"DUTY","amount":1001,"currency":"USD","ap_invoice_entry":%s}]', ap))),
    format('Landed cost 1 (Customs duty): A/P invoice %s has 1,000.00 USD left to link (net of VAT), less than 1,001.00 USD.', v_ap), 'linking more than the invoice refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"DUTY","amount":10,"currency":"USD","ap_invoice_entry":999999}]')),
    'Landed cost 1 (Customs duty): A/P invoice 999999 was not found in ZZ99.', 'unknown invoice refused');

  -- post: allocation at 3.70 (370.00), clearing at the invoice's 3.65 (365.00), gain 5.00
  r := pg_temp.call(purch, format('SELECT erp.landed_cost_create(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, format('[{"code":"DUTY","amount":100,"currency":"USD","ap_invoice_entry":%s}]', ap)));
  lc := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check((r->>'total')::numeric = 370 AND (r->>'fx_diff')::numeric = -5, 'landed cost posted: 370.00 AED capitalised, rate difference −5.00', left(r::text, 300));
  t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.balanced(t) AND pg_temp.jl(t) ~ '^1300 Dr 370, [0-9]+ Cr 365, 7100 Cr 5$',
    'journal: inventory 370.00 / clearing 365.00 (= the invoice''s AED) / exchange gain 5.00', pg_temp.jl(t));
  PERFORM pg_temp.check((SELECT currency = 'USD' AND amount_fc = 100 AND fx_rate = 3.70 AND amount = 370 AND ap_invoice_entry = ap AND clear_amount = 365 AND fx_diff = -5
                           FROM erp.landed_cost_charge WHERE company_code = 'ZZ99' AND doc_entry = lc),
    'charge stored with currency, FC amount, rate, linked invoice, clearing and difference');
  r := pg_temp.call(purch, format('SELECT erp.landed_cost_info(%L, %s)', 'ZZ99', lc));
  PERFORM pg_temp.check(r->'charges'->0->>'currency' = 'USD' AND (r->'charges'->0->>'amount_fc')::numeric = 100 AND r->'charges'->0->>'ap_invoice_no' = v_ap,
    'landed cost page shows the charge in USD with its invoice', left(r->>'charges', 300));
  PERFORM pg_temp.expect(pg_temp.call(purch, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, format('[{"code":"FREIGHT","amount":950,"currency":"USD","ap_invoice_entry":%s}]', ap))),
    format('Landed cost 1 (Sea freight): A/P invoice %s has 900.00 USD left to link (net of VAT), less than 950.00 USD.', v_ap), 'what earlier landed costs linked counts');
  -- unlinked USD charge: clearing at the landed cost's own rate, no difference
  r := pg_temp.call(purch, format('SELECT erp.landed_cost_create(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, ln, '[{"code":"INSURANCE","amount":10,"currency":"USD"}]'));
  PERFORM pg_temp.check((r->>'fx_diff')::numeric = 0 AND pg_temp.jl((r->>'trans_id')::integer) ~ '^1300 Dr 37, [0-9]+ Cr 37$', 'an unlinked USD charge clears at its own AED (no difference)', pg_temp.jl((r->>'trans_id')::integer));
END $$;

-- ======================================================================= 4. Foreign-currency totals on lists
DO $$
DECLARE
  sales uuid := '00000000-0000-4000-8000-000000000002';
  purch uuid := '00000000-0000-4000-8000-000000000010';
  r jsonb;
BEGIN
  PERFORM pg_temp.check(NOT EXISTS (
      SELECT v.n, c.column_name FROM (VALUES ('sales_doc_list', 'sales_doc_list_fc'), ('purchase_doc_list', 'purchase_doc_list_fc'), ('payment_list', 'payment_list_fc')) v(o, n)
        JOIN information_schema.columns c ON c.table_schema = 'erp' AND c.table_name = v.o
       WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c2 WHERE c2.table_schema = 'erp' AND c2.table_name = v.n AND c2.column_name = c.column_name AND c2.ordinal_position = c.ordinal_position)),
    'the new *_fc views keep every column of the earlier views in the same place');
  r := pg_temp.call(sales, $q$SELECT jsonb_agg(row_to_json(l)) FROM erp.sales_doc_list_fc l WHERE company_code = 'ZZ99' AND obj_type = 13 AND card_code = 'C0013' AND source = 'erp'$q$);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'currency' = 'USD' AND (x->>'total_fc')::numeric = 84 AND (x->>'total')::numeric = 306.60
                                   AND x->>'local_currency' = 'AED' AND (x->>'fx_rate')::numeric = 3.65),
    'sales list view: USD invoice with total 306.60 AED and 84.00 USD', left(r::text, 300));
  r := pg_temp.call(sales, $q$SELECT jsonb_agg(row_to_json(l)) FROM erp.sales_doc_list_fc l WHERE company_code = 'ZZ99' AND obj_type = 13 AND currency = 'AED' LIMIT 1$q$);
  PERFORM pg_temp.check(r IS NULL OR r = 'null'::jsonb OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'total_fc' IS NOT NULL),
    'AED documents have no FC total');
  r := pg_temp.call(purch, $q$SELECT row_to_json(l)::jsonb FROM erp.purchase_doc_list_fc l WHERE company_code = 'ZZ99' AND obj_type = 18 AND customer_ref = 'B5-AP'$q$);
  PERFORM pg_temp.check((r->>'total_fc')::numeric = 1050 AND (r->>'total')::numeric = 3832.50 AND r->>'currency' = 'USD', 'purchasing list view: A/P invoice 3,832.50 AED and 1,050.00 USD', r::text);
  PERFORM pg_temp.check(pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.purchase_doc_list_fc WHERE company_code = 'ZZ99' AND customer_ref = 'B5-AP'$q$)
                        = pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.purchase_doc_list WHERE company_code = 'ZZ99' AND customer_ref = 'B5-AP'$q$),
    'the new views follow the same row rules as the earlier ones (security invoker)');
END $$;

-- ======================================================================= 5. Period-end exchange rate revaluation
DO $$
DECLARE
  sales uuid := '00000000-0000-4000-8000-000000000002';
  fin   uuid := '00000000-0000-4000-8000-000000000004';
  r jsonb; so integer; dl integer; inv integer; v1 bigint; v2 bigint; v3 bigint; t integer; rt integer; n integer;
BEGIN
  -- open items: a USD invoice of C0013 (525 USD at 3.65, 200 USD paid on 20 Nov) and the A/P invoice of S0001 above (1,050 USD at 3.65)
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":10,"price":50}]');
  so := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ssubmit(sales, 17, so);
  dl := (pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":10}]')$q$, so))->>'doc_entry')::integer;
  inv := (pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":10}]')$q$, dl))->>'doc_entry')::integer;
  PERFORM pg_temp.ok(pg_temp.pay(fin, 'I', '{"card_code":"C0013","doc_date":"2026-11-20","transfer":200,"transfer_bank":"BNK-AED","transfer_ref":"B5-IN"}',
                                 format('[{"obj_type":13,"doc_entry":%s,"amount":200}]', inv)::jsonb), 'fixture: 200 USD received on 20 Nov');

  -- rights and input
  PERFORM pg_temp.expect(pg_temp.fxr(sales, 'preview', '{"date":"2026-11-30"}'), 'Your position does not include Financials. Ask the system admin if you need it.', 'Financials only');
  PERFORM pg_temp.expect(pg_temp.fxr(NULL, 'post', '{"date":"2026-11-30"}'), 'Sign in first.', 'anonymous refused');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'preview', '{}'), 'Choose the revaluation date.', 'date required');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'preview', '{"date":"2026-11-30","currencies":["AED"]}'), 'AED is the company currency of ZZ99. Choose foreign currencies only.', 'company currency refused');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'preview', '{"date":"2026-11-29"}'),
    'There is no exchange rate for USD on 29 Nov 2026. Enter it in Administration › Exchange Rates, then try again.', 'missing rate for the date refused');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'preview', '{"date":"2026-11-30","rates":{"USD":0}}'), 'The exchange rate for USD must be more than 0.', 'rate must be above 0');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'preview', '{"date":"2026-11-01"}'), 'There are no open foreign-currency items in ZZ99 on 01 Nov 2026.', 'nothing open on the date');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'post', '{"date":"2026-11-30","currencies":["EUR"],"rates":{"EUR":4}}'), 'There are no open foreign-currency items in ZZ99 on 30 Nov 2026.',
    'nothing open in the chosen currency');

  -- preview: as of 30 Nov at 3.75
  r := pg_temp.fxr(fin, 'preview', '{"date":"2026-11-30"}');
  PERFORM pg_temp.check(jsonb_array_length(r->'rows') = 2
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'card_code' = 'C0013' AND x->>'side' = 'receivable' AND (x->>'open_fc')::numeric = 325
                                      AND (x->>'book_lc')::numeric = 1186.25 AND (x->>'new_lc')::numeric = 1218.75 AND (x->>'gain')::numeric = 32.50)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'card_code' = 'S0001' AND x->>'side' = 'payable' AND (x->>'open_fc')::numeric = 1050
                                      AND (x->>'book_lc')::numeric = 3832.50 AND (x->>'new_lc')::numeric = 3937.50 AND (x->>'gain')::numeric = -105)
                        AND (r->'totals'->>'gain')::numeric = 32.50 AND (r->'totals'->>'loss')::numeric = 105 AND (r->>'reverse_date')::date = '2026-12-01',
    'preview: C0013 325 USD 1,186.25 → 1,218.75 (gain 32.50); S0001 owes 1,050 USD 3,832.50 → 3,937.50 (loss 105.00); reversal 1 Dec', left(r::text, 600));
  r := pg_temp.fxr(fin, 'preview', '{"date":"2026-11-19"}');
  PERFORM pg_temp.check(r->>'error' IS NOT NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'card_code' = 'C0013' AND (x->>'open_fc')::numeric <> 525),
    'as of 19 Nov the 20 Nov payment does not count yet (C0013 still owes 525 USD)', left(r::text, 300));

  -- post with the automatic reversal
  r := pg_temp.fxr(fin, 'post', '{"date":"2026-11-30","memo":"B5 November revaluation"}');
  v1 := (r->>'reval_id')::bigint;
  t := (r->>'trans_id')::integer; rt := (r->>'reverse_trans_id')::integer;
  PERFORM pg_temp.check(v1 IS NOT NULL AND (r->>'net')::numeric = -72.50 AND (r->>'reverse_date')::date = '2026-12-01', 'revaluation posted without approval: net −72.50 AED', left(r::text, 300));
  PERFORM pg_temp.check(pg_temp.jl(t) = '1200 Dr 32.5, 2100 Cr 105, 7110 Cr 32.5, 7210 Dr 105' AND pg_temp.balanced(t)
                        AND (SELECT string_agg(short_name, ',' ORDER BY line_id) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t AND short_name IN ('C0013', 'S0001')) = 'C0013,S0001',
    'journal: A/R +32.50 (C0013), A/P +105.00 (S0001), unrealised gain 7110, unrealised loss 7210', pg_temp.jl(t));
  PERFORM pg_temp.check((SELECT ref_date FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = rt) = '2026-12-01'
                        AND pg_temp.jl(rt) = '1200 Cr 32.5, 2100 Dr 105, 7110 Dr 32.5, 7210 Cr 105', 'automatic reversal on 1 Dec mirrors it', pg_temp.jl(rt));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.fx_revaluation_line WHERE reval_id = v1) = 2
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'fx_revaluation_post' AND object_ref = v1::text),
    'lines kept per partner; audit: fx_revaluation_post');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_draft WHERE memo = 'B5 November revaluation'), 'no journal approval is involved');
  -- idempotency
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'post', '{"date":"2026-11-30"}'),
    format('Open items on 30 Nov 2026 are already revalued (FXR-%s). Cancel that revaluation first if you need to run it again.', v1), 'the same date can''t be revalued twice');
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'post', '{"date":"2026-11-20"}'),
    format('A later revaluation (FXR-%s on 30 Nov 2026) is already posted. Cancel it first, or choose a date after 30 Nov 2026.', v1), 'an earlier date after a later revaluation refused');
  PERFORM pg_temp.check(pg_temp.call(fin, $q$SELECT to_jsonb(count(*)) FROM erp.fx_revaluation_list WHERE company_code = 'ZZ99'$q$) = '1'::jsonb
                        AND pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.fx_revaluation_list$q$) = '0'::jsonb, 'history: Financials reads it, Sales does not');
  r := pg_temp.call(fin, format('SELECT erp.fx_revaluation_info(%L, %s)', 'ZZ99', v1));
  PERFORM pg_temp.check(jsonb_array_length(r->'lines') = 2 AND jsonb_array_length(r->'journals') = 2 AND (r->>'can_cancel')::boolean, 'info: lines, both journals, may cancel', left(r::text, 200));

  -- cancel, then run again
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.fx_revaluation_cancel(%L, %s, NULL)', 'ZZ99', v1)), 'Add a reason for cancelling the revaluation.', 'cancel needs a reason');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.fx_revaluation_cancel(%L, %s, %L)', 'ZZ99', v1, 'x')),
    'Your position does not include Financials. Ask the system admin if you need it.', 'cancel: Financials only');
  r := pg_temp.call(fin, format('SELECT erp.fx_revaluation_cancel(%L, %s, %L)', 'ZZ99', v1, 'Wrong rate'));
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND jsonb_array_length(r->'trans_ids') = 2
                        AND (SELECT sum(debit) - sum(credit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND acct_code IN ('7110', '7210')) = 0,
    'cancel reverses the journal and its reversal (7110 / 7210 back to 0)', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.fx_revaluation_cancel(%L, %s, %L)', 'ZZ99', v1, 'again')), format('Revaluation FXR-%s is already cancelled.', v1), 'cancel twice refused');

  -- without the automatic reversal: the next revaluation starts from the revalued book value
  r := pg_temp.fxr(fin, 'post', '{"date":"2026-11-30","auto_reverse":false}');
  v2 := (r->>'reval_id')::bigint;
  PERFORM pg_temp.check(v2 IS NOT NULL AND r->>'reverse_trans_id' IS NULL AND (r->>'net')::numeric = -72.50, 'after cancelling, the date can be revalued again (no reversal this time)', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.fxr(fin, 'post', '{"date":"2026-12-15"}'), 'The open items are already at these rates on 15 Dec 2026. Nothing to post.',
    'the next revaluation counts the earlier one: same rate, nothing to post');
  r := pg_temp.fxr(fin, 'preview', '{"date":"2026-12-15","rates":{"USD":3.8}}');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'card_code' = 'C0013' AND (x->>'book_lc')::numeric = 1218.75 AND (x->>'gain')::numeric = 16.25)
                        AND (r->'rates'->'USD'->>'overridden')::boolean,
    'a typed rate (3.80, flagged): C0013''s book value 1,218.75 includes the November revaluation, gain 16.25', left(r::text, 400));

  -- period lock: the reversal date's period is locked
  PERFORM pg_temp.call(fin, format('SELECT erp.fx_revaluation_cancel(%L, %s, %L)', 'ZZ99', v2, 'Test the lock'));
  UPDATE erp.posting_period SET status = 'locked' WHERE company_code = 'ZZ99' AND period_code = '2026-12';
  r := pg_temp.fxr(fin, 'post', '{"date":"2026-11-30"}');
  PERFORM pg_temp.check(r->>'message' LIKE 'Posting period 2026-12 is locked%' AND NOT EXISTS (SELECT 1 FROM erp.fx_revaluation WHERE company_code = 'ZZ99' AND state = 'posted'),
    'the automatic reversal in a locked period refuses the whole revaluation', r->>'message');
  UPDATE erp.posting_period SET status = 'open' WHERE company_code = 'ZZ99' AND period_code = '2026-12';

  -- accounts must be set
  DELETE FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'fx_reval_loss';
  r := pg_temp.fxr(fin, 'post', '{"date":"2026-11-30"}');
  PERFORM pg_temp.check(r->>'error' IS NOT NULL AND r->>'message' LIKE '%Exchange rate differences – loss (revaluation)%', 'a missing loss account is named (G/L Account Determination)', r->>'message');

  -- setup, keys, health
  r := pg_temp.call(fin, $q$SELECT erp.fx_revaluation_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'gain_acct' = '7110' AND r->>'loss_acct' IS NULL AND (r->>'can_write')::boolean AND r->'open_currencies' ? 'USD' IS NOT NULL, 'setup: accounts, rights, currencies', left(r::text, 300));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.gl_posting_key) = 38 AND (SELECT count(*) FROM erp.gl_posting_key WHERE posting_key IN ('fx_reval_gain', 'fx_reval_loss') AND tab = 'general') = 2,
    'G/L Account Determination › General has the two revaluation keys (38 keys)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.gl_determination g JOIN erp.company c USING (company_code) WHERE g.posting_key IN ('fx_reval_gain', 'fx_reval_loss') AND c.company_code <> 'ZZ99'),
    'no revaluation accounts for real companies (empty until Finance enters them)');
  PERFORM pg_temp.check((SELECT count(*) FROM erp._health_files()) = 22 AND EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '34_open_items.sql' AND object = 'fx_revaluation_post'),
    'system health lists 34_open_items.sql (22 files)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.prosecdef AND (p.proname LIKE 'fx_revaluation%' OR p.proname LIKE 'approval_substitute%' OR p.proname LIKE '\_fxr%' OR p.proname LIKE '\_apr\_sub%')
                                       AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=erp, pg_temp%', false))),
    'new SECURITY DEFINER functions: search_path set, no anon execute');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM b5_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM b5_result;
ROLLBACK;
