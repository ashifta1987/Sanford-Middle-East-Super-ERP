-- A3 · Posting engine (Financials). Safe to run twice. Does not edit 10–17.
--
-- Super ERP documents and manual journals post balanced journal entries, using G/L account determination and VAT.
-- Posted journals stay permanent (trigger in 10): corrections are reversals. SAP-sourced documents and journals never post
-- or change here (source = 'sap' rows are read-only).
--
-- Objects:
--   erp.gl_posting_key      – the rows of Setup › Financials › G/L Account Determination (design-data.json › GLD)
--   erp.gl_determination    – account per company and posting key. Filled from SAP (OACP/OGAR) at migration; ZZ99 sample only
--   erp.posting_period      – period calendar: open / closed / locked. ZZ99 sample only
--   erp.erp_trans_id_seq    – ERP trans_id values from 900000000 up (never collide with SAP TransId)
--   erp.journal_draft(_line)– manual journals before posting: draft → pending_approval → posted / rejected / cancelled
--   erp.document_posting    – which journal a Super ERP document posted (no double posting; A4 cancels by reversal)
--   erp.approval_rule       – existing (17); rule_code gets 'journal_amount' (obj_type 30)
--   erp.journal_draft_list  – view for the drafts list, security_invoker
--   internal                – _period_message, gl_account, _je_lines_eval, post_journal, _reverse_journal, post_document,
--                             _je_guard, _je_eval, _je_lock, _doc_period_guard (trigger)
--   API                     – journal_setup / checks / draft_save / submit / decide / draft_cancel / draft_info,
--                             journal_info, journal_reverse, period_set_status, period_add_year, gl_determination_set,
--                             approval_inbox (replaced: sales orders as in 17, plus journals)
--
-- A2 change (made here, 17 untouched): a Super ERP document's posting date must be in an open period when its company
-- has a period calendar (trigger on erp.document, source = 'erp' only; cancelling is never blocked).
--
-- Business values (accounts, periods, the journal approval limit) are seeded for the sample company ZZ99 only and marked
-- SAMPLE. Real companies start empty and posting refuses with a message naming what is missing (A3 walkthrough › Needs from Ashif).

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.gl_posting_key (
    area           text NOT NULL CHECK (area IN ('sales', 'purchasing', 'general', 'inventory', 'resources')),
    posting_key    text NOT NULL,
    label          text NOT NULL,                     -- as in SAP's G/L Account Determination window
    sort           smallint NOT NULL,
    PRIMARY KEY (area, posting_key)
);

CREATE TABLE IF NOT EXISTS erp.gl_determination (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    area           text NOT NULL,
    posting_key    text NOT NULL,
    acct_code      varchar(15) NOT NULL,
    source         text NOT NULL DEFAULT 'erp',        -- 'sap' = from OACP/OGAR (read-only), 'erp' = set in Super ERP, 'sample' = ZZ99
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, area, posting_key),
    FOREIGN KEY (area, posting_key) REFERENCES erp.gl_posting_key,
    FOREIGN KEY (company_code, acct_code) REFERENCES erp.account ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.posting_period (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    period_code    text NOT NULL,                     -- e.g. 2026-11
    from_date      date NOT NULL,
    to_date        date NOT NULL,
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'locked')),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    note           text,
    PRIMARY KEY (company_code, period_code),
    CHECK (from_date <= to_date)
);
CREATE INDEX IF NOT EXISTS posting_period_dates_idx ON erp.posting_period (company_code, from_date, to_date);

CREATE SEQUENCE IF NOT EXISTS erp.erp_trans_id_seq AS integer START WITH 900000000 MINVALUE 900000000 MAXVALUE 2147483647;

CREATE TABLE IF NOT EXISTS erp.journal_draft (
    draft_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    ref_date       date,                              -- posting date
    due_date       date,
    memo           text,
    ref1           text,
    ref2           text,
    state          text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'pending_approval', 'posted', 'rejected', 'cancelled')),
    total          numeric(19,2) NOT NULL DEFAULT 0,  -- sum of debits
    currency       varchar(3),
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    submitted_by   uuid,
    submitted_at   timestamptz,
    reason         text,
    decided_at     timestamptz,
    cancelled_by   uuid,
    cancelled_at   timestamptz,
    cancel_note    text,
    trans_id       integer,                           -- the posted journal (no FK: posted journals are never deleted by the app)
    posted_at      timestamptz
);
CREATE INDEX IF NOT EXISTS journal_draft_company_idx ON erp.journal_draft (company_code, state);

CREATE TABLE IF NOT EXISTS erp.journal_draft_line (
    draft_id       integer NOT NULL REFERENCES erp.journal_draft ON DELETE CASCADE,
    line_num       integer NOT NULL,
    company_code   varchar(8) NOT NULL,
    acct_code      varchar(15),
    debit          numeric(19,2) NOT NULL DEFAULT 0,
    credit         numeric(19,2) NOT NULL DEFAULT 0,
    memo           text,
    PRIMARY KEY (draft_id, line_num)
);

CREATE TABLE IF NOT EXISTS erp.document_posting (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,
    trans_id       integer NOT NULL,
    posted_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, obj_type, doc_entry),
    UNIQUE (company_code, trans_id)
);

-- One reversal per Super ERP journal (SAP rows are not constrained).
CREATE UNIQUE INDEX IF NOT EXISTS journal_entry_erp_reversal_uniq ON erp.journal_entry (company_code, reversal_of)
  WHERE source = 'erp' AND reversal_of IS NOT NULL;

-- Manual journal approval rule (amount above the requester's limit).
ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount'));

-- ============ Reference rows: G/L Account Determination keys (same order as design-data.json › GLD) ============
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort) VALUES
  ('sales', 'domestic_ar', 'Domestic accounts receivable', 1),
  ('sales', 'revenue', 'Revenue', 2),
  ('sales', 'sales_returns', 'Sales returns', 3),
  ('sales', 'down_payment_clearing', 'Down payment clearing', 4),
  ('sales', 'output_vat', 'Output VAT', 5),
  ('sales', 'fx_gain', 'Exchange rate gains', 6),
  ('purchasing', 'domestic_ap', 'Domestic accounts payable', 7),
  ('purchasing', 'foreign_ap', 'Foreign accounts payable', 8),
  ('purchasing', 'down_payments', 'Down payments (deposits)', 9),
  ('purchasing', 'input_vat', 'Input VAT', 10),
  ('purchasing', 'goods_in_transit', 'Goods in transit', 11),
  ('purchasing', 'landed_cost_clearing', 'Landed cost clearing', 12),
  ('purchasing', 'fx_loss', 'Exchange rate losses', 13),
  ('general', 'rounding', 'Rounding', 14),
  ('general', 'bank_charges', 'Bank charges', 15),
  ('general', 'opening_balances', 'Opening balances', 16),
  ('inventory', 'inventory', 'Inventory', 17),
  ('inventory', 'cogs', 'Cost of goods sold', 18),
  ('inventory', 'count_variance', 'Stock count variance', 19),
  ('inventory', 'price_difference', 'Price difference', 20),
  ('inventory', 'inventory_revaluation', 'Inventory revaluation', 21),
  ('resources', 'resource_cost', 'Resource cost', 22)
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort;

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.gl_posting_key ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.gl_determination ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.posting_period ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.journal_draft ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.journal_draft_line ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.document_posting ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.gl_posting_key, erp.gl_determination, erp.posting_period, erp.journal_draft, erp.journal_draft_line, erp.document_posting
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.gl_posting_key, erp.gl_determination, erp.posting_period, erp.journal_draft, erp.journal_draft_line, erp.document_posting
  TO authenticated;
