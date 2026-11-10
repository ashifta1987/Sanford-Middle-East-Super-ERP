-- B1 · Pilot company AE05, Document Numbering, decided rule changes. LOCAL STACK ONLY (sample company ZZ99 +
-- scripts/local-stack/test-users.sql + test-users-b1.sql). Run on a FRESH rebuild (sql-order.txt incl. 30_numbering_company.sql).
-- Everything happens inside one transaction that is rolled back. Prints PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE b1_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON b1_result TO authenticated;

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
  INSERT INTO b1_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.ser(p_user uuid, p_s jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.doc_series_save(%L, %L::jsonb)', 'ZZ99', p_s))
$$;
CREATE FUNCTION pg_temp.so(p_user uuid, p_header jsonb, p_lines jsonb, p_series bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, CASE WHEN p_series IS NULL THEN format('SELECT erp.sales_doc_save(%L, 17, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', p_header, p_lines)
                                   ELSE format('SELECT erp.sales_doc_save(%L, 17, NULL, %L::jsonb, %L::jsonb, %s)', 'ZZ99', p_header, p_lines, p_series) END)
$$;
CREATE FUNCTION pg_temp.nxt(p_series bigint) RETURNS integer LANGUAGE sql AS $$
  SELECT next_num FROM erp.doc_series_all WHERE series_id = p_series
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  smgr   uuid := '00000000-0000-4000-8000-000000000007';
  fmgr   uuid := '00000000-0000-4000-8000-000000000008';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  bpu    uuid := '00000000-0000-4000-8000-000000000016';
  hr     uuid := '00000000-0000-4000-8000-000000000018';
  it     uuid := '00000000-0000-4000-8000-000000000023';
  prod   uuid := '00000000-0000-4000-8000-000000000024';
  svc    uuid := '00000000-0000-4000-8000-000000000025';
  r jsonb; r2 jsonb;
  so_primary bigint; so_dxb bigint; so_lock bigint; so_2027 bigint; so_wh2 bigint; so_spare bigint;
  s_id bigint; v_n integer; v_e integer; v_d integer; q1 integer; q2 integer; inv1 integer; req bigint; po integer; call1 integer;
  hs jsonb := '{"card_code":"C0011","doc_date":"2026-11-10","due_date":"2026-11-30","whs_code":"WH01"}';
  ls jsonb := '[{"item_code":"SMP-1010","qty":1,"tax_code":"SR"}]';
BEGIN
  -- ================= 1. Company AE05 =================
  PERFORM pg_temp.check((SELECT legal_name = 'UAE - ATMM GENERAL TRADING LLC' AND country = 'AE' AND currency = 'AED' AND licence_type IS NULL AND sap_schema IS NULL AND active
                           FROM erp.company WHERE company_code = 'AE05'), 'AE05 seeded: AE, AED, licence type to be confirmed, no SAP schema');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM sap._company WHERE company_code = 'AE05' AND currency = 'AED'), 'AE05 is in the migration register (sap._company)');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.user_company WHERE company_code = 'AE05') = 1
                        AND EXISTS (SELECT 1 FROM erp.user_company WHERE company_code = 'AE05' AND user_id = it), 'only qa.it has AE05 (test users)');
  r := pg_temp.call(it, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.check(r @> '[{"company_code":"AE05","steps_done":0,"steps_total":7}]', 'AE05 shows in the go-live checklist (IT)', left(r::text, 300));
  r := pg_temp.call(it, $q$SELECT erp.go_live_checklist('AE05')$q$);
  PERFORM pg_temp.ok(r, 'AE05 checklist opens');
  r := pg_temp.call(admin, 'SELECT erp.go_live_overview()');
  PERFORM pg_temp.check(NOT r @> '[{"company_code":"AE05"}]', 'admin without AE05 access does not see it', left(r::text, 200));
  r := pg_temp.call(it, $q$SELECT to_jsonb(count(*)) FROM erp.migration_company_overview WHERE company_code = 'AE05'$q$);
  PERFORM pg_temp.check(r::text = '1', 'AE05 in the migration console company list', r::text);
  r := pg_temp.call(it, 'SELECT erp.company_list()');
  PERFORM pg_temp.check(r->'companies' @> '[{"company_code":"AE05","in_register":true,"live":false,"series":0}]' AND (r->>'can_write')::boolean = false,
                        'IT lists companies read-only, AE05 in the register with no numbering yet', left(r::text, 300));
  r := pg_temp.call(it, $q$SELECT erp.doc_numbering_setup('AE05')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'types') = 33 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'types') t WHERE jsonb_array_length(t->'series') > 0),
                        'AE05 numbering: 33 document types, all empty (entered by Sanford later)', left(r::text, 200));
  PERFORM pg_temp.check(erp._series_take('AE05', 17) IS NULL, 'allocator: no series = not set up (NULL)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE company_code = 'AE05') AND NOT EXISTS (SELECT 1 FROM erp.approval_rule WHERE company_code = 'AE05'),
                        'AE05 has no invented accounts or limits');

  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":"x"}')$q$),
    'Only a system admin with full Administration access can change this.', 'sales user can''t create companies');
  PERFORM pg_temp.expect(pg_temp.call(it, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":"x"}')$q$),
    'Only a system admin with full Administration access can change this.', 'IT (read-only) can''t create companies');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"z 9","legal_name":"x"}')$q$),
    'Use 2 to 8 capital letters or digits for the company code, e.g. AE06.', 'bad company code refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"AE05","legal_name":"x"}')$q$),
    'Company AE05 already exists. Open it to change it.', 'existing code refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":""}')$q$),
    'Enter the legal name (up to 200 characters).', 'legal name required');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":"Test Co","country":"UAE"}')$q$),
    'Use the two-letter country code, e.g. AE.', 'country code checked');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":"Test Co","currency":"DH"}')$q$),
    'Use the three-letter currency code, e.g. AED.', 'currency code checked');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":"Test Co","licence_type":"offshore"}')$q$),
    'Choose the licence type: free zone, mainland or foreign (or leave it empty until it is confirmed).', 'licence type checked');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ90","legal_name":"Test Co","tax_id":"123"}')$q$),
    'A UAE TRN has 15 digits. Check the number on the VAT certificate.', 'UAE TRN checked');
  r := pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"zz90","legal_name":"B1 Test Trading LLC (test)","short_name":"B1 Test","country":"AE","currency":"AED","tax_id":"100 0000 0000 0003"}')$q$);
  PERFORM pg_temp.check(r->>'company_code' = 'ZZ90' AND (r->>'created')::boolean AND (r->>'in_register')::boolean, 'admin creates company ZZ90 (code upper-cased)', r::text);
  PERFORM pg_temp.check((SELECT tax_id = '100000000000003' AND licence_type IS NULL FROM erp.company WHERE company_code = 'ZZ90')
                        AND EXISTS (SELECT 1 FROM sap._company WHERE company_code = 'ZZ90')
                        AND EXISTS (SELECT 1 FROM erp.user_company WHERE company_code = 'ZZ90' AND user_id = admin)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'company_create' AND object_ref = 'ZZ90'),
                        'new company: register row, creator access, audited');
  r := pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ90","edit":true,"legal_name":"B1 Test Trading LLC (test)","short_name":"B1 Renamed","currency":"USD"}')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND (SELECT short_name = 'B1 Renamed' AND currency = 'USD' FROM erp.company WHERE company_code = 'ZZ90'),
                        'company without documents: basics and currency can change', r::text);
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"ZZ99","edit":true,"legal_name":"Sample Trading LLC (test data)","currency":"USD"}')$q$),
    'The currency of ZZ99 can''t change: it already has documents or journal entries.', 'currency fixed once a company has documents');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.company_save('{"company_code":"AE05","edit":true,"legal_name":"x"}')$q$),
    'You don''t have access to company AE05.', 'admin can''t edit a company they can''t see');
  r := pg_temp.call(admin, $q$WITH x AS (INSERT INTO erp.company (company_code, legal_name, short_name, country, currency) VALUES ('ZZ80', 'x', 'x', 'AE', 'AED') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct insert into erp.company', r::text);

  -- ================= 2. Document numbering: setup =================
  so_primary := (SELECT series_id FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 17);
  r := pg_temp.call(admin, $q$SELECT erp.doc_numbering_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'types') = 33 AND (r->>'can_write')::boolean
                        AND (SELECT t->'series'->0->>'name' = 'Primary' AND (t->'series'->0->>'is_default')::boolean AND t->'series'->0->>'example' = 'SO-26-00001'
                               FROM jsonb_array_elements(r->'types') t WHERE (t->>'obj_type')::int = 17)
                        AND (SELECT NOT (t->>'used')::boolean FROM jsonb_array_elements(r->'types') t WHERE (t->>'obj_type')::int = 16),
                        'setup: 33 types; the A2 series became the default "Primary"; Return not created in Super ERP yet', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.doc_numbering_setup('ZZ99')$q$),
    'Only the system admin, IT and the owner can open Administration.', 'sales user can''t open Document Numbering');
  PERFORM pg_temp.expect(pg_temp.ser(it, '{"obj_type":17,"name":"X","prefix":"X-"}'),
    'Only a system admin with full Administration access can change this.', 'IT can''t change numbering');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":99,"name":"X","prefix":"X-"}'), 'Document type 99 has no numbering in Super ERP.', 'unknown type refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"","prefix":"X-"}'), 'Enter a series name (1 to 40 characters).', 'name required');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SO 26"}'), 'Use letters, digits, - / or _ in the prefix (1 to 20 characters).', 'bad prefix refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"po-26-"}'),
    'Prefix po-26- is already used by Purchase Order (Primary). Choose a different prefix.', 'prefix of another series refused (any case)');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"primary","prefix":"SOX-"}'), 'Series name primary is already used for Sales Order. Choose another name.', 'duplicate series name refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","first_num":5,"next_num":3}'),
    'The next number can''t be below the first number 5.', 'next below first refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","first_num":5,"last_num":4}'),
    'The last number must be at least the first number.', 'last below first refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","first_num":1,"next_num":9,"last_num":5}'),
    'The next number 9 is past the last number 5.', 'next past last refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","pad":3,"last_num":12345}'),
    'The last number 12345 has more digits than the 3 set. Add digits or lower the number.', 'last number longer than the digits refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","period_from":"2026-12-31","period_to":"2026-01-01"}'),
    'The period ends before it starts. Check the dates.', 'period end before start refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","whs_code":"NOPE"}'),
    'Warehouse NOPE does not exist or is inactive in company ZZ99.', 'unknown warehouse refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","branch_id":77}'),
    'Branch 77 does not exist in company ZZ99.', 'unknown branch refused');
  PERFORM pg_temp.expect(pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai","prefix":"SOD-","locked":true,"is_default":true}'),
    'A locked series can''t be the default. Unlock it or make another series the default.', 'locked default refused');

  r := pg_temp.ser(admin, '{"obj_type":17,"name":"Dubai 2026","prefix":"SOD-26-","first_num":1,"last_num":3,"pad":4,"remarks":"Dubai showroom"}');
  so_dxb := (r->>'series_id')::bigint;
  PERFORM pg_temp.check(so_dxb IS NOT NULL AND NOT (r->>'is_default')::boolean AND r->>'example' = 'SOD-26-0001' AND (r->>'left')::int = 3,
                        'second Sales Order series added (not the default, 3 numbers)', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'doc_series_save' AND object = 'number_series' AND object_ref = '17'), 'series change audited');
  so_lock := (pg_temp.ser(admin, '{"obj_type":17,"name":"Old branch","prefix":"SOO-","locked":true}')->>'series_id')::bigint;
  so_2027 := (pg_temp.ser(admin, '{"obj_type":17,"name":"Year 2027","prefix":"SO-27-","period_from":"2027-01-01","period_to":"2027-12-31"}')->>'series_id')::bigint;
  so_wh2 := (pg_temp.ser(admin, '{"obj_type":17,"name":"WH02 counter","prefix":"SOW2-","whs_code":"WH02"}')->>'series_id')::bigint;
  so_spare := (pg_temp.ser(admin, '{"obj_type":17,"name":"Spare","prefix":"SOS-"}')->>'series_id')::bigint;
  PERFORM pg_temp.check(so_lock IS NOT NULL AND so_2027 IS NOT NULL AND so_wh2 IS NOT NULL AND so_spare IS NOT NULL
                        AND (SELECT count(*) FROM erp.doc_series_all WHERE company_code = 'ZZ99' AND obj_type = 17) = 6
                        AND (SELECT count(*) FROM erp.doc_series_all WHERE company_code = 'ZZ99' AND obj_type = 17 AND is_default) = 1
                        AND (SELECT count(*) FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 17) = 1,
                        'six Sales Order series, one default');

  -- user defaults
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.series_user_default_save(%L, %L, 17, %s)', 'ZZ99', sales, so_dxb)),
    'Only a system admin with full Administration access can change this.', 'users can''t set their own default series');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.series_user_default_save(%L, %L, 17, %s)', 'ZZ99', '00000000-0000-4000-8000-0000000000ff', so_dxb)),
    'User 00000000-0000-4000-8000-0000000000ff has no access to company ZZ99.', 'unknown user refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.series_user_default_save(%L, %L, 22, %s)', 'ZZ99', sales, so_dxb)),
    format('Series %s is not a Purchase Order series of company ZZ99.', so_dxb), 'series of another type refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.series_user_default_save(%L, %L, 17, %s)', 'ZZ99', sales, so_lock)),
    'Series Old branch is locked, so it can''t be a default. Unlock it first.', 'locked series can''t be a user default');
  r := pg_temp.call(admin, format('SELECT erp.series_user_default_save(%L, %L, 17, %s)', 'ZZ99', sales, so_dxb));
  PERFORM pg_temp.check(r->>'error' IS NULL AND EXISTS (SELECT 1 FROM erp.series_user_default WHERE user_id = sales AND obj_type = 17 AND series_id = so_dxb)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'series_user_default_save'), 'admin sets qa.sales'' default Sales Order series (audited)', r::text);
  r := pg_temp.call(sales, $q$SELECT erp.doc_series_options('ZZ99', 17)$q$);
  PERFORM pg_temp.check((r->>'default_id')::bigint = so_dxb AND (r->>'mine')::bigint = so_dxb AND jsonb_array_length(r->'series') = 5
                        AND NOT r->'series' @> format('[{"series_id":%s}]', so_lock)::jsonb,
                        'picker: the user''s default first, locked series hidden', left(r::text, 300));
  r := pg_temp.call(smgr, $q$SELECT erp.doc_series_options('ZZ99', 17)$q$);
  PERFORM pg_temp.check((r->>'default_id')::bigint = so_primary AND r->'mine' = 'null'::jsonb, 'picker: other users get the company default', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.doc_series_options('AE05', 17)$q$), 'You don''t have access to company AE05.', 'picker: other company refused');
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.series_user_default$q$);
  r2 := pg_temp.call(smgr, $q$SELECT to_jsonb(count(*)) FROM erp.series_user_default$q$);
  PERFORM pg_temp.check(r::text = '1' AND r2::text = '0', 'users read only their own default series (RLS)', r::text || ' / ' || r2::text);
  r := pg_temp.call(admin, $q$WITH x AS (UPDATE erp.number_series SET next_num = 1 RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct update of number_series', r::text);
  r := pg_temp.call(admin, $q$WITH x AS (INSERT INTO erp.doc_series (company_code, obj_type, name, prefix) VALUES ('ZZ99', 17, 'x', 'x') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct insert into doc_series', r::text);

  -- ================= 2. Numbers on documents =================
  r := pg_temp.so(sales, hs, ls);
  PERFORM pg_temp.check(r->>'doc_no' = 'SOD-26-0001', 'no series picked: the user''s default series numbers the order', r::text);
  r := pg_temp.so(sales, hs, ls, so_primary);
  PERFORM pg_temp.check(r->>'doc_no' = 'SO-26-00001', 'picked series wins over the user default', r::text);
  r := pg_temp.so(smgr, hs, ls);
  PERFORM pg_temp.check(r->>'doc_no' = 'SO-26-00002', 'other users: company default series', r::text);
  v_n := pg_temp.nxt(so_dxb);
  r := pg_temp.so(sales, hs, '[{"item_code":"SMP-1010","qty":0}]');
  PERFORM pg_temp.check(r->>'message' = 'Line 1: quantity must be more than 0.' AND pg_temp.nxt(so_dxb) = v_n, 'a refused document gives no number away (gap-free)', r::text);
  PERFORM pg_temp.expect(pg_temp.so(sales, hs, ls, so_lock),
    'Sales Order series Old branch is locked. Choose another series or ask the system admin to unlock it (Administration › System Initialization › Document Numbering).',
    'locked series refused');
  PERFORM pg_temp.expect(pg_temp.so(sales, hs, ls, so_2027),
    'Sales Order series Year 2027 is for documents dated 01 Jan 2027 to 31 Dec 2027, not 10 Nov 2026. Choose a series for this period.', 'series outside its period refused');
  PERFORM pg_temp.expect(pg_temp.so(sales, hs, ls, so_wh2),
    'Sales Order series WH02 counter is for warehouse WH02, not WH01. Choose a series for WH01 or one without a warehouse.', 'series of another warehouse refused');
  r := pg_temp.so(sales, hs || '{"whs_code":"WH02"}', ls, so_wh2);
  PERFORM pg_temp.check(r->>'doc_no' = 'SOW2-00001', 'warehouse series numbers documents of its warehouse', r::text);
  r := pg_temp.so(sales, hs, ls); r2 := pg_temp.so(sales, hs, ls);
  PERFORM pg_temp.check(r->>'doc_no' = 'SOD-26-0002' AND r2->>'doc_no' = 'SOD-26-0003', 'numbers follow one another with no gap', r::text || ' ' || r2::text);
  PERFORM pg_temp.expect(pg_temp.so(sales, hs, ls),
    'Sales Order series Dubai 2026 has used its last number (SOD-26-0003). Ask the system admin to add a new series (Administration › System Initialization › Document Numbering).',
    'used-up series refused (last number reached)');
  PERFORM pg_temp.check(pg_temp.nxt(so_dxb) = 4, 'next number stays one past the last', pg_temp.nxt(so_dxb)::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 17 AND doc_no LIKE 'SOD-26-%') = 3
                        AND (SELECT count(DISTINCT doc_no) FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 17) = (SELECT count(*) FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 17),
                        'no duplicate document numbers');
  -- period-aware default: when the company default can't number the date, the series for that period takes over
  r := pg_temp.ser(admin, jsonb_build_object('series_id', so_primary, 'name', 'Primary', 'prefix', 'SO-26-', 'period_to', '2026-12-31'));
  PERFORM pg_temp.ok(r, 'a period end can be added to a used series');
  -- (the forms always call the p_series overload, which passes the posting date; NULL = no series picked)
  r := pg_temp.call(smgr, format('SELECT erp.sales_doc_save(%L, 17, NULL, %L::jsonb, %L::jsonb, NULL::bigint)', 'ZZ99', hs || '{"doc_date":"2027-01-05","due_date":"2027-01-30"}', ls));
  PERFORM pg_temp.check(r->>'doc_no' = 'SO-27-00001', 'a 2027 document takes the 2027 series when the default ends in 2026', coalesce(r->>'doc_no', r::text));
  r := pg_temp.ser(admin, jsonb_build_object('series_id', so_primary, 'name', 'Primary', 'prefix', 'SO-26-', 'period_to', ''));

  -- forward only, used series fixed
  PERFORM pg_temp.expect(pg_temp.ser(admin, jsonb_build_object('series_id', so_primary, 'name', 'Primary', 'prefix', 'SO-26-', 'next_num', 1)),
    'Numbers only move forward: Sales Order series Primary has already reached SO-26-00003. Use a higher number or a new series.', 'numbers can''t go back');
  PERFORM pg_temp.expect(pg_temp.ser(admin, jsonb_build_object('series_id', so_primary, 'name', 'Primary', 'prefix', 'SO-Z-')),
    'The prefix of series Primary can''t change: it has already numbered documents. Add a new series instead.', 'prefix of a used series fixed');
  PERFORM pg_temp.expect(pg_temp.ser(admin, jsonb_build_object('series_id', so_primary, 'name', 'Primary', 'prefix', 'SO-26-', 'first_num', 2, 'next_num', 3)),
    'The first number of series Primary can''t change: it has already numbered documents.', 'first number of a used series fixed');
  PERFORM pg_temp.expect(pg_temp.ser(admin, jsonb_build_object('series_id', so_primary, 'name', 'Primary', 'prefix', 'SO-26-', 'is_default', false)),
    'Every document type keeps one default series. Make another series the default instead.', 'the default can''t just be switched off');
  r := pg_temp.ser(admin, jsonb_build_object('series_id', so_dxb, 'name', 'Dubai 2026', 'prefix', 'SOD-26-', 'pad', 4, 'last_num', 9));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'left')::int = 6, 'admin raises the last number of a used series', r::text);
  r := pg_temp.so(sales, hs, ls);
  PERFORM pg_temp.check(r->>'doc_no' = 'SOD-26-0004', 'numbering continues after the last number was raised', r::text);
  r := pg_temp.ser(admin, jsonb_build_object('series_id', so_spare, 'name', 'Spare', 'prefix', 'SOS-', 'is_default', true));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (SELECT is_default FROM erp.doc_series_all WHERE series_id = so_spare) AND NOT (SELECT is_default FROM erp.doc_series_all WHERE series_id = so_primary)
                        AND (SELECT next_num FROM erp.doc_series_all WHERE series_id = so_primary) = 3,
                        'another series becomes the default (the old default keeps its id and next number)', r::text);
  r := pg_temp.so(smgr, hs, ls);
  PERFORM pg_temp.check(r->>'doc_no' = 'SOS-00001', 'new default numbers the next order', r::text);
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.doc_series_delete(%L, %s)', 'ZZ99', so_primary)),
    'Series Primary has already numbered documents (next number SO-26-00003), so it can''t be deleted. Lock it instead.', 'used series can''t be deleted');
  r := pg_temp.ser(admin, '{"obj_type":17,"name":"Unused","prefix":"SOU-"}');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.doc_series_delete(%L, %s)', 'ZZ99', so_spare)),
    'Series Spare has already numbered documents (next number SOS-00002), so it can''t be deleted. Lock it instead.', 'default (used) series can''t be deleted');
  r := pg_temp.call(admin, format('SELECT erp.doc_series_delete(%L, %s)', 'ZZ99', (r->>'series_id')));
  PERFORM pg_temp.check((r->>'deleted')::boolean AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'doc_series_delete'), 'unused series deleted (audited)', r::text);

  -- A10's numbering calls still work on the default series
  r := pg_temp.call(admin, $q$SELECT erp.number_series_setup('ZZ99')$q$);
  PERFORM pg_temp.check((SELECT s->>'prefix' = 'SOS-' FROM jsonb_array_elements(r->'series') s WHERE (s->>'obj_type')::int = 17), 'A10 setup shows the default series', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.number_series_save('ZZ99', 17, 'SOS-', 1, 5, true)$q$),
    'Numbers only move forward: Sales Order has already reached SOS-00002. Use a higher number or a new prefix.', 'A10 save keeps forward-only');

  -- every module's numbering function takes its number from the picked series
  s_id := (pg_temp.ser(admin, '{"obj_type":22,"name":"China PO","prefix":"POC-","pad":4}')->>'series_id')::bigint;
  r := pg_temp.call(purch, format('SELECT erp.purchase_doc_save(%L, 22, NULL, %L::jsonb, %L::jsonb, %s)', 'ZZ99',
         '{"card_code":"S0009","doc_date":"2026-11-10","due_date":"2026-12-31","whs_code":"WH01"}', '[{"item_code":"SMP-1140","qty":10,"price":60}]', s_id));
  po := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'POC-0001', 'purchasing: purchase order numbered from the picked series', r::text);
  s_id := (pg_temp.ser(admin, '{"obj_type":59,"name":"Found stock","prefix":"GRF-"}')->>'series_id')::bigint;
  r := pg_temp.call(stock, format('SELECT erp.inventory_doc_create(%L, 59, %L::jsonb, %L::jsonb, NULL, %s)', 'ZZ99',
         '{"doc_date":"2026-11-10","whs_code":"WH01","reason_code":"FOUND"}', '[{"item_code":"SMP-1010","qty":1,"price":95}]', s_id));
  PERFORM pg_temp.check(r->>'doc_no' = 'GRF-00001', 'inventory: goods receipt numbered from the picked series', r::text);
  s_id := (pg_temp.ser(admin, '{"obj_type":2001,"name":"Dubai customers","prefix":"CD","pad":4}')->>'series_id')::bigint;
  r := pg_temp.call(bpu, format('SELECT erp.bp_save(%L, %L::jsonb, NULL, NULL, %s)', 'ZZ99',
         '{"kind":"customer","name":"B1 Numbering Customer","group_code":100,"payment_terms":2}', s_id));
  PERFORM pg_temp.check(r->>'card_code' = 'CD0001', 'business partners: customer code from the picked series', r::text);
  r := pg_temp.call(bpu, format('SELECT erp.bp_save(%L, %L::jsonb)', 'ZZ99', '{"kind":"customer","name":"B1 Default Customer","group_code":100,"payment_terms":2}'));
  PERFORM pg_temp.check(r->>'card_code' LIKE 'C0000%', 'business partners: without a pick the default C series', r::text);
  s_id := (pg_temp.ser(admin, '{"obj_type":4,"name":"Kettles","prefix":"KT-","pad":4}')->>'series_id')::bigint;
  r := pg_temp.call(stock, format('SELECT erp.item_save(%L, %L::jsonb, NULL, %s)', 'ZZ99', '{"name":"B1 numbered kettle","group_code":101,"inventory_uom":"pcs"}', s_id));
  PERFORM pg_temp.check(r->>'item_code' = 'KT-0001' AND (r->>'created')::boolean, 'items: an empty code takes the next item code', r::text);
  r := pg_temp.call(stock, format('SELECT erp.item_save(%L, %L::jsonb, NULL, NULL)', 'ZZ99', '{"item_code":"B1-HAND-1","name":"B1 typed code","group_code":101,"inventory_uom":"pcs"}'));
  PERFORM pg_temp.check(r->>'item_code' = 'B1-HAND-1', 'items: a typed code is kept', r::text);
  s_id := (pg_temp.ser(admin, '{"obj_type":171,"name":"Dubai staff","prefix":"DXB-","pad":3}')->>'series_id')::bigint;
  r := pg_temp.call(hr, format('SELECT erp.hr_employee_save(%L, %L::jsonb, %s)', 'ZZ99', '{"first_name":"Nadia","last_name":"Aziz","joined_on":"2026-10-16"}', s_id));
  PERFORM pg_temp.check(r->>'hr_code' = 'DXB-001', 'HR: employee code from the picked series', r::text);
  r := pg_temp.call(hr, format('SELECT erp.hr_employee_save(%L, %L::jsonb)', 'ZZ99', '{"first_name":"Omar","last_name":"Saleh","joined_on":"2026-10-16"}'));
  PERFORM pg_temp.check(r->>'hr_code' = 'EMP-0001', 'HR: default employee series still works', r::text);
  s_id := (pg_temp.ser(admin, '{"obj_type":202,"name":"Line 2","prefix":"PRD2-"}')->>'series_id')::bigint;
  r := pg_temp.call(prod, format('SELECT erp.prod_order_create(%L, %L::jsonb, %s)', 'ZZ99', '{"item_code":"SMP-PRD-100","planned_qty":2,"due_date":"2026-11-30"}', s_id));
  PERFORM pg_temp.check(r->>'doc_no' = 'PRD2-00001', 'production: order numbered from the picked series', r::text);
  s_id := (pg_temp.ser(admin, '{"obj_type":191,"name":"Field calls","prefix":"SCF-"}')->>'series_id')::bigint;
  r := pg_temp.call(svc, format('SELECT erp.service_call_save(%L, %L::jsonb, %s)', 'ZZ99',
         '{"card_code":"C0011","item_code":"SMP-1030","serial_no":"BL-SMP-0100","subject":"B1 noisy motor"}', s_id));
  call1 := (r->>'call_id')::integer;
  PERFORM pg_temp.check(r->>'doc_no' = 'SCF-00001', 'service: call numbered from the picked series', r::text);
  -- payments waiting for approval keep the picked series until the last approval posts them
  s_id := (pg_temp.ser(admin, '{"obj_type":46,"name":"Transfers","prefix":"PVT-"}')->>'series_id')::bigint;
  r := pg_temp.call(fin, format('SELECT erp.payment_submit(%L, %L, %L::jsonb, %L::jsonb, %L, %s)', 'ZZ99', 'O',
         '{"card_code":"S0006","doc_date":"2026-11-09","transfer":21000,"transfer_bank":"BNK-AED"}', '[]', 'Advance on account', s_id));
  v_d := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (SELECT series_id FROM erp.payment_draft WHERE draft_id = v_d) = s_id AND pg_temp.nxt(s_id) = 1,
                        'payment draft keeps the picked series (no number yet)', r::text);
  r := pg_temp.call(fmgr, format('SELECT erp.payment_decide(%L, %s, %L, NULL)', 'ZZ99', v_d, 'approved'));
  PERFORM pg_temp.check(r->>'state' = 'posted' AND r->>'doc_no' = 'PVT-00001', 'approval posts the payment with a number from that series', r::text);

  -- ================= 3. Expired quotation =================
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_save(%L, 23, NULL, %L::jsonb, %L::jsonb)', 'ZZ99',
         '{"card_code":"C0011","doc_date":"2026-10-01","due_date":"2026-10-15","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":2,"tax_code":"SR"}]'));
  q1 := (r->>'doc_entry')::integer;
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_submit(%L, 23, %s, NULL)', 'ZZ99', q1));
  PERFORM pg_temp.check(r->>'state' = 'approved', 'quotation valid until 15 Oct 2026 approved', r::text);
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.sales_copy_source(%L, 23, %s)', 'ZZ99', q1)),
    format('Quotation %s expired on 15 Oct 2026. An expired quotation can''t be copied to an order. Raise a new quotation.', (SELECT doc_no FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1)),
    'copy to: expired quotation refused');
  r := pg_temp.call(sales, $q$SELECT erp.sales_copy_source('ZZ99', 23, NULL, 'C0011')$q$);
  PERFORM pg_temp.check(NOT (r->'lines') @> format('[{"base_doc_entry":%s}]', q1)::jsonb, 'copy to: expired quotations are not offered', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.so(sales, hs, format('[{"item_code":"SMP-1010","qty":1,"tax_code":"SR","base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', q1)::jsonb, so_primary),
    format('Line 1: Quotation %s expired on 15 Oct 2026. An expired quotation can''t be copied to an order. Raise a new quotation.', (SELECT doc_no FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 23 AND doc_entry = q1)),
    'order from an expired quotation refused');
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_save(%L, 23, NULL, %L::jsonb, %L::jsonb)', 'ZZ99',
         '{"card_code":"C0011","doc_date":"2026-11-10","due_date":"2026-12-31","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":2,"tax_code":"SR"}]'));
  q2 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.call(sales, format('SELECT erp.sales_doc_submit(%L, 23, %s, NULL)', 'ZZ99', q2));
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_save(%L, 23, NULL, %L::jsonb, %L::jsonb)', 'ZZ99',
         '{"card_code":"C0011","doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":1,"tax_code":"SR"}]'));
  PERFORM pg_temp.call(sales, format('SELECT erp.sales_doc_submit(%L, 23, %s, NULL)', 'ZZ99', (r->>'doc_entry')::int));
  r2 := pg_temp.call(sales, $q$SELECT erp.sales_copy_source('ZZ99', 23, NULL, 'C0011')$q$);
  PERFORM pg_temp.check((r2->'lines') @> format('[{"base_doc_entry":%s}]', q2)::jsonb AND (r2->'lines') @> format('[{"base_doc_entry":%s}]', r->>'doc_entry')::jsonb,
                        'copy to: valid quotations and quotations without a valid-until date are offered', left(r2::text, 200));
  r := pg_temp.so(sales, hs, format('[{"item_code":"SMP-1010","qty":1,"tax_code":"SR","base_obj_type":23,"base_doc_entry":%s,"base_line":0}]', q2)::jsonb, so_primary);
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->>'doc_no' LIKE 'SO-26-%', 'order from a valid quotation still works', r::text);

  -- ================= 3. QC before shipping =================
  r := pg_temp.call(purch, format('SELECT erp.purchase_doc_submit(%L, 22, %s, NULL)', 'ZZ99', po));
  PERFORM pg_temp.check(r->>'state' = 'approved', 'purchase order open', r::text);
  r := pg_temp.call(purch, $q$SELECT erp.purchase_setting_set('ZZ99', '{"require_qc_pass":false}')$q$);
  PERFORM pg_temp.check((r->>'require_qc_pass')::boolean AND (SELECT require_qc_pass FROM erp.purchase_setting WHERE company_code = 'ZZ99'),
                        'require QC pass can''t be switched off', r::text);
  UPDATE erp.purchase_setting SET require_qc_pass = false WHERE company_code = 'ZZ99';   -- even an old setting row can't skip QC
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"eta":"2026-12-20","shipment_mode":"air"}', '[{"po_line":0,"qty":5}]')$q$, po)),
    'Purchase order POC-0001 has no QC inspection yet. Record a passed inspection before shipping.', 'shipment without a QC inspection refused');
  PERFORM pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","result":"fail","note":"B1"}')$q$, po, current_date));
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"eta":"2026-12-20","shipment_mode":"air"}', '[{"po_line":0,"qty":5}]')$q$, po)),
    'The last QC inspection of POC-0001 was fail. Record a passed inspection before shipping.', 'shipment after a failed QC refused');
  PERFORM pg_temp.call(purch, format($q$SELECT erp.purchase_qc_save('ZZ99', '{"po_doc_entry":%s,"inspected_on":"%s","result":"pass","note":"B1"}')$q$, po, current_date));
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_shipment_save('ZZ99', NULL, '{"po_doc_entry":%s,"eta":"2026-12-20","shipment_mode":"air"}', '[{"po_line":0,"qty":5}]')$q$, po));
  PERFORM pg_temp.ok(r, 'shipment after a passed QC');

  -- ================= 3. BP duplicates =================
  r := pg_temp.call(bpu, $q$SELECT erp.bp_checks('ZZ99', '{"kind":"customer","name":"B1 Numbering Customers","group_code":100,"payment_terms":2}')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'duplicates') = 0, 'a similar name no longer warns', left(r::text, 200));
  r := pg_temp.call(bpu, $q$SELECT erp.master_data_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND r::text LIKE '%OEM%', 'OEM / ODM stay configurable sourcing types', left(r::text, 120));

  -- ================= 3. Landed costs on goods already sold =================
  PERFORM pg_temp.check((SELECT acct_code FROM erp.gl_determination WHERE company_code = 'ZZ99' AND area = 'inventory' AND posting_key = 'price_difference') = '5340'
                        AND (SELECT source FROM erp.account WHERE company_code = 'ZZ99' AND acct_code = '5340') = 'sample',
                        'ZZ99 SAMPLE price difference account 5340 (real companies: entered later)');
  PERFORM pg_temp.check(position('price_difference' IN (SELECT prosrc FROM pg_proc WHERE oid = 'erp.landed_cost_create(varchar, jsonb, jsonb, jsonb)'::regprocedure)) > 0,
                        'landed costs post the sold share to inventory/price_difference');

  -- ================= 3. Credit memo approval / direct service invoice discount =================
  r := pg_temp.call(admin, $q$SELECT erp.approval_template_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->'catalogue' @> '[{"rule_code":"credit_memo_amount","obj_types":[14],"limit_kind":"amount"}]'
                        AND r->'rules' @> '[{"rule_code":"credit_memo_amount","position_code":"QA_SALES","approver_position":"QA_SALES_MGR"}]',
                        'approval templates: credit memo (amount) with the ZZ99 sample rule', left(r::text, 200));
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-SVC-01","qty":1,"price":8000}]')$q$);
  inv1 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(inv1 IS NOT NULL AND r->>'doc_no' LIKE 'IN-26-%', 'direct service invoice without discount: created at once', r::text);
  r := pg_temp.call(sales, format('SELECT erp.sales_credit_memo_create(%L, %L::jsonb, %L::jsonb)', 'ZZ99', '{"doc_date":"2026-11-10"}',
         format('[{"base_doc_entry":%s,"base_line":0,"qty":0.5}]', inv1)));
  PERFORM pg_temp.check(r->>'doc_no' LIKE 'CN-26-%', 'credit memo within the limit: created at once (4,200 AED)', r::text);
  v_n := (SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 14 AND active);
  r := pg_temp.call(sales, format('SELECT erp.sales_credit_memo_create(%L, %L::jsonb, %L::jsonb)', 'ZZ99', '{"doc_date":"2026-11-10"}',
         format('[{"base_doc_entry":%s,"base_line":0,"qty":5}]', inv1)));
  PERFORM pg_temp.expect(r, 'Line 1: you are crediting 5 of SMP-SVC-01 but only 0.5 are still open on A/R invoice ' || (SELECT doc_no FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = inv1) || '.',
    'an invalid credit memo is refused before it goes for approval');
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-SVC-01","qty":1,"price":9000}]')$q$);
  inv1 := (r->>'doc_entry')::integer;
  r := pg_temp.call(sales, format('SELECT erp.sales_credit_memo_create(%L, %L::jsonb, %L::jsonb, %s)', 'ZZ99', '{"doc_date":"2026-11-10","approval_reason":"Wrong price billed"}',
         format('[{"base_doc_entry":%s,"base_line":0,"qty":1}]', inv1), (SELECT series_id FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 14 AND active)));
  req := (r->>'request_id')::bigint;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (r->>'total')::numeric = 9450 AND r->'checks'->0->>'message' = 'Credit memo total 9,450.00 AED is above the limit of 5,000.00 AED. It needs approval from QA · sales manager.'
                        AND NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 14 AND total = 9450),
                        'credit memo above the limit waits for approval (nothing posted)', r::text);
  PERFORM pg_temp.check((SELECT next_num FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 14 AND active) = v_n,
                        'the waiting request takes no number');
  PERFORM pg_temp.check((SELECT reason = 'Wrong price billed' AND card_code = 'C0011' AND series_id IS NOT NULL FROM erp.sales_doc_request WHERE request_id = req), 'request keeps reason, customer and series');
  r := pg_temp.call(smgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(r->'waiting' @> format('[{"kind":"sales_doc_request","doc_no":"REQ-%s","card_code":"C0011"}]', req)::jsonb, 'request in the sales manager''s inbox', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.sales_doc_request_decide(%L, %s, %L)', 'ZZ99', req, 'approved')),
    'You can''t approve your own request.', 'requester can''t approve');
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.sales_doc_request_decide(%L, %s, %L)', 'ZZ99', req, 'approved')),
    'This request is waiting for approval from QA · sales manager. Your position can''t decide it.', 'other position can''t decide');
  PERFORM pg_temp.expect(pg_temp.call(smgr, format('SELECT erp.sales_doc_request_decide(%L, %s, %L)', 'ZZ99', req, 'rejected')),
    'Add a note saying why you are rejecting this request.', 'reject needs a note');
  r := pg_temp.call(smgr, format('SELECT erp.sales_doc_request_info(%L, %s)', 'ZZ99', req));
  PERFORM pg_temp.check((r->>'can_decide')::boolean AND NOT (r->>'is_requester')::boolean AND jsonb_array_length(r->'approvals') = 1, 'request page: the approver may decide', left(r::text, 200));
  r := pg_temp.call(smgr, format('SELECT erp.sales_doc_request_decide(%L, %s, %L, %L)', 'ZZ99', req, 'approved', 'OK'));
  PERFORM pg_temp.check(r->>'state' = 'approved' AND r->>'doc_no' LIKE 'CN-26-%'
                        AND (SELECT total = 9450 AND source = 'erp' FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 14 AND doc_entry = (r->>'doc_entry')::integer)
                        AND (SELECT created_by = sales FROM erp.doc_workflow WHERE company_code = 'ZZ99' AND obj_type = 14 AND doc_entry = (r->>'doc_entry')::integer),
                        'last approval creates the credit memo, as the requester', r::text);
  PERFORM pg_temp.expect(pg_temp.call(smgr, format('SELECT erp.sales_doc_request_decide(%L, %s, %L)', 'ZZ99', req, 'approved')),
    'This request is not waiting for approval.', 'decided request can''t be decided again');
  -- direct service invoice: same discount template as sales orders (QA_SALES 10 %)
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-SVC-01","qty":1,"price":100,"discount_pct":8}]')$q$);
  PERFORM pg_temp.check(r->>'doc_no' LIKE 'IN-26-%', 'service invoice within the discount limit: created at once', r::text);
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-SVC-01","qty":1,"price":100,"discount_pct":15}]')$q$);
  req := (r->>'request_id')::bigint;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND r->'checks'->0->>'message' = 'Line 1: Discount 15% is above your limit of 10%. Submit it for approval or lower the discount.',
                        'service invoice above the discount limit waits (sales-order template)', r::text);
  PERFORM pg_temp.expect(pg_temp.call(smgr, format('SELECT erp.sales_doc_request_cancel(%L, %s, %L)', 'ZZ99', req, 'x')),
    'Only the person who sent this request can cancel it.', 'only the requester cancels');
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_request_cancel(%L, %s, %L)', 'ZZ99', req, 'Discount withdrawn'));
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND NOT EXISTS (SELECT 1 FROM erp.approval WHERE object = 'sales_doc_request' AND object_ref = req::text AND decision IS NULL AND NOT superseded),
                        'requester cancels; open approvals closed', r::text);
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-10","card_code":"C0011"}', '[{"item_code":"SMP-SVC-01","qty":1,"price":100,"discount_pct":20}]')$q$);
  req := (r->>'request_id')::bigint;
  r := pg_temp.call(smgr, format('SELECT erp.sales_doc_request_decide(%L, %s, %L, %L)', 'ZZ99', req, 'rejected', 'Too much'));
  PERFORM pg_temp.check(r->>'state' = 'rejected' AND (SELECT state FROM erp.sales_doc_request WHERE request_id = req) = 'rejected', 'sales manager rejects with a note', r::text);
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.sales_doc_request$q$);
  r2 := pg_temp.call(hr, $q$SELECT to_jsonb(count(*)) FROM erp.sales_doc_request$q$);
  PERFORM pg_temp.check(r::text = '3' AND r2::text = '0', 'requests readable by Sales / Financials only (RLS)', r::text || ' / ' || r2::text);
  r := pg_temp.call(sales, $q$WITH x AS (UPDATE erp.sales_doc_request SET state = 'approved' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct update of requests', r::text);

  -- ================= 3. Spare parts =================
  r := pg_temp.call(svc, $q$SELECT erp.service_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->'setting'->>'manager_position' = 'QA_SERVICE' AND (r->>'can_issue_parts')::boolean, 'default: the service manager position may issue parts (ZZ99 SAMPLE)', left(r::text, 200));
  r := pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', call1, '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]'));
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->>'doc_no' LIKE 'GI-26-%', 'service manager issues spare parts', r::text);
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_setting_set('ZZ99', '{"parts_positions":["NOPE"]}')$q$),
    'Position NOPE does not exist. Choose positions from the list.', 'unknown position refused');
  PERFORM pg_temp.expect(pg_temp.call(svc, $q$SELECT erp.service_setting_set('ZZ99', '{"parts_users":["00000000-0000-4000-8000-0000000000ff"]}')$q$),
    'User 00000000-0000-4000-8000-0000000000ff has no access to company ZZ99. Choose users from the list.', 'unknown user refused');
  r := pg_temp.call(svc, format('SELECT erp.service_setting_set(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('parts_positions', jsonb_build_array('QA_ALL'))));
  PERFORM pg_temp.check(r->'parts_positions' = '["QA_ALL"]' AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'service_setting_set' AND detail ? 'issuers'), 'issuers saved and audited', r::text);
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', call1, '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]')),
    'Your position can''t issue spare parts in company ZZ99. Ask the service manager to add you in Service Setup (who may issue spare parts).', 'position not in the list refused');
  r := pg_temp.call(svc, format('SELECT erp.service_setting_set(%L, %L::jsonb)', 'ZZ99', jsonb_build_object('parts_users', jsonb_build_array(svc))));
  r := pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', call1, '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]'));
  PERFORM pg_temp.ok(r, 'a user named in the list may issue parts');
  r := pg_temp.call(svc, $q$SELECT erp.service_setting_set('ZZ99', '{"parts_positions":[],"parts_users":[],"manager_position":null}')$q$);
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', call1, '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]')),
    'Nobody may issue spare parts in company ZZ99 yet. Ask the service manager to set who may issue them in Service Setup.', 'nobody configured: refused');
  r := pg_temp.call(svc, $q$SELECT erp.service_setting_set('ZZ99', '{"manager_position":"QA_ALL"}')$q$);
  PERFORM pg_temp.expect(pg_temp.call(svc, format('SELECT erp.service_call_parts_issue(%L, %s, %L::jsonb, %L::jsonb)', 'ZZ99', call1, '{"doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1220","qty":1}]')),
    'Only the service manager position (QA · all modules) may issue spare parts in company ZZ99. Ask the service manager to add you in Service Setup.', 'other manager position: refused');

  -- ================= 3. Mould defaults =================
  r := pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-B1-1","name":"B1 test mould","kind":"mould"}')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND (SELECT maint_every_shots = 50000 AND rated_life_shots = 500000 AND warn_pct = 80 FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-1'),
                        'new mould: maintenance every 50,000 shots, rated life 500,000, warn at 80 %', r::text);
  r := pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-B1-2","name":"B1 own values","kind":"mould","maint_every_shots":20000,"rated_life_shots":100000,"warn_pct":70}')$q$);
  PERFORM pg_temp.check((SELECT maint_every_shots = 20000 AND rated_life_shots = 100000 AND warn_pct = 70 FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-2'),
                        'values entered for a mould are kept', r::text);
  r := pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"INJ-B1","name":"B1 machine","kind":"machine"}')$q$);
  PERFORM pg_temp.check((SELECT maint_every_shots IS NULL AND rated_life_shots IS NULL AND warn_pct IS NULL FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'INJ-B1'),
                        'machines get no mould defaults', r::text);
  PERFORM pg_temp.expect(pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-B1-1","edit":true,"name":"B1 test mould","kind":"mould","warn_pct":150}')$q$),
    'Warn at must be a percentage above 0 and up to 100.', 'warn % checked');
  r := pg_temp.call(prod, $q$SELECT erp.prod_resource_save('ZZ99', '{"res_code":"MLD-B1-1","edit":true,"name":"B1 test mould","kind":"mould","maint_every_shots":50000,"rated_life_shots":500000,"warn_pct":60}')$q$);
  PERFORM pg_temp.check((SELECT warn_pct = 60 FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-1'), 'warn % editable per mould', r::text);
  UPDATE erp.prod_resource SET shots_done = 41000, last_maint_shots = 0 WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-1';
  UPDATE erp.prod_resource SET shots_done = 13000, last_maint_shots = 0 WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-2';
  PERFORM pg_temp.check((SELECT maint_status = 'due_soon' FROM erp.mould_schedule WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-1')
                        AND (SELECT maint_status = 'ok' FROM erp.mould_schedule WHERE company_code = 'ZZ99' AND res_code = 'MLD-B1-2'),
                        'schedule: due soon from the warning % of the interval');

  -- ================= Health =================
  r := pg_temp.call(it, 'SELECT erp.system_health()');
  PERFORM pg_temp.check(r->'files' @> '[{"file":"30_numbering_company.sql","present":true}]', 'system health knows 30_numbering_company.sql', left(r::text, 120));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'checks') c WHERE c->>'status' = 'error' AND (c->>'count')::int > 0), 'system health: no errors', (r->'checks')::text);
  r := pg_temp.call(sales, $q$SELECT to_jsonb(has_function_privilege('erp._series_take(varchar, integer, text)', 'EXECUTE'))$q$);
  PERFORM pg_temp.check(r::text = 'false', 'the allocator is internal', r::text);
  r := pg_temp.call(NULL, $q$SELECT erp.doc_series_options('ZZ99', 17)$q$, 'anon');
  PERFORM pg_temp.check(r->>'error' = '42501', 'anon can''t call the API', r::text);
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM b1_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM b1_result;
ROLLBACK;
