-- A5 · Banking: incoming and outgoing payments, approvals, bank-detail-change block, deposits, bank statements, cash position.
-- Safe to run twice. Does not edit 10–19 (earlier behaviour is changed here with CREATE OR REPLACE, keeping its tests passing).
--
-- Payments made here are rows in erp.payment / erp.payment_allocation with source = 'erp', an ERP doc_entry from 900000000 up
-- and a number from erp.number_series (24 incoming, 46 outgoing, 25 deposit). SAP and sample rows are never written.
-- Allocations go to Super ERP documents only (SAP invoices are paid in SAP during the soft switch); their paid amount is kept
-- on erp.document.paid (source = 'erp' only). Every payment and deposit posts through erp.post_journal and is recorded in
-- erp.document_posting (obj_type 24 / 46 / 25), so A3's journal_reverse refuses to reverse it directly.
--
-- Bank statement matching never updates journal_line.match_no (posted journals are permanent, and match_no is SAP's own
-- reconciliation number). Matches are kept in erp.bank_match with an ERP match_no from 900000000 up; journal lines that
-- already carry a SAP match_no count as reconciled and are never offered.
--
-- Objects:
--   erp.bank_account        – house bank and cash accounts (G/L account per account)
--   erp.banking_setting     – cash / cheques-received / card-receipts accounts, statement matching window (days)
--   erp.bp_bank_account     – business partner bank details;  erp.bp_bank_change – every change (drives the bank-change rule)
--   erp.payment_draft       – outgoing payments waiting for approval: pending_approval → posted / rejected / cancelled
--   erp.payment_extra       – Super ERP payment number, bank account, references, cancellation
--   erp.payment_cheque      – cheques received (post-dated when due after the payment date) and issued
--   erp.deposit             – cheques and cash taken to a bank account
--   erp.bank_statement(_line), erp.bank_match, erp.erp_match_no_seq
--   erp.approval_rule       – rule_code gets 'payment_amount' and 'bank_change' (obj_type 46)
--   views                   – payment_list, payment_draft_list, deposit_list, bank_statement_list, bp_bank_account_list
--   internal                – _bk_guard, _bk_number, _bk_doc_open, _bk_reserved, _bk_gl_balance, _pay_eval, _pay_post
--   API                     – payment_setup / open_docs / checks / submit / decide / draft_cancel / draft_info / info / cancel,
--                             deposit_setup / create, bank_statement_import / info / auto_match / candidates / match / unmatch,
--                             bank_account_save, banking_setting_set, bp_bank_account_save, cash_position, approval_inbox (replaced)
--
-- Business values (accounts, limits, the 30-day window, matching window, numbering) are seeded for ZZ99 only and marked SAMPLE.
-- Real companies start empty (A5 walkthrough › Needs from Ashif).

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.bank_account (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    bank_code      text NOT NULL,                     -- e.g. BNK-AED
    name           text NOT NULL,
    kind           text NOT NULL DEFAULT 'bank' CHECK (kind IN ('bank', 'cash')),
    acct_code      varchar(15) NOT NULL,              -- G/L account the money sits in
    bank_name      text,
    account_no     text,
    iban           text,
    swift          text,
    currency       varchar(3),
    active         boolean NOT NULL DEFAULT true,
    source         text NOT NULL DEFAULT 'erp',       -- 'sap' (DSC1) read-only, 'erp', 'sample'
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, bank_code),
    FOREIGN KEY (company_code, acct_code) REFERENCES erp.account ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_account_acct_uniq ON erp.bank_account (company_code, acct_code);