REVOKE ALL ON SEQUENCE erp.erp_trans_id_seq FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS gl_posting_key_read ON erp.gl_posting_key;
CREATE POLICY gl_posting_key_read ON erp.gl_posting_key FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS gl_determination_read ON erp.gl_determination;
CREATE POLICY gl_determination_read ON erp.gl_determination FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.can_read('finance')));
DROP POLICY IF EXISTS posting_period_read ON erp.posting_period;
CREATE POLICY posting_period_read ON erp.posting_period FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS journal_draft_read ON erp.journal_draft;
CREATE POLICY journal_draft_read ON erp.journal_draft FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.can_read('finance')));
DROP POLICY IF EXISTS journal_draft_line_read ON erp.journal_draft_line;
CREATE POLICY journal_draft_line_read ON erp.journal_draft_line FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.can_read('finance')));
DROP POLICY IF EXISTS document_posting_read ON erp.document_posting;
CREATE POLICY document_posting_read ON erp.document_posting FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('finance')) OR (SELECT erp.can_read('sales')) OR (SELECT erp.can_read('purchase'))));

CREATE OR REPLACE VIEW erp.journal_draft_list WITH (security_invoker = true) AS
SELECT company_code, draft_id, ref_date, memo, ref1, state, total, currency, created_at, submitted_at, trans_id
  FROM erp.journal_draft;
REVOKE ALL ON erp.journal_draft_list FROM PUBLIC, anon;
GRANT SELECT ON erp.journal_draft_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
CREATE OR REPLACE FUNCTION erp._day(p date) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT to_char(p, 'DD Mon YYYY')
$$;

-- The reason nothing can be posted on p_date in p_company, or NULL when the date is in an open period.
-- p_require = false (documents): a company with no calendar at all is not checked.
CREATE OR REPLACE FUNCTION erp._period_message(p_company varchar, p_date date, p_require boolean) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  pp erp.posting_period;
BEGIN
  IF p_date IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO pp FROM erp.posting_period
   WHERE company_code = p_company AND p_date BETWEEN from_date AND to_date ORDER BY from_date LIMIT 1;
  IF NOT FOUND THEN
    IF NOT p_require AND NOT EXISTS (SELECT 1 FROM erp.posting_period WHERE company_code = p_company) THEN
      RETURN NULL;
    END IF;
    RETURN format('No posting period covers %s in %s. Ask Finance to add it in Administration › System Initialization › Posting Periods.',
                  erp._day(p_date), p_company);
  END IF;
  IF pp.status = 'closed' THEN
    RETURN format('Posting period %s is closed, so nothing can be posted on %s. Choose a date in an open period, or ask Finance to reopen it.',
                  pp.period_code, erp._day(p_date));
  ELSIF pp.status = 'locked' THEN
    RETURN format('Posting period %s is locked, so nothing can be posted on %s. Choose a date in an open period.',
                  pp.period_code, erp._day(p_date));
  END IF;
  RETURN NULL;
END $$;

-- The account for a posting key, or the message saying it is not set (p_raise = true raises it).
CREATE OR REPLACE FUNCTION erp.gl_account(p_company varchar, p_area text, p_key text, p_raise boolean DEFAULT true) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_acct  text;
  v_label text;
BEGIN
  SELECT label INTO v_label FROM erp.gl_posting_key WHERE area = p_area AND posting_key = p_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown posting key %/%.', p_area, p_key USING ERRCODE = 'P0001';
  END IF;
  SELECT acct_code INTO v_acct FROM erp.gl_determination WHERE company_code = p_company AND area = p_area AND posting_key = p_key;
  IF v_acct IS NULL AND p_raise THEN
    RAISE EXCEPTION '%', format('G/L account for ''%s'' is not set for %s. Ask Finance to set it in Setup › Financials › G/L Account Determination.',
                                v_label, p_company) USING ERRCODE = 'P0001';
  END IF;
  RETURN v_acct;
END $$;

-- Validate journal lines. Never writes. Returns {errors:[{line, field, message}], lines:[normalised], debit, credit}.
-- A line names acct_code, or area + posting_key (resolved through G/L account determination).
-- p_allow_control = false for manual journals: control accounts (customers / suppliers) need a business partner document.
CREATE OR REPLACE FUNCTION erp._je_lines_eval(p_company varchar, p_lines jsonb, p_allow_control boolean) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_err   jsonb := '[]';
  v_out   jsonb := '[]';
  l       jsonb;
  i       integer := 0;
  n       text;
  a       erp.account;
  v_code  text;
  v_label text;
  v_d     numeric;
  v_c     numeric;
  v_ok    boolean;
  v_dt    numeric := 0;
  v_ct    numeric := 0;
BEGIN
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_ok := true;
    v_code := nullif(btrim(l->>'acct_code'), '');
    IF v_code IS NULL AND nullif(btrim(l->>'posting_key'), '') IS NOT NULL THEN
      v_code := erp.gl_account(p_company, l->>'area', l->>'posting_key', false);
      IF v_code IS NULL THEN
        SELECT label INTO v_label FROM erp.gl_posting_key WHERE area = l->>'area' AND posting_key = l->>'posting_key';
        v_err := v_err || jsonb_build_object('line', i, 'field', 'acct_code', 'message',
          format('G/L account for ''%s'' is not set for %s. Ask Finance to set it in Setup › Financials › G/L Account Determination.',
                 coalesce(v_label, l->>'posting_key'), p_company));
        v_ok := false;
      END IF;
    ELSIF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'acct_code', 'message', n || 'choose an account.');
      v_ok := false;
    END IF;
    IF v_code IS NOT NULL THEN
      SELECT * INTO a FROM erp.account WHERE company_code = p_company AND acct_code = v_code;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'acct_code', 'message', n || format('account %s does not exist in %s. Check the account code.', v_code, p_company));
        v_ok := false;
      ELSIF NOT a.postable THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'acct_code', 'message', n || format('%s · %s is a title account. Choose a postable account.', v_code, a.name));
        v_ok := false;
      ELSIF a.frozen THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'acct_code', 'message', n || format('%s · %s is frozen. Choose another account, or ask Finance to unfreeze it.', v_code, a.name));
        v_ok := false;
      ELSIF a.is_control AND NOT p_allow_control THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'acct_code', 'message', n || format('%s · %s is a control account for customers or suppliers. Post to it through a business partner document.', v_code, a.name));
        v_ok := false;
      END IF;
    END IF;

    v_d := CASE WHEN nullif(btrim(l->>'debit'), '') IS NULL THEN 0 ELSE erp._num(l->>'debit') END;
    v_c := CASE WHEN nullif(btrim(l->>'credit'), '') IS NULL THEN 0 ELSE erp._num(l->>'credit') END;
    IF v_d IS NULL OR v_c IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'amounts must be numbers.');
      v_ok := false;
    ELSIF v_d < 0 OR v_c < 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'amounts can''t be negative.');
      v_ok := false;
    ELSE
      v_d := round(v_d, 2);
      v_c := round(v_c, 2);
      IF v_d > 0 AND v_c > 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'enter a debit or a credit, not both.');
        v_ok := false;
      ELSIF v_d = 0 AND v_c = 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'enter a debit or a credit amount.');
        v_ok := false;
      END IF;
    END IF;

    IF v_d IS NOT NULL AND v_c IS NOT NULL AND v_d >= 0 AND v_c >= 0 THEN
      v_dt := v_dt + v_d;
      v_ct := v_ct + v_c;
    END IF;
    IF v_ok THEN
      v_out := v_out || jsonb_build_object('line_id', i - 1, 'acct_code', v_code, 'acct_name', a.name, 'debit', v_d, 'credit', v_c,
        'memo', nullif(btrim(l->>'memo'), ''), 'short_name', coalesce(nullif(btrim(l->>'short_name'), ''), v_code),
        'tax_code', nullif(btrim(l->>'tax_code'), ''), 'cost_centre', nullif(btrim(l->>'cost_centre'), ''));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('errors', v_err, 'lines', v_out, 'debit', v_dt, 'credit', v_ct, 'count', i);
