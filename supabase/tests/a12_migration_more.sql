-- A12 · SAP migration completion tests. LOCAL STACK ONLY.
-- Run after base.txt (10–26 + test users) and 27_migration_more.sql, best on a FRESH rebuild. Everything runs in one
-- transaction that is rolled back. The raw SAP tables used here are minimal FIXTURES created inside the transaction
-- for two fictional test companies, ZZ98 and ZZ97 (no real data). Prints PASS/FAIL rows and a TOTAL row.
BEGIN;
SET LOCAL check_function_bodies = on;

CREATE TEMP TABLE a12_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a12_result TO authenticated, service_role;

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
  INSERT INTO a12_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 160)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 200))
$$;
-- open issues of a run in some areas: key -> severity
CREATE FUNCTION pg_temp.issues(p_run uuid, p_areas text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(jsonb_object_agg(issue_key, severity), '{}') FROM erp.migration_issue WHERE run_id = p_run AND status = 'open' AND area = ANY (p_areas)
$$;
CREATE FUNCTION pg_temp.failed(p_run uuid, p_areas text[]) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(area || ':' || check_name, '; '), '') FROM erp.migration_check WHERE run_id = p_run AND NOT ok AND area = ANY (p_areas)
$$;

-- ================= fixtures: companies, raw SAP copy (sap.*) and app rows (erp.*, source 'sap') =================
INSERT INTO sap._company (company_code, legal_name, country, currency, licence_type, sap_schema, in_scope)
VALUES ('ZZ98', 'Test Fixture Ninety-Eight (test data)', 'AE', 'AED', 'free_zone', 'SBO_ZZ98', false),
       ('ZZ97', 'Test Fixture Ninety-Seven (test data)', 'AE', 'AED', 'free_zone', 'SBO_ZZ97', false);
INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema)
VALUES ('ZZ98', 'Test Fixture Ninety-Eight (test data)', 'ZZ98', 'AE', 'AED', 'free_zone', 'SBO_ZZ98'),
       ('ZZ97', 'Test Fixture Ninety-Seven (test data)', 'ZZ97', 'AE', 'AED', 'free_zone', 'SBO_ZZ97');
INSERT INTO erp.user_company (user_id, company_code) SELECT u, c FROM unnest(ARRAY['00000000-0000-4000-8000-000000000001'::uuid,
  '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000023', '00000000-0000-4000-8000-000000000013']) u, unnest(ARRAY['ZZ98', 'ZZ97']) c
ON CONFLICT DO NOTHING;
INSERT INTO erp.admin_setting (company_code, owner_position) VALUES ('ZZ98', 'QA_OWNER') ON CONFLICT (company_code) DO UPDATE SET owner_position = 'QA_OWNER';

CREATE TABLE sap."OWHS" (company_code varchar(8), "WhsCode" varchar(8), "BalInvntAc" varchar(15));
CREATE TABLE sap."OITW" (company_code varchar(8), "ItemCode" varchar(50), "WhsCode" varchar(8), "OnHand" numeric, "AvgPrice" numeric);
CREATE TABLE sap."JDT1" (company_code varchar(8), "TransId" int, "Line_ID" int, "Account" varchar(15), "ShortName" varchar(15), "Debit" numeric, "Credit" numeric, "RefDate" timestamp);
CREATE TABLE sap."OCRD" (company_code varchar(8), "CardCode" varchar(15), "CardType" char(1), "Balance" numeric, "DebPayAcct" varchar(15),
                         "U_CTX_ICPC" varchar(100), "U_SFID" varchar(20), "U_Zzz" varchar(10), "UpdateDate" timestamp, "AtcEntry" int);
CREATE TABLE sap."OINV" (company_code varchar(8), "DocEntry" int, "ObjType" varchar(20), "CardCode" varchar(15), "DocTotal" numeric, "PaidToDate" numeric,
                         "CANCELED" char(1), "DocStatus" char(1), "AtcEntry" int);
CREATE TABLE sap."ORIN" (LIKE sap."OINV");
CREATE TABLE sap."OPCH" (LIKE sap."OINV");
CREATE TABLE sap."ORCT" (company_code varchar(8), "DocEntry" int, "CardCode" varchar(15), "OpenBal" numeric, "Canceled" char(1));
CREATE TABLE sap."ORDR" (company_code varchar(8), "DocEntry" int, "DocStatus" char(1), "CANCELED" char(1));
CREATE TABLE sap."RDR1" (company_code varchar(8), "DocEntry" int, "LineNum" int, "OpenQty" numeric, "Price" numeric, "DiscPrcnt" numeric, "LineStatus" char(1), "OpenSum" numeric);
CREATE TABLE sap."OPOR" (LIKE sap."ORDR");
CREATE TABLE sap."POR1" (LIKE sap."RDR1");
CREATE TABLE sap."OVTG" (company_code varchar(8), "Code" varchar(8), "Account" varchar(15), "Category" char(1));
CREATE TABLE sap."@ALT_HR_PRRT" (company_code varchar(8), "U_ALTINPRD" varchar(10), "U_ALTEMPID" varchar(20), "U_ALT1001" numeric, "U_ALT1002" numeric);
CREATE TABLE sap."ATC1" (company_code varchar(8), "AbsEntry" int, "Line" int, "srcPath" text, "trgtPath" text, "FileName" text, "FileExt" text);
CREATE TABLE sap."CUFD" (company_code varchar(8), "TableID" varchar(20), "FieldID" int, "AliasID" varchar(50), "Descr" text, "TypeID" char(1), "EditSize" int);
CREATE TABLE sap."OUTB" (company_code varchar(8), "TableName" varchar(20), "Descr" text);
CREATE TABLE sap."OSPP" (company_code varchar(8), "CardCode" varchar(15), "ItemCode" varchar(50), "Price" numeric, "Currency" varchar(3), "Discount" numeric,
                         "ListNum" int, "Valid" char(1), "ValidFrom" timestamp, "ValidTo" timestamp, "AutoUpdt" char(1));
CREATE TABLE sap."SPP1" (company_code varchar(8), "CardCode" varchar(15), "ItemCode" varchar(50), "LINENUM" int, "FromDate" timestamp, "ToDate" timestamp,
                         "Price" numeric, "Currency" varchar(3), "Discount" numeric, "ListNum" int);
