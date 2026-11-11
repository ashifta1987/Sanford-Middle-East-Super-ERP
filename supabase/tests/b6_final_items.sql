-- B6 · Last open items: landed cost vendor per cost line (broker on the header), system currency on journals, Conversion
-- Differences. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (sql-order.txt incl. 35_final_items.sql). Everything happens in one transaction that is rolled back.
-- Prints PASS/FAIL · name · detail, then a TOTAL row.
--
-- Rates (entered by QA Finance below): USD 10 Nov 3.6725 · 12 Nov 3.68 · 15 Nov 3.65 · 20 Nov 3.70 · 25 Nov 3.60.
-- ZZ99's SAMPLE system currency USD is switched on in section 2 (rolled back) — the shared database keeps it off.
BEGIN;

CREATE TEMP TABLE b6_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON b6_result TO authenticated;

CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO b6_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.psave(u uuid, obj integer, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.purchase_doc_save(%L, %s, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', obj, h, l))
$$;
CREATE FUNCTION pg_temp.psubmit(u uuid, obj integer, e integer, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.purchase_doc_submit(%L, %s, %s, %L)', 'ZZ99', obj, e, reason))
$$;
CREATE FUNCTION pg_temp.lcp(u uuid, h jsonb, l jsonb, c jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.landed_cost_preview(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, l, c))
$$;
CREATE FUNCTION pg_temp.lcc(u uuid, h jsonb, l jsonb, c jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.landed_cost_create(%L, %L::jsonb, %L::jsonb, %L::jsonb)', 'ZZ99', h, l, c))
$$;
CREATE FUNCTION pg_temp.cvd(u uuid, fn text, j jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.conversion_diff_%s(%L, %L::jsonb)', fn, 'ZZ99', j))
$$;
CREATE FUNCTION pg_temp.doc(obj integer, e integer) RETURNS erp.document LANGUAGE sql AS $$
  SELECT * FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = obj AND doc_entry = e
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
-- system currency side of a journal: "acct Dr x" per line
CREATE FUNCTION pg_temp.js(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || coalesce('/' || nullif(short_name, acct_code), '') || CASE WHEN coalesce(sys_debit, 0) > 0 THEN ' Dr ' || trim_scale(sys_debit)
                                                                                       ELSE ' Cr ' || trim_scale(coalesce(sys_credit, 0)) END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.pj(p_date date, p_lines jsonb, p_src jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN to_jsonb(erp.post_journal('ZZ99', p_date, 'B6 test', p_lines, p_src || '{"allow_control": true}'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
END $$;

-- ======================================================================= 0. Rates
DO $$
DECLARE
  fin uuid := '00000000-0000-4000-8000-000000000004';
BEGIN
  PERFORM pg_temp.ok(pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-10', 'USD', 3.6725)$q$), 'rates: USD 10 Nov');
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-12', 'USD', 3.68)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-15', 'USD', 3.65)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-20', 'USD', 3.70)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-25', 'USD', 3.60)$q$);
END $$;

-- ======================================================================= 1. Landed costs: vendor per cost line
DO $$
DECLARE
  purch uuid := '00000000-0000-4000-8000-000000000010';
  r jsonb; po integer; gr integer; ap integer; lc integer; t integer; v_ap text;
  h jsonb; ln jsonb;
BEGIN
  r := pg_temp.psave(purch, 22, '{"card_code":"S0001","doc_date":"2026-11-10","due_date":"2026-12-31","whs_code":"WH01"}', '[{"item_code":"SMP-1140","qty":100,"price":10}]');
  po := (r->>'doc_entry')::integer;
  PERFORM pg_temp.psubmit(purch, 22, po);
  gr := (pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, po))->>'doc_entry')::integer;
  ap := (pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-15","customer_ref":"B6-AP"}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, gr))->>'doc_entry')::integer;
  v_ap := erp._sd_no('ZZ99', 18, ap);
  PERFORM pg_temp.check((pg_temp.doc(18, ap)).total_fc = 1050 AND (pg_temp.doc(18, ap)).fx_rate = 3.65 AND (pg_temp.doc(18, ap)).card_code = 'S0001',
    'fixture: USD goods receipt and S0001''s A/P invoice 1,050 USD at 3.65');
  ln := format('[{"grpo_entry":%s,"grpo_line":0}]', gr)::jsonb;
  h := '{"doc_date":"2026-11-20","card_code":"S0009","reference":"B6 broker"}';     -- broker S0009 (AED)

  -- vendor validation
  PERFORM pg_temp.expect(pg_temp.lcp(purch, h, ln, '[{"code":"DUTY","amount":100,"card_code":"S9999"}]'),
    'Landed cost 1 (Customs duty): supplier S9999 does not exist in company ZZ99. Check the code.', 'unknown vendor refused');
  PERFORM pg_temp.expect(pg_temp.lcp(purch, h, ln, '[{"code":"DUTY","amount":100,"card_code":"C0001"}]'),
    'Landed cost 1 (Customs duty): supplier C0001 does not exist in company ZZ99. Check the code.', 'a customer is not a vendor');
  PERFORM pg_temp.expect(pg_temp.lcp(purch, h, ln, '[{"code":"DUTY","amount":100,"currency":"USD","card_code":"S0009"}]'),
    'Landed cost 1 (Customs duty): supplier S0009 trades in AED. Enter the charge in AED.', 'an AED vendor takes AED charges only');
  PERFORM pg_temp.expect(pg_temp.lcp(purch, h, ln, '[{"code":"DUTY","amount":100,"currency":"EUR","card_code":"S0001"}]'),
    'Landed cost 1 (Customs duty): supplier S0001 trades in USD. Enter the charge in USD or AED.', 'a USD vendor takes USD or AED charges');
  r := pg_temp.lcp(purch, h, ln, '[{"code":"DUTY","amount":100,"card_code":"S0001"}]');
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->'charges'->0->>'card_code' = 'S0001' AND r->'charges'->0->>'card_name' IS NOT NULL,
    'a USD vendor may also bill in AED; the preview names the vendor', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.lcp(purch, h, ln, format('[{"code":"DUTY","amount":100,"currency":"USD","card_code":"S0002","ap_invoice_entry":%s}]', ap)::jsonb),
    format('Landed cost 1 (Customs duty): A/P invoice %s is from S0001, not from the vendor S0002.', v_ap), 'linked invoice of another vendor refused');
  PERFORM pg_temp.expect(pg_temp.lcp(purch, h, ln, format('[{"code":"DUTY","amount":100,"currency":"USD","ap_invoice_entry":%s}]', ap)::jsonb),
    format('Landed cost 1 (Customs duty): A/P invoice %s is from S0001, not from the broker S0009.', v_ap), 'no vendor: the broker rule of B5 still applies');

  -- the line's vendor wins over the broker: S0001's invoice on a landed cost whose broker is S0009; gain 5.00 (3.70 vs 3.65)
  r := pg_temp.lcc(purch, h, ln, format('[{"code":"DUTY","amount":100,"currency":"USD","card_code":"S0001","ap_invoice_entry":%s},{"code":"CLEARING","amount":50,"card_code":"S0009"}]', ap)::jsonb);
  lc := (r->>'doc_entry')::integer;
  t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(lc IS NOT NULL AND (r->>'total')::numeric = 420 AND (r->>'fx_diff')::numeric = -5,
    'posted: 370.00 (100 USD at 3.70) + 50.00 AED, rate difference −5.00', left(r::text, 300));
  PERFORM pg_temp.check(pg_temp.jl(t) ~ '^1300 Dr 420, [0-9]+ Cr 415, 7100 Cr 5$',
    'journal: inventory 420 / clearing 415 (365 at the invoice''s rate + 50) / exchange gain 5 (B4 rule)', pg_temp.jl(t));
  PERFORM pg_temp.check((SELECT string_agg(code || ':' || coalesce(card_code, '-'), ' ' ORDER BY charge_no) FROM erp.landed_cost_charge WHERE company_code = 'ZZ99' AND doc_entry = lc) = 'DUTY:S0001 CLEARING:S0009',
    'each cost line stores its vendor');
  PERFORM pg_temp.check((SELECT card_code FROM erp.landed_cost WHERE company_code = 'ZZ99' AND doc_entry = lc) = 'S0009', 'the header keeps the broker');
  r := pg_temp.call(purch, format('SELECT erp.landed_cost_info(%L, %s)', 'ZZ99', lc));
  PERFORM pg_temp.check(r->'charges'->0->>'card_code' = 'S0001' AND r->'charges'->0->>'card_name' IS NOT NULL AND r->'charges'->1->>'card_code' = 'S0009' AND r->>'card_code' = 'S0009',
    'landed cost page: broker on the header, vendor per cost line', left(r->>'charges', 300));
  PERFORM pg_temp.check((SELECT detail->'charges'->0->>'card_code' FROM erp.audit_log WHERE action = 'landed_cost_create' AND object_ref = lc::text) = 'S0001',
    'audit: the charges carry the vendor');
  PERFORM pg_temp.check((SELECT sys_debit IS NULL AND sys_credit IS NULL FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t AND line_id = 0)
                        AND (SELECT total_sys = total_local FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t),
    'system currency inactive: journal lines carry no system currency amounts (as before)');

  -- no vendor named: the linked invoice's supplier becomes the vendor; landed cost rate 3.60 < invoice 3.65 → loss 5.00
  r := pg_temp.lcc(purch, '{"doc_date":"2026-11-25"}', ln, format('[{"code":"INSURANCE","amount":100,"currency":"USD","ap_invoice_entry":%s}]', ap)::jsonb);
  PERFORM pg_temp.check((r->>'fx_diff')::numeric = 5 AND pg_temp.jl((r->>'trans_id')::integer) ~ '^1300 Dr 360, [0-9]+ Cr 365, 7200 Dr 5$',
    'charge at 3.60 against the invoice at 3.65: clearing 365, exchange loss 5.00', coalesce(pg_temp.jl((r->>'trans_id')::integer), left(r::text, 300)));
  PERFORM pg_temp.check((SELECT card_code FROM erp.landed_cost_charge WHERE company_code = 'ZZ99' AND doc_entry = (r->>'doc_entry')::integer) = 'S0001',
    'an unnamed vendor defaults to the linked invoice''s supplier');
END $$;

-- ======================================================================= 2. System currency setting
DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  it     uuid := '00000000-0000-4000-8000-000000000023';
  r jsonb;
BEGIN
  r := pg_temp.call(it, $q$SELECT erp.system_currency_info('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND r->>'system_currency' = 'AED' AND NOT (r->>'active')::boolean AND NOT (r->>'can_write')::boolean AND NOT (r->>'locked')::boolean,
    'default: system currency = local currency AED (inactive); IT may read it', left(r::text, 300));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.system_currency_setting), 'no system currency is seeded for any company (AE01–AE05 stay inactive)');
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.system_currency_info('ZZ99')$q$), 'Only the system admin, IT and the owner can open Administration.', 'Sales can''t open it');
  PERFORM pg_temp.expect(pg_temp.call(it, $q$SELECT erp.system_currency_save('ZZ99', 'USD')$q$), 'Only a system admin with full Administration access can change this.', 'Administration read-only can''t change it');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', ' ')$q$), 'Choose the system currency.', 'currency required');
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'JPY')$q$), 'Currency JPY is not in the rates list of ZZ99 (USD, SAR, CNY, EUR).', 'currency outside the rates list refused');
  PERFORM pg_temp.expect(pg_temp.pj('2026-11-10', '[{"acct_code":"6200","sys_debit":1},{"acct_code":"6800","sys_credit":1}]', '{"sys_only": true}'),
    'The system currency of ZZ99 is its local currency AED, so there is nothing to post in the system currency only.', 'system-currency-only journal refused while inactive');
  PERFORM pg_temp.expect(pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20"}'),
    'Conversion differences need a system currency. ZZ99 uses its local currency AED as the system currency, so there is nothing to convert. Set one in Administration › Company Details.',
    'Conversion Differences explain that the feature is inactive');
  r := pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'usd')$q$);
  PERFORM pg_temp.check((r->>'active')::boolean AND r->>'system_currency' = 'USD' AND (r->>'changed')::boolean, 'admin sets the SAMPLE system currency USD for ZZ99', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'system_currency_set' AND company_code = 'ZZ99' AND detail->>'before' = 'AED' AND detail->>'after' = 'USD'),
    'audit: system_currency_set AED → USD');
  r := pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'USD')$q$);
  PERFORM pg_temp.check(NOT (r->>'changed')::boolean, 'saving the same currency changes nothing');
  r := pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'SAR')$q$);
  PERFORM pg_temp.check((r->>'changed')::boolean AND erp._sys_cur('ZZ99') = 'SAR', 'it can still be changed while no journal carries it');
  PERFORM pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'USD')$q$);
