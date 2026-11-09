-- 26_reports.sql · A11 · Reports, Control Tower rules, AI assistant (read-only + AI). Safe to run twice.
--
-- Everything here READS with the user's own rights:
--   reports        – rpt_trial_balance, rpt_balance_sheet, rpt_profit_loss, rpt_ar_aging, rpt_ap_aging, rpt_sales_analysis,
--                    rpt_open_items, rpt_inventory_in_warehouse, rpt_inventory_valuation. Each is STABLE SECURITY INVOKER, so the
--                    A1 module policies and row rules apply; each starts with _rpt_need (company + module, 42501 when missing).
--   Control Tower  – five more rules next to the Stage 1 checks: ct_count_variance, ct_bank_change, ct_price_increase,
--                    ct_duplicate_invoice, ct_checkin_outside (SECURITY INVOKER; a user without the module gets no rows), and
--                    control_findings(company) = the 5 Stage 1 checks (erp.control_checks, unchanged) + the 5 new ones, each
--                    with severity, record link and amount. Limits: erp.control_setting (design values as fallbacks).
--   AI assistant   – ai_status, ai_pick_tools, ai_ask_context (SECURITY INVOKER: the tools are the report functions above,
--                    run under the caller's JWT; a tool the user can't read is recorded as refused, never run with more rights),
--                    ai_log / ai_log_answer (audit_log actor = 'ai:assistant'). No AI function changes business data.
-- The only writes: control_setting_set (admin full, audited) and the AI audit rows.
--
-- Business values: the Control Tower limits are the design's (count variance over 1 %, purchase price over the last + 10 %,
-- supplier bank details changed in the last 30 days). The 30-day look-back for counts and check-ins is a display window
-- (A11 walkthrough › Needs from Ashif). Nothing is seeded for real companies.

-- ============ Control Tower limits ============
CREATE TABLE IF NOT EXISTS erp.control_setting (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    rule_code      text NOT NULL CHECK (rule_code IN ('count_variance_pct', 'price_increase_pct', 'bank_change_days',
                                                      'count_window_days', 'checkin_window_days')),
    limit_value    numeric(19,4) NOT NULL CHECK (limit_value > 0),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, rule_code)
);
ALTER TABLE erp.control_setting ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.control_setting FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.control_setting TO authenticated;
DROP POLICY IF EXISTS control_setting_read ON erp.control_setting;
CREATE POLICY control_setting_read ON erp.control_setting FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- Design values (Control Tower canvas / A11 prompt) used when a company has no row.
CREATE OR REPLACE FUNCTION erp._ct_default(p_rule text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_rule WHEN 'count_variance_pct' THEN 1 WHEN 'price_increase_pct' THEN 10 WHEN 'bank_change_days' THEN 30
                     WHEN 'count_window_days' THEN 30 WHEN 'checkin_window_days' THEN 30 END::numeric
$$;
CREATE OR REPLACE FUNCTION erp._ct_limit(p_company varchar, p_rule text) RETURNS numeric
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT s.limit_value FROM erp.control_setting s WHERE s.company_code = p_company AND s.rule_code = p_rule),
                  erp._ct_default(p_rule))
$$;

-- p_value NULL = back to the design value.
CREATE OR REPLACE FUNCTION erp.control_setting_set(p_company varchar, p_rule text, p_value numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_old numeric;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF NOT erp.can_write('admin') THEN
    RAISE EXCEPTION 'Only a system admin with full Administration access can change Control Tower limits.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF erp._ct_default(p_rule) IS NULL THEN
    RAISE EXCEPTION 'Control Tower rule % does not exist.', coalesce(p_rule, '(empty)') USING ERRCODE = 'P0001';
  END IF;
  IF p_value IS NOT NULL AND (p_value <= 0 OR p_value > 100000) THEN
    RAISE EXCEPTION 'Enter a limit above 0.' USING ERRCODE = 'P0001';
  END IF;
  SELECT limit_value INTO v_old FROM erp.control_setting WHERE company_code = p_company AND rule_code = p_rule FOR UPDATE;
  IF p_value IS NULL THEN
    DELETE FROM erp.control_setting WHERE company_code = p_company AND rule_code = p_rule;
  ELSE
    INSERT INTO erp.control_setting (company_code, rule_code, limit_value, updated_by, updated_at)
    VALUES (p_company, p_rule, p_value, erp.current_user_id(), now())
    ON CONFLICT (company_code, rule_code) DO UPDATE SET limit_value = EXCLUDED.limit_value, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'control_setting_set', 'control_setting', p_rule,
          jsonb_build_object('from', v_old, 'to', p_value, 'default', erp._ct_default(p_rule)));
  RETURN jsonb_build_object('rule_code', p_rule, 'limit_value', coalesce(p_value, erp._ct_default(p_rule)), 'is_default', p_value IS NULL);
END $$;