CREATE TABLE sap."OEDG" (company_code varchar(8), "AbsEntry" int, "Type" char(1), "ObjType" varchar(20), "ObjCode" varchar(50), "DiscRel" char(1),
                         "ValidFor" char(1), "ValidFrom" timestamp, "ValidTo" timestamp);
CREATE TABLE sap."EDG1" (company_code varchar(8), "AbsEntry" int, "LineNum" int, "ObjType" int, "ObjKey" varchar(50), "DiscType" char(1),
                         "Discount" numeric, "PayFor" numeric, "ForFree" numeric, "UpTo" numeric);

INSERT INTO sap."OWHS" VALUES ('ZZ98', 'W1', '1300'), ('ZZ98', 'W2', '1300');
INSERT INTO sap."OITW" VALUES ('ZZ98', 'I1', 'W1', 10, 5), ('ZZ98', 'I2', 'W2', 4, 25);
INSERT INTO sap."JDT1" VALUES
  ('ZZ98', 1, 0, '1300', '1300', 150, 0, '2026-09-10'), ('ZZ98', 1, 1, '3000', '3000', 0, 150, '2026-09-10'),
  ('ZZ98', 2, 0, '1200', 'C1', 210, 0, '2026-10-05'), ('ZZ98', 2, 1, '4000', '4000', 0, 200, '2026-10-05'), ('ZZ98', 2, 2, '2200', '2200', 0, 10, '2026-10-05'),
  ('ZZ98', 3, 0, '5000', '5000', 100, 0, '2026-10-07'), ('ZZ98', 3, 1, '1400', '1400', 5, 0, '2026-10-07'), ('ZZ98', 3, 2, '2100', 'S1', 0, 105, '2026-10-07'),
  ('ZZ98', 4, 0, '1010', '1010', 50, 0, '2026-10-20'), ('ZZ98', 4, 1, '1200', 'C1', 0, 50, '2026-10-20'),
  ('ZZ98', 5, 0, '1010', '1010', 30, 0, '2026-10-25'), ('ZZ98', 5, 1, '1200', 'C2', 0, 30, '2026-10-25'),
  ('ZZ98', 6, 0, '1200', 'C3', 70, 0, '2026-10-26'), ('ZZ98', 6, 1, '4000', '4000', 0, 70, '2026-10-26'),
  ('ZZ98', 7, 0, '1200', 'C1', 100, 0, '2026-09-15'), ('ZZ98', 7, 1, '4000', '4000', 0, 100, '2026-09-15'),
  ('ZZ98', 8, 0, '1010', '1010', 100, 0, '2026-09-16'), ('ZZ98', 8, 1, '1200', 'C1', 0, 100, '2026-09-16'),
  ('ZZ97', 1, 0, '5000', '5000', 70, 0, '2026-10-26'), ('ZZ97', 1, 1, '2100', 'S9', 0, 70, '2026-10-26');
INSERT INTO sap."OCRD" VALUES
  ('ZZ98', 'C1', 'C', 160, '1200', NULL, 'SF-1', NULL, '2026-10-01', NULL), ('ZZ98', 'C2', 'C', -30, '1200', NULL, NULL, NULL, '2026-10-02', NULL),
  ('ZZ98', 'C3', 'C', 70, '1200', 'ZZ97', NULL, NULL, NULL, NULL), ('ZZ98', 'S1', 'S', -105, '2100', NULL, NULL, NULL, NULL, NULL),
  ('ZZ97', 'S9', 'S', -70, '2100', 'ZZ98', NULL, NULL, NULL, NULL);
INSERT INTO sap."OINV" VALUES ('ZZ98', 1, '13', 'C1', 210, 50, 'N', 'O', 7), ('ZZ98', 3, '13', 'C3', 70, 0, 'N', 'O', NULL), ('ZZ98', 5, '13', 'C1', 100, 100, 'N', 'C', NULL);
INSERT INTO sap."OPCH" VALUES ('ZZ98', 1, '18', 'S1', 105, 0, 'N', 'O', NULL);
INSERT INTO sap."ORCT" VALUES ('ZZ98', 1, 'C1', 0, 'N'), ('ZZ98', 2, 'C2', 30, 'N');
INSERT INTO sap."ORDR" VALUES ('ZZ98', 1, 'O', 'N'), ('ZZ98', 2, 'C', 'N');
INSERT INTO sap."RDR1" VALUES ('ZZ98', 1, 0, 4, 20, 10, 'O', 72), ('ZZ98', 1, 1, 0, 30, 0, 'C', 0), ('ZZ98', 2, 0, 9, 9, 0, 'C', 0);
INSERT INTO sap."OPOR" VALUES ('ZZ98', 1, 'O', 'N');
INSERT INTO sap."POR1" VALUES ('ZZ98', 1, 0, 5, 10, 0, 'O', 50);
INSERT INTO sap."OVTG" VALUES ('ZZ98', 'VO5', '2200', 'O'), ('ZZ98', 'VI5', '1400', 'I');
INSERT INTO sap."@ALT_HR_PRRT" VALUES ('ZZ98', '2026-10', 'E1', 1000, -100), ('ZZ98', '2026-10', 'E2', 800, NULL), ('ZZ98', '2026-09', 'E1', 900, NULL);
INSERT INTO sap."ATC1" VALUES ('ZZ98', 7, 1, NULL, '\\sapsrv\Attachments', 'contract', 'pdf'), ('ZZ98', 7, 2, NULL, '\\sapsrv\Attachments', 'scan', 'jpg');
INSERT INTO sap."CUFD" VALUES ('ZZ98', 'OCRD', 1, 'SFID', 'Salesforce ID', 'A', 20), ('ZZ98', 'OCRD', 2, 'Zzz', 'Old flag', 'A', 10);
INSERT INTO sap."OUTB" VALUES ('ZZ98', 'TRADEMARK', 'Trademark master');
INSERT INTO sap."OSPP" VALUES ('ZZ98', 'C1', 'I1', 9.5, 'AED', 5, 1, 'Y', NULL, NULL, 'N');
INSERT INTO sap."SPP1" VALUES ('ZZ98', 'C1', 'I1', 0, '2026-11-01', '2026-11-30', 9, 'AED', 10, 1);
INSERT INTO sap."OEDG" VALUES ('ZZ98', 1, 'A', '-1', NULL, 'L', 'Y', '2026-01-01', '2026-12-31');
INSERT INTO sap."EDG1" VALUES ('ZZ98', 1, 0, 4, 'I1', 'D', 10, NULL, NULL, NULL);

