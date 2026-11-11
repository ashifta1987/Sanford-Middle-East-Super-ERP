
-- ============ 4. Conversion Differences (Financials › Exchange Rates and Revaluation › Conversion Differences) ============
-- Super ERP journal lines carry their system currency amount rounded per line, so an account or a partner can end with a
-- local currency balance of 0 and a small system currency balance. This window finds them (as of a date: lines dated on or
-- before it that carry system currency amounts) and posts one correcting journal in the system currency only (no LC
-- effect): each row is cleared against general / conversion_diff. SAP Business One journals are not touched (SAP keeps its
-- own). Period lock through post_journal; Financials full; audited; reports stay in LC.
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort, tab, ctx, store, control_ok, used_in) VALUES
  ('general', 'conversion_diff', 'Conversion differences (system currency)', 84, 'general', false, NULL, false,
     'Financials › Conversion Differences: rounding differences in the system currency')
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, tab = EXCLUDED.tab, ctx = EXCLUDED.ctx,
  store = EXCLUDED.store, control_ok = EXCLUDED.control_ok, used_in = EXCLUDED.used_in;

-- SAMPLE account for the test company ZZ99 only (real companies enter theirs in G/L Account Determination › General).
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', '7120', '7120', 'Conversion differences (SAMPLE)', '4000', 2, true, 'other', 7, 'AED', false, false, 0, 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT DO NOTHING;
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', 'general', 'conversion_diff', '7120', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = '7120')
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS erp.conv_diff_run (
    run_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    doc_no         text,
    run_date       date NOT NULL,
    accounts       boolean NOT NULL,
    partners       boolean NOT NULL,
    sys_currency   varchar(3) NOT NULL,
    debit          numeric(19,2) NOT NULL DEFAULT 0,              -- system currency
    credit         numeric(19,2) NOT NULL DEFAULT 0,
    acct_code      varchar(15),                                   -- the conversion difference account (when a net is posted)
    trans_id       integer,
    memo           text,
    state          text NOT NULL DEFAULT 'posted' CHECK (state IN ('posted', 'cancelled')),
    cancel_trans_id integer,
    cancel_reason  text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_by   uuid,
    cancelled_at   timestamptz
);

CREATE TABLE IF NOT EXISTS erp.conv_diff_line (
    run_id         bigint NOT NULL REFERENCES erp.conv_diff_run ON DELETE CASCADE,
    line_no        integer NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('account', 'partner')),
    acct_code      varchar(15) NOT NULL,
    card_code      varchar(15),
    lc_balance     numeric(19,2) NOT NULL,
    sc_balance     numeric(19,2) NOT NULL,                        -- what the correction clears (system currency)
    journals       integer NOT NULL,
    PRIMARY KEY (run_id, line_no)
);

ALTER TABLE erp.conv_diff_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.conv_diff_line ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.conv_diff_run, erp.conv_diff_line FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.conv_diff_run, erp.conv_diff_line TO authenticated;
DROP POLICY IF EXISTS conv_diff_run_read ON erp.conv_diff_run;
CREATE POLICY conv_diff_run_read ON erp.conv_diff_run FOR SELECT TO authenticated USING (erp.can_see(company_code) AND erp.can_read('finance'));
DROP POLICY IF EXISTS conv_diff_line_read ON erp.conv_diff_line;
CREATE POLICY conv_diff_line_read ON erp.conv_diff_line FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.conv_diff_run r WHERE r.run_id = conv_diff_line.run_id AND erp.can_see(r.company_code) AND erp.can_read('finance')));

CREATE OR REPLACE VIEW erp.conv_diff_list WITH (security_invoker = true) AS
SELECT r.run_id, r.company_code, coalesce(r.doc_no, 'CVD-' || r.run_id) AS doc_no, r.run_date, r.accounts, r.partners, r.sys_currency,
       r.debit, r.credit, r.trans_id, r.cancel_trans_id, r.state, r.memo, r.created_at,
       (SELECT display_name FROM erp.app_user WHERE user_id = r.created_by) AS created_by_name,
       (SELECT count(*) FROM erp.conv_diff_line l WHERE l.run_id = r.run_id) AS lines
  FROM erp.conv_diff_run r;
REVOKE ALL ON erp.conv_diff_list FROM PUBLIC, anon;
GRANT SELECT ON erp.conv_diff_list TO authenticated;