CREATE TABLE IF NOT EXISTS erp.banking_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    cash_acct      varchar(15),                       -- cash received / paid
    cheque_acct    varchar(15),                       -- cheques received, not yet deposited (incl. post-dated)
    card_acct      varchar(15),                       -- card receipts waiting for the acquirer
    match_days     smallint CHECK (match_days BETWEEN 0 AND 60),   -- statement auto-match: date window ± days (NULL = same day)
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, cash_acct) REFERENCES erp.account ON DELETE CASCADE,
    FOREIGN KEY (company_code, cheque_acct) REFERENCES erp.account ON DELETE CASCADE,
    FOREIGN KEY (company_code, card_acct) REFERENCES erp.account ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.bp_bank_account (
    bp_bank_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    bank_name      text NOT NULL,
    account_no     text,
    iban           text,
    swift          text,
    holder         text,
    active         boolean NOT NULL DEFAULT true,
    source         text NOT NULL DEFAULT 'erp',       -- 'sap' (OCRB) read-only
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS bp_bank_account_bp_idx ON erp.bp_bank_account (company_code, card_code);

CREATE TABLE IF NOT EXISTS erp.bp_bank_change (
    change_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    bp_bank_id     integer,
    change_kind    text NOT NULL CHECK (change_kind IN ('added', 'changed', 'deactivated')),
    before         jsonb,
    after          jsonb,
    changed_by     uuid,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS bp_bank_change_bp_idx ON erp.bp_bank_change (company_code, card_code, changed_at);

CREATE TABLE IF NOT EXISTS erp.payment_draft (
    draft_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    direction      char(1) NOT NULL CHECK (direction IN ('I', 'O')),
    doc_date       date NOT NULL,
    card_code      varchar(15) NOT NULL,
    card_name      text,
    total          numeric(19,2) NOT NULL,
    currency       varchar(3),
    header         jsonb NOT NULL,                    -- checked input, checked again before posting
    lines          jsonb NOT NULL,
    checks         jsonb,
    state          text NOT NULL DEFAULT 'pending_approval' CHECK (state IN ('pending_approval', 'posted', 'rejected', 'cancelled')),
    reason         text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    decided_at     timestamptz,
    cancelled_by   uuid,
    cancelled_at   timestamptz,
    cancel_note    text,
    doc_entry      integer                            -- the posted payment
);
CREATE INDEX IF NOT EXISTS payment_draft_state_idx ON erp.payment_draft (company_code, state);

CREATE TABLE IF NOT EXISTS erp.payment_extra (
    company_code   varchar(8) NOT NULL,
    direction      char(1) NOT NULL,
    doc_entry      integer NOT NULL,
    doc_no         text NOT NULL,                     -- e.g. RC-26-00001
    transfer_bank  text,                              -- house bank account of the transfer
    transfer_ref   text,
    cheque_bank    text,                              -- outgoing cheques: drawn on this house bank account
    card_ref       text,
    draft_id       integer,
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_by   uuid,
    cancelled_at   timestamptz,
    cancel_note    text,
    cancel_trans_id integer,
    PRIMARY KEY (company_code, direction, doc_entry),
    FOREIGN KEY (company_code, direction, doc_entry) REFERENCES erp.payment ON DELETE CASCADE,
    UNIQUE (company_code, direction, doc_no)
);

CREATE TABLE IF NOT EXISTS erp.payment_cheque (
    cheque_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    direction      char(1) NOT NULL,
    doc_entry      integer NOT NULL,
    line_no        smallint NOT NULL,
    cheque_no      text NOT NULL,
    bank_name      text,
    due_date       date NOT NULL,
    amount         numeric(19,2) NOT NULL CHECK (amount > 0),
    deposit_id     integer,
    FOREIGN KEY (company_code, direction, doc_entry) REFERENCES erp.payment ON DELETE CASCADE,
    UNIQUE (company_code, direction, doc_entry, line_no)
);
CREATE INDEX IF NOT EXISTS payment_cheque_open_idx ON erp.payment_cheque (company_code, direction) WHERE deposit_id IS NULL;

CREATE TABLE IF NOT EXISTS erp.deposit (
    deposit_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    doc_no         text NOT NULL,
    deposit_date   date NOT NULL,
    bank_code      text NOT NULL,
    cheque_total   numeric(19,2) NOT NULL DEFAULT 0,
    cash_amount    numeric(19,2) NOT NULL DEFAULT 0,
    total          numeric(19,2) NOT NULL,
    cheques        integer NOT NULL DEFAULT 0,
    memo           text,
    trans_id       integer,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, doc_no),
    FOREIGN KEY (company_code, bank_code) REFERENCES erp.bank_account ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.bank_statement (
    statement_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    bank_code      text NOT NULL,
    file_name      text,
    from_date      date,
    to_date        date,
    lines_imported integer NOT NULL DEFAULT 0,
    lines_skipped  integer NOT NULL DEFAULT 0,
    imported_by    uuid NOT NULL,
    imported_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, bank_code) REFERENCES erp.bank_account ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.bank_statement_line (
    line_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    statement_id   integer NOT NULL REFERENCES erp.bank_statement ON DELETE CASCADE,
    company_code   varchar(8) NOT NULL,
    bank_code      text NOT NULL,
    line_no        integer NOT NULL,
    value_date     date NOT NULL,
    description    text,
    reference      text,
    amount         numeric(19,2) NOT NULL CHECK (amount <> 0),   -- + money in, − money out
    dedupe_key     text NOT NULL,                     -- same file imported again = same keys = skipped
    UNIQUE (company_code, bank_code, dedupe_key)
);
CREATE INDEX IF NOT EXISTS bank_statement_line_stmt_idx ON erp.bank_statement_line (statement_id, line_no);

CREATE SEQUENCE IF NOT EXISTS erp.erp_match_no_seq AS integer START WITH 900000000 MINVALUE 900000000 MAXVALUE 2147483647;

CREATE TABLE IF NOT EXISTS erp.bank_match (
    match_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    match_no       integer NOT NULL,                  -- ERP reconciliation number (journal_line.match_no stays SAP's)
    statement_line_id bigint NOT NULL REFERENCES erp.bank_statement_line ON DELETE CASCADE,
    trans_id       integer NOT NULL,
    jl_line_id     integer NOT NULL,
    amount         numeric(19,2) NOT NULL,
    how            text NOT NULL CHECK (how IN ('auto', 'manual')),
    matched_by     uuid,
    matched_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (statement_line_id),
    UNIQUE (company_code, trans_id, jl_line_id)
);

-- Payment approval rules (outgoing payments, SAP object 46).
ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount', 'payment_amount', 'bank_change'));

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.bank_account ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.banking_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bp_bank_account ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bp_bank_change ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.payment_draft ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.payment_extra ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.payment_cheque ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.deposit ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bank_statement ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bank_statement_line ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bank_match ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.bank_account, erp.banking_setting, erp.bp_bank_account, erp.bp_bank_change, erp.payment_draft, erp.payment_extra,
  erp.payment_cheque, erp.deposit, erp.bank_statement, erp.bank_statement_line, erp.bank_match FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.bank_account, erp.banking_setting, erp.bp_bank_account, erp.bp_bank_change, erp.payment_draft, erp.payment_extra,
  erp.payment_cheque, erp.deposit, erp.bank_statement, erp.bank_statement_line, erp.bank_match TO authenticated;
REVOKE ALL ON SEQUENCE erp.erp_match_no_seq FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bank_account', 'banking_setting', 'payment_draft', 'payment_extra', 'payment_cheque', 'deposit',
                           'bank_statement', 'bank_statement_line', 'bank_match'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I FOR SELECT TO authenticated USING (erp.can_see(company_code) AND ((SELECT erp.can_read(''banking'')) OR (SELECT erp.can_read(''finance''))))',
                   t || '_read', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['bp_bank_account', 'bp_bank_change'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I FOR SELECT TO authenticated USING (erp.can_see(company_code) AND ((SELECT erp.can_read(''banking'')) OR (SELECT erp.can_read(''finance'')) OR (SELECT erp.can_read(''bp'')) OR (SELECT erp.can_read(''purchase''))))',
                   t || '_read', t);
  END LOOP;
END $$;

-- Lists: SAP, sample and Super ERP payments side by side; the reader's own row rules apply (security_invoker).
CREATE OR REPLACE VIEW erp.payment_list WITH (security_invoker = true) AS
SELECT p.company_code, p.direction, p.doc_entry, p.doc_num, coalesce(x.doc_no, p.doc_num::text) AS doc_no, p.doc_type, p.doc_date,
       p.card_code, p.card_name, p.currency, p.total, p.cash, p.transfer, p.cheque, p.card, p.on_account, p.cancelled, p.trans_id,
       p.memo, p.source
  FROM erp.payment p
  LEFT JOIN erp.payment_extra x ON x.company_code = p.company_code AND x.direction = p.direction AND x.doc_entry = p.doc_entry;
CREATE OR REPLACE VIEW erp.payment_draft_list WITH (security_invoker = true) AS
SELECT company_code, draft_id, direction, doc_date, card_code, card_name, total, currency, state, reason, created_at, doc_entry
  FROM erp.payment_draft;
CREATE OR REPLACE VIEW erp.deposit_list WITH (security_invoker = true) AS
SELECT d.company_code, d.deposit_id, d.doc_no, d.deposit_date, d.bank_code, b.name AS bank_name, d.cheques, d.cheque_total, d.cash_amount,
       d.total, d.memo, d.trans_id, d.created_at
  FROM erp.deposit d LEFT JOIN erp.bank_account b ON b.company_code = d.company_code AND b.bank_code = d.bank_code;
CREATE OR REPLACE VIEW erp.bank_statement_list WITH (security_invoker = true) AS
SELECT s.company_code, s.statement_id, s.bank_code, b.name AS bank_name, s.file_name, s.from_date, s.to_date, s.lines_imported, s.lines_skipped,
       s.imported_at,
       (SELECT count(*) FROM erp.bank_statement_line l WHERE l.statement_id = s.statement_id) AS lines,
       (SELECT count(*) FROM erp.bank_statement_line l JOIN erp.bank_match m ON m.statement_line_id = l.line_id WHERE l.statement_id = s.statement_id) AS matched
  FROM erp.bank_statement s LEFT JOIN erp.bank_account b ON b.company_code = s.company_code AND b.bank_code = s.bank_code;
CREATE OR REPLACE VIEW erp.bp_bank_account_list WITH (security_invoker = true) AS
SELECT a.company_code, a.bp_bank_id, a.card_code, bp.name AS card_name, bp.kind, a.bank_name, a.account_no, a.iban, a.swift, a.holder,
       a.active, a.source, a.updated_at,
       (SELECT max(c.changed_at) FROM erp.bp_bank_change c WHERE c.company_code = a.company_code AND c.card_code = a.card_code) AS last_change_at
  FROM erp.bp_bank_account a JOIN erp.business_partner bp ON bp.company_code = a.company_code AND bp.card_code = a.card_code;
REVOKE ALL ON erp.payment_list, erp.payment_draft_list, erp.deposit_list, erp.bank_statement_list, erp.bp_bank_account_list FROM PUBLIC, anon;
GRANT SELECT ON erp.payment_list, erp.payment_draft_list, erp.deposit_list, erp.bank_statement_list, erp.bp_bank_account_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
-- Who is calling, and may they read (p_write = false) or change Banking in this company? Banking or Financials both count.
CREATE OR REPLACE FUNCTION erp._bk_guard(p_company varchar, p_write boolean, p_what text DEFAULT 'record payments') RETURNS erp.app_user
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
  IF NOT (erp.can_read('banking') OR erp.can_read('finance')) THEN
    RAISE EXCEPTION 'Your position does not include Banking. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_write AND NOT (erp.can_write('banking') OR erp.can_write('finance')) THEN
    RAISE EXCEPTION 'You have read-only access to Banking. Ask the system admin for full access to %.', p_what USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION erp._bk_name(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 24 THEN 'Incoming payment' WHEN 46 THEN 'Outgoing payment' WHEN 25 THEN 'Deposit' ELSE 'Banking document' END
$$;

-- Next number for a payment or deposit (row-locked). Raises when the company has no numbering for it.
CREATE OR REPLACE FUNCTION erp._bk_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns erp.number_series;
BEGIN
  SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._bk_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.number_series SET next_num = next_num + 1 WHERE company_code = p_company AND obj_type = p_obj;
  RETURN jsonb_build_object('num', ns.next_num, 'no', ns.prefix || lpad(ns.next_num::text, ns.pad, '0'), 'entry', nextval('erp.erp_doc_entry_seq'));
END $$;

-- What is still open on a document: total − paid − credit memos based on it (an invoice) / − the part based on invoices (a credit memo).
CREATE OR REPLACE FUNCTION erp._bk_doc_open(p_company varchar, p_obj integer, p_entry integer) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d   erp.document;
  v_c numeric := 0;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry;
  IF NOT FOUND THEN RETURN 0; END IF;
  IF p_obj IN (13, 18) THEN
    SELECT coalesce(sum(cl.line_total + coalesce(cl.vat, 0)), 0) INTO v_c
      FROM erp.document_line cl
      JOIN erp.document c ON c.company_code = cl.company_code AND c.obj_type = cl.obj_type AND c.doc_entry = cl.doc_entry
     WHERE cl.company_code = p_company AND cl.obj_type = p_obj + 1 AND cl.base_obj_type = p_obj AND cl.base_doc_entry = p_entry
       AND c.status NOT IN ('cancelled', 'cancellation');
  ELSIF p_obj IN (14, 19) THEN
    SELECT coalesce(sum(line_total + coalesce(vat, 0)), 0) INTO v_c
      FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry AND base_obj_type = p_obj - 1;
  END IF;
  RETURN round(coalesce(d.total, 0) - coalesce(d.paid, 0) - v_c, 2);
END $$;

-- Amount of a document already applied in outgoing payments that wait for approval (other than p_except).
CREATE OR REPLACE FUNCTION erp._bk_reserved(p_company varchar, p_obj integer, p_entry integer, p_except integer) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(round(sum((l->>'amount')::numeric), 2), 0)
    FROM erp.payment_draft p CROSS JOIN jsonb_array_elements(p.lines) l
   WHERE p.company_code = p_company AND p.state = 'pending_approval' AND p.draft_id IS DISTINCT FROM p_except
     AND (l->>'obj_type')::integer = p_obj AND (l->>'doc_entry')::integer = p_entry
$$;

-- G/L balance of an account: SAP's balance at the last sync + every Super ERP journal since.
CREATE OR REPLACE FUNCTION erp._bk_gl_balance(p_company varchar, p_acct text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT round(coalesce((SELECT balance_local FROM erp.account WHERE company_code = p_company AND acct_code = p_acct), 0)
         + coalesce((SELECT sum(l.debit - l.credit) FROM erp.journal_line l
                       JOIN erp.journal_entry j ON j.company_code = l.company_code AND j.trans_id = l.trans_id AND j.source = 'erp'
                      WHERE l.company_code = p_company AND l.acct_code = p_acct), 0), 2)
$$;

-- Validate a payment and find the approval rules it triggers. Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, value, limit, message}],
--    header:{normalised}, lines:[{line_no, obj_type, doc_entry, doc_no, amount, sign, open}], totals:{total, applied, on_account, currency}}
-- p_header: {card_code, doc_date, memo, cash, transfer, transfer_bank, transfer_ref, cheques:[{cheque_no, bank_name, due_date, amount}],
--            cheque_bank (outgoing), card, card_ref}.  p_lines: [{obj_type, doc_entry, amount}]
CREATE OR REPLACE FUNCTION erp._pay_eval(p_company varchar, p_dir text, p_header jsonb, p_lines jsonb, p_position text, p_draft_id integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_chqin  jsonb := CASE WHEN jsonb_typeof(p_header->'cheques') = 'array' THEN p_header->'cheques' ELSE '[]'::jsonb END;
  v_in     boolean := p_dir = 'I';
  v_party  text := CASE WHEN p_dir = 'I' THEN 'customer' ELSE 'supplier' END;
  v_partyc  text := CASE WHEN p_dir = 'I' THEN 'Customer' ELSE 'Supplier' END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_chq    jsonb := '[]';
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  v_tbank  text := nullif(btrim(h->>'transfer_bank'), '');
  v_cbank  text := nullif(btrim(h->>'cheque_bank'), '');
  bp       erp.business_partner;
  st       erp.banking_setting;
  v_date   date;
  v_cash   numeric;
  v_tr     numeric;
  v_cd     numeric;
  v_ct     numeric := 0;
  v_total  numeric := 0;
  v_applied numeric := 0;
  v_amt_ok boolean := true;
  x        jsonb;
  i        integer := 0;
  n        text;
  d        erp.document;
  v_obj    integer;
  v_entry  integer;
  v_amt    numeric;
  v_open   numeric;
  v_res    numeric;
  v_no     text;
  v_noun   text;
  v_nounc   text;
  v_seen   text[] := '{}';
  v_msg    text;
  v_names  text;
  v_changed timestamptz;
  v_cno    text;
  v_cdue   date;
  v_camt   numeric;
  r        record;
  k        integer := 0;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;

  -- Business partner
  IF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Choose a %s.', v_party));
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s %s does not exist in company %s. Check the code.', v_partyc, v_card, p_company));
    ELSIF bp.kind <> v_party THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a %s. Choose a %s.', v_card, v_party, v_party));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s %s is inactive. Choose an active %s.', v_partyc, v_card, v_party));
    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message',
        format('%s %s is billed in %s. Payments in a foreign currency come in a later stage.', v_partyc, v_card, bp.currency));
    END IF;
  END IF;

  -- Posting date
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'doc_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;

  -- Means of payment
  v_cash := CASE WHEN nullif(btrim(h->>'cash'), '') IS NULL THEN 0 ELSE erp._num(h->>'cash') END;
  v_tr   := CASE WHEN nullif(btrim(h->>'transfer'), '') IS NULL THEN 0 ELSE erp._num(h->>'transfer') END;
  v_cd   := CASE WHEN nullif(btrim(h->>'card'), '') IS NULL THEN 0 ELSE erp._num(h->>'card') END;
  IF v_cash IS NULL OR v_cash < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cash', 'message', 'Cash must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  IF v_tr IS NULL OR v_tr < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer', 'message', 'The transfer amount must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  IF v_cd IS NULL OR v_cd < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card', 'message', 'The card amount must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  v_cash := round(coalesce(v_cash, 0), 2); v_tr := round(coalesce(v_tr, 0), 2); v_cd := round(coalesce(v_cd, 0), 2);

  IF v_tr > 0 THEN
    IF v_tbank IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer_bank', 'message',
        CASE WHEN v_in THEN 'Choose the bank account the transfer was paid into.' ELSE 'Choose the bank account the transfer is paid from.' END);
    ELSIF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_tbank AND active AND kind = 'bank') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer_bank', 'message', format('Bank account %s does not exist or is inactive in company %s.', v_tbank, p_company));
    END IF;
  END IF;

  FOR x IN SELECT value FROM jsonb_array_elements(v_chqin) LOOP
    k := k + 1;
    v_cno := nullif(btrim(x->>'cheque_no'), '');
    v_camt := erp._num(x->>'amount');
    v_cdue := erp._date(x->>'due_date');
    IF v_cno IS NULL AND v_camt IS NULL AND nullif(btrim(x->>'due_date'), '') IS NULL THEN CONTINUE; END IF;   -- empty row
    IF v_cno IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter the cheque number.', k));
    ELSIF v_camt IS NULL OR v_camt <= 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter an amount above 0.', k)); v_amt_ok := false;
    ELSIF v_cdue IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter a valid due date.', k));
    ELSE
      v_ct := v_ct + round(v_camt, 2);
      v_chq := v_chq || jsonb_build_object('cheque_no', v_cno, 'bank_name', nullif(btrim(x->>'bank_name'), ''), 'due_date', v_cdue,
                                           'amount', round(v_camt, 2), 'post_dated', v_date IS NOT NULL AND v_cdue > v_date);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_chq) > 0 AND NOT v_in THEN
    IF v_cbank IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheque_bank', 'message', 'Choose the bank account the cheques are drawn on.');
    ELSIF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_cbank AND active AND kind = 'bank') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheque_bank', 'message', format('Bank account %s does not exist or is inactive in company %s.', v_cbank, p_company));
    END IF;
  END IF;
  IF v_cd > 0 AND NOT v_in THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card', 'message', 'Outgoing payments by card are not supported. Pay by transfer, cheque or cash.');
  END IF;

  v_total := round(v_cash + v_tr + v_ct + v_cd, 2);
  IF v_amt_ok AND v_total <= 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'total', 'message',
      CASE WHEN v_in THEN 'Enter the amount received: cash, transfer, cheque or card.' ELSE 'Enter the amount paid: cash, transfer or cheque.' END);
  END IF;

  -- Accounts the posting needs
  IF v_cash > 0 AND st.cash_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The cash account is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF v_ct > 0 AND v_in AND st.cheque_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The account for cheques received is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF v_cd > 0 AND v_in AND st.card_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The account for card receipts is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF erp.gl_account(p_company, CASE WHEN v_in THEN 'sales' ELSE 'purchasing' END, CASE WHEN v_in THEN 'domestic_ar' ELSE 'domestic_ap' END, false) IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message',
      format('G/L account for ''%s'' is not set for %s. Ask Finance to set it in Setup › Financials › G/L Account Determination.',
             CASE WHEN v_in THEN 'Domestic accounts receivable' ELSE 'Domestic accounts payable' END, p_company));
  END IF;
  v_msg := erp._period_message(p_company, v_date, true);
  IF v_msg IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'period', 'message', v_msg);
  END IF;

  -- Allocations
  FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_obj := erp._num(x->>'obj_type')::integer;
    v_entry := erp._num(x->>'doc_entry')::integer;
    v_amt := erp._num(x->>'amount');
    IF v_obj IS NULL OR v_entry IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'choose a document.');
      CONTINUE;
    END IF;
    IF v_in AND v_obj NOT IN (13, 14) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'an incoming payment pays A/R invoices and uses A/R credit memos only.');
      CONTINUE;
    ELSIF NOT v_in AND v_obj NOT IN (18, 19, 204) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'an outgoing payment pays A/P invoices and down payments and uses A/P credit memos only.');
      CONTINUE;
    END IF;
    v_noun := CASE v_obj WHEN 13 THEN 'invoice' WHEN 14 THEN 'credit memo' WHEN 18 THEN 'A/P invoice' WHEN 19 THEN 'A/P credit memo' ELSE 'down payment' END;
    v_nounc := CASE v_obj WHEN 13 THEN 'Invoice' WHEN 14 THEN 'Credit memo' WHEN 18 THEN 'A/P invoice' WHEN 19 THEN 'A/P credit memo' ELSE 'Down payment' END;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = v_obj AND doc_entry = v_entry;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s was not found in company %s.', v_noun, v_entry, p_company));
      CONTINUE;
    END IF;
    v_no := erp._sd_no(p_company, v_obj, v_entry);
    IF d.source = 'sap' THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s came from SAP Business One. Record its payment in SAP during the soft switch.', v_noun, v_no));
    ELSIF d.source <> 'erp' THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is sample test data and can''t be paid.', v_noun, v_no));
    ELSIF d.card_code IS DISTINCT FROM v_card THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s belongs to %s, not %s.', v_noun, v_no, d.card_code, coalesce(v_card, '(none)')));
    ELSIF d.status IN ('cancelled', 'cancellation') THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is cancelled.', v_noun, v_no));
    ELSIF (v_obj || ':' || v_entry) = ANY (v_seen) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is listed twice.', v_noun, v_no));
    ELSIF v_amt IS NULL OR v_amt <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'enter an amount above 0.');
    ELSE
      v_amt := round(v_amt, 2);
      v_open := erp._bk_doc_open(p_company, v_obj, v_entry);
      v_res := erp._bk_reserved(p_company, v_obj, v_entry, p_draft_id);
      IF v_amt > v_open - v_res THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n ||
          CASE WHEN v_res > 0
               THEN format('%s %s is more than the %s %s still open on %s %s (%s %s is waiting in other payment drafts).',
                           erp._money(v_amt), v_cur, erp._money(greatest(v_open - v_res, 0)), v_cur, v_noun, v_no, erp._money(v_res), v_cur)
               ELSE format('%s %s is more than the %s %s still open on %s %s.', erp._money(v_amt), v_cur, erp._money(greatest(v_open, 0)), v_cur, v_noun, v_no) END);
      ELSE
        v_applied := v_applied + CASE WHEN v_obj IN (14, 19) THEN -v_amt ELSE v_amt END;
        v_out := v_out || jsonb_build_object('line_no', jsonb_array_length(v_out), 'obj_type', v_obj, 'doc_entry', v_entry, 'doc_no', v_no,
                                             'amount', v_amt, 'sign', CASE WHEN v_obj IN (14, 19) THEN -1 ELSE 1 END, 'open', v_open,
                                             'doc_date', d.doc_date, 'due_date', d.due_date, 'total', d.total);
      END IF;
    END IF;
    v_seen := v_seen || (v_obj || ':' || v_entry);
  END LOOP;
  v_applied := round(v_applied, 2);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_err) e WHERE e->>'field' IN ('amount', 'doc', 'cash', 'transfer', 'card', 'cheques')) THEN
    IF v_applied > v_total AND v_total > 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'applied', 'message',
        format('You applied %s %s but the payment is %s %s. Lower the applied amounts or raise the payment.', erp._money(v_applied), v_cur, erp._money(v_total), v_cur));
    ELSIF v_applied < 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'applied', 'message', 'The credit memos are more than the invoices you applied. Apply more invoices or less credit.');
    END IF;
  END IF;

  -- Approval rules (outgoing payments)
  IF NOT v_in AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 46 AND ar.active AND ar.rule_code = 'payment_amount'
                AND (ar.position_code = p_position OR ar.position_code IS NULL) AND ar.limit_value IS NOT NULL
              ORDER BY ar.step LOOP
      IF v_total > r.limit_value THEN
        v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
          'approver_name', r.approver_name, 'value', v_total, 'limit', r.limit_value,
          'message', format('Payment %s %s is above your payment limit of %s %s.', erp._money(v_total), v_cur, erp._money(r.limit_value), v_cur));
      END IF;
    END LOOP;
    SELECT string_agg(p.name, ' and ' ORDER BY ar.step) INTO v_names
      FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
     WHERE ar.company_code = p_company AND ar.obj_type = 46 AND ar.active AND ar.rule_code = 'bank_change' AND ar.limit_value IS NOT NULL;
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 46 AND ar.active AND ar.rule_code = 'bank_change' AND ar.limit_value IS NOT NULL
              ORDER BY ar.step LOOP
      SELECT max(changed_at) INTO v_changed FROM erp.bp_bank_change
       WHERE company_code = p_company AND card_code = v_card AND changed_at >= now() - make_interval(days => r.limit_value::integer);
      IF v_changed IS NOT NULL THEN
        v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
          'approver_name', r.approver_name, 'value', v_changed::date, 'limit', r.limit_value,
          'message', format('%s''s bank details changed on %s, within the last %s days. %s must both approve this payment.',
                            bp.name, erp._day(v_changed::date), trim_scale(r.limit_value), v_names));
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', bp.name, 'doc_date', v_date, 'memo', nullif(btrim(h->>'memo'), ''),
                                 'cash', v_cash, 'transfer', v_tr, 'transfer_bank', CASE WHEN v_tr > 0 THEN v_tbank END,
                                 'transfer_ref', nullif(btrim(h->>'transfer_ref'), ''), 'cheques', v_chq, 'cheque_total', v_ct,
                                 'cheque_bank', CASE WHEN v_ct > 0 AND NOT v_in THEN v_cbank END, 'card', v_cd, 'card_ref', nullif(btrim(h->>'card_ref'), '')),
    'totals', jsonb_build_object('total', v_total, 'applied', v_applied, 'on_account', round(v_total - v_applied, 2), 'currency', v_cur));
