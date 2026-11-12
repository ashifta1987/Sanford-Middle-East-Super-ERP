-- A11 · Reports, Control Tower rules, AI assistant tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run after base.txt (10–25 + test users) and 26_reports.sql, best on a FRESH rebuild. Everything happens inside one transaction
-- that is rolled back. Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a11_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a11_result TO authenticated, service_role;

-- Run one SQL expression as a user (RLS and grants apply) and return its jsonb result, or {error, message} if it raised.
CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL AND p_role <> 'service_role' THEN ''
                                                 ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a11_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 160)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 200))
$$;
-- Rows of a report as one jsonb array, run as the user.
CREATE FUNCTION pg_temp.rows(p_user uuid, p_from text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, 'SELECT coalesce(jsonb_agg(to_jsonb(r)), ''[]'') FROM ' || p_from || ' r')
$$;
CREATE FUNCTION pg_temp.sum(p_rows jsonb, p_key text, p_where text DEFAULT NULL, p_val text DEFAULT NULL) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce(sum((x->>p_key)::numeric), 0) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_rows) = 'array' THEN p_rows ELSE '[]' END) x
   WHERE p_where IS NULL OR x->>p_where IS NOT DISTINCT FROM p_val
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  stock  uuid := '00000000-0000-4000-8000-000000000013';
  hr     uuid := '00000000-0000-4000-8000-000000000018';
  y0 date := date_trunc('year', current_date)::date;
  r  jsonb;
  r2 jsonb;
  v  numeric;
  v2 numeric;
  n  bigint;
  lp numeric;
  v_emp integer;
  v_cnt integer := 990101;
  v_aud bigint;
  fin_msg text := 'Your position does not include Financials. Ask the system admin if you need it.';
  tbl text;