-- ============ Report helpers ============
-- Company + module check for a report. SECURITY INVOKER: the report itself still reads through RLS.
CREATE OR REPLACE FUNCTION erp._rpt_need(p_company varchar, p_modules text[], p_label text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE
  m text;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR btrim(p_company) = '' OR p_company = 'GRP' THEN
    RAISE EXCEPTION 'Choose one company to run this report.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', p_company USING ERRCODE = '42501';
  END IF;
  FOREACH m IN ARRAY p_modules LOOP
    IF erp.can_read(m) THEN RETURN; END IF;
  END LOOP;
  RAISE EXCEPTION 'Your position does not include %. Ask the system admin if you need it.', p_label USING ERRCODE = '42501';
END $$;

CREATE OR REPLACE FUNCTION erp._rpt_range(p_from date, p_to date) RETURNS void LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'Choose the from and to dates.' USING ERRCODE = 'P0001';
  END IF;
  IF p_to < p_from THEN
    RAISE EXCEPTION 'The to date is before the from date.' USING ERRCODE = 'P0001';
  END IF;
  IF p_to - p_from > 3660 THEN
    RAISE EXCEPTION 'Choose a period of 10 years or less.' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Record link for a marketing document (route names = src/features/erp/modules.ts › DOC_KINDS).
CREATE OR REPLACE FUNCTION erp._doc_link(p_company varchar, p_obj integer, p_entry integer) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '/docs/' || CASE p_obj WHEN 23 THEN 'sales_quotation' WHEN 17 THEN 'sales_order' WHEN 15 THEN 'delivery' WHEN 16 THEN 'sales_return'
                                WHEN 203 THEN 'ar_down_payment' WHEN 13 THEN 'ar_invoice' WHEN 14 THEN 'ar_credit_note'
                                WHEN 1470000113 THEN 'purchase_request' WHEN 540000006 THEN 'purchase_quotation' WHEN 22 THEN 'purchase_order'
                                WHEN 20 THEN 'goods_receipt_po' WHEN 21 THEN 'goods_return' WHEN 204 THEN 'ap_down_payment'
                                WHEN 18 THEN 'ap_invoice' WHEN 19 THEN 'ap_credit_note' WHEN 1250000001 THEN 'transfer_request'
                                WHEN 67 THEN 'inventory_transfer' WHEN 59 THEN 'goods_receipt' WHEN 60 THEN 'goods_issue' ELSE 'unknown' END
         || '/' || p_company || '/' || p_entry
$$;

-- ============ Financial reports (Financials read) ============
-- Trial balance from the journal: opening (before p_from), period debit / credit, closing. Accounts with no amounts are left out.
CREATE OR REPLACE FUNCTION erp.rpt_trial_balance(p_company varchar, p_from date, p_to date)
RETURNS TABLE (acct_code varchar, acct_name text, group_mask smallint, opening numeric, debit numeric, credit numeric, closing numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['finance'], 'Financials');
  PERFORM erp._rpt_range(p_from, p_to);
  RETURN QUERY
  WITH l AS (
    SELECT jl.acct_code AS code,
           round(sum(CASE WHEN je.ref_date < p_from THEN jl.debit - jl.credit ELSE 0 END), 2) AS op,
           round(sum(CASE WHEN je.ref_date >= p_from THEN jl.debit ELSE 0 END), 2) AS dr,
           round(sum(CASE WHEN je.ref_date >= p_from THEN jl.credit ELSE 0 END), 2) AS cr
      FROM erp.journal_line jl
      JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
     WHERE jl.company_code = p_company AND je.ref_date <= p_to
     GROUP BY jl.acct_code)
  SELECT l.code, coalesce(a.name, l.code::text), a.group_mask, l.op, l.dr, l.cr, l.op + l.dr - l.cr
    FROM l LEFT JOIN erp.account a ON a.company_code = p_company AND a.acct_code = l.code
   WHERE l.op <> 0 OR l.dr <> 0 OR l.cr <> 0
   ORDER BY l.code;
END $$;

-- Balance sheet at a date: assets (group 1, debit − credit), liabilities (2) and equity (3) as credit − debit, plus the result of
-- the profit and loss accounts to that date as one equity line (acct_code NULL). Assets = liabilities + equity.
CREATE OR REPLACE FUNCTION erp.rpt_balance_sheet(p_company varchar, p_as_of date)
RETURNS TABLE (section text, sort smallint, acct_code varchar, acct_name text, amount numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['finance'], 'Financials');
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'Choose the date of the balance sheet.' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  WITH b AS (
    SELECT jl.acct_code AS code, round(sum(jl.debit - jl.credit), 2) AS bal
      FROM erp.journal_line jl
      JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
     WHERE jl.company_code = p_company AND je.ref_date <= p_as_of
     GROUP BY jl.acct_code),
  x AS (
    SELECT b.code, b.bal, a.name, a.group_mask AS gm
      FROM b LEFT JOIN erp.account a ON a.company_code = p_company AND a.acct_code = b.code)
  SELECT * FROM (
    SELECT CASE x.gm WHEN 1 THEN 'assets' WHEN 2 THEN 'liabilities' ELSE 'equity' END, x.gm::smallint, x.code, coalesce(x.name, x.code::text),
           CASE WHEN x.gm = 1 THEN x.bal ELSE -x.bal END
      FROM x WHERE x.gm IN (1, 2, 3) AND x.bal <> 0
    UNION ALL
    SELECT 'equity', 3::smallint, NULL::varchar, 'Current period result', coalesce(-sum(x.bal), 0)
      FROM x WHERE coalesce(x.gm, 0) NOT IN (1, 2, 3)) r
   ORDER BY 2, 3 NULLS LAST;
END $$;

-- Profit and loss for a period: revenue (group 4) and other income/expense (7–9, and accounts without a group) as credit − debit,
-- cost of sales (5) and expenses (6) as debit − credit, then the net profit (= credit − debit of all of them).
CREATE OR REPLACE FUNCTION erp.rpt_profit_loss(p_company varchar, p_from date, p_to date)
RETURNS TABLE (section text, sort smallint, acct_code varchar, acct_name text, amount numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['finance'], 'Financials');
  PERFORM erp._rpt_range(p_from, p_to);
  RETURN QUERY
  WITH b AS (
    SELECT jl.acct_code AS code, round(sum(jl.credit - jl.debit), 2) AS net
      FROM erp.journal_line jl
      JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
     WHERE jl.company_code = p_company AND je.ref_date BETWEEN p_from AND p_to
     GROUP BY jl.acct_code),
  x AS (
    SELECT b.code, b.net, a.name, coalesce(a.group_mask, 9) AS gm
      FROM b LEFT JOIN erp.account a ON a.company_code = p_company AND a.acct_code = b.code
     WHERE coalesce(a.group_mask, 9) NOT IN (1, 2, 3))
  SELECT * FROM (
    SELECT CASE x.gm WHEN 4 THEN 'revenue' WHEN 5 THEN 'cost_of_sales' WHEN 6 THEN 'expenses' ELSE 'other' END,
           CASE x.gm WHEN 4 THEN 1 WHEN 5 THEN 2 WHEN 6 THEN 3 ELSE 4 END::smallint, x.code, coalesce(x.name, x.code::text),
           CASE WHEN x.gm IN (5, 6) THEN -x.net ELSE x.net END
      FROM x WHERE x.net <> 0
    UNION ALL
    SELECT 'net_profit', 9::smallint, NULL::varchar, 'Net profit', coalesce(sum(x.net), 0) FROM x) r
   ORDER BY 2, 3 NULLS LAST;
END $$;

-- ============ Business partner reports ============
-- Aging of open documents at a date, by days past the due date. Amounts are open now (total − paid); credit memos count negative.
CREATE OR REPLACE FUNCTION erp._rpt_aging(p_company varchar, p_as_of date, p_objs integer[])
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  WITH o AS (
    SELECT d.card_code AS cc, d.card_name AS cn, round(d.sign * (coalesce(d.total, 0) - coalesce(d.paid, 0)), 2) AS amt,
           p_as_of - coalesce(d.due_date, d.doc_date) AS late
      FROM erp.document d
     WHERE d.company_code = p_company AND d.obj_type = ANY (p_objs) AND d.status = 'open' AND d.doc_date <= p_as_of
       AND coalesce(d.total, 0) - coalesce(d.paid, 0) <> 0)
  SELECT o.cc, max(o.cn), count(*),
         coalesce(sum(o.amt) FILTER (WHERE o.late <= 0), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 1 AND 30), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 31 AND 60), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 61 AND 90), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late > 90), 0), sum(o.amt)
    FROM o GROUP BY o.cc ORDER BY sum(o.amt) DESC, o.cc
$$;

CREATE OR REPLACE FUNCTION erp.rpt_ar_aging(p_company varchar, p_as_of date)
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['sales', 'finance'], 'Sales or Financials');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'Choose the aging date.' USING ERRCODE = 'P0001'; END IF;
  RETURN QUERY SELECT * FROM erp._rpt_aging(p_company, p_as_of, ARRAY[13, 14]);
END $$;

CREATE OR REPLACE FUNCTION erp.rpt_ap_aging(p_company varchar, p_as_of date)
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['purchase', 'finance'], 'Purchasing or Financials');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'Choose the aging date.' USING ERRCODE = 'P0001'; END IF;
  RETURN QUERY SELECT * FROM erp._rpt_aging(p_company, p_as_of, ARRAY[18, 19]);
END $$;

