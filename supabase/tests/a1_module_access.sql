-- A1 · Module-level access tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run after 10–15, 16_module_access.sql and test-users.sql. Everything happens inside one transaction that is
-- rolled back, so the database is unchanged afterwards. Prints one row per check: PASS/FAIL · name · detail.
BEGIN;

CREATE TEMP TABLE a1_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a1_result TO authenticated;

-- Count rows of a query as a given user (RLS applies). Role and claims are local to the call.
CREATE FUNCTION pg_temp.cnt(p_user uuid, p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO v;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v;
END $$;
-- Same, for a boolean or text result.
CREATE FUNCTION pg_temp.val(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO v;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v;
END $$;
-- Run a statement as a user and return 'OK' or '<sqlstate>: <message>'.
CREATE FUNCTION pg_temp.try(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a1_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;

DO $$
DECLARE
  admin   uuid := '00000000-0000-4000-8000-000000000001';
  sales   uuid := '00000000-0000-4000-8000-000000000002';
  nobody  uuid := '00000000-0000-4000-8000-000000000003';
  fin     uuid := '00000000-0000-4000-8000-000000000004';
  owner   uuid := '00000000-0000-4000-8000-000000000005';
  sread   uuid := '00000000-0000-4000-8000-000000000006';
  sales_docs  text := 'SELECT count(*) FROM erp.document WHERE obj_type IN (23,17,15,16,203,13,14)';
  purch_docs  text := 'SELECT count(*) FROM erp.document WHERE obj_type IN (1470000113,540000006,22,20,21,204,18,19)';
  inv_docs    text := 'SELECT count(*) FROM erp.document WHERE obj_type IN (1250000001,67,59,60)';
  purch_lines text := 'SELECT count(*) FROM erp.document_line WHERE obj_type IN (22,20,18)';
  n bigint; e text; total bigint; tbl text;
BEGIN
  -- ---------- Sales-only user ----------
  n := pg_temp.cnt(sales, sales_docs);              PERFORM pg_temp.check(n > 0, 'sales user sees sales documents', n || ' rows');
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.journal_entry'); PERFORM pg_temp.check(n = 0, 'sales user sees 0 journal entries', n || ' rows');
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.journal_line');  PERFORM pg_temp.check(n = 0, 'sales user sees 0 journal lines', n || ' rows');
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.account');       PERFORM pg_temp.check(n = 0, 'sales user sees 0 G/L accounts', n || ' rows');
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.payment');       PERFORM pg_temp.check(n = 0, 'sales user sees 0 payments', n || ' rows');
  n := pg_temp.cnt(sales, purch_docs);              PERFORM pg_temp.check(n = 0, 'sales user sees 0 purchase documents', n || ' rows');
  n := pg_temp.cnt(sales, purch_lines);             PERFORM pg_temp.check(n = 0, 'sales user sees 0 purchase document lines', n || ' rows');
  n := pg_temp.cnt(sales, inv_docs);                PERFORM pg_temp.check(n = 0, 'sales user sees 0 inventory documents', n || ' rows');
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.business_partner'); PERFORM pg_temp.check(n > 0, 'sales user sees business partners', n || ' rows');
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.item');          PERFORM pg_temp.check(n > 0, 'sales user sees items', n || ' rows');
  e := pg_temp.try(sales, $q$INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, source)
                             VALUES ('ZZ99', 17, 999001, 999001, 'sales_order', 'open', current_date, 'erp')$q$);
  PERFORM pg_temp.check(e LIKE '42501:%', 'sales user: direct INSERT into document is refused', e);
  e := pg_temp.try(sales, $q$UPDATE erp.document SET status = 'closed' WHERE company_code = 'ZZ99'$q$);
  PERFORM pg_temp.check(e LIKE '42501:%', 'sales user: direct UPDATE of document is refused', e);
  e := pg_temp.try(sales, $q$DELETE FROM erp.journal_entry$q$);
  PERFORM pg_temp.check(e LIKE '42501:%', 'sales user: direct DELETE of journal_entry is refused', e);
  e := pg_temp.try(sales, $q$INSERT INTO erp.position_module VALUES ('QA_SALES', 'finance', 'full')$q$);
  PERFORM pg_temp.check(e LIKE '42501:%', 'sales user: direct INSERT into position_module is refused', e);
  PERFORM pg_temp.check(pg_temp.val(sales, $q$SELECT erp.module_level('sales')$q$) = 'full', 'sales user: module_level(sales) = full (from module_access)');
  PERFORM pg_temp.check(pg_temp.val(sales, $q$SELECT erp.module_level('finance')$q$) IS NULL, 'sales user: module_level(finance) is none');
  PERFORM pg_temp.check(pg_temp.val(sales, $q$SELECT erp.can_write('sales')$q$) = 'true', 'sales user: can_write(sales)');

  -- ---------- Finance user ----------
  n := pg_temp.cnt(fin, 'SELECT count(*) FROM erp.journal_entry'); PERFORM pg_temp.check(n > 0, 'finance user sees journal entries', n || ' rows');
  n := pg_temp.cnt(fin, sales_docs);  PERFORM pg_temp.check(n > 0, 'finance user sees sales documents', n || ' rows');
  n := pg_temp.cnt(fin, purch_docs);  PERFORM pg_temp.check(n > 0, 'finance user sees purchase documents', n || ' rows');
  n := pg_temp.cnt(fin, purch_lines); PERFORM pg_temp.check(n > 0, 'finance user sees purchase document lines', n || ' rows');
  n := pg_temp.cnt(fin, 'SELECT count(*) FROM erp.payment');        PERFORM pg_temp.check(n > 0, 'finance user sees payments', n || ' rows');
  n := pg_temp.cnt(fin, inv_docs);    PERFORM pg_temp.check(n = 0, 'finance user sees 0 inventory documents', n || ' rows');
  n := pg_temp.cnt(fin, 'SELECT count(*) FROM erp.employee WHERE emp_id IS NOT NULL'); PERFORM pg_temp.check(n = 0, 'finance user sees 0 employees (HR rule unchanged)', n || ' rows');

  -- ---------- Owner (business): every row the company rules allow ----------
  FOREACH tbl IN ARRAY ARRAY['account','journal_entry','journal_line','cost_centre','fx_rate','tax_code','payment','payment_allocation',
                             'document','document_line','business_partner','bp_address','bp_group','item','item_group','item_price',
                             'price_list','stock_balance','warehouse','batch','stock_movement'] LOOP
    EXECUTE format('SELECT count(*) FROM erp.%I WHERE company_code = ''ZZ99''', tbl) INTO total;
    n := pg_temp.cnt(owner, format('SELECT count(*) FROM erp.%I', tbl));
    PERFORM pg_temp.check(n = total, 'owner sees all of ' || tbl, n || ' of ' || total);
  END LOOP;
  PERFORM pg_temp.check(pg_temp.val(owner, $q$SELECT erp.can_write('finance')$q$) = 'false', 'owner: can_read everything but can_write(finance) is false');

  -- ---------- User with no profile ----------
  FOREACH tbl IN ARRAY ARRAY['document','journal_entry','payment','business_partner','item','employee','company'] LOOP
    n := pg_temp.cnt(nobody, format('SELECT count(*) FROM erp.%I', tbl));
    PERFORM pg_temp.check(n = 0, 'no-profile user sees 0 rows of ' || tbl, n || ' rows');
  END LOOP;
  n := pg_temp.cnt(NULL, 'SELECT count(*) FROM erp.document');
  PERFORM pg_temp.check(n = 0, 'request with no user sees 0 documents', n || ' rows');

  -- ---------- Read-only sales user ----------
  PERFORM pg_temp.check(pg_temp.val(sread, $q$SELECT erp.module_level('sales')$q$) = 'read', 'read-only user: module_level(sales) = read');
  PERFORM pg_temp.check(pg_temp.val(sread, $q$SELECT erp.can_read('sales')$q$) = 'true', 'read-only user: can_read(sales)');
  PERFORM pg_temp.check(pg_temp.val(sread, $q$SELECT erp.can_write('sales')$q$) = 'false', 'read-only user: cannot write sales');
  PERFORM pg_temp.check(pg_temp.val(sread, $q$SELECT erp.has_module('sales')$q$) = 'false', 'read-only user: older has_module(sales) stays false');
  n := pg_temp.cnt(sread, sales_docs); PERFORM pg_temp.check(n > 0, 'read-only user sees sales documents', n || ' rows');
  n := pg_temp.cnt(sread, 'SELECT count(*) FROM erp.journal_entry'); PERFORM pg_temp.check(n = 0, 'read-only user sees 0 journal entries', n || ' rows');

  -- ---------- HR tables: behaviour unchanged ----------
  SELECT count(*) INTO total FROM erp.employee WHERE company_code = 'ZZ99';
  n := pg_temp.cnt(admin, 'SELECT count(*) FROM erp.employee'); PERFORM pg_temp.check(n = total, 'admin (has hr) still sees all employees', n || ' of ' || total);
  n := pg_temp.cnt(sales, 'SELECT count(*) FROM erp.employee'); PERFORM pg_temp.check(n = 0, 'sales user still sees 0 employees', n || ' rows');
  n := pg_temp.cnt(owner, 'SELECT count(*) FROM erp.employee'); PERFORM pg_temp.check(n = 0, 'owner without hr still sees 0 employees (HR rule unchanged)', n || ' rows');

  -- ---------- Admin function erp.set_position_module ----------
  e := pg_temp.try(sales, $q$SELECT erp.set_position_module('QA_SALES', 'finance', 'full')$q$);
  PERFORM pg_temp.check(e LIKE '42501:%', 'sales user cannot change module access', e);
  e := pg_temp.try(admin, $q$SELECT erp.set_position_module('QA_SALES', 'flying', 'full')$q$);
  PERFORM pg_temp.check(e LIKE 'P0001: Module flying is not a known module.%', 'unknown module is refused with a clear message', e);
  e := pg_temp.try(admin, $q$SELECT erp.set_position_module('NOPE', 'sales', 'full')$q$);
  PERFORM pg_temp.check(e LIKE 'P0001: Position NOPE does not exist.%', 'unknown position is refused with a clear message', e);
  e := pg_temp.try(admin, $q$SELECT erp.set_position_module('QA_SALES', 'sales', 'write')$q$);
  PERFORM pg_temp.check(e LIKE 'P0001: Access level must be Full, Read or None.%', 'bad level is refused with a clear message', e);
  e := pg_temp.try(admin, $q$SELECT erp.set_position_module('QA_SALES', 'sales', 'read')$q$);
  PERFORM pg_temp.check(e = 'OK', 'admin sets sales user to read', e);
  PERFORM pg_temp.check(pg_temp.val(sales, $q$SELECT erp.can_write('sales')$q$) = 'false', 'after change: sales user can no longer write sales');
  PERFORM pg_temp.check(pg_temp.val(sales, $q$SELECT erp.has_module('sales')$q$) = 'false', 'after change: module_access no longer lists sales');
  n := pg_temp.cnt(sales, sales_docs); PERFORM pg_temp.check(n > 0, 'after change: sales user still reads sales documents', n || ' rows');
  e := pg_temp.try(admin, $q$SELECT erp.set_position_module('QA_SALES', 'sales', NULL)$q$);
  n := pg_temp.cnt(sales, sales_docs); PERFORM pg_temp.check(e = 'OK' AND n = 0, 'set to none: sales user sees 0 sales documents', e || ', ' || n || ' rows');
  e := pg_temp.try(admin, $q$SELECT erp.set_position_module('QA_SALES', 'sales', 'full')$q$);
  PERFORM pg_temp.check(e = 'OK' AND pg_temp.val(sales, $q$SELECT erp.has_module('sales')$q$) = 'true', 'set back to full: module_access lists sales again', e);
  SELECT count(*) INTO n FROM erp.audit_log WHERE action = 'set_position_module' AND object_ref = 'QA_SALES';
  PERFORM pg_temp.check(n = 3, 'each change writes erp.audit_log', n || ' rows');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a1_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a1_result;
ROLLBACK;

