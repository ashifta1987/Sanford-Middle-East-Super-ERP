-- B3 · G/L Account Determination and setup windows (warehouses, item groups, landed costs, resources, goods receipt / issue
-- reasons, bank statement matching). LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql). Run on a
-- FRESH rebuild (sql-order.txt incl. 32_gl_setup.sql). Everything happens inside one transaction that is rolled back.
-- Prints PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE b3_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON b3_result TO authenticated;

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
  INSERT INTO b3_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.gl(p_user uuid, p_rows jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.gl_determination_save(%L, %L::jsonb)', 'ZZ99', p_rows))
$$;
CREATE FUNCTION pg_temp.ov(p_user uuid, p_level text, p_ref text, p_rows jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.gl_override_save(%L, %L, %L, %L::jsonb)', 'ZZ99', p_level, p_ref, p_rows))
$$;
CREATE FUNCTION pg_temp.gd(p_user uuid, p_obj integer, p_header jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.inventory_doc_create(%L, %s, %L::jsonb, %L::jsonb, NULL, NULL::bigint)', 'ZZ99', p_obj, p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.su(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  EXECUTE p_sql INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
END $$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  bread  uuid := '00000000-0000-4000-8000-000000000009';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  sread  uuid := '00000000-0000-4000-8000-000000000015';
  it     uuid := '00000000-0000-4000-8000-000000000023';
  prod   uuid := '00000000-0000-4000-8000-000000000024';
  r jsonb; r2 jsonb;
  v_n integer; v_t integer; v_e integer; v_ser bigint; v_grp integer; v_stmt integer; v_gr integer;
  hi jsonb := '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"DAMAGE"}';
  no_fin text := 'Your position does not include Financials. Ask the system admin if you need it.';
BEGIN
  -- ================= 1. Posting keys (the inventory of 18–31) =================
  PERFORM pg_temp.check((SELECT count(*) FROM erp.gl_posting_key) = CASE WHEN to_regclass('erp.fx_revaluation') IS NOT NULL THEN 38 ELSE 36 END,
                        '36 posting keys (23 from A3/A6 + 13 new; 38 with B5''s revaluation keys)', (SELECT count(*) FROM erp.gl_posting_key)::text);
  PERFORM pg_temp.check((SELECT count(DISTINCT tab) FROM erp.gl_posting_key) = 9 AND NOT EXISTS (SELECT 1 FROM erp.gl_posting_key WHERE tab IS NULL),
                        'every key is on one of the 9 SAP tabs (sales, purchasing, inventory, banking, production, service, payroll, landed costs, general)');
  PERFORM pg_temp.check((SELECT string_agg(area || '/' || posting_key, ',' ORDER BY sort) FROM erp.gl_posting_key WHERE tab = 'landed_costs')
                        = 'purchasing/landed_cost_clearing,inventory/price_difference', 'Landed costs / price difference tab: clearing + price difference');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.gl_posting_key WHERE store IS NOT NULL) = 6
                        AND NOT EXISTS (SELECT 1 FROM erp.gl_determination g JOIN erp.gl_posting_key k USING (area, posting_key) WHERE k.store IS NOT NULL),
                        'six keys live in their setting columns (cash, cheques, card, WIP, variance, salaries payable) and have no gl_determination row');
  PERFORM pg_temp.check((SELECT bool_and(ctx) FROM erp.gl_posting_key WHERE area = 'inventory') AND NOT (SELECT ctx FROM erp.gl_posting_key WHERE posting_key = 'domestic_ar'),
                        'inventory keys may be set per item group / warehouse; receivables only per company');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.gl_determination WHERE company_code = 'ZZ99') = CASE WHEN to_regclass('erp.fx_revaluation') IS NOT NULL THEN 21 ELSE 19 END AND NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE company_code = 'AE05')
                        AND NOT EXISTS (SELECT 1 FROM erp.gl_determination_group) AND NOT EXISTS (SELECT 1 FROM erp.gl_determination_whs),
                        'ZZ99 keeps its 19 SAMPLE rows (21 with B5); AE05 and the override tables start empty');

  -- ================= 2. gl_setup =================
  r := pg_temp.call(fin, $q$SELECT erp.gl_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'keys') = CASE WHEN to_regclass('erp.fx_revaluation') IS NOT NULL THEN 38 ELSE 36 END AND (r->>'can_write')::boolean
                        AND (SELECT k->>'acct_code' FROM jsonb_array_elements(r->'keys') k WHERE k->>'posting_key' = 'revenue') = '4100'
                        AND (SELECT k->>'acct_code' FROM jsonb_array_elements(r->'keys') k WHERE k->>'area' = 'banking' AND k->>'posting_key' = 'cash') = '1105'
                        AND (SELECT k->>'acct_code' FROM jsonb_array_elements(r->'keys') k WHERE k->>'area' = 'production' AND k->>'posting_key' = 'wip') = '1360',
                        'finance reads every key: revenue 4100 (gl_determination), cash 1105 (banking setting), WIP 1360 (production setting)', left(r::text, 200));
  PERFORM pg_temp.check(jsonb_array_length(r->'groups') = 4 AND jsonb_array_length(r->'warehouses') = 4, 'gl_setup lists the item groups and warehouses for the override panels');
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.gl_setup('ZZ99')$q$), no_fin, 'sales user can''t open G/L Account Determination');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.gl_setup('ZZ99')$q$), no_fin, 'inventory user can''t open G/L Account Determination');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.gl_setup('AE01')$q$), 'You don''t have access to company AE01.', 'company outside the user''s companies refused');

  -- ================= 3. Saving company defaults =================
  PERFORM pg_temp.expect(pg_temp.gl(sales, '[{"area":"general","posting_key":"rounding","acct_code":"6800"}]'), no_fin, 'sales user can''t save');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[]'), 'Nothing to save. Change at least one account first.', 'empty save refused');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"rounding","acct_code":"6800"},{"area":"general","posting_key":"rounding","acct_code":"6200"}]'),
    'A key is listed twice. Save each key once.', 'same key twice refused');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"nope","acct_code":"6800"}]'), 'Unknown posting key general/nope.', 'unknown key refused');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"rounding","acct_code":"1000"}]'),
    'Rounding: Account 1000 · Assets is a title account. Choose a postable account.', 'title account refused (with the key name)');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"rounding","acct_code":"9999"}]'),
    'Rounding: Account 9999 does not exist in ZZ99. Check the account code.', 'unknown account refused');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"sales","posting_key":"revenue","acct_code":"1200"}]'),
    'Revenue: Account 1200 · Accounts receivable is a control account for customers or suppliers. Only the receivable and payable keys can use it.',
    'control account refused for a non-control key');
  r := pg_temp.gl(fin, '[{"area":"sales","posting_key":"domestic_ar","acct_code":"1200"}]');
  PERFORM pg_temp.check((r->>'saved')::int = 1 AND (r->>'changed')::int = 0, 'receivables keep their control account; the same value is not a change', r::text);
  UPDATE erp.account SET frozen = true WHERE company_code = 'ZZ99' AND acct_code = '7200';
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"rounding","acct_code":"7200"}]'),
    'Rounding: Account 7200 · FX losses is frozen. Choose another account.', 'frozen account refused');
  UPDATE erp.account SET frozen = false WHERE company_code = 'ZZ99' AND acct_code = '7200';
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"rounding","acct_code":"6800"},{"area":"sales","posting_key":"revenue","acct_code":"1000"}]'),
    'Revenue: Account 1000 · Assets is a title account. Choose a postable account.', 'one bad row stops the whole save');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'rounding'), 'all or nothing: the good row was not saved either');
  r := pg_temp.gl(fin, '[{"area":"general","posting_key":"rounding","acct_code":"6800"},{"area":"inventory","posting_key":"write_off","acct_code":"5300"},
                         {"area":"banking","posting_key":"cash","acct_code":"1105"},{"area":"payroll","posting_key":"payable","acct_code":"2300"},
                         {"area":"resources","posting_key":"resource_cost","acct_code":""}]');
  PERFORM pg_temp.check((r->>'saved')::int = 5 AND (r->>'changed')::int = 2
                        AND (SELECT acct_code FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'rounding') = '6800'
                        AND (SELECT acct_code FROM erp.gl_determination WHERE company_code = 'ZZ99' AND area = 'inventory' AND posting_key = 'write_off') = '5300',
                        'finance saves the grid: 5 rows, 2 changed (rounding, stock write-off)', r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE action = 'gl_determination_set' AND object_ref IN ('general/rounding', 'inventory/write_off')) = 2,
                        'each changed key has its audit row (unchanged ones none)');
  r := pg_temp.gl(fin, '[{"area":"banking","posting_key":"cash","acct_code":"1110"},{"area":"production","posting_key":"variance","acct_code":"5320"}]');
  PERFORM pg_temp.check((SELECT cash_acct FROM erp.banking_setting WHERE company_code = 'ZZ99') = '1110'
                        AND (SELECT variance_acct FROM erp.production_setting WHERE company_code = 'ZZ99') = '5320'
                        AND NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE company_code = 'ZZ99' AND area IN ('banking', 'production'))
                        AND erp.gl_account('ZZ99', 'banking', 'cash') = '1110',
                        'stored keys write their setting column (banking cash, production variance) and resolve from it', r::text);
  r := pg_temp.gl(fin, '[{"area":"banking","posting_key":"cash","acct_code":"1105"},{"area":"production","posting_key":"variance","acct_code":"5310"}]');
  INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source) VALUES ('ZZ99', 'general', 'opening_balances', '3200', 'sap');
  PERFORM pg_temp.expect(pg_temp.gl(fin, '[{"area":"general","posting_key":"opening_balances","acct_code":"3100"}]'),
    'The account for ''Opening balances'' comes from SAP Business One and is read-only during the soft switch.', 'SAP row stays read-only');
  DELETE FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'opening_balances';
  r := pg_temp.call(fin, $q$SELECT erp.gl_determination_set('ZZ99', 'production', 'wip', '1360')$q$);
  PERFORM pg_temp.check(r->>'acct_code' = '1360' AND NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE company_code = 'ZZ99' AND area = 'production'),
                        'A3 gl_determination_set routes a stored key to its setting too', r::text);

  -- ================= 4. Item group and warehouse accounts; resolution order =================
  PERFORM pg_temp.expect(pg_temp.ov(stock, 'group', '101', '[{"area":"inventory","posting_key":"inventory","acct_code":"1310"}]'), no_fin, 'inventory user can''t set group accounts');
  PERFORM pg_temp.expect(pg_temp.ov(fin, 'brand', '101', '[{"area":"inventory","posting_key":"inventory","acct_code":"1310"}]'),
    'Choose where the accounts are set: item group or warehouse.', 'unknown level refused');
  PERFORM pg_temp.expect(pg_temp.ov(fin, 'group', '999', '[{"area":"inventory","posting_key":"inventory","acct_code":"1310"}]'),
    'Item group 999 does not exist in company ZZ99.', 'unknown item group refused');
  PERFORM pg_temp.expect(pg_temp.ov(fin, 'warehouse', 'NOPE', '[{"area":"inventory","posting_key":"cogs","acct_code":"5210"}]'),
    'Warehouse NOPE does not exist in company ZZ99.', 'unknown warehouse refused');
  PERFORM pg_temp.expect(pg_temp.ov(fin, 'group', '101', '[{"area":"sales","posting_key":"domestic_ar","acct_code":"1200"}]'),
    '''Domestic accounts receivable'' is set for the whole company only. Set it in G/L Account Determination.', 'company-only key refused at item group level');
  r := pg_temp.ov(fin, 'group', '101', '[{"area":"inventory","posting_key":"inventory","acct_code":"1310"},{"area":"inventory","posting_key":"cogs","acct_code":"5210"},
                                         {"area":"sales","posting_key":"revenue","acct_code":"4150"}]');
  PERFORM pg_temp.check((r->>'changed')::int = 3 AND (SELECT count(*) FROM erp.gl_determination_group WHERE company_code = 'ZZ99' AND group_code = 101) = 3,
                        'finance sets item group 101 accounts (inventory 1310, COGS 5210, revenue 4150)', r::text);
  r := pg_temp.ov(fin, 'warehouse', 'WH02', '[{"area":"inventory","posting_key":"inventory","acct_code":"1600"},{"area":"inventory","posting_key":"cogs","acct_code":"5230"}]');
  PERFORM pg_temp.check((SELECT stock_acct FROM erp.warehouse_setting WHERE company_code = 'ZZ99' AND whs_code = 'WH02') = '1600'
                        AND (SELECT acct_code FROM erp.gl_determination_whs WHERE company_code = 'ZZ99' AND whs_code = 'WH02' AND posting_key = 'cogs') = '5230'
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE object_ref = 'warehouse:WH02:inventory/cogs'),
                        'warehouse WH02 accounts: stock account stays in warehouse_setting (1600), COGS 5230 in gl_determination_whs; audited', r::text);
  PERFORM pg_temp.check(erp.gl_account('ZZ99', 'inventory', 'cogs', true, 101, 'WH01') = '5210', 'resolution: item group beats the company default');
  PERFORM pg_temp.check(erp.gl_account('ZZ99', 'inventory', 'cogs', true, 101, 'WH02') = '5230', 'resolution: warehouse beats the item group');
  PERFORM pg_temp.check(erp.gl_account('ZZ99', 'inventory', 'cogs', true, 104, 'WH01') = '5100' AND erp.gl_account('ZZ99', 'inventory', 'cogs') = '5100',
                        'resolution: no override = company default (and the A3 signature is unchanged)');
  PERFORM pg_temp.check(erp.gl_account('ZZ99', 'inventory', 'inventory', true, 101, 'WH02') = '1600' AND erp._inv_whs_acct('ZZ99', 'WH02') = '1600'
                        AND erp._inv_whs_acct('ZZ99', 'WH01') = '1300', 'warehouse stock account wins; _inv_whs_acct gives the same as A7');
  PERFORM pg_temp.check(erp.gl_account('ZZ99', 'sales', 'domestic_ar', true, 101, 'WH02') = '1200', 'company-only keys ignore item group and warehouse');
  r := pg_temp.call(fin, $q$SELECT erp.gl_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'group_rows') = 3 AND jsonb_array_length(r->'warehouse_rows') = 2
                        AND (SELECT (k->>'overrides')::int FROM jsonb_array_elements(r->'keys') k WHERE k->>'posting_key' = 'cogs') = 2,
                        'gl_setup shows the overrides and counts them per key', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.su($q$SELECT to_jsonb(erp.gl_account('ZZ99', 'inventory', 'samples', true, 101, 'WH01'))$q$),
    'G/L account for ''Samples'' is not set for ZZ99. Ask Finance to set it in Setup › Financials › G/L Account Determination.', 'nothing set: the A3 message names the key');

  -- ================= 5. Posting uses the item group / warehouse accounts =================
  r := pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1010","qty":1},{"item_code":"SMP-RAW-EL","qty":1}]');
  v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(v_t IS NOT NULL AND pg_temp.jl(v_t) LIKE '%1310 Cr 95%' AND pg_temp.jl(v_t) LIKE '%1300 Cr %' AND pg_temp.jl(v_t) LIKE '%5300 Dr %',
                        'goods issue: group 101 item credits 1310, group 104 item credits the company 1300', r::text || ' ' || coalesce(pg_temp.jl(v_t), ''));
  r := pg_temp.gd(stock, 59, '{"doc_date":"2026-11-10","whs_code":"WH02","reason_code":"FOUND"}', '[{"item_code":"SMP-1010","qty":1,"price":95,"bin_code":"WH02-A-01-L1"}]');
  v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.jl(v_t) = '1600 Dr 95, 5300 Cr 95', 'goods receipt into WH02: the warehouse stock account (1600) wins over the item group', r::text || ' ' || coalesce(pg_temp.jl(v_t), ''));
  r := pg_temp.call(stock, $q$SELECT erp.transfer_create('ZZ99', '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"WH02"}', '[{"item_code":"SMP-1010","qty":2,"to_bin":"WH02-A-01-L1"}]')$q$);
  v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.jl(v_t) = '1600 Dr 190, 1310 Cr 190', 'transfer WH01 → WH02: Dr 1600 / Cr 1310 (accounts differ)', r::text || ' ' || coalesce(pg_temp.jl(v_t), ''));
  r := pg_temp.call(stock, $q$SELECT erp.transfer_create('ZZ99', '{"doc_date":"2026-11-10","from_whs":"WH01","to_whs":"TRN"}', '[{"item_code":"SMP-1010","qty":1}]')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->>'trans_id' IS NULL, 'transfer between warehouses with the same account posts nothing', r::text);
  -- Reasons without an account use their G/L key (warehouse first)
  r := pg_temp.call(admin, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"B3WO","name":"B3 write-off","direction":"out","gl_key":"inventory/write_off"}')$q$);
  PERFORM pg_temp.check(r->>'gl_key' = 'inventory/write_off' AND r->>'acct_code' IS NULL, 'finance (admin with Inventory + Financials) adds a reason mapped to a key, no account', r::text);
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"B3X","name":"X","direction":"out","gl_key":"inventory/nope"}')$q$),
    'Choose a G/L Account Determination key that exists for reason B3X.', 'reason with an unknown key refused');
  r := pg_temp.gd(stock, 60, '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"B3WO"}', '[{"item_code":"SMP-RAW-EL","qty":1}]');
  v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.jl(v_t) LIKE '%5300 Dr%', 'reason without account: offset from its key (company default 5300)', r::text || ' ' || coalesce(pg_temp.jl(v_t), ''));
  r := pg_temp.ov(fin, 'warehouse', 'WH01', '[{"area":"inventory","posting_key":"write_off","acct_code":"6400"}]');
  r := pg_temp.gd(stock, 60, '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"B3WO"}', '[{"item_code":"SMP-RAW-EL","qty":1}]');
  v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.jl(v_t) LIKE '%6400 Dr%', 'reason without account: the warehouse''s write-off account (6400) wins', r::text || ' ' || coalesce(pg_temp.jl(v_t), ''));
  r := pg_temp.call(admin, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"B3SM","name":"B3 samples","direction":"out","gl_key":"inventory/samples"}')$q$);
  r := pg_temp.call(stock, $q$SELECT erp.inventory_doc_checks('ZZ99', 60, '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"B3SM"}', '[{"item_code":"SMP-RAW-EL","qty":1}]')$q$);
  PERFORM pg_temp.check((SELECT e->>'message' FROM jsonb_array_elements(r->'errors') e WHERE e->>'field' = 'acct_code')
                        = 'Reason B3 samples has no account, and G/L account for ''Samples'' is not set for ZZ99. Choose the account, or ask Finance to set it in Setup › Financials › G/L Account Determination.',
                        'reason whose key is not set: the check names the key', left(r::text, 300));
  -- A/R side: revenue per item group; COGS per item group / warehouse (post_document on Super ERP fixtures)
  v_e := 990301;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, card_name, currency, total, vat_total, source)
  VALUES ('ZZ99', 13, v_e, v_e, 'invoice', 'open', '2026-11-10', '2026-12-10', 'C0011', 'B3 test', 'AED', 315, 15, 'erp'),
         ('ZZ99', 15, v_e, v_e, 'delivery', 'closed', '2026-11-10', '2026-11-10', 'C0011', 'B3 test', 'AED', 0, 0, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total, vat, tax_code, whs_code, stock_price)
  VALUES ('ZZ99', 13, v_e, 0, 'SMP-1010', 1, 0, 200, 200, 10, 'SR', 'WH01', 95), ('ZZ99', 13, v_e, 1, 'SMP-RAW-EL', 1, 0, 100, 100, 5, 'SR', 'WH01', 10),
         ('ZZ99', 15, v_e, 0, 'SMP-1010', 1, 0, 200, 200, 0, 'SR', 'WH01', 95), ('ZZ99', 15, v_e, 1, 'SMP-1010', 1, 0, 200, 200, 0, 'SR', 'WH02', 95);
  v_t := erp.post_document('ZZ99', 13, v_e);
  PERFORM pg_temp.check(pg_temp.jl(v_t) LIKE '%4100 Cr 100%' AND pg_temp.jl(v_t) LIKE '%4150 Cr 200%' AND pg_temp.jl(v_t) LIKE '1200 Dr 315%',
                        'A/R invoice: revenue per item group (101 → 4150, others → 4100)', coalesce(pg_temp.jl(v_t), ''));
  v_t := erp.post_document('ZZ99', 15, v_e);
  PERFORM pg_temp.check(pg_temp.jl(v_t) = '5210 Dr 95, 5230 Dr 95, 1310 Cr 95, 1600 Cr 95',
                        'delivery: COGS 5210 (group) / 5230 (WH02), stock 1310 (group) / 1600 (WH02)', coalesce(pg_temp.jl(v_t), ''));

  -- ================= 6. Warehouses =================
  r := pg_temp.call(stock, $q$SELECT erp.warehouse_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'warehouses') = 4 AND (r->>'can_write')::boolean AND NOT (r->>'can_read_finance')::boolean
                        AND (SELECT w->>'stock_acct' FROM jsonb_array_elements(r->'warehouses') w WHERE w->>'whs_code' = 'WH02') IS NULL
                        AND jsonb_array_length(r->'keys') = 0 AND jsonb_array_length(r->'doc_types') > 10
                        AND (SELECT jsonb_array_length(w->'bins') FROM jsonb_array_elements(r->'warehouses') w WHERE w->>'whs_code' = 'WH02') = 3,
                        'inventory user reads warehouses, bins and numbering; accounts stay hidden without Financials', left(r::text, 200));
  r := pg_temp.call(admin, $q$SELECT erp.warehouse_setup('ZZ99')$q$);
  PERFORM pg_temp.check((SELECT w->>'stock_acct' FROM jsonb_array_elements(r->'warehouses') w WHERE w->>'whs_code' = 'WH02') = '1600'
                        AND jsonb_array_length(r->'keys') = (SELECT count(*) FROM erp.gl_posting_key WHERE ctx), 'with Financials the Accounting tab shows the accounts and keys');
  PERFORM pg_temp.expect(pg_temp.call(sread, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"B3W","name":"B3"}')$q$),
    'You have read-only access to Inventory. Ask the system admin for full access to set up warehouses.', 'inventory read-only can''t create warehouses');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"B3 W","name":"B3"}')$q$),
    'Enter a warehouse code of up to 8 letters, digits, dashes or underscores.', 'bad warehouse code refused');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"B3W"}')$q$), 'Enter the warehouse name.', 'name required');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"B3W","name":"B3","country":"United"}')$q$),
    'Enter the country as a 2-letter code, e.g. AE.', 'bad country refused');
  r := pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"b3w","name":"B3 showroom","city":"Dubai","country":"ae","branch_id":"2"}')$q$);
  PERFORM pg_temp.check((r->>'created')::boolean AND (SELECT origin FROM erp.warehouse_setting WHERE company_code = 'ZZ99' AND whs_code = 'B3W') = 'erp'
                        AND (SELECT country || '/' || branch_id FROM erp.warehouse WHERE company_code = 'ZZ99' AND whs_code = 'B3W') = 'AE/2',
                        'inventory creates a Super ERP warehouse (code upper case, origin erp)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"B3W","name":"Again"}')$q$),
    'Warehouse B3W already exists in ZZ99. Open it to change it.', 'duplicate warehouse refused');
  r := pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"B3W","name":"B3 showroom 2","edit":true,"locked":true}')$q$);
  PERFORM pg_temp.check((SELECT name || '/' || locked FROM erp.warehouse WHERE company_code = 'ZZ99' AND whs_code = 'B3W') = 'B3 showroom 2/true', 'Super ERP warehouse general data edited', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"WH01","name":"Renamed","edit":true}')$q$),
    'Warehouse WH01 comes from SAP Business One. Change its general data in SAP until ZZ99 goes live on Super ERP.', 'SAP / sample warehouse general data stays read-only');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.warehouse_save('ZZ99', '{"whs_code":"NOPE","name":"X","edit":true}')$q$),
    'Warehouse NOPE does not exist in company ZZ99.', 'edit of an unknown warehouse refused');
  r := pg_temp.call(stock, $q$SELECT erp.warehouse_inv_set('ZZ99', 'B3W', '{"bins_enabled":true}')$q$);
  r := pg_temp.call(stock, $q$SELECT erp.bin_save('ZZ99', '{"whs_code":"B3W","bin_code":"B3W-01"}')$q$);
  PERFORM pg_temp.check((SELECT bins_enabled FROM erp.warehouse_setting WHERE company_code = 'ZZ99' AND whs_code = 'B3W')
                        AND EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = 'ZZ99' AND bin_code = 'B3W-01'), 'bin switch and bin list work on the new warehouse (A7 functions)', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'warehouse_create' AND object_ref = 'B3W') AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'warehouse_update' AND object_ref = 'B3W'),
                        'warehouse create and change audited');
  -- Default numbering per warehouse
  r := pg_temp.call(admin, $q$SELECT erp.doc_series_save('ZZ99', '{"obj_type":60,"name":"Jebel Ali issues","prefix":"GIJ-26-","pad":4}')$q$);
  v_ser := (r->>'series_id')::bigint;
  PERFORM pg_temp.expect(pg_temp.call(sread, format($q$SELECT erp.warehouse_series_set('ZZ99', 'WH02', 60, %s)$q$, v_ser)),
    'You have read-only access to Inventory. Ask the system admin for full access to set warehouse numbering.', 'read-only can''t set warehouse numbering');
  PERFORM pg_temp.expect(pg_temp.call(stock, format($q$SELECT erp.warehouse_series_set('ZZ99', 'WH02', 59, %s)$q$, v_ser)),
    format('Series %s is not a Goods Receipt series of company ZZ99.', v_ser), 'series of another document type refused');
  PERFORM pg_temp.expect(pg_temp.call(stock, format($q$SELECT erp.warehouse_series_set('ZZ99', 'WH02', 99, %s)$q$, v_ser)), 'Choose a document type.', 'unknown document type refused');
  r := pg_temp.call(stock, format($q$SELECT erp.warehouse_series_set('ZZ99', 'WH02', 60, %s)$q$, v_ser));
  PERFORM pg_temp.check(r->>'name' = 'Jebel Ali issues' AND EXISTS (SELECT 1 FROM erp.warehouse_series_default WHERE company_code = 'ZZ99' AND whs_code = 'WH02' AND obj_type = 60),
                        'inventory sets WH02''s default goods issue series', r::text);
  r := pg_temp.gd(stock, 60, hi || '{"whs_code":"WH02"}', '[{"item_code":"SMP-1010","qty":1,"bin_code":"WH02-A-01-L1"}]');
  r2 := pg_temp.gd(stock, 60, hi, '[{"item_code":"SMP-1010","qty":1}]');
  PERFORM pg_temp.check(r->>'doc_no' = 'GIJ-26-0001' AND r2->>'doc_no' LIKE 'GI-26-%', 'goods issue from WH02 numbered by the warehouse series; WH01 keeps the company default',
                        coalesce(r->>'doc_no', r::text) || ' / ' || coalesce(r2->>'doc_no', r2::text));
  PERFORM pg_temp.call(admin, format($q$SELECT erp.series_user_default_save('ZZ99', %L, 60, %s)$q$, stock, (SELECT series_id FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 60)));
  r := pg_temp.gd(stock, 60, hi || '{"whs_code":"WH02"}', '[{"item_code":"SMP-1010","qty":1,"bin_code":"WH02-A-01-L1"}]');
  PERFORM pg_temp.check(r->>'doc_no' LIKE 'GI-26-%', 'the user''s own default series comes before the warehouse default', coalesce(r->>'doc_no', r::text));
  UPDATE erp.doc_series SET locked = true WHERE series_id = v_ser;
  PERFORM pg_temp.expect(pg_temp.call(stock, format($q$SELECT erp.warehouse_series_set('ZZ99', 'WH01', 60, %s)$q$, v_ser)),
    'Goods Issue series Jebel Ali issues is locked. Choose another series.', 'locked series refused');
  r := pg_temp.call(stock, $q$SELECT erp.warehouse_series_set('ZZ99', 'WH02', 60, NULL)$q$);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.warehouse_series_default WHERE company_code = 'ZZ99' AND whs_code = 'WH02') AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'warehouse_series_set'),
                        'warehouse default cleared; changes audited', r::text);

  -- ================= 7. Item groups =================
  r := pg_temp.call(stock, $q$SELECT erp.item_group_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'groups') = 4 AND (SELECT (g->>'warranty_months')::int FROM jsonb_array_elements(r->'groups') g WHERE g->>'group_code' = '101') = 12
                        AND (SELECT g->>'manage_method' FROM jsonb_array_elements(r->'groups') g WHERE g->>'group_code' = '102') = 'none',
                        'item groups: warranty months from A13 (101 = 12), method none by default', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(sread, $q$SELECT erp.item_group_save('ZZ99', '{"group_code":103,"manage_method":"batch"}')$q$),
    'You have read-only access to Inventory. Ask the system admin for full access to set up item groups.', 'read-only can''t change item groups');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.item_group_save('ZZ99', '{"group_code":103,"manage_method":"lots"}')$q$),
    'Choose the management method: none, batch or serial.', 'unknown method refused');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.item_group_save('ZZ99', '{"group_code":103,"warranty_months":"300"}')$q$),
    'Warranty must be a whole number of months between 1 and 240, or empty.', 'warranty out of range refused');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.item_group_save('ZZ99', '{"group_code":103,"name":"Household"}')$q$),
    'Item group Home care comes from SAP Business One. Change its name in SAP until ZZ99 goes live on Super ERP.', 'SAP item group name stays read-only');
  r := pg_temp.call(stock, $q$SELECT erp.item_group_save('ZZ99', '{"group_code":103,"manage_method":"batch","warranty_months":"24"}')$q$);
  PERFORM pg_temp.check((SELECT manage_method FROM erp.item_group_setting WHERE company_code = 'ZZ99' AND group_code = 103) = 'batch'
                        AND (SELECT months FROM erp.warranty_rule WHERE company_code = 'ZZ99' AND group_code = 103 AND item_code IS NULL) = 24,
                        'group 103: batch managed, 24 months warranty (A13 warranty_rule)', r::text);
  PERFORM pg_temp.check((erp._svc_warranty('ZZ99', jsonb_build_object('item_code', (SELECT item_code FROM erp.item WHERE company_code = 'ZZ99' AND group_code = 103 LIMIT 1),
                                                                    'on_date', '2026-11-10'))->>'months') IS NOT DISTINCT FROM '24'
                        OR NOT EXISTS (SELECT 1 FROM erp.item WHERE company_code = 'ZZ99' AND group_code = 103),
                        'service warranty reads the group months');
  INSERT INTO erp.item (company_code, item_code, name, group_code, is_stock, source) VALUES ('ZZ99', 'B3-BATCH-1', 'B3 batch item', 103, true, 'erp');
  INSERT INTO erp.item (company_code, item_code, name, group_code, is_stock, source) VALUES ('ZZ99', 'B3-SAP-1', 'B3 SAP item', 103, true, 'sap');
  PERFORM pg_temp.check((SELECT batch_managed FROM erp.item WHERE company_code = 'ZZ99' AND item_code = 'B3-BATCH-1')
                        AND NOT (SELECT batch_managed FROM erp.item WHERE company_code = 'ZZ99' AND item_code = 'B3-SAP-1'),
                        'a new Super ERP item in a batch group is batch managed; SAP rows are untouched');
  r := pg_temp.call(stock, $q$SELECT erp.item_group_save('ZZ99', '{"name":"B3 spare parts","manage_method":"serial"}')$q$);
  v_grp := (r->>'group_code')::integer;
  PERFORM pg_temp.check(v_grp >= 900000 AND (SELECT origin FROM erp.item_group_setting WHERE company_code = 'ZZ99' AND group_code = v_grp) = 'erp',
                        'inventory creates a Super ERP item group (code from 900000)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.item_group_save('ZZ99', '{"name":"b3 SPARE parts"}')$q$),
    'Item group b3 SPARE parts already exists in ZZ99.', 'duplicate group name refused');
  r := pg_temp.call(stock, format($q$SELECT erp.item_group_save('ZZ99', '{"group_code":%s,"name":"B3 parts","warranty_months":""}')$q$, v_grp));
  PERFORM pg_temp.check((SELECT name FROM erp.item_group WHERE company_code = 'ZZ99' AND group_code = v_grp) = 'B3 parts', 'Super ERP group can be renamed', r::text);
  r := pg_temp.ov(fin, 'group', v_grp::text, '[{"area":"inventory","posting_key":"inventory","acct_code":"1600"}]');
  PERFORM pg_temp.ok(r, 'finance sets accounts on the new group');

  -- ================= 8. Landed cost types =================
  PERFORM pg_temp.expect(pg_temp.call(purch, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"B3PORT","name":"Port","split_method":"equal","acct_code":"5210"}')$q$),
    'Changing the account of a landed cost type also needs Financials full access.', 'purchasing alone can''t set the account');
  r := pg_temp.call(purch, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"b3port","name":"Port handling","split_method":"equal"}')$q$);
  PERFORM pg_temp.check(r->>'split_method' = 'equal' AND r->>'acct_code' IS NULL, 'purchasing adds a type split equally (account empty = clearing)', r::text);
  r := pg_temp.call(purch, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"B3VOL","name":"Volume","split_method":"volume"}')$q$);
  r2 := pg_temp.call(purch, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"B3QTY","name":"Qty","split_method":"quantity"}')$q$);
  PERFORM pg_temp.check(r->>'split_method' = 'cbm' AND r2->>'split_method' = 'qty', 'volume / quantity are stored as A6''s cbm / qty', r::text || r2::text);
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"B3PORT","name":"Port handling","split_method":"equal","acct_code":"2100"}')$q$),
    'Landed cost B3PORT: Account 2100 · Accounts payable is a control account for customers or suppliers. Only the receivable and payable keys can use it.', 'control account refused for a landed cost type');
  r := pg_temp.call(fin, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"B3PORT","name":"Port handling","split_method":"equal","acct_code":"5210"}')$q$);
  PERFORM pg_temp.check(r->>'acct_code' = '5210', 'finance maps the type to account 5210', r::text);
  r := pg_temp.call(purch, $q$SELECT erp.landed_cost_code_save('ZZ99', '{"code":"B3PORT","name":"Port handling 2","split_method":"equal"}')$q$);
  PERFORM pg_temp.check(r->>'acct_code' = '5210', 'saving without acct_code keeps the account (purchasing may rename)', r::text);
  r := pg_temp.call(purch, $q$SELECT erp.landed_cost_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'methods') = 5 AND r->>'clearing_acct' = '2130' AND NOT (r->>'can_finance')::boolean
                        AND (SELECT c->>'acct_code' FROM jsonb_array_elements(r->'codes') c WHERE c->>'code' = 'B3PORT') = '5210', 'landed_cost_setup: 5 methods, clearing 2130, types with accounts', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.landed_cost_setup('ZZ99')$q$), 'Your position does not include Purchasing. Ask the system admin if you need it.', 'sales can''t open landed cost setup');
  -- A Super ERP goods receipt fixture with two lines; equal split + type account on posting
  v_gr := 990302;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, card_name, currency, total, source)
  VALUES ('ZZ99', 20, v_gr, v_gr, 'goods_receipt_po', 'open', '2026-11-10', 'S0009', 'B3 supplier', 'AED', 1000, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total, whs_code, stock_price)
  VALUES ('ZZ99', 20, v_gr, 0, 'SMP-1010', 4, 4, 95, 380, 'WH01', 95), ('ZZ99', 20, v_gr, 1, 'SMP-RAW-EL', 10, 10, 62, 620, 'WH01', 62);
  r := pg_temp.call(purch, format($q$SELECT erp.landed_cost_preview('ZZ99', '{"doc_date":"2026-11-10"}', '[{"grpo_entry":%s,"grpo_line":0},{"grpo_entry":%s,"grpo_line":1}]', '[{"code":"B3PORT","amount":101}]')$q$, v_gr, v_gr));
  PERFORM pg_temp.check((SELECT string_agg(a->>'amount', ',' ORDER BY (a->>'line_num')::int) FROM jsonb_array_elements(r->'allocs') a) = '50.50,50.50'
                        AND r->'charges'->0->>'acct_code' = '5210', 'equal split: 101 → 50.50 + 50.50; the charge carries its type account', left(r::text, 300));
  r := pg_temp.call(purch, format($q$SELECT erp.landed_cost_create('ZZ99', '{"doc_date":"2026-11-10"}', '[{"grpo_entry":%s,"grpo_line":0},{"grpo_entry":%s,"grpo_line":1}]', '[{"code":"B3PORT","amount":101},{"code":"DUTY","amount":50}]')$q$, v_gr, v_gr));
  v_t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(pg_temp.jl(v_t) LIKE '%1300 Dr%' AND pg_temp.jl(v_t) LIKE '%1310 Dr%' AND pg_temp.jl(v_t) LIKE '%5210 Cr 101%' AND pg_temp.jl(v_t) LIKE '%2130 Cr 50%'
                        AND (SELECT acct_code FROM erp.landed_cost_charge WHERE company_code = 'ZZ99' AND doc_entry = (r->>'doc_entry')::int AND code = 'B3PORT') = '5210',
                        'landed costs: stock per item group (1310 / 1300), credit per type account (5210) and clearing (2130)', r::text || ' ' || coalesce(pg_temp.jl(v_t), ''));

  -- ================= 9. Standard goods receipt / issue reasons =================
  PERFORM pg_temp.check((SELECT count(*) FROM erp.inventory_reason WHERE company_code = 'AE05' AND acct_code IS NULL AND gl_key IS NOT NULL) = 7
                        AND (SELECT string_agg(code, ',' ORDER BY code) FROM erp.inventory_reason WHERE company_code = 'AE05') = 'DAMAGE,FOUND,INTERNAL,OPENING,SAMPLE,SERVICE,WRITEOFF',
                        'AE05 has the 7 standard reasons, each mapped to a key, no account');
  PERFORM pg_temp.check((SELECT gl_area || '/' || gl_key FROM erp.inventory_reason WHERE company_code = 'AE05' AND code = 'OPENING') = 'general/opening_balances'
                        AND (SELECT gl_area || '/' || gl_key FROM erp.inventory_reason WHERE company_code = 'AE05' AND code = 'SERVICE') = 'service/spare_parts'
                        AND (SELECT direction FROM erp.inventory_reason WHERE company_code = 'AE05' AND code = 'FOUND') = 'in', 'standard reasons: opening → opening balances, service → service spare parts, found is a receipt');
  PERFORM pg_temp.check((SELECT acct_code || ' ' || gl_key FROM erp.inventory_reason WHERE company_code = 'ZZ99' AND code = 'DAMAGE') = '5300 write_off',
                        'ZZ99 SAMPLE reasons keep their account and get the key');
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency) VALUES ('AE09', 'B3 test company', 'B3', 'AE', 'AED');
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency) VALUES ('ZZ95', 'B3 sample company', 'ZZ95', 'AE', 'AED');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.inventory_reason WHERE company_code = 'AE09') = 7 AND NOT EXISTS (SELECT 1 FROM erp.inventory_reason WHERE company_code = 'ZZ95'),
                        'a new company gets the standard reasons (not the ZZ sample / test companies)');
  PERFORM pg_temp.expect(pg_temp.call(stock, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"B3Y","name":"Y","direction":"out"}')$q$),
    'Only Financials with full access can change goods receipt and issue reasons (they decide the account).', 'inventory alone can''t change reasons');
  r := pg_temp.call(admin, $q$SELECT erp.inventory_reason_save('ZZ99', '{"code":"B3WO","name":"B3 write-off","direction":"out","acct_code":"5300"}')$q$);
  PERFORM pg_temp.check(r->>'gl_key' = 'inventory/write_off' AND r->>'acct_code' = '5300', 'saving without gl_key keeps the key', r::text);

  -- ================= 10. Production resources =================
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"B3-LAB","name":"Assembly labour","kind":"labour","unit":"hour","unit_cost":45}')$q$),
    'Resource B3-LAB has a cost, so it needs the account its cost is credited to. Ask Finance to set it.', 'resource with a rate and no account refused while resource absorption is not set');
  r := pg_temp.gl(fin, '[{"area":"resources","posting_key":"resource_cost","acct_code":"5320"}]');
  r := pg_temp.call(admin, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"B3-LAB","name":"Assembly labour","kind":"labour","unit":"hour","unit_cost":45}')$q$);
  PERFORM pg_temp.check(r->>'res_code' = 'B3-LAB' AND (SELECT unit || ' ' || trim_scale(unit_cost) || ' ' || coalesce(acct_code, '-') FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'B3-LAB') = 'hour 45 -',
                        'with resource absorption set, an hourly resource may leave its account empty', r::text);

  -- ================= 11. Bank statements =================
  PERFORM pg_temp.expect(pg_temp.call(bread, $q$SELECT erp.bank_statement_format_save('ZZ99', 'BNK-AED', '{"date":"Date","amount":"Amount"}')$q$),
    'You have read-only access to Banking. Ask the system admin for full access to save bank statement formats.', 'banking read-only can''t save a format');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_format_save('ZZ99', 'CASH', '{"date":"Date","amount":"Amount"}')$q$),
    'Choose a bank account of company ZZ99 for the format.', 'cash account has no statement format');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_format_save('ZZ99', 'BNK-AED', '{"amount":"Amount"}')$q$), 'Choose the date column.', 'date column required');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_format_save('ZZ99', 'BNK-AED', '{"date":"Date","mode":"split","debit":"Dr"}')$q$),
    'Choose the debit and the credit columns.', 'split mode needs debit and credit');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_format_save('ZZ99', 'BNK-AED', '{"date":"Date","amount":"Amount","decimal_sep":";"}')$q$),
    'The decimal separator is a dot or a comma.', 'bad decimal separator refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_format_save('ZZ99', 'BNK-AED', '{"date":"Date","amount":"Amount","date_format":"YY"}')$q$),
    'Choose a date format from the list.', 'bad date format refused');
  r := pg_temp.call(fin, $q$SELECT erp.bank_statement_format_save('ZZ99', 'BNK-AED', '{"mode":"split","date":"Value date","debit":"Debit","credit":"Credit","reference":"Cheque/Ref","description":"Narrative","date_format":"DD.MM.YYYY","decimal_sep":","}')$q$);
  PERFORM pg_temp.check((SELECT mapping->>'decimal_sep' || ' ' || (mapping->>'debit') FROM erp.bank_statement_format WHERE company_code = 'ZZ99' AND bank_code = 'BNK-AED') = ', Debit'
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'bank_statement_format_save' AND object_ref = 'BNK-AED'), 'mapping saved per bank account (audited)', r::text);
  r := pg_temp.call(bread, $q$SELECT to_jsonb(count(*)) FROM erp.bank_statement_format WHERE company_code = 'ZZ99'$q$);
  PERFORM pg_temp.check(r::text = '1', 'banking readers see the saved mapping', r::text);
  -- payments that reach the bank
  FOR v_n IN 1..4 LOOP
    r := pg_temp.call(fin, format($q$SELECT erp.payment_submit('ZZ99', 'I', %L::jsonb, '[]'::jsonb, NULL)$q$,
           jsonb_build_object('card_code', 'C0011', 'doc_date', '2026-11-09', 'transfer', (ARRAY[1234.56, 2222.22, 3333.33, 4444.44])[v_n], 'transfer_bank', 'BNK-AED',
                              'transfer_ref', (ARRAY['B3REF77', 'XYZ1', NULL, NULL])[v_n])));
    PERFORM pg_temp.ok(r, format('payment %s posted', v_n));
  END LOOP;
  r := pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'b3.csv', '[
        {"date":"2026-11-11","description":"Transfer","reference":"TT b3-ref77","amount":"1234.56"},
        {"date":"2026-11-09","description":"Transfer","reference":"OTHER99","amount":"2222.22"},
        {"date":"2026-11-12","description":"Transfer","reference":"","amount":"3333.33"},
        {"date":"2026-11-14","description":"Transfer","reference":"","amount":"4444.44"}]')$q$);
  v_stmt := (r->>'statement_id')::integer;
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_auto_match('ZZ99', %s)$q$, v_stmt));
  PERFORM pg_temp.check((r->>'matched')::int = 2 AND (r->>'unmatched')::int = 2 AND (r->>'window_days')::int = 3,
                        'auto-match: 2 matched (reference inside the bank text; no reference within 3 days), 2 left', r::text);
  PERFORM pg_temp.check((SELECT string_agg(trim_scale(l.amount)::text, ',' ORDER BY l.line_no) FROM erp.bank_statement_line l JOIN erp.bank_match m ON m.statement_line_id = l.line_id
                          WHERE l.statement_id = v_stmt) = '1234.56,3333.33', 'matched lines: the referenced transfer and the unreferenced one inside ±3 days');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.bank_statement_line l JOIN erp.bank_match m ON m.statement_line_id = l.line_id WHERE l.statement_id = v_stmt AND l.amount = 2222.22),
                        'same amount and date but a different reference: left for manual matching');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.bank_statement_line l JOIN erp.bank_match m ON m.statement_line_id = l.line_id WHERE l.statement_id = v_stmt AND l.amount = 4444.44),
                        '5 days apart: outside ±3 days, left for manual matching');
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_candidates('ZZ99', %s)$q$, (SELECT line_id FROM erp.bank_statement_line WHERE statement_id = v_stmt AND amount = 2222.22)));
  PERFORM pg_temp.check(jsonb_array_length(r) >= 1, 'the manual match still offers it', left(r::text, 200));
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_unmatch('ZZ99', %s)$q$, (SELECT line_id FROM erp.bank_statement_line WHERE statement_id = v_stmt AND amount = 3333.33)));
  r := pg_temp.call(bread, format($q$SELECT erp.bank_statement_activity('ZZ99', %s)$q$, v_stmt));
  PERFORM pg_temp.check(r->0->>'action' = 'bank_statement_unmatch' AND r->0->>'actor_name' = 'QA Finance'
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r) a WHERE a->>'action' = 'bank_statement_auto_match'),
                        'statement activity: unmatch (who) and auto-match are audited', left(r::text, 200));
  UPDATE erp.banking_setting SET match_days = NULL WHERE company_code = 'ZZ99';
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_auto_match('ZZ99', %s)$q$, v_stmt));
  PERFORM pg_temp.check((r->>'window_days')::int = 3 AND (r->>'matched')::int = 1, 'no window set: ±3 days by default (the unmatched line matches again)', r::text);

  -- ================= 12. Health, grants =================
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '32_gl_setup.sql' AND object = 'gl_setup') AND (SELECT count(*) FROM erp._health_files()) >= 20,
                        'system health knows 32_gl_setup.sql (20 files; 21 with B4)');
  r := pg_temp.call(NULL, $q$SELECT erp.gl_setup('ZZ99')$q$, 'anon');
  PERFORM pg_temp.check(r->>'error' = '42501', 'anon can''t call the setup functions', r::text);
  r := pg_temp.call(fin, $q$WITH x AS (INSERT INTO erp.gl_determination_group (company_code, group_code, area, posting_key, acct_code) VALUES ('ZZ99', 102, 'inventory', 'cogs', '5100') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct writes to the override tables', r::text);
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.gl_determination_group$q$);
  PERFORM pg_temp.check(r::text = '0', 'non-finance users read no override rows', r::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE')),
                        'no SECURITY DEFINER function is executable by anon');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END || ' | ' || name || CASE WHEN ok THEN '' ELSE ' | ' || coalesce(detail, '') END AS result FROM b3_result ORDER BY n;
SELECT 'TOTAL | ' || count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' FROM b3_result;
ROLLBACK;