END $$;

-- Post one balanced journal. Internal: callers check the user and the module first.
-- p_source_ref: {trans_type (30 = manual), ref1, ref2, ref3, base_ref, reversal_of, due_date, tax_date, allow_control,
--                action (audit action, default journal_post), object, object_ref}
-- Checks the period is open, every account exists / is postable / is not frozen, and debit = credit. Allocates trans_id
-- from 900000000 up and inserts journal_entry + journal_line in ONE statement (the balance trigger in 10 requires it).
CREATE OR REPLACE FUNCTION erp.post_journal(p_company varchar, p_date date, p_memo text, p_lines jsonb, p_source_ref jsonb DEFAULT '{}')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s       jsonb := coalesce(p_source_ref, '{}'::jsonb);
  e       jsonb;
  v_msg   text;
  v_cur   text;
  v_trans integer;
  v_nerr  integer;
  v_d     numeric;
  v_c     numeric;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Company % does not exist.', coalesce(p_company, '(none)') USING ERRCODE = 'P0001';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Choose a posting date.' USING ERRCODE = 'P0001';
  END IF;
  v_msg := erp._period_message(p_company, p_date, true);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;

  e := erp._je_lines_eval(p_company, p_lines, coalesce((s->>'allow_control')::boolean, false));
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this journal.', v_nerr - 1) ELSE '' END;
  END IF;
  IF (e->>'count')::integer < 2 THEN
    RAISE EXCEPTION 'Add at least two lines.' USING ERRCODE = 'P0001';
  END IF;
  v_d := (e->>'debit')::numeric;
  v_c := (e->>'credit')::numeric;
  IF v_d <> v_c THEN
    RAISE EXCEPTION '%', format('Debits %s and credits %s don''t balance. Difference %s %s.', erp._money(v_d), erp._money(v_c), erp._money(abs(v_d - v_c)), v_cur)
      USING ERRCODE = 'P0001';
  END IF;

  v_trans := nextval('erp.erp_trans_id_seq');
  WITH je AS (
    INSERT INTO erp.journal_entry (company_code, trans_id, number, ref_date, due_date, tax_date, memo, ref1, ref2, ref3, trans_type, base_ref,
                                   total_local, total_sys, currency, reversal_of, source, created_on)
    VALUES (p_company, v_trans, v_trans, p_date, coalesce((s->>'due_date')::date, p_date), coalesce((s->>'tax_date')::date, p_date),
            nullif(btrim(p_memo), ''), s->>'ref1', s->>'ref2', s->>'ref3', coalesce((s->>'trans_type')::integer, 30), s->>'base_ref',
            v_d, v_d, v_cur, (s->>'reversal_of')::integer, 'erp', current_date)
    RETURNING company_code, trans_id, ref_date, due_date
  )
  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, memo, ref_date, due_date, tax_code, cost_centre)
  SELECT je.company_code, je.trans_id, x.line_id, x.acct_code, x.short_name, x.debit, x.credit, coalesce(x.memo, nullif(btrim(p_memo), '')),
         je.ref_date, je.due_date, x.tax_code, x.cost_centre
    FROM je CROSS JOIN jsonb_to_recordset(e->'lines') AS x(line_id int, acct_code text, short_name text, debit numeric, credit numeric,
                                                          memo text, tax_code text, cost_centre text);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (coalesce(erp.current_user_id()::text, 'system:posting'), p_company, coalesce(s->>'action', 'journal_post'), 'journal', v_trans::text,
          jsonb_build_object('trans_type', coalesce((s->>'trans_type')::integer, 30), 'ref_date', p_date, 'memo', p_memo, 'total', v_d,
                             'lines', (e->>'count')::integer, 'reversal_of', s->'reversal_of', 'source_object', s->'object',
                             'source_ref', s->'object_ref'));
  RETURN v_trans;
END $$;

-- The mirror entry of a journal (debit ↔ credit) on p_date. Internal: journal_reverse and A4 document cancellation call it.
CREATE OR REPLACE FUNCTION erp._reverse_journal(p_company varchar, p_trans_id integer, p_date date, p_memo text, p_action text DEFAULT 'journal_reverse')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  je    erp.journal_entry;
  v_new integer;
BEGIN
  SELECT * INTO je FROM erp.journal_entry WHERE company_code = p_company AND trans_id = p_trans_id;
  v_new := erp.post_journal(p_company, p_date, p_memo,
    (SELECT jsonb_agg(jsonb_build_object('acct_code', l.acct_code, 'short_name', l.short_name, 'debit', l.credit, 'credit', l.debit,
                                         'memo', l.memo, 'tax_code', l.tax_code, 'cost_centre', l.cost_centre) ORDER BY l.line_id)
       FROM erp.journal_line l WHERE l.company_code = p_company AND l.trans_id = p_trans_id),
    jsonb_build_object('trans_type', je.trans_type, 'reversal_of', p_trans_id, 'ref1', je.ref1, 'ref2', je.ref2,
                       'base_ref', p_trans_id::text, 'allow_control', true, 'action', p_action,
                       'object', 'journal', 'object_ref', p_trans_id::text));
  RETURN v_new;
END $$;