-- ============ Sales and Purchasing ============
-- Sales analysis from A/R invoices less A/R credit memos (not cancelled), by customer, item or salesperson.
-- Gross profit = net sales − cost (the line's stock price × quantity).
CREATE OR REPLACE FUNCTION erp.rpt_sales_analysis(p_company varchar, p_from date, p_to date, p_by text DEFAULT 'customer')
RETURNS TABLE (key text, name text, docs bigint, qty numeric, net_sales numeric, gross_profit numeric, margin_pct numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['sales', 'finance'], 'Sales or Financials');
  PERFORM erp._rpt_range(p_from, p_to);
  IF coalesce(p_by, 'customer') NOT IN ('customer', 'item', 'salesperson') THEN
    RAISE EXCEPTION 'Group sales by customer, item or salesperson.' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  WITH l AS (
    SELECT CASE coalesce(p_by, 'customer') WHEN 'customer' THEN d.card_code::text WHEN 'item' THEN coalesce(dl.item_code::text, '—')
                ELSE coalesce(dl.slp_code, d.slp_code, -1)::text END AS k,
           CASE coalesce(p_by, 'customer') WHEN 'customer' THEN d.card_name WHEN 'item' THEN dl.description
                ELSE (SELECT s.name FROM erp.salesperson s WHERE s.company_code = d.company_code AND s.slp_code = coalesce(dl.slp_code, d.slp_code)) END AS n,
           d.obj_type AS ot, d.doc_entry AS de,
           d.sign * coalesce(dl.quantity, 0) AS q,
           d.sign * coalesce(dl.line_total, 0) AS net,
           d.sign * coalesce(dl.stock_price, dl.gross_buy_price, 0) * coalesce(dl.quantity, 0) AS cost
      FROM erp.document d
      JOIN erp.document_line dl ON dl.company_code = d.company_code AND dl.obj_type = d.obj_type AND dl.doc_entry = d.doc_entry
     WHERE d.company_code = p_company AND d.obj_type IN (13, 14) AND d.status NOT IN ('draft', 'cancelled', 'cancellation')
       AND d.doc_date BETWEEN p_from AND p_to)
  SELECT l.k, CASE WHEN l.k = '-1' THEN 'No salesperson' ELSE coalesce(max(l.n), l.k) END, count(DISTINCT (l.ot, l.de)),
         round(sum(l.q), 3), round(sum(l.net), 2), round(sum(l.net - l.cost), 2),
         CASE WHEN sum(l.net) <> 0 THEN round(sum(l.net - l.cost) / sum(l.net) * 100, 1) END
    FROM l GROUP BY l.k ORDER BY sum(l.net) DESC, l.k;
END $$;

-- Open documents (quotations, orders, deliveries, requests, POs, GRPOs, invoices, down payments, transfer requests).
-- open_amount: invoices / memos / down payments = total − paid; others = the open share of each line. The user's row rules decide
-- which kinds appear (Sales kinds for Sales, Purchasing kinds for Purchasing…).
CREATE OR REPLACE FUNCTION erp.rpt_open_items(p_company varchar, p_kind text DEFAULT NULL)
RETURNS TABLE (doc_kind text, obj_type integer, doc_entry integer, doc_no text, doc_date date, due_date date, card_code varchar,
               card_name text, currency varchar, total numeric, open_amount numeric, days_open integer, link text)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['sales', 'purchase', 'finance', 'inventory'], 'Sales, Purchasing, Inventory or Financials');
  IF nullif(p_kind, '') IS NOT NULL AND p_kind NOT IN ('sales_quotation', 'sales_order', 'delivery', 'ar_down_payment', 'ar_invoice',
       'ar_credit_note', 'purchase_request', 'purchase_quotation', 'purchase_order', 'goods_receipt_po', 'ap_down_payment', 'ap_invoice',
       'ap_credit_note', 'transfer_request') THEN
    RAISE EXCEPTION 'Document kind % has no open items list.', p_kind USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  SELECT d.doc_kind, d.obj_type, d.doc_entry, coalesce(w.doc_no, d.doc_num::text), d.doc_date, d.due_date, d.card_code, d.card_name,
         d.currency, round(coalesce(d.total, 0), 2),
         round(CASE WHEN d.obj_type IN (13, 14, 203, 18, 19, 204) THEN coalesce(d.total, 0) - coalesce(d.paid, 0)
                    ELSE coalesce((SELECT sum(CASE WHEN coalesce(dl.quantity, 0) = 0 THEN 0
                                                   ELSE coalesce(dl.open_qty, dl.quantity) / dl.quantity * coalesce(dl.line_total, 0) END)
                                     FROM erp.document_line dl
                                    WHERE dl.company_code = d.company_code AND dl.obj_type = d.obj_type AND dl.doc_entry = d.doc_entry),
                                  coalesce(d.total, 0)) END, 2),
         (current_date - d.doc_date)::integer,
         erp._doc_link(d.company_code, d.obj_type, d.doc_entry)
    FROM erp.document d
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.status = 'open'
     AND d.obj_type IN (23, 17, 15, 203, 13, 14, 1470000113, 540000006, 22, 20, 204, 18, 19, 1250000001)
     AND (nullif(p_kind, '') IS NULL OR d.doc_kind = p_kind)
   ORDER BY d.doc_date, d.obj_type, d.doc_entry;
END $$;

