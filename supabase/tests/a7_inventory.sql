-- A7 · Inventory tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (base.txt incl. 22_inventory.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a7_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a7_result TO authenticated;

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
  INSERT INTO a7_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
-- goods receipt (59) / issue (60)
CREATE FUNCTION pg_temp.gd(p_user uuid, p_obj integer, p_header jsonb, p_lines jsonb, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.inventory_doc_create(%L, %s, %L::jsonb, %L::jsonb, %L)', 'ZZ99', p_obj, p_header, p_lines, p_reason))
$$;
CREATE FUNCTION pg_temp.tr(p_user uuid, p_header jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.transfer_create(%L, %L::jsonb, %L::jsonb)', 'ZZ99', p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.oh(p_item text, p_whs text) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = p_item AND whs_code = p_whs), 0)
$$;
CREATE FUNCTION pg_temp.tot(p_item text) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce(sum(on_hand), 0) FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = p_item
$$;
CREATE FUNCTION pg_temp.lot(p_item text, p_no text, p_whs text) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT b.qty FROM erp.stock_lot l JOIN erp.stock_lot_balance b ON b.lot_id = l.lot_id
                    WHERE l.company_code = 'ZZ99' AND l.item_code = p_item AND l.number = p_no AND b.whs_code = p_whs), 0)
$$;
CREATE FUNCTION pg_temp.binq(p_bin text, p_item text) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT bs.qty FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                    WHERE b.company_code = 'ZZ99' AND b.bin_code = p_bin AND bs.item_code = p_item), 0)
$$;
-- every line of a count at its system quantity, with overrides {item_code: qty}
CREATE FUNCTION pg_temp.fill(p_count integer, p_over jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('line_num', line_num, 'counted_qty', coalesce((p_over->>item_code)::numeric, system_qty)) ORDER BY line_num), '[]'::jsonb)
    FROM erp.inv_count_line WHERE company_code = 'ZZ99' AND count_id = p_count
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  smgr   uuid := '00000000-0000-4000-8000-000000000014';
  sread  uuid := '00000000-0000-4000-8000-000000000015';
  r jsonb; r2 jsonb;
  v_oh numeric; v_oh2 numeric; v_tot numeric; v_n integer; v_e integer; v_e2 integer; v_t integer;
  trq integer; c1 integer; c2 integer; c3 integer; c4 integer; v_item text; v_sys numeric;
  h1 jsonb := '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"FOUND","comments":"A7 test"}';
  hi jsonb := '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"DAMAGE"}';