-- Post a Super ERP document. Internal: A4 (A/R invoice, credit memo) calls it inside its own checked function.
-- A/R invoice (13): debit receivable (customer as short name), credit revenue (line totals), credit output VAT (line VAT).
-- A/R credit memo (14): the mirror, with Sales returns instead of Revenue. Accounts come from G/L account determination.
CREATE OR REPLACE FUNCTION erp.post_document(p_company varchar, p_obj_type integer, p_doc_entry integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d       erp.document;
  v_trans integer;
  v_ar    text;
  v_rev   text;
  v_vat   text;
  v_net   numeric;
  v_vatsum numeric;
  v_sign  integer;
  v_lines jsonb;
  v_name  text;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document % was not found in company %.', p_doc_entry, p_company USING ERRCODE = 'P0001';
  END IF;
  IF d.source = 'sap' THEN
    RAISE EXCEPTION 'Document % came from SAP Business One. SAP posts its own journal entry, so nothing is posted in Super ERP.', d.doc_num
      USING ERRCODE = 'P0001';
  ELSIF d.source <> 'erp' THEN
    RAISE EXCEPTION 'Document % is sample test data. Nothing is posted.', d.doc_num USING ERRCODE = 'P0001';
  END IF;
  SELECT trans_id INTO v_trans FROM erp.document_posting WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  IF FOUND THEN
    RAISE EXCEPTION 'Document % is already posted (journal %).', d.doc_num, v_trans USING ERRCODE = 'P0001';
  END IF;
  IF p_obj_type NOT IN (13, 14) THEN
    RAISE EXCEPTION 'Posting for this document type comes in a later phase.' USING ERRCODE = 'P0001';
  END IF;

  v_sign := CASE p_obj_type WHEN 13 THEN 1 ELSE -1 END;
  v_name := CASE p_obj_type WHEN 13 THEN 'A/R invoice' ELSE 'A/R credit memo' END;
  v_ar  := erp.gl_account(p_company, 'sales', 'domestic_ar');
  v_rev := erp.gl_account(p_company, 'sales', CASE p_obj_type WHEN 13 THEN 'revenue' ELSE 'sales_returns' END);
  SELECT coalesce(sum(line_total), 0), coalesce(sum(vat), 0) INTO v_net, v_vatsum
    FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  IF v_vatsum <> 0 THEN
    v_vat := erp.gl_account(p_company, 'sales', 'output_vat');
  END IF;
  IF v_net + v_vatsum <= 0 THEN
    RAISE EXCEPTION '% % has no amount to post.', v_name, d.doc_num USING ERRCODE = 'P0001';
  END IF;

  v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_ar, 'short_name', d.card_code,
               CASE WHEN v_sign = 1 THEN 'debit' ELSE 'credit' END, round(v_net + v_vatsum, 2)));
  v_lines := v_lines || coalesce((
    SELECT jsonb_agg(jsonb_build_object('acct_code', v_rev, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(s.net, 2)))
      FROM (SELECT sum(line_total) AS net FROM erp.document_line
             WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry HAVING sum(line_total) <> 0) s), '[]'::jsonb);
  v_lines := v_lines || coalesce((
    SELECT jsonb_agg(jsonb_build_object('acct_code', v_vat, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(t.vat, 2), 'tax_code', t.tax_code)
                     ORDER BY t.tax_code)
      FROM (SELECT tax_code, sum(vat) AS vat FROM erp.document_line
             WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry GROUP BY tax_code HAVING sum(vat) <> 0) t), '[]'::jsonb);

  v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s · %s', v_name, d.doc_num, coalesce(d.card_name, d.card_code)), v_lines,
    jsonb_build_object('trans_type', p_obj_type, 'base_ref', d.doc_num::text, 'ref1', d.doc_num::text, 'ref2', d.customer_ref,
                       'due_date', d.due_date, 'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                       'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
  RETURN v_trans;
END $$;

-- Who is calling, and may they read (p_write = false) or change (p_write = true) Financials in this company?
-- p_what finishes the read-only message, e.g. 'post journals'.
CREATE OR REPLACE FUNCTION erp._je_guard(p_company varchar, p_write boolean, p_what text DEFAULT 'post journals') RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF p_write AND NOT erp.can_write('finance') THEN
    IF erp.can_read('finance') THEN
      RAISE EXCEPTION 'You have read-only access to Financials. Ask the system admin for full access to %.', p_what USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Your position does not include Financials. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF NOT p_write AND NOT erp.can_read('finance') THEN
    RAISE EXCEPTION 'Your position does not include Financials. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Validate a manual journal (header + lines) and the approval rules it triggers. Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, value, limit, message}],
--    lines:[…], header:{…}, totals:{debit, credit, difference, currency}}
-- Errors with field 'period' or 'balance' do not stop a draft from being saved; they stop posting.
CREATE OR REPLACE FUNCTION erp._je_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_position text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_err   jsonb := '[]';
  v_checks jsonb := '[]';
  e       jsonb;
  v_cur   text;
  v_date  date;
  v_due   date;
  v_msg   text;
  v_d     numeric;
  v_c     numeric;
  r       record;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF nullif(btrim(h->>'ref_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'ref_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'ref_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'ref_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'The due date is not a valid date.');
    END IF;
  END IF;

  e := erp._je_lines_eval(p_company, p_lines, false);
  v_err := v_err || (e->'errors');
  IF (e->>'count')::integer < 2 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least two lines.');
  END IF;
  v_d := (e->>'debit')::numeric;
  v_c := (e->>'credit')::numeric;

  -- Posting-only problems (a draft may still be saved with them)
  v_msg := erp._period_message(p_company, v_date, true);
  IF v_msg IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'period', 'message', v_msg);
  END IF;
  IF v_d <> v_c THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'balance', 'message',
      format('Debits %s and credits %s don''t balance. Difference %s %s.', erp._money(v_d), erp._money(v_c), erp._money(abs(v_d - v_c)), v_cur));
  END IF;

  IF jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 30 AND ar.active AND ar.rule_code = 'journal_amount'
                AND (ar.position_code = p_position OR ar.position_code IS NULL) AND ar.limit_value IS NOT NULL
              ORDER BY ar.step LOOP
      IF v_d > r.limit_value THEN
        v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
          'approver_name', r.approver_name, 'line', NULL, 'value', v_d, 'limit', r.limit_value,
          'message', format('Total %s %s is above your journal limit of %s %s. Submit it for approval.',
                            erp._money(v_d), v_cur, erp._money(r.limit_value), v_cur));
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', e->'lines',
    'header', jsonb_build_object('ref_date', v_date, 'due_date', v_due, 'memo', nullif(btrim(h->>'memo'), ''),
                                 'ref1', nullif(btrim(h->>'ref1'), ''), 'ref2', nullif(btrim(h->>'ref2'), '')),
    'totals', jsonb_build_object('debit', v_d, 'credit', v_c, 'difference', v_d - v_c, 'currency', v_cur));
END $$;

-- Lock and load a journal draft for a change.
CREATE OR REPLACE FUNCTION erp._je_lock(p_company varchar, p_draft_id integer) RETURNS erp.journal_draft
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  j erp.journal_draft;
BEGIN
  SELECT * INTO j FROM erp.journal_draft WHERE company_code = p_company AND draft_id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Journal draft % was not found in company %.', p_draft_id, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN j;
END $$;

-- The stored draft as save-function input.
CREATE OR REPLACE FUNCTION erp._je_stored(p_draft_id integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('ref_date', j.ref_date, 'due_date', j.due_date, 'memo', j.memo, 'ref1', j.ref1, 'ref2', j.ref2),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('acct_code', l.acct_code, 'debit', l.debit, 'credit', l.credit, 'memo', l.memo)
                                        ORDER BY l.line_num)
                         FROM erp.journal_draft_line l WHERE l.draft_id = j.draft_id), '[]'::jsonb))
    FROM erp.journal_draft j WHERE j.draft_id = p_draft_id
$$;

-- Post a checked draft: post_journal, then mark it posted. Internal.
CREATE OR REPLACE FUNCTION erp._je_post_draft(p_draft_id integer, e jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  j       erp.journal_draft;
  v_trans integer;
BEGIN
  SELECT * INTO j FROM erp.journal_draft WHERE draft_id = p_draft_id;
  v_trans := erp.post_journal(j.company_code, (e->'header'->>'ref_date')::date, e->'header'->>'memo', e->'lines',
    jsonb_build_object('trans_type', 30, 'ref1', e->'header'->>'ref1', 'ref2', e->'header'->>'ref2', 'due_date', e->'header'->>'due_date',
                       'action', 'journal_post', 'object', 'journal_draft', 'object_ref', p_draft_id::text));
  UPDATE erp.journal_draft SET state = 'posted', trans_id = v_trans, posted_at = now(), decided_at = coalesce(decided_at, now()), updated_at = now()
   WHERE draft_id = p_draft_id;
  RETURN v_trans;
END $$;

-- Super ERP documents: posting date in an open period when the company has a calendar (A2 sales orders and later documents).
CREATE OR REPLACE FUNCTION erp._doc_period_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_msg text;
BEGIN
  v_msg := erp._period_message(NEW.company_code, NEW.doc_date, false);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS doc_period_guard_ins ON erp.document;
CREATE TRIGGER doc_period_guard_ins BEFORE INSERT ON erp.document FOR EACH ROW
  WHEN (NEW.source = 'erp' AND NEW.status IN ('draft', 'open')) EXECUTE FUNCTION erp._doc_period_guard();
DROP TRIGGER IF EXISTS doc_period_guard_upd ON erp.document;
CREATE TRIGGER doc_period_guard_upd BEFORE UPDATE OF doc_date, status ON erp.document FOR EACH ROW
  WHEN (NEW.source = 'erp' AND NEW.status IN ('draft', 'open')
        AND (NEW.doc_date IS DISTINCT FROM OLD.doc_date OR (NEW.status = 'open' AND OLD.status IS DISTINCT FROM 'open')))
  EXECUTE FUNCTION erp._doc_period_guard();

-- ============ API: manual journals ============
-- Form defaults: currency, write access, the caller's approval limit.
CREATE OR REPLACE FUNCTION erp.journal_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._je_guard(p_company, false);
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('finance'),
    'my_limit', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 30 AND active AND rule_code = 'journal_amount'
                    AND (position_code = u.position_code OR position_code IS NULL) ORDER BY limit_value NULLS LAST, step LIMIT 1),
    'has_periods', EXISTS (SELECT 1 FROM erp.posting_period WHERE company_code = p_company));
