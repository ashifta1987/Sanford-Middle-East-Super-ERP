-- A13 · Production and Service tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (base.txt incl. 28_production_service.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a13_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a13_result TO authenticated;

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
  INSERT INTO a13_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.oh(p_item text, p_whs text DEFAULT 'WH01') RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = p_item AND whs_code = p_whs), 0)
$$;
CREATE FUNCTION pg_temp.ac(p_item text, p_whs text DEFAULT 'WH01') RETURNS numeric LANGUAGE sql AS $$
  SELECT (SELECT avg_cost FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = p_item AND whs_code = p_whs)
$$;
CREATE FUNCTION pg_temp.po(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, p_sql)
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  prod   uuid := '00000000-0000-4000-8000-000000000024';
  svc    uuid := '00000000-0000-4000-8000-000000000025';
  tech   uuid := '00000000-0000-4000-8000-000000000026';
  r jsonb; r2 jsonb;
  o1 integer; o2 integer; o3 integer; o1no text; o3no text;
  v_bc numeric; v_issue numeric; v_t integer; v_n integer; v_shots bigint; v_e integer;
  c1 integer; c2 integer; c3 integer; c4 integer; k1 integer; v_inv integer; v_po integer;
  hd jsonb := '{"doc_date":"2026-11-10"}';
