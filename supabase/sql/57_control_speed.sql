-- 57_control_speed.sql · Control Tower (control_findings) and Sana alerts (sana_alerts) timed out on AE05 (over 15 s, refreshed every minute)
-- Cause: the company check in RLS, erp.can_see(company_code), is a definer function the planner cannot inline or index, so it runs
-- once per row. Control Tower joins open sales documents to their lines (5 M lines in total): high_discount and below_cost each ran
-- over 30 s as admin, price_increase 7 s. The same queries without RLS take 0.5–0.7 s.
-- Fix: the rows stay protected by RLS, but the company check is worked out ONCE per query:
--   1. erp._my_companies(): the caller's own active companies (company codes only — a key-only definer helper, docs/sana-agent.md);
--   2. on the hot tables the company policy becomes  company_code = ANY ((SELECT erp._my_companies())::varchar[])  — the same rows as
--      erp.can_see(company_code) (can_see is exactly "company_code is one of my active companies"), evaluated once as an InitPlan,
--      with a leakproof = that the planner can use with the indexes;
--   3. partial indexes on the lines that the two document checks look for (discount above 5 %, price below cost).
-- control_findings and sana_alerts keep running with the caller's rights (they return row data, so no definer there).
-- The module (a1_*) restrictive policies are unchanged.

CREATE OR REPLACE FUNCTION erp._my_companies() RETURNS varchar[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(array_agg(uc.company_code ORDER BY uc.company_code), '{}')
    FROM erp.user_company uc JOIN erp.app_user u ON u.user_id = uc.user_id
   WHERE uc.user_id = erp.current_user_id() AND u.active
$$;
REVOKE ALL ON FUNCTION erp._my_companies() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._my_companies() TO authenticated;

-- the hot tables of Control Tower, Home and Sana: same rule, checked once per query
ALTER POLICY document_read         ON erp.document         USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));
ALTER POLICY document_line_read    ON erp.document_line    USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));
ALTER POLICY business_partner_read ON erp.business_partner USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));
ALTER POLICY stock_balance_read    ON erp.stock_balance    USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));
ALTER POLICY item_read             ON erp.item             USING (company_code = ANY ((SELECT erp._my_companies())::varchar[]));

CREATE INDEX IF NOT EXISTS document_line_discount_over5_idx ON erp.document_line (company_code, obj_type, doc_entry) WHERE discount_pct > 5;
CREATE INDEX IF NOT EXISTS document_line_below_cost_idx ON erp.document_line (company_code, obj_type, doc_entry)
  WHERE stock_price > 0 AND price * (1 - coalesce(discount_pct, 0) / 100) < stock_price;

-- sana_alerts (36): unchanged rules; a role with none of the alert topics gets the empty list at once instead of computing every
-- Control Tower finding first (admin / IT: 1 s of work for an empty answer).
CREATE OR REPLACE FUNCTION erp.sana_alerts(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('inventory', 'sales', 'purchase', 'finance', 'banking', 'hr') THEN
    RETURN jsonb_build_object('alerts', '[]'::jsonb, 'link', '/control', 'kind', 'rules');
  END IF;
  RETURN (SELECT jsonb_build_object('alerts', coalesce(jsonb_agg(jsonb_build_object('check', c.check_code, 'severity', c.severity, 'company', c.company_code,
            'subject', c.title, 'detail', c.detail, 'amount', c.amount, 'link', c.link)), '[]'), 'link', '/control', 'kind', 'rules')
    FROM (SELECT * FROM erp.control_findings(p_company) LIMIT 300) c
   WHERE CASE c.check_code
           WHEN 'low_stock'         THEN erp.sana_has('inventory','sales','purchase')
           WHEN 'below_cost'        THEN erp.sana_has('finance','purchase','inventory')   -- its detail shows cost prices
           WHEN 'count_variance'    THEN erp.sana_has('inventory','finance')
           WHEN 'bank_change'       THEN erp.sana_has('banking','finance','purchase')
           WHEN 'price_increase'    THEN erp.sana_has('purchase','finance')
           WHEN 'duplicate_invoice' THEN erp.sana_has('purchase','finance')
           WHEN 'checkin_outside'   THEN erp.sana_has('hr')
           WHEN 'credit_limit'      THEN erp.sana_has('sales','finance')
           WHEN 'high_discount'     THEN erp.sana_has('sales','finance')
           ELSE erp.sana_has('finance') END);
EXCEPTION WHEN insufficient_privilege THEN
  RETURN jsonb_build_object('alerts', '[]'::jsonb, 'link', '/control', 'kind', 'rules');
END $$;
NOTIFY pgrst, 'reload schema';