END $$;

-- Post a checked payment: erp.payment + allocations + cheques, documents' paid amounts, the journal, the BP balance. Internal.
CREATE OR REPLACE FUNCTION erp._pay_post(p_company varchar, p_dir text, e jsonb, p_user uuid, p_draft_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h       jsonb := e->'header';
  v_in    boolean := p_dir = 'I';
  v_obj   integer := CASE WHEN p_dir = 'I' THEN 24 ELSE 46 END;
  nb      jsonb;
  v_entry integer;
  v_total numeric := (e->'totals'->>'total')::numeric;
  v_cur   text := e->'totals'->>'currency';
  st      erp.banking_setting;
  v_ctl   text;
  v_side  text := CASE WHEN p_dir = 'I' THEN 'debit' ELSE 'credit' END;
  v_oside text := CASE WHEN p_dir = 'I' THEN 'credit' ELSE 'debit' END;
  v_lines jsonb := '[]';
  v_trans integer;
  v_memo  text;
  x       jsonb;
BEGIN
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  nb := erp._bk_number(p_company, v_obj);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.payment (company_code, direction, doc_entry, doc_num, doc_type, doc_date, card_code, card_name, currency, fx_rate, total,
                           cash, transfer, cheque, card, on_account, cancelled, memo, source)
  VALUES (p_company, p_dir, v_entry, (nb->>'num')::integer, CASE WHEN v_in THEN 'C' ELSE 'S' END, (h->>'doc_date')::date, h->>'card_code',
          h->>'card_name', v_cur, 1, v_total, (h->>'cash')::numeric, (h->>'transfer')::numeric, (h->>'cheque_total')::numeric, (h->>'card')::numeric,
          (e->'totals'->>'on_account')::numeric, false, h->>'memo', 'erp');
  INSERT INTO erp.payment_extra (company_code, direction, doc_entry, doc_no, transfer_bank, transfer_ref, cheque_bank, card_ref, draft_id, created_by)
  VALUES (p_company, p_dir, v_entry, nb->>'no', h->>'transfer_bank', h->>'transfer_ref', h->>'cheque_bank', h->>'card_ref', p_draft_id, p_user);
  INSERT INTO erp.payment_cheque (company_code, direction, doc_entry, line_no, cheque_no, bank_name, due_date, amount)
  SELECT p_company, p_dir, v_entry, (c.ord - 1)::smallint, c.v->>'cheque_no', c.v->>'bank_name', (c.v->>'due_date')::date, (c.v->>'amount')::numeric
    FROM jsonb_array_elements(h->'cheques') WITH ORDINALITY AS c(v, ord);
  INSERT INTO erp.payment_allocation (company_code, direction, doc_entry, line_no, target_obj_type, target_doc_entry, applied)
  SELECT p_company, p_dir, v_entry, (l->>'line_no')::integer, (l->>'obj_type')::integer, (l->>'doc_entry')::integer, (l->>'amount')::numeric
    FROM jsonb_array_elements(e->'lines') l;
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') LOOP
    UPDATE erp.document SET paid = round(coalesce(paid, 0) + (x->>'amount')::numeric, 6)
     WHERE company_code = p_company AND obj_type = (x->>'obj_type')::integer AND doc_entry = (x->>'doc_entry')::integer AND source = 'erp';
  END LOOP;

  -- Journal: money side (cash / bank / cheques / card) against the customer's receivable or the supplier's payable.
  v_ctl := erp.gl_account(p_company, CASE WHEN v_in THEN 'sales' ELSE 'purchasing' END, CASE WHEN v_in THEN 'domestic_ar' ELSE 'domestic_ap' END);
  IF (h->>'cash')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', st.cash_acct, v_side, (h->>'cash')::numeric, 'memo', 'Cash');
  END IF;
  IF (h->>'transfer')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', (SELECT acct_code FROM erp.bank_account WHERE company_code = p_company AND bank_code = h->>'transfer_bank'),
                                             v_side, (h->>'transfer')::numeric, 'memo', coalesce('Transfer ' || (h->>'transfer_ref'), 'Transfer'));
  END IF;
  IF (h->>'cheque_total')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', CASE WHEN v_in THEN st.cheque_acct
                                                               ELSE (SELECT acct_code FROM erp.bank_account WHERE company_code = p_company AND bank_code = h->>'cheque_bank') END,
                                             v_side, (h->>'cheque_total')::numeric,
                                             'memo', 'Cheques ' || (SELECT string_agg(c->>'cheque_no', ', ') FROM jsonb_array_elements(h->'cheques') c));
  END IF;
  IF (h->>'card')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', st.card_acct, v_side, (h->>'card')::numeric, 'memo', coalesce('Card ' || (h->>'card_ref'), 'Card'));
  END IF;
  IF v_in THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_ctl, 'short_name', h->>'card_code', v_oside, v_total);
  ELSE
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_ctl, 'short_name', h->>'card_code', v_oside, v_total)) || v_lines;
  END IF;
  v_memo := format('%s %s · %s', erp._bk_name(v_obj), nb->>'no', coalesce(h->>'card_name', h->>'card_code'));
  v_trans := erp.post_journal(p_company, (h->>'doc_date')::date, v_memo, v_lines,
    jsonb_build_object('trans_type', v_obj, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'ref2', h->>'transfer_ref', 'allow_control', true,
                       'action', 'payment_post', 'object', 'payment', 'object_ref', p_dir || '/' || v_entry));
  UPDATE erp.payment SET trans_id = v_trans WHERE company_code = p_company AND direction = p_dir AND doc_entry = v_entry;
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, v_obj, v_entry, v_trans);
  PERFORM erp._bp_balance_add(p_company, h->>'card_code', CASE WHEN v_in THEN -v_total ELSE v_total END);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (coalesce(p_user::text, 'system:banking'), p_company, 'payment_post', 'payment', p_dir || '/' || v_entry,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', h->>'card_code', 'total', v_total, 'on_account', e->'totals'->'on_account',
                             'allocations', jsonb_array_length(e->'lines'), 'trans_id', v_trans, 'draft_id', p_draft_id));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'trans_id', v_trans, 'total', v_total, 'on_account', e->'totals'->'on_account');
END $$;

-- ============ API: payments ============
-- Form defaults: currency, write access, house bank accounts, which accounts are set, the caller's payment limit.
CREATE OR REPLACE FUNCTION erp.payment_setup(p_company varchar, p_dir text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  st erp.banking_setting;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('banking') OR erp.can_write('finance'),
    'banks', coalesce((SELECT jsonb_agg(jsonb_build_object('bank_code', bank_code, 'name', name, 'acct_code', acct_code, 'bank_name', bank_name) ORDER BY bank_code)
                         FROM erp.bank_account WHERE company_code = p_company AND active AND kind = 'bank'), '[]'::jsonb),
    'accounts', jsonb_build_object('cash', st.cash_acct IS NOT NULL, 'cheque', st.cheque_acct IS NOT NULL, 'card', st.card_acct IS NOT NULL),
    'numbering', EXISTS (SELECT 1 FROM erp.number_series WHERE company_code = p_company AND obj_type = CASE WHEN p_dir = 'I' THEN 24 ELSE 46 END AND active),
    'my_limit', CASE WHEN p_dir = 'O' THEN (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 46 AND active
                                              AND rule_code = 'payment_amount' AND (position_code = u.position_code OR position_code IS NULL)
                                            ORDER BY limit_value NULLS LAST, step LIMIT 1) END,
    'bank_change_days', CASE WHEN p_dir = 'O' THEN (SELECT max(limit_value) FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 46
                                                      AND active AND rule_code = 'bank_change') END);
END $$;