-- Accounts (non-control lines, or control lines without a partner) and partners (control account + short name) whose
-- Super ERP lines up to p_date carrying system currency amounts net to 0 in LC but not in the system currency.
CREATE OR REPLACE FUNCTION erp._cvd_rows(p_company varchar, p_date date, p_accounts boolean, p_partners boolean, p_skip text)
RETURNS TABLE (kind text, acct_code varchar, acct_name text, card_code varchar, card_name text, lc_balance numeric, sc_balance numeric, journals bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH l AS (
    SELECT CASE WHEN a.is_control AND l.short_name IS NOT NULL AND l.short_name <> l.acct_code THEN 'partner' ELSE 'account' END AS kind,
           l.acct_code, CASE WHEN a.is_control AND l.short_name IS NOT NULL AND l.short_name <> l.acct_code THEN l.short_name END AS card_code,
           l.debit - l.credit AS lc, coalesce(l.sys_debit, 0) - coalesce(l.sys_credit, 0) AS sc, l.trans_id
      FROM erp.journal_line l
      JOIN erp.journal_entry j ON j.company_code = l.company_code AND j.trans_id = l.trans_id
      JOIN erp.account a ON a.company_code = l.company_code AND a.acct_code = l.acct_code
     WHERE l.company_code = p_company AND j.source = 'erp' AND j.ref_date <= p_date
       AND (l.sys_debit IS NOT NULL OR l.sys_credit IS NOT NULL)
       AND l.acct_code IS DISTINCT FROM p_skip
  )
  SELECT l.kind, l.acct_code, (SELECT name FROM erp.account WHERE company_code = p_company AND acct_code = l.acct_code),
         l.card_code, (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = l.card_code),
         round(sum(l.lc), 2), round(sum(l.sc), 2), count(DISTINCT l.trans_id)
    FROM l
   WHERE (l.kind = 'account' AND p_accounts) OR (l.kind = 'partner' AND p_partners)
   GROUP BY l.kind, l.acct_code, l.card_code
  HAVING round(sum(l.lc), 2) = 0 AND round(sum(l.sc), 2) <> 0
   ORDER BY l.kind, l.acct_code, l.card_code
$$;

-- Validate a request and compute the rows. Never writes. p_in: {date, accounts (default true), partners (default true)}.
CREATE OR REPLACE FUNCTION erp._cvd_eval(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_in   jsonb := coalesce(p_in, '{}'::jsonb);
  v_lc   text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_sc   text := erp._sys_cur(p_company);
  v_date date;
  v_acc  boolean := coalesce((v_in->>'accounts')::boolean, true);
  v_bp   boolean := coalesce((v_in->>'partners')::boolean, true);
  v_acct text := erp.gl_account(p_company, 'general', 'conversion_diff', false);
  v_rows jsonb;
BEGIN
  IF v_sc IS NULL THEN
    RAISE EXCEPTION 'Conversion differences need a system currency. % uses its local currency % as the system currency, so there is nothing to convert. Set one in Administration › Company Details.',
      p_company, v_lc USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_date := nullif(btrim(v_in->>'date'), '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the date as YYYY-MM-DD.' USING ERRCODE = 'P0001';
  END;
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Choose the posting date.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_acc AND NOT v_bp THEN
    RAISE EXCEPTION 'Choose G/L accounts, business partners or both.' USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_rows FROM erp._cvd_rows(p_company, v_date, v_acc, v_bp, v_acct) r;
  RETURN jsonb_build_object(
    'date', v_date, 'accounts', v_acc, 'partners', v_bp, 'local_currency', v_lc, 'sys_currency', v_sc, 'acct_code', v_acct, 'rows', v_rows,
    'totals', jsonb_build_object(
      'rows', jsonb_array_length(v_rows),
      -- the correction: a positive balance is credited, a negative one debited
      'debit', coalesce((SELECT -sum((r->>'sc_balance')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'sc_balance')::numeric < 0), 0),
      'credit', coalesce((SELECT sum((r->>'sc_balance')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'sc_balance')::numeric > 0), 0),
      'net', coalesce((SELECT sum((r->>'sc_balance')::numeric) FROM jsonb_array_elements(v_rows) r), 0)));
END $$;

-- Setup for the screen (Financials read): currencies, the account, history.
CREATE OR REPLACE FUNCTION erp.conversion_diff_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'post conversion differences');
BEGIN
  RETURN jsonb_build_object(
    'company_code', p_company,
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'sys_currency', coalesce(erp._sys_cur(p_company), (SELECT currency FROM erp.company WHERE company_code = p_company)),
    'active', erp._sys_cur(p_company) IS NOT NULL,
    'can_write', erp.can_write('finance'),
    'acct_code', erp.gl_account(p_company, 'general', 'conversion_diff', false),
    'history', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.run_date DESC, l.run_id DESC) FROM erp.conv_diff_list l WHERE l.company_code = p_company), '[]'::jsonb));
