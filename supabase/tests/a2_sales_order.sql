-- A2 · Sales order with approval tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run after 10–16, test-users.sql and 17_sales_order.sql. Everything happens inside one transaction that is rolled back,
-- so the database is unchanged afterwards. Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a2_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a2_result TO authenticated;

-- Run one SQL expression as a user (RLS and grants apply) and return its jsonb result, or {error, message} if it raised.
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
CREATE FUNCTION pg_temp.save(p_user uuid, p_entry integer, p_header jsonb, p_lines jsonb, p_company text DEFAULT 'ZZ99') RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.sales_order_save(%L, %s, %L::jsonb, %L::jsonb)', p_company, coalesce(p_entry::text, 'NULL'), p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.checks(p_user uuid, p_header jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.sales_order_checks(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.submit(p_user uuid, p_entry integer, p_reason text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.sales_order_submit(%L, %s, %L)', 'ZZ99', p_entry, p_reason))
$$;
CREATE FUNCTION pg_temp.decide(p_user uuid, p_entry integer, p_decision text, p_note text, p_disc numeric DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.sales_order_decide(%L, %s, %L, %L, %s)', 'ZZ99', p_entry, p_decision, p_note, coalesce(p_disc::text, 'NULL')))
$$;
CREATE FUNCTION pg_temp.cancel(p_user uuid, p_entry integer, p_note text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.sales_order_cancel(%L, %s, %L)', 'ZZ99', p_entry, p_note))
$$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a2_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
-- Expect an error with exactly this message.
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 120)))
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  sread  uuid := '00000000-0000-4000-8000-000000000006';
  mgr    uuid := '00000000-0000-4000-8000-000000000007';
  h      jsonb := '{"card_code":"C0011","doc_date":"2026-11-09","due_date":"2026-11-20","whs_code":"WH01"}';
  ok1    jsonb := '[{"item_code":"SMP-1010","qty":10,"discount_pct":5,"tax_code":"SR"},{"item_code":"SMP-1020","qty":3,"price":60,"tax_code":"ZR"}]';
  r      jsonb;
  r2     jsonb;
  e1     integer;
  e2     integer;
  e_disc integer;
  e_rej  integer;
  e_cred integer;
  v_next integer;
  v_cnt  bigint;
  v_txt  text;