-- Open Super ERP documents of a customer (I) or supplier (O), with what is still open and what other drafts hold.
CREATE OR REPLACE FUNCTION erp.payment_open_docs(p_company varchar, p_dir text, p_card text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  v_objs integer[] := CASE WHEN p_dir = 'I' THEN ARRAY[13, 14] ELSE ARRAY[18, 19, 204] END;
  bp     erp.business_partner;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card;
  RETURN jsonb_build_object(
    'card_code', bp.card_code, 'card_name', bp.name, 'currency', bp.currency,
    'balance', coalesce(bp.balance, 0) + coalesce((SELECT balance FROM erp.bp_balance_erp WHERE company_code = p_company AND card_code = p_card), 0),
    'bank_changed_at', (SELECT max(changed_at) FROM erp.bp_bank_change WHERE company_code = p_company AND card_code = p_card),
    'docs', coalesce((
      SELECT jsonb_agg(x ORDER BY x->>'due_date', x->>'doc_no') FROM (
        SELECT jsonb_build_object('obj_type', d.obj_type, 'doc_entry', d.doc_entry, 'doc_no', erp._sd_no(p_company, d.obj_type, d.doc_entry),
                                  'doc_date', d.doc_date, 'due_date', coalesce(d.due_date, d.doc_date), 'total', d.total,
                                  'open', erp._bk_doc_open(p_company, d.obj_type, d.doc_entry),
                                  'reserved', erp._bk_reserved(p_company, d.obj_type, d.doc_entry, NULL),
                                  'sign', CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END) AS x
          FROM erp.document d
         WHERE d.company_code = p_company AND d.card_code = p_card AND d.obj_type = ANY (v_objs) AND d.source = 'erp'
           AND d.status NOT IN ('cancelled', 'cancellation')) s
       WHERE (x->>'open')::numeric > 0), '[]'::jsonb),
    'other_open', (SELECT count(*) FROM erp.document d WHERE d.company_code = p_company AND d.card_code = p_card AND d.obj_type = ANY (v_objs)
                     AND d.source <> 'erp' AND d.status = 'open'));
END $$;

-- Live preview while typing. Writes nothing.
CREATE OR REPLACE FUNCTION erp.payment_checks(p_company varchar, p_dir text, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._bk_guard(p_company, false);
  IF p_dir IS NULL OR p_dir NOT IN ('I', 'O') THEN
    RAISE EXCEPTION 'Choose an incoming or an outgoing payment.' USING ERRCODE = 'P0001';
  END IF;
  RETURN erp._pay_eval(p_company, p_dir, p_header, p_lines, u.position_code, NULL);
END $$;

-- Record a payment. No rule triggered → posted now. Otherwise saved as a payment draft waiting for approval (reason needed).
CREATE OR REPLACE FUNCTION erp.payment_submit(p_company varchar, p_dir text, p_header jsonb, p_lines jsonb, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  e        jsonb;
  v_n      integer;
  v_reason text := nullif(btrim(p_reason), '');
  r        jsonb;
  v_id     integer;
BEGIN
  u := erp._bk_guard(p_company, true);
  IF p_dir IS NULL OR p_dir NOT IN ('I', 'O') THEN
    RAISE EXCEPTION 'Choose an incoming or an outgoing payment.' USING ERRCODE = 'P0001';
  END IF;
  e := erp._pay_eval(p_company, p_dir, p_header, p_lines, u.position_code, NULL);
  v_n := jsonb_array_length(e->'errors');
  IF v_n > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_n > 1 THEN format('%s more problem(s) on this payment.', v_n - 1) ELSE '' END;
  END IF;
  IF jsonb_array_length(e->'checks') = 0 THEN
    r := erp._pay_post(p_company, p_dir, e, u.user_id, NULL);
    RETURN r || jsonb_build_object('state', 'posted', 'checks', '[]'::jsonb);
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'This payment needs approval. Add a reason for the approver.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.payment_draft (company_code, direction, doc_date, card_code, card_name, total, currency, header, lines, checks, state, reason, created_by)
  VALUES (p_company, p_dir, (e->'header'->>'doc_date')::date, e->'header'->>'card_code', e->'header'->>'card_name', (e->'totals'->>'total')::numeric,
          e->'totals'->>'currency', e->'header', e->'lines', e->'checks', 'pending_approval', v_reason, u.user_id)
  RETURNING draft_id INTO v_id;
  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  SELECT p_company, 'payment', v_id::text, (c->>'step')::smallint, c->>'approver_position', c->>'rule_code', u.user_id, now(),
         jsonb_build_object('checks', jsonb_agg(c))
    FROM jsonb_array_elements(e->'checks') c
   GROUP BY c->>'rule_code', (c->>'step')::smallint, c->>'approver_position';
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payment_submit', 'payment_draft', v_id::text,
          jsonb_build_object('result', 'pending_approval', 'reason', v_reason, 'checks', e->'checks', 'total', e->'totals'->'total',
                             'card_code', e->'header'->'card_code'));
  RETURN jsonb_build_object('state', 'pending_approval', 'draft_id', v_id, 'checks', e->'checks', 'total', e->'totals'->'total');
END $$;

-- Approve or reject the current step. The last approval checks the payment again and posts it. Approvers need an approver
-- position on the current step and read access to Banking (the Owner approves without write access to Financials).
CREATE OR REPLACE FUNCTION erp.payment_decide(p_company varchar, p_draft_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  p       erp.payment_draft;
  sp      erp.app_user;
  v_note  text := nullif(btrim(p_note), '');
  v_step  smallint;
  v_mine  bigint[];
  v_who   text;
  v_left  integer;
  v_state text;
  e       jsonb;
  r       jsonb;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO p FROM erp.payment_draft WHERE company_code = p_company AND draft_id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment draft % was not found in company %.', p_draft_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF p.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This payment is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF p.created_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own payment.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own payment. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND approver_position = u.position_code;
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT ps.name, ' or ') INTO v_who FROM erp.approval a JOIN erp.position ps ON ps.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = 'payment' AND a.object_ref = p_draft_id::text AND a.decision IS NULL
       AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This payment is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position')
      USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this payment.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET decision = p_decision, approver_user = u.user_id, decided_at = now(), note = v_note WHERE approval_id = ANY (v_mine);
  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.payment_draft SET state = 'rejected', decided_at = now() WHERE draft_id = p_draft_id;
    v_state := 'rejected';
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      SELECT * INTO sp FROM erp.app_user WHERE user_id = p.created_by;
      e := erp._pay_eval(p_company, p.direction, p.header, p.lines, sp.position_code, p_draft_id);
      IF jsonb_array_length(e->'errors') > 0 THEN
        RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Nothing was paid. Reject it so the creator can enter it again.';
      END IF;
      r := erp._pay_post(p_company, p.direction, e, p.created_by, p_draft_id);
      UPDATE erp.payment_draft SET state = 'posted', decided_at = now(), doc_entry = (r->>'doc_entry')::integer WHERE draft_id = p_draft_id;
      v_state := 'posted';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'payment_approve' ELSE 'payment_reject' END, 'payment_draft',
          p_draft_id::text, jsonb_build_object('step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state,
                                               'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no', 'trans_id', r->'trans_id'));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', v_state, 'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no', 'trans_id', r->'trans_id',
                            'direction', p.direction);
END $$;

-- Cancel a waiting or rejected payment draft (creator only). Posted payments are cancelled with payment_cancel.
CREATE OR REPLACE FUNCTION erp.payment_draft_cancel(p_company varchar, p_draft_id integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  p      erp.payment_draft;
  v_note text := nullif(btrim(p_note), '');
BEGIN
  u := erp._bk_guard(p_company, true);
  SELECT * INTO p FROM erp.payment_draft WHERE company_code = p_company AND draft_id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment draft % was not found in company %.', p_draft_id, p_company USING ERRCODE = 'P0001';
  ELSIF p.state = 'posted' THEN
    RAISE EXCEPTION 'This payment is already posted. Cancel the payment itself instead.' USING ERRCODE = 'P0001';
  ELSIF p.state = 'cancelled' THEN
    RAISE EXCEPTION 'This payment draft is already cancelled.' USING ERRCODE = 'P0001';
  ELSIF p.created_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who entered this payment can cancel it.' USING ERRCODE = 'P0001';
  ELSIF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the payment is cancelled.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.payment_draft SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_note WHERE draft_id = p_draft_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payment_draft_cancel', 'payment_draft', p_draft_id::text, jsonb_build_object('from_state', p.state, 'note', v_note));
  RETURN jsonb_build_object('draft_id', p_draft_id, 'state', 'cancelled');
END $$;

-- Everything the payment draft page needs.
CREATE OR REPLACE FUNCTION erp.payment_draft_info(p_company varchar, p_draft_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  p      erp.payment_draft;
  v_step smallint;
  v_mine boolean;
  v_write boolean;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO p FROM erp.payment_draft WHERE company_code = p_company AND draft_id = p_draft_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_write := erp.can_write('banking') OR erp.can_write('finance');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'payment' AND object_ref = p_draft_id::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  RETURN jsonb_build_object(
    'draft_id', p.draft_id, 'company_code', p.company_code, 'direction', p.direction, 'state', p.state, 'doc_date', p.doc_date,
    'card_code', p.card_code, 'card_name', p.card_name, 'total', p.total, 'currency', p.currency, 'header', p.header, 'lines', p.lines,
    'checks', p.checks, 'reason', p.reason, 'doc_entry', p.doc_entry,
    'doc_no', (SELECT doc_no FROM erp.payment_extra WHERE company_code = p_company AND direction = p.direction AND doc_entry = p.doc_entry),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = p.created_by), 'created_at', p.created_at,
    'cancel_note', p.cancel_note, 'cancelled_at', p.cancelled_at, 'decided_at', p.decided_at,
    'is_creator', p.created_by = u.user_id,
    'can_cancel', v_write AND p.created_by = u.user_id AND p.state IN ('pending_approval', 'rejected'),
    'can_decide', p.state = 'pending_approval' AND p.created_by <> u.user_id AND v_mine,
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', ps.name, 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id, 'requested_at', a.requested_at,
               'detail', a.detail, 'superseded', a.superseded, 'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', a.approver_position = u.position_code) ORDER BY a.step, a.approval_id)
        FROM erp.approval a JOIN erp.position ps ON ps.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
       WHERE a.company_code = p_company AND a.object = 'payment' AND a.object_ref = p_draft_id::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND ((l.object = 'payment_draft' AND l.object_ref = p_draft_id::text)
                                          OR (p.doc_entry IS NOT NULL AND l.object = 'payment' AND l.object_ref = p.direction || '/' || p.doc_entry))), '[]'::jsonb));
END $$;

-- Why a payment can't be cancelled (NULL = it can). Internal.
CREATE OR REPLACE FUNCTION erp._pay_cancel_block(p_company varchar, p_dir text, p_entry integer) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  p    erp.payment;
  v_no text;
  c    record;
BEGIN
  SELECT * INTO p FROM erp.payment WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_entry;
  IF NOT FOUND THEN RETURN format('Payment %s was not found in company %s.', p_entry, p_company); END IF;
  v_no := coalesce((SELECT doc_no FROM erp.payment_extra WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_entry), p.doc_num::text);
  IF p.source = 'sap' THEN
    RETURN format('Payment %s came from SAP Business One. Cancel it in SAP during the soft switch.', v_no);
  ELSIF p.source <> 'erp' THEN
    RETURN format('Payment %s is sample test data and can''t be cancelled.', v_no);
  ELSIF p.cancelled THEN
    RETURN format('Payment %s is already cancelled.', v_no);
  END IF;
  SELECT pc.cheque_no, d.doc_no INTO c FROM erp.payment_cheque pc JOIN erp.deposit d ON d.deposit_id = pc.deposit_id
   WHERE pc.company_code = p_company AND pc.direction = p_dir AND pc.doc_entry = p_entry LIMIT 1;
  IF FOUND THEN
    RETURN format('Cheque %s is already in deposit %s, so the payment can''t be cancelled.', c.cheque_no, c.doc_no);
  END IF;
  IF EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.company_code = p_company AND m.trans_id = p.trans_id) THEN
    RETURN format('Payment %s is matched to a bank statement line. Unmatch it first.', v_no);
  END IF;
  RETURN NULL;
END $$;

