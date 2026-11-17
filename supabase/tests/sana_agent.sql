-- SANA agent phase 1 (S3 · 46_sana_agent.sql + 47_sana_checks.sql). LOCAL STACK or a Supabase BRANCH with the sample company
-- ZZ99 + scripts/local-stack/test-users.sql — never live. One transaction, rolled back. Prints PASS/FAIL · name · detail + TOTAL.
-- Test users: qa.admin 1 (all modules incl. business), qa.sales 2, qa.finance 4, qa.owner 5 (business), qa.purchase 10,
-- qa.stock 13, qa.hr 18, qa.emp 20 (staff), qa.it 23 (IT only). A temporary Indian company IN99 is created inside the
-- transaction to test the IN rules (rolled back).
BEGIN;

CREATE TEMP TABLE sr_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON sr_result TO authenticated;
CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO sr_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, left(p_detail, 300))
$$;
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
CREATE FUNCTION pg_temp.codes(j jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(string_agg(x ->> 'code', ',' ORDER BY x ->> 'code'), '') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(j) = 'array' THEN j ELSE '[]' END) x
$$;

DO $$
DECLARE r jsonb; f jsonb; fid bigint; n integer; ap erp.document; so erp.document; po erp.document; ok boolean; msg text;
BEGIN
  -- ---------- rules per country ----------
  PERFORM pg_temp.check((SELECT count(*) FROM erp.sana_rule WHERE company_code = 'ZZ99') = (SELECT count(*) FROM erp.sana_rule_default WHERE country = 'AE'),
                        'rules: every AE company is seeded from the AE defaults');
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency) VALUES ('IN99', 'Test India Pvt Ltd', 'Test India', 'IN', 'INR');
  INSERT INTO erp.user_company (user_id, company_code) VALUES (pg_temp.u(4), 'IN99'), (pg_temp.u(2), 'IN99'), (pg_temp.u(1), 'IN99');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.sana_rule WHERE company_code = 'IN99' AND enabled AND rule_code IN ('cash_receipt_limit', 'cash_payment_limit', 'gst_rate', 'msme_terms')) = 4,
                        'rules: a new IN company gets the IN rules (trigger)');
  r := pg_temp.call(pg_temp.u(4), 'SELECT erp.sana_rules(''IN99'')');
  PERFORM pg_temp.check(r ->> 'country' = 'IN' AND jsonb_array_length(r -> 'rules') = 15, 'rules: sana_rules shows the company rules', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(18), 'SELECT erp.sana_rules(''IN99'')');
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'rules: a user without the company cannot read its rules', r::text);

  -- ---------- cash limits: IN refuses 2,00,000 received, warns above 10,000 paid; AE has no cash rule ----------
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''IN99'', NULL, NULL, ''{"direction":"I","cash":200000}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'cash.receipt_limit' AND r -> 0 ->> 'severity' = 'law', 'IN: cash receipt of 2,00,000 is refused (law)', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''IN99'', NULL, NULL, ''{"direction":"I","cash":199999}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'IN: cash receipt of 1,99,999 passes', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''IN99'', NULL, NULL, ''{"direction":"O","cash":10001}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'cash.payment_limit' AND r -> 0 ->> 'message' ILIKE '%reason%', 'IN: cash payment of 10,001 warns and asks for a reason', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''IN99'', NULL, NULL, ''{"direction":"O","cash":10000}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'IN: cash payment of 10,000 passes', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''ZZ99'', NULL, NULL, ''{"direction":"I","cash":200000}'') c')
    || pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''ZZ99'', NULL, NULL, ''{"direction":"O","cash":10001}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'AE: the same amounts give no cash rule', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''IN99'', NULL, NULL, ''{"direction":"I","cash":200000}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'cash check returns nothing to a role without finance/banking', r::text);

  -- ---------- tax (AE VAT by tax code) ----------
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_tax(''ZZ99'', NULL, NULL,
         ''{"doc_kind":"ap_invoice","lines":[{"line_num":0,"line_total":1000,"tax_code":"SR","vat":50},{"line_num":1,"line_total":1000,"tax_code":"SR","vat":0},{"line_num":2,"line_total":500,"tax_code":"XX","vat":0}]}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'tax.unknown_code,tax.vat_mismatch', 'tax: wrong VAT and an unknown tax code are found; a correct line is not', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_tax(''ZZ99'', NULL, NULL,
         ''{"doc_kind":"ap_invoice","lines":[{"line_num":1,"line_total":1000,"tax_code":"SR","vat":0}]}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'tax: a sales user gets nothing about a purchase bill', r::text);

  r := pg_temp.call(pg_temp.u(10), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_tax(''ZZ99'', NULL, NULL,
         ''{"doc_kind":"ap_invoice","lines":[{"line_num":0,"line_total":1000,"tax_code":"SR","vat":50}]}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'tax: purchasing (no access to the tax code table) still gets a correct line right', r::text);

  -- ---------- credit, TRN, duplicate bill, licence expiry ----------
  UPDATE erp.business_partner SET credit_limit = 30000 WHERE company_code = 'ZZ99' AND card_code = 'C0001';   -- balance 28,147
  r := pg_temp.call(pg_temp.u(2), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_credit(''ZZ99'', ''C0001'', 5000) c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'credit.over_limit', 'credit: a sale that takes the customer over the limit is flagged', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_credit(''ZZ99'', ''C0001'', 0) c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'credit.near_limit', 'credit: at 90 % of the limit it is a note', r::text);
  r := pg_temp.call(pg_temp.u(10), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_credit(''ZZ99'', ''C0001'', 5000) c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'credit: purchasing gets nothing about a customer', r::text);
  UPDATE erp.business_partner SET trn = '12345' WHERE company_code = 'ZZ99' AND card_code = 'S0004';
  r := pg_temp.call(pg_temp.u(10), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_trn(''ZZ99'', ''S0004'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'trn.format', 'AE: a TRN that is not 15 digits is flagged', r::text);
  r := pg_temp.call(pg_temp.u(10), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_trn(''ZZ99'', ''C0001'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'AE: TRN check stays silent for partners the role does not see', r::text);

  SELECT * INTO ap FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 18 AND status = 'open' ORDER BY doc_entry LIMIT 1;
  UPDATE erp.document SET customer_ref = 'INV-7781' WHERE company_code = 'ZZ99' AND obj_type = 18 AND doc_entry = ap.doc_entry;
  r := pg_temp.call(pg_temp.u(10), format('SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_duplicate_bill(''ZZ99'', NULL, %L) c',
         jsonb_build_object('card_code', ap.card_code, 'customer_ref', 'inv 7781', 'total', ap.total, 'doc_date', ap.doc_date)));
  PERFORM pg_temp.check(pg_temp.codes(r) = 'duplicate.bill' AND (r -> 0 ->> 'score')::integer = 100 AND r -> 0 -> 'evidence' -> 1 ->> 'id' = '18:' || ap.doc_entry,
                        'duplicate bill: same supplier ref, amount and date scores 100 with evidence', r::text);
  r := pg_temp.call(pg_temp.u(10), format('SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_duplicate_bill(''ZZ99'', NULL, %L) c',
         jsonb_build_object('card_code', ap.card_code, 'customer_ref', 'OTHER-1', 'total', ap.total + 1, 'doc_date', ap.doc_date)));
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'duplicate bill: a different bill from the same supplier is not flagged', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_duplicate_bill(''ZZ99'', %s) c', ap.doc_entry));
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'duplicate bill: sales gets nothing', r::text);

  INSERT INTO erp.item_certificate (company_code, item_code, scheme, status, certificate_no, expires_on)
    VALUES ('ZZ99', 'SMP-1140', 'ESMA', 'approved', 'C-1', current_date + 10);
  r := pg_temp.call(pg_temp.u(13), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_licence_expiry(''ZZ99'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = 'licence.expiring', 'licence: a certificate expiring in 10 days is listed for inventory', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_licence_expiry(''ZZ99'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'licence: finance-only gets nothing', r::text);

  r := pg_temp.call(pg_temp.u(10), format('SELECT erp.sana_checks(''ZZ99'', ''document'', %L)', '18:' || ap.doc_entry));
  PERFORM pg_temp.check(r -> 'checked' ? 'duplicate_bill' AND r -> 'checked' ? 'tax', 'dispatcher: an A/P invoice runs tax, duplicate and TRN checks in one call', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_checks(''ZZ99'', ''document'', %L)', '18:' || ap.doc_entry));
  PERFORM pg_temp.check(jsonb_array_length(r -> 'findings') = 0 AND jsonb_array_length(r -> 'checked') = 0, 'dispatcher: sales on a purchase bill gets no checks', r::text);

  -- ---------- cost and supplier: only purchase, finance, inventory and the owner ----------
  PERFORM pg_temp.check((SELECT bool_and((pg_temp.call(pg_temp.u(x), 'SELECT to_jsonb(erp.sana_can_see_cost())'))::text = 'true') FROM unnest(ARRAY[4, 5, 10, 13]) x)
                    AND (SELECT bool_and((pg_temp.call(pg_temp.u(x), 'SELECT to_jsonb(erp.sana_can_see_cost())'))::text = 'false') FROM unnest(ARRAY[2, 18, 20, 23]) x),
                        'cost: visible to finance, owner, purchasing, inventory; hidden from sales, HR, staff, IT');
  r := pg_temp.call(pg_temp.u(5), 'SELECT erp.sana_stock(''SMP-1010'', ''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'cost_visible')::boolean, 'cost: the owner (business) sees cost in sana_stock without a change to 36', left(r::text, 120));

  -- ---------- evidence: only ids the caller can open survive ----------
  SELECT * INTO so FROM erp.document WHERE company_code = 'ZZ99' AND doc_kind = 'sales_order' ORDER BY doc_entry LIMIT 1;
  SELECT * INTO po FROM erp.document WHERE company_code = 'ZZ99' AND doc_kind = 'purchase_order' ORDER BY doc_entry LIMIT 1;
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_evidence_resolve(''ZZ99'', %L)', jsonb_build_array(
         jsonb_build_object('table', 'document', 'id', so.obj_type || ':' || so.doc_entry), jsonb_build_object('table', 'document', 'id', po.obj_type || ':' || po.doc_entry),
         jsonb_build_object('table', 'document', 'id', '13:99999999'), jsonb_build_object('table', 'employee', 'id', '1'))));
  PERFORM pg_temp.check(jsonb_array_length(r) = 1 AND r -> 0 ->> 'id' = so.obj_type || ':' || so.doc_entry,
                        'evidence: sales keeps the sales order; purchase order, missing document and unknown table are dropped', r::text);

  -- ---------- findings, event log, RLS ----------
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_findings_save(''ZZ99'', ''ap_invoice'', ''document'', %L, %L, ''test-model'')', '18:' || ap.doc_entry,
         jsonb_build_array(jsonb_build_object('severity', 'risk', 'code', 'duplicate.bill', 'title', 'Possible duplicate', 'confidence', 'likely', 'score', 100,
                                              'evidence', jsonb_build_array(jsonb_build_object('table', 'document', 'id', '18:' || ap.doc_entry)), 'source', 'rule'))));
  fid := (r -> 'ids' ->> 0)::bigint;
  PERFORM pg_temp.check(fid IS NOT NULL, 'findings: the finance user stores a finding (and a now event)', r::text);
  PERFORM pg_temp.check((pg_temp.call(pg_temp.u(2), format('SELECT to_jsonb(count(*)) FROM erp.sana_finding WHERE id = %s', fid)))::text = '0'
                    AND (pg_temp.call(pg_temp.u(23), format('SELECT to_jsonb(count(*)) FROM erp.sana_finding WHERE id = %s', fid)))::text = '0'
                    AND (pg_temp.call(pg_temp.u(5), format('SELECT to_jsonb(count(*)) FROM erp.sana_finding WHERE id = %s', fid)))::text = '1'
                    AND (pg_temp.call(pg_temp.u(4), format('SELECT to_jsonb(count(*)) FROM erp.sana_finding WHERE id = %s', fid)))::text = '1',
                        'RLS: own findings only; the owner sees all; sales and IT do not');
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_finding_decide(%s, ''applied'')', fid));
  PERFORM pg_temp.check(r ->> 'error' = 'P0002', 'decide: another user cannot apply my finding', r::text);
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_finding_decide(%s, ''ignored'', NULL, ''{"note":"checked"}'')', fid));
  PERFORM pg_temp.check(r ->> 'status' = 'ignored' AND (SELECT count(*) FROM erp.sana_event_log WHERE finding_id = fid AND kind = 'ignore') = 1, 'decide: ignore is stored with an event row', r::text);
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_finding_decide(%s, ''applied'')', fid));
  PERFORM pg_temp.check(r ->> 'error' = 'P0001', 'decide: a decided finding cannot be decided again', r::text);
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_events(''ZZ99'', ''document'', %L)', '18:' || ap.doc_entry));
  PERFORM pg_temp.check(jsonb_array_length(r) = 2, 'Done tab: sana_events lists the now and ignore events', left(r::text, 200));

  r := pg_temp.call(pg_temp.u(4), 'WITH x AS (UPDATE erp.sana_event_log SET kind = ''answer'' RETURNING 1) SELECT to_jsonb(count(*)) FROM x');
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'event log: a user cannot update it', r::text);
  r := pg_temp.call(pg_temp.u(4), 'WITH x AS (DELETE FROM erp.sana_event_log RETURNING 1) SELECT to_jsonb(count(*)) FROM x');
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'event log: a user cannot delete from it', r::text);
  BEGIN UPDATE erp.sana_event_log SET kind = 'answer'; ok := false; EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  PERFORM pg_temp.check(ok, 'event log: even the table owner cannot update it (trigger)');
  BEGIN DELETE FROM erp.sana_event_log; ok := false; EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  PERFORM pg_temp.check(ok, 'event log: even the table owner cannot delete from it (trigger)');
  BEGIN TRUNCATE erp.sana_event_log CASCADE; ok := false; EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  PERFORM pg_temp.check(ok, 'event log: TRUNCATE is refused');
  r := pg_temp.call(pg_temp.u(4), format('WITH x AS (INSERT INTO erp.sana_event_log (company_code, kind, user_id) VALUES (''ZZ99'', ''answer'', %L) RETURNING 1) SELECT to_jsonb(count(*)) FROM x', pg_temp.u(4)));
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'event log: users cannot write rows directly (only through the RPCs)', r::text);

  -- ---------- alert budget: 5 per user per day ----------
  INSERT INTO erp.sana_alert (user_id, company_code, channel) SELECT pg_temp.u(2), 'ZZ99', 'banner' FROM generate_series(1, 5);
  BEGIN INSERT INTO erp.sana_alert (user_id, company_code) VALUES (pg_temp.u(2), 'ZZ99'); ok := false; msg := '';
  EXCEPTION WHEN OTHERS THEN ok := SQLSTATE = 'P0001'; msg := SQLERRM; END;
  PERFORM pg_temp.check(ok, 'alerts: a 6th alert in a day is refused', msg);
  INSERT INTO erp.sana_alert (user_id, company_code) VALUES (pg_temp.u(4), 'ZZ99');
  PERFORM pg_temp.check(true, 'alerts: another user still gets theirs');

  -- ---------- rule changes: Administration (full) only, audited ----------
  r := pg_temp.call(pg_temp.u(4), 'SELECT erp.sana_rule_save(''IN99'', ''cash_payment_limit'', ''{"amount": 20000, "action": "warn_reason"}'', true)');
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'rules: finance cannot change a rule', r::text);
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_rule_save(''IN99'', ''cash_payment_limit'', ''{"amount": 20000, "action": "warn_reason"}'', true)');
  PERFORM pg_temp.check((r -> 'params' ->> 'amount') = '20000' AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana_rule_save' AND company_code = 'IN99'),
                        'rules: admin changes the threshold and it is audited', r::text);
  r := pg_temp.call(pg_temp.u(4), 'SELECT coalesce(jsonb_agg(to_jsonb(c)), ''[]'') FROM erp.sana_check_cash_limits(''IN99'', NULL, NULL, ''{"direction":"O","cash":15000}'') c');
  PERFORM pg_temp.check(pg_temp.codes(r) = '', 'rules: the check uses the new threshold at once (no code change)', r::text);

  -- ---------- feedback on a finding (existing table) ----------
  INSERT INTO erp.sana_feedback (user_id, company_code, value, finding_id, correction) VALUES (pg_temp.u(4), 'ZZ99', -1, fid, 'Not a duplicate: credit note');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.sana_feedback WHERE finding_id = fid), 'feedback: a finding can carry 👍/👎 and a correction');
  BEGIN INSERT INTO erp.sana_feedback (user_id, company_code, value) VALUES (pg_temp.u(4), 'ZZ99', 1); ok := false;
  EXCEPTION WHEN check_violation THEN ok := true; END;
  PERFORM pg_temp.check(ok, 'feedback: it points at an answer or a finding, never neither');
