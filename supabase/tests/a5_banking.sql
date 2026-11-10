-- A5 · Banking tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (base.txt incl. 20_banking.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a5_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a5_result TO authenticated;

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
CREATE FUNCTION pg_temp.su(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    EXECUTE p_sql INTO v;
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.pay(p_user uuid, p_dir text, p_header jsonb, p_lines jsonb, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.payment_submit(%L, %L, %L::jsonb, %L::jsonb, %L)', 'ZZ99', p_dir, p_header, p_lines, p_reason))
$$;
CREATE FUNCTION pg_temp.chk(p_user uuid, p_dir text, p_header jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.payment_checks(%L, %L, %L::jsonb, %L::jsonb)', 'ZZ99', p_dir, p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.decide(p_user uuid, p_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.payment_decide(%L, %s, %L, %L)', 'ZZ99', p_id, p_decision, p_note))
$$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a5_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 200)))
$$;
-- Does a journal balance (and is it there)?
CREATE FUNCTION pg_temp.balanced(p_trans integer) RETURNS boolean LANGUAGE sql AS $$
  SELECT count(*) >= 2 AND sum(debit) = sum(credit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;
CREATE FUNCTION pg_temp.jl(p_trans integer) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(acct_code || CASE WHEN debit > 0 THEN ' Dr ' || trim_scale(debit) ELSE ' Cr ' || trim_scale(credit) END
                    || CASE WHEN short_name IS DISTINCT FROM acct_code THEN ' ' || short_name ELSE '' END, ', ' ORDER BY line_id)
    FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = p_trans
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  fmgr   uuid := '00000000-0000-4000-8000-000000000008';
  bread  uuid := '00000000-0000-4000-8000-000000000009';
  r jsonb; r2 jsonb;
  inv1 integer; inv2 integer; no1 text; no2 text; t1 numeric; t2 numeric; cm numeric;
  bal0 numeric; bal1 numeric;
  pin integer; pin_no text; pin_trans integer;
  p5 integer; p5_trans integer; p5_no text;
  d1 integer; d2 integer; d3 integer; d4 integer;
  pbig integer; pbig_trans integer; pbc integer; pbc_trans integer;
  dep integer; dep_no text; dep_trans integer;
  stmt integer; v_line bigint; v_fee bigint; v_fee2 bigint; v_t integer; v_l integer; v_cnt integer; v_je integer;
  chq1 integer; chq2 integer;
  v_today text := to_char(current_date, 'DD Mon YYYY');
  h_in jsonb;
BEGIN
  -- ---------- Fixtures: two Super ERP A/R invoices and a credit memo (A4 functions), two Super ERP A/P invoices ----------
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"card_code":"C0011","doc_date":"2026-11-09"}', '[{"item_code":"SMP-SVC-01","qty":10,"price":100}]')$q$);
  inv1 := (r->>'doc_entry')::integer; no1 := r->>'doc_no'; t1 := (r->>'total')::numeric;
  r := pg_temp.call(sales, $q$SELECT erp.sales_invoice_create('ZZ99', '{"card_code":"C0011","doc_date":"2026-11-09"}', '[{"item_code":"SMP-SVC-01","qty":5,"price":200}]')$q$);
  inv2 := (r->>'doc_entry')::integer; no2 := r->>'doc_no'; t2 := (r->>'total')::numeric;
  r := pg_temp.call(sales, format($q$SELECT erp.sales_credit_memo_create('ZZ99', '{"doc_date":"2026-11-09"}', '[{"base_doc_entry":%s,"base_line":0,"qty":1}]')$q$, inv2));
  cm := (r->>'total')::numeric;
  PERFORM pg_temp.check(t1 = 1050 AND t2 = 1050 AND cm = 210, 'fixtures: invoices 1,050 + 1,050 and credit memo 210 (5% VAT)', format('%s %s %s', t1, t2, cm));
  PERFORM pg_temp.su($q$WITH x AS (INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, card_code, card_name, currency, total, vat_total, paid, source)
    VALUES ('ZZ99', 18, 990000501, 990000501, 'ap_invoice', 'open', '2026-11-01', '2026-11-30', 'S0006', 'Sample Freight Forwarder', 'AED', 30000, 0, 0, 'erp'),
           ('ZZ99', 18, 990000502, 990000502, 'ap_invoice', 'open', '2026-11-01', '2026-11-30', 'S0005', 'Local Carton Supplier', 'AED', 5000, 0, 0, 'erp') RETURNING 1)
    SELECT to_jsonb(count(*)) FROM x$q$);

  -- ---------- Access ----------
  PERFORM pg_temp.expect(pg_temp.chk(sales, 'I', '{}', '[]'), 'Your position does not include Banking. Ask the system admin if you need it.', 'sales-only user: no Banking');
  PERFORM pg_temp.expect(pg_temp.chk(nobody, 'I', '{}', '[]'), 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.', 'user without profile refused');
  PERFORM pg_temp.expect(pg_temp.pay(bread, 'I', '{}', '[]'), 'You have read-only access to Banking. Ask the system admin for full access to record payments.', 'banking read-only: payment refused');
  r := pg_temp.chk(bread, 'I', '{"card_code":"C0011"}', '[]');
  PERFORM pg_temp.check(r ? 'errors', 'banking read-only: live check allowed (read)', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.payment_setup('AE01', 'I')$q$), 'You don''t have access to company AE01.', 'other company refused');
  r := pg_temp.call(fin, $q$SELECT erp.payment_open_docs('ZZ99', 'I', 'C0011')$q$);
  PERFORM pg_temp.check((SELECT (d->>'open')::numeric FROM jsonb_array_elements(r->'docs') d WHERE (d->>'doc_entry')::integer = inv1) = 1050
                        AND (SELECT (d->>'open')::numeric FROM jsonb_array_elements(r->'docs') d WHERE (d->>'doc_entry')::integer = inv2) = 840
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'docs') d WHERE (d->>'obj_type')::integer = 14),
                        'open documents: invoice 1,050, invoice less its credit memo 840; the credit memo is already applied to its invoice', left(r->>'docs', 300));

  -- ---------- Validation and over-allocation ----------
  h_in := '{"card_code":"C0011","doc_date":"2026-11-09","transfer":500,"transfer_bank":"BNK-AED"}';
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, format('[{"obj_type":13,"doc_entry":%s,"amount":1050.01}]', inv1)::jsonb),
    format('Line 1: 1,050.01 AED is more than the 1,050.00 AED still open on invoice %s.', no1), 'over-allocation refused (more than open)');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, format('[{"obj_type":13,"doc_entry":%s,"amount":600}]', inv1)::jsonb),
    'You applied 600.00 AED but the payment is 500.00 AED. Lower the applied amounts or raise the payment.', 'over-allocation refused (more than the payment)');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, format('[{"obj_type":13,"doc_entry":%s,"amount":100},{"obj_type":13,"doc_entry":%s,"amount":100}]', inv1, inv1)::jsonb),
    format('Line 2: invoice %s is listed twice.', no1), 'same invoice twice refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, format('[{"obj_type":14,"doc_entry":%s,"amount":10}]', (SELECT max(doc_entry) FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 14 AND source = 'erp'))::jsonb),
    format('Line 1: 10.00 AED is more than the 0.00 AED still open on credit memo %s.', (SELECT erp._sd_no('ZZ99', 14, max(doc_entry)) FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 14 AND source = 'erp')),
    'credit memo already applied to its invoice can''t be used again');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, '[{"obj_type":13,"doc_entry":59,"amount":10}]'),
    'Line 1: invoice 100059 is sample test data and can''t be paid.', 'sample invoice refused');
  PERFORM pg_temp.su($q$WITH x AS (INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, currency, total, paid, source)
    VALUES ('ZZ99', 13, 777501, 777501, 'ar_invoice', 'open', '2026-11-01', 'C0011', 'AED', 900, 0, 'sap') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, '[{"obj_type":13,"doc_entry":777501,"amount":10}]'),
    'Line 1: invoice 777501 came from SAP Business One. Record its payment in SAP during the soft switch.', 'SAP invoice refused (paid in SAP during the soft switch)');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0003","doc_date":"2026-11-09","transfer":500,"transfer_bank":"BNK-AED"}', format('[{"obj_type":13,"doc_entry":%s,"amount":10}]', inv1)::jsonb),
    format('Line 1: invoice %s belongs to C0011, not C0003.', no1), 'another customer''s invoice refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', h_in, '[{"obj_type":18,"doc_entry":990000501,"amount":10}]'),
    'Line 1: an incoming payment pays A/R invoices and uses A/R credit memos only.', 'incoming payment can''t pay an A/P invoice');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09"}', '[]'),
    'Enter the amount received: cash, transfer, cheque or card.', 'no amount refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09","transfer":100}', '[]'),
    'Choose the bank account the transfer was paid into.', 'transfer without bank account refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09","cash":-5}', '[]'), 'Cash must be a number of 0 or more.', 'negative cash refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09","cheques":[{"amount":100,"due_date":"2026-11-09"}]}', '[]'),
    'Cheque 1: enter the cheque number.', 'cheque without number refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"S0005","doc_date":"2026-11-09","cash":10}', '[]'), 'S0005 is not a customer. Choose a customer.', 'supplier on an incoming payment refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'O', '{"card_code":"S0001","doc_date":"2026-11-09","transfer":10,"transfer_bank":"BNK-AED"}', '[]'),
    'There is no exchange rate for USD on 09 Nov 2026. Enter it in Administration › Exchange Rates, then try again.', 'USD supplier: payments in USD need the day''s rate (B4: foreign-currency payments allowed)');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'O', '{"card_code":"S0005","doc_date":"2026-11-09","card":10}', '[]'),
    'Outgoing payments by card are not supported. Pay by transfer, cheque or cash.', 'outgoing card refused');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'O', '{"card_code":"S0005","doc_date":"2026-11-09","cheques":[{"cheque_no":"900001","amount":10,"due_date":"2026-11-09"}]}', '[]'),
    'Choose the bank account the cheques are drawn on.', 'outgoing cheque without bank account refused');
  PERFORM pg_temp.call(fin, $q$SELECT erp.period_set_status('ZZ99', '2026-10', 'closed')$q$);
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-10-15","cash":10}', '[]'),
    'Posting period 2026-10 is closed, so nothing can be posted on 15 Oct 2026. Choose a date in an open period, or ask Finance to reopen it.', 'closed period refused');
  PERFORM pg_temp.call(fin, $q$SELECT erp.period_set_status('ZZ99', '2026-10', 'open')$q$);
  PERFORM pg_temp.su($q$WITH x AS (UPDATE erp.banking_setting SET card_acct = NULL WHERE company_code = 'ZZ99' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09","card":10}', '[]'),
    'The account for card receipts is not set for ZZ99. Ask Finance to set it in Banking › Banking Setup.', 'missing card account named');
  PERFORM pg_temp.su($q$WITH x AS (UPDATE erp.banking_setting SET card_acct = '1140' WHERE company_code = 'ZZ99' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.payment WHERE company_code = 'ZZ99' AND source = 'erp'), 'nothing was written by refused payments');

  -- ---------- Incoming payment: allocation maths, postings, balance ----------
  SELECT balance INTO bal0 FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011';
  r := pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09","memo":"A5 test","cash":100,"transfer":1000,"transfer_bank":"BNK-AED","transfer_ref":"TRX1",
        "cheques":[{"cheque_no":"CHQ-1","bank_name":"Test bank","due_date":"2026-11-09","amount":400},{"cheque_no":"PDC-2","bank_name":"Test bank","due_date":"2026-12-15","amount":300}],
        "card":50,"card_ref":"VISA-1"}',
       format('[{"obj_type":13,"doc_entry":%s,"amount":1050},{"obj_type":13,"doc_entry":%s,"amount":500}]', inv1, inv2)::jsonb);
  pin := (r->>'doc_entry')::integer; pin_no := r->>'doc_no'; pin_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND pin_no = 'RC-26-00001' AND pin >= 900000000, 'incoming payment posts at once (no approval for incoming)', left(r::text, 200));
  PERFORM pg_temp.check((SELECT total = 1850 AND on_account = 300 AND cash = 100 AND transfer = 1000 AND cheque = 700 AND card = 50 AND source = 'erp' AND trans_id = pin_trans
                           FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'I' AND doc_entry = pin),
                        'allocation maths: 1,850 received = 1,050 + 500 applied + 300 on account');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.payment_allocation WHERE company_code = 'ZZ99' AND direction = 'I' AND doc_entry = pin) = 2
                        AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = inv1) = 1050
                        AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = inv2) = 500
                        AND erp._bk_doc_open('ZZ99', 13, inv2) = 340, 'payment_allocation rows and invoices'' paid / open amounts (840 − 500 = 340)');
  PERFORM pg_temp.check(pg_temp.balanced(pin_trans) AND pg_temp.jl(pin_trans) = '1105 Dr 100, 1110 Dr 1000, 1130 Dr 700, 1140 Dr 50, 1200 Cr 1850 C0011',
                        'incoming posting balances: cash, bank, cheques received, card receipts / receivable (customer)', pg_temp.jl(pin_trans));
  PERFORM pg_temp.check((SELECT trans_type FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = pin_trans) = 24
                        AND EXISTS (SELECT 1 FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 24 AND doc_entry = pin AND trans_id = pin_trans),
                        'journal is trans_type 24 and recorded in document_posting');
  SELECT balance INTO bal1 FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0011';
  PERFORM pg_temp.check(bal1 = bal0 - 1850, 'customer balance down by the amount received', format('%s → %s', bal0, bal1));
  PERFORM pg_temp.check((SELECT count(*) FILTER (WHERE due_date > '2026-11-09') = 1 AND count(*) = 2 FROM erp.payment_cheque WHERE company_code = 'ZZ99' AND doc_entry = pin),
                        'two cheques kept, one post-dated');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'payment_post' AND object_ref = 'I/' || pin AND actor = fin::text), 'payment_post audit row');
  r := pg_temp.call(fin, $q$SELECT erp.payment_open_docs('ZZ99', 'I', 'C0011')$q$);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'docs') d WHERE (d->>'doc_entry')::integer = inv1), 'fully paid invoice no longer offered');
  r := pg_temp.call(bread, format($q$SELECT erp.payment_info('ZZ99', 'I', %s)$q$, pin));
  PERFORM pg_temp.check(r->>'doc_no' = pin_no AND jsonb_array_length(r->'allocations') = 2 AND (r->'cheques'->1->>'post_dated')::boolean AND r->>'cancel_block' = 'read_only',
                        'payment_info for a read-only user: allocations, post-dated cheque, cancel blocked (read only)', left(r::text, 160));

  -- ---------- Outgoing payment below the limit (posts) and above the limit (waits for approval) ----------
  r := pg_temp.pay(fin, 'O', '{"card_code":"S0005","doc_date":"2026-11-09","transfer":5000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000502,"amount":5000}]');
  p5 := (r->>'doc_entry')::integer; p5_trans := (r->>'trans_id')::integer; p5_no := r->>'doc_no';
  PERFORM pg_temp.check(r->>'state' = 'posted' AND p5_no = 'PV-26-00001', 'outgoing payment within the limit posts at once', left(r::text, 160));
  PERFORM pg_temp.check(pg_temp.balanced(p5_trans) AND pg_temp.jl(p5_trans) = '2100 Dr 5000 S0005, 1110 Cr 5000', 'outgoing posting balances: payable (supplier) / bank', pg_temp.jl(p5_trans));
  PERFORM pg_temp.check((SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'S0005') = -46800.37, 'supplier balance moves towards zero');

  r := pg_temp.pay(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":25000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":25000}]');
  PERFORM pg_temp.expect(r, 'This payment needs approval. Add a reason for the approver.', 'above the limit: a reason is required');
  r := pg_temp.chk(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":25000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":25000}]');
  PERFORM pg_temp.check(r->'checks'->0->>'message' = 'Payment 25,000.00 AED is above your payment limit of 20,000.00 AED.' AND r->'checks'->0->>'approver_position' = 'QA_FIN_MGR',
                        'live check names the limit and the approver', r->>'checks');
  r := pg_temp.pay(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":25000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":25000}]', 'Container balance due');
  d1 := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND d1 IS NOT NULL, 'outgoing payment above the limit waits for approval', left(r::text, 160));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.approval WHERE object = 'payment' AND object_ref = d1::text) = 1
                        AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = 990000501) = 0
                        AND NOT EXISTS (SELECT 1 FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'O' AND card_code = 'S0006' AND source = 'erp'),
                        'nothing paid or posted while waiting; one approval row');
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":6000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":6000}]'),
    'Line 1: 6,000.00 AED is more than the 5,000.00 AED still open on A/P invoice 990000501 (25,000.00 AED is waiting in other payment drafts).',
    'amount held by a waiting draft can''t be paid twice');
  r := pg_temp.call(fmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'payment' AND (w->>'doc_entry')::integer = d1),
                        'finance manager sees the payment in Waiting for me');
  PERFORM pg_temp.expect(pg_temp.decide(fin, d1, 'approved'), 'You can''t approve your own payment.', 'creator can''t approve');
  PERFORM pg_temp.expect(pg_temp.decide(owner, d1, 'approved'), 'This payment is waiting for approval from QA · finance manager. Your position can''t decide it.', 'wrong approver refused');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d1, 'rejected'), 'Add a note saying why you are rejecting this payment.', 'reject needs a note');
  PERFORM pg_temp.expect(pg_temp.decide(sales, d1, 'approved'), 'Your position does not include Banking. Ask the system admin if you need it.', 'sales user can''t decide');
  r := pg_temp.decide(fmgr, d1, 'approved');
  pbig := (r->>'doc_entry')::integer; pbig_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND pbig IS NOT NULL, 'approval posts the payment', left(r::text, 160));
  PERFORM pg_temp.check(pg_temp.balanced(pbig_trans) AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = 990000501) = 25000
                        AND (SELECT state = 'posted' AND doc_entry = pbig FROM erp.payment_draft WHERE draft_id = d1)
                        AND (SELECT draft_id FROM erp.payment_extra WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = pbig) = d1,
                        'approved payment: balanced journal, invoice paid, draft linked');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d1, 'approved'), 'This payment is not waiting for approval.', 'decided payment can''t be decided again');

  -- ---------- Bank-detail-change block: two-step approval (finance manager, then owner) ----------
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bp_bank_account_save('ZZ99', 'S0006', '{"bank_name":"New Bank","iban":"AE12 34"}')$q$),
    'The IBAN AE1234 is not valid. It starts with the country code and two check digits, e.g. AE07 0331 2345 6789 0123 456.', 'invalid IBAN refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bp_bank_account_save('ZZ99', 'S0006', '{"bank_name":"New Bank"}')$q$),
    'Enter the account number or the IBAN.', 'bank details need an account number or IBAN');
  PERFORM pg_temp.expect(pg_temp.call(bread, $q$SELECT erp.bp_bank_account_save('ZZ99', 'S0006', '{"bank_name":"New Bank","account_no":"1"}')$q$),
    'You have read-only access. Ask the system admin for full access to change bank details.', 'read-only user can''t change bank details');
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.bp_bank_account_save('ZZ99', 'S0006', '{"bank_name":"New Bank","account_no":"1"}')$q$),
    'Your position does not include Business Partners, Banking or Financials. Ask the system admin if you need it.', 'sales user can''t change bank details');
  r := pg_temp.call(fin, $q$SELECT erp.bp_bank_account_save('ZZ99', 'S0006', '{"bank_name":"New Bank","iban":"AE07 0331 2345 6789 0123 456","holder":"Sample Freight Forwarder"}')$q$);
  PERFORM pg_temp.check(r->>'change' = 'added' AND EXISTS (SELECT 1 FROM erp.bp_bank_change WHERE company_code = 'ZZ99' AND card_code = 'S0006' AND change_kind = 'added'),
                        'new bank account logged as a change', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bp_bank_account_save('ZZ99', 'S0006', '{"bp_bank_id":%s,"bank_name":"New Bank","iban":"AE070331234567890123456","holder":"Sample Freight Forwarder"}')$q$, r->>'bp_bank_id')),
    'Nothing changed.', 'unchanged bank details refused');
  r := pg_temp.chk(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":1000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":1000}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 2 AND r->'checks'->0->>'rule_code' = 'bank_change'
                        AND r->'checks'->0->>'message' = format('Sample Freight Forwarder''s bank details changed on %s, within the last 30 days. QA · finance manager and QA · owner (business) must both approve this payment.', v_today),
                        'changed bank account: a small payment needs two approvals', r->>'checks');
  r := pg_temp.pay(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":1000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":1000}]', 'Confirmed new account by phone');
  d2 := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (SELECT string_agg(step || ':' || approver_position, ',' ORDER BY step) FROM erp.approval WHERE object = 'payment' AND object_ref = d2::text) = '1:QA_FIN_MGR,2:QA_OWNER',
                        'bank-change payment waits for step 1 finance manager, step 2 owner');
  PERFORM pg_temp.expect(pg_temp.decide(owner, d2, 'approved'), 'This payment is waiting for approval from QA · finance manager. Your position can''t decide it.', 'owner can''t approve before the finance manager');
  r := pg_temp.decide(fmgr, d2, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'after the finance manager the payment still waits (owner step)', left(r::text, 100));
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d2, 'approved'), 'This payment is waiting for approval from QA · owner (business). Your position can''t decide it.', 'finance manager can''t approve the owner step');
  r := pg_temp.call(owner, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') w WHERE w->>'kind' = 'payment' AND (w->>'doc_entry')::integer = d2), 'owner sees it in Waiting for me');
  r := pg_temp.decide(owner, d2, 'approved');
  pbc := (r->>'doc_entry')::integer; pbc_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND pg_temp.balanced(pbc_trans), 'owner approval (without Financials write access) posts the payment', left(r::text, 120));
  PERFORM pg_temp.su($q$WITH x AS (UPDATE erp.bp_bank_change SET changed_at = now() - interval '31 days' WHERE company_code = 'ZZ99' AND card_code = 'S0006' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  r := pg_temp.chk(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":1000,"transfer_bank":"BNK-AED"}', '[{"obj_type":18,"doc_entry":990000501,"amount":1000}]');
  PERFORM pg_temp.check(jsonb_array_length(r->'errors') = 0 AND jsonb_array_length(r->'checks') = 0, 'change older than 30 days: no approval needed', left(r::text, 160));
  PERFORM pg_temp.su($q$WITH x AS (INSERT INTO erp.bp_bank_account (company_code, card_code, bank_name, account_no, source) VALUES ('ZZ99', 'S0004', 'SAP bank', '1', 'sap') RETURNING bp_bank_id) SELECT to_jsonb(max(bp_bank_id)) FROM x$q$);
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bp_bank_account_save('ZZ99', 'S0004', '{"bp_bank_id":%s,"bank_name":"Other","account_no":"2"}')$q$,
                                                 (SELECT max(bp_bank_id) FROM erp.bp_bank_account WHERE card_code = 'S0004'))),
    'These bank details came from SAP Business One and are read-only during the soft switch.', 'SAP bank details read-only');

  -- ---------- Rejected / cancelled drafts ----------
  r := pg_temp.pay(fin, 'O', '{"card_code":"S0006","doc_date":"2026-11-09","transfer":21000,"transfer_bank":"BNK-AED"}', '[]', 'Advance on account');
  d3 := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'payment on account above the limit waits', left(r::text, 100));
  r := pg_temp.decide(fmgr, d3, 'rejected', 'No advance agreed');
  PERFORM pg_temp.check(r->>'state' = 'rejected', 'finance manager rejects with a note');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_draft_cancel('ZZ99', %s, '')$q$, d3)), 'Add a note saying why the payment is cancelled.', 'cancel needs a note');
  PERFORM pg_temp.expect(pg_temp.call(fmgr, format($q$SELECT erp.payment_draft_cancel('ZZ99', %s, 'x')$q$, d3)), 'Only the person who entered this payment can cancel it.', 'only the creator cancels');
  r := pg_temp.call(fin, format($q$SELECT erp.payment_draft_cancel('ZZ99', %s, 'Entered by mistake')$q$, d3));
  PERFORM pg_temp.check(r->>'state' = 'cancelled', 'creator cancels the rejected draft');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_draft_cancel('ZZ99', %s, 'again')$q$, d3)), 'This payment draft is already cancelled.', 'cancelled draft can''t be cancelled again');
  r := pg_temp.call(fin, format($q$SELECT erp.payment_draft_info('ZZ99', %s)$q$, d2));
  PERFORM pg_temp.check(r->>'state' = 'posted' AND jsonb_array_length(r->'approvals') = 2 AND jsonb_array_length(r->'activity') >= 3 AND r->>'doc_no' IS NOT NULL,
                        'payment_draft_info: approvals, activity, posted number', left(r::text, 160));

  -- ---------- Deposits ----------
  r := pg_temp.call(fin, $q$SELECT erp.deposit_setup('ZZ99')$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'cheques') = 2 AND (r->>'cash_on_hand')::numeric = 100, 'deposit form: two cheques waiting, 100 cash on hand', left(r::text, 160));
  SELECT cheque_id INTO chq1 FROM erp.payment_cheque WHERE company_code = 'ZZ99' AND doc_entry = pin AND cheque_no = 'CHQ-1';
  SELECT cheque_id INTO chq2 FROM erp.payment_cheque WHERE company_code = 'ZZ99' AND doc_entry = pin AND cheque_no = 'PDC-2';
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"BNK-AED"}', '[%s]')$q$, chq2)),
    'Cheque PDC-2 is post-dated to 15 Dec 2026. Deposit it on or after that date.', 'post-dated cheque refused before its date');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"BNK-AED","cash_amount":101}', '[]')$q$),
    'Only 100.00 AED cash is on hand. Lower the cash amount.', 'more cash than on hand refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09"}', '[]')$q$), 'Choose the bank account to deposit into.', 'deposit needs a bank account');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"CASH"}', '[]')$q$),
    'Bank account CASH does not exist or is inactive in company ZZ99.', 'cash account is not a deposit target');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"BNK-AED"}', '[]')$q$),
    'Choose cheques or enter a cash amount to deposit.', 'empty deposit refused');
  PERFORM pg_temp.expect(pg_temp.call(bread, $q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"BNK-AED"}', '[]')$q$),
    'You have read-only access to Banking. Ask the system admin for full access to record deposits.', 'read-only user can''t deposit');
  r := pg_temp.call(fin, format($q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"BNK-AED","cash_amount":100}', '[%s]')$q$, chq1));
  dep := (r->>'deposit_id')::integer; dep_no := r->>'doc_no'; dep_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(dep_no = 'DP-26-00001' AND (r->>'total')::numeric = 500 AND pg_temp.balanced(dep_trans)
                        AND pg_temp.jl(dep_trans) = '1110 Dr 500, 1130 Cr 400, 1105 Cr 100', 'deposit posts bank / cheques received / cash', pg_temp.jl(dep_trans));
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.deposit_create('ZZ99', '{"deposit_date":"2026-11-09","bank_code":"BNK-AED"}', '[%s]')$q$, chq1)),
    format('Cheque CHQ-1 is already in deposit %s.', dep_no), 'cheque can''t be deposited twice');
  PERFORM pg_temp.check(erp._bk_gl_balance('ZZ99', '1105') = 0 AND erp._bk_gl_balance('ZZ99', '1130') = 300, 'cash 0 and 300 in cheques left after the deposit');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'I', %s, '2026-11-09', 'test')$q$, pin)),
    format('Cheque CHQ-1 is already in deposit %s, so the payment can''t be cancelled.', dep_no), 'payment with a deposited cheque can''t be cancelled');

  -- ---------- Cancel a payment ----------
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'O', %s, '2026-11-09', '')$q$, p5)), 'Add a reason for the cancellation.', 'cancel needs a reason');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'O', %s, '2026-11-01', 'x')$q$, p5)),
    'The cancellation date can''t be before the payment date (09 Nov 2026).', 'cancel date before the payment refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.journal_reverse('ZZ99', %s, '2026-11-09', 'x')$q$, p5_trans)),
    format('Journal %s was posted by a document. Cancel the document instead.', p5_trans), 'A3 journal reversal refuses a payment journal');
  r := pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'O', %s, '2026-11-09', 'Wrong supplier invoice')$q$, p5));
  v_je := (r->>'trans_id')::integer;
  PERFORM pg_temp.check((r->>'cancelled')::boolean AND (SELECT cancelled FROM erp.payment WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = p5)
                        AND (SELECT reversal_of FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = v_je) = p5_trans AND pg_temp.balanced(v_je)
                        AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = 990000502) = 0
                        AND (SELECT balance FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'S0005') = -51800.37,
                        'cancel: reversal journal, invoice open again, supplier balance back', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'O', %s, '2026-11-09', 'x')$q$, p5)), format('Payment %s is already cancelled.', p5_no), 'cancelled payment can''t be cancelled again');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.payment_cancel('ZZ99', 'O', 509, '2026-11-09', 'x')$q$), 'Payment 300009 is sample test data and can''t be cancelled.', 'sample payment can''t be cancelled');

  -- ---------- Bank statement import and matching ----------
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'bad.csv', '[{"date":"31/12/2026","amount":"5"}]')$q$),
    'Row 1: the date "31/12/2026" is not a valid date. Check the date format chosen for the file.', 'bad date refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'bad.csv', '[{"date":"2026-11-09","amount":"abc"}]')$q$),
    'Row 1: the amount "abc" is not a number.', 'bad amount refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'empty.csv', '[]')$q$), 'The file has no statement lines.', 'empty file refused');
  PERFORM pg_temp.expect(pg_temp.call(bread, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'x.csv', '[{"date":"2026-11-09","amount":"5"}]')$q$),
    'You have read-only access to Banking. Ask the system admin for full access to import bank statements.', 'read-only user can''t import');
  -- A SAP journal on the bank account that SAP already reconciled (match_no) is never offered.
  PERFORM pg_temp.su($q$WITH je AS (INSERT INTO erp.journal_entry (company_code, trans_id, number, ref_date, memo, trans_type, source, total_local)
       VALUES ('ZZ99', 777601, 777601, '2026-11-12', 'SAP reconciled receipt', 24, 'sap', 777.77) RETURNING company_code, trans_id)
     , jl AS (INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, debit, credit, match_no, ref_date)
       SELECT company_code, trans_id, v.l, v.a, v.d, v.c, v.m, '2026-11-12' FROM je, (VALUES (0, '1110', 777.77, 0, 55), (1, '4100', 0, 777.77, NULL)) v(l, a, d, c, m) RETURNING 1)
     SELECT to_jsonb(count(*)) FROM jl$q$);
  r := pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'nov.csv', '[
        {"date":"2026-11-09","description":"Transfer from Sunrise","reference":"TRX1","amount":"1000"},
        {"date":"2026-11-10","description":"Cheque and cash deposit","reference":"","amount":"500"},
        {"date":"2026-11-09","description":"Payment Sample Freight","reference":"","amount":"-25000"},
        {"date":"2026-11-12","description":"Unknown credit","reference":"","amount":"777.77"},
        {"date":"2026-11-09","description":"Cancelled carton payment","reference":"","amount":"-5000"},
        {"date":"2026-11-20","description":"Bank fee","reference":"F","amount":"-10"},
        {"date":"2026-11-20","description":"Bank fee","reference":"F","amount":"-10"}]')$q$);
  stmt := (r->>'statement_id')::integer;
  PERFORM pg_temp.check((r->>'imported')::integer = 7 AND (r->>'skipped')::integer = 0, 'statement imported: 7 lines (two identical fee lines both kept)', left(r::text, 120));
  r := pg_temp.call(fin, $q$SELECT erp.bank_statement_import('ZZ99', 'BNK-AED', 'nov.csv', '[
        {"date":"2026-11-09","description":"Transfer from Sunrise","reference":"TRX1","amount":"1000"},
        {"date":"2026-11-10","description":"Cheque and cash deposit","reference":"","amount":"500"},
        {"date":"2026-11-09","description":"Payment Sample Freight","reference":"","amount":"-25000"},
        {"date":"2026-11-12","description":"Unknown credit","reference":"","amount":"777.77"},
        {"date":"2026-11-09","description":"Cancelled carton payment","reference":"","amount":"-5000"},
        {"date":"2026-11-20","description":"Bank fee","reference":"F","amount":"-10"},
        {"date":"2026-11-20","description":"Bank fee","reference":"F","amount":"-10"}]')$q$);
  PERFORM pg_temp.check(r->>'statement_id' IS NULL AND (r->>'imported')::integer = 0 AND (r->>'skipped')::integer = 7
                        AND (SELECT count(*) FROM erp.bank_statement_line WHERE company_code = 'ZZ99') = 7, 'same file again: nothing imported, 7 skipped', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(bread, format($q$SELECT erp.bank_statement_auto_match('ZZ99', %s)$q$, stmt)),
    'You have read-only access to Banking. Ask the system admin for full access to reconcile bank statements.', 'read-only user can''t match');
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_auto_match('ZZ99', %s)$q$, stmt));
  PERFORM pg_temp.check((r->>'matched')::integer = 3 AND (r->>'unmatched')::integer = 4, 'auto-match: transfer, deposit and supplier payment matched; 4 stay unmatched', left(r::text, 120));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.bank_match m JOIN erp.bank_statement_line l ON l.line_id = m.statement_line_id
                          WHERE l.statement_id = stmt AND ((l.amount = 1000 AND m.trans_id = pin_trans) OR (l.amount = 500 AND m.trans_id = dep_trans)
                                                           OR (l.amount = -25000 AND m.trans_id = pbig_trans))) = 3
                        AND (SELECT min(match_no) FROM erp.bank_match) >= 900000000, 'matches point at the payment and deposit journals, ERP match numbers from 900000000');
  r2 := pg_temp.call(fin, format($q$SELECT erp.bank_statement_auto_match('ZZ99', %s)$q$, stmt));
  PERFORM pg_temp.check((r2->>'matched')::integer = 0 AND (r2->>'unmatched')::integer = 4 AND (SELECT count(*) FROM erp.bank_match) = 3,
                        'auto-match again: nothing changes (idempotent)', left(r2::text, 120));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id IN (pin_trans, dep_trans, pbig_trans) AND match_no IS NOT NULL),
                        'posted journal lines are not changed (match_no untouched)');
  SELECT line_id INTO v_line FROM erp.bank_statement_line WHERE statement_id = stmt AND amount = 777.77;
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_candidates('ZZ99', %s)$q$, v_line));
  PERFORM pg_temp.check(jsonb_array_length(r) = 0, 'SAP-reconciled journal line (match_no) is not offered', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bank_statement_match('ZZ99', %s, 777601, 0)$q$, v_line)),
    'Journal line 777601/0 is already reconciled in SAP Business One (match 55).', 'SAP-reconciled line refused');
  SELECT trans_id, jl_line_id INTO v_t, v_l FROM erp.bank_match WHERE trans_id = pin_trans;
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bank_statement_match('ZZ99', %s, %s, %s)$q$, v_line, v_t, v_l)),
    format('Journal line %s/%s is already matched to another statement line.', v_t, v_l), 'journal line matched twice refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bank_statement_match('ZZ99', %s, %s, 1)$q$, v_line, p5_trans)),
    'The journal line is -5,000.00 AED but the statement line is 777.77 AED. Only equal amounts can be matched.', 'different amounts refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bank_statement_match('ZZ99', %s, %s, 4)$q$, v_line, pin_trans)),
    format('Journal line %s/4 is not on bank account Main bank account AED (G/L 1110).', pin_trans), 'line on another account refused');
  -- A bank fee posted as a manual journal, matched by hand.
  r := pg_temp.call(fin, $q$SELECT erp.journal_draft_save('ZZ99', NULL, '{"ref_date":"2026-11-20","memo":"Bank fee"}', '[{"acct_code":"6800","debit":10},{"acct_code":"1110","credit":10}]')$q$);
  r := pg_temp.call(fin, format($q$SELECT erp.journal_submit('ZZ99', %s)$q$, r->>'draft_id'));
  v_je := (r->>'trans_id')::integer;
  SELECT min(line_id), max(line_id) INTO v_fee, v_fee2 FROM erp.bank_statement_line WHERE statement_id = stmt AND amount = -10;
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_candidates('ZZ99', %s)$q$, v_fee));
  PERFORM pg_temp.check((r->0->>'trans_id')::integer = v_je AND (r->0->>'line_id')::integer = 1, 'candidates offer the fee journal line', left(r::text, 160));
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_match('ZZ99', %s, %s, 1)$q$, v_fee, v_je));
  PERFORM pg_temp.check((r->>'match_no')::integer >= 900000000 AND (SELECT how FROM erp.bank_match WHERE statement_line_id = v_fee) = 'manual', 'manual match', left(r::text, 100));
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bank_statement_match('ZZ99', %s, %s, 1)$q$, v_fee, v_je)),
    'This statement line is already matched. Unmatch it first.', 'matched line can''t be matched again');
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_unmatch('ZZ99', %s)$q$, v_fee));
  PERFORM pg_temp.check((r->>'unmatched')::boolean AND NOT EXISTS (SELECT 1 FROM erp.bank_match WHERE statement_line_id = v_fee), 'unmatch');
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.bank_statement_unmatch('ZZ99', %s)$q$, v_fee)), 'This statement line is not matched.', 'unmatch an unmatched line refused');
  r := pg_temp.call(fin, format($q$SELECT erp.bank_statement_auto_match('ZZ99', %s)$q$, stmt));
  PERFORM pg_temp.check((r->>'matched')::integer = 0, 'two identical fee lines and one journal line: ambiguous, so auto-match leaves them', left(r::text, 80));
  r := pg_temp.call(bread, format($q$SELECT erp.bank_statement_info('ZZ99', %s)$q$, stmt));
  PERFORM pg_temp.check(jsonb_array_length(r->'lines') = 7 AND (SELECT count(*) FROM jsonb_array_elements(r->'lines') l WHERE l->'match' IS NOT NULL AND l->'match' <> 'null') = 3
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') l WHERE l->'match'->'source'->>'doc_no' = pin_no),
                        'statement page: unmatched lines stay listed; a match shows the payment number', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(fin, format($q$SELECT erp.payment_cancel('ZZ99', 'O', %s, '2026-11-09', 'x')$q$, pbig)),
    format('Payment %s is matched to a bank statement line. Unmatch it first.', (SELECT doc_no FROM erp.payment_extra WHERE company_code = 'ZZ99' AND direction = 'O' AND doc_entry = pbig)),
    'matched payment can''t be cancelled');

  -- ---------- Cash position ----------
  r := pg_temp.call(bread, $q$SELECT erp.cash_position('ZZ99')$q$);
  PERFORM pg_temp.check((SELECT (a->>'balance')::numeric FROM jsonb_array_elements(r->'accounts') a WHERE a->>'bank_code' = 'BNK-AED')
                          = 748091.27 + 1000 - 5000 - 25000 - 1000 + 500 + 5000 - 10
                        AND (SELECT (a->>'unmatched')::integer FROM jsonb_array_elements(r->'accounts') a WHERE a->>'bank_code' = 'BNK-AED') = 4
                        AND (r->'cheques'->>'count')::integer = 1 AND (r->'cheques'->>'post_dated_count')::integer = 1 AND (r->'cheques'->>'amount')::numeric = 300
                        AND (r->'pending_out'->>'count')::integer = 0,
                        'cash position: bank balance = SAP balance + Super ERP postings; 1 post-dated cheque; 4 unmatched lines', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.cash_position('ZZ99')$q$), 'Your position does not include Banking. Ask the system admin if you need it.', 'cash position needs Banking');

  -- ---------- Setup ----------
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_account_save('ZZ99', '{"bank_code":"BNK-X","name":"X","acct_code":"1100"}')$q$),
    'Account 1100 · Cash and bank is a title account. Choose a postable account.', 'title account refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_account_save('ZZ99', '{"bank_code":"BNK-X","name":"X","acct_code":"1200"}')$q$),
    'Account 1200 · Accounts receivable is a control account for customers or suppliers. Choose a bank, cash or clearing account.', 'control account refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.bank_account_save('ZZ99', '{"bank_code":"BNK-X","name":"X","acct_code":"1110"}')$q$),
    'Account 1110 is already used by bank account BNK-AED.', 'one house account per G/L account');
  r := pg_temp.call(fin, $q$SELECT erp.bank_account_save('ZZ99', '{"bank_code":"bnk-usd","name":"USD bank account","acct_code":"1120","currency":"usd"}')$q$);
  PERFORM pg_temp.check(r->>'bank_code' = 'BNK-USD' AND r->>'currency' = 'USD' AND r->>'source' = 'erp', 'house bank account added', left(r::text, 120));
  PERFORM pg_temp.expect(pg_temp.call(fin, $q$SELECT erp.banking_setting_set('ZZ99', '{"cash_acct":"1105","cheque_acct":"1130","card_acct":"1140","match_days":99}')$q$),
    'The matching window must be a whole number of days between 0 and 60.', 'matching window out of range refused');
  r := pg_temp.call(fin, $q$SELECT erp.banking_setting_set('ZZ99', '{"cash_acct":"1105","cheque_acct":"1130","card_acct":"1140","match_days":5}')$q$);
  PERFORM pg_temp.check((r->>'match_days')::integer = 5 AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'banking_setting_set'), 'settings saved and logged');
  PERFORM pg_temp.expect(pg_temp.call(bread, $q$SELECT erp.banking_setting_set('ZZ99', '{}')$q$),
    'You have read-only access to Banking. Ask the system admin for full access to change the banking setup.', 'read-only user can''t change setup');
  PERFORM pg_temp.su($q$WITH x AS (DELETE FROM erp.number_series WHERE company_code = 'ZZ99' AND obj_type = 24 RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.expect(pg_temp.pay(fin, 'I', '{"card_code":"C0011","doc_date":"2026-11-09","cash":10}', '[]'),
    'Incoming payment numbering is not set up for company ZZ99. Ask the system admin to add it (Administration › Document Numbering).', 'missing numbering named');

  -- ---------- Safety ----------
  r := pg_temp.call(fin, $q$WITH x AS (INSERT INTO erp.bank_account (company_code, bank_code, name, acct_code) VALUES ('ZZ99', 'HACK', 'x', '1600') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct insert into bank_account', r::text);
  r := pg_temp.call(fin, $q$WITH x AS (UPDATE erp.payment_draft SET state = 'posted' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct update of payment drafts', r::text);
  r := pg_temp.call(fin, $q$WITH x AS (DELETE FROM erp.bank_match RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct delete of matches', r::text);
  r := pg_temp.call(fin, $q$SELECT erp._pay_post('ZZ99', 'I', '{}', NULL, NULL)$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'internal posting function not callable', r::text);
  PERFORM pg_temp.check((SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = 777501) = 0
                        AND (SELECT paid FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = 59) = 0, 'SAP and sample documents untouched');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_entry j WHERE j.company_code = 'ZZ99' AND j.trans_type IN (24, 25, 46) AND j.source = 'erp'
                                      AND NOT pg_temp.balanced(j.trans_id)), 'every banking journal balances');
  r := pg_temp.call(sales, $q$SELECT to_jsonb(count(*)) FROM erp.payment_extra$q$);
  PERFORM pg_temp.check(r::text = '0', 'sales-only user reads no Super ERP payment rows (RLS)', r::text);
  r := pg_temp.call(bread, $q$SELECT to_jsonb(count(*)) FROM erp.payment_list WHERE source = 'erp'$q$);
  PERFORM pg_temp.check((r::text)::integer = 4, 'banking read-only user lists the 4 Super ERP payments', r::text);
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a5_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a5_result;
ROLLBACK;