-- Payment page: number, means, allocations, cheques, journal, may it be cancelled, activity. SAP and sample payments too.
CREATE OR REPLACE FUNCTION erp.payment_info(p_company varchar, p_dir text, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  p  erp.payment;
  x  erp.payment_extra;
  v_block text;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO p FROM erp.payment WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO x FROM erp.payment_extra WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry;
  v_block := CASE WHEN NOT (erp.can_write('banking') OR erp.can_write('finance')) THEN 'read_only' ELSE erp._pay_cancel_block(p_company, p_dir, p_doc_entry) END;
  RETURN to_jsonb(p) || jsonb_build_object(
    'doc_no', coalesce(x.doc_no, p.doc_num::text),
    'transfer_bank', x.transfer_bank, 'transfer_bank_name', (SELECT name FROM erp.bank_account WHERE company_code = p_company AND bank_code = x.transfer_bank),
    'transfer_ref', x.transfer_ref, 'cheque_bank', x.cheque_bank, 'card_ref', x.card_ref, 'draft_id', x.draft_id,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = x.created_by), 'created_at', x.created_at,
    'cancelled_at', x.cancelled_at, 'cancel_note', x.cancel_note, 'cancel_trans_id', x.cancel_trans_id,
    'can_read_journal', erp.can_read('finance'),
    'can_cancel', v_block IS NULL, 'cancel_block', v_block,
    'allocations', coalesce((SELECT jsonb_agg(jsonb_build_object('line_no', a.line_no, 'obj_type', a.target_obj_type, 'doc_entry', a.target_doc_entry,
                                                                 'doc_no', erp._sd_no(p_company, a.target_obj_type, a.target_doc_entry), 'applied', a.applied,
                                                                 'doc_total', d.total, 'doc_date', d.doc_date) ORDER BY a.line_no)
                               FROM erp.payment_allocation a
                               LEFT JOIN erp.document d ON d.company_code = a.company_code AND d.obj_type = a.target_obj_type AND d.doc_entry = a.target_doc_entry
                              WHERE a.company_code = p_company AND a.direction = p_dir AND a.doc_entry = p_doc_entry), '[]'::jsonb),
    'cheques', coalesce((SELECT jsonb_agg(jsonb_build_object('cheque_id', c.cheque_id, 'cheque_no', c.cheque_no, 'bank_name', c.bank_name, 'due_date', c.due_date,
                                                             'amount', c.amount, 'post_dated', c.due_date > p.doc_date, 'deposit_id', c.deposit_id,
                                                             'deposit_no', dp.doc_no) ORDER BY c.line_no)
                           FROM erp.payment_cheque c LEFT JOIN erp.deposit dp ON dp.deposit_id = c.deposit_id
                          WHERE c.company_code = p_company AND c.direction = p_dir AND c.doc_entry = p_doc_entry), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND ((l.object = 'payment' AND l.object_ref = p_dir || '/' || p_doc_entry)
                                          OR (x.draft_id IS NOT NULL AND l.object = 'payment_draft' AND l.object_ref = x.draft_id::text))), '[]'::jsonb));
END $$;

-- Cancel a posted Super ERP payment: reversal journal, documents open again, BP balance back. Refused once a cheque is
-- deposited or the payment is matched to a bank statement line.
CREATE OR REPLACE FUNCTION erp.payment_cancel(p_company varchar, p_dir text, p_doc_entry integer, p_date date, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  p        erp.payment;
  x        erp.payment_extra;
  v_block  text;
  v_reason text := nullif(btrim(p_reason), '');
  v_date   date;
  v_new    integer;
  a        record;
BEGIN
  u := erp._bk_guard(p_company, true, 'cancel payments');
  SELECT * INTO p FROM erp.payment WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry FOR UPDATE;
  v_block := erp._pay_cancel_block(p_company, p_dir, p_doc_entry);
  IF v_block IS NOT NULL THEN
    RAISE EXCEPTION '%', v_block USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO x FROM erp.payment_extra WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Add a reason for the cancellation.' USING ERRCODE = 'P0001';
  END IF;
  v_date := coalesce(p_date, current_date);
  IF v_date < p.doc_date THEN
    RAISE EXCEPTION 'The cancellation date can''t be before the payment date (%).', erp._day(p.doc_date) USING ERRCODE = 'P0001';
  END IF;
  v_new := erp._reverse_journal(p_company, p.trans_id, v_date, format('Cancellation of %s %s: %s', lower(erp._bk_name(CASE WHEN p_dir = 'I' THEN 24 ELSE 46 END)), x.doc_no, v_reason),
                                'payment_cancel_journal');
  UPDATE erp.payment SET cancelled = true WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry AND source = 'erp';
  UPDATE erp.payment_extra SET cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_reason, cancel_trans_id = v_new
   WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry;
  FOR a IN SELECT * FROM erp.payment_allocation WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry LOOP
    UPDATE erp.document SET paid = round(greatest(coalesce(paid, 0) - a.applied, 0), 6)
     WHERE company_code = p_company AND obj_type = a.target_obj_type AND doc_entry = a.target_doc_entry AND source = 'erp';
  END LOOP;
  PERFORM erp._bp_balance_add(p_company, p.card_code, CASE WHEN p_dir = 'I' THEN p.total ELSE -p.total END);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payment_cancel', 'payment', p_dir || '/' || p_doc_entry,
          jsonb_build_object('doc_no', x.doc_no, 'reversed_by', v_new, 'date', v_date, 'reason', v_reason, 'total', p.total));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'cancelled', true, 'trans_id', v_new);
END $$;

-- ============ API: deposits ============
-- Deposit form: house bank accounts, cheques received and not yet deposited (post-dated flagged), cash on hand.
CREATE OR REPLACE FUNCTION erp.deposit_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  st erp.banking_setting;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('banking') OR erp.can_write('finance'),
    'numbering', EXISTS (SELECT 1 FROM erp.number_series WHERE company_code = p_company AND obj_type = 25 AND active),
    'banks', coalesce((SELECT jsonb_agg(jsonb_build_object('bank_code', bank_code, 'name', name, 'acct_code', acct_code) ORDER BY bank_code)
                         FROM erp.bank_account WHERE company_code = p_company AND active AND kind = 'bank'), '[]'::jsonb),
    'cash_acct', st.cash_acct, 'cheque_acct', st.cheque_acct,
    'cash_on_hand', CASE WHEN st.cash_acct IS NOT NULL THEN erp._bk_gl_balance(p_company, st.cash_acct) END,
    'cheques', coalesce((
      SELECT jsonb_agg(jsonb_build_object('cheque_id', c.cheque_id, 'cheque_no', c.cheque_no, 'bank_name', c.bank_name, 'due_date', c.due_date,
                                          'amount', c.amount, 'doc_entry', p.doc_entry, 'doc_no', x.doc_no, 'card_code', p.card_code,
                                          'card_name', p.card_name, 'payment_date', p.doc_date) ORDER BY c.due_date, c.cheque_id)
        FROM erp.payment_cheque c
        JOIN erp.payment p ON p.company_code = c.company_code AND p.direction = c.direction AND p.doc_entry = c.doc_entry
        LEFT JOIN erp.payment_extra x ON x.company_code = p.company_code AND x.direction = p.direction AND x.doc_entry = p.doc_entry
       WHERE c.company_code = p_company AND c.direction = 'I' AND c.deposit_id IS NULL AND NOT p.cancelled), '[]'::jsonb));
END $$;

-- Deposit cheques and / or cash to a bank account: Dr bank / Cr cheques received / Cr cash.
-- p_header: {deposit_date, bank_code, cash_amount, memo}; p_cheques: [cheque_id, …]
CREATE OR REPLACE FUNCTION erp.deposit_create(p_company varchar, p_header jsonb, p_cheques jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_ids   integer[];
  v_date  date;
  v_bank  text := nullif(btrim(h->>'bank_code'), '');
  ba      erp.bank_account;
  st      erp.banking_setting;
  v_cash  numeric;
  v_chq   numeric := 0;
  v_cnt   integer := 0;
  v_cur   text;
  v_onhand numeric;
  c       record;
  nb      jsonb;
  v_id    integer;
  v_lines jsonb := '[]';
  v_trans integer;
  v_msg   text;
BEGIN
  u := erp._bk_guard(p_company, true, 'record deposits');
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  IF nullif(btrim(h->>'deposit_date'), '') IS NULL THEN
    RAISE EXCEPTION 'Choose a deposit date.' USING ERRCODE = 'P0001';
  END IF;
  v_date := erp._date(h->>'deposit_date');
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'The deposit date is not a valid date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_bank IS NULL THEN
    RAISE EXCEPTION 'Choose the bank account to deposit into.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO ba FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_bank AND active AND kind = 'bank';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank account % does not exist or is inactive in company %.', v_bank, p_company USING ERRCODE = 'P0001';
  END IF;
  v_cash := CASE WHEN nullif(btrim(h->>'cash_amount'), '') IS NULL THEN 0 ELSE erp._num(h->>'cash_amount') END;
  IF v_cash IS NULL OR v_cash < 0 THEN
    RAISE EXCEPTION 'The cash amount must be a number of 0 or more.' USING ERRCODE = 'P0001';
  END IF;
  v_cash := round(v_cash, 2);
  SELECT array_agg(DISTINCT erp._num(x)::integer) INTO v_ids FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_cheques) = 'array' THEN p_cheques ELSE '[]'::jsonb END) x;
  IF v_ids IS NOT NULL AND array_position(v_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Choose cheques from the list.' USING ERRCODE = 'P0001';
  END IF;

  FOR c IN SELECT pc.*, p.cancelled, d.doc_no AS deposit_no
             FROM erp.payment_cheque pc
             JOIN erp.payment p ON p.company_code = pc.company_code AND p.direction = pc.direction AND p.doc_entry = pc.doc_entry
             LEFT JOIN erp.deposit d ON d.deposit_id = pc.deposit_id
            WHERE pc.cheque_id = ANY (coalesce(v_ids, '{}')) ORDER BY pc.cheque_id FOR UPDATE OF pc LOOP
    IF c.company_code <> p_company OR c.direction <> 'I' THEN
      RAISE EXCEPTION 'Cheque % is not a cheque received by company %.', c.cheque_no, p_company USING ERRCODE = 'P0001';
    ELSIF c.cancelled THEN
      RAISE EXCEPTION 'Cheque % belongs to a cancelled payment.', c.cheque_no USING ERRCODE = 'P0001';
    ELSIF c.deposit_id IS NOT NULL THEN
      RAISE EXCEPTION 'Cheque % is already in deposit %.', c.cheque_no, c.deposit_no USING ERRCODE = 'P0001';
    ELSIF c.due_date > v_date THEN
      RAISE EXCEPTION 'Cheque % is post-dated to %. Deposit it on or after that date.', c.cheque_no, erp._day(c.due_date) USING ERRCODE = 'P0001';
    END IF;
    v_chq := v_chq + c.amount;
    v_cnt := v_cnt + 1;
  END LOOP;
  IF v_cnt < coalesce(array_length(v_ids, 1), 0) THEN
    RAISE EXCEPTION 'One of the chosen cheques was not found. Reload the page and choose again.' USING ERRCODE = 'P0001';
  END IF;
  IF v_chq + v_cash <= 0 THEN
    RAISE EXCEPTION 'Choose cheques or enter a cash amount to deposit.' USING ERRCODE = 'P0001';
  END IF;
  IF v_chq > 0 AND st.cheque_acct IS NULL THEN
    RAISE EXCEPTION 'The account for cheques received is not set for %. Ask Finance to set it in Banking › Banking Setup.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_cash > 0 THEN
    IF st.cash_acct IS NULL THEN
      RAISE EXCEPTION 'The cash account is not set for %. Ask Finance to set it in Banking › Banking Setup.', p_company USING ERRCODE = 'P0001';
    END IF;
    v_onhand := erp._bk_gl_balance(p_company, st.cash_acct);
    IF v_cash > v_onhand THEN
      RAISE EXCEPTION 'Only % % cash is on hand. Lower the cash amount.', erp._money(greatest(v_onhand, 0)), v_cur USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_msg := erp._period_message(p_company, v_date, true);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;

  nb := erp._bk_number(p_company, 25);
  INSERT INTO erp.deposit (company_code, doc_no, deposit_date, bank_code, cheque_total, cash_amount, total, cheques, memo, created_by)
  VALUES (p_company, nb->>'no', v_date, v_bank, v_chq, v_cash, v_chq + v_cash, v_cnt, nullif(btrim(h->>'memo'), ''), u.user_id)
  RETURNING deposit_id INTO v_id;
  UPDATE erp.payment_cheque SET deposit_id = v_id WHERE cheque_id = ANY (coalesce(v_ids, '{}'));
  v_lines := jsonb_build_array(jsonb_build_object('acct_code', ba.acct_code, 'debit', v_chq + v_cash));
  IF v_chq > 0 THEN v_lines := v_lines || jsonb_build_object('acct_code', st.cheque_acct, 'credit', v_chq, 'memo', format('%s cheque(s)', v_cnt)); END IF;
  IF v_cash > 0 THEN v_lines := v_lines || jsonb_build_object('acct_code', st.cash_acct, 'credit', v_cash, 'memo', 'Cash'); END IF;
  v_trans := erp.post_journal(p_company, v_date, format('Deposit %s · %s', nb->>'no', ba.name), v_lines,
    jsonb_build_object('trans_type', 25, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'action', 'deposit_post', 'object', 'deposit', 'object_ref', v_id::text));
  UPDATE erp.deposit SET trans_id = v_trans WHERE deposit_id = v_id;
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 25, v_id, v_trans);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'deposit_create', 'deposit', v_id::text,
          jsonb_build_object('doc_no', nb->>'no', 'bank_code', v_bank, 'cheques', v_cnt, 'cheque_total', v_chq, 'cash', v_cash, 'trans_id', v_trans));
  RETURN jsonb_build_object('deposit_id', v_id, 'doc_no', nb->>'no', 'total', v_chq + v_cash, 'cheques', v_cnt, 'trans_id', v_trans);
END $$;