END $$;

-- ======================================================================= 3. Journals carry system currency amounts
DO $$
DECLARE
  admin uuid := '00000000-0000-4000-8000-000000000001';
  r jsonb; t integer; t2 integer; rv integer;
BEGIN
  PERFORM pg_temp.expect(pg_temp.pj('2026-11-09', '[{"acct_code":"6200","debit":100},{"acct_code":"6800","credit":100}]'),
    'There is no exchange rate for USD (the system currency) on 09 Nov 2026. Enter it in Administration › Exchange Rates, then try again.', 'a posting date without a system currency rate is refused');
  -- J1 10 Nov (3.6725): 100 AED = 27.23 USD per line
  r := pg_temp.pj('2026-11-10', '[{"acct_code":"6200","debit":100},{"acct_code":"6800","credit":100}]');
  t := (r#>>'{}')::integer;
  PERFORM pg_temp.check(pg_temp.js(t) = '6200 Dr 27.23, 6800 Cr 27.23' AND pg_temp.jl(t) = '6200 Dr 100, 6800 Cr 100'
                        AND (SELECT total_local = 100 AND total_sys = 27.23 FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t),
    'each line carries LC / the posting date''s USD rate (100 AED = 27.23 USD); header total_sys 27.23', pg_temp.js(t));
  -- J2 20 Nov (3.70): back again = 27.03 USD
  r := pg_temp.pj('2026-11-20', '[{"acct_code":"6800","debit":100},{"acct_code":"6200","credit":100}]');
  PERFORM pg_temp.check(pg_temp.js((r#>>'{}')::integer) = '6800 Dr 27.03, 6200 Cr 27.03', 'at 3.70 the same 100 AED is 27.03 USD', pg_temp.js((r#>>'{}')::integer));
  -- partner: A/R of C0001 10 Nov, cleared 20 Nov
  PERFORM pg_temp.pj('2026-11-10', '[{"acct_code":"1200","short_name":"C0001","debit":100},{"acct_code":"1105","credit":100}]');
  PERFORM pg_temp.pj('2026-11-20', '[{"acct_code":"1105","debit":100},{"acct_code":"1200","short_name":"C0001","credit":100}]');
  -- rounding inside one journal: 100 = 50 + 50 → 27.23 against 13.61 + 13.61
  r := pg_temp.pj('2026-11-10', '[{"acct_code":"6100","debit":100},{"acct_code":"6400","credit":50},{"acct_code":"6400","credit":50}]');
  t := (r#>>'{}')::integer;
  PERFORM pg_temp.check(pg_temp.js(t) = '6100 Dr 27.23, 6400 Cr 13.61, 6400 Cr 13.61' AND pg_temp.jl(t) = '6100 Dr 100, 6400 Cr 50, 6400 Cr 50',
    'rounding per line: balanced in AED, 0.01 USD apart (a conversion difference)', pg_temp.js(t));
  PERFORM pg_temp.pj('2026-11-20', '[{"acct_code":"6400","debit":100},{"acct_code":"6100","credit":100}]');
  -- a USD line: its FC amount is the system currency amount
  r := pg_temp.pj('2026-11-20', '[{"acct_code":"5210","debit":370,"fc_debit":100},{"acct_code":"5230","credit":370,"fc_credit":100}]', '{"fc_currency":"USD","fc_rate":3.70}');
  t2 := (r#>>'{}')::integer;
  PERFORM pg_temp.check(pg_temp.js(t2) = '5210 Dr 100, 5230 Cr 100', 'a line in USD carries its USD amount as the system currency amount', pg_temp.js(t2));
  -- explicit amounts are kept; the reversal mirrors them exactly
  r := pg_temp.pj('2026-11-20', '[{"acct_code":"1600","debit":10,"sys_debit":2.5},{"acct_code":"3100","credit":10}]');
  t := (r#>>'{}')::integer;
  PERFORM pg_temp.check(pg_temp.js(t) = '1600 Dr 2.5, 3100 Cr 2.7', 'an amount the caller passes is kept; the others are converted', pg_temp.js(t));
  rv := erp._reverse_journal('ZZ99', t, '2026-11-20', 'B6 reversal');
  PERFORM pg_temp.check(pg_temp.js(rv) = '1600 Cr 2.5, 3100 Dr 2.7', 'a reversal mirrors the system currency amounts', pg_temp.js(rv));
  rv := erp._reverse_journal('ZZ99', t2, '2026-11-20', 'B6 reversal');
  PERFORM pg_temp.check(pg_temp.js(rv) = '5210 Cr 100, 5230 Dr 100', 'the USD journal reversed in USD too', pg_temp.js(rv));
  -- system-currency-only journals
  PERFORM pg_temp.expect(pg_temp.pj('2026-11-20', '[{"acct_code":"6200","debit":1,"sys_debit":1},{"acct_code":"6800","sys_credit":1}]', '{"sys_only": true}'),
    'A journal in the system currency only has no AED amounts. Enter the amounts in USD.', 'a system-currency-only journal refuses LC amounts');
  PERFORM pg_temp.expect(pg_temp.pj('2026-11-20', '[{"acct_code":"6200","sys_debit":1},{"acct_code":"6800","sys_credit":0.5}]', '{"sys_only": true}'),
    'Debits 1.00 and credits 0.50 don''t balance. Difference 0.50 USD.', 'a system-currency-only journal must balance in USD');
  PERFORM pg_temp.expect(pg_temp.pj('2026-11-20', '[{"acct_code":"9999","sys_debit":1},{"acct_code":"6800","sys_credit":1}]', '{"sys_only": true}'),
    'Line 1: account 9999 does not exist in ZZ99. Check the account code.', 'the usual account checks apply');
  -- locked once used
  PERFORM pg_temp.expect(pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'AED')$q$),
    format('The system currency of ZZ99 can''t be changed: %s journal entries already carry amounts in USD.', erp._sys_cur_used('ZZ99')), 'the system currency is fixed once journals carry it');
  r := pg_temp.call(admin, $q$SELECT erp.system_currency_info('ZZ99')$q$);
  PERFORM pg_temp.check((r->>'locked')::boolean AND (r->>'active')::boolean AND r->>'system_currency' = 'USD', 'info: active and locked', left(r::text, 200));
  -- switched off outside the app (e.g. a test cleanup): it may be set again
  DELETE FROM erp.system_currency_setting WHERE company_code = 'ZZ99';
  PERFORM pg_temp.check(erp._sys_cur('ZZ99') IS NULL AND NOT (pg_temp.call(admin, $q$SELECT erp.system_currency_info('ZZ99')$q$)->>'locked')::boolean,
    'an inactive system currency is not locked (only an active one is fixed)');
  PERFORM pg_temp.ok(pg_temp.call(admin, $q$SELECT erp.system_currency_save('ZZ99', 'USD')$q$), 'an inactive system currency may be set again');
END $$;

-- ======================================================================= 4. Conversion Differences
DO $$
DECLARE
  sales uuid := '00000000-0000-4000-8000-000000000002';
  fin   uuid := '00000000-0000-4000-8000-000000000004';
  r jsonb; id bigint; t integer; ct integer;
BEGIN
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.conversion_diff_setup('ZZ99')$q$), 'Your position does not include Financials. Ask the system admin if you need it.', 'Financials only');
  PERFORM pg_temp.expect(pg_temp.cvd(NULL, 'post', '{"date":"2026-11-20"}'), 'Sign in first.', 'anonymous refused');
  PERFORM pg_temp.expect(pg_temp.cvd(fin, 'preview', '{}'), 'Choose the posting date.', 'date required');
  PERFORM pg_temp.expect(pg_temp.cvd(fin, 'preview', '{"date":"20 Nov"}'), 'Enter the date as YYYY-MM-DD.', 'date format');
  PERFORM pg_temp.expect(pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20","accounts":false,"partners":false}'), 'Choose G/L accounts, business partners or both.', 'accounts or partners');

  r := pg_temp.cvd(fin, 'preview', '{"date":"2026-11-15"}');
  PERFORM pg_temp.check(jsonb_array_length(r->'rows') = 0, 'up to 15 Nov nothing nets to 0 in AED yet', left(r::text, 300));
  r := pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20"}');
  PERFORM pg_temp.check((SELECT string_agg(x->>'kind' || ':' || (x->>'acct_code') || coalesce('/' || (x->>'card_code'), '') || '=' || trim_scale((x->>'sc_balance')::numeric), ' ')
                           FROM jsonb_array_elements(r->'rows') x) = 'account:1105=-0.2 account:6100=0.2 account:6200=0.2 account:6400=-0.19 account:6800=-0.2 partner:1200/C0001=0.2',
    'preview: accounts and the partner whose AED balance is 0 but USD isn''t (the USD journals and reversals net to 0 in both)',
    (SELECT string_agg(x->>'kind' || ':' || (x->>'acct_code') || coalesce('/' || (x->>'card_code'), '') || '=' || trim_scale((x->>'sc_balance')::numeric), ' ') FROM jsonb_array_elements(r->'rows') x));
  PERFORM pg_temp.check((r->'totals'->>'debit')::numeric = 0.59 AND (r->'totals'->>'credit')::numeric = 0.60 AND (r->'totals'->>'net')::numeric = 0.01
                        AND r->>'sys_currency' = 'USD' AND r->>'acct_code' = '7120', 'totals in USD: 0.59 / 0.60, net 0.01 to the conversion difference account 7120', r->>'totals');
  r := pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20","accounts":false}');
  PERFORM pg_temp.check(jsonb_array_length(r->'rows') = 1 AND r->'rows'->0->>'card_code' = 'C0001', 'business partners only');
  r := pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20","partners":false}');
  PERFORM pg_temp.check(jsonb_array_length(r->'rows') = 5, 'G/L accounts only');

  -- period lock, missing account
  UPDATE erp.posting_period SET status = 'locked' WHERE company_code = 'ZZ99' AND period_code = '2026-11';
  r := pg_temp.cvd(fin, 'post', '{"date":"2026-11-20"}');
  PERFORM pg_temp.check(r->>'message' LIKE 'Posting period 2026-11 is locked%' AND NOT EXISTS (SELECT 1 FROM erp.conv_diff_run), 'a locked period refuses the run', r->>'message');
  UPDATE erp.posting_period SET status = 'open' WHERE company_code = 'ZZ99' AND period_code = '2026-11';
  DELETE FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'conversion_diff';
  r := pg_temp.cvd(fin, 'post', '{"date":"2026-11-20"}');
  PERFORM pg_temp.check(r->>'message' LIKE '%Conversion differences (system currency)%', 'a missing conversion difference account is named (G/L Account Determination)', r->>'message');
  INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source) VALUES ('ZZ99', 'general', 'conversion_diff', '7120', 'sample');

  -- post
  r := pg_temp.cvd(fin, 'post', '{"date":"2026-11-20","memo":"B6 November"}');
  id := (r->>'run_id')::bigint;
  t := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(id IS NOT NULL AND (r->>'rows')::integer = 6 AND r->>'doc_no' = 'CVD-' || id, 'posted: 6 rows', left(r::text, 300));
  PERFORM pg_temp.check(pg_temp.js(t) = '1105 Dr 0.2, 6100 Cr 0.2, 6200 Cr 0.2, 6400 Dr 0.19, 6800 Dr 0.2, 1200/C0001 Cr 0.2, 7120 Dr 0.01',
    'journal in USD only: each row cleared, net 0.01 to 7120', pg_temp.js(t));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t AND (debit <> 0 OR credit <> 0))
                        AND (SELECT total_local = 0 AND total_sys = 0.60 AND source = 'erp' FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t),
    'no AED effect (every LC amount 0, header total 0; USD total 0.60)');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'conversion_diff_post' AND object_ref = id::text AND actor = fin::text)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'conversion_diff_journal' AND object_ref = t::text), 'audit: run and journal');
  r := pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20"}');
  PERFORM pg_temp.check(jsonb_array_length(r->'rows') = 0, 'after the run nothing is left (the conversion difference account itself is not offered)', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.cvd(fin, 'post', '{"date":"2026-11-20"}'), 'There are no conversion differences in ZZ99 up to 20 Nov 2026.', 'nothing to post');
  PERFORM pg_temp.check((SELECT coalesce(sum(debit - credit), 0) FROM erp.journal_line WHERE company_code = 'ZZ99' AND acct_code = '7120') = 0,
    'reports stay in AED: the run changes no AED balance');

  -- info, cancel
  r := pg_temp.call(fin, format('SELECT erp.conversion_diff_info(%L, %s)', 'ZZ99', id));
  PERFORM pg_temp.check(jsonb_array_length(r->'lines') = 6 AND (r->>'can_cancel')::boolean AND r->>'memo' = 'B6 November' AND r->'lines'->0->>'acct_name' IS NOT NULL
                        AND (r->'journals'->0->'lines'->0->>'sys_debit')::numeric = 0.2, 'detail: lines, journal with USD amounts, can cancel', left(r::text, 300));
  PERFORM pg_temp.check(pg_temp.call(sales, format('SELECT erp.conversion_diff_info(%L, %s)', 'ZZ99', id))->>'error' = '42501', 'detail needs Financials');
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.conversion_diff_cancel(%L, %s, %L)', 'ZZ99', id, ' ')), 'Add a reason for cancelling the run.', 'cancel needs a reason');
  r := pg_temp.call(fin, format('SELECT erp.conversion_diff_cancel(%L, %s, %L)', 'ZZ99', id, 'B6 test cancel'));
  ct := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'cancelled' AND pg_temp.js(ct) = '1105 Cr 0.2, 6100 Dr 0.2, 6200 Dr 0.2, 6400 Cr 0.19, 6800 Cr 0.2, 1200/C0001 Dr 0.2, 7120 Cr 0.01'
                        AND NOT EXISTS (SELECT 1 FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = ct AND (debit <> 0 OR credit <> 0)),
    'cancel: the journal reversed in USD only', pg_temp.js(ct));
  PERFORM pg_temp.check(jsonb_array_length(pg_temp.cvd(fin, 'preview', '{"date":"2026-11-20"}')->'rows') = 6, 'after cancelling, the differences are back');
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.conversion_diff_cancel(%L, %s, %L)', 'ZZ99', id, 'again')),
    format('Conversion difference run CVD-%s is already cancelled.', id), 'cancel twice refused');
  r := pg_temp.call(fin, $q$SELECT erp.conversion_diff_setup('ZZ99')$q$);
  PERFORM pg_temp.check((r->>'active')::boolean AND r->>'sys_currency' = 'USD' AND r->>'acct_code' = '7120' AND jsonb_array_length(r->'history') = 1
                        AND r->'history'->0->>'state' = 'cancelled', 'setup: active, USD, account, history', left(r::text, 300));
  PERFORM pg_temp.check(pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.conv_diff_list$q$) = '0'::jsonb
                        AND pg_temp.call(fin, $q$SELECT to_jsonb(count(*)) FROM erp.conv_diff_list$q$) = '1'::jsonb, 'history list: Financials only (RLS)');
