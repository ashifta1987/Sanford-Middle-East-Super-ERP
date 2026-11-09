-- 15_stage1_overview.sql · Stage 1 (read only). Home-page figures and Control Tower checks.
-- SECURITY INVOKER: every query runs as the signed-in user, so the row-level rules in 12_erp_security.sql still decide
-- which companies (and HR rows) are counted. Nothing here writes data. Safe to run again.

-- Home page figures for one company, or every company the user can see (p_company NULL).
CREATE OR REPLACE FUNCTION erp.home_kpis(p_company varchar DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  WITH d AS (
    SELECT doc_kind, status, due_date, total, coalesce(paid, 0) AS paid
      FROM erp.document
     WHERE (p_company IS NULL OR company_code = p_company)
       AND doc_kind IN ('sales_order', 'purchase_order', 'ar_invoice', 'ap_invoice', 'sales_quotation')
       AND status = 'open'
  )
  SELECT jsonb_build_object(
    'open_sales_orders',    (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'sales_order'),
    'open_quotations',      (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'sales_quotation'),
    'open_purchase_orders', (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total), 0)) FROM d WHERE doc_kind = 'purchase_order'),
    'overdue_ar',           (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total - paid), 0)) FROM d
                              WHERE doc_kind = 'ar_invoice' AND due_date < current_date AND total > paid),
    'due_ap',               (SELECT jsonb_build_object('n', count(*), 'value', coalesce(sum(total - paid), 0)) FROM d
                              WHERE doc_kind = 'ap_invoice' AND due_date <= current_date + 7 AND total > paid),
    'low_stock',            (SELECT jsonb_build_object('n', count(*)) FROM erp.stock_balance
                              WHERE (p_company IS NULL OR company_code = p_company) AND min_stock > 0 AND on_hand < min_stock),
    'customers',            (SELECT count(*) FROM erp.business_partner
                              WHERE (p_company IS NULL OR company_code = p_company) AND kind = 'customer' AND active),
    'items',                (SELECT count(*) FROM erp.item WHERE (p_company IS NULL OR company_code = p_company) AND active)
  )
$$;

-- Control Tower: rule-based exception checks over live data (no AI, no writes). One row per finding.
CREATE OR REPLACE FUNCTION erp.control_checks(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  -- 1. Customers whose open balance is above their credit limit
  SELECT 'credit_limit', 'critical', b.company_code, b.card_code::text, b.name,
         'Balance ' || to_char(b.balance, 'FM999,999,999,990.00') || ' is above the credit limit of ' || to_char(b.credit_limit, 'FM999,999,999,990.00'),
         b.balance - b.credit_limit
    FROM erp.business_partner b
   WHERE (p_company IS NULL OR b.company_code = p_company) AND b.kind = 'customer' AND b.credit_limit > 0 AND b.balance > b.credit_limit
  UNION ALL
  -- 2. Stock below the minimum level set on the item/warehouse
  SELECT 'low_stock', 'warning', s.company_code, s.item_code || ' @ ' || s.whs_code, coalesce(i.name, s.item_code),
         'On hand ' || trim(to_char(s.on_hand, 'FM999,999,990')) || ' in ' || s.whs_code || ', minimum ' || trim(to_char(s.min_stock, 'FM999,999,990')),
         s.min_stock - s.on_hand
    FROM erp.stock_balance s LEFT JOIN erp.item i ON i.company_code = s.company_code AND i.item_code = s.item_code
   WHERE (p_company IS NULL OR s.company_code = p_company) AND s.min_stock > 0 AND s.on_hand < s.min_stock
  UNION ALL
  -- 3. Open sales quotations/orders with a line discount above 5 %
  SELECT 'high_discount', 'warning', d.company_code, d.doc_kind || ':' || d.doc_entry, d.card_name,
         'Document ' || d.doc_num || ', line ' || (l.line_num + 1) || ' ' || l.item_code || ': ' || trim(to_char(l.discount_pct, 'FM990.0')) || ' % discount',
         l.line_total
    FROM erp.document d JOIN erp.document_line l USING (company_code, obj_type, doc_entry)
   WHERE (p_company IS NULL OR d.company_code = p_company) AND d.doc_kind IN ('sales_quotation', 'sales_order') AND d.status = 'open'
     AND l.discount_pct > 5
  UNION ALL
  -- 4. Open sales lines priced below the item's cost
  SELECT 'below_cost', 'critical', d.company_code, d.doc_kind || ':' || d.doc_entry, d.card_name,
         'Document ' || d.doc_num || ', ' || l.item_code || ' sold at ' || to_char(l.price * (1 - coalesce(l.discount_pct, 0) / 100), 'FM999,990.00')
           || ', cost ' || to_char(l.stock_price, 'FM999,990.00'),
         (l.stock_price - l.price * (1 - coalesce(l.discount_pct, 0) / 100)) * l.quantity
    FROM erp.document d JOIN erp.document_line l USING (company_code, obj_type, doc_entry)
   WHERE (p_company IS NULL OR d.company_code = p_company) AND d.doc_kind IN ('sales_quotation', 'sales_order', 'ar_invoice') AND d.status = 'open'
     AND l.stock_price > 0 AND l.price * (1 - coalesce(l.discount_pct, 0) / 100) < l.stock_price
  UNION ALL
  -- 5. A/R invoices more than 60 days past due
  SELECT 'overdue_60', 'critical', d.company_code, d.doc_kind || ':' || d.doc_entry, d.card_name,
         'Invoice ' || d.doc_num || ' is ' || (current_date - d.due_date) || ' days past due',
         d.total - coalesce(d.paid, 0)
    FROM erp.document d
   WHERE (p_company IS NULL OR d.company_code = p_company) AND d.doc_kind = 'ar_invoice' AND d.status = 'open'
     AND d.due_date < current_date - 60 AND d.total > coalesce(d.paid, 0)
$$;

REVOKE ALL ON FUNCTION erp.home_kpis(varchar), erp.control_checks(varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.home_kpis(varchar), erp.control_checks(varchar) TO authenticated;
