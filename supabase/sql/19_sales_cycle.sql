-- A4 · Sales cycle: quotation → order → delivery → A/R invoice → A/R credit memo, with Available-to-Promise.
-- Safe to run twice. Does not edit 10–18 (earlier behaviour is changed here with CREATE OR REPLACE, keeping its tests passing).
--
-- Every document made here is a row in erp.document / erp.document_line with source = 'erp', its own number range
-- (erp.number_series) and an ERP doc_entry from 900000000 up. SAP and sample rows are never written: only Super ERP
-- documents can be copied on (their open quantities change), and SAP-sourced customers get their ERP balance change in
-- erp.bp_balance_erp instead of erp.business_partner.balance.
--
-- Objects:
--   erp.atp_rule            – Setup › Sales › ATP Checking Rule List (what counts as available). ZZ99 sample only
--   erp.warehouse_setting   – allow_negative per warehouse (no row = negative stock refused)
--   erp.bp_balance_erp      – ERP-side balance change of SAP-sourced customers
--   erp.erp_stock_seq       – stock_movement.trans_seq for Super ERP documents, from 900000000 up
--   erp.doc_workflow        – existing (17); gets return_stock (credit memos)
--   erp.sales_doc_list      – view for the quotation / delivery / invoice / credit memo lists, security_invoker
--   internal                – _sd_name/_sd_noun/_sd_object, _sd_guard, _sd_eval (17's _so_eval now calls it), _sd_stored,
--                             _sd_lock, _atp_rule, _atp, _sd_order_status (trigger), _stock_out, _stock_in, _bp_balance_add,
--                             _sd_new_doc, post_document (replaced: + 15 COGS, + 14 stock return)
--   API                     – sales_doc_setup / checks / save / submit / decide / cancel / info (23 quotation, 17 order;
--                             the A2 sales_order_* functions are now wrappers), sales_copy_source, sales_delivery_create,
--                             sales_invoice_create, sales_credit_memo_create, sales_doc_flow, sales_print_data, atp, atp_check,
--                             atp_rule_save, warehouse_setting_set, approval_inbox (replaced: + quotations)
--
-- A2 behaviour changes (made here, 17 untouched):
--   * An order that becomes open commits its stock (stock_balance.committed) and uses up the quotation it was copied from;
--     cancelling an open order releases both.
--   * Promising more than Available-to-Promise needs a reason on submit (logged in the submit audit row).
--
-- Business values (ATP rule, numbering, the sample service item) are seeded for the sample company ZZ99 only and marked
-- SAMPLE. Real companies start empty (A4 walkthrough › Needs from Ashif).

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.atp_rule (
    rule_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    rule_code      text NOT NULL,                     -- e.g. ATP-STD
    name           text NOT NULL,
    whs_scope      text NOT NULL DEFAULT 'order_whs' CHECK (whs_scope IN ('order_whs', 'all_whs')),
    subtract_committed boolean NOT NULL DEFAULT true, -- open sales orders already promised
    include_purchase_orders boolean NOT NULL DEFAULT true,   -- open PO lines due by the date
    include_transfers boolean NOT NULL DEFAULT false, -- open transfer requests into the warehouse due by the date
    include_in_transit boolean NOT NULL DEFAULT false,-- container ETAs (A6 shipments; nothing to count until A6)
    no_check       boolean NOT NULL DEFAULT false,    -- made to order: no stock check
    item_group     integer,                           -- used for items in this group; NULL = any item
    is_default     boolean NOT NULL DEFAULT false,
    active         boolean NOT NULL DEFAULT true,
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, rule_code)
);
CREATE UNIQUE INDEX IF NOT EXISTS atp_rule_one_default ON erp.atp_rule (company_code) WHERE is_default AND active;

CREATE TABLE IF NOT EXISTS erp.warehouse_setting (
    company_code   varchar(8) NOT NULL,
    whs_code       varchar(8) NOT NULL,
    allow_negative boolean NOT NULL DEFAULT false,
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, whs_code),
    FOREIGN KEY (company_code, whs_code) REFERENCES erp.warehouse ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.bp_balance_erp (
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    balance        numeric(19,6) NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, card_code),
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);

CREATE SEQUENCE IF NOT EXISTS erp.erp_stock_seq AS bigint START WITH 900000000 MINVALUE 900000000;

ALTER TABLE erp.doc_workflow ADD COLUMN IF NOT EXISTS return_stock boolean;

-- Super ERP documents write stock movements; let the sample company be removed and reloaded (15_sample_company.sql
-- deletes erp.company ZZ99 last). Real companies are never deleted.
ALTER TABLE erp.stock_movement DROP CONSTRAINT IF EXISTS stock_movement_company_code_fkey;
ALTER TABLE erp.stock_movement ADD CONSTRAINT stock_movement_company_code_fkey
  FOREIGN KEY (company_code) REFERENCES erp.company ON DELETE CASCADE;
-- document_posting rows of the sample company go with its documents.
CREATE INDEX IF NOT EXISTS document_line_base_line_idx ON erp.document_line (company_code, base_obj_type, base_doc_entry, base_line);

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.atp_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.warehouse_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bp_balance_erp ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.atp_rule, erp.warehouse_setting, erp.bp_balance_erp FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.atp_rule, erp.warehouse_setting, erp.bp_balance_erp TO authenticated;
REVOKE ALL ON SEQUENCE erp.erp_stock_seq FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS atp_rule_read ON erp.atp_rule;
CREATE POLICY atp_rule_read ON erp.atp_rule FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('sales')) OR (SELECT erp.can_read('inventory'))));
DROP POLICY IF EXISTS warehouse_setting_read ON erp.warehouse_setting;
CREATE POLICY warehouse_setting_read ON erp.warehouse_setting FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('sales')) OR (SELECT erp.can_read('inventory')) OR (SELECT erp.can_read('purchase'))));
DROP POLICY IF EXISTS bp_balance_erp_read ON erp.bp_balance_erp;
CREATE POLICY bp_balance_erp_read ON erp.bp_balance_erp FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('bp')) OR (SELECT erp.can_read('sales')) OR (SELECT erp.can_read('finance'))));

