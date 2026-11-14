-- 44 · open items from SAP's journal lines (14 Nov 2026, AE05 review, approved 11:32).
-- SAP's open item is the open part of a partner's journal line (JDT1 BalDueDeb - BalDueCred). Documents can stay "open" after
-- SAP settled them by a journal entry or an internal reconciliation, and journal-entry balances have no document, so aging
-- from documents (total - paid) disagreed with SAP for 503 AE05 partners. Now:
--   1. erp.journal_line.bal_due = SAP's open amount of the line (debit positive), filled by the sync;
--   2. A/R and A/P aging: SAP history from the open journal lines of the partner (by due date), plus documents created in
--      Super ERP (source <> 'sap') from total - paid as before.
BEGIN;
ALTER TABLE erp.journal_line ADD COLUMN IF NOT EXISTS bal_due numeric(21,6);
COMMENT ON COLUMN erp.journal_line.bal_due IS 'SAP open amount of the line on the partner (BalDueDeb - BalDueCred, debit positive); NULL for lines posted in Super ERP';

CREATE OR REPLACE FUNCTION erp.sync_journal_lines(p_company character varying)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'erp', 'sap', 'public', 'extensions'
AS $function$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.journal_line AS t (company_code, trans_id, line_id, acct_code, short_name, contra_acct, debit, credit, fc_debit, fc_credit, fc_currency, sys_debit, sys_credit, memo, cost_centre, cost_centre2, cost_centre3, project, ref_date, due_date, branch_id, tax_code, match_no, bal_due)
  SELECT s.company_code AS company_code,
         s."TransId" AS trans_id,
         s."Line_ID" AS line_id,
         s."Account" AS acct_code,
         nullif(s."ShortName", s."Account") AS short_name,
         s."ContraAct" AS contra_acct,
         coalesce(s."Debit", 0) AS debit,
         coalesce(s."Credit", 0) AS credit,
         s."FCDebit" AS fc_debit,
         s."FCCredit" AS fc_credit,
         s."FCCurrency" AS fc_currency,
         s."SYSDeb" AS sys_debit,
         s."SYSCred" AS sys_credit,
         s."LineMemo" AS memo,
         s."ProfitCode" AS cost_centre,
         s."OcrCode2" AS cost_centre2,
         s."OcrCode3" AS cost_centre3,
         s."Project" AS project,
         s."RefDate"::date AS ref_date,
         s."DueDate"::date AS due_date,
         s."BPLId" AS branch_id,
         s."VatGroup" AS tax_code,
         s."IntrnMatch" AS match_no,
         coalesce(s."BalDueDeb", 0) - coalesce(s."BalDueCred", 0) AS bal_due
    FROM sap."JDT1" s
   WHERE s.company_code = p_company
  ON CONFLICT (company_code, trans_id, line_id) DO UPDATE SET acct_code = EXCLUDED.acct_code, short_name = EXCLUDED.short_name, contra_acct = EXCLUDED.contra_acct, debit = EXCLUDED.debit, credit = EXCLUDED.credit, fc_debit = EXCLUDED.fc_debit, fc_credit = EXCLUDED.fc_credit, fc_currency = EXCLUDED.fc_currency, sys_debit = EXCLUDED.sys_debit, sys_credit = EXCLUDED.sys_credit, memo = EXCLUDED.memo, cost_centre = EXCLUDED.cost_centre, cost_centre2 = EXCLUDED.cost_centre2, cost_centre3 = EXCLUDED.cost_centre3, project = EXCLUDED.project, ref_date = EXCLUDED.ref_date, due_date = EXCLUDED.due_date, branch_id = EXCLUDED.branch_id, tax_code = EXCLUDED.tax_code, match_no = EXCLUDED.match_no, bal_due = EXCLUDED.bal_due WHERE (t.acct_code, t.short_name, t.contra_acct, t.debit, t.credit, t.fc_debit, t.fc_credit, t.fc_currency, t.sys_debit, t.sys_credit, t.memo, t.cost_centre, t.cost_centre2, t.cost_centre3, t.project, t.ref_date, t.due_date, t.branch_id, t.tax_code, t.match_no, t.bal_due) IS DISTINCT FROM (EXCLUDED.acct_code, EXCLUDED.short_name, EXCLUDED.contra_acct, EXCLUDED.debit, EXCLUDED.credit, EXCLUDED.fc_debit, EXCLUDED.fc_credit, EXCLUDED.fc_currency, EXCLUDED.sys_debit, EXCLUDED.sys_credit, EXCLUDED.memo, EXCLUDED.cost_centre, EXCLUDED.cost_centre2, EXCLUDED.cost_centre3, EXCLUDED.project, EXCLUDED.ref_date, EXCLUDED.due_date, EXCLUDED.branch_id, EXCLUDED.tax_code, EXCLUDED.match_no, EXCLUDED.bal_due);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION erp._rpt_aging(p_company varchar, p_as_of date, p_objs integer[])
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  WITH k AS (SELECT CASE WHEN 13 = ANY (p_objs) THEN 'customer' ELSE 'supplier' END AS kind, CASE WHEN 13 = ANY (p_objs) THEN 1 ELSE -1 END AS sgn),
  o AS (
    -- SAP history: open part of the partner's journal lines (as SAP's own aging)
    SELECT l.short_name AS cc, bp.name AS cn, round(k.sgn * l.bal_due, 2) AS amt,
           p_as_of - coalesce(l.due_date, l.ref_date) AS late
      FROM erp.journal_line l
      JOIN erp.journal_entry e ON e.company_code = l.company_code AND e.trans_id = l.trans_id AND e.source = 'sap'
      JOIN erp.business_partner bp ON bp.company_code = l.company_code AND bp.card_code = l.short_name
      CROSS JOIN k
     WHERE l.company_code = p_company AND bp.kind = k.kind AND coalesce(l.bal_due, 0) <> 0 AND l.ref_date <= p_as_of
    UNION ALL
    -- documents created in Super ERP
    SELECT d.card_code, d.card_name, round(d.sign * (coalesce(d.total, 0) - coalesce(d.paid, 0)), 2),
           p_as_of - coalesce(d.due_date, d.doc_date)
      FROM erp.document d
     WHERE d.company_code = p_company AND d.obj_type = ANY (p_objs) AND d.status = 'open' AND d.doc_date <= p_as_of
       AND coalesce(d.source, 'sap') <> 'sap' AND coalesce(d.total, 0) - coalesce(d.paid, 0) <> 0)
  SELECT o.cc, max(o.cn), count(*),
         coalesce(sum(o.amt) FILTER (WHERE o.late <= 0), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 1 AND 30), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 31 AND 60), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 61 AND 90), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late > 90), 0), sum(o.amt)
    FROM o GROUP BY o.cc ORDER BY sum(o.amt) DESC, o.cc
$$;
COMMIT;