-- ============ Inventory ============
-- Stock and value by warehouse (value = on hand × the warehouse average cost, else the item's).
CREATE OR REPLACE FUNCTION erp.rpt_inventory_in_warehouse(p_company varchar, p_whs text DEFAULT NULL)
RETURNS TABLE (whs_code varchar, whs_name text, item_code varchar, item_name text, on_hand numeric, committed numeric, on_order numeric,
               available numeric, avg_cost numeric, value numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['inventory', 'sales', 'purchase'], 'Inventory, Sales or Purchasing');
  RETURN QUERY
  SELECT s.whs_code, w.name, s.item_code, i.name, round(s.on_hand, 3), round(s.committed, 3), round(s.on_order, 3),
         round(s.on_hand - s.committed + s.on_order, 3), round(coalesce(s.avg_cost, i.avg_cost, 0), 4),
         round(s.on_hand * coalesce(s.avg_cost, i.avg_cost, 0), 2)
    FROM erp.stock_balance s
    JOIN erp.item i ON i.company_code = s.company_code AND i.item_code = s.item_code
    LEFT JOIN erp.warehouse w ON w.company_code = s.company_code AND w.whs_code = s.whs_code
   WHERE s.company_code = p_company AND (nullif(p_whs, '') IS NULL OR s.whs_code = p_whs)
     AND (s.on_hand <> 0 OR s.committed <> 0 OR s.on_order <> 0)
   ORDER BY s.whs_code, s.item_code;
END $$;

-- Inventory valuation now, per item across warehouses, with its item group.
CREATE OR REPLACE FUNCTION erp.rpt_inventory_valuation(p_company varchar)
RETURNS TABLE (item_group integer, group_name text, item_code varchar, item_name text, on_hand numeric, avg_cost numeric, value numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['inventory'], 'Inventory');
  RETURN QUERY
  WITH v AS (
    SELECT s.item_code AS ic, sum(s.on_hand) AS qty, sum(round(s.on_hand * coalesce(s.avg_cost, i.avg_cost, 0), 2)) AS val
      FROM erp.stock_balance s JOIN erp.item i ON i.company_code = s.company_code AND i.item_code = s.item_code
     WHERE s.company_code = p_company
     GROUP BY s.item_code HAVING sum(s.on_hand) <> 0)
  SELECT i.group_code, g.name, v.ic, i.name, round(v.qty, 3), CASE WHEN v.qty <> 0 THEN round(v.val / v.qty, 4) END, v.val
    FROM v JOIN erp.item i ON i.company_code = p_company AND i.item_code = v.ic
    LEFT JOIN erp.item_group g ON g.company_code = p_company AND g.group_code = i.group_code
   ORDER BY v.val DESC, v.ic;
END $$;

-- ============ Control Tower: five more rules (SECURITY INVOKER; a user without the module gets no rows) ============
-- Stock count lines (pending approval or posted, last 30 days) whose variance is over 1 % of the system quantity (system 0 = over).
-- Read through inv_count_info, so the blind-count rule of A7 still decides what is shown.
CREATE OR REPLACE FUNCTION erp.ct_count_variance(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric, link text)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
DECLARE
  c    record;
  info jsonb;
  ln   jsonb;
  v_sys numeric;
  v_var numeric;
  v_lim numeric;
BEGIN
  IF NOT erp.can_read('inventory') THEN RETURN; END IF;
  FOR c IN SELECT ic.company_code AS cc, ic.count_id, ic.doc_no, ic.whs_code, ic.state FROM erp.inv_count ic
            WHERE (p_company IS NULL OR ic.company_code = p_company) AND ic.state IN ('pending_approval', 'posted')
              AND ic.count_date >= current_date - erp._ct_limit(ic.company_code, 'count_window_days')::integer
            ORDER BY ic.count_date DESC, ic.count_id DESC LOOP
    v_lim := erp._ct_limit(c.cc, 'count_variance_pct');
    info := erp.inv_count_info(c.cc, c.count_id);
    FOR ln IN SELECT x FROM jsonb_array_elements(coalesce(info -> 'report' -> 'lines', '[]'::jsonb)) x LOOP
      v_sys := (ln ->> 'system_qty')::numeric;
      v_var := (ln ->> 'variance')::numeric;
      CONTINUE WHEN v_var IS NULL OR v_var = 0;
      CONTINUE WHEN v_sys > 0 AND abs(v_var) / v_sys * 100 <= v_lim;
      check_code := 'count_variance'; severity := 'warning'; company_code := c.cc; ref := 'count:' || c.count_id;
      title := c.doc_no || ' · ' || (ln ->> 'item_code');
      detail := 'Counted ' || trim(to_char((ln ->> 'counted_qty')::numeric, 'FM999,999,990.###')) || ', system '
                || trim(to_char(v_sys, 'FM999,999,990.###')) || ' in ' || c.whs_code
                || CASE WHEN v_sys > 0 THEN ' (' || to_char(v_var / v_sys * 100, 'FMS990.0') || ' %, limit ' || trim(to_char(v_lim, 'FM990.##')) || ' %)'
                        ELSE ' (nothing on the system)' END
                || CASE c.state WHEN 'posted' THEN ' · posted' ELSE ' · waiting for approval' END;
      amount := abs(coalesce((ln ->> 'value')::numeric, 0));
      link := '/inventory/counts/' || c.cc || '/' || c.count_id;
      RETURN NEXT;
    END LOOP;
  END LOOP;
END $$;

-- Supplier bank details added or changed in the last 30 days (latest change per supplier). Amount = what is open to pay them now.
CREATE OR REPLACE FUNCTION erp.ct_bank_change(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric, link text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT 'bank_change', 'critical', x.company_code, 'bp:' || x.card_code, coalesce(bp.name, x.card_code::text),
         'Bank details ' || x.change_kind || ' on ' || to_char(x.changed_at AT TIME ZONE 'Asia/Dubai', 'DD Mon YYYY')
           || '. Confirm by phone before paying.',
         (SELECT round(sum(coalesce(d.total, 0) - coalesce(d.paid, 0)), 2) FROM erp.document d
           WHERE d.company_code = x.company_code AND d.card_code = x.card_code AND d.obj_type IN (18, 204) AND d.status = 'open'),
         '/bp/' || x.company_code || '/' || x.card_code
    FROM (SELECT DISTINCT ON (c.company_code, c.card_code) c.company_code, c.card_code, c.change_kind, c.changed_at
            FROM erp.bp_bank_change c
           WHERE (p_company IS NULL OR c.company_code = p_company)
             AND c.changed_at >= now() - make_interval(days => erp._ct_limit(c.company_code, 'bank_change_days')::integer)
           ORDER BY c.company_code, c.card_code, c.changed_at DESC) x
    JOIN erp.business_partner bp ON bp.company_code = x.company_code AND bp.card_code = x.card_code AND bp.kind = 'supplier'
$$;

-- Open or waiting purchase order lines priced more than 10 % above the last purchase price of the item (PO, GRPO or A/P invoice
-- dated on or before the order, not this order or documents copied from it). Amount = the extra cost of the line.
CREATE OR REPLACE FUNCTION erp.ct_price_increase(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric, link text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT 'price_increase', 'warning', d.company_code, 'purchase_order:' || d.doc_entry,
         coalesce(w.doc_no, d.doc_num::text) || ' · ' || l.item_code,
         coalesce(d.card_name, d.card_code::text, '—') || ': ' || to_char(l.price, 'FM999,999,990.00') || ' vs last ' || to_char(lp.price, 'FM999,999,990.00')
           || ' on ' || lp.doc_no || ' (' || to_char((l.price / lp.price - 1) * 100, 'FM9990.0') || ' % higher)',
         round((l.price - lp.price) * coalesce(l.quantity, 0), 2),
         '/docs/purchase_order/' || d.company_code || '/' || d.doc_entry
    FROM erp.document d
    JOIN erp.document_line l ON l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
    CROSS JOIN LATERAL (
      SELECT l2.price, coalesce(w2.doc_no, d2.doc_num::text) AS doc_no
        FROM erp.document_line l2
        JOIN erp.document d2 ON d2.company_code = l2.company_code AND d2.obj_type = l2.obj_type AND d2.doc_entry = l2.doc_entry
        LEFT JOIN erp.doc_workflow w2 ON w2.company_code = d2.company_code AND w2.obj_type = d2.obj_type AND w2.doc_entry = d2.doc_entry
       WHERE l2.company_code = d.company_code AND l2.item_code = l.item_code AND l2.obj_type IN (22, 20, 18) AND l2.price > 0
         AND d2.status NOT IN ('draft', 'cancelled', 'cancellation') AND d2.doc_date <= d.doc_date
         AND NOT (d2.obj_type = 22 AND d2.doc_entry = d.doc_entry)
         AND NOT coalesce(l2.base_obj_type = 22 AND l2.base_doc_entry = d.doc_entry, false)
       ORDER BY d2.doc_date DESC, d2.doc_entry DESC, l2.line_num
       LIMIT 1) lp
   WHERE (p_company IS NULL OR d.company_code = p_company) AND d.obj_type = 22 AND d.status IN ('open', 'draft')
     AND coalesce(w.state, '') NOT IN ('rejected', 'cancelled')
     AND l.price > lp.price * (1 + erp._ct_limit(d.company_code, 'price_increase_pct') / 100)
$$;

-- The same supplier invoice number (NumAtCard) on more than one A/P invoice of the same supplier (not cancelled).
CREATE OR REPLACE FUNCTION erp.ct_duplicate_invoice(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric, link text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT 'duplicate_invoice', 'critical', x.company_code, 'ap_invoice:' || x.doc_entry,
         coalesce(x.card_name, x.card_code::text) || ' · ' || x.ref,
         'Supplier invoice ' || x.ref || ' is on ' || x.n || ' A/P invoices: ' || x.nos, round(coalesce(x.total, 0), 2),
         '/docs/ap_invoice/' || x.company_code || '/' || x.doc_entry
    FROM (SELECT d.company_code, d.doc_entry, d.card_code, d.card_name, d.total, btrim(d.customer_ref) AS ref,
                 count(*) OVER g AS n,
                 string_agg(coalesce(w.doc_no, d.doc_num::text), ', ') OVER (g ORDER BY d.doc_date, d.doc_entry
                                                                              ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS nos
            FROM erp.document d
            LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
           WHERE (p_company IS NULL OR d.company_code = p_company) AND d.obj_type = 18
             AND d.status NOT IN ('cancelled', 'cancellation', 'draft') AND nullif(btrim(d.customer_ref), '') IS NOT NULL
          WINDOW g AS (PARTITION BY d.company_code, d.card_code, upper(btrim(d.customer_ref)))) x
   WHERE x.n > 1
$$;

-- Check-ins or check-outs flagged outside the site area in the last 30 days. HR users only (the staff portal shows each person
-- their own). Amount = the distance from the site in metres.
CREATE OR REPLACE FUNCTION erp.ct_checkin_outside(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric, link text)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
#variable_conflict use_column
BEGIN
  IF erp.module_level('hr') IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT 'checkin_outside', 'warning', a.company_code, 'employee:' || a.emp_id, coalesce(a.emp_name, a.emp_id::text),
         CASE WHEN 'outside_site' = ANY (a.in_flags) THEN 'Checked in ' ELSE 'Checked out ' END
           || to_char(CASE WHEN 'outside_site' = ANY (a.in_flags) THEN a.check_in_at ELSE a.check_out_at END AT TIME ZONE 'Asia/Dubai', 'DD Mon YYYY HH24:MI')
           || ' outside the ' || coalesce(a.in_site, 'site') || ' area',
         greatest(CASE WHEN 'outside_site' = ANY (a.in_flags) THEN a.in_distance_m END,
                  CASE WHEN 'outside_site' = ANY (a.out_flags) THEN a.out_distance_m END)::numeric,
         '/hr/employees/' || a.company_code || '/' || a.emp_id
    FROM erp.attendance_list a
   WHERE (p_company IS NULL OR a.company_code = p_company) AND a.outside_site
     AND a.work_date >= current_date - erp._ct_limit(a.company_code, 'checkin_window_days')::integer
   ORDER BY a.work_date DESC;
END $$;

-- All Control Tower findings for the selected company (NULL = every company the user may see): the 5 Stage 1 checks from
-- erp.control_checks (unchanged) with their record link, and the 5 rules above. Critical first.
CREATE OR REPLACE FUNCTION erp.control_findings(p_company varchar DEFAULT NULL)
RETURNS TABLE (check_code text, severity text, company_code varchar, ref text, title text, detail text, amount numeric, link text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT * FROM (
    SELECT c.check_code, c.severity, c.company_code, c.ref, c.title, c.detail, c.amount,
           CASE c.check_code WHEN 'credit_limit' THEN '/bp/' || c.company_code || '/' || c.ref
                             WHEN 'low_stock' THEN '/items/' || c.company_code || '/' || split_part(c.ref, ' @ ', 1)
                             ELSE '/docs/' || split_part(c.ref, ':', 1) || '/' || c.company_code || '/' || split_part(c.ref, ':', 2) END
      FROM erp.control_checks(p_company) c
    UNION ALL SELECT * FROM erp.ct_count_variance(p_company)
    UNION ALL SELECT * FROM erp.ct_bank_change(p_company)
    UNION ALL SELECT * FROM erp.ct_price_increase(p_company)
    UNION ALL SELECT * FROM erp.ct_duplicate_invoice(p_company)
    UNION ALL SELECT * FROM erp.ct_checkin_outside(p_company)) f
   ORDER BY CASE f.severity WHEN 'critical' THEN 0 ELSE 1 END, f.check_code, f.company_code, f.ref
$$;

-- ============ AI assistant (only after A10 sets the provider) ============
-- Tools the assistant can call: each is a report function above (SECURITY INVOKER, run with the user's JWT) or the document
-- reader. A tool is offered to a user only when one of its modules is opened in Add-Ons › AI Assistant AND the user can read it,
-- and all its tables are opened there. The report function checks the user's rights again when it runs.
CREATE OR REPLACE FUNCTION erp._ai_tool_catalog() RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT '[
    {"tool": "trial_balance", "modules": ["finance"], "tables": ["account", "journal_entry", "journal_line"], "report": "trial-balance"},
    {"tool": "balance_sheet", "modules": ["finance"], "tables": ["account", "journal_entry", "journal_line"], "report": "balance-sheet"},
    {"tool": "profit_loss", "modules": ["finance"], "tables": ["account", "journal_entry", "journal_line"], "report": "profit-loss"},
    {"tool": "ar_aging", "modules": ["sales", "finance"], "tables": ["document"], "report": "ar-aging"},
    {"tool": "ap_aging", "modules": ["purchase", "finance"], "tables": ["document"], "report": "ap-aging"},
    {"tool": "sales_analysis", "modules": ["sales", "finance"], "tables": ["document", "document_line"], "report": "sales-analysis"},
    {"tool": "open_items", "modules": ["sales", "purchase", "finance", "inventory"], "tables": ["document"], "report": "open-items"},
    {"tool": "inventory_in_warehouse", "modules": ["inventory", "sales", "purchase"], "tables": ["stock_balance", "item"], "report": "inventory-in-warehouse"},
    {"tool": "inventory_valuation", "modules": ["inventory"], "tables": ["stock_balance", "item"], "report": "inventory-valuation"},
    {"tool": "document", "modules": ["sales", "purchase", "finance", "inventory"], "tables": ["document", "document_line"], "report": null}
  ]'::jsonb
$$;

-- Tools this user may use for this company now (empty when the assistant is off).
CREATE OR REPLACE FUNCTION erp._ai_allowed_tools(p_company varchar) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(array_agg(t ->> 'tool' ORDER BY o), '{}')
    FROM erp.ai_setting s
    CROSS JOIN LATERAL jsonb_array_elements(erp._ai_tool_catalog()) WITH ORDINALITY AS c(t, o)
   WHERE s.company_code = p_company AND s.enabled AND erp.current_user_id() IS NOT NULL AND erp.can_see(p_company)
     AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(t -> 'modules') m WHERE m = ANY (s.allowed_modules) AND erp.can_read(m))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(t -> 'tables') tb WHERE NOT tb = ANY (s.allowed_tables))
$$;

-- For the Ask AI panel: is the assistant set up for this company, and what may this user ask about?
CREATE OR REPLACE FUNCTION erp.ai_status(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s erp.ai_setting;
  v_used integer;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  SELECT * INTO s FROM erp.ai_setting WHERE company_code = p_company;
  SELECT requests INTO v_used FROM erp.ai_usage WHERE company_code = p_company AND month = to_char(now(), 'YYYY-MM');
  RETURN jsonb_build_object(
    'company', p_company,
    'configured', coalesce(s.enabled, false) AND s.chat_provider IS NOT NULL,
    'enabled', coalesce(s.enabled, false),
    'provider', s.chat_provider, 'model', s.chat_model,
    'remaining', CASE WHEN s.monthly_limit IS NULL THEN NULL ELSE greatest(s.monthly_limit - coalesce(v_used, 0), 0) END,
    'tools', to_jsonb(erp._ai_allowed_tools(p_company)),
    'can_setup', erp.can_write('admin'));
END $$;

-- Which tools answer a question: plain keyword routing (English and Arabic), at most 3, the document first when asked about one.
CREATE OR REPLACE FUNCTION erp.ai_pick_tools(p_question text, p_ref jsonb DEFAULT NULL) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((SELECT array_agg(t ORDER BY o) FROM (
    SELECT o, t FROM (SELECT lower(coalesce(p_question, '')) AS q) s CROSS JOIN LATERAL (VALUES
      (1, 'document', coalesce(p_ref ? 'obj_type' AND p_ref ? 'doc_entry', false)),
      (2, 'trial_balance', q ~ '(trial balance|ميزان المراجعة)'),
      (3, 'balance_sheet', q ~ '(balance sheet|assets|liabilit|equity|الميزانية)'),
      (4, 'profit_loss', q ~ '(profit|loss|p ?& ?l|margin|revenue|income|expense|الأرباح|ربح)'),
      (5, 'ar_aging', q ~ '(receivable|owe us|owes|ageing|aging|overdue|debtor|customer balance|ذمم مدينة|متأخر)' AND q !~ '(payable|we owe|supplier)'),
      (6, 'ap_aging', q ~ '(payable|we owe|supplier balance|owe .*supplier|creditor|ذمم دائنة)'),
      (7, 'sales_analysis', q ~ '(sales|sold|selling|best customer|top customer|top item|salesperson|مبيعات)'),
      (8, 'open_items', q ~ '(open (items|orders|documents|quotations|invoices|purchase)|backorder|not delivered|pending orders|مفتوحة)'),
      (9, 'inventory_in_warehouse', q ~ '(stock|inventory|warehouse|on hand|available|مخزون|مستودع)' AND q !~ '(valuation|stock value|value of stock|worth)'),
      (10, 'inventory_valuation', q ~ '(valuation|stock value|value of stock|worth|تقييم)')
    ) v(o, t, hit)
    WHERE hit ORDER BY o LIMIT 3) x), '{}')
$$;

-- Run one tool for the assistant with the caller's own rights (SECURITY INVOKER). Returns a short result: summary, up to 15 rows,
-- and the sources (record links) the answer may cite.
CREATE OR REPLACE FUNCTION erp._ai_run(p_tool text, p_company varchar, p_question text, p_ref jsonb) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE
  v_today date := current_date;
  v_ys date := date_trunc('year', current_date)::date;
  q text := lower(coalesce(p_question, ''));
  v_by text;
  v_rows jsonb;
  v_sum jsonb;
  v_src jsonb;
  d erp.document;
  v_rep text := '/reports/';
BEGIN
  IF p_tool = 'trial_balance' THEN
    SELECT jsonb_build_object('accounts', count(*), 'debit', coalesce(sum(debit), 0), 'credit', coalesce(sum(credit), 0),
                              'from', v_ys, 'to', v_today),
           coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY abs(r.closing) DESC) FROM (SELECT * FROM erp.rpt_trial_balance(p_company, v_ys, v_today) ORDER BY abs(closing) DESC LIMIT 15) r), '[]')
      INTO v_sum, v_rows FROM erp.rpt_trial_balance(p_company, v_ys, v_today);
    v_src := jsonb_build_array(jsonb_build_object('label', 'Trial balance ' || to_char(v_ys, 'DD Mon') || ' – ' || to_char(v_today, 'DD Mon YYYY'),
               'link', v_rep || 'trial-balance?company=' || p_company || '&from=' || v_ys || '&to=' || v_today))
             || coalesce((SELECT jsonb_agg(jsonb_build_object('label', 'Account ' || (r ->> 'acct_code') || ' ' || (r ->> 'acct_name'),
                                                              'link', '/financials/accounts?q=' || (r ->> 'acct_code')))
                            FROM (SELECT x AS r FROM jsonb_array_elements(v_rows) x LIMIT 5) y), '[]');
  ELSIF p_tool = 'balance_sheet' THEN
    SELECT jsonb_build_object('as_of', v_today,
             'assets', coalesce(sum(amount) FILTER (WHERE section = 'assets'), 0),
             'liabilities', coalesce(sum(amount) FILTER (WHERE section = 'liabilities'), 0),
             'equity', coalesce(sum(amount) FILTER (WHERE section = 'equity'), 0)),
           coalesce(jsonb_agg(to_jsonb(b)), '[]')
      INTO v_sum, v_rows FROM erp.rpt_balance_sheet(p_company, v_today) b;
    v_src := jsonb_build_array(jsonb_build_object('label', 'Balance sheet at ' || to_char(v_today, 'DD Mon YYYY'),
               'link', v_rep || 'balance-sheet?company=' || p_company || '&as_of=' || v_today));
  ELSIF p_tool = 'profit_loss' THEN
    SELECT jsonb_build_object('from', v_ys, 'to', v_today,
             'revenue', coalesce(sum(amount) FILTER (WHERE section = 'revenue'), 0),
             'cost_of_sales', coalesce(sum(amount) FILTER (WHERE section = 'cost_of_sales'), 0),
             'expenses', coalesce(sum(amount) FILTER (WHERE section = 'expenses'), 0),
             'other', coalesce(sum(amount) FILTER (WHERE section = 'other'), 0),
             'net_profit', coalesce(sum(amount) FILTER (WHERE section = 'net_profit'), 0)),
           coalesce(jsonb_agg(to_jsonb(p)), '[]')
      INTO v_sum, v_rows FROM erp.rpt_profit_loss(p_company, v_ys, v_today) p;
    v_src := jsonb_build_array(jsonb_build_object('label', 'Profit and loss ' || to_char(v_ys, 'DD Mon') || ' – ' || to_char(v_today, 'DD Mon YYYY'),
               'link', v_rep || 'profit-loss?company=' || p_company || '&from=' || v_ys || '&to=' || v_today));
  ELSIF p_tool IN ('ar_aging', 'ap_aging') THEN
    IF p_tool = 'ar_aging' THEN
      SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.total DESC), '[]') INTO v_rows FROM erp.rpt_ar_aging(p_company, v_today) a;
    ELSE
      SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.total DESC), '[]') INTO v_rows FROM erp.rpt_ap_aging(p_company, v_today) a;
    END IF;
    SELECT jsonb_build_object('as_of', v_today, 'partners', count(*), 'total', coalesce(sum((r ->> 'total')::numeric), 0),
                              'over_90', coalesce(sum((r ->> 'd90_plus')::numeric), 0), 'not_due', coalesce(sum((r ->> 'not_due')::numeric), 0)),
           coalesce((SELECT jsonb_agg(x) FROM (SELECT x FROM jsonb_array_elements(v_rows) x LIMIT 15) y), '[]')
      INTO v_sum, v_rows FROM jsonb_array_elements(v_rows) r;
    v_src := jsonb_build_array(jsonb_build_object('label', CASE p_tool WHEN 'ar_aging' THEN 'Customer receivables aging' ELSE 'Supplier payables aging' END
                                                  || ' at ' || to_char(v_today, 'DD Mon YYYY'),
               'link', v_rep || replace(p_tool, '_', '-') || '?company=' || p_company || '&as_of=' || v_today))
             || coalesce((SELECT jsonb_agg(jsonb_build_object('label', (r ->> 'card_code') || ' ' || coalesce(r ->> 'card_name', ''),
                                                              'link', '/bp/' || p_company || '/' || (r ->> 'card_code')))
                            FROM (SELECT x AS r FROM jsonb_array_elements(v_rows) x LIMIT 5) y), '[]');
  ELSIF p_tool = 'sales_analysis' THEN
    v_by := CASE WHEN q ~ '(item|product|sku|صنف)' THEN 'item' WHEN q ~ '(salesperson|sales person|rep\M|مندوب)' THEN 'salesperson' ELSE 'customer' END;
    SELECT jsonb_build_object('from', v_ys, 'to', v_today, 'by', v_by, 'groups', count(*),
                              'net_sales', coalesce(sum(net_sales), 0), 'gross_profit', coalesce(sum(gross_profit), 0)),
           coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM (SELECT * FROM erp.rpt_sales_analysis(p_company, v_ys, v_today, v_by) LIMIT 15) r), '[]')
      INTO v_sum, v_rows FROM erp.rpt_sales_analysis(p_company, v_ys, v_today, v_by);
    v_src := jsonb_build_array(jsonb_build_object('label', 'Sales analysis by ' || v_by || ' ' || to_char(v_ys, 'DD Mon') || ' – ' || to_char(v_today, 'DD Mon YYYY'),
               'link', v_rep || 'sales-analysis?company=' || p_company || '&from=' || v_ys || '&to=' || v_today || '&by=' || v_by))
             || CASE WHEN v_by IN ('customer', 'item') THEN
                  coalesce((SELECT jsonb_agg(jsonb_build_object('label', (r ->> 'key') || ' ' || coalesce(r ->> 'name', ''),
                                                                'link', CASE v_by WHEN 'customer' THEN '/bp/' ELSE '/items/' END || p_company || '/' || (r ->> 'key')))
                              FROM (SELECT x AS r FROM jsonb_array_elements(v_rows) x LIMIT 5) y), '[]')
                ELSE '[]'::jsonb END;
  ELSIF p_tool = 'open_items' THEN
    SELECT jsonb_build_object('documents', count(*), 'open_amount', coalesce(sum(open_amount), 0),
                              'by_kind', coalesce((SELECT jsonb_object_agg(k, n) FROM (SELECT doc_kind AS k, count(*) AS n FROM erp.rpt_open_items(p_company, NULL) GROUP BY 1) z), '{}')),
           coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM (SELECT * FROM erp.rpt_open_items(p_company, NULL) ORDER BY open_amount DESC LIMIT 15) r), '[]')
      INTO v_sum, v_rows FROM erp.rpt_open_items(p_company, NULL);
    v_src := jsonb_build_array(jsonb_build_object('label', 'Open items list', 'link', v_rep || 'open-items?company=' || p_company))
             || coalesce((SELECT jsonb_agg(jsonb_build_object('label', (r ->> 'doc_kind') || ' ' || (r ->> 'doc_no'), 'link', r ->> 'link'))
                            FROM (SELECT x AS r FROM jsonb_array_elements(v_rows) x LIMIT 5) y), '[]');
  ELSIF p_tool = 'inventory_in_warehouse' THEN
    SELECT jsonb_build_object('lines', count(*), 'on_hand', coalesce(sum(on_hand), 0), 'value', coalesce(sum(value), 0),
                              'warehouses', count(DISTINCT whs_code)),
           coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM (SELECT * FROM erp.rpt_inventory_in_warehouse(p_company, NULL) ORDER BY value DESC LIMIT 15) r), '[]')
      INTO v_sum, v_rows FROM erp.rpt_inventory_in_warehouse(p_company, NULL);
    v_src := jsonb_build_array(jsonb_build_object('label', 'Inventory in warehouse report', 'link', v_rep || 'inventory-in-warehouse?company=' || p_company))
             || coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_object('label', (r ->> 'item_code') || ' ' || coalesce(r ->> 'item_name', ''),
                                                                        'link', '/items/' || p_company || '/' || (r ->> 'item_code')))
                            FROM (SELECT x AS r FROM jsonb_array_elements(v_rows) x LIMIT 5) y), '[]');
  ELSIF p_tool = 'inventory_valuation' THEN
    SELECT jsonb_build_object('items', count(*), 'value', coalesce(sum(value), 0)),
           coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM (SELECT * FROM erp.rpt_inventory_valuation(p_company) LIMIT 15) r), '[]')
      INTO v_sum, v_rows FROM erp.rpt_inventory_valuation(p_company);
    v_src := jsonb_build_array(jsonb_build_object('label', 'Inventory valuation', 'link', v_rep || 'inventory-valuation?company=' || p_company))
             || coalesce((SELECT jsonb_agg(jsonb_build_object('label', (r ->> 'item_code') || ' ' || coalesce(r ->> 'item_name', ''),
                                                              'link', '/items/' || p_company || '/' || (r ->> 'item_code')))
                            FROM (SELECT x AS r FROM jsonb_array_elements(v_rows) x LIMIT 5) y), '[]');
  ELSIF p_tool = 'document' THEN
    PERFORM erp._rpt_need(p_company, ARRAY['sales', 'purchase', 'finance', 'inventory'], 'Sales, Purchasing, Inventory or Financials');
    SELECT * INTO d FROM erp.document x
     WHERE x.company_code = p_company AND x.obj_type = (p_ref ->> 'obj_type')::integer AND x.doc_entry = (p_ref ->> 'doc_entry')::integer;
    IF NOT FOUND THEN   -- not there, or the user's row rules hide it: same answer
      RAISE EXCEPTION 'You can''t read this document.' USING ERRCODE = '42501';
    END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object('line', l.line_num + 1, 'item_code', l.item_code, 'description', l.description,
                                                 'qty', l.quantity, 'price', l.price, 'discount_pct', l.discount_pct, 'line_total', l.line_total)
                              ORDER BY l.line_num), '[]')
      INTO v_rows FROM (SELECT * FROM erp.document_line x WHERE x.company_code = d.company_code AND x.obj_type = d.obj_type
                                                            AND x.doc_entry = d.doc_entry ORDER BY x.line_num LIMIT 15) l;
    v_sum := jsonb_build_object(
      'doc_kind', d.doc_kind, 'doc_no', coalesce((SELECT w.doc_no FROM erp.doc_workflow w WHERE w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry), d.doc_num::text),
      'status', d.status, 'source', d.source, 'doc_date', d.doc_date, 'due_date', d.due_date, 'card_code', d.card_code, 'card_name', d.card_name,
      'currency', d.currency, 'total', d.total, 'vat_total', d.vat_total, 'paid', d.paid,
      'lines', (SELECT count(*) FROM erp.document_line x WHERE x.company_code = d.company_code AND x.obj_type = d.obj_type AND x.doc_entry = d.doc_entry),
      'history', (SELECT jsonb_build_object('documents', count(*), 'average_total', round(avg(h.total), 2), 'last_date', max(h.doc_date))
                    FROM erp.document h WHERE h.company_code = d.company_code AND h.obj_type = d.obj_type AND h.card_code = d.card_code
                     AND h.doc_entry <> d.doc_entry AND h.status NOT IN ('cancelled', 'cancellation') AND h.doc_date >= d.doc_date - 365));
    v_src := jsonb_build_array(jsonb_build_object('label', initcap(replace(d.doc_kind, '_', ' ')) || ' ' || (v_sum ->> 'doc_no'),
                                                  'link', erp._doc_link(d.company_code, d.obj_type, d.doc_entry)))
             || CASE WHEN d.card_code IS NOT NULL THEN jsonb_build_array(jsonb_build_object('label', d.card_code || ' ' || coalesce(d.card_name, ''),
                                                                                             'link', '/bp/' || d.company_code || '/' || d.card_code))
                     ELSE '[]'::jsonb END;
  ELSE
    RAISE EXCEPTION 'Unknown assistant tool %.', p_tool USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('summary', v_sum, 'rows', v_rows, 'sources', coalesce(v_src, '[]'));