END $$;

-- ======================================================================= 5. Keys, accounts, health, security
DO $$
BEGIN
  PERFORM pg_temp.check((SELECT count(*) FROM erp.gl_posting_key) = 39 AND EXISTS (SELECT 1 FROM erp.gl_posting_key WHERE area = 'general' AND posting_key = 'conversion_diff' AND tab = 'general'),
    'G/L Account Determination › General has the conversion difference key (39 keys)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE posting_key = 'conversion_diff' AND company_code <> 'ZZ99'),
    'no conversion difference account for real companies (empty until Finance enters it)');
  PERFORM pg_temp.check((SELECT count(*) FROM erp._health_files()) = 23 AND EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '35_final_items.sql' AND object = 'conversion_diff_post'),
    'system health lists 35_final_items.sql (23 files)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'erp' AND p.prosecdef AND (p.proname LIKE 'conversion_diff%' OR p.proname LIKE 'system_currency%' OR p.proname LIKE '\_cvd%' OR p.proname LIKE '\_sys\_cur%')
                                       AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=erp, pg_temp%', false))),
    'new SECURITY DEFINER functions: search_path set, no anon execute');
  PERFORM pg_temp.check(NOT has_function_privilege('authenticated', 'erp._cvd_eval(varchar, jsonb)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'erp._sys_cur(varchar)', 'EXECUTE'),
    'internal helpers are not callable by users');
  PERFORM pg_temp.check(NOT has_table_privilege('authenticated', 'erp.system_currency_setting', 'INSERT') AND NOT has_table_privilege('authenticated', 'erp.conv_diff_run', 'INSERT'),
    'no direct write grants on the new tables');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM b6_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM b6_result;
ROLLBACK;