END $$;

-- Live preview while typing. Writes nothing.
CREATE OR REPLACE FUNCTION erp.journal_checks(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._je_guard(p_company, false);
  RETURN erp._je_eval(p_company, p_header, p_lines, u.position_code);
END $$;

-- Create (p_draft_id NULL) or replace a draft owned by the caller. Unbalanced drafts and drafts in a closed period may be saved.
CREATE OR REPLACE FUNCTION erp.journal_draft_save(p_company varchar, p_draft_id integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  j      erp.journal_draft;
  e      jsonb;
  hd     jsonb;
  v_err  jsonb;
  v_new  boolean := p_draft_id IS NULL;
  v_id   integer;
  v_n    integer;
BEGIN
  u := erp._je_guard(p_company, true);
  IF NOT v_new THEN
    j := erp._je_lock(p_company, p_draft_id);
    IF j.state = 'pending_approval' THEN
      RAISE EXCEPTION 'This journal is waiting for approval and can''t be edited. Ask the approver to reject it first.' USING ERRCODE = 'P0001';
    ELSIF j.state = 'posted' THEN
      RAISE EXCEPTION 'This journal is posted and can''t be edited. Post a reversal instead.' USING ERRCODE = 'P0001';
    ELSIF j.state = 'cancelled' THEN
      RAISE EXCEPTION 'This journal is cancelled and can''t be edited.' USING ERRCODE = 'P0001';
    ELSIF j.created_by <> u.user_id THEN
      RAISE EXCEPTION 'Only the person who created this journal can change it.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  e := erp._je_eval(p_company, p_header, p_lines, u.position_code);
  SELECT coalesce(jsonb_agg(x), '[]'::jsonb) INTO v_err FROM jsonb_array_elements(e->'errors') x
   WHERE x->>'field' NOT IN ('period', 'balance', 'lines') AND NOT (x->>'field' = 'amount' AND x->>'message' LIKE '%enter a debit or a credit amount.');
  v_n := jsonb_array_length(v_err);
  IF v_n > 0 THEN
    RAISE EXCEPTION '%', v_err->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_n > 1 THEN format('%s more problem(s) on this journal.', v_n - 1) ELSE '' END;
  END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one line.' USING ERRCODE = 'P0001';
  END IF;
  hd := e->'header';

  IF v_new THEN
    INSERT INTO erp.journal_draft (company_code, ref_date, due_date, memo, ref1, ref2, state, total, currency, created_by)
    VALUES (p_company, (hd->>'ref_date')::date, (hd->>'due_date')::date, hd->>'memo', hd->>'ref1', hd->>'ref2', 'draft',
            (e->'totals'->>'debit')::numeric, e->'totals'->>'currency', u.user_id)
    RETURNING draft_id INTO v_id;
  ELSE
    v_id := p_draft_id;
    UPDATE erp.journal_draft
       SET ref_date = (hd->>'ref_date')::date, due_date = (hd->>'due_date')::date, memo = hd->>'memo', ref1 = hd->>'ref1', ref2 = hd->>'ref2',
           state = 'draft', total = (e->'totals'->>'debit')::numeric, updated_at = now()
     WHERE draft_id = v_id;
    DELETE FROM erp.journal_draft_line WHERE draft_id = v_id;
  END IF;
  INSERT INTO erp.journal_draft_line (draft_id, line_num, company_code, acct_code, debit, credit, memo)
  SELECT v_id, x.ord - 1, p_company, nullif(btrim(x.l->>'acct_code'), ''), coalesce(round(erp._num(x.l->>'debit'), 2), 0),
         coalesce(round(erp._num(x.l->>'credit'), 2), 0), nullif(btrim(x.l->>'memo'), '')
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS x(l, ord);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_new THEN 'journal_draft_create' ELSE 'journal_draft_update' END, 'journal_draft', v_id::text,
          jsonb_build_object('ref_date', hd->'ref_date', 'memo', hd->'memo', 'total', e->'totals'->'debit', 'difference', e->'totals'->'difference',
                             'lines', jsonb_array_length(p_lines)));
  RETURN jsonb_build_object('draft_id', v_id, 'state', 'draft', 'totals', e->'totals', 'checks', e->'checks', 'errors', e->'errors');
END $$;

-- Submit: no rule triggered → posted now. Otherwise pending_approval with one approval row per rule / step / approver.
CREATE OR REPLACE FUNCTION erp.journal_submit(p_company varchar, p_draft_id integer, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  j        erp.journal_draft;
  inp      jsonb;
  e        jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_trans  integer;
  v_n      integer;
BEGIN
  u := erp._je_guard(p_company, true);
  j := erp._je_lock(p_company, p_draft_id);
  IF j.state = 'pending_approval' THEN
    RAISE EXCEPTION 'This journal is already waiting for approval.' USING ERRCODE = 'P0001';
  ELSIF j.state = 'posted' THEN
    RAISE EXCEPTION 'This journal is already posted.' USING ERRCODE = 'P0001';
  ELSIF j.state = 'cancelled' THEN
    RAISE EXCEPTION 'This journal is cancelled and can''t be submitted.' USING ERRCODE = 'P0001';
  ELSIF j.created_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who created this journal can submit it.' USING ERRCODE = 'P0001';
  END IF;

  inp := erp._je_stored(p_draft_id);
  e := erp._je_eval(p_company, inp->'header', inp->'lines', u.position_code);
  v_n := jsonb_array_length(e->'errors');
  IF v_n > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_n > 1 THEN format('%s more problem(s) on this journal.', v_n - 1) ELSE 'Open the draft, fix it and save it again.' END;
  END IF;

  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;

  IF jsonb_array_length(e->'checks') = 0 THEN
    UPDATE erp.journal_draft SET submitted_by = u.user_id, submitted_at = now(), reason = v_reason WHERE draft_id = p_draft_id;
    v_trans := erp._je_post_draft(p_draft_id, e);
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'journal_submit', 'journal_draft', p_draft_id::text,
            jsonb_build_object('result', 'posted', 'trans_id', v_trans, 'total', e->'totals'->'debit'));
    RETURN jsonb_build_object('draft_id', p_draft_id, 'state', 'posted', 'trans_id', v_trans, 'checks', '[]'::jsonb);
  END IF;

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'This journal needs approval (total above your limit). Add a reason for the approver.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  SELECT p_company, 'journal', p_draft_id::text, (c->>'step')::smallint, c->>'approver_position', c->>'rule_code', u.user_id, now(),
         jsonb_build_object('checks', jsonb_agg(c), 'max_value', max((c->>'value')::numeric), 'limit', max((c->>'limit')::numeric))
    FROM jsonb_array_elements(e->'checks') c
   GROUP BY c->>'rule_code', (c->>'step')::smallint, c->>'approver_position';
  UPDATE erp.journal_draft SET state = 'pending_approval', submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = NULL,
                               updated_at = now()
   WHERE draft_id = p_draft_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'journal_submit', 'journal_draft', p_draft_id::text,
          jsonb_build_object('result', 'pending_approval', 'reason', v_reason, 'checks', e->'checks', 'total', e->'totals'->'debit'));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', 'pending_approval', 'checks', e->'checks');
