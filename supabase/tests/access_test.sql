-- Regression of the app-layer access rules listed in README (12_erp_security.sql). Each block prints PASS or FAIL.
\set QUIET on
\set fin '{"sub":"00000000-0000-0000-0000-000000000001"}'
\set hr  '{"sub":"00000000-0000-0000-0000-000000000002"}'
\set emp '{"sub":"00000000-0000-0000-0000-000000000003"}'

-- finance user
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', :'fin', true) \gset x
DO $$ BEGIN UPDATE erp.business_partner SET name = 'x'; RAISE NOTICE 'FAIL finance can update customers';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS finance cannot update customers'; END $$;
DO $$ BEGIN INSERT INTO erp.user_company VALUES ('00000000-0000-0000-0000-000000000001', 'AE01'); RAISE NOTICE 'FAIL finance can grant access';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS finance cannot grant company access'; END $$;
DO $$ BEGIN INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, debit) VALUES ('AE01', 10, 99, '1100', 1); RAISE NOTICE 'FAIL finance can add journal lines';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS finance cannot add journal lines'; END $$;
DO $$ DECLARE n int; BEGIN SELECT count(*) INTO n FROM erp.employee_pay; IF n = 0 THEN RAISE NOTICE 'PASS finance sees no salaries'; ELSE RAISE NOTICE 'FAIL finance sees % salaries', n; END IF;
  SELECT count(*) INTO n FROM erp.business_partner; IF n > 0 THEN RAISE NOTICE 'PASS finance reads customers (%)', n; ELSE RAISE NOTICE 'FAIL finance reads no customers'; END IF; END $$;
ROLLBACK;

-- HR user
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', :'hr', true) \gset x
DO $$ DECLARE n int; BEGIN SELECT count(*) INTO n FROM erp.employee_pay; IF n > 0 THEN RAISE NOTICE 'PASS HR sees salaries (%)', n; ELSE RAISE NOTICE 'FAIL HR sees no salaries'; END IF; END $$;
ROLLBACK;

-- employee / merchandiser (emp 7 in AE01)
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', :'emp', true) \gset x
DO $$ DECLARE n int; BEGIN SELECT count(*) INTO n FROM erp.employee; IF n = 1 THEN RAISE NOTICE 'PASS employee sees only own record'; ELSE RAISE NOTICE 'FAIL employee sees % employees', n; END IF; END $$;
DO $$ BEGIN INSERT INTO erp.shop_visit (company_code, card_code, emp_id, role, checked_in_at) VALUES ('AE01', 'C0001', 7, 'merchandiser', now());
  RAISE NOTICE 'PASS merchandiser logs own visit'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FAIL merchandiser own visit: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO erp.shop_visit (company_code, card_code, emp_id, role, checked_in_at) VALUES ('AE01', 'C0001', 8, 'merchandiser', now());
  RAISE NOTICE 'FAIL merchandiser logged a visit as someone else'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS merchandiser cannot log a visit as someone else'; END $$;
ROLLBACK;

-- anonymous
BEGIN; SET LOCAL ROLE anon;
DO $$ BEGIN PERFORM 1 FROM erp.company; RAISE NOTICE 'FAIL anon reads erp';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon has no access to erp'; END $$;
DO $$ BEGIN PERFORM 1 FROM sap."OCRD"; RAISE NOTICE 'FAIL anon reads sap';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon has no access to sap'; END $$;
ROLLBACK;
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', :'fin', true) \gset x
DO $$ BEGIN PERFORM 1 FROM sap."OCRD"; RAISE NOTICE 'FAIL authenticated reads sap';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS app users have no access to sap'; END $$;
DO $$ BEGIN PERFORM 1 FROM erp.sync_log; RAISE NOTICE 'FAIL app user reads sync_log';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS app users cannot read sync_log'; END $$;
ROLLBACK;