BEGIN
  -- ---------- Access ----------
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.inventory_setup('ZZ99')$q$),
    'Your position does not include Inventory. Ask the system admin if you need it.', 'sales-only user can''t open inventory');
  r := pg_temp.call(nobody, $q$SELECT erp.inventory_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'user without a profile refused', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.inventory_setup('AE01')$q$), 'You don''t have access to company AE01.', 'other company refused');
  r := pg_temp.call(stock, $q$SELECT erp.inventory_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'reasons') >= 4 AND  -- A13 adds the SERVICE reason (28)
                        jsonb_array_length(r->'bins') = 3 AND (r->'my_limits'->>'59')::numeric = 10000
                        AND (r->'count_rules'->>'pct')::numeric = 1 AND (r->'count_rules'->>'value')::numeric = 5000 AND (r->>'can_write')::boolean
                        AND (r->>'blind_count')::boolean
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'warehouses') w WHERE w->>'code' = 'WH02' AND (w->>'bins')::boolean)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'accounts') a WHERE a->>'code' = '5300')
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'accounts') a WHERE a->>'code' = '1200'),
    'setup: 4 sample reasons, 3 bins in WH02, limits and count rules, accounts without control accounts', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.gd(sread, 59, h1, '[{"item_code":"SMP-1010","qty":1}]'),
    'You have read-only access to Inventory. Ask the system admin for full access to post goods receipts.', 'read-only user can''t post a goods receipt');
  r := pg_temp.call(stock, $q$WITH x AS (INSERT INTO erp.bin_stock (bin_id, item_code, company_code, qty) SELECT bin_id, 'SMP-1010', 'ZZ99', 5 FROM erp.bin_location LIMIT 1 RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct insert into bin_stock refused', r::text);
  r := pg_temp.call(stock, $q$WITH x AS (UPDATE erp.stock_lot SET number = 'X' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct update of stock_lot refused', r::text);
  r := pg_temp.call(stock, $q$SELECT to_jsonb(count(*)) FROM erp.inv_count_line$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'count lines are not readable directly (blind count)', r::text);

  -- ---------- Goods receipt ----------
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":1}]'),
    'Choose the reason for this goods receipt.', 'goods receipt without a reason refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, hi, '[{"item_code":"SMP-1010","qty":1}]'),
    'Reason Damaged, written off is for goods issues only.', 'issue-only reason refused on a receipt');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1 || '{"acct_code":"1200"}', '[{"item_code":"SMP-1010","qty":1}]'),
    'Account 1200 is a control account (customers or suppliers). Choose another account.', 'control account refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-SVC-01","qty":1}]'),
    'Line 1: SMP-SVC-01 is not a stock item, so it has no stock to move.', 'non-stock item refused');
  v_oh := pg_temp.oh('SMP-1010', 'WH01');
  r := pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1010","qty":10,"price":95}]');
  v_e := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'GRC-26-00001' AND r->>'state' = 'approved' AND r->>'status' = 'closed' AND pg_temp.oh('SMP-1010', 'WH01') = v_oh + 10,
    'goods receipt posts at once within the limit: stock +10', r::text);
  PERFORM pg_temp.check(pg_temp.jl((r->>'trans_id')::integer) = '1300 Dr 950, 5300 Cr 950', 'receipt journal: Dr stock 1300 / Cr reason account 5300',
    pg_temp.jl((r->>'trans_id')::integer));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'goods_receipt_create' AND object_ref = v_e::text), 'receipt in the audit log');

  -- ---------- Serial numbers ----------
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1020","qty":2,"lots":[{"number":"SN-A1"}]}]'),
    'Line 1: SMP-1020 is serial-managed. Enter 2 serial number(s) (1 entered).', 'receipt with a missing serial number refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1020","qty":2,"lots":[{"number":"SN-A1"},{"number":"SN-A1"}]}]'),
    'Line 1: serial number SN-A1 is entered twice.', 'same serial twice refused');
  r := pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1020","qty":2,"price":42,"lots":[{"number":"SN-A1"},{"number":"SN-A2"}]}]');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND pg_temp.lot('SMP-1020', 'SN-A1', 'WH01') = 1 AND pg_temp.lot('SMP-1020', 'SN-A2', 'WH01') = 1,
    'receipt with serial numbers: both in stock in WH01', r::text);
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1020","qty":1,"lots":[{"number":"SN-A1"}]}]'),
    'Line 1: serial number SN-A1 of SMP-1020 is already in stock.', 'serial already in stock refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1020","qty":1}]'),
    'Line 1: SMP-1020 is serial-managed. Enter 1 serial number(s) (0 entered).', 'issue with a missing serial number refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1020","qty":1,"lots":[{"number":"SN-ZZ"}]}]'),
    'Line 1: serial number SN-ZZ of SMP-1020 is not in stock in WH01.', 'issue of a serial not in stock refused');
  r := pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1020","qty":1,"lots":[{"number":"SN-A1"}]}]');
  PERFORM pg_temp.check(r->>'doc_no' = 'GI-26-00001' AND pg_temp.lot('SMP-1020', 'SN-A1', 'WH01') = 0 AND pg_temp.jl((r->>'trans_id')::integer) = '1300 Cr 42, 5300 Dr 42',
    'issue with its serial: serial out, Dr 5300 / Cr 1300 at average cost', r::text || ' ' || coalesce(pg_temp.jl((r->>'trans_id')::integer), ''));

  -- ---------- Issue beyond stock ----------
  v_oh := pg_temp.oh('SMP-1050', 'WH01');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi, jsonb_build_array(jsonb_build_object('item_code', 'SMP-1050', 'qty', v_oh + 1))),
    format('Line 1: only %s of SMP-1050 in stock in WH01. You can''t issue %s.', trim_scale(v_oh), trim_scale(v_oh + 1)), 'issue beyond stock refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi, jsonb_build_array(jsonb_build_object('item_code', 'SMP-1050', 'qty', v_oh - 5), jsonb_build_object('item_code', 'SMP-1050', 'qty', 6))),
    format('Line 2: only 5 of SMP-1050 in stock in WH01. You can''t issue 6.'), 'two lines together beyond stock refused');
  PERFORM pg_temp.check(pg_temp.oh('SMP-1050', 'WH01') = v_oh, 'refused issues moved nothing');

  -- ---------- Batches ----------
  r := pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1210","qty":100,"price":7,"lots":[{"number":"B-01","qty":60,"expires_on":"2028-01-31"},{"number":"B-02","qty":40}]}]');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND pg_temp.lot('SMP-1210', 'B-01', 'WH01') = 60 AND pg_temp.lot('SMP-1210', 'B-02', 'WH01') = 40
                        AND (SELECT expires_on FROM erp.stock_lot WHERE company_code = 'ZZ99' AND number = 'B-01') = '2028-01-31', 'receipt with two batches', r::text);
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1210","qty":10,"lots":[{"number":"B-03","qty":6}]}]'),
    'Line 1: SMP-1210 is batch-managed. The batches add up to 6, not 10.', 'batches not adding up refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1210","qty":70,"lots":[{"number":"B-01","qty":70}]}]'),
    'Line 1: batch B-01 of SMP-1210 has only 60 in WH01.', 'issue beyond a batch refused');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1010","qty":1,"lots":[{"number":"X"}]}]'),
    'Line 1: SMP-1010 is not managed by batches or serial numbers. Remove the numbers.', 'numbers on a plain item refused');

  -- ---------- Bins ----------
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1 || '{"whs_code":"WH02"}', '[{"item_code":"SMP-1010","qty":20}]'),
    'Line 1: WH02 uses bins. Choose the bin to put SMP-1010 away in.', 'put-away needs a bin in a bins warehouse');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1010","qty":20,"bin_code":"WH02-A-01-L1"}]'),
    'Line 1: warehouse WH01 does not use bins. Clear the bin.', 'bin refused in a warehouse without bins');
  r := pg_temp.gd(stock, 59, h1 || '{"whs_code":"WH02"}', '[{"item_code":"SMP-1010","qty":20,"price":95,"bin_code":"WH02-A-01-L1"}]');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND pg_temp.binq('WH02-A-01-L1', 'SMP-1010') = 20, 'put-away into bin WH02-A-01-L1', r::text);
  PERFORM pg_temp.expect(pg_temp.gd(stock, 60, hi || '{"whs_code":"WH02"}', '[{"item_code":"SMP-1010","qty":25,"bin_code":"WH02-A-01-L1"}]'),
    'Line 1: bin WH02-A-01-L1 holds only 20 of SMP-1010.', 'pick beyond the bin refused');
  r := pg_temp.gd(stock, 60, hi || '{"whs_code":"WH02"}', '[{"item_code":"SMP-1010","qty":5,"bin_code":"WH02-A-01-L1"}]');
  PERFORM pg_temp.check(r->>'state' = 'approved' AND pg_temp.binq('WH02-A-01-L1', 'SMP-1010') = 15, 'pick 5 from the bin', r::text);

  -- ---------- Approval above the limit ----------
  v_oh := pg_temp.oh('SMP-1010', 'WH01');
  PERFORM pg_temp.expect(pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1010","qty":120,"price":100}]'),
    'This goods receipt needs approval (value above your limit). Add a reason for the approver.', 'above the limit needs a reason');
  r := pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1010","qty":120,"price":100}]', 'Container short-shipped last month, found in the yard');
  v_e := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND r->>'status' = 'draft' AND pg_temp.oh('SMP-1010', 'WH01') = v_oh
                        AND NOT EXISTS (SELECT 1 FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 59 AND doc_entry = v_e),
    'above 10,000 AED: waits for approval, no stock moved', r::text);
  r := pg_temp.call(smgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'goods_receipt' AND (w->>'doc_entry')::integer = v_e
                                   AND w->>'card_code' = 'WH01' AND (w->>'total')::numeric = 12000), 'stock manager sees it in the Approvals inbox', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(stock, format('SELECT erp.inventory_doc_decide(%L, 59, %s, %L)', 'ZZ99', v_e, 'approved')),
    'You can''t approve your own goods receipt.', 'requester can''t approve');
  PERFORM pg_temp.expect(pg_temp.call(sread, format('SELECT erp.inventory_doc_decide(%L, 59, %s, %L)', 'ZZ99', v_e, 'approved')),
    'This goods receipt is waiting for approval from QA · stock manager. Your position can''t decide it.', 'other position can''t approve');
  PERFORM pg_temp.expect(pg_temp.call(smgr, format('SELECT erp.inventory_doc_decide(%L, 59, %s, %L)', 'ZZ99', v_e, 'rejected')),
    'Add a note saying why you are rejecting this goods receipt.', 'reject needs a note');
  r := pg_temp.call(smgr, format('SELECT erp.inventory_doc_decide(%L, 59, %s, %L)', 'ZZ99', v_e, 'approved'));
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'status' = 'closed' AND pg_temp.oh('SMP-1010', 'WH01') = v_oh + 120
                        AND pg_temp.jl((r->>'trans_id')::integer) = '1300 Dr 12000, 5300 Cr 12000', 'approval posts it: stock +120 and the journal', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, format('SELECT erp.inventory_doc_cancel(%L, 59, %s, %L)', 'ZZ99', v_e, 'oops')),
    'This goods receipt is posted, so it can''t be cancelled. Enter a goods issue to reverse it.', 'posted receipt can''t be cancelled');
  r := pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1010","qty":200}]', 'Water damage');
  v_e2 := (r->>'doc_entry')::integer;
  r := pg_temp.call(smgr, format('SELECT erp.inventory_doc_decide(%L, 60, %s, %L, %L)', 'ZZ99', v_e2, 'rejected', 'Get photos first'));
  PERFORM pg_temp.check(r->>'state' = 'rejected', 'stock manager rejects an issue with a note', r::text);
  r := pg_temp.call(stock, format('SELECT erp.inventory_doc_cancel(%L, 60, %s, %L)', 'ZZ99', v_e2, 'Will re-enter with photos'));
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 60 AND doc_entry = v_e2) = 'cancelled'
                        AND NOT EXISTS (SELECT 1 FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 60 AND doc_entry = v_e2),
    'requester cancels the rejected issue; nothing moved', r::text);
  r := pg_temp.gd(admin, 59, h1, '[{"item_code":"SMP-1010","qty":120,"price":100}]');
  PERFORM pg_temp.check(r->>'state' = 'approved', 'a position without a limit rule posts at once', r::text);

  -- ---------- Transfer request → transfer ----------
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.transfer_request_create('ZZ99', '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"WH01"}', '[{"item_code":"SMP-1050","qty":30}]')$q$),
    'Line 1: the from and to warehouse are both WH01. Choose another warehouse.', 'request to the same warehouse refused');
  r := pg_temp.call(stock, $q$SELECT erp.transfer_request_create('ZZ99', '{"doc_date":"2026-11-10","due_date":"2026-11-12","from_whs":"WH01","to_whs":"WH02"}', '[{"item_code":"SMP-1050","qty":30}]')$q$);
  trq := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'TRQ-26-00001' AND r->>'status' = 'open'
                        AND (SELECT whs_code || '<' || from_whs FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 1250000001 AND doc_entry = trq) = 'WH02<WH01',
    'transfer request opens (line: to WH02 from WH01, as ATP reads it)', r::text);
  v_tot := pg_temp.tot('SMP-1050'); v_oh := pg_temp.oh('SMP-1050', 'WH01'); v_oh2 := pg_temp.oh('SMP-1050', 'WH02');
  PERFORM pg_temp.expect(pg_temp.tr(stock, '{"doc_date":"2026-11-10"}', jsonb_build_array(jsonb_build_object('base_doc_entry', trq, 'base_line', 0, 'qty', 30))),
    'Line 1: WH02 uses bins. Choose the bin to put SMP-1050 away in.', 'transfer into a bins warehouse needs a bin');
  r := pg_temp.tr(stock, '{"doc_date":"2026-11-10"}', jsonb_build_array(jsonb_build_object('base_doc_entry', trq, 'base_line', 0, 'qty', 30, 'to_bin', 'WH02-A-01-L2')));
  v_e := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'TR-26-00001' AND pg_temp.tot('SMP-1050') = v_tot AND pg_temp.oh('SMP-1050', 'WH01') = v_oh - 30
                        AND pg_temp.oh('SMP-1050', 'WH02') = v_oh2 + 30 AND pg_temp.binq('WH02-A-01-L2', 'SMP-1050') = 30,
    'transfer keeps the total quantity: WH01 −30, WH02 +30 into the bin', r::text);
  PERFORM pg_temp.check(r->>'trans_id' IS NULL AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 1250000001 AND doc_entry = trq) = 'closed'
                        AND (SELECT count(*) FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 67 AND doc_entry = v_e) = 2,
    'same stock account: no journal; request closed; two warehouse-journal rows', r::text);
  PERFORM pg_temp.expect(pg_temp.tr(stock, '{"doc_date":"2026-11-10"}', jsonb_build_array(jsonb_build_object('base_doc_entry', trq, 'base_line', 0, 'qty', 1, 'to_bin', 'WH02-A-01-L2'))),
    'Line 1: transfer request TRQ-26-00001 is no longer open.', 'a used-up request can''t be copied again');
  PERFORM pg_temp.expect(pg_temp.tr(stock, '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"TRN"}', '[{"item_code":"SMP-1040","qty":5}]'),
    'Line 1: only 0 of SMP-1040 in stock in WH01. You can''t transfer 5.', 'transfer beyond stock refused');
  PERFORM pg_temp.expect(pg_temp.tr(stock, '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"TRN"}', '[{"item_code":"SMP-1020","qty":1}]'),
    'Line 1: SMP-1020 is serial-managed. Enter 1 serial number(s) (0 entered).', 'transfer of a serial item needs the serial');
  r := pg_temp.tr(stock, '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"TRN"}', '[{"item_code":"SMP-1020","qty":1,"lots":[{"number":"SN-A2"}]}]');
  PERFORM pg_temp.check(r->>'doc_no' IS NOT NULL AND pg_temp.lot('SMP-1020', 'SN-A2', 'WH01') = 0 AND pg_temp.lot('SMP-1020', 'SN-A2', 'TRN') = 1,
    'serial number moves with the transfer', r::text);
  r := pg_temp.tr(stock, '{"doc_date":"2026-11-10","from_whs":"WH02","to_whs":"WH02"}', '[{"item_code":"SMP-1010","qty":5,"from_bin":"WH02-A-01-L1","to_bin":"WH02-B-01-L1"}]');
  PERFORM pg_temp.check(r->>'doc_no' IS NOT NULL AND pg_temp.binq('WH02-A-01-L1', 'SMP-1010') = 10 AND pg_temp.binq('WH02-B-01-L1', 'SMP-1010') = 5,
    'bin-to-bin move inside WH02', r::text);
  v_n := (SELECT erp._inv_unbinned('ZZ99', 'SMP-1050', 'WH02'))::integer;
  r := pg_temp.tr(stock, '{"doc_date":"2026-11-10","from_whs":"WH02","to_whs":"WH02"}', '[{"item_code":"SMP-1050","qty":100,"to_bin":"WH02-A-01-L1"}]');
  PERFORM pg_temp.check(r->>'doc_no' IS NOT NULL AND erp._inv_unbinned('ZZ99', 'SMP-1050', 'WH02') = v_n - 100, 'put-away of stock outside bins into a bin', r::text);

  -- Warehouses on different stock accounts post the transfer through A3.
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_inv_set('ZZ99', 'TRN', '{"stock_acct":"1310"}')$q$),
    'Only Financials with full access can change a warehouse''s stock account.', 'inventory user can''t set a stock account');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.warehouse_inv_set('ZZ99', 'TRN', '{"stock_acct":"1310"}')$q$),
    'Your position does not include Inventory. Ask the system admin if you need it.', 'finance-only user is refused (no Inventory)');
  r := pg_temp.call(admin, $q$SELECT erp.warehouse_inv_set('ZZ99', 'TRN', '{"stock_acct":"1310"}')$q$);
  PERFORM pg_temp.check(r->>'stock_acct' = '1310', 'admin (Inventory + Financials full) sets TRN on 1310', r::text);
  r := pg_temp.tr(stock, '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"TRN"}', '[{"item_code":"SMP-1010","qty":10}]');
  PERFORM pg_temp.check(pg_temp.jl((r->>'trans_id')::integer) = format('1310 Dr %s, 1300 Cr %s', trim_scale((r->>'value')::numeric), trim_scale((r->>'value')::numeric))
                        AND (r->>'value')::numeric > 0, 'transfer between stock accounts: Dr 1310 / Cr 1300 at average cost',
    r::text || ' ' || coalesce(pg_temp.jl((r->>'trans_id')::integer), ''));
  PERFORM pg_temp.call(admin, $q$SELECT erp.warehouse_inv_set('ZZ99', 'TRN', '{"stock_acct":""}')$q$);

  -- ---------- Counting ----------
  r := pg_temp.call(stock, $q$SELECT erp.inv_count_create('ZZ99', '{"whs_code":"QC","count_date":"2026-11-10"}')$q$);
  c1 := (r->>'count_id')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'IC-26-00001' AND (r->>'lines')::integer > 0, 'count started for QC', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.inv_count_create('ZZ99', '{"whs_code":"QC","count_date":"2026-11-10"}')$q$),
    'Count IC-26-00001 is still open for warehouse QC. Post or cancel it first.', 'one open count per warehouse');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_info(%L, %s)', 'ZZ99', c1));
  PERFORM pg_temp.check((r->>'blind')::boolean AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') l WHERE l->>'system_qty' IS NOT NULL) AND r->'report' = 'null'::jsonb,
    'blind count: the sheet hides the system quantity', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(sread, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c1, '[{"line_num":0,"counted_qty":1}]')),
    'You have read-only access to Inventory. Ask the system admin for full access to count stock.', 'read-only user can''t count');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s)', 'ZZ99', c1));
  PERFORM pg_temp.check(r->>'message' LIKE '% line(s) are not counted yet. Count them, or enter 0 when there is none.', 'submit with uncounted lines refused', r::text);
  r := pg_temp.call(stock, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c1, pg_temp.fill(c1, '{"SMP-1010":850}')));
  PERFORM pg_temp.check((r->>'n_counted')::integer = (r->>'n_lines')::integer, 'every line counted (SMP-1010: 850 of 861)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s)', 'ZZ99', c1)),
    'This count needs approval (variance above the limit). Add a reason for the approver.', 'variance over 1 % needs a reason');
  v_oh := pg_temp.oh('SMP-1010', 'QC');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s, %L)', 'ZZ99', c1, 'Two cartons crushed in the QC cage'));
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND pg_temp.oh('SMP-1010', 'QC') = v_oh AND jsonb_array_length(r->'checks') = 1
                        AND r->'checks'->0->>'rule_code' = 'count_variance_pct'
                        AND r->'checks'->0->>'message' LIKE '%SMP-1010 counted 850, expected 861 (-1.28 %), above the 1 % variance limit. QA · stock manager approves it.',
    'count with variance over 1 % waits for approval; no stock moved', r::text);
  r := pg_temp.call(sread, format('SELECT erp.inv_count_info(%L, %s)', 'ZZ99', c1));
  PERFORM pg_temp.check(NOT (r->>'blind')::boolean AND (r->'report'->'totals'->>'loss')::numeric = 1045, 'after submit the variance report shows (loss 1,045.00)', left(r->>'report', 300));
  PERFORM pg_temp.expect(pg_temp.call(stock, format('SELECT erp.inv_count_decide(%L, %s, %L)', 'ZZ99', c1, 'approved')),
    'You can''t approve your own count.', 'submitter can''t approve the count');
  r := pg_temp.call(smgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'inventory_count' AND (w->>'doc_entry')::integer = c1),
    'count waits in the stock manager''s inbox', left(r::text, 200));
  r := pg_temp.call(smgr, format('SELECT erp.inv_count_decide(%L, %s, %L)', 'ZZ99', c1, 'approved'));
  PERFORM pg_temp.check(r->>'state' = 'posted' AND pg_temp.oh('SMP-1010', 'QC') = 850 AND pg_temp.jl((r->>'trans_id')::integer) = '5300 Dr 1045, 1300 Cr 1045',
    'approval posts the count: QC stock 850, Dr count variance / Cr stock', r::text || ' ' || coalesce(pg_temp.jl((r->>'trans_id')::integer), ''));
  PERFORM pg_temp.check((SELECT qty_out FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 1470000065 AND doc_entry = c1) = 11,
    'the count adjustment is in the warehouse journal (obj 1470000065)');

  -- Within the rule: posts at once.
  SELECT l.item_code, l.on_hand INTO v_item, v_sys FROM erp.stock_balance l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
   WHERE l.company_code = 'ZZ99' AND l.whs_code = 'WH01' AND i.group_code = 102 AND i.active AND l.on_hand >= 200 ORDER BY l.item_code LIMIT 1;
  r := pg_temp.call(stock, $q$SELECT erp.inv_count_create('ZZ99', '{"whs_code":"WH01","item_group":102,"count_date":"2026-11-10"}')$q$);
  c2 := (r->>'count_id')::integer;
  v_oh := pg_temp.oh(v_item, 'WH01');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c2, pg_temp.fill(c2, jsonb_build_object(v_item, v_oh + 1))));
  r := pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s)', 'ZZ99', c2));
  PERFORM pg_temp.check(r->>'state' = 'posted' AND pg_temp.oh(v_item, 'WH01') = v_oh + 1 AND jsonb_array_length(r->'checks') = 0,
    'variance within 1 % posts at once (gain of 1)', r::text);

  -- A serial item with a variance, and stock that moved during the count.
  r := pg_temp.call(stock, $q$SELECT erp.inv_count_create('ZZ99', '{"whs_code":"WH01","item_group":101,"count_date":"2026-11-10"}')$q$);
  c3 := (r->>'count_id')::integer;
  r := pg_temp.call(stock, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c3, pg_temp.fill(c3, jsonb_build_object('SMP-1020', pg_temp.oh('SMP-1020', 'WH01') + 1))));
  r := pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s, %L)', 'ZZ99', c3, 'x'));
  PERFORM pg_temp.check(r->>'message' LIKE 'Line %: SMP-1020 is managed by serial numbers. Post the difference with a goods receipt or goods issue that names them, then recount.',
    'serial item with a count variance refused', r::text);
  r := pg_temp.call(stock, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c3, '[{"item_code":"6299448074725","counted_qty":5}]'));
  PERFORM pg_temp.check((r->>'added')::integer = 0, 'scanning a barcode finds the line already on the sheet', r::text);
  PERFORM pg_temp.gd(stock, 59, h1, '[{"item_code":"SMP-1050","qty":1,"price":38}]');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c3, pg_temp.fill(c3)));
  r := pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s, %L)', 'ZZ99', c3, 'x'));
  PERFORM pg_temp.check(r->>'message' LIKE 'Line %: stock of SMP-1050 changed since the count started (% then, % now). Cancel this count and start a new one.',
    'stock moved during the count: refused', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, format('SELECT erp.inv_count_cancel(%L, %s, %L)', 'ZZ99', c3, '')),
    'Add a note saying why you are cancelling this count.', 'cancel needs a note');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_cancel(%L, %s, %L)', 'ZZ99', c3, 'Recount tomorrow'));
  PERFORM pg_temp.check(r->>'state' = 'cancelled', 'count cancelled', r::text);

  -- Bins warehouse count: lines per bin, plus stock outside bins.
  r := pg_temp.call(stock, $q$SELECT erp.inv_count_create('ZZ99', '{"whs_code":"WH02","item_group":101,"count_date":"2026-11-10"}')$q$);
  c4 := (r->>'count_id')::integer;
  PERFORM pg_temp.check((SELECT count(*) FROM erp.inv_count_line l JOIN erp.bin_location b ON b.bin_id = l.bin_id WHERE l.company_code = 'ZZ99' AND l.count_id = c4 AND l.item_code = 'SMP-1010') = 2
                        AND EXISTS (SELECT 1 FROM erp.inv_count_line WHERE company_code = 'ZZ99' AND count_id = c4 AND item_code = 'SMP-1010' AND bin_id IS NULL),
    'bins count: SMP-1010 has a line per bin and one for stock outside bins');
  r := pg_temp.call(stock, format('SELECT erp.inv_count_save(%L, %s, %L::jsonb)', 'ZZ99', c4,
         pg_temp.fill(c4) || '[{"item_code":"SMP-1010","bin_code":"WH02-A-01-L1","counted_qty":9}]'::jsonb));
  r := pg_temp.call(stock, format('SELECT erp.inv_count_submit(%L, %s, %L)', 'ZZ99', c4, 'One unit missing from the bin'));
  IF r->>'state' = 'pending_approval' THEN
    r := pg_temp.call(smgr, format('SELECT erp.inv_count_decide(%L, %s, %L)', 'ZZ99', c4, 'approved'));
  END IF;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND pg_temp.binq('WH02-A-01-L1', 'SMP-1010') = 9, 'bin count posts into the bin (10 → 9)', r::text);

  -- ---------- Setup ----------
  r := pg_temp.call(stock, $q$SELECT erp.bin_save('ZZ99', '{"bin_code":"wh02-c-01-l1","whs_code":"WH02","name":"Zone C"}')$q$);
  PERFORM pg_temp.check(r->>'bin_code' = 'WH02-C-01-L1', 'new bin (code upper-cased)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.bin_save('ZZ99', '{"bin_code":"WH02-A-01-L1","active":false}')$q$),
    'Bin WH02-A-01-L1 still holds stock. Move it to another bin before deactivating it.', 'bin with stock can''t be deactivated');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_inv_set('ZZ99', 'WH02', '{"bins_enabled":false}')$q$),
    'Bins in WH02 still hold stock, so bins can''t be turned off.', 'bins can''t be turned off while they hold stock');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"OWN","name":"Own use","direction":"out","acct_code":"6200"}')$q$),
    'Only Financials with full access can change goods receipt and issue reasons (they decide the account).', 'inventory user can''t change reasons');
  r := pg_temp.call(admin, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"own","name":"Own use","direction":"out","acct_code":"6200"}')$q$);
  PERFORM pg_temp.check(r->>'code' = 'OWN', 'admin adds a reason', r::text);

  -- ---------- History and ties ----------
  r := pg_temp.call(sread, format('SELECT erp.lot_history(%L, %s)', 'ZZ99', (SELECT lot_id FROM erp.stock_lot WHERE company_code = 'ZZ99' AND number = 'SN-A2')));
  PERFORM pg_temp.check(jsonb_array_length(r->'moves') = 3 AND r->'balances'->0->>'whs_code' = 'TRN', 'serial history: received, transferred out and in; now in TRN', left(r::text, 300));
  r := pg_temp.call(sread, $q$SELECT to_jsonb(array_agg(doc_no ORDER BY trans_seq)) FROM erp.item_movement_list WHERE company_code = 'ZZ99' AND item_code = 'SMP-1010' AND trans_seq >= 900000000$q$);
  PERFORM pg_temp.check(r->>0 = 'GRC-26-00001' AND r ? 'IC-26-00001' AND r ? 'GI-26-00002', 'item history shows document numbers (receipt, issue, count)', left(r::text, 300));
  PERFORM pg_temp.check(NOT EXISTS (
      SELECT 1 FROM erp.stock_movement m
       WHERE m.company_code = 'ZZ99' AND m.trans_type IN (59, 60, 67, 1470000065) AND m.trans_seq >= 900000000
         AND NOT EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = m.company_code AND l.obj_type = m.trans_type AND l.doc_entry = m.doc_entry
                            AND l.line_num = m.doc_line AND l.item_code = m.item_code)
         AND NOT EXISTS (SELECT 1 FROM erp.inv_count_line c WHERE m.trans_type = 1470000065 AND c.company_code = m.company_code AND c.count_id = m.doc_entry
                            AND c.line_num = m.doc_line AND c.item_code = m.item_code))
    AND (SELECT count(*) FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type IN (59, 60, 67, 1470000065)) >= 15,
    'every movement row ties back to its document line');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.stock_lot_move m WHERE NOT EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = m.company_code
                                       AND l.obj_type = m.obj_type AND l.doc_entry = m.doc_entry AND l.line_num = m.doc_line))
                        AND NOT EXISTS (SELECT 1 FROM erp.bin_move m WHERE m.obj_type <> 1470000065 AND NOT EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = m.company_code
                                       AND l.obj_type = m.obj_type AND l.doc_entry = m.doc_entry AND l.line_num = m.doc_line)),
    'every batch / serial and bin movement ties back to its document line');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.stock_balance sb WHERE sb.company_code = 'ZZ99'
                                       AND (SELECT coalesce(sum(bs.qty), 0) FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                                             WHERE b.company_code = 'ZZ99' AND b.whs_code = sb.whs_code AND bs.item_code = sb.item_code) > sb.on_hand),
    'bins never hold more than the warehouse');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document_posting p JOIN erp.journal_line j ON j.company_code = p.company_code AND j.trans_id = p.trans_id
                                     WHERE p.company_code = 'ZZ99' AND p.obj_type IN (59, 60, 67, 1470000065)
                                     GROUP BY p.trans_id HAVING sum(j.debit) <> sum(j.credit)), 'every inventory journal balances');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE company_code = 'ZZ99' AND action IN ('goods_receipt_create', 'goods_issue_create', 'goods_receipt_approve',
                           'goods_issue_reject', 'goods_issue_cancel', 'transfer_request_create', 'inventory_transfer_create', 'inventory_count_create',
                           'inventory_count_save', 'inventory_count_submit', 'inventory_count_approve', 'inventory_count_cancel', 'bin_save', 'warehouse_inv_set',
                           'inventory_reason_save')) >= 30, 'every step is in the audit log');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = 'ZZ99' AND source <> 'erp' AND obj_type IN (1250000001, 67, 59, 60)
                                      AND doc_entry >= 900000000), 'no SAP or sample document touched');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a7_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a7_result;
ROLLBACK;