END $$;

-- Approve or reject the current step. The last approval posts the journal (checks run again: the period may have closed).
CREATE OR REPLACE FUNCTION erp.journal_decide(p_company varchar, p_draft_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  j       erp.journal_draft;
  v_note  text := nullif(btrim(p_note), '');
  v_step  smallint;
  v_mine  bigint[];
  v_who   text;
  v_left  integer;
  v_state text;
  v_trans integer;
  inp     jsonb;
  e       jsonb;
  sp      erp.app_user;
BEGIN
  u := erp._je_guard(p_company, true);
  j := erp._je_lock(p_company, p_draft_id);
  IF j.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This journal is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF j.submitted_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own journal.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own journal. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND approver_position = u.position_code;
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT p.name, ' or ') INTO v_who FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = 'journal' AND a.object_ref = p_draft_id::text AND a.decision IS NULL
       AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This journal is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position')
      USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this journal.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET decision = p_decision, approver_user = u.user_id, decided_at = now(), note = v_note WHERE approval_id = ANY (v_mine);

  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.journal_draft SET state = 'rejected', decided_at = now(), updated_at = now() WHERE draft_id = p_draft_id;
    v_state := 'rejected';
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      SELECT * INTO sp FROM erp.app_user WHERE user_id = j.submitted_by;
      inp := erp._je_stored(p_draft_id);
      e := erp._je_eval(p_company, inp->'header', inp->'lines', sp.position_code);
      IF jsonb_array_length(e->'errors') > 0 THEN
        RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Nothing was posted. Reject it so the creator can fix it.';
      END IF;
      v_trans := erp._je_post_draft(p_draft_id, e);
      v_state := 'posted';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'journal_approve' ELSE 'journal_reject' END, 'journal_draft',
          p_draft_id::text, jsonb_build_object('step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state, 'trans_id', v_trans));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', v_state, 'trans_id', v_trans);
END $$;

-- Cancel a draft, a rejected or a waiting journal (creator only). Posted journals are reversed instead.
CREATE OR REPLACE FUNCTION erp.journal_draft_cancel(p_company varchar, p_draft_id integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  j      erp.journal_draft;
  v_note text := nullif(btrim(p_note), '');
BEGIN
  u := erp._je_guard(p_company, true);
  j := erp._je_lock(p_company, p_draft_id);
  IF j.state = 'posted' THEN
    RAISE EXCEPTION 'This journal is posted and can''t be cancelled. Post a reversal instead.' USING ERRCODE = 'P0001';
  ELSIF j.state = 'cancelled' THEN
    RAISE EXCEPTION 'This journal is already cancelled.' USING ERRCODE = 'P0001';
  ELSIF j.created_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who created this journal can cancel it.' USING ERRCODE = 'P0001';
  ELSIF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the journal is cancelled.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.journal_draft SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_note, updated_at = now()
   WHERE draft_id = p_draft_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'journal_draft_cancel', 'journal_draft', p_draft_id::text, jsonb_build_object('from_state', j.state, 'note', v_note));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', 'cancelled');
END $$;

-- Everything the draft page needs: header, lines with account names, approvals, what the caller may do, activity.
CREATE OR REPLACE FUNCTION erp.journal_draft_info(p_company varchar, p_draft_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  j       erp.journal_draft;
  v_write boolean;
  v_step  smallint;
  v_mine  boolean;
BEGIN
  u := erp._je_guard(p_company, false);
  SELECT * INTO j FROM erp.journal_draft WHERE company_code = p_company AND draft_id = p_draft_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_write := erp.can_write('finance');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'journal' AND object_ref = p_draft_id::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  RETURN jsonb_build_object(
    'draft_id', j.draft_id, 'company_code', j.company_code, 'state', j.state,
    'ref_date', j.ref_date, 'due_date', j.due_date, 'memo', j.memo, 'ref1', j.ref1, 'ref2', j.ref2, 'total', j.total, 'currency', j.currency,
    'trans_id', j.trans_id, 'posted_at', j.posted_at, 'reason', j.reason, 'cancel_note', j.cancel_note, 'cancelled_at', j.cancelled_at,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = j.created_by), 'created_at', j.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = j.submitted_by), 'submitted_at', j.submitted_at,
    'is_creator', j.created_by = u.user_id, 'is_submitter', j.submitted_by = u.user_id,
    'can_edit', v_write AND j.created_by = u.user_id AND j.state IN ('draft', 'rejected'),
    'can_cancel', v_write AND j.created_by = u.user_id AND j.state IN ('draft', 'rejected', 'pending_approval'),
    'can_decide', v_write AND j.state = 'pending_approval' AND j.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'acct_code', l.acct_code, 'acct_name', a.name,
                                                          'debit', l.debit, 'credit', l.credit, 'memo', l.memo) ORDER BY l.line_num)
                         FROM erp.journal_draft_line l LEFT JOIN erp.account a ON a.company_code = l.company_code AND a.acct_code = l.acct_code
                        WHERE l.draft_id = j.draft_id), '[]'::jsonb),
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', p.name, 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id, 'requested_at', a.requested_at,
               'detail', a.detail, 'superseded', a.superseded, 'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', a.approver_position = u.position_code) ORDER BY a.approval_id)
        FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
       WHERE a.company_code = p_company AND a.object = 'journal' AND a.object_ref = p_draft_id::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND l.object = 'journal_draft' AND l.object_ref = p_draft_id::text), '[]'::jsonb));
END $$;

-- What the journal page needs beyond the entry itself: reversal links, the draft or document that posted it, may it be reversed.
CREATE OR REPLACE FUNCTION erp.journal_info(p_company varchar, p_trans_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  je      erp.journal_entry;
  v_rev   integer;
  v_doc   erp.document_posting;
  v_draft integer;
  v_block text;
BEGIN
  u := erp._je_guard(p_company, false);
  SELECT * INTO je FROM erp.journal_entry WHERE company_code = p_company AND trans_id = p_trans_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT trans_id INTO v_rev FROM erp.journal_entry WHERE company_code = p_company AND reversal_of = p_trans_id AND source = 'erp' LIMIT 1;
  SELECT * INTO v_doc FROM erp.document_posting WHERE company_code = p_company AND trans_id = p_trans_id;
  SELECT draft_id INTO v_draft FROM erp.journal_draft WHERE company_code = p_company AND trans_id = p_trans_id;
  v_block := CASE
    WHEN NOT erp.can_write('finance') THEN 'read_only'
    WHEN je.source = 'sap' THEN format('Journal %s came from SAP Business One. Reverse it in SAP during the soft switch.', je.number)
    WHEN je.source <> 'erp' THEN format('Journal %s is sample test data and can''t be reversed.', je.number)
    WHEN je.reversal_of IS NOT NULL THEN format('Journal %s is itself a reversal of journal %s and can''t be reversed.', je.number, je.reversal_of)
    WHEN v_rev IS NOT NULL THEN format('Journal %s was already reversed by journal %s.', je.number, v_rev)
    WHEN v_doc.trans_id IS NOT NULL THEN format('Journal %s was posted by a document. Cancel the document instead.', je.number)
  END;
  RETURN jsonb_build_object(
    'trans_id', je.trans_id, 'source', je.source, 'reversal_of', je.reversal_of, 'reversed_by', v_rev, 'draft_id', v_draft,
    'document', CASE WHEN v_doc.trans_id IS NOT NULL THEN jsonb_build_object('obj_type', v_doc.obj_type, 'doc_entry', v_doc.doc_entry) END,
    'can_reverse', v_block IS NULL, 'reverse_block', v_block,
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND ((l.object = 'journal' AND l.object_ref = p_trans_id::text)
                                          OR (v_draft IS NOT NULL AND l.object = 'journal_draft' AND l.object_ref = v_draft::text))), '[]'::jsonb));