-- Lists for quotations, deliveries, invoices and credit memos: SAP, sample and Super ERP documents side by side.
CREATE OR REPLACE VIEW erp.sales_doc_list WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status,
       w.state, d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total, d.vat_total,
       d.paid, d.source, d.created_on
  FROM erp.document d
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (23, 17, 15, 13, 14);
REVOKE ALL ON erp.sales_doc_list FROM PUBLIC, anon;
GRANT SELECT ON erp.sales_doc_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
CREATE OR REPLACE FUNCTION erp._sd_name(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 23 THEN 'Sales quotation' WHEN 17 THEN 'Sales order' WHEN 15 THEN 'Delivery' WHEN 13 THEN 'A/R invoice'
                    WHEN 14 THEN 'A/R credit memo' WHEN 16 THEN 'Return' ELSE 'Document' END
$$;
CREATE OR REPLACE FUNCTION erp._sd_noun(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 23 THEN 'quotation' WHEN 17 THEN 'order' WHEN 15 THEN 'delivery' WHEN 13 THEN 'invoice'
                    WHEN 14 THEN 'credit memo' ELSE 'document' END
$$;
-- erp.approval.object / erp.audit_log.object for each document type.
CREATE OR REPLACE FUNCTION erp._sd_object(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 23 THEN 'sales_quotation' WHEN 17 THEN 'sales_order' WHEN 15 THEN 'delivery' WHEN 13 THEN 'ar_invoice'
                    WHEN 14 THEN 'ar_credit_memo' ELSE 'document' END
$$;
-- Number people see: the Super ERP number, else SAP's doc_num.
CREATE OR REPLACE FUNCTION erp._sd_no(p_company varchar, p_obj integer, p_entry integer) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(w.doc_no, d.doc_num::text)
    FROM erp.document d
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_entry
$$;

-- Who is calling, and may they read or change sales documents in this company? (17 keeps _so_guard's exact words.)
CREATE OR REPLACE FUNCTION erp._sd_guard(p_company varchar, p_write boolean, p_obj integer DEFAULT 17) RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF p_obj = 17 OR NOT p_write THEN
    RETURN erp._so_guard(p_company, p_write);
  END IF;
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
  IF NOT erp.can_write('sales') THEN
    IF erp.can_read('sales') THEN
      RAISE EXCEPTION 'You have read-only access to Sales. Ask the system admin for full access to create %.',
        CASE p_obj WHEN 23 THEN 'quotations' WHEN 15 THEN 'deliveries' WHEN 13 THEN 'invoices' WHEN 14 THEN 'credit memos' ELSE 'sales documents' END
        USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Your position does not include Sales. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- The ATP rule for an item: an active rule for its item group, else the company's default rule. NULL = ATP not set up.
CREATE OR REPLACE FUNCTION erp._atp_rule(p_company varchar, p_item text) RETURNS erp.atp_rule
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT r.* FROM erp.atp_rule r
   WHERE r.company_code = p_company AND r.active
     AND (r.item_group = (SELECT group_code FROM erp.item WHERE company_code = p_company AND item_code = p_item) OR (r.item_group IS NULL AND r.is_default))
   ORDER BY (r.item_group IS NULL), r.rule_id LIMIT 1
$$;

-- Available-to-Promise for one item in one warehouse by a date, under one rule:
--   on hand − committed (open orders) + open purchase orders due by the date + open transfer requests due by the date
--   (+ containers in transit when A6 provides ETAs). Returns the parts so the screen can explain the number.
CREATE OR REPLACE FUNCTION erp._atp(p_company varchar, p_item text, p_whs text, p_date date, r erp.atp_rule) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_all   boolean := r.whs_scope = 'all_whs';
  v_oh    numeric := 0;
  v_cm    numeric := 0;
  v_po    numeric := 0;
  v_tr    numeric := 0;
  v_it    numeric := 0;
BEGIN
  IF r.rule_id IS NULL OR r.no_check THEN
    RETURN jsonb_build_object('rule_code', r.rule_code, 'no_check', coalesce(r.no_check, false), 'available', NULL, 'date', p_date);
  END IF;
  SELECT coalesce(sum(on_hand), 0), coalesce(sum(committed), 0) INTO v_oh, v_cm
    FROM erp.stock_balance WHERE company_code = p_company AND item_code = p_item AND (v_all OR whs_code = p_whs);
  IF r.include_purchase_orders THEN
    SELECT coalesce(sum(l.open_qty), 0) INTO v_po
      FROM erp.document d JOIN erp.document_line l ON l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry
     WHERE d.company_code = p_company AND d.obj_type = 22 AND d.status = 'open' AND coalesce(l.line_status, 'O') = 'O'
       AND l.item_code = p_item AND (v_all OR l.whs_code = p_whs) AND coalesce(d.due_date, d.doc_date) <= p_date;
  END IF;
  IF r.include_transfers AND NOT v_all THEN
    SELECT coalesce(sum(l.open_qty), 0) INTO v_tr
      FROM erp.document d JOIN erp.document_line l ON l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry
     WHERE d.company_code = p_company AND d.obj_type = 1250000001 AND d.status = 'open' AND coalesce(l.line_status, 'O') = 'O'
       AND l.item_code = p_item AND l.whs_code = p_whs AND coalesce(l.from_whs, d.from_whs, '') <> p_whs
       AND coalesce(d.due_date, d.doc_date) <= p_date;
  END IF;
  -- include_in_transit: A6 (purchasing / China shipments) adds container ETAs. Nothing to count before that.
  RETURN jsonb_build_object('rule_code', r.rule_code, 'rule_name', r.name, 'no_check', false, 'date', p_date,
    'scope', r.whs_scope, 'on_hand', v_oh, 'committed', CASE WHEN r.subtract_committed THEN v_cm ELSE 0 END,
    'purchase_orders', v_po, 'transfers', v_tr, 'in_transit', v_it,
    'available', v_oh - CASE WHEN r.subtract_committed THEN v_cm ELSE 0 END + v_po + v_tr + v_it);
END $$;

-- Validate, price and check one quotation (23) or order (17). Never writes. Same result shape as A2's _so_eval, plus:
--   lines[].base_obj_type/base_doc_entry/base_line (copied from a quotation), lines[].atp {available, date, rule_code},
--   atp:[{line, item_code, whs_code, qty, available, date, message}] (orders only: what is promised beyond ATP).
-- Quotations use the order's discount and below-cost rules (approval_rule obj_type 17); the credit rule is for orders only.
CREATE OR REPLACE FUNCTION erp._sd_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_atp    jsonb := '[]';
  v_credit jsonb;
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  bp       erp.business_partner;
  v_bp_ok  boolean := false;
  v_doc_date date;
  v_due    date;
  v_pl     integer;
  v_terms  integer;
  v_slp    integer;
  v_whs    text;
  v_branch integer;
  v_def_tax text;
  v_def_whs text;
  l        jsonb;
  i        integer := 0;
  n        text;
  it       erp.item;
  v_item_ok boolean;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_disc   numeric;
  v_tax    text;
  v_tc     erp.tax_code;
  v_lwhs   text;
  v_ok     boolean;
  v_cost   numeric;
  v_avail  numeric;
  v_sb_cost numeric;
  v_gross  numeric := 0;
  v_net    numeric := 0;
  v_vat    numeric := 0;
  v_lt     numeric;
  v_lv     numeric;
  r        record;
  x        record;
  v_open   numeric;
  v_exposure numeric;
  v_bobj   integer;
  v_bentry integer;
  v_bline  integer;
  bd       erp.document;
  bw       erp.doc_workflow;
  bl       erp.document_line;
  v_bno    text;
  v_atpd   date;
  ar       erp.atp_rule;
  v_a      jsonb;
  v_used   jsonb := '{}'::jsonb;    -- item|whs → quantity already promised by earlier lines of this order
  v_key    text;
  v_prev   numeric;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT default_tax_code, default_whs_code INTO v_def_tax, v_def_whs FROM erp.sales_setting WHERE company_code = p_company;

  -- Customer
  IF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', 'Choose a customer.');
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s does not exist in company %s. Check the code.', v_card, p_company));
    ELSIF bp.kind <> 'customer' THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a customer. Choose a customer.', v_card));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s is inactive. Choose an active customer.', v_card));
    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s is billed in %s. Orders in a foreign currency come in a later stage.', v_card, bp.currency));
    ELSE
      v_bp_ok := true;
      bp.balance := coalesce(bp.balance, 0) + coalesce((SELECT b.balance FROM erp.bp_balance_erp b WHERE b.company_code = p_company AND b.card_code = v_card), 0);
    END IF;
  END IF;

  -- Dates
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_doc_date := erp._date(h->>'doc_date');
    IF v_doc_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN p_obj = 23 THEN 'The valid-until date is not a valid date.' ELSE 'The delivery date is not a valid date.' END);
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN p_obj = 23 THEN 'The valid-until date can''t be before the posting date.' ELSE 'The delivery date can''t be before the posting date.' END);
    END IF;
  END IF;

  -- Price list, payment terms, salesperson: the header value, else the customer's own
  v_pl := coalesce(erp._num(h->>'price_list')::integer, CASE WHEN v_bp_ok THEN bp.price_list END);
  IF v_pl IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.price_list WHERE company_code = p_company AND list_num = v_pl) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'price_list', 'message', format('Price list %s does not exist.', v_pl));
  END IF;
  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);
  IF v_terms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_terms) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'payment_terms', 'message', format('Payment terms %s do not exist.', v_terms));
  END IF;
  v_slp := coalesce(erp._num(h->>'slp_code')::integer, CASE WHEN v_bp_ok THEN bp.slp_code END);
  IF v_slp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.salesperson WHERE company_code = p_company AND slp_code = v_slp) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'slp_code', 'message', format('Salesperson %s does not exist.', v_slp));
  END IF;

  -- Header warehouse (lines use it unless they name their own)
  v_whs := coalesce(nullif(btrim(h->>'whs_code'), ''), v_def_whs);
  IF v_whs IS NOT NULL THEN
    SELECT branch_id INTO v_branch FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist in company %s.', v_whs, p_company));
    ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is inactive. Choose another warehouse.', v_whs));
    END IF;
  END IF;
  v_atpd := coalesce(v_due, v_doc_date);

  -- Lines
  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one line.');
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_ok := true;
    v_item_ok := false;
    v_code := nullif(btrim(l->>'item_code'), '');
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'choose an item.');
      v_ok := false;
    ELSE
      SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('item %s does not exist. Check the item code.', v_code));
        v_ok := false;
      ELSIF NOT it.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is inactive. Choose an active item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_sold, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a sales item.', v_code));
        v_ok := false;
      ELSE
        v_item_ok := true;
      END IF;
    END IF;

    v_qty := erp._num(l->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || 'quantity must be more than 0.');
      v_ok := false;
    END IF;

    v_disc := CASE WHEN nullif(btrim(l->>'discount_pct'), '') IS NULL THEN 0 ELSE erp._num(l->>'discount_pct') END;
    IF v_disc IS NULL OR v_disc < 0 OR v_disc > 100 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'discount_pct', 'message', n || 'discount must be between 0 and 100%.');
      v_ok := false;
    END IF;

    v_lwhs := coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs);
    IF v_lwhs IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || 'choose a warehouse.');
      v_ok := false;
    ELSIF v_lwhs IS DISTINCT FROM v_whs THEN
      IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s does not exist in company %s.', v_lwhs, p_company));
        v_ok := false;
      ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs AND active) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s is inactive. Choose another warehouse.', v_lwhs));
        v_ok := false;
      END IF;
    END IF;

    v_tax := coalesce(nullif(btrim(l->>'tax_code'), ''), v_def_tax);
    v_tc := NULL;
    IF v_tax IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || 'choose a tax code.');
      v_ok := false;
    ELSE
      SELECT * INTO v_tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s does not exist.', v_tax));
        v_ok := false;
      ELSIF NOT v_tc.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is inactive.', v_tax));
        v_ok := false;
      ELSIF v_tc.category = 'I' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is for purchases. Choose a sales tax code.', v_tax));
        v_ok := false;
      END IF;
    END IF;

    v_price := NULL;
    IF nullif(btrim(l->>'price'), '') IS NOT NULL THEN
      v_price := erp._num(l->>'price');
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price must be a number.');
        v_ok := false;
      ELSIF v_price < 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price can''t be negative.');
        v_ok := false;
      END IF;
    ELSIF v_item_ok AND v_pl IS NULL AND NOT v_bp_ok THEN
      v_ok := false;   -- no valid customer yet, so no price list to price from (the customer problem is already listed)
    ELSIF v_item_ok THEN
      SELECT price INTO v_price FROM erp.item_price WHERE company_code = p_company AND list_num = v_pl AND item_code = v_code;
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has no price in the customer''s price list. Enter a price.', v_code));
        v_ok := false;
      END IF;
    END IF;

    -- Copied from a quotation: the quotation must be a Super ERP one, open, for this customer and item, with enough left.
    v_bobj := erp._num(l->>'base_obj_type')::integer;
    v_bentry := erp._num(l->>'base_doc_entry')::integer;
    v_bline := erp._num(l->>'base_line')::integer;
    IF v_bentry IS NOT NULL OR v_bobj IS NOT NULL THEN
      IF p_obj <> 17 OR coalesce(v_bobj, 0) <> 23 OR v_bentry IS NULL OR v_bline IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'only a sales order can be copied from a quotation.');
        v_ok := false;
      ELSE
        SELECT * INTO bd FROM erp.document WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry;
        SELECT * INTO bw FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry;
        v_bno := coalesce(bw.doc_no, bd.doc_num::text);
        SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry AND line_num = v_bline;
        IF bd.doc_entry IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s was not found in company %s.', v_bentry, p_company));
          v_ok := false;
        ELSIF bd.source <> 'erp' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s came from %s. Only Super ERP quotations can be copied.',
            v_bno, CASE bd.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
          v_ok := false;
        ELSIF bw.state IS DISTINCT FROM 'approved' OR bd.status <> 'open' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s is not open, so it can''t be copied.', v_bno));
          v_ok := false;
        ELSIF bd.card_code IS DISTINCT FROM v_card THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'card_code', 'message', n || format('quotation %s is for customer %s. Copy it to an order for the same customer.', v_bno, bd.card_code));
          v_ok := false;
        ELSIF bl.line_num IS NULL OR bl.item_code IS DISTINCT FROM v_code THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('the item does not match line %s of quotation %s.', v_bline + 1, v_bno));
          v_ok := false;
        ELSIF v_qty IS NOT NULL AND v_qty > coalesce(bl.open_qty, 0) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || format('only %s of %s are still open on quotation %s.', trim_scale(coalesce(bl.open_qty, 0)), v_code, v_bno));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    IF v_ok THEN
      SELECT sb.avg_cost, sb.on_hand - sb.committed INTO v_sb_cost, v_avail
        FROM erp.stock_balance sb WHERE sb.company_code = p_company AND sb.item_code = v_code AND sb.whs_code = v_lwhs;
      IF NOT FOUND THEN v_sb_cost := NULL; v_avail := NULL; END IF;
      v_cost := coalesce(v_sb_cost, it.avg_cost);
      v_lt := round(v_qty * v_price * (1 - v_disc / 100), 2);
      v_lv := round(v_lt * v_tc.rate / 100, 2);
      v_gross := v_gross + round(v_qty * v_price, 2);
      v_net := v_net + v_lt;
      v_vat := v_vat + v_lv;

      -- Available-to-Promise (orders, stock items, when the company has an ATP rule for the item)
      v_a := NULL;
      IF p_obj = 17 AND coalesce(it.is_stock, false) AND v_atpd IS NOT NULL THEN
        ar := erp._atp_rule(p_company, v_code);
        IF ar.rule_id IS NOT NULL THEN
          v_a := erp._atp(p_company, v_code, v_lwhs, v_atpd, ar);
          IF NOT (v_a->>'no_check')::boolean THEN
            v_key := v_code || '|' || CASE WHEN ar.whs_scope = 'all_whs' THEN '*' ELSE v_lwhs END;
            v_prev := coalesce((v_used->>v_key)::numeric, 0);
            v_used := v_used || jsonb_build_object(v_key, v_prev + v_qty);
            IF v_prev + v_qty > (v_a->>'available')::numeric THEN
              v_atp := v_atp || jsonb_build_object('line', i, 'item_code', v_code, 'whs_code', v_lwhs, 'qty', v_prev + v_qty,
                'available', (v_a->>'available')::numeric, 'date', v_atpd, 'rule_code', ar.rule_code,
                'message', format('Line %s: you are promising %s of %s but can promise only %s by %s.', i, trim_scale(v_prev + v_qty), v_code,
                                  trim_scale(greatest((v_a->>'available')::numeric, 0)), erp._day(v_atpd)));
            END IF;
          END IF;
        END IF;
      END IF;

      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.sales_uom, 'qty', v_qty, 'price', v_price,
        'discount_pct', v_disc, 'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs,
        'line_total', v_lt, 'vat', v_lv, 'cost', v_cost, 'available', v_avail, 'is_stock', coalesce(it.is_stock, false),
        'base_obj_type', CASE WHEN v_bentry IS NOT NULL THEN 23 END, 'base_doc_entry', v_bentry, 'base_line', CASE WHEN v_bentry IS NOT NULL THEN v_bline END,
        'atp', v_a);
    END IF;
  END LOOP;

  -- Credit position (orders; shown on the form even when no rule applies)
  IF v_bp_ok THEN
    SELECT coalesce(sum(total), 0) INTO v_open FROM erp.document
     WHERE company_code = p_company AND obj_type = 17 AND status = 'open' AND card_code = v_card AND (p_obj <> 17 OR doc_entry IS DISTINCT FROM p_doc_entry);
    v_credit := jsonb_build_object('limit', bp.credit_limit, 'balance', coalesce(bp.balance, 0), 'open_orders', v_open,
                                   'this_order', v_net + v_vat, 'left', bp.credit_limit - coalesce(bp.balance, 0) - v_open);
  END IF;

  -- Rule checks (only for a document that is otherwise valid)
  IF jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT ar2.*, p.name AS approver_name FROM erp.approval_rule ar2 JOIN erp.position p ON p.position_code = ar2.approver_position
              WHERE ar2.company_code = p_company AND ar2.obj_type = 17 AND ar2.active
                AND (ar2.position_code = p_position OR (ar2.position_code IS NULL AND ar2.rule_code <> 'discount_pct'))
                AND (p_obj = 17 OR ar2.rule_code IN ('discount_pct', 'below_cost'))
              ORDER BY ar2.step, ar2.rule_code LOOP
      IF r.rule_code = 'discount_pct' THEN
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, discount_pct numeric, item_code text) WHERE t.discount_pct > r.limit_value LOOP
          v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
            'approver_name', r.approver_name, 'line', x.line_num + 1, 'value', x.discount_pct, 'limit', r.limit_value,
            'message', format('Line %s: Discount %s%% is above your limit of %s%%. Submit it for approval or lower the discount.',
                              x.line_num + 1, erp._pct(x.discount_pct), erp._pct(r.limit_value)));
        END LOOP;
      ELSIF r.rule_code = 'credit_limit' THEN
        -- NULL credit limit = not set in SAP: the rule does not apply to this customer.
        IF bp.credit_limit IS NOT NULL THEN
          v_exposure := coalesce(bp.balance, 0) + v_open + v_net + v_vat;
          IF v_exposure > bp.credit_limit THEN
            v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
              'approver_name', r.approver_name, 'line', NULL, 'value', v_exposure, 'limit', bp.credit_limit,
              'message', format('Customer %s would be over the credit limit of %s %s: balance %s + open orders %s + this order %s = %s %s.',
                                v_card, erp._money(bp.credit_limit), v_cur, erp._money(bp.balance), erp._money(v_open),
                                erp._money(v_net + v_vat), erp._money(v_exposure), v_cur));
          END IF;
        END IF;
      ELSIF r.rule_code = 'below_cost' THEN
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, price numeric, discount_pct numeric, cost numeric, item_code text)
                  WHERE t.cost IS NOT NULL AND round(t.price * (1 - t.discount_pct / 100), 4) < t.cost LOOP
          v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
            'approver_name', r.approver_name, 'line', x.line_num + 1, 'value', round(x.price * (1 - x.discount_pct / 100), 4), 'limit', x.cost,
            'message', format('Line %s: net price %s for %s is below its cost of %s.',
                              x.line_num + 1, erp._money(x.price * (1 - x.discount_pct / 100)), x.item_code, erp._money(x.cost)));
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'atp', CASE WHEN jsonb_array_length(v_err) = 0 THEN v_atp ELSE '[]'::jsonb END,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date,
                                 'due_date', v_due, 'price_list', v_pl, 'payment_terms', v_terms, 'slp_code', v_slp, 'whs_code', v_whs,
                                 'branch_id', v_branch, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('before_discount', v_gross, 'discount', v_gross - v_net, 'net', v_net, 'vat', v_vat,
                                 'total', v_net + v_vat, 'currency', v_cur),
    'credit', CASE WHEN p_obj = 17 THEN v_credit END);
END $$;

-- A2's evaluator now runs the generic one (orders).
CREATE OR REPLACE FUNCTION erp._so_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp._sd_eval(p_company, 17, p_header, p_lines, p_position, p_doc_entry)
$$;

-- The stored quotation / order as save-function input (used to re-check it on submit).
CREATE OR REPLACE FUNCTION erp._sd_stored(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('card_code', d.card_code, 'doc_date', d.doc_date, 'due_date', d.due_date, 'price_list', w.price_list,
                                 'payment_terms', w.payment_terms, 'slp_code', d.slp_code, 'whs_code', w.whs_code,
                                 'customer_ref', d.customer_ref, 'comments', d.comments),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', l.item_code, 'qty', l.quantity, 'price', l.price,
                                                          'discount_pct', l.discount_pct, 'tax_code', l.tax_code, 'whs_code', l.whs_code,
                                                          'base_obj_type', l.base_obj_type, 'base_doc_entry', l.base_doc_entry, 'base_line', l.base_line)
                                        ORDER BY l.line_num)
                         FROM erp.document_line l
                        WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry), '[]'::jsonb))
    FROM erp.document d
    JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_doc_entry