-- ============ API: bank statements and reconciliation ============
-- Import statement lines (already parsed from the bank's CSV by the browser with the chosen column mapping).
-- p_rows: [{date (YYYY-MM-DD), description, reference, amount (+ in / − out)}]. A line imported before (same date, amount,
-- reference, description and position among identical lines) is skipped, so importing the same file twice adds nothing.
CREATE OR REPLACE FUNCTION erp.bank_statement_import(p_company varchar, p_bank_code text, p_file_name text, p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  v_rows  jsonb := CASE WHEN jsonb_typeof(p_rows) = 'array' THEN p_rows ELSE '[]'::jsonb END;
  v_norm  jsonb := '[]';
  v_occ   jsonb := '{}';
  x       jsonb;
  i       integer := 0;
  v_date  date;
  v_amt   numeric;
  v_base  text;
  v_k     integer;
  v_id    integer;
  v_n     integer;
  v_total integer;
BEGIN
  u := erp._bk_guard(p_company, true, 'import bank statements');
  IF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = p_bank_code AND active AND kind = 'bank') THEN
    RAISE EXCEPTION 'Choose an active bank account of company % for the statement.', p_company USING ERRCODE = 'P0001';
  END IF;
  v_total := jsonb_array_length(v_rows);
  IF v_total = 0 THEN
    RAISE EXCEPTION 'The file has no statement lines.' USING ERRCODE = 'P0001';
  ELSIF v_total > 5000 THEN
    RAISE EXCEPTION 'A statement can have at most 5,000 lines. Split the file.' USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(v_rows) LOOP
    i := i + 1;
    v_date := CASE WHEN coalesce(x->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$' THEN erp._date(x->>'date') END;
    IF v_date IS NULL THEN
      RAISE EXCEPTION 'Row %: the date "%" is not a valid date. Check the date format chosen for the file.', i, coalesce(x->>'date', '') USING ERRCODE = 'P0001';
    END IF;
    v_amt := erp._num(x->>'amount');
    IF v_amt IS NULL THEN
      RAISE EXCEPTION 'Row %: the amount "%" is not a number.', i, coalesce(x->>'amount', '') USING ERRCODE = 'P0001';
    ELSIF round(v_amt, 2) = 0 THEN
      RAISE EXCEPTION 'Row %: the amount is 0. Remove the row or check the amount columns.', i USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(v_amt, 2);
    v_base := concat_ws('|', v_date, v_amt, coalesce(btrim(x->>'reference'), ''), coalesce(btrim(x->>'description'), ''));
    v_k := coalesce((v_occ->>v_base)::integer, 0) + 1;
    v_occ := v_occ || jsonb_build_object(v_base, v_k);
    v_norm := v_norm || jsonb_build_object('line_no', i, 'value_date', v_date, 'amount', v_amt, 'reference', nullif(btrim(x->>'reference'), ''),
                                           'description', nullif(btrim(x->>'description'), ''), 'dedupe_key', md5(v_base || '|' || v_k));
  END LOOP;

  INSERT INTO erp.bank_statement (company_code, bank_code, file_name, imported_by) VALUES (p_company, p_bank_code, nullif(btrim(p_file_name), ''), u.user_id)
  RETURNING statement_id INTO v_id;
  INSERT INTO erp.bank_statement_line (statement_id, company_code, bank_code, line_no, value_date, description, reference, amount, dedupe_key)
  SELECT v_id, p_company, p_bank_code, r.line_no, r.value_date, r.description, r.reference, r.amount, r.dedupe_key
    FROM jsonb_to_recordset(v_norm) AS r(line_no integer, value_date date, description text, reference text, amount numeric, dedupe_key text)
  ON CONFLICT (company_code, bank_code, dedupe_key) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    DELETE FROM erp.bank_statement WHERE statement_id = v_id;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'bank_statement_import', 'bank_statement', NULL,
            jsonb_build_object('bank_code', p_bank_code, 'file_name', p_file_name, 'imported', 0, 'skipped', v_total));
    RETURN jsonb_build_object('statement_id', NULL, 'imported', 0, 'skipped', v_total);
  END IF;
  UPDATE erp.bank_statement s SET lines_imported = v_n, lines_skipped = v_total - v_n,
         from_date = (SELECT min(value_date) FROM erp.bank_statement_line WHERE statement_id = v_id),
         to_date = (SELECT max(value_date) FROM erp.bank_statement_line WHERE statement_id = v_id)
   WHERE s.statement_id = v_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bank_statement_import', 'bank_statement', v_id::text,
          jsonb_build_object('bank_code', p_bank_code, 'file_name', p_file_name, 'imported', v_n, 'skipped', v_total - v_n));
  RETURN jsonb_build_object('statement_id', v_id, 'imported', v_n, 'skipped', v_total - v_n);
END $$;

-- Journal lines on the bank's G/L account that can still be matched: not reconciled in SAP (match_no), not matched here,
-- not part of a reversed journal or a reversal (a cancelled payment never reached the bank). Internal.
CREATE OR REPLACE FUNCTION erp._bk_open_jl(p_company varchar, p_acct text) RETURNS TABLE (trans_id integer, line_id integer, ref_date date, amount numeric,
  memo text, ref1 text, trans_type integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT l.trans_id, l.line_id, coalesce(l.ref_date, j.ref_date), round(l.debit - l.credit, 2), coalesce(l.memo, j.memo), j.ref1, j.trans_type
    FROM erp.journal_line l
    JOIN erp.journal_entry j ON j.company_code = l.company_code AND j.trans_id = l.trans_id
   WHERE l.company_code = p_company AND l.acct_code = p_acct AND l.match_no IS NULL AND round(l.debit - l.credit, 2) <> 0
     AND j.reversal_of IS NULL
     AND NOT EXISTS (SELECT 1 FROM erp.journal_entry r WHERE r.company_code = j.company_code AND r.reversal_of = j.trans_id)
     AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.company_code = l.company_code AND m.trans_id = l.trans_id AND m.jl_line_id = l.line_id)
$$;

-- What a journal came from, for the reconciliation screens (payment / deposit number). Internal.
CREATE OR REPLACE FUNCTION erp._bk_jl_source(p_company varchar, p_trans integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN dp.obj_type IN (24, 46) THEN jsonb_build_object('kind', 'payment', 'direction', CASE dp.obj_type WHEN 24 THEN 'I' ELSE 'O' END,
                                                                    'doc_entry', dp.doc_entry, 'doc_no', x.doc_no)
              WHEN dp.obj_type = 25 THEN jsonb_build_object('kind', 'deposit', 'doc_entry', dp.doc_entry, 'doc_no', d.doc_no)
              WHEN dp.obj_type IS NOT NULL THEN jsonb_build_object('kind', 'document', 'obj_type', dp.obj_type, 'doc_entry', dp.doc_entry) END
    FROM (SELECT 1) one
    LEFT JOIN erp.document_posting dp ON dp.company_code = p_company AND dp.trans_id = p_trans
    LEFT JOIN erp.payment_extra x ON x.company_code = p_company AND x.direction = CASE dp.obj_type WHEN 24 THEN 'I' ELSE 'O' END AND x.doc_entry = dp.doc_entry
    LEFT JOIN erp.deposit d ON d.deposit_id = dp.doc_entry AND dp.obj_type = 25
$$;

-- Statement page: header, every line with its match (journal, payment or deposit), counts.
CREATE OR REPLACE FUNCTION erp.bank_statement_info(p_company varchar, p_statement_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  s erp.bank_statement;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO s FROM erp.bank_statement WHERE company_code = p_company AND statement_id = p_statement_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN to_jsonb(s) || jsonb_build_object(
    'bank_name', (SELECT name FROM erp.bank_account WHERE company_code = p_company AND bank_code = s.bank_code),
    'acct_code', (SELECT acct_code FROM erp.bank_account WHERE company_code = p_company AND bank_code = s.bank_code),
    'imported_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = s.imported_by),
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('banking') OR erp.can_write('finance'),
    'match_days', (SELECT match_days FROM erp.banking_setting WHERE company_code = p_company),
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object('line_id', l.line_id, 'line_no', l.line_no, 'value_date', l.value_date, 'description', l.description,
               'reference', l.reference, 'amount', l.amount,
               'match', CASE WHEN m.match_id IS NOT NULL THEN jsonb_build_object('match_no', m.match_no, 'trans_id', m.trans_id, 'jl_line_id', m.jl_line_id,
                          'how', m.how, 'matched_at', m.matched_at, 'memo', coalesce(jl.memo, je.memo), 'ref_date', je.ref_date,
                          'source', erp._bk_jl_source(p_company, m.trans_id)) END) ORDER BY l.line_no)
        FROM erp.bank_statement_line l
        LEFT JOIN erp.bank_match m ON m.statement_line_id = l.line_id
        LEFT JOIN erp.journal_entry je ON je.company_code = m.company_code AND je.trans_id = m.trans_id
        LEFT JOIN erp.journal_line jl ON jl.company_code = m.company_code AND jl.trans_id = m.trans_id AND jl.line_id = m.jl_line_id
       WHERE l.statement_id = p_statement_id), '[]'::jsonb));
END $$;

-- Auto-match: each unmatched line takes the one journal line on the bank account with the same amount within the date window
-- (banking_setting.match_days, empty = same day). Lines with no or several candidates stay unmatched. Running it again adds nothing.
CREATE OR REPLACE FUNCTION erp.bank_statement_auto_match(p_company varchar, p_statement_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  s       erp.bank_statement;
  v_acct  text;
  v_days  integer;
  l       record;
  v_t     integer;
  v_l     integer;
  v_cnt   integer;
  v_done  integer := 0;
  v_left  integer;
BEGIN
  u := erp._bk_guard(p_company, true, 'reconcile bank statements');
  SELECT * INTO s FROM erp.bank_statement WHERE company_code = p_company AND statement_id = p_statement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank statement % was not found in company %.', p_statement_id, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT acct_code INTO v_acct FROM erp.bank_account WHERE company_code = p_company AND bank_code = s.bank_code;
  v_days := coalesce((SELECT match_days FROM erp.banking_setting WHERE company_code = p_company), 0);
  FOR l IN SELECT sl.* FROM erp.bank_statement_line sl
            WHERE sl.statement_id = p_statement_id AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = sl.line_id)
            ORDER BY sl.line_no LOOP
    SELECT count(*), min(j.trans_id), min(j.line_id) INTO v_cnt, v_t, v_l
      FROM erp._bk_open_jl(p_company, v_acct) j
     WHERE j.amount = l.amount AND j.ref_date BETWEEN l.value_date - v_days AND l.value_date + v_days;
    IF v_cnt = 1 AND (SELECT count(*) FROM erp.bank_statement_line o
                       WHERE o.statement_id = p_statement_id AND o.amount = l.amount
                         AND o.value_date BETWEEN (SELECT j.ref_date FROM erp._bk_open_jl(p_company, v_acct) j WHERE j.trans_id = v_t AND j.line_id = v_l) - v_days
                                              AND (SELECT j.ref_date FROM erp._bk_open_jl(p_company, v_acct) j WHERE j.trans_id = v_t AND j.line_id = v_l) + v_days
                         AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = o.line_id)) = 1 THEN
      -- one candidate journal line, and no other unmatched line of this statement could take it either
      INSERT INTO erp.bank_match (company_code, match_no, statement_line_id, trans_id, jl_line_id, amount, how, matched_by)
      VALUES (p_company, nextval('erp.erp_match_no_seq'), l.line_id, v_t, v_l, l.amount, 'auto', u.user_id);
      v_done := v_done + 1;
    END IF;
  END LOOP;
  SELECT count(*) INTO v_left FROM erp.bank_statement_line sl
   WHERE sl.statement_id = p_statement_id AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = sl.line_id);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bank_statement_auto_match', 'bank_statement', p_statement_id::text,
          jsonb_build_object('matched', v_done, 'unmatched', v_left, 'window_days', v_days));
  RETURN jsonb_build_object('matched', v_done, 'unmatched', v_left);
END $$;

-- Journal lines that could match a statement line by hand: same amount on the bank's G/L account, nearest dates first.
CREATE OR REPLACE FUNCTION erp.bank_statement_candidates(p_company varchar, p_line_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  l      erp.bank_statement_line;
  v_acct text;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO l FROM erp.bank_statement_line WHERE company_code = p_company AND line_id = p_line_id;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  SELECT acct_code INTO v_acct FROM erp.bank_account WHERE company_code = p_company AND bank_code = l.bank_code;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('trans_id', j.trans_id, 'line_id', j.line_id, 'ref_date', j.ref_date, 'amount', j.amount, 'memo', j.memo,
                                        'ref1', j.ref1, 'days', abs(j.ref_date - l.value_date), 'source', erp._bk_jl_source(p_company, j.trans_id))
                     ORDER BY abs(j.ref_date - l.value_date), j.trans_id)
      FROM (SELECT * FROM erp._bk_open_jl(p_company, v_acct) o WHERE o.amount = l.amount ORDER BY abs(o.ref_date - l.value_date), o.trans_id LIMIT 20) j), '[]'::jsonb);
END $$;