END $$;

-- Reverse a posted Super ERP journal: a new entry with debit and credit swapped. The original is never edited.
CREATE OR REPLACE FUNCTION erp.journal_reverse(p_company varchar, p_trans_id integer, p_date date, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  je       erp.journal_entry;
  v_reason text := nullif(btrim(p_reason), '');
  v_date   date := coalesce(p_date, current_date);
  v_rev    integer;
  v_new    integer;
BEGIN
  u := erp._je_guard(p_company, true);
  SELECT * INTO je FROM erp.journal_entry WHERE company_code = p_company AND trans_id = p_trans_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Journal % was not found in company %.', p_trans_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF je.source = 'sap' THEN
    RAISE EXCEPTION 'Journal % came from SAP Business One. Reverse it in SAP during the soft switch.', je.number USING ERRCODE = 'P0001';
  ELSIF je.source <> 'erp' THEN
    RAISE EXCEPTION 'Journal % is sample test data and can''t be reversed.', je.number USING ERRCODE = 'P0001';
  END IF;
  IF je.reversal_of IS NOT NULL THEN
    RAISE EXCEPTION 'Journal % is itself a reversal of journal % and can''t be reversed.', je.number, je.reversal_of USING ERRCODE = 'P0001';
  END IF;
  SELECT trans_id INTO v_rev FROM erp.journal_entry WHERE company_code = p_company AND reversal_of = p_trans_id AND source = 'erp' LIMIT 1;
  IF v_rev IS NOT NULL THEN
    RAISE EXCEPTION 'Journal % was already reversed by journal %.', je.number, v_rev USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.document_posting WHERE company_code = p_company AND trans_id = p_trans_id) THEN
    RAISE EXCEPTION 'Journal % was posted by a document. Cancel the document instead.', je.number USING ERRCODE = 'P0001';
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Add a reason for the reversal.' USING ERRCODE = 'P0001';
  END IF;
  IF v_date < je.ref_date THEN
    RAISE EXCEPTION 'The reversal date can''t be before the journal''s posting date (%).', erp._day(je.ref_date) USING ERRCODE = 'P0001';
  END IF;

  v_new := erp._reverse_journal(p_company, p_trans_id, v_date, format('Reversal of journal %s: %s', je.number, v_reason));
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'journal_reversed', 'journal', p_trans_id::text,
          jsonb_build_object('reversed_by', v_new, 'ref_date', v_date, 'reason', v_reason));
  RETURN jsonb_build_object('trans_id', v_new, 'reversal_of', p_trans_id);
END $$;

-- ============ API: posting periods ============
CREATE OR REPLACE FUNCTION erp.period_set_status(p_company varchar, p_period text, p_status text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  pp erp.posting_period;
BEGIN
  u := erp._je_guard(p_company, true, 'change posting periods');
  IF p_status IS NULL OR p_status NOT IN ('open', 'closed', 'locked') THEN
    RAISE EXCEPTION 'Choose open, closed or locked.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO pp FROM erp.posting_period WHERE company_code = p_company AND period_code = p_period FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Posting period % does not exist in %.', coalesce(p_period, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF pp.status = p_status THEN
    RAISE EXCEPTION 'Posting period % is already %.', p_period, p_status USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.posting_period SET status = p_status, updated_by = u.user_id, updated_at = now()
   WHERE company_code = p_company AND period_code = p_period;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'period_set_status', 'posting_period', p_period, jsonb_build_object('from', pp.status, 'to', p_status));
  RETURN jsonb_build_object('period_code', p_period, 'status', p_status, 'from', pp.status);
END $$;

-- Twelve monthly periods for a calendar year, all open (the calendar itself is a Finance decision: A3 walkthrough › Needs from Ashif).
CREATE OR REPLACE FUNCTION erp.period_add_year(p_company varchar, p_year integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._je_guard(p_company, true, 'change posting periods');
  IF p_year IS NULL OR p_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Enter a year between 2000 and 2100.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.posting_period WHERE company_code = p_company
              AND from_date <= make_date(p_year, 12, 31) AND to_date >= make_date(p_year, 1, 1)) THEN
    RAISE EXCEPTION 'Posting periods for % already exist in %.', p_year, p_company USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.posting_period (company_code, period_code, from_date, to_date, status, updated_by)
  SELECT p_company, to_char(m, 'YYYY-MM'), m::date, (m + interval '1 month - 1 day')::date, 'open', u.user_id
    FROM generate_series(make_date(p_year, 1, 1), make_date(p_year, 12, 1), interval '1 month') AS m;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'period_add_year', 'posting_period', p_year::text, jsonb_build_object('periods', 12, 'status', 'open'));
  RETURN jsonb_build_object('year', p_year, 'periods', 12);
END $$;

-- ============ API: G/L account determination ============
-- p_acct NULL or '' clears the key. Rows that came from SAP stay read-only.
CREATE OR REPLACE FUNCTION erp.gl_determination_set(p_company varchar, p_area text, p_key text, p_acct text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  g      erp.gl_determination;
  a      erp.account;
  v_acct text := nullif(btrim(p_acct), '');
  v_label text;
BEGIN
  u := erp._je_guard(p_company, true, 'change G/L account determination');
  SELECT label INTO v_label FROM erp.gl_posting_key WHERE area = p_area AND posting_key = p_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown posting key %/%.', coalesce(p_area, '(none)'), coalesce(p_key, '(none)') USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO g FROM erp.gl_determination WHERE company_code = p_company AND area = p_area AND posting_key = p_key FOR UPDATE;
  IF FOUND AND g.source = 'sap' THEN
    RAISE EXCEPTION 'The account for ''%'' comes from SAP Business One and is read-only during the soft switch.', v_label USING ERRCODE = 'P0001';
  END IF;
  IF v_acct IS NULL THEN
    DELETE FROM erp.gl_determination WHERE company_code = p_company AND area = p_area AND posting_key = p_key;
  ELSE
    SELECT * INTO a FROM erp.account WHERE company_code = p_company AND acct_code = v_acct;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Account % does not exist in %. Check the account code.', v_acct, p_company USING ERRCODE = 'P0001';
    ELSIF NOT a.postable THEN
      RAISE EXCEPTION 'Account % · % is a title account. Choose a postable account.', v_acct, a.name USING ERRCODE = 'P0001';
    ELSIF a.frozen THEN
      RAISE EXCEPTION 'Account % · % is frozen. Choose another account.', v_acct, a.name USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source, updated_by, updated_at)
    VALUES (p_company, p_area, p_key, v_acct, 'erp', u.user_id, now())
    ON CONFLICT (company_code, area, posting_key) DO UPDATE SET acct_code = EXCLUDED.acct_code, source = 'erp', updated_by = EXCLUDED.updated_by,
                                                                updated_at = now();
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_acct IS NULL THEN 'gl_determination_clear' ELSE 'gl_determination_set' END, 'gl_determination',
          p_area || '/' || p_key, jsonb_build_object('from', g.acct_code, 'to', v_acct));
  RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', g.acct_code);
