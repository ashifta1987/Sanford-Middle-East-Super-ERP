-- 56_home_kpis_speed.sql: home_kpis (now counts as definer, rules checked once) gives exactly what the old RLS version gave, for
-- every local test role. LOCAL STACK or a Supabase BRANCH with ZZ99 + test users — never live. One transaction, rolled back.
-- Users: 1 admin (all modules), 2 sales, 3 no profile, 4 finance, 5 owner (business), 6 sales read-only, 7 sales manager.
BEGIN;
CREATE TEMP TABLE sr_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON sr_result TO authenticated;
CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO sr_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
-- the 15_stage1_overview.sql version (invoker, RLS per row) as the reference
CREATE FUNCTION pg_temp.home_kpis_rls(p_company varchar DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT doc_kind, status, due_date, total, coalesce(paid, 0) AS paid FROM erp.document
     WHERE (p_company IS NULL OR company_code = p_company)
       AND doc_kind IN ('sales_order', 'purchase_order', 'ar_invoice', 'ap_invoice', 'sales_quotation') AND status = 'open')
  SELECT jsonb_build_object(
    'open_sales_orders',    (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'sales_order'),
    'open_quotations',      (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'sales_quotation'),
    'open_purchase_orders', (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'purchase_order'),
    'overdue_ar',           (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total - paid), 0)) FROM d WHERE doc_kind = 'ar_invoice' AND due_date < current_date AND total > paid),
    'due_ap',               (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total - paid), 0)) FROM d WHERE doc_kind = 'ap_invoice' AND due_date <= current_date + 7 AND total > paid),
    'low_stock',            (SELECT jsonb_build_object('n', count(*)) FROM erp.stock_balance WHERE (p_company IS NULL OR company_code = p_company) AND min_stock > 0 AND on_hand < min_stock),
    'customers',            (SELECT count(*) FROM erp.business_partner WHERE (p_company IS NULL OR company_code = p_company) AND kind = 'customer' AND active),
    'items',                (SELECT count(*) FROM erp.item WHERE (p_company IS NULL OR company_code = p_company) AND active))
$$;
GRANT EXECUTE ON FUNCTION pg_temp.home_kpis_rls(varchar) TO authenticated;

DO $$
DECLARE a jsonb; b jsonb; u integer; co text;
BEGIN
  -- make sure there is something below its minimum, so low_stock is not trivially 0
  UPDATE erp.stock_balance SET min_stock = on_hand + 5 WHERE company_code = 'ZZ99' AND (item_code, whs_code) IN (SELECT item_code, whs_code FROM erp.stock_balance WHERE company_code = 'ZZ99' LIMIT 3);
  FOREACH u IN ARRAY ARRAY[1, 2, 3, 4, 5, 6, 7] LOOP
    FOREACH co IN ARRAY ARRAY['ZZ99', NULL] LOOP
      a := pg_temp.call(pg_temp.u(u), format('SELECT erp.home_kpis(%L)', co));
      b := pg_temp.call(pg_temp.u(u), format('SELECT pg_temp.home_kpis_rls(%L)', co));
      PERFORM pg_temp.check(a = b, format('home_kpis = the RLS version for user %s, company %s', u, coalesce(co, 'all')), a::text || ' vs ' || b::text);
    END LOOP;
  END LOOP;
  a := pg_temp.call(pg_temp.u(1), 'SELECT erp.home_kpis(''ZZ99'')');
  PERFORM pg_temp.check((a -> 'low_stock' ->> 'n')::integer >= 3 AND (a -> 'open_sales_orders' ->> 'n')::integer > 0, 'admin sees real counts (not all zero)', a::text);
  a := pg_temp.call(pg_temp.u(2), 'SELECT erp.home_kpis(''AE05'')');
  PERFORM pg_temp.check((a -> 'open_sales_orders' ->> 'n')::integer = 0 AND (a ->> 'items')::integer = 0, 'a company the user cannot see gives only zeros', a::text);
  a := pg_temp.call(NULL, 'SELECT erp.home_kpis(''ZZ99'')');
  PERFORM pg_temp.check((a ->> 'customers')::integer = 0 AND (a -> 'due_ap' ->> 'n')::integer = 0, 'not signed in: only zeros', a::text);
  PERFORM pg_temp.check(NOT has_function_privilege('anon', 'erp.home_kpis(varchar)', 'EXECUTE')
                        AND (SELECT array_to_string(proconfig, ',') LIKE '%search_path=erp, pg_temp%' FROM pg_proc WHERE oid = 'erp.home_kpis(varchar)'::regprocedure),
                        'definer home_kpis: search_path pinned, no anon execute');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'stock_balance_below_min_idx'), 'partial index on stock below minimum exists');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM sr_result ORDER BY n;
SELECT 'TOTAL' AS result, format('%s passed, %s failed', count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok)) AS name, '' AS detail FROM sr_result;
ROLLBACK;

