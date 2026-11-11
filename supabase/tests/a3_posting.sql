-- A3 · Posting engine tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run after 10–17, test-users.sql and 18_posting.sql. Everything happens inside one transaction that is rolled back,
-- so the database is unchanged afterwards. Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a3_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a3_result TO authenticated;

-- Run one SQL expression as a user (RLS and grants apply) and return its jsonb result, or {error, message} if it raised.
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
-- Run SQL as the database owner (no user); returns {error, message} if it raised.
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
CREATE FUNCTION pg_temp.save(p_user uuid, p_id integer, p_header jsonb, p_lines jsonb, p_company text DEFAULT 'ZZ99') RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.journal_draft_save(%L, %s, %L::jsonb, %L::jsonb)', p_company, coalesce(p_id::text, 'NULL'), p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.checks(p_user uuid, p_header jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.journal_checks(%L, %L::jsonb, %L::jsonb)', 'ZZ99', p_header, p_lines))
$$;
CREATE FUNCTION pg_temp.submit(p_user uuid, p_id integer, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.journal_submit(%L, %s, %L)', 'ZZ99', p_id, p_reason))
$$;
CREATE FUNCTION pg_temp.decide(p_user uuid, p_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.journal_decide(%L, %s, %L, %L)', 'ZZ99', p_id, p_decision, p_note))
$$;
CREATE FUNCTION pg_temp.rev(p_user uuid, p_trans integer, p_date date, p_reason text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.journal_reverse(%L, %s, %L, %L)', 'ZZ99', p_trans, p_date, p_reason))
$$;
CREATE FUNCTION pg_temp.period(p_user uuid, p_period text, p_status text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.period_set_status(%L, %L, %L)', 'ZZ99', p_period, p_status))
$$;
CREATE FUNCTION pg_temp.gl(p_user uuid, p_area text, p_key text, p_acct text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.gl_determination_set(%L, %L, %L, %L)', 'ZZ99', p_area, p_key, p_acct))
$$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a3_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
-- Expect an error with exactly this message.
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 160)))
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  smgr   uuid := '00000000-0000-4000-8000-000000000007';
  fmgr   uuid := '00000000-0000-4000-8000-000000000008';
  h      jsonb := '{"ref_date":"2026-11-09","memo":"A3 test rent","ref1":"T-1"}';
  ok2    jsonb := '[{"acct_code":"6200","debit":1000,"memo":"Rent"},{"acct_code":"1110","credit":1000}]';
  big    jsonb := '[{"acct_code":"6200","debit":60000},{"acct_code":"1110","credit":60000}]';
  r      jsonb;
  r2     jsonb;
  d1     integer;
  d2     integer;
  d3     integer;
  t1     integer;
  t2     integer;
  t3     integer;
  t4     integer;
  v_cnt  bigint;
  v_n    numeric;
  v_txt  text;
  v_seq  integer;
  e_so   integer;
  e_inv  integer;
BEGIN
  -- ---------- Who may call ----------
  PERFORM pg_temp.expect(pg_temp.save(nobody, NULL, h, ok2), 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.', 'user without a profile refused');
  r := pg_temp.save(sales, NULL, h, ok2);
  PERFORM pg_temp.expect(r, 'Your position does not include Financials. Ask the system admin if you need it.', 'sales-only user refused (journal save)');
  PERFORM pg_temp.check(r->>'error' = '42501', 'sales refusal is 42501', r->>'error');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.journal_checks(''ZZ99'', ''{}''::jsonb, ''[]''::jsonb)'),
    'Your position does not include Financials. Ask the system admin if you need it.', 'sales-only user refused (journal checks)');
  PERFORM pg_temp.expect(pg_temp.rev(sales, 9000, '2026-11-09', 'x'), 'Your position does not include Financials. Ask the system admin if you need it.', 'sales-only user refused (reverse)');
  PERFORM pg_temp.expect(pg_temp.period(sales, '2026-10', 'closed'), 'Your position does not include Financials. Ask the system admin if you need it.', 'sales-only user refused (period)');
  PERFORM pg_temp.expect(pg_temp.gl(sales, 'sales', 'revenue', '4100'), 'Your position does not include Financials. Ask the system admin if you need it.', 'sales-only user refused (G/L determination)');
  PERFORM pg_temp.expect(pg_temp.call(sales, 'SELECT erp.journal_info(''ZZ99'', 9000)'), 'Your position does not include Financials. Ask the system admin if you need it.', 'sales-only user refused (journal info)');
  PERFORM pg_temp.expect(pg_temp.save(owner, NULL, h, ok2), 'You have read-only access to Financials. Ask the system admin for full access to post journals.', 'read-only (owner) refused (journal save)');
  PERFORM pg_temp.expect(pg_temp.period(owner, '2026-10', 'closed'), 'You have read-only access to Financials. Ask the system admin for full access to change posting periods.', 'read-only refused (period)');
  PERFORM pg_temp.expect(pg_temp.gl(owner, 'sales', 'revenue', '4100'), 'You have read-only access to Financials. Ask the system admin for full access to change G/L account determination.', 'read-only refused (G/L determination)');
  PERFORM pg_temp.expect(pg_temp.rev(owner, 9000, '2026-11-09', 'x'), 'You have read-only access to Financials. Ask the system admin for full access to post journals.', 'read-only refused (reverse)');
  r := pg_temp.call(owner, 'SELECT erp.journal_setup(''ZZ99'')');
  PERFORM pg_temp.check(r->>'can_write' = 'false' AND r->>'currency' = 'AED', 'read-only user may open the setup (can_write false)', r::text);
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type) VALUES ('ZZ98', 'Other test co', 'Other', 'AE', 'AED', 'mainland');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, ok2, 'ZZ98'), 'You don''t have access to company ZZ98.', 'another company refused');
  r := pg_temp.call(NULL, format('SELECT erp.journal_draft_save(%L, NULL, %L::jsonb, %L::jsonb)', 'ZZ99', h, ok2), 'anon');
  PERFORM pg_temp.check(r->>'error' = '42501', 'anon cannot execute journal_draft_save', r::text);
  r := pg_temp.call(fin, format('SELECT to_jsonb(erp.post_journal(%L, %L::date, %L, %L::jsonb, ''{}''::jsonb))', 'ZZ99', '2026-11-09', 'x', ok2));
  PERFORM pg_temp.check(r->>'error' = '42501', 'post_journal is internal (authenticated cannot call it)', r::text);
  r := pg_temp.call(fin, 'SELECT to_jsonb(erp.post_document(''ZZ99'', 13, 1))');
  PERFORM pg_temp.check(r->>'error' = '42501', 'post_document is internal', r::text);
  r := pg_temp.call(fin, 'SELECT to_jsonb(erp.gl_account(''ZZ99'', ''sales'', ''revenue'', true))');
  PERFORM pg_temp.check(r->>'error' = '42501', 'gl_account is internal', r::text);
  r := pg_temp.call(fin, 'SELECT to_jsonb(erp._reverse_journal(''ZZ99'', 9000, ''2026-11-09'', ''x'', ''journal_reverse''))');
  PERFORM pg_temp.check(r->>'error' = '42501', '_reverse_journal is internal', r::text);

  -- Direct writes refused (no table write grants)
  r := pg_temp.call(fin, $q$WITH x AS (INSERT INTO erp.journal_entry (company_code, trans_id, ref_date, source) VALUES ('ZZ99', 1, '2026-11-09', 'erp') RETURNING 1) SELECT to_jsonb(1) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct insert into journal_entry refused', r::text);
  r := pg_temp.call(fin, $q$WITH x AS (INSERT INTO erp.journal_draft (company_code, created_by) VALUES ('ZZ99', '00000000-0000-4000-8000-000000000004') RETURNING 1) SELECT to_jsonb(1) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct insert into journal_draft refused', r::text);
  r := pg_temp.call(fin, $q$WITH x AS (UPDATE erp.posting_period SET status = 'closed' WHERE company_code = 'ZZ99' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct update of posting_period refused', r::text);
  r := pg_temp.call(fin, $q$WITH x AS (DELETE FROM erp.gl_determination WHERE company_code = 'ZZ99' RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'direct delete from gl_determination refused', r::text);
  r := pg_temp.call(fin, 'SELECT to_jsonb(nextval(''erp.erp_trans_id_seq''))');
  PERFORM pg_temp.check(r->>'error' = '42501', 'trans_id sequence not usable directly', r::text);

  -- Reading
  r := pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.gl_determination');
  PERFORM pg_temp.check(r::text = '0', 'sales user reads no G/L determination rows', r::text);
  r := pg_temp.call(fin, 'SELECT to_jsonb(count(*)) FROM erp.gl_determination WHERE company_code = ''ZZ99''');
  -- A6 (21_purchasing.sql) adds 3 ZZ99 sample rows: down payments, goods received not invoiced, landed cost clearing.
  -- A7 (22_inventory.sql) adds 1 ZZ99 sample row: stock count variance.
  -- B1 (30_numbering_company.sql) adds 1 ZZ99 sample row: price difference (landed costs on goods already sold).
  -- B5 (34_open_items.sql) adds 2 ZZ99 sample rows: the revaluation gain / loss accounts.
  -- B6 (35_final_items.sql) adds 1 ZZ99 sample row: the conversion difference account.
  PERFORM pg_temp.check(r::text = CASE WHEN to_regclass('erp.conv_diff_run') IS NOT NULL THEN '22' WHEN to_regclass('erp.fx_revaluation') IS NOT NULL THEN '21' WHEN to_regclass('erp.landed_cost') IS NULL THEN '14' WHEN to_regclass('erp.inv_count') IS NULL THEN '17'
                                       WHEN to_regclass('erp.sales_doc_request') IS NULL THEN '18' ELSE '19' END,
                        'finance reads the ZZ99 sample G/L rows (14, 17 with A6, 18 with A7, 19 with B1, 21 with B5, 22 with B6)', r::text);
  r := pg_temp.call(fin, 'SELECT to_jsonb(count(*)) FROM erp.posting_period WHERE company_code = ''ZZ99''');
  PERFORM pg_temp.check(r::text = '24', 'finance reads 24 ZZ99 sample periods (2026–2027)', r::text);
  r := pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.gl_posting_key');
  -- A6 adds purchasing/grpo_clearing (goods received, not invoiced). B3 (32_gl_setup.sql) adds the Banking, Production, Service,
  -- Payroll and goods receipt / issue reason keys: 36.
  -- B5 adds general/fx_reval_gain and general/fx_reval_loss: 38. B6 adds general/conversion_diff: 39.
  PERFORM pg_temp.check(r::text = CASE WHEN to_regclass('erp.conv_diff_run') IS NOT NULL THEN '39' WHEN to_regclass('erp.fx_revaluation') IS NOT NULL THEN '38' WHEN to_regclass('erp.gl_determination_group') IS NOT NULL THEN '36' WHEN to_regclass('erp.landed_cost') IS NULL THEN '22' ELSE '23' END,
                        'posting keys are reference data (22 rows, 23 with A6, 36 with B3, 38 with B5, 39 with B6, readable)', r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.gl_determination g JOIN erp.company c USING (company_code) WHERE c.company_code <> 'ZZ99') = 0,
                        'real companies have no G/L determination rows', '');

  -- ---------- G/L account not set ----------
  r := pg_temp.su($q$SELECT to_jsonb(erp.gl_account('ZZ98', 'sales', 'revenue'))$q$);
  PERFORM pg_temp.expect(r, 'G/L account for ''Revenue'' is not set for ZZ98. Ask Finance to set it in Setup › Financials › G/L Account Determination.', 'G/L not set: exact message (Revenue)');
  r := pg_temp.su($q$SELECT to_jsonb(erp.gl_account('ZZ99', 'sales', 'revenue'))$q$);
  PERFORM pg_temp.check(r #>> '{}' = '4100', 'G/L account resolves for ZZ99 (Revenue → 4100)', r::text);
  r := pg_temp.su($q$SELECT to_jsonb(erp.post_journal('ZZ99', '2026-11-09', 'x', '[{"area":"general","posting_key":"rounding","debit":1},{"acct_code":"1110","credit":1}]'::jsonb, '{}'::jsonb))$q$);
  PERFORM pg_temp.expect(r, 'G/L account for ''Rounding'' is not set for ZZ99. Ask Finance to set it in Setup › Financials › G/L Account Determination.', 'posting with an unset key refused');

  -- ---------- Line and header validation (exact messages) ----------
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"1000","debit":5},{"acct_code":"1110","credit":5}]'),
    'Line 1: 1000 · Assets is a title account. Choose a postable account.', 'non-postable (title) account refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"6200","debit":5},{"acct_code":"9999","credit":5}]'),
    'Line 2: account 9999 does not exist in ZZ99. Check the account code.', 'unknown account refused');
  UPDATE erp.account SET frozen = true WHERE company_code = 'ZZ99' AND acct_code = '6400';
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"6400","debit":5},{"acct_code":"1110","credit":5}]'),
    'Line 1: 6400 · Marketing is frozen. Choose another account, or ask Finance to unfreeze it.', 'frozen account refused');
  PERFORM pg_temp.expect(pg_temp.su($q$SELECT to_jsonb(erp.post_journal('ZZ99', '2026-11-09', 'x', '[{"acct_code":"6400","debit":5},{"acct_code":"1110","credit":5}]'::jsonb, '{}'::jsonb))$q$),
    'Line 1: 6400 · Marketing is frozen. Choose another account, or ask Finance to unfreeze it.', 'post_journal refuses a frozen account');
  UPDATE erp.account SET frozen = false WHERE company_code = 'ZZ99' AND acct_code = '6400';
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"1200","debit":5},{"acct_code":"1110","credit":5}]'),
    'Line 1: 1200 · Accounts receivable is a control account for customers or suppliers. Post to it through a business partner document.', 'control account refused in a manual journal');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"6200","debit":5,"credit":5},{"acct_code":"1110","credit":5}]'),
    'Line 1: enter a debit or a credit, not both.', 'debit and credit on one line refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"6200","debit":-5},{"acct_code":"1110","credit":5}]'),
    'Line 1: amounts can''t be negative.', 'negative amount refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"acct_code":"6200","debit":"abc"},{"acct_code":"1110","credit":5}]'),
    'Line 1: amounts must be numbers.', 'non-numeric amount refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[{"debit":5},{"acct_code":"1110","credit":5}]'),
    'Line 1: choose an account.', 'line without an account refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, '{"memo":"x"}', ok2), 'Choose a posting date.', 'missing posting date refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, '{"ref_date":"2026-13-45"}', ok2), 'The posting date is not a valid date.', 'invalid posting date refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, NULL, h, '[]'), 'Add at least one line.', 'empty journal refused');
  PERFORM pg_temp.expect(pg_temp.save(fin, 99999999, h, ok2), 'Journal draft 99999999 was not found in company ZZ99.', 'unknown draft refused');

  -- Live check: unbalanced shows the difference; approval preview above the limit
  r := pg_temp.checks(fin, h, '[{"acct_code":"6200","debit":100},{"acct_code":"1110","credit":90}]');
  PERFORM pg_temp.check((r->'totals'->>'difference')::numeric = 10 AND r->'errors'->0->>'message' = 'Debits 100.00 and credits 90.00 don''t balance. Difference 10.00 AED.',
                        'checks: running difference and balance message', r->'errors'->0->>'message');
  r := pg_temp.checks(fin, h, big);
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 1 AND r->'checks'->0->>'approver_name' = 'QA · finance manager'
                        AND r->'checks'->0->>'message' = 'Total 60,000.00 AED is above your journal limit of 50,000.00 AED. Submit it for approval.',
                        'checks: 60,000 needs the finance manager (sample limit 50,000)', (r->'checks')::text);
  r := pg_temp.checks(admin, h, big);
  PERFORM pg_temp.check(jsonb_array_length(r->'checks') = 0, 'checks: no rule for the admin position → posts straight away', (r->'checks')::text);

  -- ---------- Unbalanced: draft may be saved, posting refused ----------
  r := pg_temp.save(fin, NULL, h, '[{"acct_code":"6200","debit":100},{"acct_code":"1110","credit":90}]');
  d1 := (r->>'draft_id')::integer;
  PERFORM pg_temp.check(d1 IS NOT NULL AND r->>'state' = 'draft', 'unbalanced draft can be saved', r::text);
  PERFORM pg_temp.expect(pg_temp.submit(fin, d1), 'Debits 100.00 and credits 90.00 don''t balance. Difference 10.00 AED.', 'unbalanced journal refused on post');
  PERFORM pg_temp.expect(pg_temp.su($q$SELECT to_jsonb(erp.post_journal('ZZ99', '2026-11-09', 'x', '[{"acct_code":"6200","debit":100},{"acct_code":"1110","credit":90}]'::jsonb, '{}'::jsonb))$q$),
    'Debits 100.00 and credits 90.00 don''t balance. Difference 10.00 AED.', 'post_journal refuses an unbalanced journal');
  PERFORM pg_temp.expect(pg_temp.su($q$SELECT to_jsonb(erp.post_journal('ZZ99', '2026-11-09', 'x', '[{"acct_code":"6200","debit":100}]'::jsonb, '{}'::jsonb))$q$),
    'Add at least two lines.', 'post_journal refuses a single line');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_entry WHERE company_code = 'ZZ99' AND source = 'erp'), 'nothing posted by the refusals', '');
  PERFORM pg_temp.expect(pg_temp.save(admin, d1, h, ok2), 'Only the person who created this journal can change it.', 'another user cannot edit the draft');
  r := pg_temp.save(fin, d1, h, ok2);
  PERFORM pg_temp.check(r->>'state' = 'draft' AND (r->'totals'->>'difference')::numeric = 0, 'creator fixes the draft', (r->'totals')::text);

  -- ---------- Periods: closed, locked, missing ----------
  r := pg_temp.period(fin, '2026-11', 'closed');
  PERFORM pg_temp.check(r->>'status' = 'closed' AND r->>'from' = 'open', 'finance closes 2026-11', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'period_set_status' AND object_ref = '2026-11' AND detail->>'to' = 'closed'), 'audit row for period change', '');
  PERFORM pg_temp.expect(pg_temp.submit(fin, d1), 'Posting period 2026-11 is closed, so nothing can be posted on 09 Nov 2026. Choose a date in an open period, or ask Finance to reopen it.', 'closed period refused');
  PERFORM pg_temp.expect(pg_temp.period(fin, '2026-11', 'closed'), 'Posting period 2026-11 is already closed.', 'same status refused');
  PERFORM pg_temp.period(fin, '2026-11', 'locked');
  PERFORM pg_temp.expect(pg_temp.submit(fin, d1), 'Posting period 2026-11 is locked, so nothing can be posted on 09 Nov 2026. Choose a date in an open period.', 'locked period refused');
  r := pg_temp.save(fin, d1, h, ok2);
  PERFORM pg_temp.check(r->>'state' = 'draft' AND r->'errors' @> '[{"field":"period"}]', 'draft still saves in a locked period (posting is what is blocked)', (r->'errors')::text);
  PERFORM pg_temp.expect(pg_temp.period(fin, '2026-11', 'shut'), 'Choose open, closed or locked.', 'unknown status refused');
  PERFORM pg_temp.expect(pg_temp.period(fin, '2030-01', 'open'), 'Posting period 2030-01 does not exist in ZZ99.', 'unknown period refused');
  r := pg_temp.period(fin, '2026-11', 'open');
  PERFORM pg_temp.check(r->>'status' = 'open' AND r->>'from' = 'locked', 'finance reopens 2026-11 (any transition, audited)', r::text);
  r := pg_temp.save(fin, NULL, '{"ref_date":"2025-06-01","memo":"no period"}', ok2);
  d3 := (r->>'draft_id')::integer;
  PERFORM pg_temp.expect(pg_temp.submit(fin, d3), 'No posting period covers 01 Jun 2025 in ZZ99. Ask Finance to add it in Administration › System Initialization › Posting Periods.', 'date without a period refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.period_add_year(''ZZ99'', 2026)'), 'Posting periods for 2026 already exist in ZZ99.', 'adding an existing year refused');
  PERFORM pg_temp.expect(pg_temp.call(fin, 'SELECT erp.period_add_year(''ZZ99'', 1999)'), 'Enter a year between 2000 and 2100.', 'year out of range refused');
  r := pg_temp.call(fin, 'SELECT erp.period_add_year(''ZZ99'', 2025)');
  PERFORM pg_temp.check((r->>'periods')::int = 12 AND (SELECT count(*) FROM erp.posting_period WHERE company_code = 'ZZ99' AND period_code LIKE '2025-%' AND status = 'open') = 12,
                        'finance adds 2025: 12 open monthly periods', r::text);
  PERFORM pg_temp.check((SELECT to_date FROM erp.posting_period WHERE company_code = 'ZZ99' AND period_code = '2025-02') = date '2025-02-28', 'February ends on the 28th', '');
  PERFORM pg_temp.expect(pg_temp.call(owner, 'SELECT erp.period_add_year(''ZZ99'', 2028)'), 'You have read-only access to Financials. Ask the system admin for full access to change posting periods.', 'read-only cannot add a year');

  -- ---------- Allowed: post a balanced journal ----------
  r := pg_temp.submit(fin, d1);
  t1 := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND t1 >= 900000000, 'balanced journal under the limit posts straight away (trans_id ≥ 900000000)', r::text);
  PERFORM pg_temp.check((SELECT source = 'erp' AND ref_date = '2026-11-09' AND total_local = 1000 AND trans_type = 30 AND memo = 'A3 test rent' AND ref1 = 'T-1' AND number = t1
                           FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t1), 'journal_entry written (source erp, date, total, type 30, memo, ref)', '');
  PERFORM pg_temp.check((SELECT count(*) = 2 AND sum(debit) = 1000 AND sum(credit) = 1000 FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t1),
                        'two balanced journal lines written', '');
  PERFORM pg_temp.check((SELECT memo FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t1 AND line_id = 0) = 'Rent'
                        AND (SELECT memo FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t1 AND line_id = 1) = 'A3 test rent',
                        'line memo kept; empty line memo takes the header memo', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'journal_post' AND object_ref = t1::text)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'journal_submit' AND object_ref = d1::text AND detail->>'result' = 'posted'),
                        'audit rows written (journal_post, journal_submit)', '');
  PERFORM pg_temp.check((SELECT state = 'posted' AND trans_id = t1 FROM erp.journal_draft WHERE draft_id = d1), 'draft marked posted with its trans_id', '');
  PERFORM pg_temp.expect(pg_temp.save(fin, d1, h, ok2), 'This journal is posted and can''t be edited. Post a reversal instead.', 'posted journal cannot be edited');
  PERFORM pg_temp.expect(pg_temp.submit(fin, d1), 'This journal is already posted.', 'posted journal cannot be submitted again');
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.journal_draft_cancel(''ZZ99'', %s, ''x'')', d1)), 'This journal is posted and can''t be cancelled. Post a reversal instead.', 'posted journal cannot be cancelled');
  r := pg_temp.su(format('WITH x AS (UPDATE erp.journal_line SET debit = 1 WHERE company_code = ''ZZ99'' AND trans_id = %s RETURNING 1) SELECT to_jsonb(count(*)) FROM x', t1));
  PERFORM pg_temp.check(r->>'message' = 'posted journals cannot be changed or deleted - post a reversal instead', 'posted journal is permanent (even for the owner role)', r::text);
  r := pg_temp.call(fin, format('SELECT erp.journal_info(''ZZ99'', %s)', t1));
  PERFORM pg_temp.check(r->>'can_reverse' = 'true' AND (r->>'draft_id')::int = d1, 'journal_info: can reverse, linked to its draft', r::text);
  r := pg_temp.call(owner, format('SELECT erp.journal_info(''ZZ99'', %s)', t1));
  PERFORM pg_temp.check(r->>'can_reverse' = 'false' AND r->>'reverse_block' = 'read_only', 'journal_info: read-only user cannot reverse', r->>'reverse_block');

  -- ---------- Reversal ----------
  PERFORM pg_temp.expect(pg_temp.rev(fin, t1, '2026-11-09', '  '), 'Add a reason for the reversal.', 'reversal without a reason refused');
  PERFORM pg_temp.expect(pg_temp.rev(fin, t1, '2026-11-01', 'Wrong month'), 'The reversal date can''t be before the journal''s posting date (09 Nov 2026).', 'reversal before the posting date refused');
  PERFORM pg_temp.expect(pg_temp.rev(fin, 123, '2026-11-09', 'x'), 'Journal 123 was not found in company ZZ99.', 'reversal of an unknown journal refused');
  PERFORM pg_temp.expect(pg_temp.rev(fin, 9000, '2026-11-09', 'x'), 'Journal 9000 is sample test data and can''t be reversed.', 'reversal of sample data refused');
  PERFORM pg_temp.period(fin, '2026-12', 'closed');
  PERFORM pg_temp.expect(pg_temp.rev(fin, t1, '2026-12-01', 'x'), 'Posting period 2026-12 is closed, so nothing can be posted on 01 Dec 2026. Choose a date in an open period, or ask Finance to reopen it.', 'reversal into a closed period refused');
  PERFORM pg_temp.period(fin, '2026-12', 'open');
  r := pg_temp.rev(fin, t1, '2026-11-10', 'Posted to the wrong account');
  t2 := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(t2 > t1 AND (r->>'reversal_of')::int = t1, 'reversal posts a new journal', r::text);
  PERFORM pg_temp.check((SELECT reversal_of = t1 AND source = 'erp' AND ref_date = '2026-11-10' AND memo = format('Reversal of journal %s: Posted to the wrong account', t1)
                           FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t2), 'reversal header: reversal_of, date, memo', '');
  PERFORM pg_temp.check(NOT EXISTS (
      SELECT o.acct_code FROM erp.journal_line o JOIN erp.journal_line v ON v.company_code = o.company_code AND v.line_id = o.line_id AND v.trans_id = t2
       WHERE o.company_code = 'ZZ99' AND o.trans_id = t1 AND NOT (v.acct_code = o.acct_code AND v.debit = o.credit AND v.credit = o.debit))
    AND (SELECT count(*) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t2) = 2,
    'reversal is the mirror entry (same accounts, debit ↔ credit)', '');
  PERFORM pg_temp.check((SELECT reversal_of IS NULL AND total_local = 1000 FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t1)
                        AND (SELECT sum(debit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t1) = 1000, 'original journal unchanged', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'journal_reversed' AND object_ref = t1::text AND (detail->>'reversed_by')::int = t2)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'journal_reverse' AND object_ref = t2::text), 'audit rows written for the reversal', '');
  PERFORM pg_temp.expect(pg_temp.rev(fin, t1, '2026-11-10', 'again'), format('Journal %s was already reversed by journal %s.', t1, t2), 'second reversal refused');
  PERFORM pg_temp.expect(pg_temp.rev(fin, t2, '2026-11-10', 'undo'), format('Journal %s is itself a reversal of journal %s and can''t be reversed.', t2, t1), 'reversing a reversal refused');
  r := pg_temp.call(fin, format('SELECT erp.journal_info(''ZZ99'', %s)', t1));
  PERFORM pg_temp.check(r->>'can_reverse' = 'false' AND (r->>'reversed_by')::int = t2 AND r->>'reverse_block' = format('Journal %s was already reversed by journal %s.', t1, t2),
                        'journal_info: reversed_by and the reason it cannot be reversed again', r->>'reverse_block');
  -- An SAP journal is never reversed or changed here
  INSERT INTO erp.account (company_code, acct_code, name, postable, source) VALUES ('ZZ99', 'S6200', 'SAP rent', true, 'sap');
  WITH je AS (INSERT INTO erp.journal_entry (company_code, trans_id, number, ref_date, memo, trans_type, source) VALUES ('ZZ99', 777001, 777001, '2026-11-02', 'SAP JE', 30, 'sap') RETURNING company_code, trans_id)
  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, debit, credit) SELECT company_code, trans_id, v.l, v.a, v.d, v.c FROM je,
    (VALUES (0, 'S6200', 50::numeric, 0::numeric), (1, '1110', 0, 50)) AS v(l, a, d, c);
  PERFORM pg_temp.expect(pg_temp.rev(fin, 777001, '2026-11-09', 'x'), 'Journal 777001 came from SAP Business One. Reverse it in SAP during the soft switch.', 'reversal of an SAP journal refused');
  PERFORM pg_temp.check((SELECT count(*) FROM erp.journal_entry WHERE company_code = 'ZZ99' AND reversal_of = 777001) = 0
                        AND (SELECT sum(debit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = 777001) = 50, 'SAP journal untouched', '');

  -- ---------- Approval above the limit ----------
  r := pg_temp.save(fin, NULL, '{"ref_date":"2026-11-09","memo":"Big accrual"}', big);
  d2 := (r->>'draft_id')::integer;
  PERFORM pg_temp.expect(pg_temp.submit(fin, d2), 'This journal needs approval (total above your limit). Add a reason for the approver.', 'approval needed: reason required');
  r := pg_temp.submit(fin, d2, 'Year-end accrual');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'journal above the limit waits for approval', r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM erp.approval WHERE object = 'journal' AND object_ref = d2::text AND approver_position = 'QA_FIN_MGR' AND decision IS NULL AND NOT superseded) = 1,
                        'one approval row for the finance manager', '');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_entry WHERE company_code = 'ZZ99' AND memo = 'Big accrual'), 'nothing posted while waiting', '');
  PERFORM pg_temp.expect(pg_temp.save(fin, d2, h, big), 'This journal is waiting for approval and can''t be edited. Ask the approver to reject it first.', 'waiting journal cannot be edited');
  PERFORM pg_temp.expect(pg_temp.submit(fin, d2, 'x'), 'This journal is already waiting for approval.', 'waiting journal cannot be submitted again');
  PERFORM pg_temp.expect(pg_temp.decide(fin, d2, 'approved'), 'You can''t approve your own journal.', 'own journal cannot be approved');
  PERFORM pg_temp.expect(pg_temp.decide(fin, d2, 'rejected', 'n'), 'You can''t reject your own journal. Cancel it instead if it is no longer needed.', 'own journal cannot be rejected');
  PERFORM pg_temp.expect(pg_temp.decide(admin, d2, 'approved'), 'This journal is waiting for approval from QA · finance manager. Your position can''t decide it.', 'wrong approver refused');
  PERFORM pg_temp.expect(pg_temp.decide(smgr, d2, 'approved'), 'Your position does not include Financials. Ask the system admin if you need it.', 'sales manager (no Financials) refused');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d2, 'maybe'), 'Choose approve or reject.', 'unknown decision refused');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d2, 'rejected', ' '), 'Add a note saying why you are rejecting this journal.', 'reject without a note refused');
  r := pg_temp.call(fmgr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(r->>'is_approver' = 'true' AND r->'waiting' @> jsonb_build_array(jsonb_build_object('kind', 'journal', 'doc_entry', d2, 'rule_code', 'journal_amount')),
                        'inbox: journal waiting for the finance manager', left((r->'waiting')::text, 200));
  r := pg_temp.call(fin, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(r->'sent' @> jsonb_build_array(jsonb_build_object('kind', 'journal', 'doc_entry', d2)) AND jsonb_array_length(r->'waiting') = 0,
                        'inbox: listed under Sent by me for the requester', '');
  r := pg_temp.call(sales, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(NOT (r->'sent' @> '[{"kind":"journal"}]') AND NOT (r->'waiting' @> '[{"kind":"journal"}]'), 'inbox: sales user sees no journals', '');
  r := pg_temp.call(fmgr, format('SELECT erp.journal_draft_info(''ZZ99'', %s)', d2));
  PERFORM pg_temp.check(r->>'can_decide' = 'true' AND r->>'can_edit' = 'false' AND r->>'reason' = 'Year-end accrual' AND jsonb_array_length(r->'lines') = 2,
                        'draft info for the approver: can decide, reason, lines', '');
  r := pg_temp.decide(fmgr, d2, 'rejected', 'Split it by cost centre');
  PERFORM pg_temp.check(r->>'state' = 'rejected', 'finance manager rejects with a note', r::text);
  r := pg_temp.call(fin, format('SELECT erp.journal_draft_info(''ZZ99'', %s)', d2));
  PERFORM pg_temp.check(r->>'can_edit' = 'true' AND r->>'state' = 'rejected', 'rejected journal can be edited by its creator', '');
  PERFORM pg_temp.save(fin, d2, '{"ref_date":"2026-11-09","memo":"Big accrual"}', big);
  PERFORM pg_temp.submit(fin, d2, 'Resubmitted');
  -- Approval while the period closed in the meantime: nothing is posted, the journal stays waiting
  PERFORM pg_temp.period(fin, '2026-11', 'closed');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d2, 'approved'), 'Posting period 2026-11 is closed, so nothing can be posted on 09 Nov 2026. Choose a date in an open period, or ask Finance to reopen it.',
                         'approval into a closed period refused');
  PERFORM pg_temp.check((SELECT state FROM erp.journal_draft WHERE draft_id = d2) = 'pending_approval'
                        AND NOT EXISTS (SELECT 1 FROM erp.approval WHERE object = 'journal' AND object_ref = d2::text AND decision = 'approved'),
                        'refused approval left the journal waiting', '');
  PERFORM pg_temp.period(fin, '2026-11', 'open');
  r := pg_temp.decide(fmgr, d2, 'approved');
  t3 := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND t3 IS NOT NULL, 'finance manager approves → posted', r::text);
  PERFORM pg_temp.check((SELECT total_local FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t3) = 60000, 'approved journal posted for 60,000', '');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'journal_approve' AND object_ref = d2::text)
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'journal_reject' AND object_ref = d2::text), 'audit rows for approve and reject', '');
  PERFORM pg_temp.expect(pg_temp.decide(fmgr, d2, 'approved'), 'This journal is not waiting for approval.', 'deciding twice refused');
  r := pg_temp.save(admin, NULL, h, big);
  r := pg_temp.submit(admin, (r->>'draft_id')::integer);
  PERFORM pg_temp.check(r->>'state' = 'posted', 'no rule for the admin position: 60,000 posts straight away', r::text);

  -- Cancel a draft
  PERFORM pg_temp.expect(pg_temp.call(fin, format('SELECT erp.journal_draft_cancel(''ZZ99'', %s, '' '')', d3)), 'Add a note saying why the journal is cancelled.', 'cancel without a note refused');
  PERFORM pg_temp.expect(pg_temp.call(admin, format('SELECT erp.journal_draft_cancel(''ZZ99'', %s, ''x'')', d3)), 'Only the person who created this journal can cancel it.', 'another user cannot cancel');
  r := pg_temp.call(fin, format('SELECT erp.journal_draft_cancel(''ZZ99'', %s, ''Not needed'')', d3));
  PERFORM pg_temp.check(r->>'state' = 'cancelled', 'creator cancels a draft', r::text);
  PERFORM pg_temp.expect(pg_temp.save(fin, d3, h, ok2), 'This journal is cancelled and can''t be edited.', 'cancelled journal cannot be edited');
  PERFORM pg_temp.expect(pg_temp.submit(fin, d3), 'This journal is cancelled and can''t be submitted.', 'cancelled journal cannot be submitted');
  r := pg_temp.call(fin, 'SELECT to_jsonb(count(*)) FROM erp.journal_draft_list WHERE company_code = ''ZZ99''');
  PERFORM pg_temp.check((r #>> '{}')::int >= 4, 'finance reads the drafts list view', r::text);
  r := pg_temp.call(sales, 'SELECT to_jsonb(count(*)) FROM erp.journal_draft_list');
  PERFORM pg_temp.check(r::text = '0', 'sales user reads no drafts', r::text);

  -- ---------- G/L account determination ----------
  r := pg_temp.gl(fin, 'sales', 'rounding', '6800');
  PERFORM pg_temp.expect(r, 'Unknown posting key sales/rounding.', 'unknown posting key refused');
  PERFORM pg_temp.expect(pg_temp.gl(fin, 'general', 'rounding', '4000'), 'Account 4000 · Revenue is a title account. Choose a postable account.', 'title account refused for G/L determination');
  PERFORM pg_temp.expect(pg_temp.gl(fin, 'general', 'rounding', '9999'), 'Account 9999 does not exist in ZZ99. Check the account code.', 'unknown account refused for G/L determination');
  UPDATE erp.account SET frozen = true WHERE company_code = 'ZZ99' AND acct_code = '6400';
  PERFORM pg_temp.expect(pg_temp.gl(fin, 'general', 'rounding', '6400'), 'Account 6400 · Marketing is frozen. Choose another account.', 'frozen account refused for G/L determination');
  UPDATE erp.account SET frozen = false WHERE company_code = 'ZZ99' AND acct_code = '6400';
  r := pg_temp.gl(fin, 'general', 'rounding', '6800');
  PERFORM pg_temp.check(r->>'acct_code' = '6800' AND (SELECT acct_code = '6800' AND source = 'erp' AND updated_by = fin FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'rounding'),
                        'finance sets Rounding → 6800 (source erp)', r::text);
  r := pg_temp.su($q$SELECT to_jsonb(erp.post_journal('ZZ99', '2026-11-09', 'Rounding test', '[{"area":"general","posting_key":"rounding","debit":0.01},{"acct_code":"1110","credit":0.01}]'::jsonb, '{}'::jsonb))$q$);
  PERFORM pg_temp.check((SELECT acct_code FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = (r #>> '{}')::int AND line_id = 0) = '6800',
                        'posting key resolves through G/L determination', r::text);
  r := pg_temp.gl(fin, 'general', 'rounding', '');
  PERFORM pg_temp.check(r->>'acct_code' IS NULL AND NOT EXISTS (SELECT 1 FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'rounding'), 'finance clears a key', r::text);
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'gl_determination_set' AND object_ref = 'general/rounding')
                        AND EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'gl_determination_clear' AND object_ref = 'general/rounding'), 'audit rows for G/L changes', '');
  INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source) VALUES ('ZZ99', 'general', 'opening_balances', 'S6200', 'sap');
  PERFORM pg_temp.expect(pg_temp.gl(fin, 'general', 'opening_balances', '3200'), 'The account for ''Opening balances'' comes from SAP Business One and is read-only during the soft switch.', 'SAP G/L row cannot be changed');
  PERFORM pg_temp.expect(pg_temp.gl(fin, 'general', 'opening_balances', NULL), 'The account for ''Opening balances'' comes from SAP Business One and is read-only during the soft switch.', 'SAP G/L row cannot be cleared');
  PERFORM pg_temp.check((SELECT acct_code FROM erp.gl_determination WHERE company_code = 'ZZ99' AND posting_key = 'opening_balances') = 'S6200', 'SAP G/L row untouched', '');

  -- ---------- Document posting (internal, for A4) ----------
  e_inv := 900777001;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, card_name, currency, total, vat_total, source)
  VALUES ('ZZ99', 13, e_inv, 7001, 'ar_invoice', 'open', '2026-11-09', 'C0011', 'Sample customer', 'AED', 1155, 55, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, price, line_total, tax_code, vat)
  VALUES ('ZZ99', 13, e_inv, 0, 'SMP-1010', 10, 100, 1000, 'SR', 50), ('ZZ99', 13, e_inv, 1, 'SMP-1020', 1, 100, 100, 'SR', 5), ('ZZ99', 13, e_inv, 2, 'SMP-1020', 1, 0, 0, 'ZR', 0);
  r := pg_temp.su(format('SELECT to_jsonb(erp.post_document(''ZZ99'', 13, %s))', e_inv));
  t4 := (r #>> '{}')::int;
  PERFORM pg_temp.check(t4 >= 900000000, 'ERP A/R invoice posts a journal', r::text);
  PERFORM pg_temp.check((SELECT debit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t4 AND acct_code = '1200' AND short_name = 'C0011') = 1155
                        AND (SELECT credit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t4 AND acct_code = '4100') = 1100
                        AND (SELECT credit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t4 AND acct_code = '2200' AND tax_code = 'SR') = 55
                        AND (SELECT count(*) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = t4) = 3,
                        'invoice journal: AR 1,155 Dr (customer) / Revenue 1,100 Cr / Output VAT 55 Cr', '');
  PERFORM pg_temp.check((SELECT trans_type = 13 AND ref1 = '7001' FROM erp.journal_entry WHERE company_code = 'ZZ99' AND trans_id = t4)
                        AND EXISTS (SELECT 1 FROM erp.document_posting WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = e_inv AND trans_id = t4),
                        'invoice journal type 13, linked in document_posting', '');
  PERFORM pg_temp.expect(pg_temp.su(format('SELECT to_jsonb(erp.post_document(''ZZ99'', 13, %s))', e_inv)), format('Document 7001 is already posted (journal %s).', t4), 'document cannot post twice');
  PERFORM pg_temp.expect(pg_temp.rev(fin, t4, '2026-11-09', 'x'), format('Journal %s was posted by a document. Cancel the document instead.', t4), 'document journal not reversed by hand');
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, currency, total, source)
  VALUES ('ZZ99', 14, e_inv, 7002, 'ar_credit_note', 'open', '2026-11-09', 'C0011', 'AED', 105, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, price, line_total, tax_code, vat)
  VALUES ('ZZ99', 14, e_inv, 0, 'SMP-1010', 1, 100, 100, 'SR', 5);
  r := pg_temp.su(format('SELECT to_jsonb(erp.post_document(''ZZ99'', 14, %s))', e_inv));
  PERFORM pg_temp.check((SELECT credit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = (r #>> '{}')::int AND acct_code = '1200') = 105
                        AND (SELECT debit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = (r #>> '{}')::int AND acct_code = '4150') = 100
                        AND (SELECT debit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = (r #>> '{}')::int AND acct_code = '2200') = 5,
                        'credit memo journal: Sales returns 100 Dr / VAT 5 Dr / AR 105 Cr', r::text);
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, currency, total, source)
  VALUES ('ZZ99', 13, 777002, 777002, 'ar_invoice', 'open', '2026-11-09', 'AED', 10, 'sap');
  PERFORM pg_temp.expect(pg_temp.su('SELECT to_jsonb(erp.post_document(''ZZ99'', 13, 777002))'),
    'Document 777002 came from SAP Business One. SAP posts its own journal entry, so nothing is posted in Super ERP.', 'SAP document never posts');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.document_posting WHERE doc_entry = 777002) AND (SELECT status FROM erp.document WHERE company_code = 'ZZ99' AND obj_type = 13 AND doc_entry = 777002) = 'open',
                        'SAP document untouched', '');
  SELECT doc_entry, doc_num INTO e_so, v_seq FROM erp.document WHERE company_code = 'ZZ99' AND source = 'sample' AND obj_type = 13 LIMIT 1;
  PERFORM pg_temp.expect(pg_temp.su(format('SELECT to_jsonb(erp.post_document(''ZZ99'', 13, %s))', e_so)), format('Document %s is sample test data. Nothing is posted.', v_seq), 'sample document never posts');
  INSERT INTO erp.account (company_code, acct_code, name, postable, is_control, source) VALUES ('ZZ98', '1200', 'AR', true, true, 'erp');
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, card_code, currency, total, source)
  VALUES ('ZZ98', 13, 900777003, 1, 'ar_invoice', 'open', '2026-11-09', 'X', 'AED', 100, 'erp');
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, quantity, price, line_total, vat) VALUES ('ZZ98', 13, 900777003, 0, 'X', 1, 100, 100, 0);
  PERFORM pg_temp.expect(pg_temp.su('SELECT to_jsonb(erp.post_document(''ZZ98'', 13, 900777003))'),
    'G/L account for ''Domestic accounts receivable'' is not set for ZZ98. Ask Finance to set it in Setup › Financials › G/L Account Determination.', 'company without G/L determination: posting refused (receivable)');
  INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code) VALUES ('ZZ98', 'sales', 'domestic_ar', '1200');
  PERFORM pg_temp.expect(pg_temp.su('SELECT to_jsonb(erp.post_document(''ZZ98'', 13, 900777003))'),
    'G/L account for ''Revenue'' is not set for ZZ98. Ask Finance to set it in Setup › Financials › G/L Account Determination.', 'company without G/L determination: posting refused (Revenue)');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.journal_entry WHERE company_code = 'ZZ98'), 'nothing posted for ZZ98', '');

  -- ---------- A2 sales orders: posting date must be in an open period ----------
  PERFORM pg_temp.period(fin, '2026-11', 'closed');
  r := pg_temp.call(sales, format('SELECT erp.sales_order_save(''ZZ99'', NULL, %L::jsonb, %L::jsonb)',
         '{"card_code":"C0011","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":1,"tax_code":"SR"}]'));
  PERFORM pg_temp.expect(r, 'Posting period 2026-11 is closed, so nothing can be posted on 09 Nov 2026. Choose a date in an open period, or ask Finance to reopen it.', 'sales order in a closed period refused');
  PERFORM pg_temp.period(fin, '2026-11', 'open');
  r := pg_temp.call(sales, format('SELECT erp.sales_order_save(''ZZ99'', NULL, %L::jsonb, %L::jsonb)',
         '{"card_code":"C0011","doc_date":"2026-11-09","whs_code":"WH01"}', '[{"item_code":"SMP-1010","qty":1,"tax_code":"SR"}]'));
  e_so := (r->>'doc_entry')::integer;
  PERFORM pg_temp.check(e_so IS NOT NULL, 'sales order in an open period saves', r::text);
  PERFORM pg_temp.period(fin, '2026-11', 'locked');
  PERFORM pg_temp.expect(pg_temp.call(sales, format('SELECT erp.sales_order_submit(''ZZ99'', %s, NULL)', e_so)),
    'Posting period 2026-11 is locked, so nothing can be posted on 09 Nov 2026. Choose a date in an open period.', 'sales order submit in a locked period refused');
  r := pg_temp.call(sales, format('SELECT erp.sales_order_cancel(''ZZ99'', %s, ''Period locked'')', e_so));
  PERFORM pg_temp.check(r->>'state' = 'cancelled', 'cancelling is never blocked by the period', r::text);
  PERFORM pg_temp.period(fin, '2026-11', 'open');
  r := pg_temp.su($q$WITH x AS (INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, currency, total, source)
                    VALUES ('ZZ98', 17, 900777004, 2, 'sales_order', 'draft', '2019-01-01', 'AED', 0, 'erp') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r::text = '1', 'company without a calendar: documents are not period-checked (A2 behaviour kept)', r::text);
  r := pg_temp.su($q$WITH x AS (INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, currency, total, source)
                    VALUES ('ZZ99', 17, 777003, 777003, 'sales_order', 'open', '2019-01-01', 'AED', 0, 'sap') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r::text = '1', 'SAP rows are never period-checked', r::text);
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a3_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a3_result;
ROLLBACK;