$$;
CREATE OR REPLACE FUNCTION erp._so_stored(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp._sd_stored(p_company, 17, p_doc_entry)
$$;

-- Lock and load a Super ERP sales document for a change.
CREATE OR REPLACE FUNCTION erp._sd_lock(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS erp.doc_workflow
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d erp.document;
  w erp.doc_workflow;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% % was not found in company %.', erp._sd_name(p_obj), p_doc_entry, p_company USING ERRCODE = 'P0001';
  END IF;
  IF d.source <> 'erp' THEN
    RAISE EXCEPTION 'This % came from %, so it is read-only in Super ERP.', erp._sd_noun(p_obj),
      CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% % has no workflow record. Ask the system admin to check it.', erp._sd_name(p_obj), p_doc_entry USING ERRCODE = 'P0001';
  END IF;
  RETURN w;
END $$;
CREATE OR REPLACE FUNCTION erp._so_lock(p_company varchar, p_doc_entry integer) RETURNS erp.doc_workflow
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp._sd_lock(p_company, 17, p_doc_entry)
$$;

-- Customer balance after an invoice (+) or credit memo (−). SAP-sourced customers are never written: their Super ERP
-- change is kept in bp_balance_erp and added wherever the balance is shown or checked.
CREATE OR REPLACE FUNCTION erp._bp_balance_add(p_company varchar, p_card text, p_amount numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF p_amount = 0 THEN RETURN; END IF;
  IF (SELECT source FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card) = 'sap' THEN
    INSERT INTO erp.bp_balance_erp (company_code, card_code, balance) VALUES (p_company, p_card, p_amount)
    ON CONFLICT (company_code, card_code) DO UPDATE SET balance = erp.bp_balance_erp.balance + EXCLUDED.balance, updated_at = now();
  ELSE
    UPDATE erp.business_partner SET balance = coalesce(balance, 0) + p_amount WHERE company_code = p_company AND card_code = p_card AND source <> 'sap';
  END IF;
END $$;

-- Stock out of / into a warehouse with its warehouse-journal row. Internal: callers have checked the quantities.
CREATE OR REPLACE FUNCTION erp._stock_move(p_company varchar, p_item text, p_whs text, p_qty_in numeric, p_qty_out numeric, p_cost numeric,
                                           p_obj integer, p_entry integer, p_line integer, p_date date, p_release_committed numeric DEFAULT 0)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  INSERT INTO erp.stock_balance (company_code, item_code, whs_code, on_hand, committed, avg_cost)
  VALUES (p_company, p_item, p_whs, 0, 0, p_cost)
  ON CONFLICT (company_code, item_code, whs_code) DO NOTHING;
  UPDATE erp.stock_balance
     SET avg_cost = CASE WHEN p_qty_in > 0 AND on_hand + p_qty_in > 0 AND on_hand >= 0
                         THEN round((on_hand * coalesce(avg_cost, p_cost) + p_qty_in * p_cost) / (on_hand + p_qty_in), 6)
                         ELSE coalesce(avg_cost, p_cost) END,
         on_hand = on_hand + p_qty_in - p_qty_out,
         committed = greatest(committed - coalesce(p_release_committed, 0), 0)
   WHERE company_code = p_company AND item_code = p_item AND whs_code = p_whs;
  INSERT INTO erp.stock_movement (company_code, trans_seq, trans_type, doc_entry, doc_line, doc_date, item_code, whs_code, qty_in, qty_out, price, currency)
  VALUES (p_company, nextval('erp.erp_stock_seq'), p_obj, p_entry, p_line, p_date, p_item, p_whs, p_qty_in, p_qty_out, p_cost,
          (SELECT currency FROM erp.company WHERE company_code = p_company));
END $$;

-- A Super ERP order changes status: it opens (approved) → commit its stock and use up the quotation it was copied from;
-- it is cancelled while open → release both. Raises when the quotation no longer has enough left.
CREATE OR REPLACE FUNCTION erp._sd_order_status() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r    record;
  v_no text;
BEGIN
  IF NEW.status = 'open' AND OLD.status = 'draft' THEN
    FOR r IN SELECT l.line_num, l.item_code, l.quantity, l.base_doc_entry, l.base_line, ql.open_qty AS q_open, qd.status AS q_status,
                    qw.state AS q_state, coalesce(qw.doc_no, qd.doc_num::text) AS q_no
               FROM erp.document_line l
               LEFT JOIN erp.document_line ql ON ql.company_code = l.company_code AND ql.obj_type = 23 AND ql.doc_entry = l.base_doc_entry AND ql.line_num = l.base_line
               LEFT JOIN erp.document qd ON qd.company_code = l.company_code AND qd.obj_type = 23 AND qd.doc_entry = l.base_doc_entry
               LEFT JOIN erp.doc_workflow qw ON qw.company_code = l.company_code AND qw.obj_type = 23 AND qw.doc_entry = l.base_doc_entry
              WHERE l.company_code = NEW.company_code AND l.obj_type = 17 AND l.doc_entry = NEW.doc_entry AND l.base_obj_type = 23
              ORDER BY l.line_num LOOP
      IF r.q_status IS DISTINCT FROM 'open' OR r.q_state IS DISTINCT FROM 'approved' THEN
        RAISE EXCEPTION 'Line %: quotation % is no longer open, so the order can''t be opened. Remove the copied lines or copy a new quotation.',
          r.line_num + 1, coalesce(r.q_no, r.base_doc_entry::text) USING ERRCODE = 'P0001';
      END IF;
      IF coalesce(r.q_open, 0) < r.quantity THEN
        RAISE EXCEPTION 'Line %: only % of % are still open on quotation %.', r.line_num + 1, trim_scale(coalesce(r.q_open, 0)), r.item_code, r.q_no
          USING ERRCODE = 'P0001';
      END IF;
      UPDATE erp.document_line SET open_qty = open_qty - r.quantity, line_status = CASE WHEN open_qty - r.quantity <= 0 THEN 'C' ELSE 'O' END
       WHERE company_code = NEW.company_code AND obj_type = 23 AND doc_entry = r.base_doc_entry AND line_num = r.base_line;
    END LOOP;
    UPDATE erp.document q SET status = 'closed'
     WHERE q.company_code = NEW.company_code AND q.obj_type = 23 AND q.source = 'erp' AND q.status = 'open'
       AND q.doc_entry IN (SELECT base_doc_entry FROM erp.document_line WHERE company_code = NEW.company_code AND obj_type = 17
                             AND doc_entry = NEW.doc_entry AND base_obj_type = 23)
       AND NOT EXISTS (SELECT 1 FROM erp.document_line ql WHERE ql.company_code = q.company_code AND ql.obj_type = 23
                          AND ql.doc_entry = q.doc_entry AND coalesce(ql.line_status, 'O') = 'O');
    -- Commit stock items in their warehouses (ATP subtracts committed).
    INSERT INTO erp.stock_balance (company_code, item_code, whs_code, committed)
    SELECT l.company_code, l.item_code, l.whs_code, sum(l.quantity)
      FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
     WHERE l.company_code = NEW.company_code AND l.obj_type = 17 AND l.doc_entry = NEW.doc_entry AND l.whs_code IS NOT NULL
     GROUP BY 1, 2, 3
    ON CONFLICT (company_code, item_code, whs_code) DO UPDATE SET committed = erp.stock_balance.committed + EXCLUDED.committed;
  ELSIF NEW.status = 'cancelled' AND OLD.status = 'open' THEN
    UPDATE erp.stock_balance sb SET committed = greatest(sb.committed - s.qty, 0)
      FROM (SELECT l.item_code, l.whs_code, sum(l.open_qty) AS qty
              FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
             WHERE l.company_code = NEW.company_code AND l.obj_type = 17 AND l.doc_entry = NEW.doc_entry GROUP BY 1, 2) s
     WHERE sb.company_code = NEW.company_code AND sb.item_code = s.item_code AND sb.whs_code = s.whs_code;
    FOR r IN SELECT l.quantity, l.base_doc_entry, l.base_line FROM erp.document_line l
              WHERE l.company_code = NEW.company_code AND l.obj_type = 17 AND l.doc_entry = NEW.doc_entry AND l.base_obj_type = 23 LOOP
      UPDATE erp.document_line SET open_qty = least(open_qty + r.quantity, quantity), line_status = 'O'
       WHERE company_code = NEW.company_code AND obj_type = 23 AND doc_entry = r.base_doc_entry AND line_num = r.base_line;
    END LOOP;
    SELECT string_agg(DISTINCT base_doc_entry::text, ',') INTO v_no FROM erp.document_line
     WHERE company_code = NEW.company_code AND obj_type = 17 AND doc_entry = NEW.doc_entry AND base_obj_type = 23;
    IF v_no IS NOT NULL THEN
      UPDATE erp.document q SET status = 'open'
       WHERE q.company_code = NEW.company_code AND q.obj_type = 23 AND q.source = 'erp' AND q.status = 'closed'
         AND q.doc_entry = ANY (string_to_array(v_no, ',')::integer[])
         AND EXISTS (SELECT 1 FROM erp.doc_workflow qw WHERE qw.company_code = q.company_code AND qw.obj_type = 23 AND qw.doc_entry = q.doc_entry AND qw.state = 'approved');
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS sd_order_status ON erp.document;
CREATE TRIGGER sd_order_status AFTER UPDATE OF status ON erp.document FOR EACH ROW
  WHEN (NEW.source = 'erp' AND NEW.obj_type = 17 AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION erp._sd_order_status();

-- Post a Super ERP document (replaces 18's). Internal: the document functions below call it inside their own checks.
--   13 A/R invoice:     Dr receivable (customer) / Cr revenue / Cr output VAT per tax code             (as in 18)
--   14 A/R credit memo: the mirror with Sales returns; plus Dr inventory / Cr COGS at the delivered cost when goods come back
--   15 Delivery:        Dr cost of goods sold / Cr inventory, at the average cost stored on each line (stock items only)
CREATE OR REPLACE FUNCTION erp.post_document(p_company varchar, p_obj_type integer, p_doc_entry integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d       erp.document;
  w       erp.doc_workflow;
  v_trans integer;
  v_ar    text;
  v_rev   text;
  v_vat   text;
  v_inv   text;
  v_cogs  text;
  v_net   numeric;
  v_vatsum numeric;
  v_cost  numeric;
  v_sign  integer;
  v_lines jsonb;
  v_name  text;
  v_ref   text;
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
  IF p_obj_type NOT IN (13, 14, 15) THEN
    RAISE EXCEPTION 'Posting for this document type comes in a later phase.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  v_ref := coalesce(w.doc_no, d.doc_num::text);

  IF p_obj_type = 15 THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
     WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing from stock (service lines only, or zero cost): no journal
    END IF;
    v_cogs := erp.gl_account(p_company, 'inventory', 'cogs');
    v_inv := erp.gl_account(p_company, 'inventory', 'inventory');
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_cogs, 'debit', v_cost),
                                 jsonb_build_object('acct_code', v_inv, 'credit', v_cost));
    v_trans := erp.post_journal(p_company, d.doc_date, format('Delivery %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 15, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('15/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 15, p_doc_entry, v_trans);
    RETURN v_trans;
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

  -- Goods back in stock on a credit memo: inventory up, cost of goods sold down, at the cost they left with.
  IF p_obj_type = 14 AND coalesce(w.return_stock, false) THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
     WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry;
    IF v_cost > 0 THEN
      v_inv := erp.gl_account(p_company, 'inventory', 'inventory');
      v_cogs := erp.gl_account(p_company, 'inventory', 'cogs');
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_inv, 'debit', v_cost),
                                              jsonb_build_object('acct_code', v_cogs, 'credit', v_cost));
    END IF;
  END IF;

  v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s · %s', v_name, v_ref, coalesce(d.card_name, d.card_code)), v_lines,
    jsonb_build_object('trans_type', p_obj_type, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                       'due_date', d.due_date, 'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                       'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
  RETURN v_trans;
END $$;

-- Next number for a Super ERP document (row-locked). Raises when the company has no numbering for the type.
CREATE OR REPLACE FUNCTION erp._sd_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns erp.number_series;
BEGIN
  SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._sd_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.number_series SET next_num = next_num + 1 WHERE company_code = p_company AND obj_type = p_obj;
  RETURN jsonb_build_object('num', ns.next_num, 'no', ns.prefix || lpad(ns.next_num::text, ns.pad, '0'), 'entry', nextval('erp.erp_doc_entry_seq'));
END $$;

-- ============ API: quotations (23) and orders (17) ============
CREATE OR REPLACE FUNCTION erp._sd_check_obj(p_obj integer) RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = erp, pg_temp AS $$
BEGIN
  IF p_obj IS NULL OR p_obj NOT IN (23, 17) THEN
    RAISE EXCEPTION 'Only sales quotations and sales orders are edited this way.' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Lists and defaults for the quotation / order form (sales users cannot read tax_code directly, so it comes from here).
CREATE OR REPLACE FUNCTION erp.sales_doc_setup(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._so_guard(p_company, false);
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'tax_codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name, 'rate', rate) ORDER BY code)
                             FROM erp.tax_code WHERE company_code = p_company AND active AND coalesce(category, 'O') <> 'I'), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', whs_code, 'name', name) ORDER BY whs_code)
                              FROM erp.warehouse WHERE company_code = p_company AND active), '[]'::jsonb),
    'price_lists', coalesce((SELECT jsonb_agg(jsonb_build_object('code', list_num, 'name', name) ORDER BY list_num)
                               FROM erp.price_list WHERE company_code = p_company), '[]'::jsonb),
    'payment_terms', coalesce((SELECT jsonb_agg(jsonb_build_object('code', group_num, 'name', name, 'days', extra_days) ORDER BY group_num)
                                 FROM erp.payment_terms WHERE company_code = p_company), '[]'::jsonb),
    'salespersons', coalesce((SELECT jsonb_agg(jsonb_build_object('code', slp_code, 'name', name) ORDER BY slp_code)
                                FROM erp.salesperson WHERE company_code = p_company AND active), '[]'::jsonb),
    'default_tax_code', (SELECT default_tax_code FROM erp.sales_setting WHERE company_code = p_company),
    'default_whs_code', (SELECT default_whs_code FROM erp.sales_setting WHERE company_code = p_company),
    'numbering', (SELECT jsonb_build_object('prefix', prefix, 'next_num', next_num) FROM erp.number_series
                   WHERE company_code = p_company AND obj_type = p_obj AND active),
    'my_discount_limit', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 17 AND active
                            AND rule_code = 'discount_pct' AND position_code = u.position_code ORDER BY step LIMIT 1),
    'atp_on', p_obj = 17 AND EXISTS (SELECT 1 FROM erp.atp_rule WHERE company_code = p_company AND active),
    'can_write', erp.can_write('sales'));