-- Match one statement line to one journal line by hand (equal amounts only).
CREATE OR REPLACE FUNCTION erp.bank_statement_match(p_company varchar, p_line_id bigint, p_trans_id integer, p_jl_line_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  l      erp.bank_statement_line;
  jl     erp.journal_line;
  ba     erp.bank_account;
  v_cur  text;
  v_no   integer;
BEGIN
  u := erp._bk_guard(p_company, true, 'reconcile bank statements');
  SELECT * INTO l FROM erp.bank_statement_line WHERE company_code = p_company AND line_id = p_line_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Statement line % was not found in company %.', p_line_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.bank_match WHERE statement_line_id = p_line_id) THEN
    RAISE EXCEPTION 'This statement line is already matched. Unmatch it first.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO ba FROM erp.bank_account WHERE company_code = p_company AND bank_code = l.bank_code;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO jl FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id AND line_id = p_jl_line_id;
  IF jl.trans_id IS NULL THEN
    RAISE EXCEPTION 'Journal line %/% was not found in company %.', p_trans_id, p_jl_line_id, p_company USING ERRCODE = 'P0001';
  ELSIF jl.acct_code <> ba.acct_code THEN
    RAISE EXCEPTION 'Journal line %/% is not on bank account % (G/L %).', p_trans_id, p_jl_line_id, ba.name, ba.acct_code USING ERRCODE = 'P0001';
  ELSIF jl.match_no IS NOT NULL THEN
    RAISE EXCEPTION 'Journal line %/% is already reconciled in SAP Business One (match %).', p_trans_id, p_jl_line_id, jl.match_no USING ERRCODE = 'P0001';
  ELSIF EXISTS (SELECT 1 FROM erp.bank_match WHERE company_code = p_company AND trans_id = p_trans_id AND jl_line_id = p_jl_line_id) THEN
    RAISE EXCEPTION 'Journal line %/% is already matched to another statement line.', p_trans_id, p_jl_line_id USING ERRCODE = 'P0001';
  ELSIF round(jl.debit - jl.credit, 2) <> l.amount THEN
    RAISE EXCEPTION 'The journal line is % % but the statement line is % %. Only equal amounts can be matched.',
      erp._money(jl.debit - jl.credit), v_cur, erp._money(l.amount), v_cur USING ERRCODE = 'P0001';
  END IF;
  v_no := nextval('erp.erp_match_no_seq');
  INSERT INTO erp.bank_match (company_code, match_no, statement_line_id, trans_id, jl_line_id, amount, how, matched_by)
  VALUES (p_company, v_no, p_line_id, p_trans_id, p_jl_line_id, l.amount, 'manual', u.user_id);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bank_statement_match', 'bank_statement', l.statement_id::text,
          jsonb_build_object('line_id', p_line_id, 'trans_id', p_trans_id, 'jl_line_id', p_jl_line_id, 'match_no', v_no, 'amount', l.amount));
  RETURN jsonb_build_object('line_id', p_line_id, 'match_no', v_no);
END $$;

-- Undo a match (the journal itself is never touched).
CREATE OR REPLACE FUNCTION erp.bank_statement_unmatch(p_company varchar, p_line_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  m erp.bank_match;
  v_stmt integer;
BEGIN
  u := erp._bk_guard(p_company, true, 'reconcile bank statements');
  SELECT * INTO m FROM erp.bank_match WHERE company_code = p_company AND statement_line_id = p_line_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This statement line is not matched.' USING ERRCODE = 'P0001';
  END IF;
  SELECT statement_id INTO v_stmt FROM erp.bank_statement_line WHERE line_id = p_line_id;
  DELETE FROM erp.bank_match WHERE match_id = m.match_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bank_statement_unmatch', 'bank_statement', v_stmt::text,
          jsonb_build_object('line_id', p_line_id, 'trans_id', m.trans_id, 'jl_line_id', m.jl_line_id, 'match_no', m.match_no));
  RETURN jsonb_build_object('line_id', p_line_id, 'unmatched', true);
END $$;

-- ============ API: setup ============
-- Check an account for banking use. Returns the problem, or NULL. Internal.
CREATE OR REPLACE FUNCTION erp._bk_acct_problem(p_company varchar, p_acct text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  a erp.account;
BEGIN
  SELECT * INTO a FROM erp.account WHERE company_code = p_company AND acct_code = p_acct;
  IF NOT FOUND THEN
    RETURN format('Account %s does not exist in %s. Check the account code.', p_acct, p_company);
  ELSIF NOT a.postable THEN
    RETURN format('Account %s · %s is a title account. Choose a postable account.', p_acct, a.name);
  ELSIF a.frozen THEN
    RETURN format('Account %s · %s is frozen. Choose another account.', p_acct, a.name);
  ELSIF a.is_control THEN
    RETURN format('Account %s · %s is a control account for customers or suppliers. Choose a bank, cash or clearing account.', p_acct, a.name);
  END IF;
  RETURN NULL;
END $$;

-- Banking › Banking Setup › House Bank Accounts: add or change one (rows from SAP stay read-only). Never deleted, only made inactive.
-- p_acct: {bank_code, name, kind, acct_code, bank_name, account_no, iban, swift, currency, active, note}
CREATE OR REPLACE FUNCTION erp.bank_account_save(p_company varchar, p_acct jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  r      jsonb := coalesce(p_acct, '{}'::jsonb);
  v_code text := upper(nullif(btrim(r->>'bank_code'), ''));
  v_name text := nullif(btrim(r->>'name'), '');
  v_kind text := coalesce(nullif(btrim(r->>'kind'), ''), 'bank');
  v_gl   text := nullif(btrim(r->>'acct_code'), '');
  v_iban text := nullif(upper(regexp_replace(coalesce(r->>'iban', ''), '\s', '', 'g')), '');
  old    erp.bank_account;
  v_other text;
  v_msg  text;
BEGIN
  u := erp._bk_guard(p_company, true, 'change the banking setup');
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Enter a code for the bank account, for example BNK-AED.' USING ERRCODE = 'P0001';
  ELSIF v_code !~ '^[A-Z0-9][A-Z0-9_-]{1,19}$' THEN
    RAISE EXCEPTION 'The code can use letters, numbers, - and _ (2 to 20 characters).' USING ERRCODE = 'P0001';
  ELSIF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter a name for the bank account.' USING ERRCODE = 'P0001';
  ELSIF v_kind NOT IN ('bank', 'cash') THEN
    RAISE EXCEPTION 'Choose bank or cash.' USING ERRCODE = 'P0001';
  ELSIF v_gl IS NULL THEN
    RAISE EXCEPTION 'Choose the G/L account the money is kept in.' USING ERRCODE = 'P0001';
  ELSIF v_iban IS NOT NULL AND v_iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' THEN
    RAISE EXCEPTION 'The IBAN % is not valid. It starts with the country code and two check digits, e.g. AE07 0331 2345 6789 0123 456.', v_iban USING ERRCODE = 'P0001';
  END IF;
  v_msg := erp._bk_acct_problem(p_company, v_gl);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_code FOR UPDATE;
  IF FOUND AND old.source = 'sap' THEN
    RAISE EXCEPTION 'Bank account % comes from SAP Business One and is read-only during the soft switch.', v_code USING ERRCODE = 'P0001';
  END IF;
  SELECT bank_code INTO v_other FROM erp.bank_account WHERE company_code = p_company AND acct_code = v_gl AND bank_code <> v_code;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'Account % is already used by bank account %.', v_gl, v_other USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.bank_account (company_code, bank_code, name, kind, acct_code, bank_name, account_no, iban, swift, currency, active, note, source, updated_by, updated_at)
  VALUES (p_company, v_code, v_name, v_kind, v_gl, nullif(btrim(r->>'bank_name'), ''), nullif(btrim(r->>'account_no'), ''), v_iban,
          nullif(upper(btrim(r->>'swift')), ''), coalesce(nullif(upper(btrim(r->>'currency')), ''), (SELECT currency FROM erp.company WHERE company_code = p_company)),
          coalesce((r->>'active')::boolean, true), nullif(btrim(r->>'note'), ''), 'erp', u.user_id, now())
  ON CONFLICT (company_code, bank_code) DO UPDATE
    SET name = EXCLUDED.name, kind = EXCLUDED.kind, acct_code = EXCLUDED.acct_code, bank_name = EXCLUDED.bank_name, account_no = EXCLUDED.account_no,
        iban = EXCLUDED.iban, swift = EXCLUDED.swift, currency = EXCLUDED.currency, active = EXCLUDED.active, note = EXCLUDED.note,
        source = CASE WHEN erp.bank_account.source = 'sample' THEN 'sample' ELSE 'erp' END, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.bank_code IS NULL THEN 'bank_account_create' ELSE 'bank_account_update' END, 'bank_account', v_code,
          jsonb_build_object('before', CASE WHEN old.bank_code IS NOT NULL THEN to_jsonb(old) - 'updated_by' - 'updated_at' END,
                             'after', (SELECT to_jsonb(b) - 'updated_by' - 'updated_at' FROM erp.bank_account b WHERE company_code = p_company AND bank_code = v_code)));
  RETURN (SELECT to_jsonb(b) FROM erp.bank_account b WHERE company_code = p_company AND bank_code = v_code);
END $$;

-- Banking › Banking Setup › accounts for cash, cheques received and card receipts, and the statement matching window.
-- p_setting: {cash_acct, cheque_acct, card_acct, match_days}; '' or null clears a value.
CREATE OR REPLACE FUNCTION erp.banking_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  r      jsonb := coalesce(p_setting, '{}'::jsonb);
  old    erp.banking_setting;
  k      text;
  v_acct text;
  v_msg  text;
  v_days integer;
BEGIN
  u := erp._bk_guard(p_company, true, 'change the banking setup');
  FOREACH k IN ARRAY ARRAY['cash_acct', 'cheque_acct', 'card_acct'] LOOP
    v_acct := nullif(btrim(r->>k), '');
    IF v_acct IS NOT NULL THEN
      v_msg := erp._bk_acct_problem(p_company, v_acct);
      IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END LOOP;
  IF nullif(btrim(r->>'match_days'), '') IS NOT NULL THEN
    v_days := erp._num(r->>'match_days')::integer;
    IF v_days IS NULL OR v_days NOT BETWEEN 0 AND 60 OR erp._num(r->>'match_days') <> v_days THEN
      RAISE EXCEPTION 'The matching window must be a whole number of days between 0 and 60.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  SELECT * INTO old FROM erp.banking_setting WHERE company_code = p_company FOR UPDATE;
  INSERT INTO erp.banking_setting (company_code, cash_acct, cheque_acct, card_acct, match_days, updated_by, updated_at)
  VALUES (p_company, nullif(btrim(r->>'cash_acct'), ''), nullif(btrim(r->>'cheque_acct'), ''), nullif(btrim(r->>'card_acct'), ''), v_days, u.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET cash_acct = EXCLUDED.cash_acct, cheque_acct = EXCLUDED.cheque_acct, card_acct = EXCLUDED.card_acct,
                                           match_days = EXCLUDED.match_days, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'banking_setting_set', 'banking_setting', p_company,
          jsonb_build_object('before', to_jsonb(old) - 'updated_by' - 'updated_at',
                             'after', (SELECT to_jsonb(s) - 'updated_by' - 'updated_at' FROM erp.banking_setting s WHERE company_code = p_company)));
  RETURN (SELECT to_jsonb(s) FROM erp.banking_setting s WHERE company_code = p_company);
END $$;

-- Add or change a business partner's bank details. Every change is logged in bp_bank_change; a change in the last N days
-- (approval_rule 'bank_change') sends the supplier's outgoing payments to two-step approval. Business Partners, Banking or
-- Financials with full access. Bank details from SAP stay read-only.
-- p_bank: {bp_bank_id (change) | null (add), bank_name, account_no, iban, swift, holder, active}
CREATE OR REPLACE FUNCTION erp.bp_bank_account_save(p_company varchar, p_card text, p_bank jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  r      jsonb := coalesce(p_bank, '{}'::jsonb);
  v_id   integer := erp._num(r->>'bp_bank_id')::integer;
  v_bank text := nullif(btrim(r->>'bank_name'), '');
  v_acc  text := nullif(btrim(r->>'account_no'), '');
  v_iban text := nullif(upper(regexp_replace(coalesce(r->>'iban', ''), '\s', '', 'g')), '');
  v_act  boolean := coalesce((r->>'active')::boolean, true);
  old    erp.bp_bank_account;
  v_new  jsonb;
  v_kind text;
  bp     erp.business_partner;
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
  IF NOT (erp.can_write('bp') OR erp.can_write('banking') OR erp.can_write('finance')) THEN
    IF erp.can_read('bp') OR erp.can_read('banking') OR erp.can_read('finance') THEN
      RAISE EXCEPTION 'You have read-only access. Ask the system admin for full access to change bank details.' USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Your position does not include Business Partners, Banking or Financials. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business partner % does not exist in company %. Check the code.', coalesce(p_card, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_bank IS NULL THEN
    RAISE EXCEPTION 'Enter the bank name.' USING ERRCODE = 'P0001';
  ELSIF v_acc IS NULL AND v_iban IS NULL THEN
    RAISE EXCEPTION 'Enter the account number or the IBAN.' USING ERRCODE = 'P0001';
  ELSIF v_iban IS NOT NULL AND v_iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' THEN
    RAISE EXCEPTION 'The IBAN % is not valid. It starts with the country code and two check digits, e.g. AE07 0331 2345 6789 0123 456.', v_iban USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.bp_bank_account WHERE bp_bank_id = v_id AND company_code = p_company AND card_code = p_card FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Bank account % was not found for %.', v_id, p_card USING ERRCODE = 'P0001';
    ELSIF old.source = 'sap' THEN
      RAISE EXCEPTION 'These bank details came from SAP Business One and are read-only during the soft switch.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_new := jsonb_build_object('bank_name', v_bank, 'account_no', v_acc, 'iban', v_iban, 'swift', nullif(upper(btrim(r->>'swift')), ''),
                              'holder', nullif(btrim(r->>'holder'), ''), 'active', v_act);
  IF v_id IS NOT NULL AND v_new = jsonb_build_object('bank_name', old.bank_name, 'account_no', old.account_no, 'iban', old.iban, 'swift', old.swift,
                                                     'holder', old.holder, 'active', old.active) THEN
    RAISE EXCEPTION 'Nothing changed.' USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO erp.bp_bank_account (company_code, card_code, bank_name, account_no, iban, swift, holder, active, source, updated_by)
    VALUES (p_company, p_card, v_bank, v_acc, v_iban, v_new->>'swift', v_new->>'holder', v_act, 'erp', u.user_id)
    RETURNING bp_bank_id INTO v_id;
    v_kind := 'added';
  ELSE
    UPDATE erp.bp_bank_account SET bank_name = v_bank, account_no = v_acc, iban = v_iban, swift = v_new->>'swift', holder = v_new->>'holder',
                                   active = v_act, updated_by = u.user_id, updated_at = now()
     WHERE bp_bank_id = v_id;
    v_kind := CASE WHEN old.active AND NOT v_act THEN 'deactivated' ELSE 'changed' END;
  END IF;
  INSERT INTO erp.bp_bank_change (company_code, card_code, bp_bank_id, change_kind, before, after, changed_by)
  VALUES (p_company, p_card, v_id, v_kind,
          CASE WHEN old.bp_bank_id IS NOT NULL THEN jsonb_build_object('bank_name', old.bank_name, 'account_no', old.account_no, 'iban', old.iban,
                                                                       'swift', old.swift, 'holder', old.holder, 'active', old.active) END, v_new, u.user_id);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bp_bank_change', 'business_partner', p_card,
          jsonb_build_object('bp_bank_id', v_id, 'change', v_kind, 'before', CASE WHEN old.bp_bank_id IS NOT NULL THEN to_jsonb(old) - 'updated_by' END, 'after', v_new));
  RETURN jsonb_build_object('bp_bank_id', v_id, 'change', v_kind, 'changed_at', now());
