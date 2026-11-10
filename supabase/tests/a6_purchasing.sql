-- A6 · Purchasing (China flow) tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (base.txt incl. 21_purchasing.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a6_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a6_result TO authenticated;

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
CREATE FUNCTION pg_temp.su(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    EXECUTE p_sql INTO v;
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a6_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 200)))
$$;
CREATE FUNCTION pg_temp.save(p_user uuid, p_obj integer, p_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.purchase_doc_save(%L, %s, %s, %L::jsonb, %L::jsonb)', 'ZZ99', p_obj, coalesce(p_entry::text, 'NULL'), p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.submit(p_user uuid, p_obj integer, p_entry integer, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.purchase_doc_submit(%L, %s, %s, %L)', 'ZZ99', p_obj, p_entry, p_reason))
$$;
CREATE FUNCTION pg_temp.decide(p_user uuid, p_entry integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.purchase_doc_decide(%L, 22, %s, %L, %L)', 'ZZ99', p_entry, p_decision, p_note))
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END
                    || CASE WHEN short_name IS DISTINCT FROM acct_code THEN ' ' || short_name ELSE '' END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.balanced(p_trans integer) RETURNS boolean LANGUAGE sql AS $$
  SELECT count(*) >= 2 AND sum(debit) = sum(credit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.sb(p_item text, p_whs text) RETURNS erp.stock_balance LANGUAGE sql AS $$
  SELECT * FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = p_item AND whs_code = p_whs
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  pmgr   uuid := '00000000-0000-4000-8000-000000000011';
  staff  uuid := '00000000-0000-4000-8000-000000000012';
  r jsonb; r2 jsonb;
  req integer; req_no text; q1 integer; q2 integer; po integer; po_no text; po2 integer;
  pi integer; dp integer; dp_no text; dp2 integer; dp2_no text; pay integer;
  sh integer; gr integer; gr_no text; ap integer; ap_no text; lc integer; lc2 integer;
  v_trans integer; v_t numeric; v_n integer;
  sb0 erp.stock_balance; sb1 erp.stock_balance; sb2 erp.stock_balance;
  oo0 numeric; avg1150 numeric; oh1150 numeric;
  bal0 numeric;
  smp_po integer; smp_no text;
  hreq jsonb := '{"doc_date":"2026-11-10","due_date":"2026-12-15","china_office":"SZ","whs_code":"WH01","comments":"Winter range"}';
BEGIN
  -- ---------- Access ----------
  r := pg_temp.call(sales, $q$SELECT erp.purchase_doc_setup('ZZ99')$q$);
  PERFORM pg_temp.expect(r, 'Your position does not include Purchasing. Ask the system admin if you need it.', 'sales-only user can''t open purchasing');
  r := pg_temp.call(nobody, $q$SELECT erp.purchase_doc_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'user without a profile refused', r::text);
  r := pg_temp.call(purch, $q$SELECT erp.purchase_doc_setup('AE01')$q$);
  PERFORM pg_temp.expect(r, 'You don''t have access to company AE01.', 'other company refused');
  r := pg_temp.call(purch, $q$SELECT erp.purchase_doc_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'default_tax_code' = 'IP' AND jsonb_array_length(r->'offices') = 4 AND (r->>'can_write')::boolean
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'tax_codes') t WHERE t->>'code' = 'SR')
                        AND (r->>'my_po_limit')::numeric = 50000 AND (r->>'price_increase_pct')::numeric = 10,
                        'setup: purchase tax codes only, 4 China offices, PO limit 50,000, +10 % rule', left(r::text, 300));

  -- ---------- 1 · Purchase request (any staff member with Purchasing access) ----------
  PERFORM pg_temp.expect(pg_temp.save(staff, 1470000113, NULL, '{"doc_date":"2026-11-10"}', '[{"item_code":"SMP-1140","qty":1000}]'),
    'Choose the date the goods are needed by.', 'request needs a needed-by date');
  PERFORM pg_temp.expect(pg_temp.save(staff, 1470000113, NULL, hreq, '[{"item_code":"SMP-SVC-01","qty":1}]'),
    'Line 1: SMP-SVC-01 is not a purchase item.', 'non-purchase item refused');
  PERFORM pg_temp.expect(pg_temp.save(staff, 1470000113, NULL, hreq || '{"china_office":"XX"}', '[{"item_code":"SMP-1140","qty":1000}]'),
    'China office XX is not set up for ZZ99.', 'unknown China office refused');
  r := pg_temp.save(staff, 1470000113, NULL, hreq, '[{"item_code":"SMP-1140","qty":1000},{"item_code":"SMP-1150","qty":50}]');
  req := (r->>'doc_entry')::integer; req_no := r->>'doc_no';
  PERFORM pg_temp.check(req_no = 'PR-26-00001' AND req >= 900000000 AND (r->'totals'->>'total')::numeric = 0, 'staff (read-only Purchasing) saves a request', left(r::text, 200));
  r := pg_temp.submit(staff, 1470000113, req);
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'open', 'request opens straight away (no approval rules)', r::text);
  PERFORM pg_temp.expect(pg_temp.save(staff, 540000006, NULL, '{"card_code":"S0009","doc_date":"2026-11-10"}', '[{"item_code":"SMP-1140","qty":1,"price":1}]'),
    'You have read-only access to Purchasing. Ask the system admin for full access to create purchase quotations.', 'staff can''t create quotations');
  PERFORM pg_temp.check((SELECT china_office FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 1470000113 AND doc_entry = req) = 'SZ',
    'China office stored on the request');

  -- ---------- 2 · Quotations from two suppliers, compared ----------
  PERFORM pg_temp.expect(pg_temp.save(purch, 540000006, NULL, '{"card_code":"S0001","doc_date":"2026-11-10"}', '[{"item_code":"SMP-1140","qty":1000,"price":16}]'),
    'Supplier S0001 is billed in USD. Purchasing in a foreign currency comes in a later stage.', 'USD supplier refused (company currency only)');
  PERFORM pg_temp.expect(pg_temp.save(purch, 540000006, NULL, '{"card_code":"C0001","doc_date":"2026-11-10"}', '[{"item_code":"SMP-1140","qty":1,"price":1}]'),
    'C0001 is not a supplier. Choose a supplier.', 'customer as supplier refused');
  PERFORM pg_temp.expect(pg_temp.save(purch, 540000006, NULL, '{"card_code":"S0009","doc_date":"2026-11-10"}', '[{"item_code":"SMP-1140","qty":1,"price":1,"tax_code":"SR"}]'),
    'Line 1: tax code SR is for sales. Choose a purchase tax code.', 'sales tax code refused');
  r := pg_temp.save(purch, 540000006, NULL, '{"card_code":"S0009","doc_date":"2026-11-10","customer_ref":"Q-SZ-1"}',
    format('[{"item_code":"SMP-1140","qty":1000,"price":60,"base_obj_type":1470000113,"base_doc_entry":%s,"base_line":0},{"item_code":"SMP-1150","qty":50,"price":100,"base_obj_type":1470000113,"base_doc_entry":%s,"base_line":1}]', req, req)::jsonb);
  q1 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'PQ-26-00001' AND (r->'totals'->>'total')::numeric = 68250, 'quotation 1 (S0009) priced: 65,000 + VAT 3,250', left(r::text, 200));
  r := pg_temp.save(purch, 540000006, NULL, '{"card_code":"S0010","doc_date":"2026-11-10"}',
    format('[{"item_code":"SMP-1140","qty":1000,"price":58,"base_obj_type":1470000113,"base_doc_entry":%s,"base_line":0},{"item_code":"SMP-1150","qty":50,"price":105,"base_obj_type":1470000113,"base_doc_entry":%s,"base_line":1}]', req, req)::jsonb);
  q2 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.submit(purch, 540000006, q1);
  r := pg_temp.submit(purch, 540000006, q2);
  PERFORM pg_temp.check(r->>'status' = 'open' AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 1470000113 AND doc_entry = req) = 'open',
    'quotations open; the request stays open (quotations don''t use it up)', r::text);
  r := pg_temp.call(purch, format('SELECT erp.purchase_quotation_compare(%L, %s)', 'ZZ99', req));
  PERFORM pg_temp.check(jsonb_array_length(r->'quotations') = 2 AND jsonb_array_length(r->'lines'->0->'offers') = 2
                        AND (SELECT o->>'card_code' FROM jsonb_array_elements(r->'lines'->0->'offers') o WHERE (o->>'best')::boolean) = 'S0010'
                        AND (SELECT o->>'card_code' FROM jsonb_array_elements(r->'lines'->1->'offers') o WHERE (o->>'best')::boolean) = 'S0009',
                        'comparison: 2 quotations side by side, cheapest marked per line', left(r::text, 300));

  -- ---------- 3 · Purchase order with approval ----------
  PERFORM pg_temp.expect(pg_temp.save(purch, 22, NULL, '{"card_code":"S0010","doc_date":"2026-11-10"}',
    format('[{"item_code":"SMP-1140","qty":1000,"price":60,"base_obj_type":540000006,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb),
    'Line 1: quotation PQ-26-00001 is from supplier S0009. Copy it to an order for the same supplier.', 'order copied from another supplier''s quotation refused');
  PERFORM pg_temp.expect(pg_temp.save(purch, 22, NULL, '{"card_code":"S0009","doc_date":"2026-11-10"}',
    format('[{"item_code":"SMP-1140","qty":1001,"price":60,"base_obj_type":540000006,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb),
    'Line 1: only 1000 of SMP-1140 are still open on purchase quotation PQ-26-00001.', 'order above the quotation quantity refused');
  r := pg_temp.save(purch, 22, NULL, '{"card_code":"S0009","doc_date":"2026-11-10","due_date":"2026-12-31","china_office":"SZ","whs_code":"WH01"}',
    format('[{"item_code":"SMP-1140","qty":1000,"price":60,"cbm":30,"base_obj_type":540000006,"base_doc_entry":%s,"base_line":0},{"item_code":"SMP-1150","qty":50,"price":100,"cbm":5,"base_obj_type":540000006,"base_doc_entry":%s,"base_line":1}]', q1, q1)::jsonb);
  po := (r->>'doc_entry')::integer; po_no := r->>'doc_no';
  PERFORM pg_temp.check(po_no = 'PO-26-00001' AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'checks') c WHERE c->>'rule_code' = 'po_amount'
                        AND c->>'message' = 'Purchase order total 68,250.00 AED is above your limit of 50,000.00 AED.'),
                        'PO above 50,000 flags the po_amount rule with its message', left(r::text, 400));
  r := pg_temp.submit(purch, 22, po);
  PERFORM pg_temp.check(r->>'message' LIKE 'This purchase order needs approval (%total above your limit%). Add a reason for the approver.', 'submit needs a reason', r::text);
  SELECT on_order INTO oo0 FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = 'SMP-1140' AND whs_code = 'WH01';
  r := pg_temp.submit(purch, 22, po, 'Winter range, price agreed in Shenzhen');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = po) = 'draft',
    'PO waits for approval (still draft)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-10"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, po)),
    'Purchase order PO-26-00001 is not open (pending approval). Only approved, open documents can be received.', 'PO approval enforced: no receipt before approval');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_deposit_create('ZZ99', %s, '{"doc_date":"2026-11-10","pct":30}')$q$, po)),
    'Purchase order PO-26-00001 is not approved yet (pending approval). A deposit needs an approved order.', 'PO approval enforced: no deposit before approval');
  r := pg_temp.call(pmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'purchase_order' AND w->>'doc_no' = po_no),
    'purchasing manager sees the PO in the approvals inbox', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.decide(purch, po, 'approved'), 'You can''t approve your own purchase order.', 'requester can''t approve own PO');
  PERFORM pg_temp.expect(pg_temp.decide(staff, po, 'approved'),
    'You have read-only access to Purchasing. Ask the system admin for full access to approve purchase orders.', 'read-only user can''t approve');
  PERFORM pg_temp.expect(pg_temp.decide(admin, po, 'approved'),
    'This purchase order is waiting for approval from QA · purchasing manager. Your position can''t decide it.', 'other position can''t approve');
  r := pg_temp.decide(pmgr, po, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'open', 'purchasing manager approves: PO open', r::text);
  PERFORM pg_temp.check((SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 1470000113 AND doc_entry = req) = 'closed'
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 540000006 AND doc_entry = q1) = 'closed'
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 540000006 AND doc_entry = q2) = 'open',
    'opening the PO uses up quotation 1 and the request (quotation 2 stays open)');
  PERFORM pg_temp.check((pg_temp.sb('SMP-1140', 'WH01')).on_order = oo0 + 1000, 'PO quantity on order in WH01',
    (pg_temp.sb('SMP-1140', 'WH01')).on_order::text);

  -- ---------- 4 · Proforma invoice and deposit ----------
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_pi_save('ZZ99', NULL, '{"po_doc_entry":%s,"vendor_pi_no":"SZ-PI-7781","pi_date":"2026-11-11","status":"bogus"}')$q$, po)),
    'PI status bogus is not set up for ZZ99.', 'unknown PI status refused');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_pi_save('ZZ99', NULL, '{"po_doc_entry":%s,"vendor_pi_no":"SZ-PI-7781","pi_date":"2026-11-11","amount":68250,"eta":"2026-12-20","status":"received"}')$q$, po));
  pi := (r->>'pi_id')::integer;
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_pi_save('ZZ99', %s, '{"vendor_pi_no":"SZ-PI-7781","pi_date":"2026-11-11","amount":68250,"eta":"2026-12-20","status":"confirmed"}')$q$, pi));
  PERFORM pg_temp.check(r->>'status' = 'confirmed' AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'purchase_pi_update' AND object_ref = pi::text
                          AND detail->>'from_status' = 'received' AND detail->>'status' = 'confirmed'), 'PI status change tracked', r::text);
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_pi_save('ZZ99', NULL, '{"po_doc_entry":%s,"vendor_pi_no":"SZ-PI-7781","pi_date":"2026-11-11","status":"received"}')$q$, po)),
    'PI SZ-PI-7781 of supplier S0009 is already recorded.', 'duplicate PI refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_deposit_create('ZZ99', %s, '{"doc_date":"2026-11-12","amount":70000}')$q$, po)),
    'Deposits on PO-26-00001 would be 70,000.00 AED, more than the order total of 68,250.00 AED (0.00 AED already raised).', 'deposit above the order refused');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_deposit_create('ZZ99', %s, '{"doc_date":"2026-11-12","pct":30,"pi_id":%s}')$q$, po, pi));
  dp := (r->>'doc_entry')::integer; dp_no := r->>'doc_no'; v_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(dp_no = 'DPI-26-00001' AND (r->>'total')::numeric = 20475 AND pg_temp.jl(v_trans) = '1350 Dr 20475, 2100 Cr 20475 S0009',
    'deposit = A/P down payment invoice 30 %: Dr down payments / Cr payable', coalesce(pg_temp.jl(v_trans), r::text));
  PERFORM pg_temp.check((SELECT deposit_doc_entry FROM erp.purchase_pi WHERE pi_id = pi) = dp, 'PI linked to its deposit');
  -- A5 pays the deposit (outgoing payment allocated to the 204).
  r := pg_temp.call(admin, format($q$SELECT erp.payment_open_docs('ZZ99', 'O', 'S0009')$q$));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'docs') x WHERE (x->>'obj_type')::integer = 204 AND (x->>'doc_entry')::integer = dp
                          AND (x->>'open')::numeric = 20475), 'A5 lists the deposit as payable', left(r::text, 300));
  r := pg_temp.call(admin, format($q$SELECT erp.payment_submit('ZZ99', 'O', '{"card_code":"S0009","doc_date":"2026-11-12","transfer":20475,"transfer_bank":"BNK-AED","transfer_ref":"TT-1"}', '[{"obj_type":204,"doc_entry":%s,"amount":20475}]')$q$, dp));
  pay := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'doc_no' LIKE 'PV-26-%' AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 204 AND doc_entry = dp) = 20475,
    'outgoing payment pays the deposit (A5)', r::text);

  -- ---------- 5 · QC inspection ----------
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"eta":"2026-12-20","shipment_mode":"sea","container_no":"MSKU1234567"}', '[{"po_line":0,"qty":600}]')$q$, po)),
    'Purchase order PO-26-00001 has no QC inspection yet. Record a passed inspection before shipping.', 'no shipment before QC');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","result":"rework"}')$q$, po, current_date)),
    'Add a note saying what failed or needs rework.', 'rework needs a note');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","inspector":"Li Wei","result":"rework","note":"Rating plates missing on 40 units"}')$q$, po, current_date));
  PERFORM pg_temp.check(r->>'result' = 'rework', 'rework inspection recorded', r::text);
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"eta":"2026-12-20","shipment_mode":"sea","container_no":"MSKU1234567"}', '[{"po_line":0,"qty":600}]')$q$, po)),
    'The last QC inspection of PO-26-00001 was rework. Record a passed inspection before shipping.', 'no shipment after a rework result');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","result":"pass","checklist":[{"code":"qty","ok":true},{"code":"label","ok":false}]}')$q$, po, current_date)),
    'A checklist item is not ticked, so the result can''t be pass. Tick it, or choose fail or rework.', 'pass with an unticked checklist item refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","result":"pass","photos":["AE01/1/x.jpg"]}')$q$, po, current_date)),
    format('Photo AE01/1/x.jpg is not stored under qc/ZZ99/%s/. Upload it again from this page.', po), 'photo outside qc/<company>/<po>/ refused');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","inspector":"Li Wei","result":"pass","checklist":[{"code":"qty","ok":true},{"code":"function","ok":true},{"code":"label","ok":true}],"photos":["ZZ99/%s/carton.jpg"]}')$q$, po, current_date, po));
  PERFORM pg_temp.check(r->>'result' = 'pass' AND (SELECT cardinality(photos) FROM erp.qc_inspection WHERE qc_id = (r->>'qc_id')::integer) = 1
                        AND (SELECT checklist->1->>'name' FROM erp.qc_inspection WHERE qc_id = (r->>'qc_id')::integer) = 'Function test passed',
    'passed inspection with checklist and photo path', r::text);

  -- ---------- 6 · Shipment (ETA feeds ATP) ----------
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"eta":"2026-12-20","shipment_mode":"sea"}', '[{"po_line":0,"qty":600}]')$q$, po)),
    'Enter the container number for a sea shipment.', 'sea shipment needs a container');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"container_no":"MSKU1234567","shipping_mark":"SANFORD DXB","shipment_mode":"sea","etd":"2026-11-25","eta":"2026-12-20"}', '[{"po_line":0,"qty":600}]')$q$, po));
  sh := (r->>'shipment_id')::integer;
  PERFORM pg_temp.check(sh IS NOT NULL AND (SELECT container_no FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = po) = 'MSKU1234567',
    'shipment recorded; PO shows the container', r::text);
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"container_no":"MSKU7654321","shipment_mode":"sea","eta":"2026-12-28"}', '[{"po_line":0,"qty":500}]')$q$, po)),
    'Line 1: you are shipping 500 of SMP-1140 but only 400 are open on PO-26-00001 and not on a shipment yet.', 'shipping more than is open refused');
  r := pg_temp.su($q$SELECT erp._atp('ZZ99', 'SMP-1140', 'WH01', '2026-12-25', erp._atp_rule('ZZ99', 'SMP-1140'))$q$);
  r2 := pg_temp.su($q$SELECT erp._atp('ZZ99', 'SMP-1140', 'WH01', '2026-12-15', erp._atp_rule('ZZ99', 'SMP-1140'))$q$);
  PERFORM pg_temp.check((r->>'in_transit')::numeric = 600 AND (r2->>'in_transit')::numeric = 0
                        AND (r->>'available')::numeric = (r2->>'available')::numeric + 600,
    'ATP counts the container by its ETA (600 by 25 Dec, none by 15 Dec)', r::text || ' / ' || r2::text);
  r := pg_temp.su($q$SELECT erp._atp('ZZ99', 'SMP-1140', 'WH01', '2027-01-05', erp._atp_rule('ZZ99', 'SMP-1140'))$q$);
  PERFORM pg_temp.check((r->>'in_transit')::numeric = 600 AND (r->>'purchase_orders')::numeric = (SELECT sum(l.open_qty) FROM erp.document_line l
                          JOIN erp.document d USING (company_code, obj_type, doc_entry) WHERE l.company_code = 'ZZ99' AND l.obj_type = 22 AND d.status = 'open'
                          AND l.item_code = 'SMP-1140' AND l.whs_code = 'WH01' AND coalesce(d.due_date, d.doc_date) <= '2027-01-05') - 600,
    'shipped PO quantity is not counted twice (PO part minus the container)', r::text);

  -- ---------- 7 · Goods receipt PO ----------
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1001}]')$q$, po)),
    'Line 1: you are receiving 1001 of SMP-1140 but only 1000 are still open on purchase order PO-26-00001.', 'GRPO beyond the PO quantity refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":600},{"base_doc_entry":%s,"base_line":0,"qty":401}]')$q$, po, po)),
    'Line 1: you are receiving 1001 of SMP-1140 but only 1000 are still open on purchase order PO-26-00001.', 'the same PO line twice is added up');
  SELECT doc_entry, doc_num::text INTO smp_po, smp_no FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 22 AND source = 'sample' AND status = 'open' LIMIT 1;
  IF smp_po IS NOT NULL THEN
    PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, smp_po)),
      format('Purchase order %s came from the sample test data, so it can''t be received in Super ERP.', smp_no), 'sample PO can''t be received');
  ELSE
    PERFORM pg_temp.check(true, 'sample PO can''t be received (no open sample PO to try)');
  END IF;
  sb0 := pg_temp.sb('SMP-1140', 'WH01');
  sb1 := pg_temp.sb('SMP-1150', 'WH01');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-20","customer_ref":"DN-8812"}', '[{"base_doc_entry":%s,"base_line":0,"qty":600},{"base_doc_entry":%s,"base_line":1,"qty":50}]')$q$, po, po));
  gr := (r->>'doc_entry')::integer; gr_no := r->>'doc_no'; v_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(gr_no = 'GR-26-00001' AND pg_temp.jl(v_trans) = '1300 Dr 41000, 2120 Cr 41000',
    'GRPO posts Dr inventory / Cr goods received not invoiced at PO price (600×60 + 50×100)', coalesce(pg_temp.jl(v_trans), r::text));
  sb2 := pg_temp.sb('SMP-1140', 'WH01');
  PERFORM pg_temp.check(sb2.on_hand = sb0.on_hand + 600 AND sb2.on_order = sb0.on_order - 600
                        AND sb2.avg_cost = round((greatest(sb0.on_hand, 0) * coalesce(sb0.avg_cost, 60) + 600 * 60) / (greatest(sb0.on_hand, 0) + 600), 6),
    'stock in at PO price, average cost updated, off order', format('%s → %s, avg %s → %s', sb0.on_hand, sb2.on_hand, sb0.avg_cost, sb2.avg_cost));
  sb2 := pg_temp.sb('SMP-1150', 'WH01');
  PERFORM pg_temp.check(sb2.avg_cost = round((sb1.on_hand * sb1.avg_cost + 50 * 100) / (sb1.on_hand + 50), 6),
    'average cost of an item already in stock is blended', format('%s → %s', sb1.avg_cost, sb2.avg_cost));
  PERFORM pg_temp.check((SELECT status FROM erp.purchase_shipment WHERE shipment_id = sh) = 'arrived'
                        AND (SELECT received_qty FROM erp.purchase_shipment_line WHERE shipment_id = sh AND po_line = 0) = 600,
    'the container is marked received and arrived');
  PERFORM pg_temp.check((SELECT open_qty FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = po AND line_num = 0) = 400
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = po) = 'open'
                        AND (SELECT cbm FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 20 AND doc_entry = gr AND line_num = 0) = 18,
    'PO line 1 has 400 left; receipt carries its share of the CBM (18 of 30)');

  -- ---------- 8 · A/P invoice (draws the deposit) ----------
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_deposit_create('ZZ99', %s, '{"doc_date":"2026-11-12","amount":3412.50}')$q$, po));
  dp2 := (r->>'doc_entry')::integer; dp2_no := r->>'doc_no';
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-21","down_payments":[{"doc_entry":%s,"amount":100}]}', '[{"base_doc_entry":%s,"base_line":0,"qty":600}]')$q$, dp2, gr)),
    format('Down payment invoice %s is not paid yet. Pay it first in Banking › Outgoing Payments, then draw it.', dp2_no), 'unpaid down payment can''t be drawn');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-21","down_payments":[{"doc_entry":%s,"amount":30000}]}', '[{"base_doc_entry":%s,"base_line":0,"qty":600}]')$q$, dp, gr)),
    format('You are drawing 30,000.00 AED from down payment invoice %s, but only 20,475.00 AED of it is paid and not drawn yet.', dp_no), 'drawing more than paid refused');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-21"}', '[{"base_doc_entry":%s,"base_line":0,"qty":601}]')$q$, gr)),
    'Line 1: you are invoicing 601 of SMP-1140 but only 600 are still open on goods receipt GR-26-00001.', 'invoicing more than received refused');
  bal0 := coalesce((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'S0009'), 0);
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-21","customer_ref":"INV-SZ-5521","down_payments":[{"doc_entry":%s,"amount":20475}]}', '[{"base_doc_entry":%s,"base_line":0,"qty":600},{"base_doc_entry":%s,"base_line":1,"qty":50}]')$q$, dp, gr, gr));
  ap := (r->>'doc_entry')::integer; ap_no := r->>'doc_no'; v_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(ap_no = 'AP-26-00001' AND (r->>'gross')::numeric = 43050 AND (r->>'drawn')::numeric = 20475 AND (r->>'total')::numeric = 22575,
    'A/P invoice: gross 43,050, deposit drawn 20,475, 22,575 due', r::text);
  PERFORM pg_temp.check(pg_temp.jl(v_trans) = '2120 Dr 41000, 1400 Dr 2050, 2100 Cr 43050 S0009, 2100 Dr 20475 S0009, 1350 Cr 20475',
    'A/P invoice posts through A3: clears GRNI, input VAT, payable, draws the down payment', pg_temp.jl(v_trans));
  PERFORM pg_temp.check((SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 204 AND doc_entry = dp) = 'closed'
                        AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 20 AND doc_entry = gr) = 'closed'
                        AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = ap) = 0
                        AND (SELECT source FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = ap) = 'erp',
    'deposit drawn in full is closed; receipt fully invoiced is closed; invoice is a Super ERP document with paid = 0');
  PERFORM pg_temp.check(coalesce((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'S0009'), 0) = bal0 - 22575,
    'supplier balance owes the amount due', format('%s → %s', bal0, (SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'S0009')));
  r := pg_temp.call(admin, $q$SELECT erp.payment_open_docs('ZZ99', 'O', 'S0009')$q$);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'docs') x WHERE (x->>'obj_type')::integer = 18 AND (x->>'doc_entry')::integer = ap AND (x->>'open')::numeric = 22575)
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'docs') x WHERE (x->>'obj_type')::integer = 204 AND (x->>'doc_entry')::integer = dp),
    'A5 offers the invoice (22,575 open) and no longer the paid deposit', left(r::text, 400));
  r := pg_temp.call(admin, format($q$SELECT erp.payment_submit('ZZ99', 'O', '{"card_code":"S0009","doc_date":"2026-11-22","transfer":10000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":%s,"amount":10000}]')$q$, ap));
  PERFORM pg_temp.check(r->>'doc_no' LIKE 'PV-26-%' AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = ap) = 10000
                        AND erp._bk_doc_open('ZZ99', 18, ap) = 12575, 'A5 outgoing payment allocates to the A/P invoice', r::text);

  -- ---------- 9 · Landed costs ----------
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.landed_cost_preview('ZZ99', '{"doc_date":"2026-11-25"}', '[{"grpo_entry":%s,"grpo_line":0},{"grpo_entry":%s,"grpo_line":1}]', '[{"code":"TRANSPORT","amount":300}]')$q$, gr, gr)),
    'Landed cost 1 (Local transport) is split by weight, but none of the lines has a weight. Enter it on the lines.', 'weight split needs weights');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.landed_cost_preview('ZZ99', '{"doc_date":"2026-11-25"}', '[{"grpo_entry":%s,"grpo_line":0}]', '[{"code":"PORT","amount":300}]')$q$, gr)),
    'Landed cost 1: code PORT is not set up for ZZ99. Ask Purchasing to add it in Purchasing › Purchasing Setup.', 'unknown landed cost code refused');
  sb0 := pg_temp.sb('SMP-1140', 'WH01');
  sb1 := pg_temp.sb('SMP-1150', 'WH01');
  r := pg_temp.call(purch, format($q$SELECT erp.landed_cost_create('ZZ99', '{"doc_date":"2026-11-25","card_code":"S0006","reference":"FWD-221"}', '[{"grpo_entry":%s,"grpo_line":0},{"grpo_entry":%s,"grpo_line":1}]', '[{"code":"FREIGHT","amount":1000},{"code":"DUTY","amount":2050},{"code":"CLEARING","amount":100}]')$q$, gr, gr));
  lc := (r->>'doc_entry')::integer; v_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'LC-26-00001' AND (r->>'total')::numeric = 3150 AND pg_temp.jl(v_trans) = '1300 Dr 3150, 2130 Cr 3150',
    'landed costs post Dr inventory / Cr landed cost clearing', coalesce(pg_temp.jl(v_trans), r::text));
  PERFORM pg_temp.check((SELECT string_agg(amount::text, ',' ORDER BY line_num) FROM erp.landed_cost_alloc WHERE company_code = 'ZZ99' AND doc_entry = lc AND charge_no = 0) = '782.61,217.39'
                        AND (SELECT string_agg(amount::text, ',' ORDER BY line_num) FROM erp.landed_cost_alloc WHERE company_code = 'ZZ99' AND doc_entry = lc AND charge_no = 1) = '1800.00,250.00'
                        AND (SELECT string_agg(amount::text, ',' ORDER BY line_num) FROM erp.landed_cost_alloc WHERE company_code = 'ZZ99' AND doc_entry = lc AND charge_no = 2) = '92.31,7.69',
    'split by CBM 18:5, value 36,000:5,000, quantity 600:50; remainder on the last line',
    (SELECT string_agg(charge_no || ':' || amount, ' ' ORDER BY charge_no, line_num) FROM erp.landed_cost_alloc WHERE company_code = 'ZZ99' AND doc_entry = lc));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.landed_cost_charge c WHERE c.company_code = 'ZZ99' AND c.doc_entry = lc
                                      AND c.amount <> (SELECT sum(a.amount) FROM erp.landed_cost_alloc a WHERE a.company_code = c.company_code AND a.doc_entry = c.doc_entry AND a.charge_no = c.charge_no))
                        AND (SELECT sum(allocated) FROM erp.landed_cost_line WHERE company_code = 'ZZ99' AND doc_entry = lc) = 3150,
    'every charge adds up exactly');
  sb2 := pg_temp.sb('SMP-1140', 'WH01');
  PERFORM pg_temp.check(sb2.avg_cost = round((sb0.on_hand * sb0.avg_cost + 2674.92) / sb0.on_hand, 6)
                        AND (pg_temp.sb('SMP-1150', 'WH01')).avg_cost = round((sb1.on_hand * sb1.avg_cost + 475.08) / sb1.on_hand, 6),
    'average cost raised by the landed costs on stock', format('SMP-1140 %s → %s', sb0.avg_cost, sb2.avg_cost));
  -- Goods partly sold: only the on-hand share goes to inventory, the rest to cost of goods sold.
  PERFORM pg_temp.su($q$WITH x AS (UPDATE erp.stock_balance SET on_hand = 200 WHERE company_code = 'ZZ99' AND item_code = 'SMP-1140' AND whs_code = 'WH01' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  sb0 := pg_temp.sb('SMP-1140', 'WH01');
  r := pg_temp.call(admin, format($q$SELECT erp.landed_cost_create('ZZ99', '{"doc_date":"2026-11-26"}', '[{"grpo_entry":%s,"grpo_line":0,"weight":5400}]', '[{"code":"TRANSPORT","amount":300}]')$q$, gr));
  lc2 := (r->>'doc_entry')::integer; v_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check((r->>'to_inventory')::numeric = 100 AND (r->>'to_cogs')::numeric = 200 AND pg_temp.jl(v_trans) = CASE WHEN to_regclass('erp.sales_doc_request') IS NULL THEN '1300 Dr 100, 5100 Dr 200, 2130 Cr 300' ELSE '1300 Dr 100, 5340 Dr 200, 2130 Cr 300' END
                        AND (pg_temp.sb('SMP-1140', 'WH01')).avg_cost = round((200 * sb0.avg_cost + 100) / 200, 6),
    '200 of 600 on hand: 1/3 to inventory (average cost), 2/3 to COGS (price difference since B1)', coalesce(pg_temp.jl(v_trans), r::text));
  PERFORM pg_temp.expect(pg_temp.call(staff, format($q$SELECT erp.landed_cost_create('ZZ99', '{"doc_date":"2026-11-26"}', '[{"grpo_entry":%s,"grpo_line":0}]', '[{"code":"CLEARING","amount":1}]')$q$, gr)),
    'You have read-only access to Purchasing. Ask the system admin for full access to post landed costs.', 'read-only user can''t post landed costs');

  -- ---------- 10 · Price-increase rule, reject, cancel ----------
  r := pg_temp.save(purch, 22, NULL, '{"card_code":"S0009","doc_date":"2026-11-27","whs_code":"WH01"}', '[{"item_code":"SMP-1140","qty":10,"price":70}]');
  po2 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'checks') c WHERE c->>'rule_code' = 'po_price_increase'
                          AND c->>'message' LIKE 'Line 1: price 70.00 for SMP-1140 is 16.67% above the last purchase price of 60.00 (%). The limit is 10%.'),
    'price more than 10 % over the last purchase price flagged', left(r::text, 400));
  r := pg_temp.submit(purch, 22, po2, 'New mould cost');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'price rule sends the PO for approval', r::text);
  PERFORM pg_temp.expect(pg_temp.decide(pmgr, po2, 'rejected'), 'Add a note saying why you are rejecting this purchase order.', 'reject needs a note');
  r := pg_temp.decide(pmgr, po2, 'rejected', 'Negotiate back to 60');
  PERFORM pg_temp.check(r->>'state' = 'rejected', 'purchasing manager rejects', r::text);
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_doc_cancel('ZZ99', 22, %s, 'Supplier holds the old price')$q$, po2));
  PERFORM pg_temp.check(r->>'status' = 'cancelled', 'rejected PO cancelled by its creator', r::text);
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_doc_cancel('ZZ99', 22, %s, 'x')$q$, po)),
    'This purchase order has a goods receipt or a down payment invoice and can''t be cancelled.', 'PO with receipts can''t be cancelled');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_doc_cancel('ZZ99', 540000006, %s, 'x')$q$, q1)),
    'This quotation was copied to a purchase order and can''t be cancelled. Cancel the order first.', 'quotation in a live PO can''t be cancelled');

  -- ---------- 11 · Flow, page info, setup ----------
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_doc_flow('ZZ99', 22, %s)$q$, po));
  PERFORM pg_temp.check((SELECT count(*) FROM jsonb_array_elements(r->'docs') x WHERE (x->>'obj_type')::integer IN (1470000113, 540000006, 22, 204, 20, 18)) = 8
                        AND jsonb_array_length(r->'pis') = 1 AND jsonb_array_length(r->'qcs') = 2 AND jsonb_array_length(r->'shipments') = 1
                        AND jsonb_array_length(r->'payments') = 2 AND jsonb_array_length(r->'landed_costs') = 2,
    'flow strip data: request, 2 quotations, PO, 2 deposits, receipt, invoice + PI, QC, shipment, payments, landed costs', left(r::text, 300));
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_doc_info('ZZ99', 22, %s)$q$, po));
  PERFORM pg_temp.check(jsonb_array_length(r->'deposits') = 2 AND jsonb_array_length(r->'shipments') = 1 AND r->>'last_qc' = 'pass'
                        AND NOT (r->>'can_cancel')::boolean AND (r->>'can_copy')::boolean AND r->>'china_office_name' = 'Shenzhen',
    'PO page info: deposits, shipment, last QC, can copy, can''t cancel', left(r::text, 300));
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_view('ZZ99', 18, %s)$q$, ap));
  PERFORM pg_temp.check((r->>'gross')::numeric = 43050 AND (r->>'open_amount')::numeric = 12575 AND jsonb_array_length(r->'draws') = 1,
    'A/P invoice page: gross, open amount, deposit drawn', left(r::text, 300));
  r := pg_temp.call(purch, format($q$SELECT erp.landed_cost_info('ZZ99', %s)$q$, lc));
  PERFORM pg_temp.check(jsonb_array_length(r->'lines') = 2 AND jsonb_array_length(r->'charges') = 3 AND (r->'lines'->0->>'allocated')::numeric = 2674.92,
    'landed cost page info', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(staff, $q$SELECT erp.purchase_setting_set('ZZ99', '{"require_qc_pass":false}')$q$),
    'You have read-only access to Purchasing. Ask the system admin for full access to change the purchasing setup.', 'read-only user can''t change setup');
  r := pg_temp.call(purch, $q$SELECT erp.purchase_list_save('ZZ99', 'china_office', '{"code":"YW","name":"Yiwu","sort":5}')$q$);
  PERFORM pg_temp.check(r->>'code' = 'YW' AND EXISTS (SELECT 1 FROM erp.china_office WHERE company_code = 'ZZ99' AND code = 'YW'), 'China office added', r::text);
  r := pg_temp.call(fin, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"demurrage","name":"Demurrage","split_method":"cbm"}')$q$);
  PERFORM pg_temp.check(r->>'code' = 'DEMURRAGE', 'finance (full) adds a landed cost code', r::text);
  PERFORM pg_temp.expect(pg_temp.call(purch, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"X","name":"X","split_method":"area"}')$q$),
    -- B3 (32_gl_setup.sql) adds the split method 'equal' (decisions C4), so the message lists five methods.
    CASE WHEN to_regclass('erp.gl_determination_group') IS NOT NULL THEN 'Choose how X is split: quantity, weight, volume (CBM), value or equal.'
         ELSE 'Choose how X is split: volume (CBM), quantity, value or weight.' END, 'unknown split method refused');

  -- ---------- Safety ----------
  r := pg_temp.call(purch, $q$WITH x AS (INSERT INTO erp.purchase_pi (company_code, po_doc_entry, card_code, vendor_pi_no, pi_date, status, created_by) VALUES ('ZZ99', 1, 'S0009', 'H', current_date, 'received', '00000000-0000-4000-8000-000000000010') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct insert into purchase_pi', r::text);
  r := pg_temp.call(purch, $q$WITH x AS (UPDATE erp.landed_cost_alloc SET amount = 0 RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct update of landed cost splits', r::text);
  r := pg_temp.call(purch, $q$SELECT erp._lc_eval('ZZ99', '{}', '[]', '[]')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'internal split function not callable', r::text);
  r := pg_temp.call(purch, $q$SELECT to_jsonb(erp.post_document('ZZ99', 20, 1))$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'post_document not callable', r::text);
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.purchase_pi$q$);
  PERFORM pg_temp.check(r::text = '0', 'sales-only user reads no purchasing rows (RLS)', r::text);
  r := pg_temp.call(staff, format($q$SELECT to_jsonb(count(*)) FROM erp.purchase_doc_list WHERE source = 'erp' AND doc_entry >= %s$q$, req));
  PERFORM pg_temp.check((r::text)::integer = 9, 'read-only staff lists the 9 Super ERP purchasing documents', r::text);
  r := pg_temp.call(purch, format($q$SELECT to_jsonb(count(*)) FROM erp.purchase_doc_list WHERE doc_entry >= %s AND china_office = 'SZ' AND doc_no LIKE 'P%%'$q$, req));
  PERFORM pg_temp.check((r::text)::integer = 2, 'purchasing user reads the Super ERP number and China office (doc_workflow policy)', r::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_entry j WHERE j.company_code = 'ZZ99' AND j.trans_type IN (20, 204, 18, 69) AND j.source = 'erp'
                                      AND NOT pg_temp.balanced(j.trans_id)), 'every purchasing journal balances');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.audit_log WHERE action LIKE 'grpo%' AND detail IS NULL)
                        AND (SELECT count(*) FROM erp.audit_log WHERE company_code = 'ZZ99' AND action IN ('purchase_request_create', 'purchase_quotation_create',
                             'purchase_order_create', 'purchase_order_approve', 'ap_down_payment_create', 'qc_inspection_create', 'purchase_shipment_create',
                             'grpo_create', 'ap_invoice_create', 'landed_cost_create')) >= 12, 'every step is in the audit log');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = 'ZZ99' AND source <> 'erp' AND obj_type IN (1470000113, 540000006, 22, 20, 204, 18)
                                      AND doc_entry >= 900000000), 'no SAP or sample document touched (ERP range only for ERP rows)');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a6_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a6_result;
ROLLBACK;
