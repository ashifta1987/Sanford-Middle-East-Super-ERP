-- 57_control_speed.sql: Control Tower findings, Sana alerts and the rows of the five re-written policies are exactly what they were
-- with erp.can_see(company_code), for every local test role. LOCAL STACK or a Supabase BRANCH — never live. Rolled back.
-- Users: 1 admin, 2 sales, 3 no profile, 4 finance, 5 owner, 6 sales read-only, 7 sales manager (made inactive below for one pass).
BEGIN;
CREATE TEMP TABLE sr_result (n serial, ok boolean, name text, detail text);
CREATE TEMP TABLE snap (pass text, u integer, what text, v text);
GRANT ALL ON sr_result, snap TO authenticated;
CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN 'error ' || SQLSTATE || ' ' || SQLERRM;
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO sr_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
-- one snapshot of everything a user can see through the changed paths
CREATE FUNCTION pg_temp.take(p_pass text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE u integer; w record;
BEGIN
  FOREACH u IN ARRAY ARRAY[1, 2, 3, 4, 5, 6, 7] LOOP
    FOR w IN SELECT * FROM (VALUES
      ('control_findings ZZ99', 'SELECT md5(coalesce(string_agg(f::text, ''|'' ORDER BY f::text), '''')) || '':'' || count(*) FROM erp.control_findings(''ZZ99'') f'),
      ('control_findings all',  'SELECT md5(coalesce(string_agg(f::text, ''|'' ORDER BY f::text), '''')) || '':'' || count(*) FROM erp.control_findings(NULL) f'),
      -- as a set: the alert order inside equal (severity, check, company, ref) keys is not fixed, before or after 57
      ('sana_alerts ZZ99',      'SELECT md5(coalesce(string_agg(e::text, ''|'' ORDER BY e::text), '''')) || '':'' || count(*) FROM jsonb_array_elements(erp.sana_alerts(''ZZ99'') -> ''alerts'') e'),
      ('home_kpis ZZ99',        'SELECT md5(erp.home_kpis(''ZZ99'')::text)'),
      ('document rows',         'SELECT count(*) || '':'' || md5(coalesce(string_agg(company_code || obj_type || '':'' || doc_entry, '','' ORDER BY company_code, obj_type, doc_entry), '''')) FROM erp.document'),
      ('document_line rows',    'SELECT count(*)::text FROM erp.document_line'),
      ('business_partner rows', 'SELECT count(*) || '':'' || md5(coalesce(string_agg(company_code || card_code, '','' ORDER BY company_code, card_code), '''')) FROM erp.business_partner'),
      ('stock_balance rows',    'SELECT count(*)::text FROM erp.stock_balance'),
      ('item rows',             'SELECT count(*) || '':'' || md5(coalesce(string_agg(company_code || item_code, '','' ORDER BY company_code, item_code), '''')) FROM erp.item')) AS q(what, sql)
    LOOP
      INSERT INTO snap VALUES (p_pass, u, w.what, pg_temp.call(pg_temp.u(u), w.sql));
    END LOOP;
  END LOOP;
END $$;

DO $$
DECLARE r record; n integer;
BEGIN
  -- something for every check to find
  UPDATE erp.stock_balance SET min_stock = on_hand + 5 WHERE company_code = 'ZZ99' AND (item_code, whs_code) IN (SELECT item_code, whs_code FROM erp.stock_balance WHERE company_code = 'ZZ99' LIMIT 3);
  PERFORM pg_temp.take('new');
  -- the policies as they were before 57
  ALTER POLICY document_read         ON erp.document         USING (erp.can_see(company_code));
  ALTER POLICY document_line_read    ON erp.document_line    USING (erp.can_see(company_code));
  ALTER POLICY business_partner_read ON erp.business_partner USING (erp.can_see(company_code));
  ALTER POLICY stock_balance_read    ON erp.stock_balance    USING (erp.can_see(company_code));
  ALTER POLICY item_read             ON erp.item             USING (erp.can_see(company_code));
  PERFORM pg_temp.take('old');
  FOR r IN SELECT a.u, a.what, a.v AS new_v, b.v AS old_v FROM snap a JOIN snap b ON b.u = a.u AND b.what = a.what AND b.pass = 'old' WHERE a.pass = 'new' ORDER BY a.u, a.what LOOP
    PERFORM pg_temp.check(r.new_v = r.old_v AND r.new_v NOT LIKE 'error%', format('user %s · %s: same as with can_see', r.u, r.what), r.new_v || ' vs ' || r.old_v);
  END LOOP;
  SELECT count(*) INTO n FROM snap WHERE pass = 'new' AND what = 'control_findings ZZ99' AND split_part(v, ':', 2)::integer > 0;
  PERFORM pg_temp.check(n >= 3, 'control findings are not trivially empty (at least 3 roles see some)', n::text);
  -- an inactive user sees nothing through the new policy
  UPDATE erp.app_user SET active = false WHERE user_id = pg_temp.u(7);
END $$;
-- re-apply 57's policies for the inactive-user check
ALTER POLICY document_read ON erp.document USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));
ALTER POLICY item_read     ON erp.item     USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));
DO $$ BEGIN
  PERFORM pg_temp.check(pg_temp.call(pg_temp.u(7), 'SELECT ((SELECT count(*) FROM erp.document) + (SELECT count(*) FROM erp.item))::text') = '0', 'an inactive user sees no documents or items (new policy)');
  PERFORM pg_temp.check(pg_temp.call(NULL, 'SELECT ((SELECT count(*) FROM erp.document) + (SELECT count(*) FROM erp.item))::text') = '0', 'not signed in: no documents or items');
  PERFORM pg_temp.check(NOT has_function_privilege('anon', 'erp._my_companies()', 'EXECUTE'), '_my_companies: no anon execute');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM sr_result ORDER BY n;
SELECT 'TOTAL' AS result, format('%s passed, %s failed', count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok)) AS name, '' AS detail FROM sr_result;
ROLLBACK;