END $$;

-- Live preview while typing. Writes nothing.
CREATE OR REPLACE FUNCTION erp.sales_doc_checks(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._so_guard(p_company, false);
  RETURN erp._sd_eval(p_company, p_obj, p_header, p_lines, u.position_code, p_doc_entry);
END $$;

-- Create (p_doc_entry NULL) or replace a draft owned by the caller. The server prices, totals and numbers the document.
CREATE OR REPLACE FUNCTION erp.sales_doc_save(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  e      jsonb;
  hd     jsonb;
  nb     jsonb;
  v_new  boolean := p_doc_entry IS NULL;
  v_entry integer;
  v_num  integer;
  v_no   text;
  v_nerr integer;
  v_noun text := erp._sd_noun(p_obj);
  v_obj  text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  IF NOT v_new THEN
    w := erp._sd_lock(p_company, p_obj, p_doc_entry);
    IF w.state = 'pending_approval' THEN
      RAISE EXCEPTION 'This % is waiting for approval and can''t be edited. Ask the approver to reject it first.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.state = 'approved' THEN
      RAISE EXCEPTION 'This % is approved and can''t be edited.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.state = 'cancelled' THEN
      RAISE EXCEPTION 'This % is cancelled and can''t be edited.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.created_by <> u.user_id THEN
      RAISE EXCEPTION 'Only the person who created this % can change it.', v_noun USING ERRCODE = 'P0001';
    END IF;
  END IF;

  e := erp._sd_eval(p_company, p_obj, p_header, p_lines, u.position_code, p_doc_entry);
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this %s.', v_nerr - 1, v_noun) ELSE '' END;
  END IF;
  hd := e->'header';

  IF v_new THEN
    nb := erp._sd_number(p_company, p_obj);
    v_num := (nb->>'num')::integer;
    v_no := nb->>'no';
    v_entry := (nb->>'entry')::integer;
    INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                              customer_ref, currency, fx_rate, total, vat_total, paid, slp_code, branch_id, comments, created_on, source)
    VALUES (p_company, p_obj, v_entry, v_num, CASE p_obj WHEN 23 THEN 'sales_quotation' ELSE 'sales_order' END, 'draft',
            (hd->>'doc_date')::date, (hd->>'due_date')::date, (hd->>'doc_date')::date,
            hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', 1, (e->'totals'->>'total')::numeric,
            (e->'totals'->>'vat')::numeric, 0, (hd->>'slp_code')::integer, (hd->>'branch_id')::integer, hd->>'comments', current_date, 'erp');
    INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, price_list, payment_terms, whs_code)
    VALUES (p_company, p_obj, v_entry, v_no, 'draft', u.user_id, (hd->>'price_list')::integer, (hd->>'payment_terms')::integer, hd->>'whs_code');
  ELSE
    v_entry := p_doc_entry;
    v_no := w.doc_no;
    SELECT doc_num INTO v_num FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    UPDATE erp.document
       SET status = 'draft', doc_date = (hd->>'doc_date')::date, due_date = (hd->>'due_date')::date, tax_date = (hd->>'doc_date')::date,
           card_code = hd->>'card_code', card_name = hd->>'card_name', customer_ref = hd->>'customer_ref',
           total = (e->'totals'->>'total')::numeric, vat_total = (e->'totals'->>'vat')::numeric, slp_code = (hd->>'slp_code')::integer,
           branch_id = (hd->>'branch_id')::integer, comments = hd->>'comments'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry AND source = 'erp';
    UPDATE erp.doc_workflow
       SET state = 'draft', updated_at = now(), price_list = (hd->>'price_list')::integer,
           payment_terms = (hd->>'payment_terms')::integer, whs_code = hd->>'whs_code'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    DELETE FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
  END IF;

  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                 discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                 base_obj_type, base_doc_entry, base_line)
  SELECT p_company, p_obj, v_entry, x.line_num, x.item_code, x.description, x.qty, x.qty, x.uom, x.price, e->'totals'->>'currency',
         x.discount_pct, x.line_total, x.tax_code, x.vat, x.whs_code, 'O', x.cost, x.cost, (hd->>'slp_code')::integer,
         x.base_obj_type, x.base_doc_entry, x.base_line
    FROM jsonb_to_recordset(e->'lines') AS x(line_num int, item_code text, description text, uom text, qty numeric, price numeric,
                                             discount_pct numeric, tax_code text, whs_code text, line_total numeric, vat numeric, cost numeric,
                                             base_obj_type int, base_doc_entry int, base_line int);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN v_new THEN '_create' ELSE '_update' END, v_obj, v_entry::text,
          jsonb_build_object('doc_no', v_no, 'card_code', hd->>'card_code', 'total', e->'totals'->'total',
                             'lines', jsonb_array_length(e->'lines'), 'checks', jsonb_array_length(e->'checks'),
                             'copied_from', (SELECT jsonb_agg(DISTINCT x.base_doc_entry) FROM jsonb_to_recordset(e->'lines') AS x(base_doc_entry int)
                                              WHERE x.base_doc_entry IS NOT NULL)));

  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_num', v_num, 'doc_no', v_no, 'state', 'draft',
                            'totals', e->'totals', 'checks', e->'checks', 'atp', e->'atp', 'lines', e->'lines');
END $$;

-- Run the rules: none triggered → approved and open. Otherwise pending_approval with one approval row per rule / step / approver.
-- Orders promising more than Available-to-Promise need a reason too (no approver: the reason is the confirmation, and it is logged).
CREATE OR REPLACE FUNCTION erp.sales_doc_submit(p_company varchar, p_obj integer, p_doc_entry integer, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  inp    jsonb;
  e      jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_rules text;
  v_noun text := erp._sd_noun(p_obj);
  v_obj  text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  w := erp._sd_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'pending_approval' THEN
    RAISE EXCEPTION 'This % is already waiting for approval.', v_noun USING ERRCODE = 'P0001';
  ELSIF w.state = 'approved' THEN
    RAISE EXCEPTION 'This % is already approved.', v_noun USING ERRCODE = 'P0001';
  ELSIF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is cancelled and can''t be submitted.', v_noun USING ERRCODE = 'P0001';
  ELSIF w.created_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who created this % can submit it.', v_noun USING ERRCODE = 'P0001';
  END IF;

  inp := erp._sd_stored(p_company, p_obj, p_doc_entry);
  e := erp._sd_eval(p_company, p_obj, inp->'header', inp->'lines', u.position_code, p_doc_entry);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Open the draft, fix it and save it again.';
  END IF;

  IF jsonb_array_length(e->'checks') > 0 AND v_reason IS NULL THEN
    SELECT string_agg(DISTINCT CASE c->>'rule_code' WHEN 'discount_pct' THEN 'discount above your limit'
                                                  WHEN 'credit_limit' THEN 'over the credit limit'
                                                  ELSE 'price below cost' END, ', ')
      INTO v_rules FROM jsonb_array_elements(e->'checks') c;
    RAISE EXCEPTION 'This % needs approval (%). Add a reason for the approver.', v_noun, v_rules USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(e->'atp') > 0 AND v_reason IS NULL THEN
    RAISE EXCEPTION '% Add a reason to confirm the promise.', e->'atp'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN jsonb_array_length(e->'atp') > 1 THEN format('%s more line(s) above Available-to-Promise.', jsonb_array_length(e->'atp') - 1) ELSE '' END;
  END IF;

  -- Anything still open from an earlier round is closed without a decision.
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;

  IF jsonb_array_length(e->'checks') = 0 THEN
    UPDATE erp.doc_workflow SET state = 'approved', submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, v_obj || '_submit', v_obj, p_doc_entry::text,
            jsonb_build_object('doc_no', w.doc_no, 'result', 'approved', 'checks', '[]'::jsonb, 'total', e->'totals'->'total',
                               'reason', v_reason, 'atp', e->'atp'));
    RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'approved', 'status', 'open', 'checks', '[]'::jsonb, 'atp', e->'atp');
  END IF;

  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  SELECT p_company, v_obj, p_doc_entry::text, (c->>'step')::smallint, c->>'approver_position', c->>'rule_code', u.user_id, now(),
         jsonb_build_object('checks', jsonb_agg(c),
                            'lines', coalesce(jsonb_agg(c->'line') FILTER (WHERE c->>'line' IS NOT NULL), '[]'::jsonb),
                            'max_value', max((c->>'value')::numeric), 'limit', max((c->>'limit')::numeric))
    FROM jsonb_array_elements(e->'checks') c
   GROUP BY c->>'rule_code', (c->>'step')::smallint, c->>'approver_position';

  UPDATE erp.doc_workflow SET state = 'pending_approval', submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = NULL, updated_at = now()
   WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_submit', v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'result', 'pending_approval', 'reason', v_reason, 'checks', e->'checks', 'total', e->'totals'->'total',
                             'atp', e->'atp'));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'pending_approval', 'status', 'draft', 'checks', e->'checks', 'atp', e->'atp');
END $$;

-- Approve or reject the current step. p_new_discount = "Approve at n %": lowers the flagged discounts to n and recalculates.
CREATE OR REPLACE FUNCTION erp.sales_doc_decide(p_company varchar, p_obj integer, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL,
                                                p_new_discount numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  w        erp.doc_workflow;
  v_note   text := nullif(btrim(p_note), '');
  v_step   smallint;
  v_mine   bigint[];
  v_who    text;
  v_limit  numeric;
  v_flag   integer[];
  v_maxd   numeric;
  v_left   integer;
  v_state  text;
  v_noun   text := erp._sd_noun(p_obj);
  v_obj    text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  w := erp._sd_lock(p_company, p_obj, p_doc_entry);
  IF w.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This % is not waiting for approval.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF w.submitted_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own %.', v_noun USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own %. Cancel it instead if it is no longer needed.', v_noun USING ERRCODE = 'P0001';
  END IF;

  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND approver_position = u.position_code;
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT p.name, ' or ') INTO v_who FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = v_obj AND a.object_ref = p_doc_entry::text AND a.decision IS NULL
       AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This % is waiting for approval from %. Your position can''t decide it.', v_noun, coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this %.', v_noun USING ERRCODE = 'P0001';
  END IF;

  IF p_new_discount IS NOT NULL THEN
    IF p_decision <> 'approved' THEN
      RAISE EXCEPTION 'Approve at a lower discount only works with approve.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT (ln.v)::integer), max((a.detail->>'max_value')::numeric) INTO v_flag, v_maxd
      FROM erp.approval a CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(a.detail->'lines', '[]'::jsonb)) AS ln(v)
     WHERE a.approval_id = ANY (v_mine) AND a.rule_code = 'discount_pct';
    IF v_flag IS NULL THEN
      RAISE EXCEPTION 'Approve at a lower discount only applies to a discount approval.' USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount < 0 OR p_new_discount > 100 THEN
      RAISE EXCEPTION 'The discount must be between 0 and 100%%.' USING ERRCODE = 'P0001';
    END IF;
    SELECT limit_value INTO v_limit FROM erp.approval_rule
     WHERE company_code = p_company AND obj_type = 17 AND active AND rule_code = 'discount_pct' AND position_code = u.position_code
     ORDER BY step LIMIT 1;
    IF v_limit IS NULL THEN
      RAISE EXCEPTION 'Your position has no discount limit set, so you can''t approve at a different discount. Approve or reject the % as it is.', v_noun
        USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount > v_limit THEN
      RAISE EXCEPTION '%', format('Discount %s%% is above your own limit of %s%%. Approve the %s as it is, or choose a lower discount.',
        erp._pct(p_new_discount), erp._pct(v_limit), v_noun) USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount >= v_maxd THEN
      RAISE EXCEPTION '%', format('Approve at %s%% must be lower than the requested discount of %s%%.', erp._pct(p_new_discount), erp._pct(v_maxd))
        USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.document_line l
       SET discount_pct = p_new_discount,
           line_total = round(l.quantity * l.price * (1 - p_new_discount / 100), 2),
           vat = round(round(l.quantity * l.price * (1 - p_new_discount / 100), 2)
                       * coalesce((SELECT t.rate FROM erp.tax_code t WHERE t.company_code = l.company_code AND t.code = l.tax_code), 0) / 100, 2)
     WHERE l.company_code = p_company AND l.obj_type = p_obj AND l.doc_entry = p_doc_entry
       AND l.line_num + 1 = ANY (v_flag) AND l.discount_pct > p_new_discount;
    UPDATE erp.document d
       SET vat_total = s.vat, total = s.net + s.vat
      FROM (SELECT coalesce(sum(line_total), 0) AS net, coalesce(sum(vat), 0) AS vat FROM erp.document_line
             WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry) s
     WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_doc_entry AND d.source = 'erp';
  END IF;

  UPDATE erp.approval
     SET decision = p_decision, approver_user = u.user_id, decided_at = now(),
         note = coalesce(v_note, CASE WHEN p_new_discount IS NOT NULL THEN format('Approved at %s%%', erp._pct(p_new_discount)) END),
         detail = detail || CASE WHEN p_new_discount IS NOT NULL THEN jsonb_build_object('approved_at', p_new_discount) ELSE '{}'::jsonb END
   WHERE approval_id = ANY (v_mine);

  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    v_state := 'rejected';
    UPDATE erp.doc_workflow SET state = 'rejected', decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      v_state := 'approved';
      UPDATE erp.doc_workflow SET state = 'approved', decided_at = now(), updated_at = now()
       WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
      UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN p_decision = 'approved' THEN '_approve' ELSE '_reject' END,
          v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note,
                             'approved_at', p_new_discount, 'state', v_state));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', v_state,
                            'status', (SELECT status FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry),
                            'total', (SELECT total FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry));
