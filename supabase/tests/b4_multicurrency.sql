-- B4 · Multi-currency (sales, purchasing, payments) and soft-switch stock. LOCAL STACK ONLY (sample company ZZ99 +
-- scripts/local-stack/test-users.sql). Run on a FRESH rebuild (sql-order.txt incl. 33_multicurrency.sql). Everything happens
-- inside one transaction that is rolled back. Prints PASS/FAIL · name · detail, then a TOTAL row.
--
-- Rates used (entered by QA Finance below): USD 10 Nov 3.6725 · 12 Nov 3.6800 · 15 Nov 3.6500 · 20 Nov 3.7000. 11 Nov has none.
-- Fixtures (rolled back): customer C0013 trades in USD, customer C0012 in all currencies ('##').
BEGIN;

CREATE TEMP TABLE b4_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON b4_result TO authenticated;

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
  INSERT INTO b4_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
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
CREATE FUNCTION pg_temp.ssave(u uuid, obj integer, h jsonb, l jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_save(%L, %s, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', obj, h, l))
$$;
CREATE FUNCTION pg_temp.ssubmit(u uuid, obj integer, e integer, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.sales_doc_submit(%L, %s, %s, %L)', 'ZZ99', obj, e, reason))
$$;
CREATE FUNCTION pg_temp.pay(u uuid, dir text, h jsonb, l jsonb, reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(u, format('SELECT erp.payment_submit(%L, %L, %L::jsonb, %L::jsonb, %L)', 'ZZ99', dir, h, l, reason))
$$;
CREATE FUNCTION pg_temp.doc(obj integer, e integer) RETURNS erp.document LANGUAGE sql AS $$
  SELECT * FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = obj AND doc_entry = e
$$;
-- "acct Dr|Cr amount [fc]" per journal line, in line order
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END
                    || CASE WHEN fc_currency IS NOT NULL THEN ' [' || trim_scale(coalesce(nullif(fc_debit, 0), fc_credit, 0)) || ']' ELSE '' END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.balanced(p_trans integer) RETURNS boolean LANGUAGE sql AS $$
  SELECT sum(debit) = sum(credit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.oh(item text, whs text DEFAULT 'WH01') RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = item AND whs_code = whs), 0)
$$;

-- Fixtures: a USD customer and an all-currencies customer.
UPDATE erp.business_partner SET currency = 'USD' WHERE company_code = 'ZZ99' AND card_code = 'C0013';
UPDATE erp.business_partner SET currency = '##' WHERE company_code = 'ZZ99' AND card_code = 'C0012';

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  r jsonb; d erp.document; t integer;
  po integer; dp integer; gr integer; ap integer; so integer; dl integer; inv integer; inv2 integer; dl2 integer; so2 integer; cm integer;
  p1 integer; p2 integer; p3 integer;
  hpo jsonb := '{"card_code":"S0001","doc_date":"2026-11-10","due_date":"2026-12-31","whs_code":"WH01"}';
BEGIN
  -- ================= 0. Rates =================
  PERFORM pg_temp.ok(pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-10', 'USD', 3.6725)$q$), 'Finance enters USD 10 Nov 3.6725');
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-12', 'USD', 3.68)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-15', 'USD', 3.65)$q$);
  PERFORM pg_temp.call(fin, $q$SELECT erp.fx_rate_save('ZZ99', '2026-11-20', 'USD', 3.70)$q$);
  r := pg_temp.call(sales, $q$SELECT erp.currency_rate('ZZ99', 'usd', '2026-11-10')$q$);
  PERFORM pg_temp.check(r->>'currency' = 'USD' AND (r->>'rate')::numeric = 3.6725 AND r->>'local' = 'AED' AND NOT (r->>'can_override')::boolean,
    'a sales user reads the USD rate for a form (no Financials needed, may not override)', r::text);
  r := pg_temp.call(sales, $q$SELECT erp.currency_rate('ZZ99', 'USD', '2026-11-11')$q$);
  PERFORM pg_temp.check(r->>'rate' IS NULL AND r->>'message' = 'There is no exchange rate for USD on 11 Nov 2026. Enter it in Administration › Exchange Rates, then try again.',
    'a missing rate names the currency and the date', r::text);
  PERFORM pg_temp.check((pg_temp.call(fin, $q$SELECT erp.currency_rate('ZZ99', 'USD', '2026-11-10')$q$)->>'can_override')::boolean, 'Financials may override the rate');
  PERFORM pg_temp.expect(pg_temp.call(NULL, $q$SELECT erp.currency_rate('ZZ99', 'USD', '2026-11-10')$q$), 'Sign in first.', 'currency_rate: anonymous refused');
  PERFORM pg_temp.expect(pg_temp.call(nobody, $q$SELECT erp.currency_rate('ZZ99', 'USD', '2026-11-10')$q$), 'You don''t have access to company ZZ99.', 'currency_rate: no profile refused');
  PERFORM pg_temp.check(erp._cur_conv('ZZ99', 100, 'USD', 'AED', '2026-11-10') = 367.25 AND erp._cur_conv('ZZ99', 367.25, 'AED', 'USD', '2026-11-10') = 100
                        AND erp._cur_conv('ZZ99', 1, 'USD', 'AED', '2026-11-11') IS NULL, 'conversion through LC at the date''s rate; NULL without a rate');

  -- ================= 1. Purchasing rules =================
  PERFORM pg_temp.expect(pg_temp.psave(purch, 22, hpo || '{"doc_date":"2026-11-11"}', '[{"item_code":"SMP-1140","qty":100,"price":10}]'),
    'There is no exchange rate for USD on 11 Nov 2026. Enter it in Administration › Exchange Rates, then try again.', 'USD purchase order without a rate for the date refused');
  PERFORM pg_temp.expect(pg_temp.psave(purch, 22, hpo || '{"currency":"EUR"}', '[{"item_code":"SMP-1140","qty":100,"price":10}]'),
    'Supplier S0001 trades in USD. Choose USD or AED.', 'another currency than the supplier''s refused');
  PERFORM pg_temp.expect(pg_temp.psave(purch, 22, hpo || '{"fx_rate":3.7}', '[{"item_code":"SMP-1140","qty":100,"price":10}]'),
    'Only Financials can change the exchange rate. The rate for USD on 10 Nov 2026 is 3.6725.', 'a different rate refused for Purchasing');
  PERFORM pg_temp.expect(pg_temp.psave(purch, 22, hpo || '{"fx_rate":-1}', '[{"item_code":"SMP-1140","qty":100,"price":10}]'),
    'The exchange rate must be more than 0.', 'a negative rate refused');
  r := pg_temp.psave(purch, 22, hpo || '{"currency":"AED"}', '[{"item_code":"SMP-1140","qty":1,"price":10}]');
  PERFORM pg_temp.check(r->'totals'->>'currency' = 'AED' AND (r->'totals'->>'rate')::numeric = 1, 'a USD supplier may also be billed in the company currency', left(r::text, 200));
  r := pg_temp.call(admin, format('SELECT erp.purchase_doc_checks(%L, 22, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', hpo || '{"fx_rate":3.7}', '[{"item_code":"SMP-1140","qty":100,"price":10}]'));
  PERFORM pg_temp.check(r->'totals'->>'rate' = '3.7' AND (r->'totals'->>'rate_overridden')::boolean AND jsonb_array_length(r->'errors') = 0,
    'Financials (admin) may type another rate; it is flagged as overridden', left(r::text, 300));

  -- ================= 2. USD factory: PO → deposit → payment → GRPO → A/P invoice → payment =================
  r := pg_temp.psave(purch, 22, hpo, '[{"item_code":"SMP-1140","qty":100,"price":10}]');
  po := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->'totals'->>'currency' = 'USD' AND (r->'totals'->>'total')::numeric = 1050 AND (r->'totals'->>'total_lc')::numeric = 3856.13
                        AND (r->'totals'->>'rate')::numeric = 3.6725, 'USD purchase order: 1,050.00 USD = 3,856.13 AED at 3.6725', left(r::text, 300));
  d := pg_temp.doc(22, po);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.6725 AND d.total = 3856.13 AND d.total_fc = 1050 AND d.vat_total = 183.63 AND d.vat_total_fc = 50,
    'PO header: currency, rate, LC and FC totals', format('%s %s %s %s %s %s', d.currency, d.fx_rate, d.total, d.total_fc, d.vat_total, d.vat_total_fc));
  PERFORM pg_temp.check((SELECT price = 10 AND line_total = 3672.50 AND line_total_fc = 1000 AND vat = 183.63 AND vat_fc = 50 AND currency = 'USD'
                           FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 22 AND doc_entry = po AND line_num = 0),
    'PO line: price in USD, line total in AED and USD');
  r := pg_temp.psubmit(purch, 22, po);
  PERFORM pg_temp.check(r->>'status' = 'open', 'USD PO opens (3,856.13 AED is below the 50,000 AED limit, compared in LC)', r::text);
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_copy_source('ZZ99', 22, %s)$q$, po));
  PERFORM pg_temp.check(r->'header'->>'currency' = 'USD' AND (r->'header'->>'fx_rate')::numeric = 3.6725 AND r->'lines'->0->>'currency' = 'USD'
                        AND (r->'lines'->0->>'line_total_fc')::numeric = 1000, 'copy source carries the currency and rate', left(r::text, 300));

  -- deposit 30 % on 12 Nov (3.68): 315 USD = 1,159.20 AED
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_deposit_create('ZZ99', %s, '{"doc_date":"2026-11-12","pct":30}')$q$, po));
  dp := (r->>'doc_entry')::integer;
  d := pg_temp.doc(204, dp);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.68 AND d.total_fc = 315 AND d.total = 1159.20, 'deposit in USD at its own date''s rate: 315 USD = 1,159.20 AED',
    format('%s %s %s %s', d.currency, d.fx_rate, d.total_fc, d.total));
  t := (SELECT trans_id FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 204 AND doc_entry = dp);
  PERFORM pg_temp.check(pg_temp.jl(t) = '1350 Dr 1159.2 [315], 2100 Cr 1159.2 [315]', 'deposit journal in AED with the USD amounts', pg_temp.jl(t));
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_deposit_create('ZZ99', %s, '{"doc_date":"2026-11-12","amount":800}')$q$, po)),
    'Deposits on PO-26-00002 would be 1,115.00 USD, more than the order total of 1,050.00 USD (315.00 USD already raised).', 'deposits capped at the order total in USD');

  -- pay the deposit on 15 Nov (3.65): 315 USD = 1,149.75 AED, the deposit carried 1,159.20 → gain 9.45
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'O', '{"card_code":"S0001","doc_date":"2026-11-15","transfer":315,"transfer_bank":"BNK-AED","currency":"AED"}',
                                     format('[{"obj_type":204,"doc_entry":%s,"amount":315}]', dp)::jsonb),
    'Line 1: down payment DPI-26-00001 is in USD, but this payment is in AED. Pay each currency''s documents in their own currency.', 'an AED payment can''t pay a USD document');
  r := pg_temp.pay(fin, 'O', '{"card_code":"S0001","doc_date":"2026-11-15","transfer":315,"transfer_bank":"BNK-AED","transfer_ref":"TT-USD-1"}',
                   format('[{"obj_type":204,"doc_entry":%s,"amount":315}]', dp)::jsonb);
  p1 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(r->>'currency' = 'USD' AND (r->>'total')::numeric = 1149.75 AND (r->>'fx_diff')::numeric = -9.45, 'USD outgoing payment posted (A5''s foreign-currency refusal lifted)', left(r::text, 300));
  t := (SELECT trans_id FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = p1);
  PERFORM pg_temp.check(pg_temp.jl(t) = '2100 Dr 1159.2 [315], 1110 Cr 1149.75 [315], 7100 Cr 9.45 [0]' AND pg_temp.balanced(t),
    'payment journal: A/P cleared at the deposit''s 1,159.20, bank 1,149.75, realised gain 9.45 to fx_gain', pg_temp.jl(t));
  d := pg_temp.doc(204, dp);
  PERFORM pg_temp.check(d.paid = 1159.20 AND d.paid_fc = 315 AND erp._bk_doc_open_fc('ZZ99', 204, dp) = 0 AND erp._bk_doc_open('ZZ99', 204, dp) = 0,
    'deposit fully paid in both currencies', format('%s %s', d.paid, d.paid_fc));
  PERFORM pg_temp.check((SELECT total_fc = 315 AND fx_diff = 9.45 AND fx_rate = 3.65 AND currency = 'USD' FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = p1)
                        AND (SELECT applied = 1159.20 AND applied_fc = 315 FROM erp.payment_allocation WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = p1),
    'payment keeps USD total, rate, gain and the allocation in both currencies');

  -- GRPO on 12 Nov keeps the PO rate (3.6725); stock at 36.725 AED
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-12","fx_rate":3.68}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, po)),
    'This goods receipt keeps the exchange rate of the document it is copied from (3.6725).', 'GRPO can''t change the PO rate');
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-12","currency":"AED"}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, po)),
    'The lines you copy are in USD, so this goods receipt is in USD too. The currency can''t be changed on a copy.', 'GRPO can''t change the currency');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, po));
  gr := (r->>'doc_entry')::integer;
  d := pg_temp.doc(20, gr);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.6725 AND d.total = 3856.13 AND d.total_fc = 1050, 'GRPO in USD at the PO rate',
    format('%s %s %s %s', d.currency, d.fx_rate, d.total, d.total_fc));
  PERFORM pg_temp.check((SELECT stock_price FROM erp.document_line WHERE company_code = 'ZZ99' AND obj_type = 20 AND doc_entry = gr AND line_num = 0) = 36.725
                        AND (SELECT price FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_type = 20 AND doc_entry = gr) = 36.725,
    'stock comes in at the LC price 36.725 AED (10 USD × 3.6725)');
  t := (SELECT trans_id FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 20 AND doc_entry = gr);
  PERFORM pg_temp.check(pg_temp.jl(t) = '1300 Dr 3672.5 [1000], 2120 Cr 3672.5 [1000]', 'GRPO journal: inventory / GRNI 3,672.50 AED (1,000 USD)', pg_temp.jl(t));

  -- A/P invoice on 15 Nov (3.65) drawing the deposit
  PERFORM pg_temp.expect(pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-15","down_payments":[{"doc_entry":%s,"amount":400}]}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, dp, gr)),
    'You are drawing 400.00 USD from down payment invoice DPI-26-00001, but only 315.00 USD of it is paid and not drawn yet.', 'draw above the paid deposit refused (in USD)');
  r := pg_temp.call(purch, format($q$SELECT erp.purchase_invoice_create('ZZ99', '{"doc_date":"2026-11-15","customer_ref":"INV-FS-1","down_payments":[{"doc_entry":%s,"amount":315}]}', '[{"base_doc_entry":%s,"base_line":0,"qty":100}]')$q$, dp, gr));
  ap := (r->>'doc_entry')::integer;
  d := pg_temp.doc(18, ap);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.65 AND d.total_fc = 735 AND d.total = 2673.30 AND d.paid = 0,
    'A/P invoice at its own rate 3.65: 1,050 USD − 315 drawn = 735 USD; 3,832.50 − 1,159.20 = 2,673.30 AED', format('%s %s %s %s', d.currency, d.fx_rate, d.total_fc, d.total));
  PERFORM pg_temp.check((SELECT amount = 1159.20 AND amount_fc = 315 FROM erp.ap_dp_draw WHERE company_code = 'ZZ99' AND invoice_entry = ap),
    'the draw is 315 USD = 1,159.20 AED (the deposit''s own LC)');
  t := (SELECT trans_id FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = ap);
  PERFORM pg_temp.check(pg_temp.jl(t) = '2120 Dr 3672.5 [1000], 7100 Cr 22.5 [0], 1400 Dr 182.5 [50], 2100 Cr 3832.5 [1050], 2100 Dr 1159.2 [315], 1350 Cr 1159.2 [315]'
                        AND pg_temp.balanced(t),
    'A/P journal: GRNI cleared at the GRPO''s 3,672.50, rate difference 22.50 to fx_gain, VAT and A/P at 3.65, deposit drawn', pg_temp.jl(t));
  PERFORM pg_temp.check((SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 204 AND doc_entry = dp) = 'closed', 'fully drawn deposit closed');
  r := pg_temp.call(fin, format($q$SELECT erp.payment_open_docs('ZZ99', 'O', 'S0001')$q$));
  PERFORM pg_temp.check((SELECT (x->>'open')::numeric = 735 AND (x->>'open_lc')::numeric = 2673.30 AND x->>'currency' = 'USD' FROM jsonb_array_elements(r->'docs') x WHERE (x->>'doc_entry')::integer = ap),
    'open documents list the invoice in USD (735) and AED (2,673.30)', left(r::text, 400));

  -- pay 735 USD on 15 Nov (3.65 = 2,682.75 AED) → loss 9.45
  r := pg_temp.pay(fin, 'O', '{"card_code":"S0001","doc_date":"2026-11-15","transfer":735,"transfer_bank":"BNK-AED","transfer_ref":"TT-USD-2"}',
                   format('[{"obj_type":18,"doc_entry":%s,"amount":735}]', ap)::jsonb);
  p2 := (r->>'doc_entry')::integer;
  t := (SELECT trans_id FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = p2);
  PERFORM pg_temp.check(pg_temp.jl(t) = '2100 Dr 2673.3 [735], 1110 Cr 2682.75 [735], 7200 Dr 9.45 [0]' AND pg_temp.balanced(t),
    'invoice payment: A/P 2,673.30 cleared, bank 2,682.75, realised loss 9.45 to fx_loss', coalesce(pg_temp.jl(t), r::text));
  d := pg_temp.doc(18, ap);
  PERFORM pg_temp.check(d.paid = 2673.30 AND d.paid_fc = 735 AND erp._bk_doc_open('ZZ99', 18, ap) = 0, 'USD factory invoice fully paid in both currencies');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'O', '{"card_code":"S0001","doc_date":"2026-11-15","transfer":1,"transfer_bank":"BNK-AED"}',
                                     format('[{"obj_type":18,"doc_entry":%s,"amount":1}]', ap)::jsonb),
    'Line 1: 1.00 USD is more than the 0.00 USD still open on A/P invoice AP-26-00001.', 'nothing left to pay (message in USD)');

  -- ================= 3. Sales in USD =================
  PERFORM pg_temp.expect(pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-11","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":1,"price":50}]'),
    'There is no exchange rate for USD on 11 Nov 2026. Enter it in Administration › Exchange Rates, then try again.', 'USD order without a rate refused');
  PERFORM pg_temp.expect(pg_temp.ssave(sales, 17, '{"card_code":"C0012","doc_date":"2026-11-10","whs_code":"WH01","currency":"JPY"}', '[{"item_code":"SMP-1010","qty":1,"price":50}]'),
    'Currency JPY is not in the rates list of ZZ99 (USD, SAR, CNY, EUR).', 'all-currencies customer: only listed currencies');
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0012","doc_date":"2026-11-10","whs_code":"WH01","currency":"USD"}', '[{"item_code":"SMP-1010","qty":1}]');
  PERFORM pg_temp.check(r->'totals'->>'currency' = 'USD' AND (r->'lines'->0->>'price')::numeric = round(133.16 / 3.6725, 6),
    'all-currencies customer picks USD; the AED price list price is converted (133.16 / 3.6725)', left(r::text, 300));
  r := pg_temp.ssubmit(sales, 17, (r->>'doc_entry')::integer);
  PERFORM pg_temp.check(r->>'status' = 'open' AND (SELECT currency = 'USD' AND fx_rate = 3.6725 FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17
                          AND doc_entry = (SELECT max(doc_entry) FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 17 AND card_code = 'C0012')),
    'submit re-checks the stored order in its own currency (USD kept)', r::text);
  r := pg_temp.call(admin, format('SELECT erp.sales_doc_save(%L, 17, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', '{"card_code":"C0013","doc_date":"2026-11-10","whs_code":"WH01","fx_rate":3.7}', '[{"item_code":"SMP-1010","qty":1,"price":50}]'));
  PERFORM pg_temp.check((pg_temp.doc(17, (r->>'doc_entry')::integer)).fx_rate = 3.7, 'Financials saves an order at its own rate (3.7)', left(r::text, 200));
  r := pg_temp.ssubmit(admin, 17, (r->>'doc_entry')::integer);
  PERFORM pg_temp.check(r->>'status' = 'open', 'the kept rate passes the re-check at submit', r::text);
  r := pg_temp.call(sales, format('SELECT erp.sales_doc_checks(%L, 17, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', '{"card_code":"C0013","doc_date":"2026-11-10","whs_code":"WH01"}',
                                  '[{"item_code":"SMP-1010","qty":10,"price":50}]'));
  PERFORM pg_temp.check((r->'credit'->>'this_order')::numeric = 1928.06 AND r->'credit'->>'currency' = 'AED', 'credit position counts the order in AED (525 USD = 1,928.06 AED)', left(r->>'credit', 300));
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-10","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":10,"price":50}]');
  so := (r->>'doc_entry')::integer;
  d := pg_temp.doc(17, so);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.6725 AND d.total_fc = 525 AND d.total = 1928.06, 'USD sales order: 525.00 USD = 1,928.06 AED',
    format('%s %s %s %s', d.currency, d.fx_rate, d.total_fc, d.total));
  PERFORM pg_temp.check((pg_temp.ssubmit(sales, 17, so))->>'status' = 'open', 'USD order opens');
  r := pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":10}]')$q$, so));
  dl := (r->>'doc_entry')::integer;
  d := pg_temp.doc(15, dl);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.6725 AND d.total_fc = 525, 'delivery keeps the order''s currency and rate', format('%s %s %s', d.currency, d.fx_rate, d.total_fc));
  t := (SELECT trans_id FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 15 AND doc_entry = dl);
  PERFORM pg_temp.check(pg_temp.balanced(t) AND (SELECT bool_and(fc_currency = 'USD') FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t),
    'delivery posts cost of goods sold in AED (FC shown)', pg_temp.jl(t));
  r := pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":10}]')$q$, dl));
  inv := (r->>'doc_entry')::integer;
  d := pg_temp.doc(13, inv);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.65 AND d.total_fc = 525 AND d.total = 1916.25 AND d.vat_total = 91.25,
    'A/R invoice takes its own date''s rate: 525 USD = 1,916.25 AED', format('%s %s %s %s', d.currency, d.fx_rate, d.total_fc, d.total));
  t := (SELECT trans_id FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = inv);
  PERFORM pg_temp.check(pg_temp.jl(t) = '1200 Dr 1916.25 [525], 4100 Cr 1825 [500], 2200 Cr 91.25 [25]', 'A/R invoice journal with USD amounts', pg_temp.jl(t));

  -- incoming: 200 USD on 15 Nov (no difference), 325 USD on 20 Nov at 3.70 (gain 16.25)
  r := pg_temp.pay(fin, 'I', '{"card_code":"C0013","doc_date":"2026-11-15","transfer":200,"transfer_bank":"BNK-AED","transfer_ref":"USD-IN-1"}',
                   format('[{"obj_type":13,"doc_entry":%s,"amount":200}]', inv)::jsonb);
  p3 := (r->>'doc_entry')::integer;
  d := pg_temp.doc(13, inv);
  PERFORM pg_temp.check(d.paid = 730 AND d.paid_fc = 200 AND (r->>'fx_diff')::numeric = 0 AND erp._bk_doc_open_fc('ZZ99', 13, inv) = 325 AND erp._bk_doc_open('ZZ99', 13, inv) = 1186.25,
    'part payment 200 USD clears 730.00 AED in proportion; 325 USD / 1,186.25 AED still open', format('%s %s %s', d.paid, d.paid_fc, r->>'fx_diff'));
  r := pg_temp.pay(fin, 'I', '{"card_code":"C0013","doc_date":"2026-11-20","transfer":325,"transfer_bank":"BNK-AED","transfer_ref":"USD-IN-2"}',
                   format('[{"obj_type":13,"doc_entry":%s,"amount":325}]', inv)::jsonb);
  p2 := (r->>'doc_entry')::integer;
  t := (SELECT trans_id FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'I' AND doc_entry = p2);
  PERFORM pg_temp.check(pg_temp.jl(t) = '1110 Dr 1202.5 [325], 1200 Cr 1186.25 [325], 7100 Cr 16.25 [0]' AND pg_temp.balanced(t),
    'final payment at 3.70: bank 1,202.50, A/R rest 1,186.25, realised gain 16.25', coalesce(pg_temp.jl(t), r::text));
  d := pg_temp.doc(13, inv);
  PERFORM pg_temp.check(d.paid = 1916.25 AND d.paid_fc = 525, 'USD invoice fully paid in both currencies');
  -- cancel the final payment: everything back
  r := pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'I', %s, '2026-11-20', 'Wrong value date')$q$, p2));
  d := pg_temp.doc(13, inv);
  PERFORM pg_temp.check(d.paid = 730 AND d.paid_fc = 200 AND pg_temp.jl((r->>'trans_id')::integer) = '1110 Cr 1202.5 [325], 1200 Dr 1186.25 [325], 7100 Dr 16.25 [0]',
    'payment cancel: paid amounts back in both currencies, reversal mirrors the USD amounts and the gain', coalesce(pg_temp.jl((r->>'trans_id')::integer), r::text));
  r := pg_temp.call(sales, $q$SELECT row_to_json(a)::jsonb FROM erp.rpt_ar_aging_fc('ZZ99', '2026-11-30') a WHERE a.card_code = 'C0013'$q$);
  PERFORM pg_temp.check(r->>'currency' = 'USD' AND (r->>'total_fc')::numeric = 325 AND (r->>'total')::numeric = 1186.25, 'customer aging: AED total with the USD open amount', r::text);
  r := pg_temp.call(sales, $q$SELECT row_to_json(b)::jsonb FROM erp.bp_balance_fc b WHERE b.company_code = 'ZZ99' AND b.card_code = 'C0013'$q$);
  PERFORM pg_temp.check((r->>'open_fc')::numeric = 325 AND (r->>'open_lc')::numeric = 1186.25 AND r->>'side' = 'receivable', 'partner balance in USD and AED', r::text);
  PERFORM pg_temp.check(pg_temp.call(purch, $q$SELECT row_to_json(b)::jsonb FROM erp.bp_balance_fc b WHERE b.company_code = 'ZZ99' AND b.card_code = 'C0013'$q$) = 'null'::jsonb,
    'Purchasing doesn''t see customer balances');

  -- credit memo keeps the invoice's rate and nets it in both currencies
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-12","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":3,"price":40}]');
  so2 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ssubmit(sales, 17, so2);
  dl2 := (pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":3}]')$q$, so2))->>'doc_entry')::integer;
  -- an AED order of the same customer: copying AED and USD deliveries into one invoice is refused
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0013","doc_date":"2026-11-12","whs_code":"WH01","currency":"AED"}', '[{"item_code":"SMP-1010","qty":1,"price":150}]');
  PERFORM pg_temp.ssubmit(sales, 17, (r->>'doc_entry')::integer);
  r := pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-12"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, (r->>'doc_entry')::integer));
  PERFORM pg_temp.check((pg_temp.doc(15, (r->>'doc_entry')::integer)).currency = 'AED', 'a USD customer may also buy in AED');
  PERFORM pg_temp.expect(pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":3},{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, dl2, (r->>'doc_entry')::integer)),
    'The lines you copy are in more than one currency (AED, USD). Copy the documents of one currency at a time.', 'one invoice can''t mix AED and USD deliveries');
  inv2 := (pg_temp.call(sales, format($q$SELECT erp.sales_invoice_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":3}]')$q$, dl2))->>'doc_entry')::integer;
  PERFORM pg_temp.expect(pg_temp.call(sales, format($q$SELECT erp.sales_credit_memo_create('ZZ99', '{"doc_date":"2026-11-20","fx_rate":3.5}', '[{"base_doc_entry":%s,"base_line":0,"qty":3}]')$q$, inv2)),
    'This credit memo keeps the exchange rate of the document it is copied from (3.7).', 'credit memo can''t change the invoice rate');
  r := pg_temp.call(sales, format($q$SELECT erp.sales_credit_memo_create('ZZ99', '{"doc_date":"2026-11-20"}', '[{"base_doc_entry":%s,"base_line":0,"qty":3}]')$q$, inv2));
  cm := (r->>'doc_entry')::integer;
  d := pg_temp.doc(14, cm);
  PERFORM pg_temp.check(d.currency = 'USD' AND d.fx_rate = 3.70 AND d.total_fc = 126 AND erp._bk_doc_open_fc('ZZ99', 13, inv2) = 0 AND erp._bk_doc_open('ZZ99', 13, inv2) = 0,
    'credit memo at the invoice rate nets the invoice to 0 in USD and AED', format('%s %s %s', d.currency, d.fx_rate, d.total_fc));

  -- ================= 4. Payments: currency rules =================
  r := pg_temp.call(fin, format('SELECT erp.payment_checks(%L, %L, %L::jsonb, %L::jsonb)', 'ZZ99', 'I', '{"card_code":"C0013","doc_date":"2026-11-15","transfer":10,"transfer_bank":"BNK-AED","fx_rate":3.9}', '[]'));
  PERFORM pg_temp.check((r->'totals'->>'rate')::numeric = 3.9 AND (r->'totals'->>'rate_overridden')::boolean AND (r->'totals'->>'total_lc')::numeric = 39,
    'Financials may type another payment rate (flagged, LC 39.00)', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0013","doc_date":"2026-11-15","transfer":10,"transfer_bank":"BNK-AED","currency":"EUR"}', '[]'),
    'Customer C0013 trades in USD. Choose USD or AED.', 'payment in another currency than the customer''s refused');
  -- approval amounts in LC: 13,650 USD = 50,129.63 AED is above QA Purchasing's 50,000 AED
  r := pg_temp.psave(purch, 22, hpo || '{"due_date":"2027-01-31"}', '[{"item_code":"SMP-1150","qty":1000,"price":13,"tax_code":"RC"}]');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'checks') c WHERE c->>'rule_code' = 'po_amount'
                        AND c->>'message' = 'Purchase order total 50,129.63 AED is above your limit of 50,000.00 AED.'),
    'USD PO above the AED limit flags po_amount with the AED amount', left(r::text, 400));
END $$;

-- ================= 5. Soft switch: SAP on-hand + Super ERP movements =================
CREATE TABLE IF NOT EXISTS sap."OITW" (company_code varchar(8), "ItemCode" text, "WhsCode" text, "OnHand" numeric, "IsCommited" numeric, "OnOrder" numeric,
                                       "AvgPrice" numeric, "MinStock" numeric, "MaxStock" numeric);
CREATE TABLE IF NOT EXISTS sap."OIVL" (company_code varchar(8), "TransSeq" bigint, "TransType" integer, "CreatedBy" integer, "DocLineNum" integer, "DocDate" timestamp,
                                       "ItemCode" text, "LocCode" text, "InQty" numeric, "OutQty" numeric, "Price" numeric, "Currency" text);
UPDATE erp.item SET source = 'sap' WHERE company_code = 'ZZ99' AND item_code = 'SMP-1010';   -- fixture: an item that comes from SAP
CREATE FUNCTION pg_temp.sync_stock() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('erp.sync', 'on', true);
  PERFORM erp.sync_stock_balances('ZZ99');
  PERFORM erp.sync_stock_movements('ZZ99');
  PERFORM set_config('erp.sync', 'off', true);
END $$;
CREATE FUNCTION pg_temp.sb() RETURNS erp.stock_balance LANGUAGE sql AS $$
  SELECT * FROM erp.stock_balance WHERE company_code = 'ZZ99' AND item_code = 'SMP-1010' AND whs_code = 'WH01'
$$;

DO $$
DECLARE
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  purch  uuid := '00000000-0000-4000-8000-000000000010';
  b erp.stock_balance; b0 erp.stock_balance;
  e0 numeric; c0 numeric; atp0 numeric; r jsonb; so integer; po integer; seq bigint; ln bigint; p1 integer; p2 integer;
BEGIN
  b0 := pg_temp.sb();
  e0 := b0.erp_on_hand; c0 := b0.erp_committed;
  PERFORM pg_temp.check(e0 = -14, 'the USD deliveries above are Super ERP movements (−14 of SMP-1010 in WH01)', e0::text);
  INSERT INTO sap."OITW" VALUES ('ZZ99', 'SMP-1010', 'WH01', 1000, 200, 0, 95, NULL, NULL);
  PERFORM pg_temp.sync_stock();
  b := pg_temp.sb();
  PERFORM pg_temp.check(b.sap_on_hand = 1000 AND b.on_hand = 1000 + e0 AND b.erp_on_hand = e0 AND b.committed = 200 + c0,
    'sync 1: on hand = SAP 1,000 + Super ERP −14 = 986; committed = SAP 200 + Super ERP', format('%s = %s + %s; committed %s', b.on_hand, b.sap_on_hand, b.erp_on_hand, b.committed));
  atp0 := erp.atp('ZZ99', 'SMP-1010', 'WH01', '2026-11-30');
  -- Super ERP documents between two syncs: delivery −5, goods receipt +8, an open order commits 4
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0011","doc_date":"2026-11-15","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":5,"price":150}]');
  so := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ssubmit(sales, 17, so);
  PERFORM pg_temp.ok(pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":5}]')$q$, so)), 'delivery −5 (Super ERP)');
  r := pg_temp.psave(purch, 22, '{"card_code":"S0009","doc_date":"2026-11-15","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":8,"price":90}]');
  po := (r->>'doc_entry')::integer;
  PERFORM pg_temp.psubmit(purch, 22, po);
  PERFORM pg_temp.ok(pg_temp.call(purch, format($q$SELECT erp.purchase_grpo_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":8}]')$q$, po)), 'goods receipt +8 (Super ERP)');
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0011","doc_date":"2026-11-15","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":4,"price":150}]');
  PERFORM pg_temp.ssubmit(sales, 17, (r->>'doc_entry')::integer);
  b := pg_temp.sb();
  PERFORM pg_temp.check(b.on_hand = 1000 + e0 + 3 AND b.erp_on_hand = e0 + 3 AND b.sap_on_hand = 1000 AND b.erp_committed = c0 + 4,
    'between syncs: Super ERP part +3 on hand, +4 committed; SAP part unchanged', format('%s / %s / %s / %s', b.on_hand, b.sap_on_hand, b.erp_on_hand, b.erp_committed));
  PERFORM pg_temp.sync_stock();
  b := pg_temp.sb();
  PERFORM pg_temp.check(b.on_hand = 1000 + e0 + 3 AND b.erp_on_hand = e0 + 3 AND b.committed = 200 + c0 + 4,
    'sync 2 with the same SAP figure: Super ERP movements kept (989), commitments kept', format('%s / %s', b.on_hand, b.committed));
  UPDATE sap."OITW" SET "OnHand" = 990 WHERE company_code = 'ZZ99' AND "ItemCode" = 'SMP-1010' AND "WhsCode" = 'WH01';
  PERFORM pg_temp.sync_stock();
  b := pg_temp.sb();
  PERFORM pg_temp.check(b.on_hand = 990 + e0 + 3 AND b.sap_on_hand = 990, 'sync 3: a changed SAP figure (990) shows at once: 990 + Super ERP = 979', format('%s / %s', b.on_hand, b.sap_on_hand));
  PERFORM pg_temp.check(erp.atp('ZZ99', 'SMP-1010', 'WH01', '2026-11-30') = atp0 - 10 + 3 - 4,
    'ATP follows the combined figure (−10 SAP, +3 on hand, −4 committed)', format('%s → %s', atp0, erp.atp('ZZ99', 'SMP-1010', 'WH01', '2026-11-30')));
  -- no negative stock against the combined figure: SAP says 0, Super ERP −11 → nothing to deliver
  UPDATE sap."OITW" SET "OnHand" = 13 WHERE company_code = 'ZZ99' AND "ItemCode" = 'SMP-1010' AND "WhsCode" = 'WH01';
  PERFORM pg_temp.sync_stock();
  r := pg_temp.ssave(sales, 17, '{"card_code":"C0011","doc_date":"2026-11-15","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":3,"price":150}]');
  so := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ssubmit(sales, 17, so, 'Customer waits');
  PERFORM pg_temp.expect(pg_temp.call(sales, format($q$SELECT erp.sales_delivery_create('ZZ99', '{"doc_date":"2026-11-15"}', '[{"base_doc_entry":%s,"base_line":0,"qty":3}]')$q$, so)),
    'Line 1: only 2 of SMP-1010 are in stock in WH01. Delivering 3 would make stock negative, and WH01 does not allow negative stock.',
    'no-negative-stock check uses SAP 13 + Super ERP −11 = 2');
  -- the sync never overwrites a Super ERP warehouse-journal row
  SELECT trans_seq INTO seq FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_seq >= 900000000 AND item_code = 'SMP-1010' ORDER BY trans_seq LIMIT 1;
  INSERT INTO sap."OIVL" VALUES ('ZZ99', seq, 13, 1, 0, '2026-11-01', 'SMP-1010', 'WH01', 999, 0, 1, 'AED'), ('ZZ99', 4242, 13, 1, 0, '2026-11-01', 'SMP-1010', 'WH01', 1, 0, 1, 'AED');
  PERFORM pg_temp.sync_stock();
  PERFORM pg_temp.check((SELECT qty_in FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_seq = seq) <> 999
                        AND EXISTS (SELECT 1 FROM erp.sync_conflict WHERE company_code = 'ZZ99' AND table_name = 'stock_movement' AND row_key = seq::text)
                        AND EXISTS (SELECT 1 FROM erp.stock_movement WHERE company_code = 'ZZ99' AND trans_seq = 4242),
    'stock movements: SAP rows load, a Super ERP row is kept and the clash is logged');
  PERFORM pg_temp.check((SELECT on_hand = sap_on_hand + erp_on_hand FROM erp.stock_balance_parts WHERE company_code = 'ZZ99' AND item_code = 'SMP-1010' AND whs_code = 'WH01'),
    'stock_balance_parts shows both parts');

  -- ================= 6. Manual bank matching ranks by reference =================
  r := pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-10","transfer":777.77,"transfer_bank":"BNK-AED","transfer_ref":"REF-AAA1"}', '[]');
  p1 := (r->>'doc_entry')::integer;
  r := pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-10","transfer":777.77,"transfer_bank":"BNK-AED","transfer_ref":"REF-BBB2"}', '[]');
  p2 := (r->>'doc_entry')::integer;
  PERFORM pg_temp.ok(pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'b4.csv', '[{"date":"2026-11-11","amount":777.77,"reference":"BBB2","description":"Customer transfer"}]')$q$),
    'statement imported');
  SELECT line_id INTO ln FROM erp.bank_statement_line WHERE company_code = 'ZZ99' AND reference = 'BBB2' ORDER BY line_id DESC LIMIT 1;
  r := pg_temp.call(fin, format('SELECT erp.bank_statement_candidates(%L, %s)', 'ZZ99', ln));
  PERFORM pg_temp.check(jsonb_array_length(r) = 2 AND (r->0->>'ref_match')::boolean AND NOT (r->1->>'ref_match')::boolean
                        AND (r->0->>'trans_id')::integer = (SELECT trans_id FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'I' AND doc_entry = p2),
    'manual candidates: the payment whose reference fits comes first (ref_match)', left(r::text, 400));

  -- ================= 7. Health =================
  PERFORM pg_temp.check((SELECT count(*) FROM erp._health_files()) = 21 AND EXISTS (SELECT 1 FROM erp._health_files() WHERE file_name = '33_multicurrency.sql' AND object = 'currency_rate'),
    'system health lists 33_multicurrency.sql (21 files)');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM b4_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM b4_result;
ROLLBACK;