DO $$ BEGIN PERFORM set_config('erp.sync', 'on', true); END $$;
INSERT INTO erp.account (company_code, acct_code, name, postable, source)
SELECT 'ZZ98', a, 'Test account ' || a, true, 'sap' FROM unnest(ARRAY['1010', '1200', '1300', '1400', '2100', '2200', '3000', '4000', '5000']) a;
INSERT INTO erp.account (company_code, acct_code, name, postable, source) VALUES ('ZZ98', '3990', 'Opening balance clearing (test)', true, 'sap'),
  ('ZZ97', '2100', 'Test A/P', true, 'sap'), ('ZZ97', '5000', 'Test cost', true, 'sap');
INSERT INTO erp.business_partner (company_code, card_code, kind, name, ic_partner_company, trn, phone, source) VALUES
  ('ZZ98', 'C1', 'customer', 'Alpha Trading L.L.C.', NULL, '100000000000003', '+971 50 123 4567', 'sap'),
  ('ZZ98', 'C2', 'customer', 'ALPHA TRADING LLC', NULL, '100-0000-0000-0003', '050 1234567', 'sap'),
  ('ZZ98', 'C3', 'customer', 'Sister Company ZZ97 (test)', 'ZZ97', NULL, NULL, 'sap'),
  ('ZZ98', 'S1', 'supplier', 'Test Supplier One', NULL, NULL, NULL, 'sap'),
  ('ZZ97', 'S9', 'supplier', 'Sister Company ZZ98 (test)', 'ZZ98', NULL, NULL, 'sap');
INSERT INTO erp.warehouse (company_code, whs_code, name) VALUES ('ZZ98', 'W1', 'Test W1'), ('ZZ98', 'W2', 'Test W2');
INSERT INTO erp.item (company_code, item_code, name, barcode, preferred_supplier, supplier_part_no, source) VALUES
  ('ZZ98', 'I1', 'Test kettle', '6291234', 'S1', 'P-1', 'sap'), ('ZZ98', 'I2', 'Test kettle (copy)', '6291234', 'S1', 'P-1', 'sap');
INSERT INTO erp.stock_balance (company_code, item_code, whs_code, on_hand, avg_cost) VALUES ('ZZ98', 'I1', 'W1', 10, 5), ('ZZ98', 'I2', 'W2', 4, 25);
INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, total, paid, source) VALUES
  ('ZZ98', 13, 1, 1, 'I', 'open', '2026-10-05', 'C1', 210, 50, 'sap'), ('ZZ98', 13, 3, 3, 'I', 'open', '2026-10-26', 'C3', 70, 0, 'sap'),
  ('ZZ98', 13, 5, 5, 'I', 'closed', '2026-09-15', 'C1', 100, 100, 'sap'), ('ZZ98', 18, 1, 1, 'I', 'open', '2026-10-07', 'S1', 105, 0, 'sap'),
  ('ZZ98', 17, 1, 1, 'I', 'open', '2026-10-01', 'C1', 100, 0, 'sap'), ('ZZ98', 17, 2, 2, 'I', 'closed', '2026-09-01', 'C1', 81, 0, 'sap'),
  ('ZZ98', 22, 1, 1, 'I', 'open', '2026-10-01', 'S1', 50, 0, 'sap');
INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, discount_pct, line_status) VALUES
  ('ZZ98', 17, 1, 0, 'I1', 10, 4, 20, 10, 'O'), ('ZZ98', 17, 1, 1, 'I2', 5, 0, 30, 0, 'C'), ('ZZ98', 17, 2, 0, 'I1', 9, 9, 9, 0, 'C'),
  ('ZZ98', 22, 1, 0, 'I1', 5, 5, 10, 0, 'O');
INSERT INTO erp.journal_entry (company_code, trans_id, ref_date, source)
SELECT DISTINCT company_code, "TransId", "RefDate"::date, 'sap' FROM sap."JDT1";
INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, ref_date)
SELECT company_code, "TransId", "Line_ID", "Account", "ShortName", "Debit", "Credit", "RefDate"::date FROM sap."JDT1";
INSERT INTO erp.payroll_result (company_code, period, hr_code, wage_code, amount) VALUES
  ('ZZ98', '2026-10', 'E1', '1001', 1000), ('ZZ98', '2026-10', 'E1', '1002', -100), ('ZZ98', '2026-10', 'E2', '1001', 800), ('ZZ98', '2026-09', 'E1', '1001', 900);
DO $$ BEGIN PERFORM set_config('erp.sync', 'off', true); END $$;
INSERT INTO erp.migration_run (run_id, company_code, kind, status) VALUES
  ('a1200000-0000-4000-8000-000000000001', 'ZZ98', 'full', 'needs_review'),
  ('a1200000-0000-4000-8000-000000000002', 'ZZ98', 'opening_only', 'needs_review');

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
 it     uuid := '00000000-0000-4000-8000-000000000023';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  run    uuid := 'a1200000-0000-4000-8000-000000000001';
  orun   uuid := 'a1200000-0000-4000-8000-000000000002';
  recon  text[] := ARRAY['inventory_gl', 'partners', 'open_orders', 'vat', 'intercompany', 'payroll'];
  r jsonb; i jsonb; n bigint; v text;
