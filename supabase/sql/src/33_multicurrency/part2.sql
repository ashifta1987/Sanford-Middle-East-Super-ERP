
-- ============ 7b. Reports: aging with the document currency ============
-- Replaces 26 (return type changes, so DROP + CREATE): the same LC buckets and total, plus the partner's document
-- currency (several = comma-separated) and the open amount in that currency when it is one foreign currency.
DROP FUNCTION IF EXISTS erp.rpt_ar_aging(varchar, date);
DROP FUNCTION IF EXISTS erp.rpt_ap_aging(varchar, date);
DROP FUNCTION IF EXISTS erp._rpt_aging(varchar, date, integer[]);
CREATE FUNCTION erp._rpt_aging(p_company varchar, p_as_of date, p_objs integer[])
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric, currency text, total_fc numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  WITH o AS (
    SELECT d.card_code AS cc, d.card_name AS cn, round(d.sign * (coalesce(d.total, 0) - coalesce(d.paid, 0)), 2) AS amt,
           p_as_of - coalesce(d.due_date, d.doc_date) AS late,
           coalesce(d.currency, c.currency) AS cur, c.currency AS lc,
           CASE WHEN d.total_fc IS NOT NULL AND d.currency <> c.currency THEN round(d.sign * (coalesce(d.total_fc, 0) - coalesce(d.paid_fc, 0)), 2) END AS amt_fc
      FROM erp.document d JOIN erp.company c ON c.company_code = d.company_code
     WHERE d.company_code = p_company AND d.obj_type = ANY (p_objs) AND d.status = 'open' AND d.doc_date <= p_as_of
       AND coalesce(d.total, 0) - coalesce(d.paid, 0) <> 0)
  SELECT o.cc, max(o.cn), count(*),
         coalesce(sum(o.amt) FILTER (WHERE o.late <= 0), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 1 AND 30), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 31 AND 60), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 61 AND 90), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late > 90), 0), sum(o.amt),
         string_agg(DISTINCT o.cur, ', '),
         CASE WHEN count(DISTINCT o.cur) = 1 AND max(o.cur) <> max(o.lc) THEN sum(o.amt_fc) END
    FROM o GROUP BY o.cc ORDER BY sum(o.amt) DESC, o.cc
$$;

CREATE FUNCTION erp.rpt_ar_aging(p_company varchar, p_as_of date)
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric, currency text, total_fc numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['sales', 'finance'], 'Sales or Financials');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'Choose the aging date.' USING ERRCODE = 'P0001'; END IF;
  RETURN QUERY SELECT * FROM erp._rpt_aging(p_company, p_as_of, ARRAY[13, 14]);
END $$;

CREATE FUNCTION erp.rpt_ap_aging(p_company varchar, p_as_of date)
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric, currency text, total_fc numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['purchase', 'finance'], 'Purchasing or Financials');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'Choose the aging date.' USING ERRCODE = 'P0001'; END IF;
  RETURN QUERY SELECT * FROM erp._rpt_aging(p_company, p_as_of, ARRAY[18, 19]);
END $$;
REVOKE ALL ON FUNCTION erp._rpt_aging(varchar, date, integer[]), erp.rpt_ar_aging(varchar, date), erp.rpt_ap_aging(varchar, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._rpt_aging(varchar, date, integer[]), erp.rpt_ar_aging(varchar, date), erp.rpt_ap_aging(varchar, date) TO authenticated;