BEGIN
  -- ---------- Access ----------
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.production_setup('ZZ99')$q$),
    'Your position does not include Production. Ask the system admin if you need it.', 'sales-only user can''t open production');
  r := pg_temp.call(nobody, $q$SELECT erp.production_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'user without a profile refused', r::text);
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.production_setup('AE01')$q$), 'You don''t have access to company AE01.', 'other company refused');
  r := pg_temp.call(stock, $q$SELECT erp.production_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'can_write')::boolean = false, 'inventory user reads production (read-only)', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":2,"due_date":"2026-11-30"}')$q$),
    'You have read-only access to Production. Ask the system admin for full access to create production orders.', 'inventory user can''t create orders');
  r := pg_temp.call(prod, $q$SELECT to_jsonb(count(*)) FROM erp.bom_line$q$);
  PERFORM pg_temp.check(r::text = '5', 'production user reads BOM lines (RLS)', r::text);
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.bom_line$q$);
  PERFORM pg_temp.check(r::text = '0', 'sales user sees no BOM lines (RLS)', r::text);
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.equipment_card$q$);
  PERFORM pg_temp.check(r::text = '2', 'sales user reads equipment cards (Service read)', r::text);
  r := pg_temp.call(stock, $q$SELECT to_jsonb(count(*)) FROM erp.equipment_card$q$);
  PERFORM pg_temp.check(r::text = '0', 'inventory user sees no equipment cards (RLS)', r::text);
  r := pg_temp.call(prod, $q$SELECT to_jsonb(count(*)) FROM erp.prod_order$q$);
  PERFORM pg_temp.check(r::text = '0', 'no production orders before the tests', r::text);

  -- ---------- Settings and resources ----------
  r := pg_temp.call(prod, $q$SELECT erp.production_setting_set('ZZ99', '{"wip_acct":"1300"}')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501' AND r->>'message' = 'Changing the production accounts also needs Financials full access.', 'production user can''t change accounts', r::text);
  PERFORM pg_temp.ok(pg_temp.call(prod, $q$SELECT erp.production_setting_set('ZZ99', '{"life_warn_pct":85}')$q$), 'production user changes the life warning %');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.production_setting_set('ZZ99', '{"life_warn_pct":150}')$q$),
    'The mould life warning must be a percentage between 1 and 100.', 'life warning above 100 % refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-NEW","name":"New mould","kind":"mould","unit_cost":0.2,"acct_code":"5320"}')$q$),
    'Changing the resource account also needs Financials full access.', 'resource account needs Financials');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-NEW","name":"New mould","kind":"mould","unit_cost":0.2}')$q$),
    'Resource MLD-NEW has a cost, so it needs the account its cost is credited to. Ask Finance to set it.', 'resource with a cost needs an account');
  PERFORM pg_temp.ok(pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"mld-new","name":"New mould","kind":"mould","cavities":8,"rated_life_shots":300000}')$q$),
    'mould without a cost saved (code upper-cased)');
  PERFORM pg_temp.check((SELECT unit FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-NEW') = 'shot', 'a mould counts shots');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-NEW","name":"Again","kind":"mould"}')$q$),
    'Resource MLD-NEW already exists. Open it to change it.', 'duplicate resource refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-X","name":"X","kind":"mould","cavities":0}')$q$),
    'Cavities must be a whole number above zero.', 'zero cavities refused');

  -- ---------- Mould maintenance schedule ----------
  PERFORM pg_temp.check((SELECT maint_status FROM erp.mould_schedule WHERE company_code = 'ZZ99' AND res_code = 'MLD-CAP-4') = 'overdue', 'cap mould is overdue (55,000 shots since)');
  PERFORM pg_temp.check((SELECT life_warn FROM erp.mould_schedule WHERE company_code = 'ZZ99' AND res_code = 'MLD-CAP-4'), 'cap mould warns: 91 % of rated life');
  PERFORM pg_temp.check(NOT (SELECT life_warn FROM erp.mould_schedule WHERE company_code = 'ZZ99' AND res_code = 'MLD-KET-2'), 'kettle mould at 82 % does not warn');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.mould_maintenance_record('ZZ99', 'MLD-CAP-4', jsonb_build_object('done_on', current_date + 1))$q$),
    'The maintenance date can''t be in the future.', 'future maintenance refused');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.mould_maintenance_record('ZZ99', 'MLD-CAP-4', jsonb_build_object('done_on', current_date))$q$),
    'You have read-only access to Production. Ask the system admin for full access to record maintenance.', 'read-only user can''t record maintenance');
  PERFORM pg_temp.ok(pg_temp.call(prod, $q$SELECT erp.mould_maintenance_record('ZZ99', 'MLD-CAP-4', jsonb_build_object('done_on', current_date, 'kind', 'preventive', 'note', 'cleaned'))$q$),
    'maintenance recorded');
  PERFORM pg_temp.check((SELECT maint_status = 'ok' AND shots_since = 0 AND next_due_shots = 505000 FROM erp.mould_schedule WHERE company_code = 'ZZ99' AND res_code = 'MLD-CAP-4'),
    'maintenance resets the schedule (next due at 505,000 shots)');

  -- ---------- Bills of materials ----------
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-PRD-100","qty":1,"whs_code":"WH01","lines":[{"comp_code":"SMP-RAW-PP","qty":1}]}')$q$),
    'A bill of materials for SMP-PRD-100 already exists. Open it to change it.', 'second BOM for an item refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-RAW-EL","qty":1,"whs_code":"WH01","lines":[{"comp_code":"SMP-PRD-100","qty":1}]}')$q$),
    'Line 1: the bill of materials of SMP-PRD-100 already uses SMP-RAW-EL, so this would make a loop.', 'BOM loop refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-1010","qty":1,"whs_code":"WH01","lines":[{"comp_code":"SMP-1010","qty":1}]}')$q$),
    'Line 1: SMP-1010 can''t be a component of itself.', 'item as its own component refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-SVC-01","qty":1,"whs_code":"WH01","lines":[{"comp_code":"SMP-1010","qty":1}]}')$q$),
    'SMP-SVC-01 is not a stock item, so it can''t be produced into stock. Use a sales kit, or make it a stock item first.', 'non-stock production parent refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-1010","qty":1,"whs_code":"WH01","lines":[{"comp_code":"SMP-1220","qty":1},{"comp_code":"SMP-1220","qty":2}]}')$q$),
    'Line 2: SMP-1220 is already on line 1.', 'duplicate component refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-1010","qty":1,"whs_code":"WH01","lines":[{"comp_kind":"resource","comp_code":"NOPE","qty":1}]}')$q$),
    'Line 1: resource NOPE does not exist in company ZZ99. Add it under Moulds and resources.', 'unknown resource refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-1010","qty":1,"whs_code":"WH01","lines":[{"comp_code":"SMP-1220","qty":0}]}')$q$),
    'Line 1: enter a quantity above zero.', 'zero component quantity refused');
  PERFORM pg_temp.ok(pg_temp.call(prod, $q$SELECT erp.bom_save('ZZ99', '{"item_code":"SMP-1010","bom_type":"sales","qty":1,"lines":[{"comp_code":"SMP-1220","qty":1},{"comp_code":"SMP-1230","qty":1}]}')$q$),
    'sales kit BOM saved');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-1010","planned_qty":2,"due_date":"2026-11-30"}')$q$),
    'The bill of materials of SMP-1010 is a sales kit BOM. Only production BOMs make production orders.', 'sales kit can''t make a production order');
  r := pg_temp.call(prod, $q$SELECT erp.bom_info('ZZ99', 'SMP-PRD-100')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'lines') = 5 AND (r->>'unit_cost')::numeric > 12, 'BOM info: 5 lines and a unit cost', left(r::text, 200));
  PERFORM pg_temp.ok(pg_temp.call(prod, $q$SELECT erp.bom_delete('ZZ99', 'SMP-1010')$q$), 'BOM deleted');

  -- ---------- Production order: create, shortage on release (with the PO) ----------
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":0,"due_date":"2026-11-30"}')$q$),
    'Enter a planned quantity above zero.', 'zero quantity refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":2}')$q$),
    'Choose the due date.', 'due date required');
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-1020","planned_qty":2,"due_date":"2026-11-30"}')$q$),
    'SMP-1020 has no bill of materials. Create the BOM first.', 'item without a BOM refused');
  r := pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":1000,"due_date":"2026-11-30","comments":"big run"}')$q$);
  o3 := (r->>'order_id')::integer; o3no := r->>'doc_no';
  PERFORM pg_temp.check(o3no = 'PRD-26-00001' AND r->>'state' = 'planned', 'order created as planned with its own number', r::text);
  PERFORM pg_temp.check((SELECT planned_qty FROM erp.prod_order_line WHERE company_code = 'ZZ99' AND order_id = o3 AND comp_code = 'SMP-RAW-PP') = 600,
    'lines copied from the BOM (1.2 kg per 2 → 600 kg for 1,000)');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_release(%L, %s)', 'ZZ99', o3)),
    'Can''t release PRD-26-00001: SMP-RAW-PP is short by 100 in WH01 (needs 600, free 500). No open purchase order brings it yet. (2 more component(s) short.)',
    'release blocked when a component is short');
  -- a Super ERP purchase order for the resin, due 13 Nov 2026
  v_po := nextval('erp.erp_doc_entry_seq');
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, currency, total, source)
  VALUES ('ZZ99', 22, v_po, 99013, 'purchase_order', 'open', DATE '2026-11-01', DATE '2026-11-13', 'S0009', 'AED', 3250, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total, whs_code, line_status)
  VALUES ('ZZ99', 22, v_po, 0, 'SMP-RAW-PP', 500, 500, 6.5, 3250, 'WH01', 'O');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by) VALUES ('ZZ99', 22, v_po, 'PO-T13-001', 'approved', admin);
  r := pg_temp.call(prod, format('SELECT erp.prod_order_checks(%L, %s)', 'ZZ99', o3));
  PERFORM pg_temp.check(r->'messages'->>0 = 'SMP-RAW-PP is short by 100 in WH01 (needs 600, free 500). Purchase order PO-T13-001 brings 500 on 13 Nov 2026.'
                        AND jsonb_array_length(r->'shortages') = 3, 'shortage shows the PO that will arrive', left(r::text, 400));
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_release(%L, %s)', 'ZZ99', o3)),
    'Can''t release PRD-26-00001: SMP-RAW-PP is short by 100 in WH01 (needs 600, free 500). Purchase order PO-T13-001 brings 500 on 13 Nov 2026. (2 more component(s) short.)',
    'release message names the PO');
  PERFORM pg_temp.check((SELECT state FROM erp.prod_order WHERE company_code = 'ZZ99' AND order_id = o3) = 'planned', 'refused order stays planned');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_close(%L, %s)', 'ZZ99', o3)),
    'Production order PRD-26-00001 was never released. Cancel it instead.', 'planned order can''t be closed');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_cancel(%L, %s, NULL)', 'ZZ99', o3)),
    'Add a note saying why the order is cancelled.', 'cancel needs a note');
  PERFORM pg_temp.ok(pg_temp.call(prod, format('SELECT erp.prod_order_cancel(%L, %s, %L)', 'ZZ99', o3, 'too big')), 'planned order cancelled');

  -- ---------- Production order: issue → receipt → close at the right cost ----------
  r := pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":10,"due_date":"2026-11-30"}')$q$);
  o1 := (r->>'order_id')::integer; o1no := r->>'doc_no';
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o1, hd, '[{"line_num":0,"qty":6}]')),
    'Release production order ' || o1no || ' first. Components are issued to released orders only.', 'issue before release refused');
  PERFORM pg_temp.ok(pg_temp.call(prod, format('SELECT erp.prod_order_release(%L, %s)', 'ZZ99', o1)), 'order with enough stock released');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_receipt(%L, %s, %L::jsonb)', 'ZZ99', o1, '{"doc_date":"2026-11-10","qty":2}')),
    'Issue the components first: nothing has been issued to ' || o1no || ' yet.', 'receipt before any issue refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o1, hd, '[{"line_num":0,"qty":501}]')),
    'Only 500 of SMP-RAW-PP in stock in WH01. You can''t issue 501.', 'issue beyond stock refused');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o1, hd, '[{"line_num":3,"qty":1}]')),
    'Line 3 is not a component item of ' || o1no || '.', 'resources are not issued');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o1, hd, '[{"line_num":0,"qty":7}]')),
    'This issue goes above the planned quantity of a component. Add a reason for the extra issue.', 'extra issue without a reason refused');
  v_bc := pg_temp.ac('SMP-1220');
  v_issue := 39 + 90 + round(10 * v_bc, 2);
  r := pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o1, hd,
                                 '[{"line_num":0,"qty":6},{"line_num":1,"qty":10},{"line_num":2,"qty":10}]'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'value')::numeric = v_issue, 'components issued at average cost', r::text || ' expected ' || v_issue);
  v_e := (r->>'doc_entry')::integer; v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.jl(v_t) = '1300 Cr ' || trim_scale(v_issue) || ', 1360 Dr ' || trim_scale(v_issue), 'issue posts Dr WIP / Cr stock', pg_temp.jl(v_t));
  PERFORM pg_temp.check(pg_temp.oh('SMP-RAW-PP') = 494 AND pg_temp.oh('SMP-RAW-EL') = 90, 'components left stock');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 60 AND doc_entry = v_e AND base_obj_type = 202 AND base_doc_entry = o1) = 3,
    'issue is a goods issue based on the order (base 202)');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 60 AND doc_entry = v_e) = 3, 'one warehouse-journal row per issued line');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.inventory_doc_list WHERE company_code = 'ZZ99' AND obj_type = 60 AND doc_entry = v_e AND state = 'approved'),
    'issue shows in the inventory document list');

  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_receipt(%L, %s, %L::jsonb)', 'ZZ99', o1, '{"doc_date":"2026-11-10","qty":11}')),
    'Only 10 left to report on ' || o1no || '. You can''t receive 11.', 'receipt above the planned quantity refused');
  v_shots := (SELECT shots_done FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-KET-2');
  r := pg_temp.call(prod, format('SELECT erp.prod_order_receipt(%L, %s, %L::jsonb)', 'ZZ99', o1, '{"doc_date":"2026-11-10","qty":4}'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'component_share')::numeric = round(v_issue * 0.4, 2) AND (r->>'resource_cost')::numeric = 2.2,
    'first receipt: 40 % of the components + resources 2.20 (2 shots × 0.40 + 0.04 h × 35)', r::text);
  PERFORM pg_temp.check((r->>'unit_cost')::numeric = round((round(v_issue * 0.4, 2) + 2.2) / 4, 6), 'cost per unit = (component share + resources) / qty', r::text);
  PERFORM pg_temp.check(pg_temp.jl((r->>'resource_trans_id')::integer) = '1360 Dr 2.2, 5320 Cr 2.2', 'resources post Dr WIP / Cr absorbed overhead',
    pg_temp.jl((r->>'resource_trans_id')::integer));
  PERFORM pg_temp.check(pg_temp.jl((r->>'trans_id')::integer) = '1300 Dr ' || trim_scale((r->>'value')::numeric) || ', 1360 Cr ' || trim_scale((r->>'value')::numeric),
    'receipt posts Dr stock / Cr WIP', pg_temp.jl((r->>'trans_id')::integer));
  PERFORM pg_temp.check(pg_temp.oh('SMP-PRD-100') = 4, 'finished stock added');
  PERFORM pg_temp.check((SELECT shots_done FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-KET-2') = v_shots + 2, 'mould shot count +2');
  r2 := pg_temp.call(prod, format('SELECT erp.prod_order_receipt(%L, %s, %L::jsonb)', 'ZZ99', o1, '{"doc_date":"2026-11-10","qty":6}'));
  PERFORM pg_temp.check(r2->>'error' IS NULL AND (r2->>'component_share')::numeric = v_issue - round(v_issue * 0.4, 2) AND (r2->>'resource_cost')::numeric = 3.3,
    'last receipt takes the rest of the components', r2::text);
  PERFORM pg_temp.check(pg_temp.oh('SMP-PRD-100') = 10 AND abs(pg_temp.ac('SMP-PRD-100') - (v_issue + 5.5) / 10) < 0.01,
    'finished stock at the right cost: (components + resources) / 10', pg_temp.ac('SMP-PRD-100')::text || ' vs ' || ((v_issue + 5.5) / 10)::text);
  PERFORM pg_temp.check((SELECT shots_done FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-KET-2') = v_shots + 5, 'mould shot count +5 in total');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_receipt(%L, %s, %L::jsonb)', 'ZZ99', o1, '{"doc_date":"2026-11-10","qty":1}')),
    'Only 0 left to report on ' || o1no || '. You can''t receive 1.', 'nothing left to report');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_cancel(%L, %s, %L)', 'ZZ99', o1, 'x')),
    'Components were issued or output was reported on ' || o1no || ', so it can''t be cancelled. Close it instead.', 'order with movements can''t be cancelled');
  r := pg_temp.call(prod, format('SELECT erp.prod_order_close(%L, %s, %L)', 'ZZ99', o1, 'done'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND abs((r->>'variance')::numeric) <= 0.02, 'closed with no variance (rounding only)', r::text);
  PERFORM pg_temp.check((SELECT issued_value + resource_value - received_value - coalesce(variance_value, 0) FROM erp.prod_order WHERE company_code = 'ZZ99' AND order_id = o1) = 0,
    'WIP of the order is zero after closing');
  PERFORM pg_temp.check(coalesce((SELECT sum(j.debit - j.credit) FROM erp.journal_line j JOIN erp.journal_entry e ON e.company_code = j.company_code AND e.trans_id = j.trans_id
                                  WHERE j.company_code = 'ZZ99' AND j.acct_code = '1360'), 0) = 0, 'WIP account balances to zero');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o1, hd, '[{"line_num":0,"qty":1}]')),
    'Production order ' || o1no || ' is closed. Nothing more can be issued to it.', 'closed order takes no more issues');
  r := pg_temp.call(stock, format('SELECT erp.prod_order_info(%L, %s)', 'ZZ99', o1));
  PERFORM pg_temp.check(jsonb_array_length(r->'documents') = 3 AND jsonb_array_length(r->'resource_use') = 4 AND jsonb_array_length(r->'activity') >= 5,
    'order info: 3 stock documents, 4 resource uses, activity', left(r::text, 200));

  -- ---------- Extra issue with a reason, and a variance at close ----------
  r := pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":2,"due_date":"2026-11-30"}')$q$);
  o2 := (r->>'order_id')::integer;
  PERFORM pg_temp.ok(pg_temp.call(prod, format('SELECT erp.prod_order_release(%L, %s)', 'ZZ99', o2)), 'second order released');
  r := pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o2, '{"doc_date":"2026-11-10","reason":"spill"}',
                                 '[{"line_num":0,"qty":1.7},{"line_num":1,"qty":2},{"line_num":2,"qty":2}]'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (SELECT issued_qty FROM erp.prod_order_line WHERE company_code = 'ZZ99' AND order_id = o2 AND line_num = 0) = 1.7,
    'extra issue with a reason accepted', r::text);
  PERFORM pg_temp.check((SELECT comments FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 60 AND doc_entry = (r->>'doc_entry')::integer) LIKE '%Extra issue: spill',
    'extra issue reason kept on the goods issue');
  PERFORM pg_temp.ok(pg_temp.call(prod, format('SELECT erp.prod_order_receipt(%L, %s, %L::jsonb)', 'ZZ99', o2, '{"doc_date":"2026-11-10","qty":1}')), 'half the output reported');
  r := pg_temp.call(prod, format('SELECT erp.prod_order_close(%L, %s)', 'ZZ99', o2));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'variance')::numeric > 0 AND pg_temp.jl((r->>'trans_id')::integer) LIKE '5310 Dr %, 1360 Cr %',
    'closing short posts what is left in WIP to the variance account', r::text || ' ' || coalesce(pg_temp.jl((r->>'trans_id')::integer), ''));

  -- ---------- Settings missing ----------
  UPDATE erp.production_setting SET wip_acct = NULL WHERE company_code = 'ZZ99';
  r := pg_temp.call(prod, $q$SELECT erp.prod_order_create('ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":2,"due_date":"2026-11-30"}')$q$);
  o2 := (r->>'order_id')::integer;
  PERFORM pg_temp.ok(pg_temp.call(prod, format('SELECT erp.prod_order_release(%L, %s)', 'ZZ99', o2)), 'third order released');
  PERFORM pg_temp.expect(pg_temp.call(prod, format('SELECT erp.prod_order_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', o2, hd, '[{"line_num":0,"qty":1}]')),
    'The work-in-progress account is not set for company ZZ99. Ask Finance to set it in Production Setup.', 'issue refused without a WIP account');
  UPDATE erp.production_setting SET wip_acct = '1360' WHERE company_code = 'ZZ99';
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.production_setting_set('ZZ99', '{"wip_acct":"1200"}')$q$),
    'Your position does not include Production. Ask the system admin if you need it.', 'finance alone can''t open production settings');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.bom_delete('ZZ99', 'SMP-PRD-100')$q$),
    'Production order PRD-26-00004 for SMP-PRD-100 is still open. Close or cancel it first.', 'BOM with an open order can''t be deleted');

  -- ---------- Service: warranty ----------
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.service_setup('ZZ99')$q$),
    'Your position does not include Service. Ask the system admin if you need it.', 'inventory user can''t open service');
  r := pg_temp.call(sales, $q$SELECT erp.service_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND NOT (r->>'can_write')::boolean, 'sales user reads service (read-only)', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.service_call_save('ZZ99', '{"card_code":"C0003","subject":"x"}')$q$),
    'You have read-only access to Service. Ask the system admin for full access to log service calls.', 'sales user can''t log calls');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_call_save('ZZ99', '{"card_code":"C0003","item_code":"SMP-1020","subject":"No power"}')$q$),
    'SMP-1020 is serial-managed. Enter the serial number from the unit.', 'serial-managed item needs the serial');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_call_save('ZZ99', '{"card_code":"C0003","item_code":"SMP-1020","serial_no":"KT-SMP-0001"}')$q$),
    'Describe the problem in a few words (subject).', 'subject required');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_call_save('ZZ99', '{"card_code":"S0009","subject":"x"}')$q$),
    'Customer S0009 does not exist in company ZZ99.', 'supplier is not a customer');
  r := pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb)', 'ZZ99',
         jsonb_build_object('card_code', 'C0003', 'item_code', 'SMP-1020', 'serial_no', 'KT-SMP-0001', 'subject', 'Kettle does not heat', 'priority', 'high', 'technician', tech)));
  c1 := (r->>'call_id')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'SC-26-00001' AND r->'warranty'->>'status' = 'out_of_warranty' AND (r->'warranty'->>'flagged')::boolean,
    'call on an out-of-warranty serial is flagged', r::text);
  PERFORM pg_temp.check((SELECT flagged AND warranty_status = 'out_of_warranty' AND warranty_end = DATE '2025-09-15' AND technician_name = 'QA Technician'
                           AND warranty_note LIKE '%Out of warranty: the warranty of SMP-1020 serial KT-SMP-0001 ended on 15 Sep 2025.%'
                           FROM erp.service_call WHERE company_code = 'ZZ99' AND call_id = c1), 'flag, warranty end and message stored on the call');
  PERFORM pg_temp.check((SELECT flagged FROM erp.service_call_list WHERE company_code = 'ZZ99' AND call_id = c1), 'flag shows in the call list');
  r := pg_temp.call(svc, $q$SELECT erp.service_call_save('ZZ99', '{"card_code":"C0011","item_code":"SMP-1030","serial_no":"BL-SMP-0100","subject":"Noisy motor"}')$q$);
  c2 := (r->>'call_id')::integer;
  PERFORM pg_temp.check(r->'warranty'->>'status' = 'in_warranty' AND NOT (r->'warranty'->>'flagged')::boolean AND r->'warranty'->>'basis' = 'equipment_card',
    'in-warranty serial is not flagged', r::text);
  SELECT doc_entry INTO v_inv FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_num = 100076;
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb)', 'ZZ99',
         jsonb_build_object('card_code', 'C0003', 'item_code', 'SMP-1020', 'serial_no', 'KT-NEW-77', 'invoice_entry', v_inv, 'subject', 'Lid broken'))),
    format('A/R invoice %s is not an invoice of customer C0003 for SMP-1020. Choose the invoice that sold this unit.', v_inv), 'invoice of another customer refused');
  r := pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb)', 'ZZ99',
         jsonb_build_object('card_code', 'C0010', 'item_code', 'SMP-1020', 'serial_no', 'KT-NEW-77', 'invoice_entry', v_inv, 'subject', 'Lid broken')));
  c3 := (r->>'call_id')::integer;
  PERFORM pg_temp.check(r->'warranty'->>'status' = 'in_warranty' AND r->'warranty'->>'basis' = 'invoice'
                        AND (r->'warranty'->>'warranty_end')::date = ((SELECT doc_date FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = v_inv) + interval '12 months')::date,
    'warranty from the invoice date + 12 months', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.equipment_card WHERE company_code = 'ZZ99' AND serial_no = 'KT-NEW-77' AND invoice_entry = v_inv AND card_id = (r->>'equipment_card_id')::integer),
    'equipment card created from the call');
  PERFORM pg_temp.check((r->'warranty'->'messages')->>0 LIKE 'Serial number KT-NEW-77 of SMP-1020 is not known%', 'unknown serial is mentioned', r::text);
  -- no warranty period for group 103
  PERFORM pg_temp.ok(pg_temp.call(svc, $q$SELECT erp.equipment_card_save('ZZ99', '{"item_code":"SMP-1150","serial_no":"GS-1","card_code":"C0003","sold_on":"2026-01-05"}')$q$),
    'equipment card without an invoice saved');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.equipment_card_save('ZZ99', '{"item_code":"SMP-1150","serial_no":"GS-1","card_code":"C0003"}')$q$),
    'Serial number GS-1 of SMP-1150 already has an equipment card.', 'one card per serial');
  r := pg_temp.call(svc, $q$SELECT erp.service_warranty('ZZ99', '{"card_code":"C0003","item_code":"SMP-1150","serial_no":"GS-1"}')$q$);
  PERFORM pg_temp.check(r->>'status' = 'no_rule' AND NOT (r->>'flagged')::boolean, 'no warranty period set → no_rule, not flagged', r::text);
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.warranty_rule_save('ZZ99', '{"group_code":101,"months":24}')$q$),
    'A warranty period for this item group is already set. Change that one instead.', 'duplicate warranty rule refused');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.warranty_rule_save('ZZ99', '{"group_code":103,"months":1.5}')$q$),
    'The warranty period must be a whole number of months above zero.', 'fractional months refused');
  PERFORM pg_temp.ok(pg_temp.call(svc, $q$SELECT erp.warranty_rule_save('ZZ99', '{"group_code":103,"months":24}')$q$), 'warranty rule for group 103 added');
  r := pg_temp.call(svc, $q$SELECT erp.service_warranty('ZZ99', '{"card_code":"C0003","item_code":"SMP-1150","serial_no":"GS-1"}')$q$);
  PERFORM pg_temp.check(r->>'status' = 'in_warranty' AND (r->>'warranty_end')::date = DATE '2028-01-05', 'rule applies to a card without a stored end', r::text);

  -- ---------- Service: contract coverage ----------
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_contract_save('ZZ99', '{"card_code":"C0003","starts_on":"2026-01-01","ends_on":"2026-12-31"}')$q$),
    'Add the items or serial numbers the contract covers, or tick "All items".', 'contract needs coverage');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_contract_save('ZZ99', '{"card_code":"C0003","starts_on":"2026-12-01","ends_on":"2026-01-31","all_items":true}')$q$),
    'The end date can''t be before the start date.', 'contract dates checked');
  r := pg_temp.call(svc, $q$SELECT erp.service_contract_save('ZZ99', '{"card_code":"C0003","starts_on":"2026-01-01","ends_on":"2026-12-31","response_hours":24,"covers_parts":true,"covers_labour":true,"lines":[{"item_code":"SMP-1020"}]}')$q$);
  k1 := (r->>'contract_id')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'SCT-26-00001' AND r->>'state' = 'draft', 'contract saved as draft', r::text);
  r := pg_temp.call(svc, $q$SELECT erp.service_warranty('ZZ99', '{"card_code":"C0003","item_code":"SMP-1020","serial_no":"KT-SMP-0001"}')$q$);
  PERFORM pg_temp.check(r->>'status' = 'out_of_warranty', 'draft contract does not cover', r::text);
  PERFORM pg_temp.ok(pg_temp.call(svc, format('SELECT erp.service_contract_status(%L, %s, %L)', 'ZZ99', k1, 'activate')), 'contract activated');
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_contract_save(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('contract_id', k1, 'card_code', 'C0003', 'all_items', true, 'starts_on', '2026-01-01', 'ends_on', '2026-12-31'))),
    'Service contract SCT-26-00001 is active. Only draft contracts can be changed.', 'active contract can''t be edited');
  r := pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('call_id', c1, 'card_code', 'C0003', 'item_code', 'SMP-1020',
         'serial_no', 'KT-SMP-0001', 'subject', 'Kettle does not heat', 'priority', 'high', 'technician', tech)));
  PERFORM pg_temp.check(r->'warranty'->>'status' = 'contract' AND NOT (r->'warranty'->>'flagged')::boolean
                        AND (SELECT contract_id = k1 AND due_by = opened_at + interval '24 hours' AND NOT flagged FROM erp.service_call WHERE company_code = 'ZZ99' AND call_id = c1),
    'out of warranty but under contract: not flagged, response due in 24 h', r::text);
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_contract_status(%L, %s, %L)', 'ZZ99', k1, 'end')),
    'Add a note saying why.', 'ending a contract needs a note');

  -- ---------- Service: status flow ----------
  PERFORM pg_temp.expect(pg_temp.call(tech, format('SELECT erp.service_call_status(%L, %s, %L)', 'ZZ99', c2, 'resolved')),
    'Enter the solution before marking the call resolved.', 'resolved needs the solution');
  PERFORM pg_temp.ok(pg_temp.call(tech, format('SELECT erp.service_call_status(%L, %s, %L)', 'ZZ99', c2, 'in_progress')), 'technician starts the call');
  PERFORM pg_temp.ok(pg_temp.call(tech, format('SELECT erp.service_call_status(%L, %s, %L, %L)', 'ZZ99', c2, 'resolved', 'Replaced motor brush')), 'technician resolves with the solution');
  PERFORM pg_temp.ok(pg_temp.call(svc, format('SELECT erp.service_call_status(%L, %s, %L)', 'ZZ99', c2, 'closed')), 'service desk closes the call');
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_status(%L, %s, %L)', 'ZZ99', c2, 'in_progress')),
    'Service call SC-26-00002 is closed, so it can''t be moved to in progress.', 'closed call can''t reopen');
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('call_id', c2, 'card_code', 'C0011', 'subject', 'x'))),
    'Service call SC-26-00002 is closed. It can''t be changed.', 'closed call can''t be edited');
  PERFORM pg_temp.check((SELECT solution = 'Replaced motor brush' AND closed_at IS NOT NULL FROM erp.service_call WHERE company_code = 'ZZ99' AND call_id = c2), 'solution and close time kept');
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('card_code', 'C0003', 'subject', 'x', 'technician', stock))),
    'The technician must be an active user with Service access in company ZZ99.', 'technician must have Service access');

  -- ---------- Service: spare parts through A7 goods issue ----------
  PERFORM pg_temp.expect(pg_temp.call(tech, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', c3,
                                                   '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":2}]')),
    'Your position does not include Inventory. Ask the system admin if you need it.', 'technician without Inventory can''t issue parts');
  v_n := pg_temp.oh('SMP-1220')::integer;
  r := pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', c3,
                                '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":2}]'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->>'state' = 'approved' AND pg_temp.oh('SMP-1220') = v_n - 2, 'spare parts issued through a goods issue', r::text);
  PERFORM pg_temp.check(pg_temp.jl((r->>'trans_id')::integer) LIKE '1300 Cr %, 5330 Dr %' OR pg_temp.jl((r->>'trans_id')::integer) LIKE '5330 Dr %, 1300 Cr %',
    'parts post to the spare-parts reason account', coalesce(pg_temp.jl((r->>'trans_id')::integer), ''));
  PERFORM pg_temp.check((SELECT customer_ref FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 60 AND doc_entry = (r->>'doc_entry')::integer) = 'SC-26-00003'
                        AND EXISTS (SELECT 1 FROM erp.service_call_part WHERE company_code = 'ZZ99' AND call_id = c3 AND doc_entry = (r->>'doc_entry')::integer),
    'goods issue references and is linked to the call');
  PERFORM pg_temp.check((SELECT status FROM erp.service_call WHERE company_code = 'ZZ99' AND call_id = c3) = 'in_progress', 'issuing parts starts the call');
  r := pg_temp.call(sales, format('SELECT erp.service_call_info(%L, %s)', 'ZZ99', c3));
  PERFORM pg_temp.check(jsonb_array_length(r->'parts') = 1 AND jsonb_array_length(r->'activity') >= 2, 'call info shows parts and activity', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', c2,
                                                  '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]')),
    'Service call SC-26-00002 is closed. Parts can''t be issued to it.', 'no parts on a closed call');
  UPDATE erp.service_setting SET parts_reason_code = NULL WHERE company_code = 'ZZ99';
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', c3,
                                                  '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]')),
    'No spare-parts reason is set for company ZZ99. Ask the service manager to set it in Service Setup.', 'parts refused without a reason set');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_setting_set('ZZ99', '{"parts_reason_code":"FOUND"}')$q$),
    'Reason Found stock is for goods receipts only. Choose a goods issue reason.', 'receipt reason refused for parts');
  PERFORM pg_temp.ok(pg_temp.call(svc, $q$SELECT erp.service_setting_set('ZZ99', '{"parts_reason_code":"SERVICE"}')$q$), 'spare-parts reason set again');
  r := pg_temp.call(svc, format('SELECT erp.equipment_card_info(%L, %s)', 'ZZ99', (SELECT card_id FROM erp.equipment_card WHERE company_code = 'ZZ99' AND serial_no = 'KT-SMP-0001')));
  PERFORM pg_temp.check(jsonb_array_length(r->'calls') = 1 AND r->'warranty'->>'status' = 'contract', 'equipment card shows its calls and coverage', left(r::text, 300));

  -- ---------- Numbering, audit, SAP rows ----------
  PERFORM pg_temp.check((SELECT count(*) FROM erp._adm_doc_types() WHERE obj_type IN (202, 191, 190)) = 3, 'numbering lists production order, service call and contract');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE company_code = 'ZZ99' AND action IN ('prod_order_create', 'prod_order_release', 'prod_order_issue',
                           'prod_order_receipt', 'prod_order_close', 'prod_order_cancel', 'bom_create', 'bom_delete', 'prod_resource_create', 'mould_maintenance_record',
                           'production_setting_set', 'service_call_create', 'service_call_update', 'service_call_resolved', 'service_call_closed', 'service_call_parts',
                           'service_contract_create', 'service_contract_activate', 'equipment_card_create', 'warranty_rule_create', 'service_setting_set')) >= 30,
    'every step is in the audit log');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = 'ZZ99' AND source <> 'erp' AND doc_entry >= 900000000), 'no SAP or sample document touched');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document_posting p JOIN erp.journal_line j ON j.company_code = p.company_code AND j.trans_id = p.trans_id
                                     WHERE p.company_code = 'ZZ99' GROUP BY p.trans_id HAVING sum(j.debit) <> sum(j.credit)), 'every journal balances');
  r := pg_temp.call(prod, $q$SELECT to_jsonb(has_table_privilege('erp.prod_order', 'INSERT'))$q$);
  PERFORM pg_temp.check(r::text = 'false', 'no direct write grant on production tables', r::text);
  r := pg_temp.call(svc, $q$SELECT to_jsonb(has_table_privilege('erp.service_call', 'UPDATE'))$q$);
  PERFORM pg_temp.check(r::text = 'false', 'no direct write grant on service tables', r::text);
  r := pg_temp.call(prod, $q$SELECT to_jsonb(has_function_privilege('erp._prd_stock_doc(varchar, integer, date, text, text, integer, jsonb, uuid)', 'EXECUTE'))$q$);
  PERFORM pg_temp.check(r::text = 'false', 'internal helpers are not callable', r::text);
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a13_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a13_result;
ROLLBACK;