END $$;

-- Preview (Financials full).
CREATE OR REPLACE FUNCTION erp.conversion_diff_preview(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, true, 'post conversion differences');
BEGIN
  RETURN erp._cvd_eval(p_company, p_in);
END $$;

-- Post the correcting journal in the system currency only. p_in: preview input + {memo}.
CREATE OR REPLACE FUNCTION erp.conversion_diff_post(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user := erp._je_guard(p_company, true, 'post conversion differences');
  v_in    jsonb := coalesce(p_in, '{}'::jsonb);
  e       jsonb;
  v_date  date;
  v_memo  text := nullif(btrim(v_in->>'memo'), '');
  v_net   numeric;
  v_acct  text;
  v_lines jsonb := '[]';
  v_id    bigint;
  v_no    text;
  v_trans integer;
  x       record;
  i       integer := 0;
BEGIN
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  e := erp._cvd_eval(p_company, v_in);
  v_date := (e->>'date')::date;
  IF jsonb_array_length(e->'rows') = 0 THEN
    RAISE EXCEPTION 'There are no conversion differences in % up to %.', p_company, erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  v_net := (e->'totals'->>'net')::numeric;
  IF v_net <> 0 THEN
    v_acct := erp.gl_account(p_company, 'general', 'conversion_diff');
  END IF;

  INSERT INTO erp.conv_diff_run (company_code, run_date, accounts, partners, sys_currency, debit, credit, acct_code, memo, created_by)
  VALUES (p_company, v_date, (e->>'accounts')::boolean, (e->>'partners')::boolean, e->>'sys_currency',
          (e->'totals'->>'debit')::numeric, (e->'totals'->>'credit')::numeric, v_acct, v_memo, u.user_id)
  RETURNING run_id INTO v_id;
  v_no := 'CVD-' || v_id;
  UPDATE erp.conv_diff_run SET doc_no = v_no WHERE run_id = v_id;

  FOR x IN SELECT * FROM jsonb_to_recordset(e->'rows') AS y(kind text, acct_code text, card_code text, lc_balance numeric, sc_balance numeric, journals integer) LOOP
    i := i + 1;
    INSERT INTO erp.conv_diff_line (run_id, line_no, kind, acct_code, card_code, lc_balance, sc_balance, journals)
    VALUES (v_id, i, x.kind, x.acct_code, x.card_code, x.lc_balance, x.sc_balance, x.journals);
    v_lines := v_lines || jsonb_build_object('acct_code', x.acct_code, 'short_name', x.card_code,
      CASE WHEN x.sc_balance > 0 THEN 'sys_credit' ELSE 'sys_debit' END, abs(x.sc_balance),
      'memo', format('Conversion difference %s %s', coalesce(x.card_code, x.acct_code), erp._money(x.sc_balance)));
  END LOOP;
  IF v_net > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_acct, 'sys_debit', v_net, 'memo', 'Conversion differences');
  ELSIF v_net < 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_acct, 'sys_credit', -v_net, 'memo', 'Conversion differences');
  END IF;
  v_trans := erp.post_journal(p_company, v_date, coalesce(v_memo, format('Conversion differences %s · %s', erp._day(v_date), e->>'sys_currency')), v_lines,
    jsonb_build_object('trans_type', 30, 'ref1', v_no, 'ref2', 'Conversion differences', 'base_ref', v_no, 'allow_control', true, 'sys_only', true,
                       'action', 'conversion_diff_journal', 'object', 'conversion_diff', 'object_ref', v_id::text));
  UPDATE erp.conv_diff_run SET trans_id = v_trans WHERE run_id = v_id;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'conversion_diff_post', 'conversion_diff', v_id::text,
          jsonb_build_object('doc_no', v_no, 'date', v_date, 'sys_currency', e->>'sys_currency', 'rows', i, 'debit', e->'totals'->'debit',
                             'credit', e->'totals'->'credit', 'net', v_net, 'trans_id', v_trans));
  RETURN jsonb_build_object('run_id', v_id, 'doc_no', v_no, 'date', v_date, 'trans_id', v_trans, 'rows', i, 'net', v_net,
                            'sys_currency', e->>'sys_currency');
END $$;