END $$;

-- ============ Approvals inbox (replaces 17's): sales orders exactly as before, plus manual journals ============
CREATE OR REPLACE FUNCTION erp.approval_inbox() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_approver', false, 'waiting', '[]'::jsonb, 'sent', '[]'::jsonb, 'decided', '[]'::jsonb);
  END IF;
  RETURN (
    WITH base AS (
      SELECT a.*, 'sales_order'::text AS kind, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 17 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'sales_order' AND erp.can_see(a.company_code)
      UNION ALL
      SELECT a.*, 'journal'::text, j.draft_id::text, j.state, j.reason, j.submitted_by, j.draft_id, NULL::varchar, j.memo, j.total, j.currency
        FROM erp.approval a
        JOIN erp.journal_draft j ON j.company_code = a.company_code AND j.draft_id::text = a.object_ref
       WHERE a.object = 'journal' AND erp.can_see(a.company_code) AND erp.can_read('finance')
    ), a AS (
      SELECT b.*, p.name AS approver_position_name, ru.display_name AS requested_by_name, du.display_name AS decided_by_name,
             min(b.step) FILTER (WHERE b.decision IS NULL AND NOT b.superseded)
               OVER (PARTITION BY b.company_code, b.object, b.object_ref) AS current_step
        FROM base b
        JOIN erp.position p ON p.position_code = b.approver_position
        LEFT JOIN erp.app_user ru ON ru.user_id = b.requested_by
        LEFT JOIN erp.app_user du ON du.user_id = b.approver_user
    ), r AS (
      SELECT a.*, jsonb_build_object(
               'approval_id', a.approval_id, 'company_code', a.company_code, 'kind', a.kind, 'doc_entry', a.doc_entry,
               'doc_no', a.doc_no, 'rule_code', a.rule_code, 'step', a.step, 'card_code', a.card_code, 'card_name', a.card_name,
               'total', a.total, 'currency', a.currency, 'requested_by_name', a.requested_by_name, 'requested_at', a.requested_at,
               'reason', a.reason, 'decision', a.decision, 'decided_at', a.decided_at, 'decided_by_name', a.decided_by_name,
               'note', a.note, 'state', a.state, 'approver_position_name', a.approver_position_name, 'superseded', a.superseded,
               'message', a.detail->'checks'->0->>'message') AS j
        FROM a
    )
    SELECT jsonb_build_object(
      'is_approver', EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.approver_position = u.position_code AND ar.active AND erp.can_see(ar.company_code)),
      'waiting', coalesce((SELECT jsonb_agg(j ORDER BY requested_at) FROM r
                            WHERE decision IS NULL AND NOT superseded AND state = 'pending_approval' AND step = current_step
                              AND approver_position = u.position_code AND submitted_by IS DISTINCT FROM u.user_id), '[]'::jsonb),
      'sent', coalesce((SELECT jsonb_agg(j ORDER BY requested_at DESC, approval_id) FROM (SELECT * FROM r WHERE requested_by = u.user_id
                         ORDER BY requested_at DESC LIMIT 100) s), '[]'::jsonb),
      'decided', coalesce((SELECT jsonb_agg(j ORDER BY decided_at DESC) FROM (SELECT * FROM r WHERE approver_user = u.user_id AND decision IS NOT NULL
                            ORDER BY decided_at DESC LIMIT 100) s), '[]'::jsonb)));
END $$;

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._day(date), erp._period_message(varchar, date, boolean), erp.gl_account(varchar, text, text, boolean),
  erp._je_lines_eval(varchar, jsonb, boolean), erp.post_journal(varchar, date, text, jsonb, jsonb),
  erp._reverse_journal(varchar, integer, date, text, text), erp.post_document(varchar, integer, integer), erp._je_guard(varchar, boolean, text),
  erp._je_eval(varchar, jsonb, jsonb, text), erp._je_lock(varchar, integer), erp._je_stored(integer), erp._je_post_draft(integer, jsonb),
  erp._doc_period_guard()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.journal_setup(varchar), erp.journal_checks(varchar, jsonb, jsonb), erp.journal_draft_save(varchar, integer, jsonb, jsonb),
  erp.journal_submit(varchar, integer, text), erp.journal_decide(varchar, integer, text, text), erp.journal_draft_cancel(varchar, integer, text),
  erp.journal_draft_info(varchar, integer), erp.journal_info(varchar, integer), erp.journal_reverse(varchar, integer, date, text),
  erp.period_set_status(varchar, text, text), erp.period_add_year(varchar, integer), erp.gl_determination_set(varchar, text, text, text),
  erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.journal_setup(varchar), erp.journal_checks(varchar, jsonb, jsonb), erp.journal_draft_save(varchar, integer, jsonb, jsonb),
  erp.journal_submit(varchar, integer, text), erp.journal_decide(varchar, integer, text, text), erp.journal_draft_cancel(varchar, integer, text),
  erp.journal_draft_info(varchar, integer), erp.journal_info(varchar, integer), erp.journal_reverse(varchar, integer, date, text),
  erp.period_set_status(varchar, text, text), erp.period_add_year(varchar, integer), erp.gl_determination_set(varchar, text, text, text),
  erp.approval_inbox()
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- G/L account determination from ZZ99's own sample chart. Keys without an obvious ZZ99 account stay empty on purpose.
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', v.area, v.k, v.acct, 'sample'
  FROM (VALUES ('sales', 'domestic_ar', '1200'), ('sales', 'revenue', '4100'), ('sales', 'sales_returns', '4150'),
               ('sales', 'down_payment_clearing', '2150'), ('sales', 'output_vat', '2200'), ('sales', 'fx_gain', '7100'),
               ('purchasing', 'domestic_ap', '2100'), ('purchasing', 'foreign_ap', '2100'), ('purchasing', 'input_vat', '1400'),
               ('purchasing', 'goods_in_transit', '1310'), ('purchasing', 'fx_loss', '7200'),
               ('general', 'bank_charges', '6800'),
               ('inventory', 'inventory', '1300'), ('inventory', 'cogs', '5100')) AS v(area, k, acct)
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = v.acct)
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

-- Monthly periods 2026 and 2027, open (SAMPLE calendar for ZZ99 only).
INSERT INTO erp.posting_period (company_code, period_code, from_date, to_date, status, note)
SELECT 'ZZ99', to_char(m, 'YYYY-MM'), m::date, (m + interval '1 month - 1 day')::date, 'open', 'SAMPLE calendar for test company ZZ99 only'
  FROM generate_series(date '2026-01-01', date '2027-12-01', interval '1 month') AS m
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, period_code) DO NOTHING;

-- Manual journals above 50,000 AED raised by QA · finance need QA · finance manager (SAMPLE rule).
INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', 30, 'journal_amount', 'QA_FINANCE', 50000, 'QA_FIN_MGR', 1, 'SAMPLE rule for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_FINANCE')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_FIN_MGR')
ON CONFLICT (company_code, obj_type, rule_code, (coalesce(position_code, '')), step) DO NOTHING;