END $$;

-- Audit rows for the assistant (actor 'ai:assistant'; the signed-in user is in detail.user_id). Only the caller's own question.
CREATE OR REPLACE FUNCTION erp.ai_log(p_company varchar, p_question text, p_ref jsonb, p_tools jsonb, p_sources integer) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_id bigint;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES ('ai:assistant', p_company, 'ai_question', 'ai_assistant',
          CASE WHEN p_ref ? 'obj_type' THEN (p_ref ->> 'obj_type') || ':' || (p_ref ->> 'doc_entry') END,
          jsonb_build_object('user_id', erp.current_user_id(), 'question', left(p_question, 500), 'ref', p_ref,
                             'tools', coalesce(p_tools, '[]'::jsonb), 'sources', coalesce(p_sources, 0)))
  RETURNING audit_id INTO v_id;
  RETURN v_id;
END $$;

-- After the answer: who answered (provider name, or 'local-test' on the local stack) — only for the caller's own question.
CREATE OR REPLACE FUNCTION erp.ai_log_answer(p_audit_id bigint, p_responder text, p_chars integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  a erp.audit_log;
BEGIN
  SELECT * INTO a FROM erp.audit_log WHERE audit_id = p_audit_id AND actor = 'ai:assistant' AND action = 'ai_question';
  IF NOT FOUND OR (a.detail ->> 'user_id') IS DISTINCT FROM erp.current_user_id()::text OR a.at < now() - interval '15 minutes' THEN
    RAISE EXCEPTION 'This question is not yours to answer.' USING ERRCODE = '42501';
  END IF;
  IF p_responder IS NULL OR p_responder !~ '^[a-z0-9._:-]{1,40}$' THEN
    RAISE EXCEPTION 'Name the responder.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES ('ai:assistant', a.company_code, 'ai_answer', 'ai_assistant', p_audit_id::text,
          jsonb_build_object('user_id', erp.current_user_id(), 'responder', p_responder, 'chars', greatest(coalesce(p_chars, 0), 0)));