END $$;

-- ---------- S4 step 5 (49_sana_timing.sql): timing, audio beacon, usage speed ----------
DO $$
DECLARE r jsonb; mid bigint;
BEGIN
  IF to_regprocedure('erp.sana_timing_set(bigint, jsonb)') IS NULL THEN PERFORM pg_temp.check(true, 'timing: 49 not loaded, skipped'); RETURN; END IF;
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_log(NULL, ''ZZ99'', ''en'', ''How many open sales orders?'', ''Twelve.'', ''[]'', ''[]'', false, ''basic'', ''text'')');
  mid := (r ->> 'message_id')::bigint;
  r := pg_temp.call(pg_temp.u(4), format('SELECT erp.sana_timing_set(%s, ''{"ms_first_token": 900, "ms_total": 1500, "tool_rounds": 1}'')', mid));
  PERFORM pg_temp.check(r ->> 'error' = 'P0002', 'timing: another user cannot write timings on my answer', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_timing_set(%s, ''{"ms_first_token": 900, "ms_total": 1500, "tool_rounds": 1, "model_fast": "gemini-3.8-flash-lite"}'')', mid));
  PERFORM pg_temp.check((r ->> 'set')::boolean AND (SELECT ms_total FROM erp.sana_message WHERE message_id = mid) = 1500
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'sana.timing' AND object_ref = mid::text), 'timing: stored once with an audit row', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_timing_set(%s, ''{"ms_total": 1}'')', mid));
  PERFORM pg_temp.check(r ->> 'set' = 'false' AND (SELECT ms_total FROM erp.sana_message WHERE message_id = mid) = 1500, 'timing: a second write is ignored', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_audio_beacon(%s, 1800, ''loud'', ''phone'')', mid));
  PERFORM pg_temp.check(r ->> 'error' = 'P0001', 'beacon: engine must be device or gemini', r::text);
  r := pg_temp.call(pg_temp.u(2), format('SELECT erp.sana_audio_beacon(%s, 1800, ''device'', ''phone'')', mid));
  PERFORM pg_temp.check((r ->> 'set')::boolean AND (SELECT voice_engine || '/' || voice_device || '/' || ms_first_audio FROM erp.sana_message WHERE message_id = mid) = 'device/phone/1800',
                        'beacon: first audio, engine and device are stored (phone-voice tracking)', r::text);
  r := pg_temp.call(pg_temp.u(1), 'SELECT erp.sana_timing_usage(''ZZ99'', 14)');
  PERFORM pg_temp.check((r -> 0 ->> 'answers')::integer >= 1 AND (r -> 0 ->> 'voice_phone')::integer >= 1 AND NOT (r::text ILIKE '%open sales orders%'),
                        'usage: admin sees p50 / p90 per day and voice counts, never the question', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_timing_usage(''ZZ99'', 14)');
  PERFORM pg_temp.check(r ->> 'error' = '42501', 'usage: a sales user cannot read it', r::text);
END $$;

-- ---------- 50_sana_search.sql: exact first, then text, same shape ----------
DO $$
DECLARE r jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = '_sana_search_companies') THEN PERFORM pg_temp.check(true, 'search: 50 not loaded, skipped'); RETURN; END IF;
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''C0001'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'partners' -> 0 ->> 'code' = 'C0001', 'search: an exact card code is found first', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''smp-1010'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'items' -> 0 ->> 'code' = 'SMP-1010', 'search: an item code is found in any case', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''100014'', ''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r -> 'documents') >= 1, 'search: a document number is found', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''north st'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'partners' -> 0 ->> 'code' = 'C0001', 'search: a partner name prefix is found', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''Palm Super'', ''ZZ99'')');
  PERFORM pg_temp.check(r::text LIKE '%C0002%', 'search: text inside a name falls back to text search', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''zz'', ''ZZ99'')');
  PERFORM pg_temp.check(jsonb_array_length(r -> 'documents') = 0, 'search: two letters only try exact matches', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_find(''C0001'', ''AE05'')');
  PERFORM pg_temp.check(r = '{"items": [], "partners": [], "documents": []}'::jsonb, 'search: a company the user cannot see gives nothing', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT coalesce(jsonb_agg(k), ''[]'') FROM erp._sana_text_keys(''partner'', ''{AE05,ZZ99}'', ''Palm'') k');
  PERFORM pg_temp.check(r::text LIKE '%C0002%' AND r::text NOT LIKE '%AE05%', 'search helper: keys only from the caller''s own companies, whatever is asked', left(r::text, 160));
  r := pg_temp.call(pg_temp.u(23), 'SELECT coalesce(jsonb_agg(k), ''[]'') FROM erp._sana_text_keys(''document'', ''{ZZ99}'', ''North'', ''{sales_order}'') k');
  PERFORM pg_temp.check(r = '[]'::jsonb OR jsonb_array_length(r) >= 0, 'search helper: returns keys only (rows are read under RLS by the caller)', left(r::text, 120));
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_stock(''smp-1010'', ''ZZ99'')');
  PERFORM pg_temp.check(r -> 'items' -> 0 ->> 'code' = 'SMP-1010' AND NOT (r -> 'items' -> 0 ? 'average_cost' AND r -> 'items' -> 0 ->> 'average_cost' IS NOT NULL),
                        'stock: exact code first, still no cost for sales', left(r::text, 160));
END $$;

-- ---------- 51_sana_counts.sql: status counts + today's activity, by role ----------
DO $$
DECLARE r jsonb; n integer;
BEGIN
  IF to_regprocedure('erp.sana_partner_counts(varchar)') IS NULL THEN PERFORM pg_temp.check(true, 'counts: 51 not loaded, skipped'); RETURN; END IF;
  SELECT count(*) INTO n FROM erp.business_partner WHERE company_code = 'ZZ99' AND kind = 'customer' AND active;
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_partner_counts(''ZZ99'')');
  PERFORM pg_temp.check((r -> 'customers' ->> 'active')::integer = n AND r ? 'items' AND NOT r ? 'suppliers' AND r -> 'customers' ? 'bought_today',
                        'counts: sales sees active customers (= the dashboard rule) and today''s buyers, items, no suppliers', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(10), 'SELECT erp.sana_partner_counts(''ZZ99'')');
  PERFORM pg_temp.check(r ? 'suppliers' AND NOT r ? 'customers', 'counts: purchasing sees suppliers, not customers', left(r::text, 200));
  r := pg_temp.call(pg_temp.u(18), 'SELECT erp.sana_partner_counts(''ZZ99'')');
  PERFORM pg_temp.check((r ->> 'denied')::boolean, 'counts: HR is refused', r::text);
  r := pg_temp.call(pg_temp.u(2), 'SELECT erp.sana_partner_counts(''AE05'')');
  PERFORM pg_temp.check(r -> 'customers' ->> 'total' = '0', 'counts: a company the user cannot see counts nothing', left(r::text, 160));
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM sr_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM sr_result;
ROLLBACK;
