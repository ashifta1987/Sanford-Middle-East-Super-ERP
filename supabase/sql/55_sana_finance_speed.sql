-- 55_sana_finance_speed.sql · S5: the finance summary lookup (Sana's finance_summary tool) took over 30 s on AE05 under RLS
-- Cause: "by drawer" added Southfield-posted journal lines to each account with a correlated sub-query per account (555 accounts),
-- and each one scanned journal_line (1.6 M rows) under RLS — even though only 2 of AE05's 491 k journal entries are not from SAP.
-- Fix (same output, same caller rights, no definer helper needed):
--   1. a partial index on the few non-SAP journal entries;
--   2. the Southfield-posted lines are summed once per account, starting from that index (set-based, not per account).
-- Sana's 3 s limit had been hiding this ("couldn't find it"), while the query kept running in the database.

CREATE INDEX IF NOT EXISTS journal_entry_non_sap_idx ON erp.journal_entry (company_code, trans_id) WHERE source <> 'sap';

CREATE OR REPLACE FUNCTION erp.sana_finance_summary(p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = erp, pg_temp AS $$
BEGIN
  IF NOT erp.sana_has('finance') THEN RETURN erp.sana_denied('finance'); END IF;
  RETURN jsonb_build_object(
    'by_drawer', (SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM (
       SELECT CASE a.group_mask WHEN 1 THEN 'assets' WHEN 2 THEN 'liabilities' WHEN 3 THEN 'equity' WHEN 4 THEN 'revenue'
                                WHEN 5 THEN 'cost_of_sales' WHEN 6 THEN 'expenses' ELSE 'other' END AS k,
              sum(coalesce(a.balance_local, 0) + coalesce(sf.amount, 0)) AS v
         FROM erp.account a
         LEFT JOIN (   -- Southfield-posted lines (SAP's are already in balance_local), from the partial index
           SELECT jl.company_code, jl.acct_code, sum(jl.debit - jl.credit) AS amount
             FROM erp.journal_entry je
             JOIN erp.journal_line jl ON jl.company_code = je.company_code AND jl.trans_id = je.trans_id
            WHERE je.source <> 'sap' AND (p_company IS NULL OR je.company_code = p_company)
            GROUP BY 1, 2) sf ON sf.company_code = a.company_code AND sf.acct_code = a.acct_code
        WHERE a.postable AND (p_company IS NULL OR a.company_code = p_company) GROUP BY 1) a),
    'payables_due_7_days', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(total - coalesce(paid,0)), 0)) FROM erp.document
       WHERE doc_kind = 'ap_invoice' AND status = 'open' AND due_date <= current_date + 7 AND (p_company IS NULL OR company_code = p_company)),
    'journals_last_30_days', (SELECT count(*) FROM erp.journal_entry WHERE ref_date >= current_date - 30 AND (p_company IS NULL OR company_code = p_company)),
    'links', jsonb_build_array(jsonb_build_object('label', 'Chart of accounts', 'link', '/financials/accounts'),
                               jsonb_build_object('label', 'Journal entries', 'link', '/financials/journals')));
END $$;

REVOKE ALL ON FUNCTION erp.sana_finance_summary(varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_finance_summary(varchar) TO authenticated;
NOTIFY pgrst, 'reload schema';