BEGIN
  -- ---------- Who may call ----------
  r := pg_temp.save(nobody, NULL, h, ok1);
  PERFORM pg_temp.expect(r, 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.', 'user without a profile refused');
  r := pg_temp.save(sread, NULL, h, ok1);
  PERFORM pg_temp.expect(r, 'You have read-only access to Sales. Ask the system admin for full access to create or change orders.', 'read-only sales user refused (save)');
  PERFORM pg_temp.check(r->>'error' = '42501', 'read-only refusal is 42501', r->>'error');
  r := pg_temp.save(fin, NULL, h, ok1);
  PERFORM pg_temp.expect(r, 'Your position does not include Sales. Ask the system admin if you need it.', 'finance user (no Sales) refused');
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type) VALUES ('ZZ98', 'Other test co', 'Other', 'AE', 'AED', 'mainland');
  r := pg_temp.save(sales, NULL, h, ok1, 'ZZ98');
  PERFORM pg_temp.expect(r, 'You don''t have access to company ZZ98.', 'another company refused');
  r := pg_temp.call(NULL, format('SELECT erp.sales_order_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', h, ok1), 'anon');
  PERFORM pg_temp.check(r->>'error' = '42501', 'anon cannot execute sales_order_save', r::text);
  r := pg_temp.call(sales, 'SELECT to_jsonb(erp._so_eval(''ZZ99'', ''{}''::jsonb, ''[]''::jsonb, ''QA_SALES'', NULL))');
  PERFORM pg_temp.check(r->>'error' = '42501', 'internal _so_eval is not callable from the API', r->>'message');

  -- ---------- Validation messages ----------
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, '{"doc_date":"2026-11-09","whs_code":"WH01"}', ok1), 'Choose a customer.', 'validation: no customer');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h || '{"card_code":"C9999"}', ok1), 'Customer C9999 does not exist in company ZZ99. Check the code.', 'validation: unknown customer');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h || '{"card_code":"C0018"}', ok1), 'Customer C0018 is inactive. Choose an active customer.', 'validation: inactive customer');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h || '{"card_code":"S0001"}', ok1), 'S0001 is not a customer. Choose a customer.', 'validation: supplier is not a customer');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[]'), 'Add at least one line.', 'validation: no lines');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-9999","qty":1,"price":1}]'), 'Line 1: item SMP-9999 does not exist. Check the item code.', 'validation: unknown item');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1130","qty":1,"price":1}]'), 'Line 1: SMP-1130 is inactive. Choose an active item.', 'validation: inactive item');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1},{"item_code":"SMP-1220","qty":1,"price":1}]'), 'Line 2: SMP-1220 is not a sales item.', 'validation: not a sales item (line 2)');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":0}]'), 'Line 1: quantity must be more than 0.', 'validation: qty 0');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":-2}]'), 'Line 1: quantity must be more than 0.', 'validation: negative qty');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"price":-1}]'), 'Line 1: price can''t be negative.', 'validation: negative price');
  r := pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"price":0}]');
  PERFORM pg_temp.check(r ? 'doc_entry', 'validation: price 0 is allowed', left(r::text, 100));
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"discount_pct":101}]'), 'Line 1: discount must be between 0 and 100%.', 'validation: discount 101');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"discount_pct":-1}]'), 'Line 1: discount must be between 0 and 100%.', 'validation: discount -1');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h || '{"whs_code":"XX"}', ok1), 'Warehouse XX does not exist in company ZZ99.', 'validation: unknown header warehouse');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"whs_code":"NOPE"}]'), 'Line 1: warehouse NOPE does not exist in company ZZ99.', 'validation: unknown line warehouse');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"tax_code":"ZZ"}]'), 'Line 1: tax code ZZ does not exist.', 'validation: unknown tax code');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"tax_code":"IP"}]'), 'Line 1: tax code IP is for purchases. Choose a sales tax code.', 'validation: purchase tax code');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h - 'doc_date', ok1), 'Choose a posting date.', 'validation: no posting date');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h || '{"due_date":"2026-11-01"}', ok1), 'The delivery date can''t be before the posting date.', 'validation: delivery before posting');
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h || '{"price_list":99}', ok1), 'Price list 99 does not exist.', 'validation: unknown price list');
  DELETE FROM erp.item_price WHERE company_code = 'ZZ99' AND list_num = 1 AND item_code = 'SMP-1250';
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1250","qty":1}]'), 'Line 1: SMP-1250 has no price in the customer''s price list. Enter a price.', 'validation: no price in price list');
  r := pg_temp.checks(sales, '{"doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":0}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'errors') = 2 AND r->'errors'->1->>'line' = '1' AND r->'errors'->1->>'field' = 'qty',
                        'checks() lists every problem with line and field', (r->'errors')::text);
  r := pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":0},{"item_code":"SMP-1130","qty":1}]');
  PERFORM pg_temp.check(r->>'message' = 'Line 1: quantity must be more than 0.', 'save raises the first problem', r->>'message');

  -- ---------- Numbering, totals, VAT ----------
  UPDATE erp.number_series SET active = false WHERE company_code = 'ZZ99' AND obj_type = 17;
  PERFORM pg_temp.expect(pg_temp.save(sales, NULL, h, ok1), 'Sales order numbering is not set up for company ZZ99. Ask the system admin to add it (Administration › Document Numbering).', 'numbering missing refused');
  UPDATE erp.number_series SET active = true, next_num = 41 WHERE company_code = 'ZZ99' AND obj_type = 17;
  r := pg_temp.save(sales, NULL, h, ok1);
  e1 := (r->>'doc_entry')::int;
  PERFORM pg_temp.check(r->>'doc_no' = 'SO-26-00041' AND (r->>'doc_num')::int = 41, 'number allocated from number_series (SO-26-00041)', r->>'doc_no');
  PERFORM pg_temp.check(e1 >= 900000000, 'ERP doc_entry is 900000000 or above', e1::text);
  PERFORM pg_temp.check((r->'totals'->>'before_discount')::numeric = 1511.60 AND (r->'totals'->>'discount')::numeric = 66.58
                        AND (r->'totals'->>'net')::numeric = 1445.02 AND (r->'totals'->>'vat')::numeric = 63.25
                        AND (r->'totals'->>'total')::numeric = 1508.27, 'totals: before discount, discount, net, VAT 5 %, total', (r->'totals')::text);
  PERFORM pg_temp.check((r->'lines'->0->>'price')::numeric = 133.16, 'price taken from the customer''s price list when none is sent', r->'lines'->0->>'price');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e1
                                   AND status = 'draft' AND source = 'erp' AND total = 1508.27 AND vat_total = 63.25 AND card_name = 'Sunrise Online Store'),
                        'document stored as draft, source erp, server totals', '');
  PERFORM pg_temp.check((SELECT count(*) = 2 AND bool_and(open_qty = quantity) AND sum(line_total) = 1445.02 AND sum(vat) = 63.25
                           FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e1),
                        'lines stored with open_qty = qty, line totals and VAT', '');
  r2 := pg_temp.save(sales, NULL, h, ok1);
  e2 := (r2->>'doc_entry')::int;
  PERFORM pg_temp.check(r2->>'doc_no' = 'SO-26-00042' AND e2 > e1, 'next order gets the next number and doc_entry', r2->>'doc_no');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sales_order_create' AND object = 'sales_order'
                                   AND object_ref = e1::text AND actor = sales::text AND company_code = 'ZZ99'), 'audit row written on create', '');
  r := pg_temp.save(sales, e1, h, '[{"item_code":"SMP-1010","qty":2,"price":100,"discount_pct":0,"tax_code":"SR"}]');
  PERFORM pg_temp.check(r->>'doc_no' = 'SO-26-00041' AND (r->'totals'->>'total')::numeric = 210.00
                        AND (SELECT count(*) FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e1) = 1,
                        'editing a draft replaces its lines and keeps its number', (r->'totals')::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sales_order_update' AND object_ref = e1::text), 'audit row written on update', '');
  PERFORM pg_temp.expect(pg_temp.save(admin, e1, h, ok1), 'Only the person who created this order can change it.', 'another user cannot edit the draft');
  PERFORM pg_temp.expect(pg_temp.save(sales, 14, h, ok1), 'This order came from the sample test data, so it is read-only in Super ERP.', 'sample order cannot be edited');
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, source)
  VALUES ('ZZ99', 17, 5, 5, 'sales_order', 'open', '2026-01-01', 'sap');
  PERFORM pg_temp.expect(pg_temp.save(sales, 5, h, ok1), 'This order came from SAP Business One, so it is read-only in Super ERP.', 'SAP order cannot be edited');
  PERFORM pg_temp.expect(pg_temp.cancel(sales, 5, 'x'), 'This order came from SAP Business One, so it is read-only in Super ERP.', 'SAP order cannot be cancelled');
  PERFORM pg_temp.check((SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = 5) = 'open', 'SAP row unchanged', '');

  -- ---------- Direct writes are refused ----------
  r := pg_temp.call(sales, 'WITH x AS (UPDATE erp.document SET total = 0 WHERE source = ''erp'' RETURNING 1) SELECT to_jsonb(count(*)) FROM x');
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct UPDATE on erp.document refused', r->>'message');
  r := pg_temp.call(sales, 'WITH x AS (UPDATE erp.doc_workflow SET state = ''approved'' RETURNING 1) SELECT to_jsonb(count(*)) FROM x');
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct UPDATE on erp.doc_workflow refused', r->>'message');
  r := pg_temp.call(sales, 'WITH x AS (INSERT INTO erp.approval_rule (company_code, rule_code, position_code, limit_value, approver_position) VALUES (''ZZ99'',''discount_pct'',''QA_SALES'',100,''QA_SALES'') RETURNING 1) SELECT to_jsonb(count(*)) FROM x');
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct INSERT on erp.approval_rule refused', r->>'message');

  -- ---------- Rules: triggering and not triggering ----------
  r := pg_temp.checks(sales, h, '[{"item_code":"SMP-1010","qty":1,"discount_pct":10}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 0, 'discount 10 % (= limit) needs no approval', (r->'checks')::text);
  r := pg_temp.checks(sales, h, '[{"item_code":"SMP-1010","qty":1,"discount_pct":10.5}]');
  PERFORM pg_temp.check(r->'checks'->0->>'message' = 'Line 1: Discount 10.5% is above your limit of 10%. Submit it for approval or lower the discount.'
                        AND r->'checks'->0->>'approver_position' = 'QA_SALES_MGR', 'discount 10.5 % triggers the discount rule (→ sales manager)', r->'checks'->0->>'message');
  r := pg_temp.checks(mgr, h, '[{"item_code":"SMP-1010","qty":1,"discount_pct":12}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 0, 'sales manager''s own limit is 15 % (12 % passes)', (r->'checks')::text);
  r := pg_temp.checks(sales, h, '[{"item_code":"SMP-1010","qty":1,"price":90}]');
  PERFORM pg_temp.check(r->'checks'->0->>'message' = 'Line 1: net price 90.00 for SMP-1010 is below its cost of 95.00.'
                        AND r->'checks'->0->>'approver_position' = 'QA_ALL', 'price below cost triggers the below-cost rule (→ QA_ALL)', r->'checks'->0->>'message');
  r := pg_temp.checks(sales, h, '[{"item_code":"SMP-1010","qty":1,"price":95}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 0, 'price equal to cost needs no approval', (r->'checks')::text);
  r := pg_temp.checks(sales, h || '{"card_code":"C0001"}', '[{"item_code":"SMP-1010","qty":1}]');
  PERFORM pg_temp.check(r->'checks'->0->>'rule_code' = 'credit_limit'
                        AND r->'checks'->0->>'message' LIKE 'Customer C0001 would be over the credit limit of 50,000.00 AED: balance 28,147.11 + open orders 23,749.53 + this order 139.82 = 52,036.46 AED.',
                        'customer over credit limit triggers the credit rule', r->'checks'->0->>'message');
  r := pg_temp.checks(sales, h || '{"card_code":"C0010"}', '[{"item_code":"SMP-1010","qty":1}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 0 AND (r->'credit'->>'left')::numeric = 46738.31, 'customer within credit limit: no rule, credit left shown', (r->'credit')::text);

  -- ---------- Submit without approval ----------
  r := pg_temp.submit(sales, e1, NULL);
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'open', 'no rule triggered: submit goes straight to approved / open', r::text);
  PERFORM pg_temp.check((SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e1) = 'open', 'document status open', '');
  PERFORM pg_temp.expect(pg_temp.save(sales, e1, h, ok1), 'This order is approved and can''t be edited.', 'approved order cannot be edited');
  PERFORM pg_temp.expect(pg_temp.submit(sales, e1, NULL), 'This order is already approved.', 'approved order cannot be resubmitted');

  -- ---------- Discount approval: 18 % → approve at 10 % ----------
  r := pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":10,"price":133.16,"discount_pct":18,"tax_code":"SR"}]');
  e_disc := (r->>'doc_entry')::int;
  PERFORM pg_temp.check(r->'checks'->0->>'message' = 'Line 1: Discount 18% is above your limit of 10%. Submit it for approval or lower the discount.', 'save returns the checks it would trigger', r->'checks'->0->>'message');
  PERFORM pg_temp.expect(pg_temp.submit(sales, e_disc, '  '), 'This order needs approval (discount above your limit). Add a reason for the approver.', 'submit needing approval without a reason refused');
  r := pg_temp.submit(sales, e_disc, 'Launch promotion agreed with buyer');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND r->>'status' = 'draft', 'submit with a reason: pending approval, document stays draft', r->>'state');
  PERFORM pg_temp.check((SELECT count(*) = 1 AND bool_and(approver_position = 'QA_SALES_MGR' AND rule_code = 'discount_pct' AND step = 1 AND requested_by = sales)
                           FROM erp.approval WHERE company_code = 'ZZ99' AND object = 'sales_order' AND object_ref = e_disc::text),
                        'one approval row for the discount rule, to the sales manager', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sales_order_submit' AND object_ref = e_disc::text AND detail->>'result' = 'pending_approval'),
                        'audit row written on submit', '');
  PERFORM pg_temp.expect(pg_temp.save(sales, e_disc, h, ok1), 'This order is waiting for approval and can''t be edited. Ask the approver to reject it first.', 'edit while pending refused');
  PERFORM pg_temp.expect(pg_temp.submit(sales, e_disc, 'again'), 'This order is already waiting for approval.', 'resubmit while pending refused');
  PERFORM pg_temp.expect(pg_temp.decide(sales, e_disc, 'approved', NULL), 'You can''t approve your own order.', 'submitter cannot approve own order');
  PERFORM pg_temp.expect(pg_temp.decide(admin, e_disc, 'approved', NULL), 'This order is waiting for approval from QA · sales manager. Your position can''t decide it.', 'wrong approver refused');
  PERFORM pg_temp.expect(pg_temp.decide(sread, e_disc, 'approved', NULL), 'You have read-only access to Sales. Ask the system admin for full access to create or change orders.', 'read-only user cannot approve');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_disc, 'maybe', NULL), 'Choose approve or reject.', 'unknown decision refused');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_disc, 'rejected', '   '), 'Add a note saying why you are rejecting this order.', 'reject without a note refused');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_disc, 'approved', NULL, 16), 'Discount 16% is above your own limit of 15%. Approve the order as it is, or choose a lower discount.', 'approve at 16 % (above approver''s 15 %) refused');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_disc, 'rejected', 'no', 10), 'Approve at a lower discount only works with approve.', 'approve-at with reject refused');
  r := pg_temp.call(mgr, format('SELECT erp.sales_order_info(%L, %s)', 'ZZ99', e_disc));
  PERFORM pg_temp.check((r->>'can_decide')::boolean AND (r->>'my_discount_limit')::numeric = 15 AND (r->>'requester_discount_limit')::numeric = 10,
                        'info: sales manager can decide; limits 15 % / 10 %', concat_ws(' ', r->>'can_decide', r->>'my_discount_limit', r->>'requester_discount_limit'));
  r := pg_temp.call(sales, format('SELECT erp.sales_order_info(%L, %s)', 'ZZ99', e_disc));
  PERFORM pg_temp.check(NOT (r->>'can_decide')::boolean AND NOT (r->>'can_edit')::boolean AND (r->>'can_cancel')::boolean, 'info: submitter cannot decide or edit, can cancel', '');
  r := pg_temp.call(mgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check((r->>'is_approver')::boolean AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') x WHERE (x->>'doc_entry')::int = e_disc),
                        'inbox: order is waiting for the sales manager', jsonb_array_length(r->'waiting')::text);
  r := pg_temp.call(sales, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(NOT (r->>'is_approver')::boolean AND jsonb_array_length(r->'waiting') = 0
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sent') x WHERE (x->>'doc_entry')::int = e_disc),
                        'inbox: sales user sees it under sent by me, not waiting', '');
  r := pg_temp.call(admin, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') x WHERE (x->>'doc_entry')::int = e_disc), 'inbox: not waiting for another position', '');

  r := pg_temp.decide(mgr, e_disc, 'approved', NULL, 10);
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'open', 'approve at 10 %: order approved and open', r::text);
  PERFORM pg_temp.check((SELECT discount_pct = 10 AND line_total = 1198.44 AND vat = 59.92 FROM erp.document_line
                          WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e_disc AND line_num = 0),
                        'approve at 10 %: discount lowered, line total and VAT recalculated', '');
  PERFORM pg_temp.check((SELECT total = 1258.36 AND vat_total = 59.92 FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e_disc),
                        'approve at 10 %: document total 1,258.36 recalculated', (SELECT total::text FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e_disc));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.approval WHERE object_ref = e_disc::text AND object = 'sales_order' AND decision = 'approved'
                                   AND approver_user = mgr AND note = 'Approved at 10%' AND decided_at IS NOT NULL), 'approval row decided by the manager', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sales_order_approve' AND object_ref = e_disc::text AND actor = mgr::text),
                        'audit row written on approve', '');
  r := pg_temp.call(mgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'decided') x WHERE (x->>'doc_entry')::int = e_disc AND x->>'decision' = 'approved'),
                        'inbox: decided tab shows the approval', '');
  r := pg_temp.call(sales, format('SELECT erp.sales_order_info(%L, %s)', 'ZZ99', e_disc));
  PERFORM pg_temp.check((SELECT array_agg(x->>'action' ORDER BY ord) FROM jsonb_array_elements(r->'activity') WITH ORDINALITY AS t(x, ord))
                        = ARRAY['sales_order_create', 'sales_order_submit', 'sales_order_approve'], 'activity timeline: created, submitted, approved',
                        (SELECT string_agg(x->>'action', ', ') FROM jsonb_array_elements(r->'activity') x));
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_disc, 'approved', NULL), 'This order is not waiting for approval.', 'deciding twice refused');

  -- "Approve at n %" must be lower than the requested discount
  r := pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":1,"price":133.16,"discount_pct":12}]');
  e2 := (r->>'doc_entry')::int;
  PERFORM pg_temp.submit(sales, e2, 'Volume order');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e2, 'approved', NULL, 13), 'Approve at 13% must be lower than the requested discount of 12%.', 'approve at n % not lower than requested refused');
  r := pg_temp.decide(mgr, e2, 'approved', 'OK as requested');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND (SELECT discount_pct FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e2) = 12,
                        'plain approve keeps the requested discount', r->>'state');

  -- ---------- Reject path, edit and resubmit ----------
  r := pg_temp.save(sales, NULL, h, '[{"item_code":"SMP-1010","qty":5,"price":133.16,"discount_pct":20}]');
  e_rej := (r->>'doc_entry')::int;
  PERFORM pg_temp.submit(sales, e_rej, 'Clearance');
  r := pg_temp.decide(mgr, e_rej, 'rejected', 'Too high for this customer');
  PERFORM pg_temp.check(r->>'state' = 'rejected' AND r->>'status' = 'draft', 'reject: order rejected, document stays draft', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sales_order_reject' AND object_ref = e_rej::text AND detail->>'note' = 'Too high for this customer'),
                        'audit row written on reject with the note', '');
  r := pg_temp.save(sales, e_rej, h, '[{"item_code":"SMP-1010","qty":5,"price":133.16,"discount_pct":10}]');
  PERFORM pg_temp.check(r->>'state' = 'draft' AND jsonb_array_length(r->'checks') = 0, 'rejected order can be edited by its creator (back to draft)', r->>'state');
  r := pg_temp.submit(sales, e_rej, NULL);
  PERFORM pg_temp.check(r->>'state' = 'approved', 'resubmitted within limit: approved', r->>'state');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.approval WHERE object = 'sales_order' AND object_ref = e_rej::text AND decision = 'rejected') = 1,
                        'rejection kept in the approval history', '');

  -- ---------- Credit rule, self-approval when the submitter holds the approver position ----------
  r := pg_temp.save(mgr, NULL, h || '{"card_code":"C0001"}', '[{"item_code":"SMP-1010","qty":1}]');
  e_cred := (r->>'doc_entry')::int;
  r := pg_temp.submit(mgr, e_cred, 'Customer pays on Monday');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND r->'checks'->0->>'rule_code' = 'credit_limit', 'credit rule: order goes to approval', r->>'state');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_cred, 'approved', NULL), 'You can''t approve your own order.', 'self-approval refused even for an approver position');
  PERFORM pg_temp.expect(pg_temp.decide(mgr, e_cred, 'rejected', 'x'), 'You can''t reject your own order. Cancel it instead if it is no longer needed.', 'submitter cannot reject own order');
  r := pg_temp.call(mgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') x WHERE (x->>'doc_entry')::int = e_cred), 'own order is not in my waiting list', '');

  -- ---------- Cancel ----------
  PERFORM pg_temp.expect(pg_temp.cancel(admin, e_cred, 'x'), 'Only the person who created this order or one of its approvers can cancel it.', 'cancel by an unrelated user refused');
  PERFORM pg_temp.expect(pg_temp.cancel(mgr, e_cred, ' '), 'Add a note saying why the order is cancelled.', 'cancel without a note refused');
  r := pg_temp.cancel(mgr, e_cred, 'Customer withdrew');
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = e_cred) = 'cancelled',
                        'creator cancels: state and status cancelled', r::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.approval WHERE object = 'sales_order' AND object_ref = e_cred::text AND decision IS NULL AND NOT superseded),
                        'open approvals closed on cancel', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sales_order_cancel' AND object_ref = e_cred::text), 'audit row written on cancel', '');
  PERFORM pg_temp.expect(pg_temp.cancel(mgr, e_cred, 'again'), 'This order is already cancelled.', 'cancel twice refused');
  PERFORM pg_temp.expect(pg_temp.save(mgr, e_cred, h, ok1), 'This order is cancelled and can''t be edited.', 'cancelled order cannot be edited');
  r := pg_temp.cancel(mgr, e_disc, 'Approver cancels');
  PERFORM pg_temp.check(r->>'state' = 'cancelled', 'an approver of the order can cancel it', r->>'state');
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, source) VALUES ('ZZ99', 15, 777, 777, 'delivery', 'open', '2026-11-09', 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, base_obj_type, base_doc_entry, base_line)
  VALUES ('ZZ99', 15, 777, 0, 'SMP-1010', 1, 17, e2, 0);
  PERFORM pg_temp.expect(pg_temp.cancel(sales, e2, 'x'), 'This order has a delivery and can''t be cancelled.', 'cancel after a delivery refused');

  -- ---------- Reading ----------
  v_cnt := (pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.sales_order_list WHERE source = ''erp'''))::text::bigint;
  PERFORM pg_temp.check(v_cnt >= 5, 'sales user reads ERP orders in sales_order_list', v_cnt::text);
  v_cnt := (pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.sales_order_list WHERE state = ''pending_approval'''))::text::bigint;
  PERFORM pg_temp.check(v_cnt = 0, 'list "Waiting approval" filter works on the view', v_cnt::text);
  v_cnt := (pg_temp.call(fin, 'SELECT to_jsonb(count(*)) FROM erp.doc_workflow'))::text::bigint;
  PERFORM pg_temp.check(v_cnt >= 5, 'finance reads workflow rows (sales documents rule)', v_cnt::text);
  r := pg_temp.call(nobody, 'SELECT to_jsonb(count(*)) FROM erp.sales_order_list');
  PERFORM pg_temp.check(r::text = '0', 'user without a profile reads nothing from sales_order_list', r::text);
  r := pg_temp.call(sales, 'SELECT erp.sales_order_setup(''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r->'tax_codes') = 3 AND r->>'default_tax_code' = 'SR' AND (r->>'my_discount_limit')::numeric = 10,
                        'setup: sales tax codes only (no input VAT), defaults, my limit', concat_ws(' ', jsonb_array_length(r->'tax_codes'), r->>'default_tax_code', r->>'my_discount_limit'));
  r := pg_temp.call(sales, 'SELECT erp.sales_order_info(''ZZ99'', 14)');
  PERFORM pg_temp.check(r->>'workflow' = 'false' AND r->>'source' = 'sample', 'info for a sample/SAP order: no workflow', r::text);
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a2_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a2_result;
ROLLBACK;