END $$;

-- Cancel: the creator or one of the document's approvers, with a note. An order with a delivery, or a quotation copied
-- to a live order, can't be cancelled.
CREATE OR REPLACE FUNCTION erp.sales_doc_cancel(p_company varchar, p_obj integer, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  v_note text := nullif(btrim(p_note), '');
  v_noun text := erp._sd_noun(p_obj);
  v_obj  text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  w := erp._sd_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is already cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 17 AND EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND base_obj_type = 17 AND base_doc_entry = p_doc_entry) THEN
    RAISE EXCEPTION 'This order has a delivery and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 23 AND EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                             WHERE l.company_code = p_company AND l.base_obj_type = 23 AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled') THEN
    RAISE EXCEPTION 'This quotation was copied to a sales order and can''t be cancelled. Cancel the order first.' USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (
       SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
          AND approver_position = u.position_code) THEN
    RAISE EXCEPTION 'Only the person who created this % or one of its approvers can cancel it.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the % is cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_note, updated_at = now()
   WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
  UPDATE erp.document_line SET line_status = 'C' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_cancel', v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'from_state', w.state, 'note', v_note));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled', 'status', 'cancelled');
END $$;

-- Everything the quotation / order page needs beyond the document itself. NULL when not visible; {workflow:false} for SAP / sample.
CREATE OR REPLACE FUNCTION erp.sales_doc_info(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  d        erp.document;
  w        erp.doc_workflow;
  v_write  boolean;
  v_step   smallint;
  v_mine   boolean;
  v_appr   boolean;
  v_child  boolean;
  v_live_child boolean;
  v_open   boolean;
  v_sub_pos text;
  v_obj    text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._so_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN jsonb_build_object('workflow', false, 'source', d.source); END IF;

  v_write := erp.can_write('sales');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND approver_position = u.position_code);
  v_child := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND base_obj_type = p_obj AND base_doc_entry = p_doc_entry);
  v_live_child := EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                           WHERE l.company_code = p_company AND l.base_obj_type = p_obj AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled');
  v_open := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND coalesce(line_status, 'O') = 'O');
  SELECT position_code INTO v_sub_pos FROM erp.app_user WHERE user_id = w.submitted_by;

  RETURN jsonb_build_object(
    'workflow', true,
    'obj_type', p_obj,
    'source', d.source,
    'doc_no', w.doc_no,
    'state', w.state,
    'status', d.status,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.submitted_by),
    'submitted_at', w.submitted_at,
    'reason', w.reason,
    'cancel_note', w.cancel_note,
    'cancelled_at', w.cancelled_at,
    'price_list', w.price_list, 'payment_terms', w.payment_terms, 'whs_code', w.whs_code,
    'is_creator', w.created_by = u.user_id,
    'is_submitter', w.submitted_by = u.user_id,
    'can_edit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_submit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_cancel', v_write AND w.state <> 'cancelled' AND NOT (CASE WHEN p_obj = 17 THEN v_child ELSE v_live_child END)
                  AND (w.created_by = u.user_id OR v_appr),
    'can_decide', v_write AND w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_copy', v_write AND w.state = 'approved' AND d.status = 'open' AND v_open,
    'copy_block', CASE WHEN w.state <> 'approved' THEN 'not_approved' WHEN d.status <> 'open' OR NOT v_open THEN 'closed'
                       WHEN NOT v_write THEN 'read_only' END,
    'atp_reason_logged', (SELECT l.detail->'atp' FROM erp.audit_log l WHERE l.company_code = p_company AND l.object = v_obj
                            AND l.object_ref = p_doc_entry::text AND l.action = v_obj || '_submit' ORDER BY l.at DESC, l.audit_id DESC LIMIT 1),
    'my_discount_limit', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 17 AND active
                            AND rule_code = 'discount_pct' AND position_code = u.position_code ORDER BY step LIMIT 1),
    'requester_discount_limit', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 17 AND active
                                   AND rule_code = 'discount_pct' AND position_code = v_sub_pos ORDER BY step LIMIT 1),
    'approvals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code, 'approver_position', a.approver_position,
               'approver_position_name', p.name, 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
               'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = u.user_id,
               'requested_by_name', ru.display_name, 'requested_at', a.requested_at, 'detail', a.detail, 'superseded', a.superseded,
               'current', a.decision IS NULL AND NOT a.superseded AND a.step = v_step,
               'mine', a.approver_position = u.position_code) ORDER BY a.approval_id)
        FROM erp.approval a
        JOIN erp.position p ON p.position_code = a.approver_position
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
        LEFT JOIN erp.app_user ru ON ru.user_id = a.requested_by
       WHERE a.company_code = p_company AND a.object = v_obj AND a.object_ref = p_doc_entry::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l
        LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND l.object = v_obj AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;