BEGIN
  -- ---------- 1. Report functions are SECURITY INVOKER (the user's own rights) ----------
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'erp' AND (p.proname LIKE 'rpt\_%' OR p.proname LIKE 'ct\_%' OR p.proname IN ('control_findings', 'ai_ask_context', '_ai_run', '_rpt_aging', '_rpt_need'))
     AND p.prosecdef;
  PERFORM pg_temp.check(n = 0, 'all report, Control Tower and AI context functions are SECURITY INVOKER', n || ' definer');
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'erp' AND (p.proname LIKE 'rpt\_%' OR p.proname LIKE 'ct\_%' OR p.proname = 'control_findings') AND p.provolatile <> 's';
  PERFORM pg_temp.check(n = 0, 'reports and rules are STABLE (read-only)', n || ' not stable');

  -- ---------- 2. Trial balance = journal sums ----------
  r := pg_temp.rows(fin, format('erp.rpt_trial_balance(%L, %L, %L)', 'ZZ99', y0, current_date));
  SELECT round(sum(jl.debit), 2), round(sum(jl.credit), 2) INTO v, v2 FROM erp.journal_line jl
    JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
   WHERE jl.company_code = 'ZZ99' AND je.ref_date BETWEEN y0 AND current_date;
  PERFORM pg_temp.check(jsonb_array_length(r) > 5, 'finance user runs the trial balance', jsonb_array_length(r) || ' accounts');
  PERFORM pg_temp.check(pg_temp.sum(r, 'debit') = v AND pg_temp.sum(r, 'credit') = v2, 'trial balance debit and credit = journal sums',
                        pg_temp.sum(r, 'debit') || ' / ' || v || ' · ' || pg_temp.sum(r, 'credit') || ' / ' || v2);
  PERFORM pg_temp.check(pg_temp.sum(r, 'closing') = 0, 'trial balance closing balances add up to zero', pg_temp.sum(r, 'closing')::text);
  SELECT count(*) INTO n FROM (
    SELECT jl.acct_code, round(sum(jl.debit - jl.credit), 2) AS bal FROM erp.journal_line jl
      JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
     WHERE jl.company_code = 'ZZ99' AND je.ref_date <= current_date GROUP BY 1 HAVING round(sum(jl.debit - jl.credit), 2) <> 0
    EXCEPT SELECT x->>'acct_code', (x->>'closing')::numeric FROM jsonb_array_elements(r) x WHERE (x->>'closing')::numeric <> 0) d;
  PERFORM pg_temp.check(n = 0, 'every account closing = its journal balance', n || ' differ');
  r2 := pg_temp.rows(fin, format('erp.rpt_trial_balance(%L, %L, %L)', 'ZZ99', current_date - 30, current_date));
  PERFORM pg_temp.check(pg_temp.sum(r2, 'opening') + pg_temp.sum(r2, 'debit') - pg_temp.sum(r2, 'credit') = pg_temp.sum(r2, 'closing')
                        AND pg_temp.sum(r2, 'closing') = 0, 'opening + debit − credit = closing (30-day period)', pg_temp.sum(r2, 'opening')::text);

  -- ---------- 3. Balance sheet and profit and loss ----------
  r := pg_temp.rows(fin, format('erp.rpt_balance_sheet(%L, %L)', 'ZZ99', current_date));
  PERFORM pg_temp.check(pg_temp.sum(r, 'amount', 'section', 'assets') = pg_temp.sum(r, 'amount', 'section', 'liabilities') + pg_temp.sum(r, 'amount', 'section', 'equity'),
                        'balance sheet: assets = liabilities + equity', pg_temp.sum(r, 'amount', 'section', 'assets')::text);
  SELECT round(sum(jl.credit - jl.debit), 2) INTO v FROM erp.journal_line jl
    JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
    JOIN erp.account a ON a.company_code = jl.company_code AND a.acct_code = jl.acct_code
   WHERE jl.company_code = 'ZZ99' AND je.ref_date <= current_date AND a.group_mask NOT IN (1, 2, 3);
  PERFORM pg_temp.check((SELECT (x->>'amount')::numeric FROM jsonb_array_elements(r) x WHERE x->>'acct_code' IS NULL) = v,
                        'balance sheet current result = journal sum of P&L accounts', v::text);
  r := pg_temp.rows(fin, format('erp.rpt_profit_loss(%L, %L, %L)', 'ZZ99', y0, current_date));
  SELECT round(sum(jl.credit - jl.debit), 2) INTO v FROM erp.journal_line jl
    JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
    JOIN erp.account a ON a.company_code = jl.company_code AND a.acct_code = jl.acct_code
   WHERE jl.company_code = 'ZZ99' AND je.ref_date BETWEEN y0 AND current_date AND a.group_mask NOT IN (1, 2, 3);
  PERFORM pg_temp.check(pg_temp.sum(r, 'amount', 'section', 'net_profit') = v, 'P&L net profit = journal sum (credit − debit)', v::text);
  PERFORM pg_temp.check(pg_temp.sum(r, 'amount', 'section', 'revenue') - pg_temp.sum(r, 'amount', 'section', 'cost_of_sales')
                        - pg_temp.sum(r, 'amount', 'section', 'expenses') + pg_temp.sum(r, 'amount', 'section', 'other') = v,
                        'P&L sections add up to the net profit', '');
  PERFORM pg_temp.ok(pg_temp.rows(owner, format('erp.rpt_profit_loss(%L, %L, %L)', 'ZZ99', y0, current_date)), 'owner can run the P&L (read everything)');

  -- ---------- 4. A sales user can't run finance reports ----------
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_trial_balance(%L, %L, %L)', 'ZZ99', y0, current_date)), fin_msg, 'sales user refused the trial balance');
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_balance_sheet(%L, %L)', 'ZZ99', current_date)), fin_msg, 'sales user refused the balance sheet');
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_profit_loss(%L, %L, %L)', 'ZZ99', y0, current_date)), fin_msg, 'sales user refused the P&L');
  PERFORM pg_temp.check((pg_temp.rows(sales, format('erp.rpt_profit_loss(%L, %L, %L)', 'ZZ99', y0, current_date)))->>'error' = '42501', 'refusal is 42501', '');
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_ap_aging(%L, %L)', 'ZZ99', current_date)),
    'Your position does not include Purchasing or Financials. Ask the system admin if you need it.', 'sales user refused supplier aging');
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_inventory_valuation(%L)', 'ZZ99')),
    'Your position does not include Inventory. Ask the system admin if you need it.', 'sales user refused inventory valuation');
  PERFORM pg_temp.expect(pg_temp.rows(purch, format('erp.rpt_ar_aging(%L, %L)', 'ZZ99', current_date)),
    'Your position does not include Sales or Financials. Ask the system admin if you need it.', 'purchasing user refused customer aging');
  PERFORM pg_temp.expect(pg_temp.rows(nobody, format('erp.rpt_ar_aging(%L, %L)', 'ZZ99', current_date)),
    'You don''t have access to company ZZ99.', 'user without a profile refused');
  PERFORM pg_temp.expect(pg_temp.rows(NULL, format('erp.rpt_ar_aging(%L, %L)', 'ZZ99', current_date)), 'Sign in first.', 'anonymous refused');
  PERFORM pg_temp.expect(pg_temp.rows(fin, format('erp.rpt_trial_balance(%L, %L, %L)', 'GRP', y0, current_date)),
    'Choose one company to run this report.', 'all companies at once refused');
  PERFORM pg_temp.expect(pg_temp.rows(fin, format('erp.rpt_trial_balance(%L, %L, %L)', 'ZZ99', current_date, y0 - 1)),
    'The to date is before the from date.', 'reversed dates refused');
  PERFORM pg_temp.expect(pg_temp.rows(fin, format('erp.rpt_profit_loss(%L, NULL, %L)', 'ZZ99', current_date)), 'Choose the from and to dates.', 'missing date refused');
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_sales_analysis(%L, %L, %L, %L)', 'ZZ99', y0, current_date, 'colour')),
    'Group sales by customer, item or salesperson.', 'unknown grouping refused');
  PERFORM pg_temp.expect(pg_temp.rows(sales, format('erp.rpt_open_items(%L, %L)', 'ZZ99', 'payroll')), 'Document kind payroll has no open items list.', 'unknown kind refused');
  PERFORM pg_temp.check((pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.journal_line'))::text = '0', 'sales user still sees 0 journal lines directly (RLS)', '');

  -- ---------- 5. Sales, partner, open items and inventory reports ----------
  r := pg_temp.rows(sales, format('erp.rpt_ar_aging(%L, %L)', 'ZZ99', current_date));
  SELECT round(sum(d.sign * (coalesce(d.total, 0) - coalesce(d.paid, 0))), 2) INTO v FROM erp.document d
   WHERE d.company_code = 'ZZ99' AND d.obj_type IN (13, 14) AND d.status = 'open' AND d.doc_date <= current_date;
  PERFORM pg_temp.check(pg_temp.sum(r, 'total') = v, 'customer aging total = open A/R documents', pg_temp.sum(r, 'total') || ' / ' || v);
  PERFORM pg_temp.check(pg_temp.sum(r, 'not_due') + pg_temp.sum(r, 'd1_30') + pg_temp.sum(r, 'd31_60') + pg_temp.sum(r, 'd61_90') + pg_temp.sum(r, 'd90_plus') = v,
                        'aging buckets add up to the total', '');
  r := pg_temp.rows(purch, format('erp.rpt_ap_aging(%L, %L)', 'ZZ99', current_date));
  SELECT round(sum(d.sign * (coalesce(d.total, 0) - coalesce(d.paid, 0))), 2) INTO v FROM erp.document d
   WHERE d.company_code = 'ZZ99' AND d.obj_type IN (18, 19) AND d.status = 'open' AND d.doc_date <= current_date;
  PERFORM pg_temp.check(pg_temp.sum(r, 'total') = coalesce(v, 0), 'supplier aging total = open A/P documents', pg_temp.sum(r, 'total') || ' / ' || v);
  r := pg_temp.rows(sales, format('erp.rpt_sales_analysis(%L, %L, %L, %L)', 'ZZ99', y0, current_date, 'customer'));
  SELECT round(sum(d.sign * coalesce(l.line_total, 0)), 2) INTO v FROM erp.document d JOIN erp.document_line l USING (company_code, obj_type, doc_entry)
   WHERE d.company_code = 'ZZ99' AND d.obj_type IN (13, 14) AND d.status NOT IN ('draft', 'cancelled', 'cancellation') AND d.doc_date BETWEEN y0 AND current_date;
  PERFORM pg_temp.check(pg_temp.sum(r, 'net_sales') = v, 'sales analysis net sales = invoice lines − credit memo lines', v::text);
  r2 := pg_temp.rows(sales, format('erp.rpt_sales_analysis(%L, %L, %L, %L)', 'ZZ99', y0, current_date, 'item'));
  PERFORM pg_temp.check(pg_temp.sum(r2, 'net_sales') = v, 'by item gives the same total', pg_temp.sum(r2, 'net_sales')::text);
  r2 := pg_temp.rows(sales, format('erp.rpt_sales_analysis(%L, %L, %L, %L)', 'ZZ99', y0, current_date, 'salesperson'));
  PERFORM pg_temp.check(pg_temp.sum(r2, 'net_sales') = v, 'by salesperson gives the same total', pg_temp.sum(r2, 'net_sales')::text);
  r := pg_temp.rows(sales, format('erp.rpt_open_items(%L, NULL)', 'ZZ99'));
  PERFORM pg_temp.check(jsonb_array_length(r) > 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'obj_type')::int IN (1470000113, 540000006, 22, 20, 204, 18, 19, 1250000001)),
                        'sales user: open items show sales documents only', jsonb_array_length(r) || ' rows');
  r := pg_temp.rows(purch, format('erp.rpt_open_items(%L, NULL)', 'ZZ99'));
  PERFORM pg_temp.check(jsonb_array_length(r) > 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'obj_type')::int IN (23, 17, 15, 203, 13, 14)),
                        'purchasing user: open items show purchasing documents only', jsonb_array_length(r) || ' rows');
  SELECT count(*) INTO n FROM erp.document WHERE company_code = 'ZZ99' AND status = 'open' AND obj_type = 17;
  PERFORM pg_temp.check(jsonb_array_length(pg_temp.rows(sales, format('erp.rpt_open_items(%L, %L)', 'ZZ99', 'sales_order'))) = n, 'open items filtered by kind', n::text);
  r := pg_temp.rows(stock, format('erp.rpt_inventory_in_warehouse(%L, NULL)', 'ZZ99'));
  SELECT round(sum(round(s.on_hand * coalesce(s.avg_cost, i.avg_cost, 0), 2)), 2) INTO v FROM erp.stock_balance s JOIN erp.item i USING (company_code, item_code)
   WHERE s.company_code = 'ZZ99' AND (s.on_hand <> 0 OR s.committed <> 0 OR s.on_order <> 0);
  PERFORM pg_temp.check(pg_temp.sum(r, 'value') = v, 'inventory in warehouse value = stock × cost', v::text);
  r2 := pg_temp.rows(stock, format('erp.rpt_inventory_valuation(%L)', 'ZZ99'));
  PERFORM pg_temp.check(pg_temp.sum(r2, 'value') = v, 'inventory valuation total = the warehouse report total', pg_temp.sum(r2, 'value')::text);
  PERFORM pg_temp.check(jsonb_array_length(pg_temp.rows(stock, format('erp.rpt_inventory_in_warehouse(%L, %L)', 'ZZ99', 'WH01'))) =
                        (SELECT count(*) FROM erp.stock_balance WHERE company_code = 'ZZ99' AND whs_code = 'WH01' AND (on_hand <> 0 OR committed <> 0 OR on_order <> 0)),
                        'inventory in warehouse filtered by warehouse', '');

  -- ---------- 6. Control Tower: fixtures (rolled back) ----------
  -- duplicate supplier invoice: two A/P invoices of S0001 with the same supplier invoice number
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, card_name, customer_ref, currency, total, paid, source)
  VALUES ('ZZ99', 18, 990001, 990001, 'ap_invoice', 'open', current_date - 3, current_date + 27, 'S0001', 'A11 dup supplier', 'INV-A11-77', 'AED', 1000, 0, 'erp'),
         ('ZZ99', 18, 990002, 990002, 'ap_invoice', 'open', current_date - 1, current_date + 29, 'S0001', 'A11 dup supplier', ' inv-a11-77 ', 'AED', 1000, 0, 'erp'),
         ('ZZ99', 18, 990003, 990003, 'ap_invoice', 'cancelled', current_date - 1, current_date + 29, 'S0002', 'A11 other', 'INV-A11-88', 'AED', 500, 0, 'erp'),
         ('ZZ99', 18, 990004, 990004, 'ap_invoice', 'open', current_date - 1, current_date + 29, 'S0002', 'A11 other', 'INV-A11-88', 'AED', 500, 0, 'erp');
  -- price increase: two purchase orders for SMP-1010, one 20 % and one 5 % above the last purchase price
  SELECT l.price INTO lp FROM erp.document_line l JOIN erp.document d USING (company_code, obj_type, doc_entry)
   WHERE l.company_code = 'ZZ99' AND l.item_code = 'SMP-1010' AND l.obj_type IN (22, 20, 18) AND l.price > 0
     AND d.status NOT IN ('draft', 'cancelled', 'cancellation') AND d.doc_date <= current_date
   ORDER BY d.doc_date DESC, d.doc_entry DESC, l.line_num LIMIT 1;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, card_name, currency, total, source)
  VALUES ('ZZ99', 22, 990011, 990011, 'purchase_order', 'open', current_date + 1, 'S0001', 'A11 price up', 'AED', 100, 'erp'),
         ('ZZ99', 22, 990012, 990012, 'purchase_order', 'open', current_date + 1, 'S0001', 'A11 price ok', 'AED', 100, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, open_qty, price, line_total)
  VALUES ('ZZ99', 22, 990011, 0, 'SMP-1010', 10, 10, round(lp * 1.2, 2), round(lp * 12, 2)),
         ('ZZ99', 22, 990012, 0, 'SMP-1010', 10, 10, round(lp * 1.05, 2), round(lp * 10.5, 2));
  -- supplier bank details: one changed today, one 40 days ago
  INSERT INTO erp.bp_bank_change (company_code, card_code, change_kind, changed_at) VALUES ('ZZ99', 'S0002', 'changed', now()), ('ZZ99', 'S0003', 'changed', now() - interval '40 days');
  DELETE FROM erp.bp_bank_change WHERE company_code = 'ZZ99' AND card_code = 'S0003' AND changed_at > now() - interval '35 days';
  -- stock count: posted today, one line 2 % off (flagged), one 0.5 % off (not flagged)
  INSERT INTO erp.inv_count (company_code, count_id, doc_no, whs_code, count_date, state, n_lines, n_counted, created_by, posted_at)
  VALUES ('ZZ99', v_cnt, 'IC-A11-TEST', 'WH01', current_date, 'posted', 2, 2, admin, now());
  INSERT INTO erp.inv_count_line (company_code, count_id, line_num, item_code, system_qty, avg_cost, counted_qty)
  VALUES ('ZZ99', v_cnt, 0, 'SMP-1010', 100, 10, 98), ('ZZ99', v_cnt, 1, 'SMP-1020', 200, 10, 201);
  -- check-in outside the site area two days ago
  SELECT emp_id INTO v_emp FROM erp.employee WHERE company_code = 'ZZ99' ORDER BY emp_id LIMIT 1;
  DELETE FROM erp.hr_attendance WHERE company_code = 'ZZ99' AND emp_id = v_emp AND work_date = current_date - 2;
  INSERT INTO erp.hr_attendance (company_code, emp_id, work_date, check_in_at, in_site, in_distance_m, in_flags)
  VALUES ('ZZ99', v_emp, current_date - 2, now() - interval '2 days', 'DWC', 1234, ARRAY['outside_site']);

  -- ---------- 7. Control Tower: rules, rights, links ----------
  r := pg_temp.rows(purch, format('erp.control_findings(%L)', 'ZZ99'));
  PERFORM pg_temp.check((SELECT count(*) FROM jsonb_array_elements(r) x WHERE x->>'check_code' = 'duplicate_invoice' AND x->>'ref' IN ('ap_invoice:990001', 'ap_invoice:990002')) = 2,
                        'same supplier invoice twice: both A/P invoices flagged (case and spaces ignored)', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'ref' = 'ap_invoice:990004'), 'a cancelled invoice does not make a duplicate', '');
  PERFORM pg_temp.check((SELECT x->>'severity' = 'critical' AND x->>'link' = '/docs/ap_invoice/ZZ99/990001' AND (x->>'amount')::numeric = 1000
                           FROM jsonb_array_elements(r) x WHERE x->>'ref' = 'ap_invoice:990001'), 'duplicate invoice: critical, record link, amount', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' = 'price_increase' AND x->>'ref' = 'purchase_order:990011'
                                  AND x->>'link' = '/docs/purchase_order/ZZ99/990011' AND (x->>'amount')::numeric > 0),
                        'purchase price over last + 10 %: flagged with link and extra cost', lp::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'ref' = 'purchase_order:990012'), 'price 5 % above last: not flagged', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' = 'bank_change' AND x->>'ref' = 'bp:S0002' AND x->>'severity' = 'critical' AND x->>'link' = '/bp/ZZ99/S0002'),
                        'supplier bank details changed today: flagged', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'ref' = 'bp:S0003'), 'bank change 40 days ago: not flagged', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' IN ('count_variance', 'checkin_outside', 'credit_limit')),
                        'purchasing user sees no stock count, attendance or customer findings', '');
  r := pg_temp.rows(stock, format('erp.control_findings(%L)', 'ZZ99'));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' = 'count_variance' AND x->>'title' = 'IC-A11-TEST · SMP-1010'
                                  AND x->>'link' = '/inventory/counts/ZZ99/' || v_cnt AND (x->>'amount')::numeric > 0
                                  AND x->>'detail' LIKE 'Counted 98, system 100 in WH01 (-2.0 %, limit 1 %)%'),
                        'stock count variance over 1 %: flagged with link and value', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'title' = 'IC-A11-TEST · SMP-1020'), 'count variance 0.5 %: not flagged', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' IN ('duplicate_invoice', 'price_increase', 'checkin_outside')),
                        'inventory user sees no purchasing or attendance findings', '');
  r := pg_temp.rows(hr, format('erp.control_findings(%L)', 'ZZ99'));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' = 'checkin_outside' AND x->>'ref' = 'employee:' || v_emp
                                  AND (x->>'amount')::numeric = 1234 AND x->>'link' = '/hr/employees/ZZ99/' || v_emp),
                        'check-in outside the site area: flagged for HR with distance and link', '');
  r := pg_temp.rows(sales, format('erp.control_findings(%L)', 'ZZ99'));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'check_code' IN ('duplicate_invoice', 'price_increase', 'bank_change', 'count_variance', 'checkin_outside')),
                        'sales user sees none of the new rules (no access to their data)', jsonb_array_length(r) || ' findings');
  PERFORM pg_temp.check(jsonb_array_length(r) = (SELECT jsonb_array_length(pg_temp.rows(sales, format('erp.control_checks(%L)', 'ZZ99')))),
                        'sales user: the 5 Stage 1 checks are unchanged', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'link' IS NULL), 'every finding has a record link', '');
  r := pg_temp.rows(admin, format('erp.control_findings(%L)', 'ZZ99'));
  PERFORM pg_temp.check((SELECT count(DISTINCT x->>'check_code') FROM jsonb_array_elements(r) x
                          WHERE x->>'check_code' IN ('duplicate_invoice', 'price_increase', 'bank_change', 'count_variance', 'checkin_outside')) = 5,
                        'admin (reads everything) sees all 5 new rules', '');
  PERFORM pg_temp.check(jsonb_array_length(pg_temp.rows(admin, 'erp.control_findings(NULL)')) >= jsonb_array_length(r), 'all companies at once works for the Control Tower', '');
  -- limits are settings
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.control_setting_set(''ZZ99'', ''price_increase_pct'', 25)'),
    'Only a system admin with full Administration access can change Control Tower limits.', 'finance user cannot change Control Tower limits');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.control_setting_set(''ZZ99'', ''nope'', 25)'), 'Control Tower rule nope does not exist.', 'unknown rule refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, 'SELECT erp.control_setting_set(''ZZ99'', ''price_increase_pct'', -1)'), 'Enter a limit above 0.', 'negative limit refused');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.control_setting_set(''ZZ99'', ''price_increase_pct'', 25)'), 'admin sets the price limit to 25 %');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.rows(purch, 'erp.ct_price_increase(''ZZ99'')')) x WHERE x->>'ref' = 'purchase_order:990011'),
                        'with a 25 % limit the 20 % order is no longer flagged', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'control_setting_set' AND object_ref = 'price_increase_pct' AND company_code = 'ZZ99'), 'limit change is audited', '');
  PERFORM pg_temp.ok(pg_temp.call(admin, 'SELECT erp.control_setting_set(''ZZ99'', ''price_increase_pct'', NULL)'), 'back to the design value');
  PERFORM pg_temp.check(erp._ct_limit('ZZ99', 'price_increase_pct') = 10, 'design value 10 % again', '');

  -- ---------- 8. AI assistant ----------
  DELETE FROM erp.ai_setting WHERE company_code = 'ZZ99';
  DELETE FROM erp.ai_usage WHERE company_code = 'ZZ99';
  r := pg_temp.call(sales, 'SELECT erp.ai_status(''ZZ99'')');
  PERFORM pg_temp.check((r->>'configured')::boolean = false AND jsonb_array_length(r->'tools') = 0, 'no provider set: AI not configured, no tools', left(r::text, 160));
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.ai_ask_context(''ZZ99'', ''who owes us money?'', NULL)'), 'The AI Assistant is off for ZZ99.', 'asking while off is refused');
  PERFORM pg_temp.expect(pg_temp.call(nobody, 'SELECT erp.ai_status(''ZZ99'')'), 'You don''t have access to company ZZ99.', 'AI status refused without company access');
  PERFORM pg_temp.ok(pg_temp.call(admin, $q$SELECT erp.ai_setting_save('ZZ99', '{"enabled": true, "chat_provider": "google", "chat_model": "gemini-3.8-flash", "monthly_limit": 100,
      "allowed_modules": ["finance", "sales", "purchase", "inventory"],
      "allowed_tables": ["account", "journal_entry", "journal_line", "document", "document_line", "stock_balance", "item"]}')$q$), 'admin switches the assistant on (A10 settings)');
  r := pg_temp.call(sales, 'SELECT erp.ai_status(''ZZ99'')');
  PERFORM pg_temp.check((r->>'configured')::boolean AND r->'tools' ? 'ar_aging' AND NOT r->'tools' ? 'profit_loss' AND NOT r->'tools' ? 'trial_balance',
                        'sales user may use sales tools, not finance tools', r->>'tools');
  r := pg_temp.call(fin, 'SELECT erp.ai_status(''ZZ99'')');
  PERFORM pg_temp.check(r->'tools' ? 'profit_loss' AND r->'tools' ? 'trial_balance' AND NOT r->'tools' ? 'inventory_valuation',
                        'finance user may use finance tools, not inventory valuation', r->>'tools');
  PERFORM pg_temp.check(erp.ai_pick_tools('Who owes us the most and what is our profit?', NULL) = ARRAY['profit_loss', 'ar_aging'], 'router: profit + receivables', '');
  PERFORM pg_temp.check(erp.ai_pick_tools('What do we owe suppliers?', NULL) = ARRAY['ap_aging'], 'router: payables', '');
  PERFORM pg_temp.check(erp.ai_pick_tools('Summarise this order', '{"obj_type": 17, "doc_entry": 5}') = ARRAY['document'], 'router: the open document', '');
  PERFORM pg_temp.check(erp.ai_pick_tools('hello', NULL) = '{}'::text[], 'router: nothing matched', '');

  SELECT count(*) INTO n FROM erp.audit_log WHERE actor = 'ai:assistant';
  r := pg_temp.call(sales, 'SELECT erp.ai_ask_context(''ZZ99'', ''Show me the trial balance, the profit and loss and who owes us the most'', NULL)');
  PERFORM pg_temp.check(r->>'error' IS NULL, 'sales user asks a mixed question', left(r::text, 200));
  PERFORM pg_temp.check((SELECT x->>'status' FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'trial_balance') = 'not_allowed'
                        AND (SELECT x->>'status' FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'profit_loss') = 'not_allowed',
                        'finance tools not run for the sales user', '');
  PERFORM pg_temp.check((SELECT x->>'status' FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'ar_aging') = 'ok', 'receivables tool run for the sales user', '');
  PERFORM pg_temp.check(r::text !~ '"acct_code"' AND r::text !~* 'journal' AND r::text !~ '"net_profit"' AND r::text !~ '"debit"'
                        AND NOT EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND r::text LIKE '%' || a.name || '%' AND length(a.name) > 8),
                        'the sales user''s AI context contains no finance data (no accounts, journals or P&L)', '');
  PERFORM pg_temp.check(jsonb_array_length(r->'sources') > 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sources') s WHERE s->>'link' IS NULL OR s->>'label' IS NULL)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sources') s WHERE s->>'link' LIKE '/bp/ZZ99/%'),
                        'answer sources are record links (report + partners)', jsonb_array_length(r->'sources')::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE actor = 'ai:assistant') = n + 1, 'the question is logged once as ai:assistant', '');
  SELECT audit_id INTO v_aud FROM erp.audit_log WHERE actor = 'ai:assistant' ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.check((SELECT detail->>'user_id' = sales::text AND action = 'ai_question' AND company_code = 'ZZ99'
                                AND detail->>'question' LIKE 'Show me the trial balance%'
                                AND jsonb_array_length(detail->'tools') = 3
                                AND EXISTS (SELECT 1 FROM jsonb_array_elements(detail->'tools') t WHERE t->>'tool' = 'profit_loss' AND t->>'status' = 'not_allowed')
                           FROM erp.audit_log WHERE audit_id = v_aud), 'log has the user, the question and every tool with its status', '');
  PERFORM pg_temp.check((r->>'audit_id')::bigint = v_aud, 'context returns its audit id', '');
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT to_jsonb(erp.ai_log_answer(%s, %L, 10))', v_aud, 'local-test')), 'This question is not yours to answer.', 'another user cannot log the answer');
  PERFORM pg_temp.ok(pg_temp.call(sales, format('SELECT to_jsonb(erp.ai_log_answer(%s, %L, 120))', v_aud, 'local-test')), 'the asker logs who answered');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE actor = 'ai:assistant' AND action = 'ai_answer' AND object_ref = v_aud::text AND detail->>'responder' = 'local-test'),
                        'answer logged with its responder', '');
  PERFORM pg_temp.check((pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.audit_log WHERE actor = 'ai:assistant'$q$))::text = '0', 'the audit log stays admin-only', '');

  r := pg_temp.call(fin, 'SELECT erp.ai_ask_context(''ZZ99'', ''What is our profit and loss this year?'', NULL)');
  PERFORM pg_temp.check((SELECT (x->'summary'->>'net_profit')::numeric FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'profit_loss')
                        = pg_temp.sum(pg_temp.rows(fin, format('erp.rpt_profit_loss(%L, %L, %L)', 'ZZ99', y0, current_date)), 'amount', 'section', 'net_profit'),
                        'finance user: AI P&L figure = the P&L report', '');
  -- a tool the setting allows but the user's row rules refuse
  SELECT doc_entry INTO n FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 22 ORDER BY doc_entry LIMIT 1;
  r := pg_temp.call(sales, format('SELECT erp.ai_ask_context(''ZZ99'', ''Ask AI about this order'', ''{"obj_type": 22, "doc_entry": %s}'')', n));
  PERFORM pg_temp.check((SELECT x->>'status' = 'refused' AND x->>'message' = 'You can''t read this document.' FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'document')
                        AND NOT (r ? 'rows'), 'sales user asking about a purchase order: refused by the row rules, nothing read', left(r::text, 160));
  SELECT doc_entry INTO n FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 ORDER BY doc_entry LIMIT 1;
  r := pg_temp.call(sales, format('SELECT erp.ai_ask_context(''ZZ99'', ''Ask AI about this order'', ''{"obj_type": 17, "doc_entry": %s}'')', n));
  PERFORM pg_temp.check((SELECT x->>'status' = 'ok' AND x->'summary' ? 'history' AND jsonb_array_length(x->'rows') > 0 FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'document')
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sources') s WHERE s->>'link' = '/docs/sales_order/ZZ99/' || n),
                        'Ask AI about this order: lines, customer history and the order link', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE actor = 'ai:assistant' AND object_ref = '17:' || n), 'document question logged with the document reference', '');
  -- admin narrows the setting: finance closed to the assistant even for the finance user
  PERFORM pg_temp.ok(pg_temp.call(admin, $q$SELECT erp.ai_setting_save('ZZ99', '{"allowed_modules": ["sales"]}')$q$), 'admin opens only Sales to the assistant');
  r := pg_temp.call(fin, 'SELECT erp.ai_ask_context(''ZZ99'', ''profit and loss'', NULL)');
  PERFORM pg_temp.check((SELECT x->>'status' FROM jsonb_array_elements(r->'tools') x WHERE x->>'tool' = 'profit_loss') = 'not_allowed', 'finance closed in the setting: P&L not used', '');
  -- input checks and the monthly limit
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.ai_ask_context(''ZZ99'', ''   '', NULL)'), 'Type a question first.', 'empty question refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.ai_ask_context(''ZZ99'', %L, NULL)', repeat('x', 501))), 'Keep the question under 500 characters.', 'long question refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.ai_ask_context(''ZZ99'', ''this order'', ''{"obj_type": "x"}'')'), 'The document reference is not valid.', 'bad document reference refused');
  PERFORM pg_temp.call(NULL, 'SELECT to_jsonb(erp.ai_usage_record(''ZZ99'', 100, 10))', 'service_role');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.ai_ask_context(''ZZ99'', ''who owes us?'', NULL)'),
    'This month''s AI Assistant limit for ZZ99 is used up (100 requests).', 'monthly limit applies to Ask AI');
  -- no AI function writes business data: no write grants, nothing changed
  FOREACH tbl IN ARRAY ARRAY['document', 'document_line', 'journal_entry', 'journal_line', 'business_partner', 'stock_balance'] LOOP
    PERFORM pg_temp.check(NOT has_table_privilege('authenticated', 'erp.' || tbl, 'INSERT,UPDATE,DELETE'), 'no write grant on ' || tbl, '');
  END LOOP;
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
                                    WHERE s.nspname = 'erp' AND p.proname IN ('ai_ask_context', '_ai_run')
                                      AND (p.prosrc ~* '\m(insert|update|delete)\M\s' )),
                        'the AI context functions contain no INSERT / UPDATE / DELETE', '');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a11_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a11_result;
ROLLBACK;
