-- A4 · Sales cycle tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run after base.txt (10–18 + test users) and 19_sales_cycle.sql, on a FRESH rebuild. Everything happens inside one
-- transaction that is rolled back. Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a4_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a4_result TO authenticated;

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
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a4_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 160)))
$$;
-- Shorthands
CREATE FUNCTION pg_temp.dsave(u uuid, obj int, e int, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_save(''ZZ99'', %s, %s, %L::jsonb, %L::jsonb)', obj, coalesce(e::text, 'NULL'), h, l))
$$;
CREATE FUNCTION pg_temp.dsubmit(u uuid, obj int, e int, reason text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_submit(''ZZ99'', %s, %s, %L)', obj, e, reason))
$$;
CREATE FUNCTION pg_temp.ddecide(u uuid, obj int, e int, decision text, note text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_decide(''ZZ99'', %s, %s, %L, %L, NULL)', obj, e, decision, note))
$$;
CREATE FUNCTION pg_temp.deliver(u uuid, h jsonb, l jsonb, c text DEFAULT 'ZZ99') RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_delivery_create(%L, %L::jsonb, %L::jsonb)', c, h, l))
$$;
CREATE FUNCTION pg_temp.invoice(u uuid, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_invoice_create(''ZZ99'', %L::jsonb, %L::jsonb)', h, l))
$$;
CREATE FUNCTION pg_temp.credit(u uuid, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_credit_memo_create(''ZZ99'', %L::jsonb, %L::jsonb)', h, l))
$$;
CREATE FUNCTION pg_temp.oh(item text, whs text DEFAULT 'WH01') RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = item AND whs_code = whs), 0)
$$;
CREATE FUNCTION pg_temp.cm(item text, whs text DEFAULT 'WH01') RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT committed FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = item AND whs_code = whs), 0)
$$;
CREATE FUNCTION pg_temp.openq(obj int, e int, ln int) RETURNS numeric LANGUAGE sql AS $$
  SELECT open_qty FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = obj AND doc_entry = e AND line_num = ln
$$;
CREATE FUNCTION pg_temp.jl(t int, acct text, side text) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce(sum(CASE side WHEN 'd' THEN debit ELSE credit END), 0) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t AND acct_code = acct
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  sread  uuid := '00000000-0000-4000-8000-000000000006';
  mgr    uuid := '00000000-0000-4000-8000-000000000007';
  hq     jsonb := '{"card_code":"C0011","doc_date":"2026-11-09","due_date":"2026-11-30","whs_code":"WH01"}';
  r      jsonb;
  q1     integer;  q_no text;
  o1     integer;  o_no text;
  o2     integer;
  o3     integer;
  d1     integer;  d_no text;
  i1     integer;  i_no text;
  i2     integer;
  c1     integer;
  t      integer;
  oh1010 numeric := pg_temp.oh('SMP-1010');
  cm1010 numeric := pg_temp.cm('SMP-1010');
  oh1020 numeric := pg_temp.oh('SMP-1020');
  cm1020 numeric := pg_temp.cm('SMP-1020');
  bal0   numeric := (SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011');
  v_net  numeric;
  v_vat  numeric;
  v_tot  numeric;
  v_inv_total numeric;
  v_cm_total  numeric;
  v_svc_total numeric;
  e_sample integer;
  v_x    numeric;
BEGIN
  -- ================= Access =================
  PERFORM pg_temp.expect(pg_temp.dsave(sread, 23, NULL, hq, '[{"item_code":"SMP-1010","qty":1}]'),
    'You have read-only access to Sales. Ask the system admin for full access to create quotations.', 'quotation: read-only Sales refused');
  PERFORM pg_temp.expect(pg_temp.dsave(fin, 23, NULL, hq, '[{"item_code":"SMP-1010","qty":1}]'),
    'Your position does not include Sales. Ask the system admin if you need it.', 'quotation: finance-only refused');
  PERFORM pg_temp.expect(pg_temp.dsave(nobody, 23, NULL, hq, '[{"item_code":"SMP-1010","qty":1}]'),
    'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.', 'quotation: no profile refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.sales_doc_setup(''ZZ99'', 13)'),
    'Only sales quotations and sales orders are edited this way.', 'sales_doc_* only for 23 / 17');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', '[{"base_doc_entry":1,"base_line":0,"qty":1}]', 'ZZ98'),
    'You don''t have access to company ZZ98.', 'delivery: other company refused');
  r := pg_temp.call(sales, 'SELECT to_jsonb(erp.post_document(''ZZ99'', 15, 1))');
  PERFORM pg_temp.check(r->>'error' = '42501', 'post_document is internal', r::text);
  r := pg_temp.call(sales, 'SELECT to_jsonb(erp._stock_move(''ZZ99'', ''SMP-1010'', ''WH01'', 1, 0, 1, 15, 1, 0, current_date, 0))');
  PERFORM pg_temp.check(r->>'error' = '42501', '_stock_move is internal', r::text);
  r := pg_temp.call(admin, 'WITH u AS (INSERT INTO erp.atp_rule (company_code, rule_code, name) VALUES (''ZZ99'', ''XX'', ''x'') RETURNING 1) SELECT to_jsonb(count(*)) FROM u');
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct insert into atp_rule refused', r::text);
  r := pg_temp.call(admin, 'WITH u AS (UPDATE erp.stock_balance SET on_hand = 0 WHERE company_code = ''ZZ99'' RETURNING 1) SELECT to_jsonb(count(*)) FROM u');
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct update of stock_balance refused', r::text);
  r := pg_temp.call(admin, 'WITH u AS (UPDATE erp.warehouse_setting SET allow_negative = true RETURNING 1) SELECT to_jsonb(count(*)) FROM u');
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct update of warehouse_setting refused', r::text);

  -- ================= Quotation =================
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_checks(''ZZ99'', 23, NULL, %L::jsonb, %L::jsonb)',
         '{"card_code":"C0004","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1200","qty":200,"tax_code":"SR"}]'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'checks') c WHERE c->>'rule_code' = 'credit_limit')
                        AND r->'credit' = 'null'::jsonb AND jsonb_array_length(r->'atp') = 0,
                        'quotation: no credit-limit check and no ATP (orders only)', left(r::text, 200));
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_checks(''ZZ99'', 23, NULL, %L::jsonb, %L::jsonb)', hq, '[{"item_code":"SMP-1010","qty":2,"discount_pct":15,"tax_code":"SR"}]'));
  PERFORM pg_temp.check(r->'checks'->0->>'rule_code' = 'discount_pct'
                        AND r->'checks'->0->>'message' = 'Line 1: Discount 15% is above your limit of 10%. Submit it for approval or lower the discount.',
                        'quotation: same discount rule as orders', left(r::text, 200));
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_checks(''ZZ99'', 23, NULL, %L::jsonb, %L::jsonb)',
         '{"card_code":"C0011","doc_date":"2026-11-09","due_date":"2026-11-01"}', '[{"item_code":"SMP-1010","qty":1}]'));
  PERFORM pg_temp.check(r->'errors'->0->>'message' = 'The valid-until date can''t be before the posting date.', 'quotation: valid-until wording', left(r::text, 200));

  r := pg_temp.dsave(sales, 23, NULL, hq, '[{"item_code":"SMP-1010","qty":20,"discount_pct":12,"tax_code":"SR"},{"item_code":"SMP-1020","qty":10,"price":60,"tax_code":"SR"}]');
  q1 := (r->>'doc_entry')::integer; q_no := r->>'doc_no';
  PERFORM pg_temp.check(q1 >= 900000000 AND q_no LIKE 'SQ-26-%' AND r->>'state' = 'draft', 'quotation saved: ERP entry, SQ number, draft', left(r::text, 200));
  PERFORM pg_temp.check((SELECT doc_kind = 'sales_quotation' AND status = 'draft' AND source = 'erp' FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1),
                        'quotation row: kind, draft, source erp', '');
  PERFORM pg_temp.expect(pg_temp.dsubmit(sales, 23, q1, NULL), 'This quotation needs approval (discount above your limit). Add a reason for the approver.',
                         'quotation: submit without reason refused');
  r := pg_temp.dsubmit(sales, 23, q1, 'Project price for 2027 range');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'quotation: sent for approval', left(r::text, 200));
  r := pg_temp.call(mgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'sales_quotation' AND (w->>'doc_entry')::int = q1),
                        'approval inbox shows the quotation to the sales manager', '');
  PERFORM pg_temp.expect(pg_temp.ddecide(sales, 23, q1, 'approved', NULL), 'You can''t approve your own quotation.', 'quotation: own approval refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.sales_copy_source(''ZZ99'', 23, %s)', q1)),
    format('Sales quotation %s is not approved yet, so it can''t be copied.', q_no), 'copy before approval refused');
  r := pg_temp.ddecide(mgr, 23, q1, 'approved', NULL);
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'open', 'quotation approved → open', left(r::text, 200));
  PERFORM pg_temp.check(pg_temp.cm('SMP-1010') = cm1010, 'an open quotation commits no stock', '');
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_info(''ZZ99'', 23, %s)', q1));
  PERFORM pg_temp.check((r->>'can_copy')::boolean AND r->>'state' = 'approved', 'quotation info: can copy', left(r::text, 120));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE object = 'sales_quotation' AND object_ref = q1::text AND action = 'sales_quotation_approve'),
                        'audit: sales_quotation_approve', '');

  -- ================= Copy to sales order =================
  r := pg_temp.call(sales, format('SELECT erp.sales_copy_source(''ZZ99'', 23, %s)', q1));
  PERFORM pg_temp.check(jsonb_array_length(r->'lines') = 2 AND (r->'lines'->0->>'open_qty')::numeric = 20 AND r->'header'->>'card_code' = 'C0011',
                        'copy source: 2 open lines with remaining quantities', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.dsave(sales, 17, NULL, hq, format('[{"item_code":"SMP-1010","qty":25,"discount_pct":12,"tax_code":"SR","base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb),
    format('Line 1: only 20 of SMP-1010 are still open on quotation %s.', q_no), 'order: more than the quotation has left refused');
  PERFORM pg_temp.expect(pg_temp.dsave(sales, 17, NULL, '{"card_code":"C0002","doc_date":"2026-11-09","whs_code":"WH01"}',
      format('[{"item_code":"SMP-1010","qty":1,"base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb),
    format('Line 1: quotation %s is for customer C0011. Copy it to an order for the same customer.', q_no), 'order: other customer refused');
  PERFORM pg_temp.expect(pg_temp.dsave(sales, 17, NULL, hq, format('[{"item_code":"SMP-1030","qty":1,"base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb),
    format('Line 1: the item does not match line 1 of quotation %s.', q_no), 'order: item mismatch refused');
  SELECT doc_entry INTO e_sample FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 23 AND source = 'sample' LIMIT 1;
  r := pg_temp.dsave(sales, 17, NULL, hq, format('[{"item_code":"SMP-1010","qty":1,"base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', e_sample)::jsonb);
  PERFORM pg_temp.check(r->>'message' LIKE 'Line 1: quotation % came from the sample test data. Only Super ERP quotations can be copied.', 'order: copy from sample quotation refused', r->>'message');

  r := pg_temp.dsave(sales, 17, NULL, hq, format('[{"item_code":"SMP-1010","qty":15,"discount_pct":12,"tax_code":"SR","base_obj_type":23,"base_doc_entry":%s,"base_line":0},
                                                 {"item_code":"SMP-1020","qty":10,"price":60,"tax_code":"SR","base_obj_type":23,"base_doc_entry":%s,"base_line":1}]', q1, q1)::jsonb);
  o1 := (r->>'doc_entry')::integer; o_no := r->>'doc_no';
  PERFORM pg_temp.check(o1 IS NOT NULL AND o_no LIKE 'SO-26-%', 'order saved from the quotation', left(r::text, 200));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = o1 AND base_obj_type = 23 AND base_doc_entry = q1) = 2
                        AND (SELECT base_line FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = o1 AND line_num = 1) = 1,
                        'order lines keep base_obj_type / base_doc_entry / base_line', '');
  PERFORM pg_temp.check(pg_temp.openq(23, q1, 0) = 20, 'draft order does not use up the quotation', '');
  r := pg_temp.dsubmit(sales, 17, o1, 'Agreed in the quotation');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'order from quotation needs approval (12%)', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', o1)::jsonb),
    format('Sales order %s is not open (pending approval). Only approved, open documents can be delivered.', o_no), 'delivery from a pending order refused');
  r := pg_temp.call(mgr, format('SELECT erp.sales_order_decide(''ZZ99'', %s, ''approved'', NULL, NULL)', o1));
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'open', 'order approved (A2 wrapper) → open', left(r::text, 200));
  PERFORM pg_temp.check(pg_temp.openq(23, q1, 0) = 5 AND pg_temp.openq(23, q1, 1) = 0
                        AND (SELECT line_status FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1 AND line_num = 1) = 'C',
                        'order opened: quotation open quantities 5 / 0', '');
  PERFORM pg_temp.check((SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1) = 'open', 'quotation stays open while 5 are left', '');
  PERFORM pg_temp.check(pg_temp.cm('SMP-1010') = cm1010 + 15 AND pg_temp.cm('SMP-1020') = cm1020 + 10, 'order opened: stock committed 15 / 10', '');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.sales_doc_cancel(''ZZ99'', 23, %s, ''x'')', q1)),
    'This quotation was copied to a sales order and can''t be cancelled. Cancel the order first.', 'quotation with a live order can''t be cancelled');

  -- Second order uses the last 5, closing the quotation; cancelling it gives them back.
  r := pg_temp.dsave(sales, 17, NULL, hq, format('[{"item_code":"SMP-1010","qty":5,"tax_code":"SR","base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb);
  o2 := (r->>'doc_entry')::integer;
  r := pg_temp.dsubmit(sales, 17, o2, NULL);
  PERFORM pg_temp.check(r->>'state' = 'approved', 'second order straight to open', left(r::text, 200));
  PERFORM pg_temp.check(pg_temp.openq(23, q1, 0) = 0 AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1) = 'closed',
                        'quotation fully used → closed', '');
  r := pg_temp.call(sales, format('SELECT erp.sales_order_cancel(''ZZ99'', %s, ''Customer changed plan'')', o2));
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND pg_temp.openq(23, q1, 0) = 5
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1) = 'open'
                        AND pg_temp.cm('SMP-1010') = cm1010 + 15,
                        'cancelling the open order releases its stock and reopens the quotation', left(r::text, 120));

  -- ================= Available-to-Promise =================
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_checks(''ZZ99'', 17, NULL, %L::jsonb, %L::jsonb)',
         '{"card_code":"C0011","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1040","qty":5,"tax_code":"SR"}]'));
  PERFORM pg_temp.check(jsonb_array_length(r->'atp') = 1 AND r->'atp'->0->>'message' = 'Line 1: you are promising 5 of SMP-1040 but can promise only 0 by 09 Nov 2026.'
                        AND (r->'lines'->0->'atp'->>'available')::numeric = 0 AND r->'lines'->0->'atp'->>'rule_code' = 'ATP-STD',
                        'ATP warning: nothing to promise for SMP-1040 in WH01', left(r::text, 300));
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.atp(''ZZ99'', ''SMP-1260'', ''WH01'', ''2026-11-09''))'))::text::numeric = 240,
                        'erp.atp = on hand 145 − committed 145 + PO 240 due 21 Sep', '');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.atp(''ZZ99'', ''SMP-1260'', ''WH01'', ''2026-09-01''))'))::text::numeric = 0,
                        'erp.atp before the PO is due = 0', '');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(erp.atp(''ZZ99'', ''SMP-1040'', ''WH02'', ''2026-11-09''))'))::text::numeric = 500 + pg_temp.oh('SMP-1040', 'WH02') - pg_temp.cm('SMP-1040', 'WH02'),
                        'erp.atp counts transfer requests into the warehouse', '');
  r := pg_temp.call(fin, 'SELECT to_jsonb(erp.atp(''ZZ99'', ''SMP-1260'', ''WH01'', ''2026-11-09''))');
  PERFORM pg_temp.check(r->>'error' = '42501', 'erp.atp refused without sales / inventory / purchase', r::text);
  r := pg_temp.call(sales, 'SELECT erp.atp_check(''ZZ99'', ''SMP-1260'', ''WH01'', ''2026-11-09'')');
  PERFORM pg_temp.check((r->>'on_hand')::numeric = pg_temp.oh('SMP-1260') AND (r->>'purchase_orders')::numeric = 240 AND jsonb_array_length(r->'incoming') >= 1,
                        'atp_check explains on hand, committed and incoming', left(r::text, 200));
  PERFORM pg_temp.check((pg_temp.call(sales, format('SELECT erp.sales_doc_checks(''ZZ99'', 17, NULL, %L::jsonb, %L::jsonb)',
         '{"card_code":"C0011","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1080","qty":600,"tax_code":"SR"},{"item_code":"SMP-1080","qty":200,"tax_code":"SR"}]')))->'atp'->0->>'line' = '2',
                        'ATP adds up lines of the same item: line 2 goes over', '');
  r := pg_temp.dsave(sales, 17, NULL, '{"card_code":"C0011","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1040","qty":5,"tax_code":"SR"}]');
  o3 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(jsonb_array_length(r->'atp') = 1, 'saving a draft above ATP is allowed (warning only)', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.dsubmit(sales, 17, o3, NULL),
    'Line 1: you are promising 5 of SMP-1040 but can promise only 0 by 09 Nov 2026. Add a reason to confirm the promise.', 'submit above ATP without a reason refused');
  r := pg_temp.dsubmit(sales, 17, o3, 'Container arrives next week');
  PERFORM pg_temp.check(r->>'state' = 'approved', 'submit above ATP with a reason: open', left(r::text, 200));
  PERFORM pg_temp.check((SELECT detail->>'reason' = 'Container arrives next week' AND jsonb_array_length(detail->'atp') = 1 FROM erp.audit_log
                          WHERE object = 'sales_order' AND object_ref = o3::text AND action = 'sales_order_submit'), 'ATP promise and reason logged', '');
  PERFORM pg_temp.check(pg_temp.cm('SMP-1040') = 5, 'ATP order commits its stock', '');
  PERFORM pg_temp.call(sales, format('SELECT erp.sales_order_cancel(''ZZ99'', %s, ''Test over'')', o3));
  PERFORM pg_temp.check(pg_temp.cm('SMP-1040') = 0, 'cancel releases committed', '');

  -- ATP rule list
  PERFORM pg_temp.expect(pg_temp.call(sread, 'SELECT erp.atp_rule_save(''ZZ99'', ''{"rule_code":"ATP-WH","name":"Warehouse only"}'')'),
    'You have read-only access to Sales. Ask the system admin for full access to create sales documents.', 'ATP rule: read-only refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.atp_rule_save(''ZZ99'', ''{"rule_code":"a b","name":"x"}'')'),
    'The rule code can use letters, numbers, - and _ (2 to 20 characters).', 'ATP rule: bad code refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.atp_rule_save(''ZZ99'', ''{"rule_code":"ATP-X","name":"x","is_default":true,"item_group":104}'')'),
    'The default rule is for all items. Clear the item group, or untick Default.', 'ATP rule: default with an item group refused');
  r := pg_temp.call(sales, 'SELECT erp.atp_rule_save(''ZZ99'', ''{"rule_code":"atp-mto","name":"Made to order","no_check":true,"item_group":104}'')');
  PERFORM pg_temp.check(r->>'rule_code' = 'ATP-MTO' AND (r->>'no_check')::boolean, 'ATP rule saved by Sales (code upper-cased)', left(r::text, 120));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'atp_rule_create' AND object_ref = 'ATP-MTO'), 'audit: atp_rule_create', '');
  r := pg_temp.call(sales, 'SELECT erp.atp_rule_save(''ZZ99'', ''{"rule_code":"ATP-MTO","name":"Made to order","no_check":true,"item_group":104,"active":false}'')');
  PERFORM pg_temp.check((r->>'active')::boolean = false AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'atp_rule_update' AND object_ref = 'ATP-MTO'),
                        'ATP rule made inactive (update logged)', '');

  -- ================= Delivery (partial) =================
  PERFORM pg_temp.expect(pg_temp.deliver(sread, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', o1)::jsonb),
    'You have read-only access to Sales. Ask the system admin for full access to create deliveries.', 'delivery: read-only refused');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":16}]', o1)::jsonb),
    format('Line 1: you are delivering 16 of SMP-1010 but only 15 are still open on sales order %s.', o_no), 'over-delivery refused');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":10},{"base_doc_entry":%s,"base_line":0,"qty":6}]', o1, o1)::jsonb),
    format('Line 1: you are delivering 16 of SMP-1010 but only 15 are still open on sales order %s.', o_no), 'over-delivery across two lines refused');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', o1)::jsonb), 'Choose a posting date.', 'delivery: date required');
  SELECT doc_entry INTO e_sample FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND source = 'sample' LIMIT 1;
  r := pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', e_sample)::jsonb);
  PERFORM pg_temp.check(r->>'message' LIKE 'Sales order % came from the sample test data, so it can''t be delivered in Super ERP.', 'delivery from a sample order refused', r->>'message');

  r := pg_temp.deliver(sales, '{"doc_date":"2026-11-09","comments":"Partial — rest next week"}',
         format('[{"base_doc_entry":%s,"base_line":0,"qty":10},{"base_doc_entry":%s,"base_line":1,"qty":10}]', o1, o1)::jsonb);
  d1 := (r->>'doc_entry')::integer; d_no := r->>'doc_no'; t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(d1 IS NOT NULL AND d_no LIKE 'DN-26-%' AND t >= 900000000, 'partial delivery created with a COGS journal', left(r::text, 200));
  PERFORM pg_temp.check(pg_temp.oh('SMP-1010') = oh1010 - 10 AND pg_temp.oh('SMP-1020') = oh1020 - 10, 'on hand down 10 / 10', '');
  PERFORM pg_temp.check(pg_temp.cm('SMP-1010') = cm1010 + 5 AND pg_temp.cm('SMP-1020') = cm1020, 'committed down by what was delivered (5 still promised)', '');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 15 AND doc_entry = d1 AND qty_out = 10 AND trans_seq >= 900000000) = 2
                        AND (SELECT price FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 15 AND doc_entry = d1 AND item_code = 'SMP-1010') = 95,
                        'stock_movement written at average cost', '');
  PERFORM pg_temp.check(pg_temp.openq(17, o1, 0) = 5 AND pg_temp.openq(17, o1, 1) = 0
                        AND (SELECT line_status FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = o1 AND line_num = 1) = 'C'
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = o1) = 'open',
                        'order lines closed by quantity; order stays open', '');
  PERFORM pg_temp.check(pg_temp.jl(t, '5100', 'd') = 10 * 95 + 10 * 42 AND pg_temp.jl(t, '1300', 'c') = 10 * 95 + 10 * 42
                        AND (SELECT trans_type FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t) = 15
                        AND EXISTS (SELECT 1 FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 15 AND doc_entry = d1 AND trans_id = t),
                        'COGS journal: Dr 5100 / Cr 1300 = 1,370.00, linked', '');
  PERFORM pg_temp.check((SELECT base_obj_type = 17 AND base_doc_entry = o1 AND stock_price = 95 FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 15 AND doc_entry = d1 AND line_num = 0),
                        'delivery line: base link to the order, cost kept', '');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":1,"qty":1}]', o1)::jsonb),
    format('Line 1: you are delivering 1 of SMP-1020 but only 0 are still open on sales order %s.', o_no), 'delivering a closed line refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.sales_order_cancel(''ZZ99'', %s, ''x'')', o1)), 'This order has a delivery and can''t be cancelled.', 'order with a delivery can''t be cancelled');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'delivery_create' AND object_ref = d1::text), 'audit: delivery_create', '');

  -- Negative stock
  r := pg_temp.dsave(sales, 17, NULL, '{"card_code":"C0011","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1080","qty":800,"tax_code":"SR"}]');
  o2 := (r->>'doc_entry')::integer;
  r := pg_temp.dsubmit(sales, 17, o2, 'Customer accepts a later delivery');
  PERFORM pg_temp.check(r->>'state' = 'approved', 'big order above ATP opens with a reason', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":800}]', o2)::jsonb),
    'Line 1: only 728 of SMP-1080 are in stock in WH01. Delivering 800 would make stock negative, and WH01 does not allow negative stock.', 'negative stock refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.warehouse_setting_set(''ZZ99'', ''WH01'', true)'),
    'Only Inventory with full access can change warehouse settings.', 'warehouse setting: sales refused');
  r := pg_temp.call(admin, 'SELECT erp.warehouse_setting_set(''ZZ99'', ''WH01'', true)');
  PERFORM pg_temp.check((r->>'allow_negative')::boolean, 'warehouse setting: inventory full may allow negative stock', left(r::text, 120));
  r := pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":730}]', o2)::jsonb);
  PERFORM pg_temp.check(r->>'doc_no' IS NOT NULL AND pg_temp.oh('SMP-1080') = -2, 'warehouse that allows it may go below zero', left(r::text, 160));
  PERFORM pg_temp.call(admin, 'SELECT erp.warehouse_setting_set(''ZZ99'', ''WH01'', false)');

  -- ================= A/R invoice =================
  PERFORM pg_temp.expect(pg_temp.invoice(sales, '{"doc_date":"2026-11-10"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":11}]', d1)::jsonb),
    format('Line 1: you are invoicing 11 of SMP-1010 but only 10 are still open on delivery %s.', d_no), 'over-invoicing refused');
  PERFORM pg_temp.expect(pg_temp.invoice(sales, '{"doc_date":"2026-11-10","card_code":"C0002"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', d1)::jsonb),
    'The deliveries are for customer C0011, not C0002.', 'invoice: other customer refused');
  PERFORM pg_temp.expect(pg_temp.invoice(sales, '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-1010","qty":1}]'),
    'Line 1: SMP-1010 is a stock item. Deliver it first, then copy the delivery to an invoice.', 'invoice: stock item without delivery refused');
  -- Closed period
  UPDATE erp.posting_period SET status = 'closed' WHERE company_code = 'ZZ99' AND period_code = '2026-10';
  PERFORM pg_temp.expect(pg_temp.invoice(sales, '{"doc_date":"2026-10-15"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":6}]', d1)::jsonb),
    'Posting period 2026-10 is closed, so nothing can be posted on 15 Oct 2026. Choose a date in an open period, or ask Finance to reopen it.', 'invoice in a closed period refused');
  PERFORM pg_temp.check(pg_temp.openq(15, d1, 0) = 10 AND NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND source = 'erp'),
                        'refused invoice changed nothing', '');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-10-15"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', o1)::jsonb),
    'Posting period 2026-10 is closed, so nothing can be posted on 15 Oct 2026. Choose a date in an open period, or ask Finance to reopen it.', 'delivery in a closed period refused');
  UPDATE erp.posting_period SET status = 'open' WHERE company_code = 'ZZ99' AND period_code = '2026-10';

  r := pg_temp.invoice(sales, '{"doc_date":"2026-11-10","customer_ref":"PO-7781"}',
         format('[{"base_doc_entry":%s,"base_line":0,"qty":6},{"base_doc_entry":%s,"base_line":1,"qty":10}]', d1, d1)::jsonb);
  i1 := (r->>'doc_entry')::integer; i_no := r->>'doc_no'; t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(i1 IS NOT NULL AND i_no LIKE 'IN-26-%' AND r->>'due_date' = '2027-01-09', 'invoice created; due date from payment terms (Net 60)', left(r::text, 200));
  SELECT sum(line_total), sum(vat), max(d.total) INTO v_net, v_vat, v_tot
    FROM erp.document_line l JOIN erp.document d USING (company_code, obj_type, doc_entry) WHERE l.company_code = 'ZZ99' AND l.obj_type = 13 AND l.doc_entry = i1;
  v_inv_total := v_tot;
  PERFORM pg_temp.check(v_net = round(6 * 133.16 * 0.88, 2) + 600 AND v_vat = round(round(6 * 133.16 * 0.88, 2) * 0.05, 2) + 30 AND v_tot = v_net + v_vat,
                        'invoice amounts from the delivered lines (price, 12% discount, VAT 5%)', format('net %s vat %s total %s', v_net, v_vat, v_tot));
  PERFORM pg_temp.check(pg_temp.jl(t, '1200', 'd') = v_tot AND pg_temp.jl(t, '4100', 'c') = v_net AND pg_temp.jl(t, '2200', 'c') = v_vat
                        AND (SELECT short_name FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t AND acct_code = '1200') = 'C0011',
                        'invoice journal: Dr A/R (customer) / Cr revenue / Cr VAT', '');
  PERFORM pg_temp.check((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011') = bal0 + v_tot, 'customer balance up by the invoice total', '');
  PERFORM pg_temp.check(pg_temp.openq(15, d1, 0) = 4 AND pg_temp.openq(15, d1, 1) = 0
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 15 AND doc_entry = d1) = 'open',
                        'delivery open quantities 4 / 0, delivery still open', '');
  PERFORM pg_temp.expect(pg_temp.invoice(sales, '{"doc_date":"2026-11-10"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":5}]', d1)::jsonb),
    format('Line 1: you are invoicing 5 of SMP-1010 but only 4 are still open on delivery %s.', d_no), 'over-invoicing after a partial invoice refused');
  -- Service invoice, no delivery
  r := pg_temp.invoice(sales, '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-SVC-01","qty":2}]');
  i2 := (r->>'doc_entry')::integer;
  v_svc_total := (r->>'total')::numeric;
  PERFORM pg_temp.check(v_svc_total = 315 AND (r->>'trans_id')::integer IS NOT NULL, 'service invoice without delivery: 2 × 150 + VAT = 315.00', left(r::text, 160));
  PERFORM pg_temp.check((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011') = bal0 + v_inv_total + 315, 'balance includes the service invoice', '');

  -- ================= A/R credit memo =================
  PERFORM pg_temp.expect(pg_temp.credit(sales, '{"doc_date":"2026-11-11","return_stock":true}', format('[{"base_doc_entry":%s,"base_line":0,"qty":7}]', i1)::jsonb),
    format('Line 1: you are crediting 7 of SMP-1010 but only 6 are still open on A/R invoice %s.', i_no), 'over-crediting refused');
  SELECT doc_entry INTO e_sample FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND source = 'sample' LIMIT 1;
  r := pg_temp.credit(sales, '{"doc_date":"2026-11-11"}', format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', e_sample)::jsonb);
  PERFORM pg_temp.check(r->>'message' LIKE 'A/R invoice % came from the sample test data, so it can''t be credited in Super ERP.', 'credit memo on a sample invoice refused', r->>'message');
  v_x := pg_temp.oh('SMP-1010');
  r := pg_temp.credit(sales, '{"doc_date":"2026-11-11","return_stock":true,"comments":"2 damaged in transit"}',
         format('[{"base_doc_entry":%s,"base_line":0,"qty":2},{"base_doc_entry":%s,"base_line":1,"qty":1}]', i1, i1)::jsonb);
  c1 := (r->>'doc_entry')::integer; t := (r->>'trans_id')::integer;
  v_cm_total := (r->>'total')::numeric;
  SELECT sum(line_total), sum(vat) INTO v_net, v_vat FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 14 AND doc_entry = c1;
  PERFORM pg_temp.check(r->>'doc_no' LIKE 'CN-26-%' AND v_net = round(2 * 133.16 * 0.88, 2) + 60 AND v_cm_total = v_net + v_vat, 'credit memo created from the invoice', left(r::text, 200));
  PERFORM pg_temp.check(pg_temp.jl(t, '1200', 'c') = v_cm_total AND pg_temp.jl(t, '4150', 'd') = v_net AND pg_temp.jl(t, '2200', 'd') = v_vat
                        AND pg_temp.jl(t, '1300', 'd') = 2 * 95 + 1 * 42 AND pg_temp.jl(t, '5100', 'c') = 2 * 95 + 1 * 42,
                        'credit memo journal: revenue + VAT reversed, goods back (Dr 1300 / Cr 5100 at delivered cost)', '');
  PERFORM pg_temp.check(pg_temp.oh('SMP-1010') = v_x + 2 AND EXISTS (SELECT 1 FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 14 AND doc_entry = c1 AND qty_in = 2),
                        'returned goods back in stock with a movement', '');
  PERFORM pg_temp.check(pg_temp.openq(13, i1, 0) = 4 AND pg_temp.openq(13, i1, 1) = 9, 'invoice open (creditable) quantities 4 / 9', '');
  PERFORM pg_temp.check((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011') = bal0 + v_inv_total + 315 - v_cm_total,
                        'customer balance down by the credit memo', '');
  v_x := pg_temp.oh('SMP-1020');
  r := pg_temp.credit(sales, '{"doc_date":"2026-11-11","return_stock":false,"comments":"Price correction"}', format('[{"base_doc_entry":%s,"base_line":1,"qty":1}]', i1)::jsonb);
  t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.oh('SMP-1020') = v_x AND pg_temp.jl(t, '1300', 'd') = 0 AND pg_temp.jl(t, '4150', 'd') = 60,
                        'credit memo without return: no stock, no inventory lines', '');
  v_cm_total := v_cm_total + (r->>'total')::numeric;
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'ar_credit_memo_create' AND object_ref = c1::text AND (detail->>'return_stock')::boolean),
                        'audit: ar_credit_memo_create with return_stock', '');

  -- ================= Reconciliation =================
  PERFORM pg_temp.check(pg_temp.oh('SMP-1010') = oh1010 - 10 + 2 AND pg_temp.cm('SMP-1010') = cm1010 + 5, 'SMP-1010: on hand −10 +2, committed +5 (still open on the order)', '');
  PERFORM pg_temp.check(pg_temp.oh('SMP-1020') = oh1020 - 10 + 1 AND pg_temp.cm('SMP-1020') = cm1020, 'SMP-1020: on hand −10 +1, nothing left committed', '');
  PERFORM pg_temp.check((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011') = bal0 + v_inv_total + v_svc_total - v_cm_total,
                        'customer balance = start + invoices − credit memos', '');
  PERFORM pg_temp.check((SELECT sum(l.credit) - sum(l.debit) FROM erp.journal_line l JOIN erp.journal_entry j USING (company_code, trans_id)
                          WHERE l.company_code = 'ZZ99' AND j.source = 'erp' AND l.acct_code = '2200' AND j.trans_type IN (13, 14))
                        = (SELECT sum(d.sign * d.vat_total) FROM erp.document d WHERE d.company_code = 'ZZ99' AND d.source = 'erp' AND d.obj_type IN (13, 14)),
                        'VAT account = invoice VAT − credit memo VAT', '');
  PERFORM pg_temp.check((SELECT sum(l.debit) - sum(l.credit) FROM erp.journal_line l JOIN erp.journal_entry j USING (company_code, trans_id)
                          WHERE l.company_code = 'ZZ99' AND j.source = 'erp' AND l.acct_code = '1200' AND j.trans_type IN (13, 14))
                        = v_inv_total + v_svc_total - v_cm_total, 'receivable = invoices − credit memos', '');
  PERFORM pg_temp.check((SELECT sum(l.debit) - sum(l.credit) FROM erp.journal_line l JOIN erp.journal_entry j USING (company_code, trans_id)
                          WHERE l.company_code = 'ZZ99' AND j.source = 'erp' AND l.acct_code = '1300' AND j.trans_type IN (15, 14))
                        = (SELECT sum((qty_in - qty_out) * price) FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_seq >= 900000000),
                        'inventory account = stock movements at cost', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_line l JOIN erp.journal_entry j USING (company_code, trans_id)
                                     WHERE l.company_code = 'ZZ99' AND j.source = 'erp' GROUP BY l.trans_id HAVING sum(l.debit) <> sum(l.credit)),
                        'every journal balances', '');

  -- ================= Flow, view, print =================
  r := pg_temp.call(sread, format('SELECT erp.sales_doc_flow(''ZZ99'', 13, %s)', i1));
  PERFORM pg_temp.check((SELECT count(DISTINCT x->>'obj_type') FROM jsonb_array_elements(r) x) = 5
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'current')::boolean AND (x->>'doc_entry')::int = i1)
                        AND r->0->>'obj_type' = '23',
                        'document flow from the invoice: quotation → order → delivery → invoice → credit memo', left(r::text, 200));
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_flow(''ZZ99'', 23, %s)', q1));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'obj_type')::int = 14), 'document flow from the quotation reaches the credit memo', '');
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_view(''ZZ99'', 15, %s)', d1));
  PERFORM pg_temp.check(r->>'doc_no' = d_no AND (r->>'trans_id')::int IS NOT NULL AND (r->>'can_copy')::boolean, 'delivery view: number, journal, can copy to invoice', left(r::text, 160));
  r := pg_temp.call(sales, format('SELECT erp.sales_print_data(''ZZ99'', 13, %s)', i1));
  PERFORM pg_temp.check(r->'company'->>'tax_id' = '100000000000003' AND r->'doc'->>'doc_no' = i_no AND jsonb_array_length(r->'lines') = 2
                        AND (r->'vat'->0->>'vat')::numeric > 0, 'print data: company TRN, number, lines, VAT summary', left(r::text, 160));
  r := pg_temp.call(fin, format('SELECT erp.sales_print_data(''ZZ99'', 13, %s)', i1));
  PERFORM pg_temp.check(r->'doc'->>'doc_no' = i_no, 'finance can print an invoice', left(r::text, 80));

  -- ================= SAP rows are never written =================
  INSERT INTO erp.business_partner (company_code, card_code, kind, name, currency, balance, price_list, payment_terms, active, source)
  VALUES ('ZZ99', 'CSAP1', 'customer', 'SAP customer (test)', 'AED', 1000, 1, 1, true, 'sap');
  r := pg_temp.invoice(sales, '{"doc_date":"2026-11-10","card_code":"CSAP1"}', '[{"item_code":"SMP-SVC-01","qty":1}]');
  PERFORM pg_temp.check((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'CSAP1') = 1000
                        AND (SELECT balance FROM erp.bp_balance_erp WHERE company_code = 'ZZ99' AND card_code = 'CSAP1') = (r->>'total')::numeric,
                        'SAP customer: business_partner untouched, ERP change kept in bp_balance_erp', left(r::text, 120));
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, currency, total, source)
  VALUES ('ZZ99', 17, 777101, 777101, 'sales_order', 'open', '2026-11-01', 'C0011', 'AED', 100, 'sap');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total, whs_code, line_status)
  VALUES ('ZZ99', 17, 777101, 0, 'SMP-1010', 1, 1, 100, 100, 'WH01', 'O');
  PERFORM pg_temp.expect(pg_temp.deliver(sales, '{"doc_date":"2026-11-09"}', '[{"base_doc_entry":777101,"base_line":0,"qty":1}]'),
    'Sales order 777101 came from SAP Business One, so it can''t be delivered in Super ERP.', 'delivery from a SAP order refused');
  PERFORM pg_temp.check((SELECT open_qty FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_entry = 777101) = 1, 'SAP order line untouched', '');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.sales_copy_source(''ZZ99'', 17, 777101)'),
    'Sales order 777101 came from SAP Business One. Copy to works on Super ERP documents only.', 'copy from a SAP order refused');

  -- A2 wrappers still behave as before
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT erp.sales_order_setup(''ZZ99'')'))->>'numbering' IS NOT NULL
                        AND ((pg_temp.call(sales, 'SELECT erp.sales_order_setup(''ZZ99'')'))->>'atp_on')::boolean, 'sales_order_setup: numbering and ATP on', '');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a4_result ORDER BY n;
SELECT 'TOTAL', format('%s passed, %s failed', count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok)), '' FROM a4_result;
ROLLBACK;