END $$;

-- The assistant's context for one question, gathered with the caller's own rights (SECURITY INVOKER). Never writes business data;
-- the question and the tools used (and refused) are logged as 'ai:assistant'.
CREATE OR REPLACE FUNCTION erp.ai_ask_context(p_company varchar, p_question text, p_ref jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE
  v_q     text := btrim(coalesce(p_question, ''));
  chk     jsonb;
  allowed text[];
  picked  text[];
  t       text;
  res     jsonb;
  tools   jsonb := '[]'::jsonb;
  srcs    jsonb := '[]'::jsonb;
  v_id    bigint;
BEGIN
  IF v_q = '' THEN
    RAISE EXCEPTION 'Type a question first.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_q) > 500 THEN
    RAISE EXCEPTION 'Keep the question under 500 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF p_ref IS NOT NULL AND (jsonb_typeof(p_ref) <> 'object' OR (p_ref ->> 'obj_type') !~ '^\d{1,10}$' OR (p_ref ->> 'doc_entry') !~ '^\d{1,10}$') THEN
    RAISE EXCEPTION 'The document reference is not valid.' USING ERRCODE = 'P0001';
  END IF;
  chk := erp.ai_request_check(p_company);          -- signed in, company, assistant on, monthly limit left
  allowed := erp._ai_allowed_tools(p_company);
  picked := erp.ai_pick_tools(v_q, p_ref);
  FOREACH t IN ARRAY picked LOOP
    IF NOT t = ANY (allowed) THEN
      tools := tools || jsonb_build_object('tool', t, 'status', 'not_allowed',
        'message', 'The assistant may not read this for you: it is not opened in Add-Ons › AI Assistant, or not in your position.');
      CONTINUE;
    END IF;
    BEGIN
      res := erp._ai_run(t, p_company, v_q, p_ref);
      tools := tools || (jsonb_build_object('tool', t, 'status', 'ok') || res);
      srcs := srcs || coalesce(res -> 'sources', '[]'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN
      tools := tools || jsonb_build_object('tool', t, 'status', 'refused', 'message', SQLERRM);
    END;
  END LOOP;
  SELECT coalesce(jsonb_agg(u.s ORDER BY u.o), '[]') INTO srcs
    FROM (SELECT e.s, min(e.o) AS o FROM jsonb_array_elements(srcs) WITH ORDINALITY AS e(s, o) GROUP BY e.s) u;
  v_id := erp.ai_log(p_company, v_q, p_ref,
            (SELECT coalesce(jsonb_agg(jsonb_build_object('tool', x ->> 'tool', 'status', x ->> 'status',
                                                          'rows', jsonb_array_length(coalesce(x -> 'rows', '[]'::jsonb)))), '[]')
               FROM jsonb_array_elements(tools) x),
            jsonb_array_length(srcs));
  RETURN jsonb_build_object('audit_id', v_id, 'company', p_company, 'question', v_q, 'ref', p_ref, 'tools', tools, 'sources', srcs,
                            'provider', chk ->> 'chat_provider', 'model', chk ->> 'chat_model', 'remaining', chk -> 'remaining',
                            'picked', to_jsonb(picked));
END $$;

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._ct_default(text), erp._ct_limit(varchar, text), erp._rpt_need(varchar, text[], text), erp._rpt_range(date, date),
  erp._doc_link(varchar, integer, integer), erp._rpt_aging(varchar, date, integer[]), erp._ai_tool_catalog(), erp._ai_allowed_tools(varchar),
  erp._ai_run(text, varchar, text, jsonb), erp.control_setting_set(varchar, text, numeric),
  erp.rpt_trial_balance(varchar, date, date), erp.rpt_balance_sheet(varchar, date), erp.rpt_profit_loss(varchar, date, date),
  erp.rpt_ar_aging(varchar, date), erp.rpt_ap_aging(varchar, date), erp.rpt_sales_analysis(varchar, date, date, text),
  erp.rpt_open_items(varchar, text), erp.rpt_inventory_in_warehouse(varchar, text), erp.rpt_inventory_valuation(varchar),
  erp.ct_count_variance(varchar), erp.ct_bank_change(varchar), erp.ct_price_increase(varchar), erp.ct_duplicate_invoice(varchar),
  erp.ct_checkin_outside(varchar), erp.control_findings(varchar), erp.ai_status(varchar), erp.ai_pick_tools(text, jsonb),
  erp.ai_log(varchar, text, jsonb, jsonb, integer), erp.ai_log_answer(bigint, text, integer), erp.ai_ask_context(varchar, text, jsonb)
  FROM PUBLIC, anon;
-- Invoker helpers are called inside the user's own reports, so authenticated needs EXECUTE on them; they grant no extra rights.
GRANT EXECUTE ON FUNCTION erp._ct_default(text), erp._ct_limit(varchar, text), erp._rpt_need(varchar, text[], text), erp._rpt_range(date, date),
  erp._doc_link(varchar, integer, integer), erp._rpt_aging(varchar, date, integer[]), erp._ai_tool_catalog(), erp._ai_allowed_tools(varchar),
  erp._ai_run(text, varchar, text, jsonb), erp.control_setting_set(varchar, text, numeric),
  erp.rpt_trial_balance(varchar, date, date), erp.rpt_balance_sheet(varchar, date), erp.rpt_profit_loss(varchar, date, date),
  erp.rpt_ar_aging(varchar, date), erp.rpt_ap_aging(varchar, date), erp.rpt_sales_analysis(varchar, date, date, text),
  erp.rpt_open_items(varchar, text), erp.rpt_inventory_in_warehouse(varchar, text), erp.rpt_inventory_valuation(varchar),
  erp.ct_count_variance(varchar), erp.ct_bank_change(varchar), erp.ct_price_increase(varchar), erp.ct_duplicate_invoice(varchar),
  erp.ct_checkin_outside(varchar), erp.control_findings(varchar), erp.ai_status(varchar), erp.ai_pick_tools(text, jsonb),
  erp.ai_log(varchar, text, jsonb, jsonb, integer), erp.ai_log_answer(bigint, text, integer), erp.ai_ask_context(varchar, text, jsonb)
  TO authenticated;
