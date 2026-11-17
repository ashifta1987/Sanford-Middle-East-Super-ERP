-- 56_home_kpis_speed.sql · Home › Today at a glance timed out ("canceling statement due to statement timeout") as admin on AE05
-- Cause: home_kpis (15) counts under RLS, and RLS calls erp.can_see(company_code) — a definer function the planner cannot inline —
-- once per row: 49.5 k open documents (3.0 s), 18.4 k items (1.1 s) and the low-stock count over AE05's 1.16 M stock rows
-- (more than 20 s). The same counts without RLS take 0.4–0.7 s.
-- Fix (the 51 / 55 rule: a definer helper is allowed for counts within the caller's companies and role, never for row data):
--   1. home_kpis returns only counts and sums, as SECURITY DEFINER, with the RLS rules checked ONCE up front instead of per row:
--      companies = the caller's own active companies (∩ the chosen company), and each figure only if the caller's modules would let
--      RLS show those rows (the same groups as the a1_* policies: sales orders / quotations / A/R invoices → sales or finance;
--      purchase orders / A/P invoices → purchase or finance; stock and items → inventory, sales or purchase; customers → partners,
--      sales, purchase or finance). A figure the role may not see is 0, exactly what RLS returned before.
--   2. A partial index on the rows that are below their minimum stock, so that count reads only those rows.
-- Same output, same numbers for every role.

CREATE INDEX IF NOT EXISTS stock_balance_below_min_idx ON erp.stock_balance (company_code) WHERE min_stock > 0 AND on_hand < min_stock;

CREATE OR REPLACE FUNCTION erp.home_kpis(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  cos varchar[] := ARRAY(SELECT uc.company_code FROM erp.user_company uc JOIN erp.app_user u ON u.user_id = uc.user_id
                          WHERE uc.user_id = erp.current_user_id() AND u.active AND (p_company IS NULL OR uc.company_code = p_company));
  sales_docs boolean := erp.can_read('sales') OR erp.can_read('finance');
  purch_docs boolean := erp.can_read('purchase') OR erp.can_read('finance');
  stock boolean := erp.can_read('inventory') OR erp.can_read('sales') OR erp.can_read('purchase');
  partners boolean := erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance');
  zero jsonb := jsonb_build_object('n', 0, 'value', 0);
  r jsonb;
BEGIN
  WITH d AS (
    SELECT doc_kind, due_date, total, coalesce(paid, 0) AS paid
      FROM erp.document
     WHERE company_code = ANY (cos) AND status = 'open'
       AND ((sales_docs AND doc_kind IN ('sales_order', 'sales_quotation', 'ar_invoice'))
         OR (purch_docs AND doc_kind IN ('purchase_order', 'ap_invoice'))))
  SELECT jsonb_build_object(
    'open_sales_orders',    (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'sales_order'),
    'open_quotations',      (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'sales_quotation'),
    'open_purchase_orders', (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'purchase_order'),
    'overdue_ar',           (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total - paid), 0)) FROM d
                              WHERE doc_kind = 'ar_invoice' AND due_date < current_date AND total > paid),
    'due_ap',               (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total - paid), 0)) FROM d
                              WHERE doc_kind = 'ap_invoice' AND due_date <= current_date + 7 AND total > paid),
    'low_stock',            jsonb_build_object('n', CASE WHEN stock THEN (SELECT count(*) FROM erp.stock_balance
                              WHERE company_code = ANY (cos) AND min_stock > 0 AND on_hand < min_stock) ELSE 0 END),
    'customers',            CASE WHEN partners THEN (SELECT count(*) FROM erp.business_partner WHERE company_code = ANY (cos) AND kind = 'customer' AND active) ELSE 0 END,
    'items',                CASE WHEN stock THEN (SELECT count(*) FROM erp.item WHERE company_code = ANY (cos) AND active) ELSE 0 END
  ) INTO r;
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION erp.home_kpis(varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.home_kpis(varchar) TO authenticated;
NOTIFY pgrst, 'reload schema';

