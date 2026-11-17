-- 51 · SANA: record counts by status, and today's activity next to them (17 Nov 2026).
-- Why: "How many customers are active today?" was answered "none (no invoices today)" while the dashboard shows 1,452 active
-- customers. Sana had no tool for status counts, so it read "active" as "bought today". This tool returns both readings:
-- the record status (business_partner.active / item.active — the same rule as the dashboard, 15_stage1_overview.sql) and
-- today's / this month's activity (distinct partners on A/R invoices / A/P invoices, Dubai date). The prompt (core.ts rule 9)
-- says which one to lead with.
-- SECURITY DEFINER for speed (under RLS every one of 24k items / 3k partners would run the access check one by one: 2.4 s on live),
-- but nothing is wider than the caller's rights: the companies are the caller's own (erp._sana_search_companies, re-checked), the
-- role rules (erp.sana_has, read from the caller's token) decide which parts are returned, and only counts leave the function.
-- Role rules as in 36: customers for sales / finance / bp, suppliers for purchasing / finance / bp, items for
-- inventory / sales / purchasing; other parts are left out (not zero). Read only. Safe to run twice.
-- Needs 50 (erp._sana_search_companies). Note: S5 M2's Live file moves to 52_sana_live.sql.

CREATE OR REPLACE FUNCTION erp.sana_partner_counts(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE cos varchar[] := erp._sana_search_companies(p_company);   -- the company asked for (if visible), else all the caller's companies
        today date := (now() AT TIME ZONE 'Asia/Dubai')::date; m0 date := date_trunc('month', (now() AT TIME ZONE 'Asia/Dubai'))::date;
        out jsonb := jsonb_build_object('companies', to_jsonb(erp._sana_search_companies(p_company)), 'today', (now() AT TIME ZONE 'Asia/Dubai')::date,
                                        'meaning', 'active = record status (as on the dashboard); bought/billed = documents dated today or this month');
BEGIN
  IF NOT erp.sana_has('sales', 'finance', 'bp', 'purchase', 'inventory') THEN RETURN erp.sana_denied('partners'); END IF;
  IF erp.sana_has('sales', 'finance', 'bp') THEN
    out := out || jsonb_build_object('customers', (SELECT jsonb_build_object(
      'active', count(*) FILTER (WHERE b.active), 'inactive', count(*) FILTER (WHERE NOT b.active), 'total', count(*),
      'bought_today', (SELECT count(DISTINCT d.card_code) FROM erp.document d WHERE d.company_code = ANY (cos) AND d.obj_type = 13 AND d.doc_date = today AND d.status NOT IN ('cancelled', 'cancellation', 'draft')),
      'bought_this_month', (SELECT count(DISTINCT d.card_code) FROM erp.document d WHERE d.company_code = ANY (cos) AND d.obj_type = 13 AND d.doc_date >= m0 AND d.status NOT IN ('cancelled', 'cancellation', 'draft')),
      'list_link', '/bp?f_kind=customer&f_active=1')
      FROM erp.business_partner b WHERE b.company_code = ANY (cos) AND b.kind = 'customer'));
  END IF;
  IF erp.sana_has('purchase', 'finance', 'bp') THEN
    out := out || jsonb_build_object('suppliers', (SELECT jsonb_build_object(
      'active', count(*) FILTER (WHERE b.active), 'inactive', count(*) FILTER (WHERE NOT b.active), 'total', count(*),
      'billed_today', (SELECT count(DISTINCT d.card_code) FROM erp.document d WHERE d.company_code = ANY (cos) AND d.obj_type = 18 AND d.doc_date = today AND d.status NOT IN ('cancelled', 'cancellation', 'draft')),
      'list_link', '/bp?f_kind=supplier&f_active=1')
      FROM erp.business_partner b WHERE b.company_code = ANY (cos) AND b.kind = 'supplier'));
  END IF;
  IF erp.sana_has('inventory', 'sales', 'purchase') THEN
    out := out || jsonb_build_object('items', (SELECT jsonb_build_object(
      'active', count(*) FILTER (WHERE i.active), 'inactive', count(*) FILTER (WHERE NOT i.active), 'total', count(*), 'list_link', '/items')
      FROM erp.item i WHERE i.company_code = ANY (cos)));
  END IF;
  RETURN out;
END $$;

REVOKE ALL ON FUNCTION erp.sana_partner_counts(varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_partner_counts(varchar) TO authenticated;

NOTIFY pgrst, 'reload schema';