BEGIN
  -- ---------- 1. settings and run kind ----------
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_request(''ZZ98'', ''opening_only'', NULL))'),
    'An opening-balances-only run needs the opening date and the clearing account of ZZ98. Enter them under Opening balances first.', 'opening_only run refused without settings');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_request(''ZZ98'', ''everything'', NULL))'),
    'kind must be full, tables, structure_only or opening_only', 'unknown run kind refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT to_jsonb(erp.migration_setting_save(''ZZ98'', ''{"opening_date":"2026-10-31"}''))'),
    'Only admin or IT positions can change migration settings.', 'sales cannot change migration settings');
  PERFORM pg_temp.expect(pg_temp.call(it, 'SELECT to_jsonb(erp.migration_setting_save(''ZZ98'', ''{"opening_clearing_acct":"3990"}''))'),
    'Changing the opening clearing account also needs Financials full access.', 'IT cannot set the clearing account without Financials');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_setting_save(''ZZ98'', ''{"opening_clearing_acct":"9999"}''))'),
    'Account 9999 is not in the chart of accounts of ZZ98.', 'unknown clearing account refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_setting_save(''ZZ98'', ''{"vat_period_from":"2026-10-01"}''))'),
    'Enter both the start and the end of the VAT period, or neither.', 'one-sided VAT period refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_setting_save(''ZZ98'', ''{"vat_period_from":"2026-10-31","vat_period_to":"2026-10-01"}''))'),
    'The VAT period start must be on or before its end.', 'reversed VAT period refused');
  r := pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_setting_save(''ZZ98'', ''{"opening_date":"2026-10-31","opening_clearing_acct":"3990","net_pay_wage_codes":["1001"," 1002 ",""]}''))');
  PERFORM pg_temp.check(r->>'opening_clearing_acct' = '3990' AND r->'net_pay_wage_codes' = '["1001","1002"]', 'admin saves opening date, clearing account and wage codes', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'migration_setting_save' AND company_code = 'ZZ98'), 'settings change audited', '');
  PERFORM pg_temp.check((pg_temp.call(stock, 'SELECT to_jsonb(count(*)) FROM erp.migration_setting'))::text = '0', 'a user who is neither admin/IT nor a sign-off role cannot read migration settings', '');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.migration_setting'))::text = '1', 'business sign-off users (sales) can read them', '');
  r := pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_request(''ZZ98'', ''opening_only'', ''A12 test''))');
  PERFORM pg_temp.check(r->>'error' IS NULL AND EXISTS (SELECT 1 FROM erp.migration_run WHERE run_id = (r#>>'{}')::uuid AND kind = 'opening_only'),
    'opening_only run accepted once the settings exist', r::text);
  DELETE FROM erp.migration_run WHERE run_id = (r#>>'{}')::uuid;

  -- ---------- 2. reconciliation checks on good data ----------
  PERFORM pg_temp.check((pg_temp.call(admin, 'SELECT to_jsonb(erp.migration_more_checks(''ZZ98'', ''a1200000-0000-4000-8000-000000000001''))'))->>'error' = '42501',
    'browser users cannot run the checks (service role only)', '');
  PERFORM erp.migration_more_checks('ZZ98', run);
  v := pg_temp.failed(run, recon);
  PERFORM pg_temp.check(v = '', 'good data: every check 5.3, 5.5-5.9 passes', v);
  i := pg_temp.issues(run, recon);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_each_text(i) WHERE value = 'critical'), 'good data: no critical issue', i::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.migration_check WHERE run_id = run AND area = ANY (recon)) >= 18, 'checks written with SAP / raw / app values',
    (SELECT count(*) FROM erp.migration_check WHERE run_id = run AND area = ANY (recon))::text);
  PERFORM pg_temp.check((SELECT sap_value = 150 AND raw_value = 150 AND app_value = 150 AND difference = 0 FROM erp.migration_check WHERE run_id = run AND check_name = 'inventory value = G/L 1300'),
    '5.3 inventory 1300: G/L 150 = stock 150 (SAP and app)', '');
  PERFORM pg_temp.check((SELECT sap_value = 200 AND raw_value = 200 AND app_value = 200 FROM erp.migration_check WHERE run_id = run AND check_name = 'A/R control accounts = open customer items'),
    '5.5 A/R control account = open customer items (200)', '');
  PERFORM pg_temp.check((SELECT sap_value = -105 AND raw_value = -105 FROM erp.migration_check WHERE run_id = run AND check_name = 'A/P control accounts = open supplier items'),
    '5.5 A/P control account = open supplier items (-105)', '');
  PERFORM pg_temp.check((SELECT raw_value = 72 AND app_value = 72 AND sap_value = 72 FROM erp.migration_check WHERE run_id = run AND check_name = 'open sales orders: open value'),
    '5.6 open sales order value 72 (open qty x price x discount = OpenSum)', '');
  PERFORM pg_temp.check((SELECT raw_value = 4 FROM erp.migration_check WHERE run_id = run AND check_name = 'open sales orders: open quantity'), '5.6 closed lines not counted', '');
  PERFORM pg_temp.check((SELECT raw_value = 10 AND app_value = 10 FROM erp.migration_check WHERE run_id = run AND check_name = 'VAT payable 2200 2026-10-01..2026-10-31'),
    '5.7 VAT payable for the last month with postings', '');
  PERFORM pg_temp.check((SELECT raw_value = 5 FROM erp.migration_check WHERE run_id = run AND check_name = 'VAT recoverable, last open period'), '5.7 VAT recoverable total', '');
  PERFORM pg_temp.check((SELECT raw_value = 0 AND app_value = 0 AND detail ? 'ZZ98->ZZ97' FROM erp.migration_check WHERE run_id = run AND check_name = 'intercompany ZZ97 / ZZ98'),
    '5.8 intercompany ZZ98/ZZ97 nets to zero', '');
  PERFORM pg_temp.check((SELECT raw_value = 1700 AND app_value = 1700 FROM erp.migration_check WHERE run_id = run AND check_name = 'net pay 2026-10'),
    '5.9 net pay of the last period with the configured wage codes', '');
  PERFORM pg_temp.check((SELECT raw_value = 2 AND app_value = 2 FROM erp.migration_check WHERE run_id = run AND check_name = 'employees paid 2026-10'), '5.9 employees paid', '');

  -- ---------- 3. planted errors are caught ----------
  UPDATE erp.stock_balance SET avg_cost = 6 WHERE company_code = 'ZZ98' AND item_code = 'I1';
  UPDATE erp.document SET paid = 60 WHERE company_code = 'ZZ98' AND obj_type = 13 AND doc_entry = 1;
  UPDATE erp.document_line SET open_qty = 3 WHERE company_code = 'ZZ98' AND obj_type = 17 AND doc_entry = 1 AND line_num = 0;
  PERFORM set_config('erp.sync', 'on', true);
  UPDATE erp.journal_line SET credit = 11 WHERE company_code = 'ZZ98' AND trans_id = 2 AND line_id = 2;
  UPDATE erp.journal_line SET credit = 199 WHERE company_code = 'ZZ98' AND trans_id = 2 AND line_id = 1;
  PERFORM set_config('erp.sync', 'off', true);
  UPDATE sap."JDT1" SET "Credit" = 60 WHERE company_code = 'ZZ97' AND "TransId" = 1 AND "Line_ID" = 1;
  UPDATE sap."JDT1" SET "Debit" = 60 WHERE company_code = 'ZZ97' AND "TransId" = 1 AND "Line_ID" = 0;
  UPDATE erp.payroll_result SET amount = 700 WHERE company_code = 'ZZ98' AND period = '2026-10' AND hr_code = 'E2';
  PERFORM erp.migration_more_checks('ZZ98', run);
  i := pg_temp.issues(run, recon);
  PERFORM pg_temp.check(i->>'invgl:ZZ98:1300' = 'critical', 'planted stock cost error caught by 5.3', i::text);
  PERFORM pg_temp.check(i->>'bp:ZZ98:C1' = 'critical' AND i->>'ctl:ZZ98:C' IS NULL, 'planted paid amount caught per partner by 5.5', '');
  PERFORM pg_temp.check((SELECT NOT ok AND raw_value = 160 AND app_value = 150 FROM erp.migration_check WHERE run_id = run AND check_name = 'partner balance C1'),
    '5.5 partner row shows SAP 160 vs app 150', '');
  PERFORM pg_temp.check(i->>'oo:ZZ98:17' = 'critical' AND i->>'oo:ZZ98:22' IS NULL, 'planted open quantity caught by 5.6 (sales only)', '');
  PERFORM pg_temp.check(i->>'vat:ZZ98:O:2200' = 'critical' AND i->>'vat:ZZ98:I:1400' IS NULL, 'planted VAT difference caught by 5.7', '');
  PERFORM pg_temp.check(i->>'ic:ZZ98:ZZ97' = 'critical', 'planted intercompany difference caught by 5.8', '');
  PERFORM pg_temp.check(i->>'payroll:ZZ98:2026-10' = 'critical', 'planted net pay difference caught by 5.9', '');
  PERFORM pg_temp.check((SELECT raw_value = 10 AND app_value = 0 AND NOT ok FROM erp.migration_check WHERE run_id = run AND check_name = 'intercompany ZZ97 / ZZ98'), 'intercompany row shows SAP net 10 vs app 0', '');
  -- fix and re-check: the issues close themselves
  UPDATE erp.stock_balance SET avg_cost = 5 WHERE company_code = 'ZZ98' AND item_code = 'I1';
  UPDATE erp.payroll_result SET amount = 800 WHERE company_code = 'ZZ98' AND period = '2026-10' AND hr_code = 'E2';
  PERFORM erp.migration_more_checks('ZZ98', run);
  PERFORM pg_temp.check((SELECT status FROM erp.migration_issue WHERE run_id = run AND issue_key = 'invgl:ZZ98:1300') = 'fixed'
                        AND (SELECT status FROM erp.migration_issue WHERE run_id = run AND issue_key = 'payroll:ZZ98:2026-10') = 'fixed'
                        AND (SELECT status FROM erp.migration_issue WHERE run_id = run AND issue_key = 'bp:ZZ98:C1') = 'open',
    're-check marks fixed issues fixed and keeps the rest open', '');
  UPDATE erp.document SET paid = 50 WHERE company_code = 'ZZ98' AND obj_type = 13 AND doc_entry = 1;
  PERFORM set_config('erp.sync', 'on', true);
  UPDATE erp.journal_line SET credit = 10 WHERE company_code = 'ZZ98' AND trans_id = 2 AND line_id = 2;
  UPDATE erp.journal_line SET credit = 200 WHERE company_code = 'ZZ98' AND trans_id = 2 AND line_id = 1;
  PERFORM set_config('erp.sync', 'off', true);
  UPDATE erp.document_line SET open_qty = 4 WHERE company_code = 'ZZ98' AND obj_type = 17 AND doc_entry = 1 AND line_num = 0;
  UPDATE sap."JDT1" SET "Credit" = 70 WHERE company_code = 'ZZ97' AND "TransId" = 1 AND "Line_ID" = 1;
  UPDATE sap."JDT1" SET "Debit" = 70 WHERE company_code = 'ZZ97' AND "TransId" = 1 AND "Line_ID" = 0;
  -- a warehouse without an inventory account
  INSERT INTO sap."OWHS" VALUES ('ZZ98', 'W3', NULL);
  INSERT INTO sap."OITW" VALUES ('ZZ98', 'I1', 'W3', 1, 5);
  PERFORM erp.migration_more_checks('ZZ98', run);
  i := pg_temp.issues(run, recon);
  PERFORM pg_temp.check(i->>'invgl_noacct:ZZ98' = 'critical', 'warehouse without inventory account reported', i::text);
  DELETE FROM sap."OITW" WHERE "WhsCode" = 'W3'; DELETE FROM sap."OWHS" WHERE "WhsCode" = 'W3';

  -- missing raw table: the check is skipped with an info issue, never an error
  ALTER TABLE sap."OVTG" RENAME TO "OVTG_hidden";
  PERFORM erp.migration_more_checks('ZZ98', run);
  PERFORM pg_temp.check((SELECT ok AND detail->>'skipped' = 'true' FROM erp.migration_check WHERE run_id = run AND area = 'vat' AND check_name = 'VAT accounts, last open period')
                        AND (SELECT severity FROM erp.migration_issue WHERE run_id = run AND issue_key = 'skip:ZZ98:vat:VAT accounts, last open period') = 'info',
    'table missing from the SAP copy: check skipped with an info issue', '');
  ALTER TABLE sap."OVTG_hidden" RENAME TO "OVTG";
  PERFORM erp.migration_more_checks('ZZ98', run);
  PERFORM pg_temp.check((SELECT status FROM erp.migration_issue WHERE run_id = run AND issue_key = 'skip:ZZ98:vat:VAT accounts, last open period') = 'fixed'
                        AND pg_temp.failed(run, recon) = '', 'all checks pass again after the fixes', pg_temp.failed(run, recon));

  -- ---------- 4. duplicates (warnings, no merge) ----------
  i := pg_temp.issues(run, ARRAY['duplicates']);
  PERFORM pg_temp.check(i->>'dup:ZZ98:bp:TRN:customer:100000000000003' = 'warning', 'planted pair found by TRN', i::text);
  PERFORM pg_temp.check(i->>'dup:ZZ98:bp:phone:customer:501234567' = 'warning', 'planted pair found by phone', '');
  PERFORM pg_temp.check(i->>'dup:ZZ98:bp:name:customer:alphatrading' = 'warning', 'planted pair found by normalised name', '');
  PERFORM pg_temp.check(i->>'dup:ZZ98:item:barcode:6291234' = 'warning' AND i->>'dup:ZZ98:item:supplier part number:S1:P-1' = 'warning',
    'items found by barcode and by supplier part number', '');
  PERFORM pg_temp.check((SELECT count(*) FROM jsonb_each_text(i)) = 5 AND NOT EXISTS (SELECT 1 FROM jsonb_each_text(i) WHERE value <> 'warning'),
    'exactly five duplicate warnings, all warnings', (SELECT count(*) FROM jsonb_each_text(i))::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.business_partner WHERE company_code = 'ZZ98' AND card_code IN ('C1', 'C2')) = 2, 'duplicates are never merged', '');
  PERFORM pg_temp.check((SELECT detail FROM erp.migration_issue WHERE run_id = run AND issue_key = 'dup:ZZ98:bp:TRN:customer:100000000000003') LIKE '%Not merged%', 'warning says it was not merged', '');

  -- ---------- 5. attachments 5.10 ----------
  i := pg_temp.issues(run, ARRAY['attachments']);
  PERFORM pg_temp.check(i->>'att_notrun:ZZ98' = 'warning', 'attachment copy not run yet: warning', i::text);
  INSERT INTO erp.migration_attachment (run_id, company_code, abs_entry, line, obj_type, doc_key, file_name, source_path, storage_path, bytes, sha256, status)
  VALUES (run, 'ZZ98', 7, 1, '13', '1', 'contract.pdf', '/mnt/sap/contract.pdf', 'attachments/ZZ98/13/1/contract.pdf', 1234, repeat('a', 64), 'copied'),
         (run, 'ZZ98', 7, 2, '13', '1', 'scan.jpg', '/mnt/sap/scan.jpg', NULL, NULL, NULL, 'missing');
  PERFORM erp.migration_attachment_check(run, 'ZZ98');
  i := pg_temp.issues(run, ARRAY['attachments']);
  PERFORM pg_temp.check(i->>'att_missing:ZZ98' = 'critical' AND i->>'att_notrun:ZZ98' IS NULL, 'missing attachment file reported (critical)', i::text);
  PERFORM pg_temp.check((SELECT sap_value = 2 AND raw_value = 1 AND app_value = 1 AND NOT ok FROM erp.migration_check WHERE run_id = run AND check_name = 'attachment files (ATC1 -> Storage)'),
    '5.10 listed 2, found 1, copied 1', '');
  PERFORM pg_temp.check((SELECT detail FROM erp.migration_issue WHERE run_id = run AND issue_key = 'att_missing:ZZ98') LIKE '%/mnt/sap/scan.jpg%', 'missing file path named', '');
  r := pg_temp.call(NULL, 'SELECT jsonb_agg(to_jsonb(x)) FROM erp.migration_attachment_list(''ZZ98'') x', 'service_role');
  PERFORM pg_temp.check(r->0->>'obj_type' = '13' AND r->0->>'doc_key' = '1' AND r->1->>'file_name' = 'scan', 'ATC1 rows linked to their document (AtcEntry)', left(r::text, 200));

  -- ---------- 6. custom-field register ----------
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT to_jsonb(erp.custom_field_register_build(''ZZ98''))'),
    'Only admin or IT positions can rebuild the custom-field register.', 'sales cannot build the register');
  r := pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_register_build(''ZZ98''))');
  PERFORM pg_temp.check((r#>>'{}')::int = 3, 'register built from CUFD/OUTB: 2 fields + 1 user table', r::text);
  PERFORM pg_temp.check((SELECT decision = 'mapped' AND target = 'erp.business_partner.salesforce_id' AND rows_used = 1 AND last_used = '2026-10-01' AND in_raw
                           FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND field_name = 'U_SFID'),
    'U_SFID mapped from the sync code, 1 row uses it, last used 01 Oct', '');
  PERFORM pg_temp.check((SELECT decision = 'raw_only' AND rows_used = 0 FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND field_name = 'U_Zzz'),
    'unused U_Zzz suggested raw_only with 0 rows', '');
  PERFORM pg_temp.check((SELECT decision = 'mapped' AND target = 'erp.trademark' AND kind = 'table' AND NOT in_raw FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND table_name = '@TRADEMARK'),
    '@TRADEMARK user table mapped to erp.trademark', '');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.custom_field_register'))::text = '0', 'sales cannot read the register', '');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', ''drop''))'),
    'Only admin or IT positions can change the custom-field register.', 'sales cannot decide');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', ''mapped''))'),
    'A mapped field needs a target column, for example erp.business_partner.salesforce_id.', 'mapped needs a target');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', ''mapped'', ''erp.business_partner.nope''))'),
    'Target erp.business_partner.nope does not exist. Use erp.<table>.<column>.', 'unknown target refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Nope"}]'', ''raw_only''))'),
    'Field OCRD.U_Nope is not on the register of ZZ98.', 'unknown field refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[]'', ''raw_only''))'), 'Pick at least one field.', 'empty selection refused');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', ''drop'', NULL, ''never used''))'),
    'admin proposes dropping U_Zzz');
  PERFORM pg_temp.check((SELECT drop_state FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND field_name = 'U_Zzz') = 'pending', 'drop waits for the owner', '');
  PERFORM erp._mc_custom_fields(run, 'ZZ98');
  PERFORM pg_temp.check((SELECT severity FROM erp.migration_issue WHERE run_id = run AND issue_key = 'cf_pending:ZZ98') = 'warning', 'pending drop shown as a warning on the run', '');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_drop_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', true))'),
    'Only the owner position of ZZ98 can approve dropping custom fields.', 'admin cannot approve a drop');
  PERFORM pg_temp.expect(pg_temp.call(owner, 'SELECT to_jsonb(erp.custom_field_drop_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_SFID"}]'', true))'),
    'Field OCRD.U_SFID is not waiting for a drop approval.', 'only proposed drops can be approved');
  PERFORM pg_temp.expect(pg_temp.call(owner, 'SELECT to_jsonb(erp.custom_field_drop_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', false))'),
    'Say why the drop is rejected.', 'reject needs a reason');
  PERFORM pg_temp.check((pg_temp.call(owner, 'SELECT to_jsonb(count(*)) FROM erp.custom_field_register WHERE company_code = ''ZZ98'''))::text = '3', 'owner can read the register', '');
  r := pg_temp.call(owner, 'SELECT erp.custom_field_setup(''ZZ98'')');
  PERFORM pg_temp.check((r->>'can_approve_drop')::boolean AND NOT (r->>'can_edit')::boolean AND (r#>>'{summary,drop_pending}')::int = 1, 'setup tells the owner what they can do', r::text);
  PERFORM pg_temp.ok(pg_temp.call(owner, 'SELECT to_jsonb(erp.custom_field_drop_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_Zzz"}]'', true, ''ok to drop''))'), 'owner approves the drop');
  PERFORM pg_temp.check((SELECT decision = 'drop' AND drop_state = 'approved' AND drop_decided_by = owner FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND field_name = 'U_Zzz'),
    'drop approved by the owner', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'custom_field_drop_approve' AND company_code = 'ZZ98'), 'drop approval audited', '');
  PERFORM pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_register_build(''ZZ98''))');
  PERFORM pg_temp.check((SELECT decision = 'drop' AND drop_state = 'approved' FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND field_name = 'U_Zzz'),
    'rebuilding the register keeps decisions', '');
  PERFORM pg_temp.call(admin, 'SELECT to_jsonb(erp.custom_field_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_SFID"}]'', ''drop''))');
  PERFORM pg_temp.ok(pg_temp.call(owner, 'SELECT to_jsonb(erp.custom_field_drop_decide(''ZZ98'', ''[{"table":"OCRD","field":"U_SFID"}]'', false, ''still used''))'), 'owner rejects a drop');
  PERFORM pg_temp.check((SELECT decision = 'raw_only' AND drop_state = 'rejected' FROM erp.custom_field_register WHERE company_code = 'ZZ98' AND field_name = 'U_SFID'),
    'rejected drop goes back to raw_only', '');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.custom_field_setup(''ZZ98'')'), 'You don''t have access to this.', 'sales cannot open the register setup');

  -- ---------- 7. coexistence: the sync never overwrites Super ERP rows ----------
  INSERT INTO erp.business_partner (company_code, card_code, kind, name, source) VALUES ('ZZ98', 'C9', 'customer', 'Made in Super ERP', 'erp');
  INSERT INTO erp.item (company_code, item_code, name, source) VALUES ('ZZ98', 'IE', 'ERP item', 'erp');
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, total, paid, source)
  VALUES ('ZZ98', 13, 900000001, 900000001, 'I', 'open', '2026-10-30', 'C9', 99, 0, 'erp');
  PERFORM set_config('erp.sync', 'on', true);
  INSERT INTO erp.business_partner AS t (company_code, card_code, kind, name, source) VALUES ('ZZ98', 'C9', 'customer', 'SAP overwrite', 'sap'), ('ZZ98', 'C1', 'customer', 'Alpha Trading L.L.C. (renamed in SAP)', 'sap')
  ON CONFLICT (company_code, card_code) DO UPDATE SET name = EXCLUDED.name, source = EXCLUDED.source;
  INSERT INTO erp.document AS t (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, total, paid, source)
  VALUES ('ZZ98', 13, 900000001, 7, 'I', 'closed', '2026-10-30', 'C1', 1, 1, 'sap')
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET total = EXCLUDED.total, status = EXCLUDED.status, source = EXCLUDED.source;
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity) VALUES ('ZZ98', 13, 900000001, 0, 'I1', 1);
  UPDATE erp.document SET paid = 99 WHERE company_code = 'ZZ98' AND obj_type = 13 AND doc_entry = 900000001;
  INSERT INTO erp.stock_balance (company_code, item_code, whs_code, on_hand) VALUES ('ZZ98', 'IE', 'W1', 500)
  ON CONFLICT (company_code, item_code, whs_code) DO UPDATE SET on_hand = EXCLUDED.on_hand;
  INSERT INTO erp.item AS t (company_code, item_code, name, source) VALUES ('ZZ98', 'IE', 'SAP item', 'sap')
  ON CONFLICT (company_code, item_code) DO UPDATE SET name = EXCLUDED.name, source = EXCLUDED.source;
  PERFORM set_config('erp.sync', 'off', true);
  PERFORM pg_temp.check((SELECT name = 'Made in Super ERP' AND source = 'erp' FROM erp.business_partner WHERE company_code = 'ZZ98' AND card_code = 'C9'),
    'sync does not overwrite a Super ERP partner', '');
  PERFORM pg_temp.check((SELECT name LIKE '%renamed in SAP%' FROM erp.business_partner WHERE company_code = 'ZZ98' AND card_code = 'C1'), 'sync still updates SAP partners', '');
  PERFORM pg_temp.check((SELECT total = 99 AND paid = 0 AND status = 'open' AND source = 'erp' FROM erp.document WHERE company_code = 'ZZ98' AND obj_type = 13 AND doc_entry = 900000001),
    'sync does not overwrite or update a Super ERP document', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = 'ZZ98' AND doc_entry = 900000001), 'SAP lines are not added to a Super ERP document', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.stock_balance WHERE company_code = 'ZZ98' AND item_code = 'IE') AND (SELECT name FROM erp.item WHERE company_code = 'ZZ98' AND item_code = 'IE') = 'ERP item',
    'SAP stock and item rows skip a Super ERP item', '');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.sync_conflict WHERE company_code = 'ZZ98') >= 4
                        AND EXISTS (SELECT 1 FROM erp.sync_conflict WHERE company_code = 'ZZ98' AND table_name = 'business_partner' AND row_key = 'C9' AND owner_source = 'erp'),
    'every skipped SAP row logged in sync_conflict', (SELECT string_agg(table_name || ':' || row_key, ', ') FROM erp.sync_conflict WHERE company_code = 'ZZ98'));
  UPDATE erp.document SET paid = 10 WHERE company_code = 'ZZ98' AND obj_type = 13 AND doc_entry = 900000001;
  PERFORM pg_temp.check((SELECT paid FROM erp.document WHERE company_code = 'ZZ98' AND doc_entry = 900000001) = 10, 'outside the sync Super ERP rows change normally', '');
  PERFORM erp.migration_more_checks('ZZ98', run);
  i := pg_temp.issues(run, ARRAY['coexistence']);
  PERFORM pg_temp.check(i->>'coexist:ZZ98:business_partner' = 'warning' AND i->>'coexist:ZZ98:document' = 'warning', 'cross-check lists the skipped SAP rows as warnings', i::text);
  DELETE FROM erp.document WHERE company_code = 'ZZ98' AND doc_entry = 900000001;
  DELETE FROM erp.business_partner WHERE company_code = 'ZZ98' AND card_code = 'C9';
  DELETE FROM erp.item WHERE company_code = 'ZZ98' AND item_code = 'IE';
  DELETE FROM erp.sync_conflict WHERE company_code = 'ZZ98';

  -- ---------- 8. special prices ----------
  PERFORM pg_temp.check(erp.sync_special_prices('ZZ98') = 1 AND erp.sync_special_price_periods('ZZ98') = 1 AND erp.sync_discount_groups('ZZ98') = 1
                        AND erp.sync_discount_group_lines('ZZ98') = 1, 'special prices, periods, discount groups and lines synced', '');
  PERFORM pg_temp.check(erp.sync_special_prices('ZZ98') = 0 AND erp.sync_special_price_periods('ZZ98') = 0 AND erp.sync_discount_groups('ZZ98') = 0
                        AND erp.sync_discount_group_lines('ZZ98') = 0, 'second sync writes 0 rows', '');
  PERFORM pg_temp.check((SELECT price = 9.5 AND discount_pct = 5 AND valid AND NOT auto_update FROM erp.special_price WHERE company_code = 'ZZ98'), 'OSPP values mapped', '');
  PERFORM pg_temp.check(position('sync_special_prices' IN (SELECT prosrc FROM pg_proc WHERE oid = 'erp.sync_company(varchar)'::regprocedure)) > 0,
    'sync_company runs the new steps (and so does migration_sync_company)', '');
  r := pg_temp.call(admin, 'SELECT jsonb_agg(to_jsonb(x)) FROM erp.special_price_list x WHERE company_code = ''ZZ98''');
  PERFORM pg_temp.check(r->0->>'card_name' LIKE 'Alpha%' AND (r->0->>'periods')::int = 1, 'special price list shows partner, item and periods', left(r::text, 200));
  PERFORM pg_temp.check((pg_temp.call(it, 'SELECT to_jsonb(count(*)) FROM erp.special_price_list'))::text = '0', 'IT-only user does not see prices', '');
  ALTER TABLE sap."OSPP" RENAME TO "OSPP_hidden";
  PERFORM pg_temp.check(erp.sync_special_prices('ZZ98') = 0, 'OSPP missing from the SAP copy: step writes 0 rows', '');
  ALTER TABLE sap."OSPP_hidden" RENAME TO "OSPP";

  -- ---------- 9. opening-balances-only loader ----------
  PERFORM pg_temp.check((pg_temp.call(NULL, 'SELECT erp.migration_opening_apply(''ZZ97'', ''a1200000-0000-4000-8000-000000000002'')', 'service_role'))->>'message'
                        = 'An opening-balances-only run needs the opening date and the clearing account of ZZ97. Enter them under Opening balances first.',
    'opening loader refuses a company without settings', '');
  PERFORM pg_temp.check((pg_temp.call(admin, 'SELECT erp.migration_opening_apply(''ZZ98'', ''a1200000-0000-4000-8000-000000000002'')'))->>'error' = '42501',
    'browser users cannot run the opening loader', '');
  r := erp.migration_opening_apply('ZZ98', orun);
  PERFORM pg_temp.check((r->>'remainder')::numeric = 0 AND (r->>'debit')::numeric = (r->>'credit')::numeric AND (r->>'accounts_differing')::int = 0,
    'opening journal balances, clearing remainder 0, every account = SAP trial balance', r::text);
  PERFORM pg_temp.check((r->>'closed_removed')::int = 2 AND (r->>'journals_replaced')::int = 8 AND (r->>'open_documents')::int = 5,
    'closed documents removed, 8 SAP journals replaced, 5 open documents kept', r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.journal_entry WHERE company_code = 'ZZ98') = 1
                        AND (SELECT sum(debit) FROM erp.journal_line WHERE company_code = 'ZZ98' AND acct_code = '1200' AND short_name = 'C1') = 160,
    'one opening journal; A/R posted per partner (C1 160)', '');
  PERFORM pg_temp.check((SELECT sum(debit - credit) FROM erp.journal_line WHERE company_code = 'ZZ98' AND acct_code = '1300') = 150, 'inventory account at the stock value', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_line WHERE company_code = 'ZZ98' AND acct_code = '3990'), 'no clearing line when everything ties', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.migration_check WHERE run_id = orun AND area = 'opening' AND NOT ok), 'opening checks pass', pg_temp.failed(orun, ARRAY['opening']));
  UPDATE erp.document SET paid = 10 WHERE company_code = 'ZZ98' AND obj_type = 13 AND doc_entry = 3;
  r := erp.migration_opening_apply('ZZ98', orun);
  i := pg_temp.issues(orun, ARRAY['opening']);
  PERFORM pg_temp.check((r->>'remainder')::numeric = 10 AND i->>'opening:clear:ZZ98' = 'critical' AND i->>'opening:tb:ZZ98:1200' = 'critical',
    'planted sub-ledger error: clearing remainder 10 and A/R balance flagged', i::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.journal_entry WHERE company_code = 'ZZ98') = 1, 're-running the loader replaces the opening journal', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'migration_opening_apply' AND company_code = 'ZZ98'), 'opening load audited', '');

  -- ---------- 10. run report ----------
  r := pg_temp.call(admin, 'SELECT erp.migration_report(''a1200000-0000-4000-8000-000000000001'')');
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') > 20 AND jsonb_array_length(r->'issues') > 5 AND r#>>'{run,kind}' = 'full'
                        AND (r#>>'{attachments,missing}')::int = 1 AND (r#>>'{custom_fields,total}')::int = 3 AND r->'signoffs' = '[]',
    'run report holds checks, issues, sign-offs, register and attachments', left(r::text, 200));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'migration_report'), 'report download audited', '');
  PERFORM pg_temp.expect(pg_temp.call(stock, 'SELECT erp.migration_report(''a1200000-0000-4000-8000-000000000001'')'), 'run not found', 'a user outside admin/IT and sign-off roles cannot export the run report');
  PERFORM pg_temp.ok(pg_temp.call(sales, 'SELECT erp.migration_report(''a1200000-0000-4000-8000-000000000001'')'), 'business sign-off user can export the report of a run in review');
  PERFORM pg_temp.check((pg_temp.call(nobody, 'SELECT erp.migration_report(''a1200000-0000-4000-8000-000000000001'')'))->>'error' = '42501', 'user without profile refused', '');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a12_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a12_result;
ROLLBACK;