-- ============ A2's sales order API, now on the generic functions (same names, arguments and messages) ============
CREATE OR REPLACE FUNCTION erp.sales_order_setup(p_company varchar) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_setup(p_company, 17) $$;
CREATE OR REPLACE FUNCTION erp.sales_order_checks(p_company varchar, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_checks(p_company, 17, p_doc_entry, p_header, p_lines) $$;
CREATE OR REPLACE FUNCTION erp.sales_order_save(p_company varchar, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_save(p_company, 17, p_doc_entry, p_header, p_lines) $$;
CREATE OR REPLACE FUNCTION erp.sales_order_submit(p_company varchar, p_doc_entry integer, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_submit(p_company, 17, p_doc_entry, p_reason) $$;
CREATE OR REPLACE FUNCTION erp.sales_order_decide(p_company varchar, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL,
                                                  p_new_discount numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_decide(p_company, 17, p_doc_entry, p_decision, p_note, p_new_discount) $$;
CREATE OR REPLACE FUNCTION erp.sales_order_cancel(p_company varchar, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_cancel(p_company, 17, p_doc_entry, p_note) $$;
CREATE OR REPLACE FUNCTION erp.sales_order_info(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$ SELECT erp.sales_doc_info(p_company, 17, p_doc_entry) $$;

-- ============ API: Copy to ============
-- Open lines of a Super ERP document (or, with p_doc_entry NULL, of every open Super ERP document of that type for one
-- customer) with what is left to copy, for the quotation → order, order → delivery, delivery → invoice and
-- invoice → credit memo forms.
CREATE OR REPLACE FUNCTION erp.sales_copy_source(p_company varchar, p_obj integer, p_doc_entry integer, p_card_code text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u    erp.app_user;
  d    erp.document;
  w    erp.doc_workflow;
  v_no text;
BEGIN
  u := erp._so_guard(p_company, false);
  IF p_obj IS NULL OR p_obj NOT IN (23, 17, 15, 13) THEN
    RAISE EXCEPTION 'Copy to works from quotations, orders, deliveries and invoices only.' USING ERRCODE = 'P0001';
  END IF;
  IF p_doc_entry IS NOT NULL THEN
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% % was not found in company %.', erp._sd_name(p_obj), p_doc_entry, p_company USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    v_no := coalesce(w.doc_no, d.doc_num::text);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION '% % came from %. Copy to works on Super ERP documents only.', erp._sd_name(p_obj), v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION '% % is not approved yet, so it can''t be copied.', erp._sd_name(p_obj), v_no USING ERRCODE = 'P0001';
    END IF;
    IF d.status <> 'open' THEN
      RAISE EXCEPTION '% % is %, so nothing is left to copy.', erp._sd_name(p_obj), v_no, d.status USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN jsonb_build_object(
    'obj_type', p_obj,
    'header', CASE WHEN p_doc_entry IS NOT NULL THEN jsonb_build_object(
                'doc_entry', d.doc_entry, 'doc_no', v_no, 'card_code', d.card_code, 'card_name', d.card_name, 'doc_date', d.doc_date,
                'due_date', d.due_date, 'price_list', w.price_list, 'payment_terms', w.payment_terms, 'slp_code', d.slp_code,
                'whs_code', w.whs_code, 'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency) END,
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'base_obj_type', l.obj_type, 'base_doc_entry', l.doc_entry, 'base_line', l.line_num, 'base_doc_no', coalesce(lw.doc_no, ld.doc_num::text),
               'base_doc_date', ld.doc_date, 'card_code', ld.card_code, 'item_code', l.item_code, 'description', l.description, 'uom', l.uom,
               'quantity', l.quantity, 'open_qty', l.open_qty, 'price', l.price, 'discount_pct', l.discount_pct, 'tax_code', l.tax_code,
               'tax_rate', (SELECT t.rate FROM erp.tax_code t WHERE t.company_code = l.company_code AND t.code = l.tax_code),
               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cost', l.stock_price,
               'is_stock', coalesce(i.is_stock, false),
               'on_hand', (SELECT sb.on_hand FROM erp.stock_balance sb WHERE sb.company_code = l.company_code AND sb.item_code = l.item_code AND sb.whs_code = l.whs_code))
             ORDER BY ld.doc_date, l.doc_entry, l.line_num)
        FROM erp.document_line l
        JOIN erp.document ld ON ld.company_code = l.company_code AND ld.obj_type = l.obj_type AND ld.doc_entry = l.doc_entry
        JOIN erp.doc_workflow lw ON lw.company_code = l.company_code AND lw.obj_type = l.obj_type AND lw.doc_entry = l.doc_entry AND lw.state = 'approved'
        LEFT JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
       WHERE l.company_code = p_company AND l.obj_type = p_obj AND ld.source = 'erp' AND ld.status = 'open'
         AND coalesce(l.line_status, 'O') = 'O' AND l.open_qty > 0
         AND (CASE WHEN p_doc_entry IS NOT NULL THEN l.doc_entry = p_doc_entry ELSE ld.card_code = p_card_code END)), '[]'::jsonb));
END $$;

-- Base lines of a delivery / invoice / credit memo request, checked and locked. Internal.
-- p_lines: [{base_doc_entry, base_line, qty, whs_code?}]. Returns the lines with the base data, or raises the first problem.
CREATE OR REPLACE FUNCTION erp._sd_base_lines(p_company varchar, p_obj integer, p_base_obj integer, p_lines jsonb, p_verb text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_out   jsonb := '[]';
  l       jsonb;
  i       integer := 0;
  n       text;
  v_entry integer;
  v_line  integer;
  v_qty   numeric;
  v_sum   numeric;
  d       erp.document;
  w       erp.doc_workflow;
  bl      erp.document_line;
  v_no    text;
  v_card  text;
  v_base  text := erp._sd_name(p_base_obj);
  v_lb    text := CASE p_base_obj WHEN 13 THEN 'A/R invoice' ELSE lower(erp._sd_name(p_base_obj)) END;
BEGIN
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one line.' USING ERRCODE = 'P0001';
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_entry := erp._num(l->>'base_doc_entry')::integer;
    v_line := erp._num(l->>'base_line')::integer;
    v_qty := erp._num(l->>'qty');
    IF v_entry IS NULL OR v_line IS NULL THEN
      RAISE EXCEPTION '%', n || format('choose the %s line to copy.', v_lb) USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', n || format('%s %s was not found in company %s.', v_lb, v_entry, p_company) USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry;
    v_no := coalesce(w.doc_no, d.doc_num::text);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION '%', format('%s %s came from %s, so it can''t be %s in Super ERP.', v_base, v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END, p_verb || 'ed') USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' OR d.status <> 'open' THEN
      RAISE EXCEPTION '%', format('%s %s is not open (%s). Only approved, open documents can be %s.', v_base, v_no,
        CASE WHEN w.state IS DISTINCT FROM 'approved' THEN replace(coalesce(w.state, d.status), '_', ' ') ELSE d.status END, p_verb || 'ed')
        USING ERRCODE = 'P0001';
    END IF;
    IF v_card IS NULL THEN
      v_card := d.card_code;
    ELSIF v_card IS DISTINCT FROM d.card_code THEN
      RAISE EXCEPTION 'All lines must be for the same customer: % is for %, not %.', v_no, d.card_code, v_card USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry AND line_num = v_line FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', n || format('%s %s has no line %s.', v_lb, v_no, v_line + 1) USING ERRCODE = 'P0001';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '%', n || 'quantity must be more than 0.' USING ERRCODE = 'P0001';
    END IF;
    -- The same base line may appear twice: add them up.
    SELECT coalesce(sum(erp._num(x->>'qty')), 0) INTO v_sum FROM jsonb_array_elements(v_lines) x
     WHERE erp._num(x->>'base_doc_entry')::integer = v_entry AND erp._num(x->>'base_line')::integer = v_line;
    IF coalesce(bl.line_status, 'O') <> 'O' OR v_sum > coalesce(bl.open_qty, 0) THEN
      RAISE EXCEPTION '%', n || format('you are %s %s of %s but only %s %s still open on %s %s.', p_verb || 'ing', trim_scale(v_sum), bl.item_code,
        trim_scale(CASE WHEN coalesce(bl.line_status, 'O') = 'O' THEN coalesce(bl.open_qty, 0) ELSE 0 END),
        CASE WHEN coalesce(bl.open_qty, 0) = 1 THEN 'is' ELSE 'are' END, v_lb, v_no) USING ERRCODE = 'P0001';
    END IF;
    v_out := v_out || jsonb_build_object('n', i, 'base_doc_entry', v_entry, 'base_line', v_line, 'base_doc_no', v_no, 'qty', v_qty,
      'whs_code', nullif(btrim(l->>'whs_code'), ''), 'item_code', bl.item_code, 'description', bl.description, 'uom', bl.uom,
      'price', bl.price, 'discount_pct', coalesce(bl.discount_pct, 0), 'tax_code', bl.tax_code, 'base_whs', bl.whs_code,
      'cost', bl.stock_price, 'base_qty', bl.quantity, 'base_line_total', bl.line_total, 'base_vat', bl.vat,
      'card_code', d.card_code, 'card_name', d.card_name, 'slp_code', d.slp_code, 'branch_id', d.branch_id, 'customer_ref', d.customer_ref);
  END LOOP;
  RETURN v_out;
END $$;

-- Insert the header + workflow row of a Super ERP delivery / invoice / credit memo. Internal.
CREATE OR REPLACE FUNCTION erp._sd_new_doc(p_company varchar, p_obj integer, p_user uuid, p_card text, p_card_name text, p_date date, p_due date,
                                           p_ref text, p_comments text, p_slp integer, p_branch integer, p_whs text, p_return boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb;
BEGIN
  nb := erp._sd_number(p_company, p_obj);
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                            customer_ref, currency, fx_rate, total, vat_total, paid, slp_code, branch_id, comments, created_on, source)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, (nb->>'num')::integer,
          CASE p_obj WHEN 15 THEN 'delivery' WHEN 13 THEN 'ar_invoice' ELSE 'ar_credit_note' END, 'open', p_date, coalesce(p_due, p_date), p_date,
          p_card, p_card_name, p_ref, (SELECT currency FROM erp.company WHERE company_code = p_company), 1, 0, 0, 0, p_slp, p_branch, p_comments,
          current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code, return_stock)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, nb->>'no', 'approved', p_user, p_user, now(), now(), p_whs, p_return);
  RETURN nb;
END $$;

-- Totals of a Super ERP document from its lines. Internal.
CREATE OR REPLACE FUNCTION erp._sd_retotal(p_company varchar, p_obj integer, p_entry integer) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_total numeric;
BEGIN
  UPDATE erp.document d SET total = s.net + s.vat, vat_total = s.vat
    FROM (SELECT coalesce(sum(line_total), 0) AS net, coalesce(sum(vat), 0) AS vat FROM erp.document_line
           WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry) s
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_entry AND d.source = 'erp'
  RETURNING d.total INTO v_total;
  RETURN v_total;
END $$;

-- Take quantities off the base lines; close lines at 0 and the base document when nothing is left. Internal.
CREATE OR REPLACE FUNCTION erp._sd_consume(p_company varchar, p_base_obj integer, p_lines jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  x record;
BEGIN
  FOR x IN SELECT (l->>'base_doc_entry')::integer AS e, (l->>'base_line')::integer AS ln, sum((l->>'qty')::numeric) AS q
             FROM jsonb_array_elements(p_lines) l GROUP BY 1, 2 LOOP
    UPDATE erp.document_line SET open_qty = open_qty - x.q, line_status = CASE WHEN open_qty - x.q <= 0 THEN 'C' ELSE 'O' END
     WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = x.e AND line_num = x.ln;
  END LOOP;
  UPDATE erp.document d SET status = 'closed'
   WHERE d.company_code = p_company AND d.obj_type = p_base_obj AND d.source = 'erp' AND d.status = 'open'
     AND d.doc_entry IN (SELECT (l->>'base_doc_entry')::integer FROM jsonb_array_elements(p_lines) l)
     AND NOT EXISTS (SELECT 1 FROM erp.document_line bl WHERE bl.company_code = d.company_code AND bl.obj_type = d.obj_type
                        AND bl.doc_entry = d.doc_entry AND coalesce(bl.line_status, 'O') = 'O');
END $$;

-- Posting date for a new delivery / invoice / credit memo. Internal.
CREATE OR REPLACE FUNCTION erp._sd_doc_date(p_header jsonb) RETURNS date
LANGUAGE plpgsql STABLE SET search_path = erp, pg_temp AS $$
DECLARE
  v date;
BEGIN
  IF nullif(btrim(p_header->>'doc_date'), '') IS NULL THEN
    RAISE EXCEPTION 'Choose a posting date.' USING ERRCODE = 'P0001';
  END IF;
  v := erp._date(p_header->>'doc_date');
  IF v IS NULL THEN
    RAISE EXCEPTION 'The posting date is not a valid date.' USING ERRCODE = 'P0001';
  END IF;
  RETURN v;
END $$;

-- ============ API: delivery (15) ============
-- From approved, open Super ERP order lines of one customer. Stock leaves the chosen warehouse at average cost, the order
-- lines close by quantity, and cost of goods sold posts (inventory → COGS). Over-delivery and negative stock are refused.
-- p_header: {doc_date, whs_code (all lines, optional), customer_ref, comments}; p_lines: [{base_doc_entry, base_line, qty, whs_code?}]
CREATE OR REPLACE FUNCTION erp.sales_delivery_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  h      jsonb := coalesce(p_header, '{}'::jsonb);
  v_date date;
  v_hwhs text := nullif(btrim(h->>'whs_code'), '');
  bl     jsonb;
  v_out  jsonb := '[]';
  x      jsonb;
  it     erp.item;
  v_whs  text;
  v_cost numeric;
  v_oh   numeric;
  v_need numeric;
  v_neg  boolean;
  v_lt   numeric;
  v_rate numeric;
  nb     jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  i      integer := 0;
BEGIN
  u := erp._sd_guard(p_company, true, 15);
  v_date := erp._sd_doc_date(h);
  bl := erp._sd_base_lines(p_company, 15, 17, p_lines, 'deliver');

  IF v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    v_whs := coalesce(x->>'whs_code', v_hwhs, x->>'base_whs');
    IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      RAISE EXCEPTION 'Line %: warehouse % does not exist or is inactive.', x->>'n', coalesce(v_whs, '(none)') USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = x->>'item_code';
    v_cost := NULL;
    IF coalesce(it.is_stock, false) THEN
      SELECT sb.on_hand, sb.avg_cost INTO v_oh, v_cost FROM erp.stock_balance sb
       WHERE sb.company_code = p_company AND sb.item_code = it.item_code AND sb.whs_code = v_whs;
      v_oh := coalesce(v_oh, 0);
      v_cost := coalesce(v_cost, it.avg_cost);
      IF v_cost IS NULL THEN
        RAISE EXCEPTION 'Line %: % has no average cost in %, so cost of goods sold can''t be posted. Ask Finance to check the item cost.',
          x->>'n', it.item_code, v_whs USING ERRCODE = 'P0001';
      END IF;
      -- Everything this delivery takes of the item from the warehouse, against what is on hand.
      SELECT coalesce(sum((y->>'qty')::numeric), 0) INTO v_need FROM jsonb_array_elements(bl) y
       WHERE y->>'item_code' = it.item_code AND coalesce(y->>'whs_code', v_hwhs, y->>'base_whs') = v_whs;
      SELECT allow_negative INTO v_neg FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_whs;
      IF v_oh - v_need < 0 AND NOT coalesce(v_neg, false) THEN
        RAISE EXCEPTION 'Line %: only % of % are in stock in %. Delivering % would make stock negative, and % does not allow negative stock.',
          x->>'n', trim_scale(greatest(v_oh, 0)), it.item_code, v_whs, trim_scale(v_need), v_whs USING ERRCODE = 'P0001';
      END IF;
    END IF;
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    -- The full remaining quantity of a line carries its remaining amount exactly; part quantities are priced from the line.
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('whs', v_whs, 'cost', v_cost, 'is_stock', coalesce(it.is_stock, false),
                                              'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  nb := erp._sd_new_doc(p_company, 15, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        (bl->0->>'slp_code')::integer, (bl->0->>'branch_id')::integer, v_hwhs);
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 15, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, (SELECT currency FROM erp.company WHERE company_code = p_company), (x->>'discount_pct')::numeric,
            (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric, x->>'whs', 'O', (x->>'cost')::numeric, (x->>'cost')::numeric,
            (x->>'slp_code')::integer, 17, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    IF (x->>'is_stock')::boolean THEN
      -- Committed was added when the order opened, in the order line's warehouse.
      PERFORM erp._stock_move(p_company, x->>'item_code', x->>'whs', 0, (x->>'qty')::numeric, (x->>'cost')::numeric, 15, v_entry, i, v_date,
                              CASE WHEN x->>'whs' = x->>'base_whs' THEN (x->>'qty')::numeric ELSE 0 END);
      IF x->>'whs' IS DISTINCT FROM x->>'base_whs' THEN
        UPDATE erp.stock_balance SET committed = greatest(committed - (x->>'qty')::numeric, 0)
         WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'base_whs';
      END IF;
    END IF;
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 15, v_entry);
  PERFORM erp._sd_consume(p_company, 17, bl);
  v_trans := erp.post_document(p_company, 15, v_entry);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'delivery_create', 'delivery', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'orders', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);
END $$;

-- ============ API: A/R invoice (13) ============
-- From open Super ERP delivery lines of one customer, and/or directly for service (non-stock) items. Posts A/R, revenue
-- and VAT through post_document and adds the total to the customer balance.
-- p_header: {card_code (needed for service-only invoices), doc_date, due_date?, customer_ref, comments}
-- p_lines:  [{base_doc_entry, base_line, qty}] (delivery lines) or [{item_code, qty, price?, discount_pct?, tax_code?}] (services)
CREATE OR REPLACE FUNCTION erp.sales_invoice_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_base  jsonb := '[]';
  v_svc   jsonb := '[]';
  bl      jsonb := '[]';
  v_out   jsonb := '[]';
  x       jsonb;
  v_date  date;
  v_due   date;
  v_card  text := nullif(btrim(h->>'card_code'), '');
  bp      erp.business_partner;
  it      erp.item;
  tc      erp.tax_code;
  v_cur   text;
  v_price numeric;
  v_qty   numeric;
  v_disc  numeric;
  v_tax   text;
  v_lt    numeric;
  v_rate  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_def_tax text;
  i       integer := 0;
  n       text;
BEGIN
  u := erp._sd_guard(p_company, true, 13);
  v_date := erp._sd_doc_date(h);
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one line.' USING ERRCODE = 'P0001';
  END IF;
  SELECT jsonb_agg(l) FILTER (WHERE l ? 'base_doc_entry' AND nullif(l->>'base_doc_entry', '') IS NOT NULL),
         jsonb_agg(l) FILTER (WHERE NOT (l ? 'base_doc_entry' AND nullif(l->>'base_doc_entry', '') IS NOT NULL))
    INTO v_base, v_svc FROM jsonb_array_elements(v_lines) l;
  v_base := coalesce(v_base, '[]'::jsonb);
  v_svc := coalesce(v_svc, '[]'::jsonb);
  IF jsonb_array_length(v_base) > 0 THEN
    bl := erp._sd_base_lines(p_company, 13, 15, v_base, 'invoic');
    IF v_card IS NOT NULL AND v_card IS DISTINCT FROM bl->0->>'card_code' THEN
      RAISE EXCEPTION 'The deliveries are for customer %, not %.', bl->0->>'card_code', v_card USING ERRCODE = 'P0001';
    END IF;
    v_card := bl->0->>'card_code';
  END IF;

  IF v_card IS NULL THEN
    RAISE EXCEPTION 'Choose a customer.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF NOT FOUND OR bp.card_code IS NULL THEN
    RAISE EXCEPTION 'Customer % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  ELSIF bp.kind <> 'customer' THEN
    RAISE EXCEPTION '% is not a customer. Choose a customer.', v_card USING ERRCODE = 'P0001';
  ELSIF NOT bp.active THEN
    RAISE EXCEPTION 'Customer % is inactive. Choose an active customer.', v_card USING ERRCODE = 'P0001';
  ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
    RAISE EXCEPTION 'Customer % is billed in %. Invoices in a foreign currency come in a later stage.', v_card, bp.currency USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      RAISE EXCEPTION 'The due date is not a valid date.' USING ERRCODE = 'P0001';
    ELSIF v_due < v_date THEN
      RAISE EXCEPTION 'The due date can''t be before the posting date.' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT v_date + coalesce(pt.extra_days, 0) + make_interval(months => coalesce(pt.extra_months, 0)) INTO v_due
      FROM erp.payment_terms pt WHERE pt.company_code = p_company AND pt.group_num = bp.payment_terms;
    v_due := coalesce(v_due, v_date);
  END IF;

  -- Delivery lines: price, discount and tax as delivered; cost carried for a later credit memo.
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('base_obj_type', 15, 'whs', x->>'base_whs', 'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  -- Service lines: non-stock sales items only; stock items go through a delivery first.
  SELECT default_tax_code INTO v_def_tax FROM erp.sales_setting WHERE company_code = p_company;
  FOR x IN SELECT value FROM jsonb_array_elements(v_svc) LOOP
    i := i + 1;
    n := format('Line %s: ', jsonb_array_length(bl) + i);
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = nullif(btrim(x->>'item_code'), '');
    IF nullif(btrim(x->>'item_code'), '') IS NULL THEN
      RAISE EXCEPTION '%', n || 'choose an item.' USING ERRCODE = 'P0001';
    ELSIF it.item_code IS NULL THEN
      RAISE EXCEPTION '%', n || format('item %s does not exist. Check the item code.', x->>'item_code') USING ERRCODE = 'P0001';
    ELSIF NOT it.active OR NOT coalesce(it.is_sold, false) THEN
      RAISE EXCEPTION '%', n || format('%s is not an active sales item.', it.item_code) USING ERRCODE = 'P0001';
    ELSIF coalesce(it.is_stock, false) THEN
      RAISE EXCEPTION '%', n || format('%s is a stock item. Deliver it first, then copy the delivery to an invoice.', it.item_code) USING ERRCODE = 'P0001';
    END IF;
    v_qty := erp._num(x->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '%', n || 'quantity must be more than 0.' USING ERRCODE = 'P0001';
    END IF;
    v_disc := coalesce(erp._num(nullif(btrim(x->>'discount_pct'), '')), 0);
    IF v_disc < 0 OR v_disc > 100 THEN
      RAISE EXCEPTION '%', n || 'discount must be between 0 and 100%.' USING ERRCODE = 'P0001';
    END IF;
    IF nullif(btrim(x->>'price'), '') IS NOT NULL THEN
      v_price := erp._num(x->>'price');
      IF v_price IS NULL OR v_price < 0 THEN
        RAISE EXCEPTION '%', n || 'price must be a number of 0 or more.' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      SELECT price INTO v_price FROM erp.item_price WHERE company_code = p_company AND list_num = bp.price_list AND item_code = it.item_code;
      IF v_price IS NULL THEN
        RAISE EXCEPTION '%', n || format('%s has no price in the customer''s price list. Enter a price.', it.item_code) USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_tax := coalesce(nullif(btrim(x->>'tax_code'), ''), v_def_tax);
    SELECT * INTO tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
    IF v_tax IS NULL THEN
      RAISE EXCEPTION '%', n || 'choose a tax code.' USING ERRCODE = 'P0001';
    ELSIF tc.code IS NULL OR NOT tc.active OR tc.category = 'I' THEN
      RAISE EXCEPTION '%', n || format('tax code %s is not an active sales tax code.', v_tax) USING ERRCODE = 'P0001';
    END IF;
    v_lt := round(v_qty * v_price * (1 - v_disc / 100), 2);
    v_out := v_out || jsonb_build_object('item_code', it.item_code, 'description', it.name, 'uom', it.sales_uom, 'qty', v_qty, 'price', v_price,
      'discount_pct', v_disc, 'tax_code', v_tax, 'line_total', v_lt, 'vat', round(v_lt * tc.rate / 100, 2), 'whs', NULL, 'cost', NULL,
      'slp_code', bp.slp_code);
  END LOOP;

  nb := erp._sd_new_doc(p_company, 13, u.user_id, v_card, bp.name, v_date, v_due,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        coalesce((bl->0->>'slp_code')::integer, bp.slp_code), (bl->0->>'branch_id')::integer, NULL);
  v_entry := (nb->>'entry')::integer;
  i := 0;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 13, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, v_cur, (x->>'discount_pct')::numeric, (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric,
            x->>'whs', 'O', (x->>'cost')::numeric, (x->>'cost')::numeric, (x->>'slp_code')::integer,
            (x->>'base_obj_type')::integer, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 13, v_entry);
  IF jsonb_array_length(bl) > 0 THEN
    PERFORM erp._sd_consume(p_company, 15, bl);
  END IF;
  v_trans := erp.post_document(p_company, 13, v_entry);
  PERFORM erp._bp_balance_add(p_company, v_card, v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ar_invoice_create', 'ar_invoice', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', v_card, 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'deliveries', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans, 'due_date', v_due);
END $$;

-- ============ API: A/R credit memo (14) ============
-- Based on open Super ERP invoice lines. Reverses revenue and VAT; with return_stock the goods go back into stock at the
-- cost they left with (inventory up, COGS down). The customer balance goes down by the total.
-- p_header: {doc_date, return_stock (bool), whs_code (return warehouse, optional), customer_ref, comments}
-- p_lines:  [{base_doc_entry, base_line, qty}]
CREATE OR REPLACE FUNCTION erp.sales_credit_memo_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_ret   boolean := coalesce((h->>'return_stock')::boolean, false);
  v_hwhs  text := nullif(btrim(h->>'whs_code'), '');
  bl      jsonb;
  v_out   jsonb := '[]';
  x       jsonb;
  it      erp.item;
  v_date  date;
  v_whs   text;
  v_lt    numeric;
  v_rate  numeric;
  v_cost  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_cur   text;
  i       integer := 0;
BEGIN
  u := erp._sd_guard(p_company, true, 14);
  v_date := erp._sd_doc_date(h);
  bl := erp._sd_base_lines(p_company, 14, 13, p_lines, 'credit');
  IF v_ret AND v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = x->>'item_code';
    v_whs := CASE WHEN v_ret AND coalesce(it.is_stock, false) THEN coalesce(v_hwhs, x->>'base_whs') ELSE x->>'base_whs' END;
    v_cost := (x->>'cost')::numeric;
    IF v_ret AND coalesce(it.is_stock, false) THEN
      IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
        RAISE EXCEPTION 'Line %: choose an active warehouse for the returned goods.', x->>'n' USING ERRCODE = 'P0001';
      END IF;
      IF v_cost IS NULL THEN
        v_cost := coalesce((SELECT avg_cost FROM erp.stock_balance WHERE company_code = p_company AND item_code = it.item_code AND whs_code = v_whs), it.avg_cost, 0);
      END IF;
    END IF;
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    -- Crediting the whole remaining quantity of a line returns exactly what is left of its amount.
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('whs', v_whs, 'cost', v_cost, 'stock_back', v_ret AND coalesce(it.is_stock, false),
                                              'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  nb := erp._sd_new_doc(p_company, 14, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        (bl->0->>'slp_code')::integer, (bl->0->>'branch_id')::integer, CASE WHEN v_ret THEN v_hwhs END, v_ret);
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 14, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, 0, x->>'uom',
            (x->>'price')::numeric, v_cur, (x->>'discount_pct')::numeric, (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric,
            x->>'whs', 'C', (x->>'cost')::numeric, (x->>'cost')::numeric, (x->>'slp_code')::integer, 13, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    IF (x->>'stock_back')::boolean THEN
      PERFORM erp._stock_move(p_company, x->>'item_code', x->>'whs', (x->>'qty')::numeric, 0, (x->>'cost')::numeric, 14, v_entry, i, v_date);
    END IF;
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 14, v_entry);
  PERFORM erp._sd_consume(p_company, 13, bl);
  v_trans := erp.post_document(p_company, 14, v_entry);
  PERFORM erp._bp_balance_add(p_company, bl->0->>'card_code', -v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ar_credit_memo_create', 'ar_credit_memo', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'return_stock', v_ret, 'invoices', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y),
                             'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);
END $$;

-- ============ API: document flow, print, view info ============
-- Every sales document linked to this one through base links, in both directions (SAP, sample and Super ERP alike).
CREATE OR REPLACE FUNCTION erp.sales_doc_flow(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  v_set text[] := ARRAY[p_obj || ':' || p_doc_entry];
  v_new text[] := ARRAY[p_obj || ':' || p_doc_entry];
  v_add text[];
  k     integer := 0;
BEGIN
  u := erp._so_guard(p_company, false);
  IF NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry) THEN
    RETURN '[]'::jsonb;
  END IF;
  WHILE coalesce(array_length(v_new, 1), 0) > 0 AND k < 8 LOOP
    k := k + 1;
    SELECT array_agg(DISTINCT x) INTO v_add FROM (
      SELECT l.base_obj_type || ':' || l.base_doc_entry AS x
        FROM erp.document_line l
       WHERE l.company_code = p_company AND (l.obj_type || ':' || l.doc_entry) = ANY (v_new) AND l.base_obj_type IN (23, 17, 15, 16, 13, 14)
         AND l.base_doc_entry IS NOT NULL
      UNION
      SELECT l.obj_type || ':' || l.doc_entry
        FROM erp.document_line l
        JOIN unnest(v_new) AS s(key) ON split_part(s.key, ':', 1)::integer = l.base_obj_type AND split_part(s.key, ':', 2)::integer = l.base_doc_entry
       WHERE l.company_code = p_company AND l.obj_type IN (23, 17, 15, 16, 13, 14)) q
     WHERE NOT (x = ANY (v_set));
    v_new := coalesce(v_add, '{}');
    v_set := v_set || v_new;
  END LOOP;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'doc_entry', d.doc_entry, 'doc_no', coalesce(w.doc_no, d.doc_num::text),
             'doc_date', d.doc_date, 'status', d.status, 'state', w.state, 'total', d.total, 'currency', d.currency, 'source', d.source,
             'trans_id', dp.trans_id, 'current', d.obj_type = p_obj AND d.doc_entry = p_doc_entry)
           ORDER BY array_position(ARRAY[23, 17, 15, 16, 13, 14], d.obj_type), d.doc_date, d.doc_entry)
      FROM erp.document d
      LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
      LEFT JOIN erp.document_posting dp ON dp.company_code = d.company_code AND dp.obj_type = d.obj_type AND dp.doc_entry = d.doc_entry
     WHERE d.company_code = p_company AND (d.obj_type || ':' || d.doc_entry) = ANY (v_set)), '[]'::jsonb);
END $$;

-- Delivery / invoice / credit memo page: number, who made it, the journal, what can be copied, activity.
CREATE OR REPLACE FUNCTION erp.sales_doc_view(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  d   erp.document;
  w   erp.doc_workflow;
  v_open boolean;
  v_obj text := erp._sd_object(p_obj);
BEGIN
  u := erp._so_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  v_open := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry
                      AND coalesce(line_status, 'O') = 'O' AND open_qty > 0);
  RETURN jsonb_build_object(
    'workflow', w.doc_entry IS NOT NULL,
    'source', d.source,
    'doc_no', coalesce(w.doc_no, d.doc_num::text),
    'state', w.state,
    'status', d.status,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'return_stock', w.return_stock,
    'trans_id', (SELECT trans_id FROM erp.document_posting WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry),
    'can_read_journal', erp.can_read('finance'),
    'can_copy', d.source = 'erp' AND w.state = 'approved' AND d.status = 'open' AND v_open AND erp.can_write('sales') AND p_obj IN (15, 13),
    'copy_block', CASE WHEN d.source <> 'erp' THEN 'source' WHEN d.status <> 'open' OR NOT v_open THEN 'closed'
                       WHEN NOT erp.can_write('sales') THEN 'read_only' END,
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND l.object = v_obj AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;

-- Everything the A4 print layout needs: company (legal name, TRN), customer (TRN, bill-to address), document, lines, VAT summary.
CREATE OR REPLACE FUNCTION erp.sales_print_data(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  d  erp.document;
  c  erp.company;
  bp erp.business_partner;
BEGIN
  u := erp._so_guard(p_company, false);
  IF p_obj IS NULL OR p_obj NOT IN (23, 17, 15, 13, 14) THEN
    RAISE EXCEPTION 'Printing works for quotations, orders, deliveries, invoices and credit memos.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO c FROM erp.company WHERE company_code = p_company;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = d.card_code;
  RETURN jsonb_build_object(
    'company', jsonb_build_object('code', c.company_code, 'legal_name', c.legal_name, 'short_name', c.short_name, 'tax_id', c.tax_id,
                                  'licence_authority', c.licence_authority, 'country', c.country, 'currency', c.currency),
    'customer', jsonb_build_object('card_code', d.card_code, 'name', coalesce(bp.name, d.card_name), 'foreign_name', bp.foreign_name,
                                   'trn', bp.trn, 'phone', coalesce(bp.phone, bp.mobile), 'email', bp.email, 'city', bp.city, 'country', bp.country,
                                   'address', (SELECT jsonb_build_object('street', a.street, 'block', a.block, 'building', a.building, 'city', a.city,
                                                                         'country', a.country)
                                                 FROM erp.bp_address a WHERE a.company_code = p_company AND a.card_code = d.card_code
                                                ORDER BY (a.kind = 'B') DESC, a.address_name LIMIT 1)),
    'doc', jsonb_build_object('obj_type', d.obj_type, 'doc_no', erp._sd_no(p_company, p_obj, p_doc_entry), 'doc_date', d.doc_date,
                              'due_date', d.due_date, 'customer_ref', d.customer_ref, 'comments', d.comments, 'total', d.total,
                              'vat_total', d.vat_total, 'currency', d.currency, 'status', d.status, 'source', d.source,
                              'salesperson', (SELECT name FROM erp.salesperson WHERE company_code = p_company AND slp_code = d.slp_code),
                              'base_docs', (SELECT jsonb_agg(DISTINCT erp._sd_no(p_company, l.base_obj_type, l.base_doc_entry))
                                              FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj
                                               AND l.doc_entry = p_doc_entry AND l.base_doc_entry IS NOT NULL)),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'item_code', l.item_code, 'description', l.description,
                                                          'foreign_name', i.foreign_name, 'qty', l.quantity, 'uom', l.uom, 'price', l.price,
                                                          'discount_pct', l.discount_pct, 'line_total', l.line_total, 'tax_code', l.tax_code,
                                                          'vat', l.vat, 'whs_code', l.whs_code) ORDER BY l.line_num)
                         FROM erp.document_line l LEFT JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
                        WHERE l.company_code = p_company AND l.obj_type = p_obj AND l.doc_entry = p_doc_entry), '[]'::jsonb),
    'vat', coalesce((SELECT jsonb_agg(jsonb_build_object('tax_code', s.tax_code, 'rate', s.rate, 'net', s.net, 'vat', s.vat) ORDER BY s.tax_code)
                       FROM (SELECT l.tax_code, max(t.rate) AS rate, sum(l.line_total) AS net, sum(l.vat) AS vat
                               FROM erp.document_line l LEFT JOIN erp.tax_code t ON t.company_code = l.company_code AND t.code = l.tax_code
                              WHERE l.company_code = p_company AND l.obj_type = p_obj AND l.doc_entry = p_doc_entry GROUP BY l.tax_code) s), '[]'::jsonb));
END $$;

-- ============ API: Available-to-Promise ============
-- erp.atp(company, item, warehouse, date): the quantity that can be promised (NULL = no ATP rule, or a no-check rule).
CREATE OR REPLACE FUNCTION erp.atp(p_company varchar, p_item text, p_whs text, p_date date) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF erp.current_user_id() IS NOT NULL AND NOT (erp.can_see(p_company) AND (erp.can_read('sales') OR erp.can_read('inventory') OR erp.can_read('purchase'))) THEN
    RAISE EXCEPTION 'You don''t have access to stock in company %.', p_company USING ERRCODE = '42501';
  END IF;
  RETURN (erp._atp(p_company, p_item, p_whs, coalesce(p_date, current_date), erp._atp_rule(p_company, p_item))->>'available')::numeric;
END $$;

-- Sales › Available-to-Promise Check: the number and its parts, plus the open documents behind it.
CREATE OR REPLACE FUNCTION erp.atp_check(p_company varchar, p_item text, p_whs text, p_date date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r  erp.atp_rule;
  it erp.item;
BEGIN
  IF erp.current_user_id() IS NULL OR NOT erp.can_see(coalesce(p_company, '')) OR NOT (erp.can_read('sales') OR erp.can_read('inventory')) THEN
    RAISE EXCEPTION 'You don''t have access to this.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = p_item;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item % does not exist in company %. Check the item code.', coalesce(p_item, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = p_whs) THEN
    RAISE EXCEPTION 'Warehouse % does not exist in company %.', coalesce(p_whs, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  r := erp._atp_rule(p_company, p_item);
  IF r.rule_id IS NULL THEN
    RETURN jsonb_build_object('rule_code', NULL, 'available', NULL, 'item_code', it.item_code, 'item_name', it.name, 'whs_code', p_whs,
                              'date', coalesce(p_date, current_date), 'message',
                              format('No ATP rule is set up for %s. Ask Sales to add one in Setup › Sales › ATP Checking Rule List.', p_company));
  END IF;
  RETURN erp._atp(p_company, p_item, p_whs, coalesce(p_date, current_date), r)
    || jsonb_build_object('item_code', it.item_code, 'item_name', it.name, 'whs_code', p_whs, 'is_stock', coalesce(it.is_stock, false),
         'incoming', coalesce((SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'doc_entry', d.doc_entry, 'doc_no', erp._sd_no(p_company, d.obj_type, d.doc_entry),
                                  'due_date', coalesce(d.due_date, d.doc_date), 'whs_code', l.whs_code, 'open_qty', l.open_qty,
                                  'counted', coalesce(d.due_date, d.doc_date) <= coalesce(p_date, current_date)) ORDER BY coalesce(d.due_date, d.doc_date))
                                 FROM erp.document d JOIN erp.document_line l ON l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry
                                WHERE d.company_code = p_company AND d.obj_type IN (22, 1250000001) AND d.status = 'open' AND coalesce(l.line_status, 'O') = 'O'
                                  AND l.item_code = p_item AND (r.whs_scope = 'all_whs' OR l.whs_code = p_whs)), '[]'::jsonb));
END $$;

-- Setup › Sales › ATP Checking Rule List: add or change a rule (Sales, full access). Rules are never deleted, only made inactive.
-- p_rule: {rule_code, name, whs_scope, subtract_committed, include_purchase_orders, include_transfers, include_in_transit, no_check,
--          item_group, is_default, active, note}
CREATE OR REPLACE FUNCTION erp.atp_rule_save(p_company varchar, p_rule jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  r      jsonb := coalesce(p_rule, '{}'::jsonb);
  v_code text := upper(nullif(btrim(r->>'rule_code'), ''));
  v_name text := nullif(btrim(r->>'name'), '');
  v_scope text := coalesce(nullif(btrim(r->>'whs_scope'), ''), 'order_whs');
  v_group integer := erp._num(r->>'item_group')::integer;
  v_def  boolean := coalesce((r->>'is_default')::boolean, false);
  v_act  boolean := coalesce((r->>'active')::boolean, true);
  old    erp.atp_rule;
  v_id   integer;
BEGIN
  u := erp._sd_guard(p_company, true, 0);
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Enter a rule code, for example ATP-STD.' USING ERRCODE = 'P0001';
  ELSIF v_code !~ '^[A-Z0-9][A-Z0-9_-]{1,19}$' THEN
    RAISE EXCEPTION 'The rule code can use letters, numbers, - and _ (2 to 20 characters).' USING ERRCODE = 'P0001';
  ELSIF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter a name for the rule.' USING ERRCODE = 'P0001';
  ELSIF v_scope NOT IN ('order_whs', 'all_whs') THEN
    RAISE EXCEPTION 'Choose which warehouses count: the order''s warehouse or all warehouses.' USING ERRCODE = 'P0001';
  ELSIF v_group IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND group_code = v_group) THEN
    RAISE EXCEPTION 'Item group % does not exist in company %.', v_group, p_company USING ERRCODE = 'P0001';
  ELSIF v_def AND v_group IS NOT NULL THEN
    RAISE EXCEPTION 'The default rule is for all items. Clear the item group, or untick Default.' USING ERRCODE = 'P0001';
  ELSIF v_def AND NOT v_act THEN
    RAISE EXCEPTION 'The default rule must be active.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.atp_rule WHERE company_code = p_company AND rule_code = v_code FOR UPDATE;
  IF v_def THEN
    UPDATE erp.atp_rule SET is_default = false, updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND is_default AND rule_code <> v_code;
  END IF;
  INSERT INTO erp.atp_rule (company_code, rule_code, name, whs_scope, subtract_committed, include_purchase_orders, include_transfers,
                            include_in_transit, no_check, item_group, is_default, active, note, updated_by, updated_at)
  VALUES (p_company, v_code, v_name, v_scope, coalesce((r->>'subtract_committed')::boolean, true), coalesce((r->>'include_purchase_orders')::boolean, true),
          coalesce((r->>'include_transfers')::boolean, false), coalesce((r->>'include_in_transit')::boolean, false), coalesce((r->>'no_check')::boolean, false),
          v_group, v_def, v_act, nullif(btrim(r->>'note'), ''), u.user_id, now())
  ON CONFLICT (company_code, rule_code) DO UPDATE
    SET name = EXCLUDED.name, whs_scope = EXCLUDED.whs_scope, subtract_committed = EXCLUDED.subtract_committed,
        include_purchase_orders = EXCLUDED.include_purchase_orders, include_transfers = EXCLUDED.include_transfers,
        include_in_transit = EXCLUDED.include_in_transit, no_check = EXCLUDED.no_check, item_group = EXCLUDED.item_group,
        is_default = EXCLUDED.is_default, active = EXCLUDED.active, note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now()
  RETURNING rule_id INTO v_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.rule_id IS NULL THEN 'atp_rule_create' ELSE 'atp_rule_update' END, 'atp_rule', v_code,
          jsonb_build_object('before', CASE WHEN old.rule_id IS NOT NULL THEN to_jsonb(old) - 'updated_by' - 'updated_at' END,
                             'after', (SELECT to_jsonb(x) - 'updated_by' - 'updated_at' FROM erp.atp_rule x WHERE x.rule_id = v_id)));
  RETURN (SELECT to_jsonb(x) FROM erp.atp_rule x WHERE x.rule_id = v_id);
END $$;

-- Setup › Inventory › Warehouses: may this warehouse go below zero? (Inventory, full access.)
CREATE OR REPLACE FUNCTION erp.warehouse_setting_set(p_company varchar, p_whs text, p_allow_negative boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_uid  uuid := erp.current_user_id();
  v_old  boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF NOT erp.can_write('inventory') THEN
    RAISE EXCEPTION 'Only Inventory with full access can change warehouse settings.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = p_whs) THEN
    RAISE EXCEPTION 'Warehouse % does not exist in company %.', coalesce(p_whs, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF p_allow_negative IS NULL THEN
    RAISE EXCEPTION 'Choose whether the warehouse may go below zero.' USING ERRCODE = 'P0001';
  END IF;
  SELECT allow_negative INTO v_old FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = p_whs;
  INSERT INTO erp.warehouse_setting (company_code, whs_code, allow_negative, updated_by, updated_at)
  VALUES (p_company, p_whs, p_allow_negative, v_uid, now())
  ON CONFLICT (company_code, whs_code) DO UPDATE SET allow_negative = EXCLUDED.allow_negative, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (v_uid::text, p_company, 'warehouse_setting_set', 'warehouse', p_whs,
          jsonb_build_object('allow_negative', p_allow_negative, 'before', coalesce(v_old, false)));
  RETURN jsonb_build_object('whs_code', p_whs, 'allow_negative', p_allow_negative);
END $$;

-- ============ Approvals inbox (replaces 18's): sales orders and journals exactly as before, plus sales quotations ============
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
REVOKE ALL ON FUNCTION erp._sd_name(integer), erp._sd_noun(integer), erp._sd_object(integer), erp._sd_no(varchar, integer, integer),
  erp._sd_guard(varchar, boolean, integer), erp._atp_rule(varchar, text), erp._atp(varchar, text, text, date, erp.atp_rule),
  erp._sd_eval(varchar, integer, jsonb, jsonb, text, integer), erp._sd_stored(varchar, integer, integer), erp._sd_lock(varchar, integer, integer),
  erp._bp_balance_add(varchar, text, numeric), erp._stock_move(varchar, text, text, numeric, numeric, numeric, integer, integer, integer, date, numeric),
  erp._sd_order_status(), erp._sd_number(varchar, integer), erp._sd_check_obj(integer), erp._sd_base_lines(varchar, integer, integer, jsonb, text),
  erp._sd_new_doc(varchar, integer, uuid, text, text, date, date, text, text, integer, integer, text, boolean),
  erp._sd_retotal(varchar, integer, integer), erp._sd_consume(varchar, integer, jsonb), erp._sd_doc_date(jsonb),
  erp.post_document(varchar, integer, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.sales_doc_setup(varchar, integer), erp.sales_doc_checks(varchar, integer, integer, jsonb, jsonb),
  erp.sales_doc_save(varchar, integer, integer, jsonb, jsonb), erp.sales_doc_submit(varchar, integer, integer, text),
  erp.sales_doc_decide(varchar, integer, integer, text, text, numeric), erp.sales_doc_cancel(varchar, integer, integer, text),
  erp.sales_doc_info(varchar, integer, integer), erp.sales_copy_source(varchar, integer, integer, text),
  erp.sales_delivery_create(varchar, jsonb, jsonb), erp.sales_invoice_create(varchar, jsonb, jsonb), erp.sales_credit_memo_create(varchar, jsonb, jsonb),
  erp.sales_doc_flow(varchar, integer, integer), erp.sales_doc_view(varchar, integer, integer), erp.sales_print_data(varchar, integer, integer),
  erp.atp(varchar, text, text, date), erp.atp_check(varchar, text, text, date), erp.atp_rule_save(varchar, jsonb),
  erp.warehouse_setting_set(varchar, text, boolean), erp.approval_inbox(),
  erp.sales_order_setup(varchar), erp.sales_order_checks(varchar, integer, jsonb, jsonb), erp.sales_order_save(varchar, integer, jsonb, jsonb),
  erp.sales_order_submit(varchar, integer, text), erp.sales_order_decide(varchar, integer, text, text, numeric),
  erp.sales_order_cancel(varchar, integer, text), erp.sales_order_info(varchar, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sales_doc_setup(varchar, integer), erp.sales_doc_checks(varchar, integer, integer, jsonb, jsonb),
  erp.sales_doc_save(varchar, integer, integer, jsonb, jsonb), erp.sales_doc_submit(varchar, integer, integer, text),
  erp.sales_doc_decide(varchar, integer, integer, text, text, numeric), erp.sales_doc_cancel(varchar, integer, integer, text),
  erp.sales_doc_info(varchar, integer, integer), erp.sales_copy_source(varchar, integer, integer, text),
  erp.sales_delivery_create(varchar, jsonb, jsonb), erp.sales_invoice_create(varchar, jsonb, jsonb), erp.sales_credit_memo_create(varchar, jsonb, jsonb),
  erp.sales_doc_flow(varchar, integer, integer), erp.sales_doc_view(varchar, integer, integer), erp.sales_print_data(varchar, integer, integer),
  erp.atp(varchar, text, text, date), erp.atp_check(varchar, text, text, date), erp.atp_rule_save(varchar, jsonb),
  erp.warehouse_setting_set(varchar, text, boolean), erp.approval_inbox(),
  erp.sales_order_setup(varchar), erp.sales_order_checks(varchar, integer, jsonb, jsonb), erp.sales_order_save(varchar, integer, jsonb, jsonb),
  erp.sales_order_submit(varchar, integer, text), erp.sales_order_decide(varchar, integer, text, text, numeric),
  erp.sales_order_cancel(varchar, integer, text), erp.sales_order_info(varchar, integer)
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Numbering for quotations, deliveries, invoices and credit memos (real companies: A10 Document Numbering).
INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', v.obj, v.prefix, 1, 5
  FROM (VALUES (23, 'SQ-26-'), (15, 'DN-26-'), (13, 'IN-26-'), (14, 'CN-26-')) AS v(obj, prefix)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

-- One ATP rule: the order's warehouse, on hand − committed + open purchase orders + transfer requests due by the date.
INSERT INTO erp.atp_rule (company_code, rule_code, name, whs_scope, subtract_committed, include_purchase_orders, include_transfers,
                          include_in_transit, no_check, is_default, note)
SELECT 'ZZ99', 'ATP-STD', 'Standard — order warehouse', 'order_whs', true, true, true, false, false, true, 'SAMPLE rule for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, rule_code) DO NOTHING;

-- A service (non-stock) item, so a direct service invoice can be tested.
INSERT INTO erp.item (company_code, item_code, name, group_code, sales_uom, inventory_uom, is_stock, is_sold, is_bought, avg_cost, active, created_on, source)
SELECT 'ZZ99', 'SMP-SVC-01', 'Installation service (sample)', NULL, 'Job', 'Job', false, true, false, 0, true, current_date, 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, item_code) DO NOTHING;
INSERT INTO erp.item_price (company_code, list_num, item_code, price, currency)
SELECT 'ZZ99', pl.list_num, 'SMP-SVC-01', CASE pl.list_num WHEN 1 THEN 150 ELSE 200 END, 'AED'
  FROM erp.price_list pl
 WHERE pl.company_code = 'ZZ99' AND EXISTS (SELECT 1 FROM erp.item WHERE company_code = 'ZZ99' AND item_code = 'SMP-SVC-01')
ON CONFLICT (company_code, list_num, item_code) DO NOTHING;