-- Cancel a run: reverses its journal on the run date (system currency only). The period must be open.
CREATE OR REPLACE FUNCTION erp.conversion_diff_cancel(p_company varchar, p_run_id bigint, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user := erp._je_guard(p_company, true, 'post conversion differences');
  r      erp.conv_diff_run;
  v_note text := nullif(btrim(p_reason), '');
  v_t    integer;
BEGIN
  SELECT * INTO r FROM erp.conv_diff_run WHERE run_id = p_run_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversion difference run % was not found in %.', coalesce(p_run_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF r.state = 'cancelled' THEN
    RAISE EXCEPTION 'Conversion difference run % is already cancelled.', r.doc_no USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a reason for cancelling the run.' USING ERRCODE = 'P0001';
  END IF;
  v_t := erp._reverse_journal(p_company, r.trans_id, r.run_date, format('Cancellation of %s: %s', r.doc_no, v_note), 'conversion_diff_cancel');
  UPDATE erp.conv_diff_run SET state = 'cancelled', cancel_trans_id = v_t, cancel_reason = v_note, cancelled_by = u.user_id, cancelled_at = now()
   WHERE run_id = p_run_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'conversion_diff_cancel', 'conversion_diff', p_run_id::text,
          jsonb_build_object('doc_no', r.doc_no, 'date', r.run_date, 'reason', v_note, 'trans_id', v_t));
  RETURN jsonb_build_object('run_id', p_run_id, 'doc_no', r.doc_no, 'state', 'cancelled', 'trans_id', v_t);
END $$;

-- One run with its lines, journals (LC and system currency amounts) and activity (Financials read).
CREATE OR REPLACE FUNCTION erp.conversion_diff_info(p_company varchar, p_run_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'post conversion differences');
  r erp.conv_diff_run;
BEGIN
  SELECT * INTO r FROM erp.conv_diff_run WHERE run_id = p_run_id AND company_code = p_company;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN to_jsonb(r) || jsonb_build_object(
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'created_by_name', erp._adm_name(r.created_by), 'cancelled_by_name', erp._adm_name(r.cancelled_by),
    'can_cancel', r.state = 'posted' AND erp.can_write('finance'),
    'lines', coalesce((SELECT jsonb_agg(to_jsonb(l) || jsonb_build_object(
                         'acct_name', (SELECT name FROM erp.account WHERE company_code = p_company AND acct_code = l.acct_code),
                         'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = l.card_code)) ORDER BY l.line_no)
                         FROM erp.conv_diff_line l WHERE l.run_id = r.run_id), '[]'::jsonb),
    'journals', coalesce((SELECT jsonb_agg(jsonb_build_object('trans_id', j.trans_id, 'ref_date', j.ref_date, 'memo', j.memo, 'total', j.total_local, 'total_sys', j.total_sys,
                                                              'lines', (SELECT jsonb_agg(jsonb_build_object('acct_code', jl.acct_code, 'short_name', jl.short_name,
                                                                                                             'debit', jl.debit, 'credit', jl.credit, 'sys_debit', jl.sys_debit,
                                                                                                             'sys_credit', jl.sys_credit, 'memo', jl.memo) ORDER BY jl.line_id)
                                                                          FROM erp.journal_line jl WHERE jl.company_code = j.company_code AND jl.trans_id = j.trans_id))
                                           ORDER BY j.ref_date, j.trans_id)
                            FROM erp.journal_entry j
                           WHERE j.company_code = p_company AND j.trans_id = ANY (array_remove(ARRAY[r.trans_id, r.cancel_trans_id], NULL))), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', coalesce(au.display_name, a.actor)) ORDER BY a.at, a.audit_id)
                            FROM erp.audit_log a LEFT JOIN erp.app_user au ON au.user_id::text = a.actor
                           WHERE a.company_code = p_company AND a.object = 'conversion_diff' AND a.object_ref = r.run_id::text), '[]'::jsonb));
END $$;

-- ============ 5. Grants ============
REVOKE ALL ON FUNCTION
  erp._sys_cur(varchar), erp._sys_cur_used(varchar), erp._cvd_rows(varchar, date, boolean, boolean, text), erp._cvd_eval(varchar, jsonb)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  erp.system_currency_info(varchar), erp.system_currency_save(varchar, text),
  erp.conversion_diff_setup(varchar), erp.conversion_diff_preview(varchar, jsonb), erp.conversion_diff_post(varchar, jsonb),
  erp.conversion_diff_cancel(varchar, bigint, text), erp.conversion_diff_info(varchar, bigint)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  erp.system_currency_info(varchar), erp.system_currency_save(varchar, text),
  erp.conversion_diff_setup(varchar), erp.conversion_diff_preview(varchar, jsonb), erp.conversion_diff_post(varchar, jsonb),
  erp.conversion_diff_cancel(varchar, bigint, text), erp.conversion_diff_info(varchar, bigint)
TO authenticated;