END $$;

-- ============ API: Banking Reports › cash position ============
-- Balance of every house bank and cash account (SAP balance at the last sync + Super ERP journals), cheques and card receipts
-- not yet in the bank, outgoing payments waiting for approval, statement lines not yet matched.
CREATE OR REPLACE FUNCTION erp.cash_position(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  st erp.banking_setting;
  v_accounts jsonb;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'bank_code', b.bank_code, 'name', b.name, 'kind', b.kind, 'acct_code', b.acct_code, 'bank_name', b.bank_name, 'iban', b.iban,
           'currency', b.currency, 'balance', erp._bk_gl_balance(p_company, b.acct_code),
           'unmatched', (SELECT count(*) FROM erp.bank_statement_line l WHERE l.company_code = p_company AND l.bank_code = b.bank_code
                           AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = l.line_id)),
           'unmatched_amount', (SELECT coalesce(sum(l.amount), 0) FROM erp.bank_statement_line l WHERE l.company_code = p_company AND l.bank_code = b.bank_code
                                  AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = l.line_id)),
           'last_statement', (SELECT max(l.value_date) FROM erp.bank_statement_line l WHERE l.company_code = p_company AND l.bank_code = b.bank_code))
         ORDER BY b.kind, b.bank_code), '[]'::jsonb)
    INTO v_accounts FROM erp.bank_account b WHERE b.company_code = p_company AND b.active;
  RETURN jsonb_build_object(
    'company_code', p_company, 'currency', (SELECT currency FROM erp.company WHERE company_code = p_company), 'as_of', now(),
    'accounts', v_accounts,
    'total', (SELECT coalesce(sum((a->>'balance')::numeric), 0) FROM jsonb_array_elements(v_accounts) a),
    'cheque_acct', CASE WHEN st.cheque_acct IS NOT NULL THEN jsonb_build_object('acct_code', st.cheque_acct, 'balance', erp._bk_gl_balance(p_company, st.cheque_acct)) END,
    'card_acct', CASE WHEN st.card_acct IS NOT NULL THEN jsonb_build_object('acct_code', st.card_acct, 'balance', erp._bk_gl_balance(p_company, st.card_acct)) END,
    'cheques', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(c.amount), 0),
                                          'due_count', count(*) FILTER (WHERE c.due_date <= current_date),
                                          'due_amount', coalesce(sum(c.amount) FILTER (WHERE c.due_date <= current_date), 0),
                                          'post_dated_count', count(*) FILTER (WHERE c.due_date > current_date),
                                          'post_dated_amount', coalesce(sum(c.amount) FILTER (WHERE c.due_date > current_date), 0))
                  FROM erp.payment_cheque c JOIN erp.payment p ON p.company_code = c.company_code AND p.direction = c.direction AND p.doc_entry = c.doc_entry
                 WHERE c.company_code = p_company AND c.direction = 'I' AND c.deposit_id IS NULL AND NOT p.cancelled),
    'pending_out', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(total), 0))
                      FROM erp.payment_draft WHERE company_code = p_company AND direction = 'O' AND state = 'pending_approval'));
END $$;

-- ============ Approvals inbox (replaces 19's): sales orders, quotations and journals exactly as before, plus payments ============
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
      SELECT a.*, 'sales_quotation'::text, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 23 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'sales_quotation' AND erp.can_see(a.company_code)
      UNION ALL
      SELECT a.*, 'journal'::text, j.draft_id::text, j.state, j.reason, j.submitted_by, j.draft_id, NULL::varchar, j.memo, j.total, j.currency
        FROM erp.approval a
        JOIN erp.journal_draft j ON j.company_code = a.company_code AND j.draft_id::text = a.object_ref
       WHERE a.object = 'journal' AND erp.can_see(a.company_code) AND erp.can_read('finance')
      UNION ALL
      SELECT a.*, 'payment'::text, p.draft_id::text, p.state, p.reason, p.created_by, p.draft_id, p.card_code, p.card_name, p.total, p.currency
        FROM erp.approval a
        JOIN erp.payment_draft p ON p.company_code = a.company_code AND p.draft_id::text = a.object_ref
       WHERE a.object = 'payment' AND erp.can_see(a.company_code) AND (erp.can_read('banking') OR erp.can_read('finance'))
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
REVOKE ALL ON FUNCTION erp._bk_guard(varchar, boolean, text), erp._bk_name(integer), erp._bk_number(varchar, integer),
  erp._bk_doc_open(varchar, integer, integer), erp._bk_reserved(varchar, integer, integer, integer), erp._bk_gl_balance(varchar, text),
  erp._pay_eval(varchar, text, jsonb, jsonb, text, integer), erp._pay_post(varchar, text, jsonb, uuid, integer),
  erp._pay_cancel_block(varchar, text, integer), erp._bk_open_jl(varchar, text), erp._bk_jl_source(varchar, integer),
  erp._bk_acct_problem(varchar, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.payment_setup(varchar, text), erp.payment_open_docs(varchar, text, text), erp.payment_checks(varchar, text, jsonb, jsonb),
  erp.payment_submit(varchar, text, jsonb, jsonb, text), erp.payment_decide(varchar, integer, text, text), erp.payment_draft_cancel(varchar, integer, text),
  erp.payment_draft_info(varchar, integer), erp.payment_info(varchar, text, integer), erp.payment_cancel(varchar, text, integer, date, text),
  erp.deposit_setup(varchar), erp.deposit_create(varchar, jsonb, jsonb),
  erp.bank_statement_import(varchar, text, text, jsonb), erp.bank_statement_info(varchar, integer), erp.bank_statement_auto_match(varchar, integer),
  erp.bank_statement_candidates(varchar, bigint), erp.bank_statement_match(varchar, bigint, integer, integer), erp.bank_statement_unmatch(varchar, bigint),
  erp.bank_account_save(varchar, jsonb), erp.banking_setting_set(varchar, jsonb), erp.bp_bank_account_save(varchar, text, jsonb),
  erp.cash_position(varchar), erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.payment_setup(varchar, text), erp.payment_open_docs(varchar, text, text), erp.payment_checks(varchar, text, jsonb, jsonb),
  erp.payment_submit(varchar, text, jsonb, jsonb, text), erp.payment_decide(varchar, integer, text, text), erp.payment_draft_cancel(varchar, integer, text),
  erp.payment_draft_info(varchar, integer), erp.payment_info(varchar, text, integer), erp.payment_cancel(varchar, text, integer, date, text),
  erp.deposit_setup(varchar), erp.deposit_create(varchar, jsonb, jsonb),
  erp.bank_statement_import(varchar, text, text, jsonb), erp.bank_statement_info(varchar, integer), erp.bank_statement_auto_match(varchar, integer),
  erp.bank_statement_candidates(varchar, bigint), erp.bank_statement_match(varchar, bigint, integer, integer), erp.bank_statement_unmatch(varchar, bigint),
  erp.bank_account_save(varchar, jsonb), erp.banking_setting_set(varchar, jsonb), erp.bp_bank_account_save(varchar, text, jsonb),
  erp.cash_position(varchar), erp.approval_inbox()
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Three clearing accounts in ZZ99's sample chart (cash on hand, cheques received, card receipts).
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', v.code, v.code, v.name, '1100', 3, true, 'other', 1, 'AED', false, false, 0, 'sample'
  FROM (VALUES ('1105', 'Cash on hand (SAMPLE)'), ('1130', 'Cheques received, not yet deposited (SAMPLE)'),
               ('1140', 'Card receipts to be settled (SAMPLE)')) AS v(code, name)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, acct_code) DO NOTHING;

-- House bank and cash accounts.
INSERT INTO erp.bank_account (company_code, bank_code, name, kind, acct_code, bank_name, account_no, iban, swift, currency, source, note)
SELECT 'ZZ99', v.code, v.name, v.kind, v.acct, v.bank, v.no, v.iban, v.swift, 'AED', 'sample', 'SAMPLE account for test company ZZ99 only'
  FROM (VALUES ('BNK-AED', 'Main bank account AED', 'bank', '1110', 'Sample Bank (test)', '0000000001', 'AE070331234567890123456', 'SMPLAEAD'),
               ('CASH', 'Cash on hand', 'cash', '1105', NULL, NULL, NULL, NULL)) AS v(code, name, kind, acct, bank, no, iban, swift)
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = v.acct)
ON CONFLICT (company_code, bank_code) DO NOTHING;

INSERT INTO erp.banking_setting (company_code, cash_acct, cheque_acct, card_acct, match_days, note)
SELECT 'ZZ99', '1105', '1130', '1140', 3, 'SAMPLE setting for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.account WHERE company_code = 'ZZ99' AND acct_code = '1140')
ON CONFLICT (company_code) DO NOTHING;

-- Numbering: incoming payments, outgoing payments, deposits.
INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', v.obj, v.prefix, 1, 5
  FROM (VALUES (24, 'RC-26-'), (46, 'PV-26-'), (25, 'DP-26-')) AS v(obj, prefix)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

-- Outgoing payments above 20,000 AED entered by QA · finance need QA · finance manager. A supplier whose bank details changed
-- in the last 30 days (design › approval templates) needs QA · finance manager and then QA · owner. SAMPLE rules.
INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', 46, v.rule, v.pos, v.lim, v.appr, v.step, 'SAMPLE rule for test company ZZ99 only'
  FROM (VALUES ('payment_amount', 'QA_FINANCE', 20000, 'QA_FIN_MGR', 1), ('bank_change', NULL, 30, 'QA_FIN_MGR', 1),
               ('bank_change', NULL, 30, 'QA_OWNER', 2)) AS v(rule, pos, lim, appr, step)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.appr)
   AND (v.pos IS NULL OR EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.pos))
ON CONFLICT (company_code, obj_type, rule_code, (coalesce(position_code, '')), step) DO NOTHING;

-- Bank details on file for one sample supplier (no recent change, so its payments are not blocked).
INSERT INTO erp.bp_bank_account (company_code, card_code, bank_name, account_no, iban, swift, holder, source, created_at, updated_at)
SELECT 'ZZ99', 'S0005', 'Sample Bank (test)', '0000000099', 'AE460330000010123456789', 'SMPLAEAD', 'Local Carton Supplier', 'sample',
       now() - interval '400 days', now() - interval '400 days'
 WHERE EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'S0005')
   AND NOT EXISTS (SELECT 1 FROM erp.bp_bank_account WHERE company_code = 'ZZ99' AND card_code = 'S0005');
