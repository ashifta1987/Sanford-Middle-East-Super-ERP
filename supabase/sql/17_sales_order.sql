-- A2 · Sales order with approval. Safe to run twice. Does not edit 10–16.
--
-- The first complete Super ERP workflow: create, edit (draft), submit, approve / reject and cancel sales orders.
-- Orders made here are rows in erp.document / erp.document_line with source = 'erp' (SAP rows are never touched),
-- an ERP doc_entry from 900000000 up, and a doc number from erp.number_series.
-- No accounting entries and no stock movements (delivery / invoice come in A4).
--
-- Objects:
--   erp.number_series     – document numbering per company and object type (row-locked in the save function)
--   erp.erp_doc_entry_seq – ERP doc_entry values, starting at 900000000 so they never collide with SAP DocEntry
--   erp.doc_workflow      – workflow state the document table cannot hold: draft / pending_approval / approved / rejected / cancelled
--   erp.approval_rule     – which rules need whose approval (discount_pct, credit_limit, below_cost)
--   erp.sales_setting     – form defaults (tax code, warehouse) per company
--   erp.approval          – existing table; gets rule_code, requested_by, requested_at, detail, superseded
--   erp.sales_order_list  – view for the Sales Orders list (document + workflow state), security_invoker
--   functions             – sales_order_setup / checks / save / submit / decide / cancel / info, approval_inbox
--
-- Business values (limits, prefixes, defaults) are seeded for the sample company ZZ99 only and marked SAMPLE.
-- Real companies start empty: no approval rules, no numbering, no defaults (see A2 walkthrough, "Needs from Ashif").
-- There is no posting-period table yet, so the "posting date in an open period" check is skipped (A3 adds periods).

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.number_series (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    obj_type       integer NOT NULL,                  -- SAP object type (17 = sales order)
    prefix         text NOT NULL,                     -- e.g. SO-26-
    next_num       integer NOT NULL DEFAULT 1 CHECK (next_num > 0),
    pad            smallint NOT NULL DEFAULT 5 CHECK (pad BETWEEN 1 AND 10),
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, obj_type)
);

CREATE SEQUENCE IF NOT EXISTS erp.erp_doc_entry_seq AS integer START WITH 900000000 MINVALUE 900000000 MAXVALUE 2147483647;

CREATE TABLE IF NOT EXISTS erp.doc_workflow (
    company_code   varchar(8) NOT NULL,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,
    doc_no         text NOT NULL,                     -- number people see, e.g. SO-26-00042
    state          text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'pending_approval', 'approved', 'rejected', 'cancelled')),
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    submitted_by   uuid,
    submitted_at   timestamptz,
    reason         text,                              -- the requester's reason when approval is needed
    decided_at     timestamptz,
    cancelled_by   uuid,
    cancelled_at   timestamptz,
    cancel_note    text,
    price_list     integer,                           -- header fields erp.document has no column for
    payment_terms  integer,
    whs_code       varchar(8),
    PRIMARY KEY (company_code, obj_type, doc_entry),
    FOREIGN KEY (company_code, obj_type, doc_entry) REFERENCES erp.document ON DELETE CASCADE,
    UNIQUE (company_code, obj_type, doc_no)
);
CREATE INDEX IF NOT EXISTS doc_workflow_state_idx ON erp.doc_workflow (company_code, obj_type, state);

CREATE TABLE IF NOT EXISTS erp.approval_rule (
    rule_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    obj_type       integer NOT NULL DEFAULT 17,
    rule_code      text NOT NULL CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost')),
    position_code  text REFERENCES erp.position ON DELETE CASCADE,   -- requester's position; NULL = every position (credit_limit, below_cost)
    limit_value    numeric(19,4),                     -- discount_pct: the requester's limit in %. Not used by credit_limit / below_cost
    approver_position text NOT NULL REFERENCES erp.position ON DELETE CASCADE,
    step           smallint NOT NULL DEFAULT 1 CHECK (step BETWEEN 1 AND 9),
    active         boolean NOT NULL DEFAULT true,
    note           text,
    CHECK (rule_code <> 'discount_pct' OR (position_code IS NOT NULL AND limit_value BETWEEN 0 AND 100))
);
CREATE UNIQUE INDEX IF NOT EXISTS approval_rule_uniq ON erp.approval_rule (company_code, obj_type, rule_code, (coalesce(position_code, '')), step);

CREATE TABLE IF NOT EXISTS erp.sales_setting (
    company_code     varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    default_tax_code varchar(8),
    default_whs_code varchar(8),
    note             text
);

ALTER TABLE erp.approval
  ADD COLUMN IF NOT EXISTS rule_code    text,
  ADD COLUMN IF NOT EXISTS requested_by uuid,
  ADD COLUMN IF NOT EXISTS requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS detail       jsonb,
  ADD COLUMN IF NOT EXISTS superseded   boolean NOT NULL DEFAULT false;   -- closed without a decision (rejected / resubmitted / cancelled)
CREATE INDEX IF NOT EXISTS approval_object_idx ON erp.approval (company_code, object, object_ref);
CREATE INDEX IF NOT EXISTS approval_open_idx ON erp.approval (approver_position) WHERE decision IS NULL AND NOT superseded;

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.number_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.doc_workflow ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.approval_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sales_setting ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.number_series, erp.doc_workflow, erp.approval_rule, erp.sales_setting FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.number_series, erp.doc_workflow, erp.approval_rule, erp.sales_setting TO authenticated;
REVOKE ALL ON SEQUENCE erp.erp_doc_entry_seq FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS number_series_read ON erp.number_series;
CREATE POLICY number_series_read ON erp.number_series FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS approval_rule_read ON erp.approval_rule;
CREATE POLICY approval_rule_read ON erp.approval_rule FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS sales_setting_read ON erp.sales_setting;
CREATE POLICY sales_setting_read ON erp.sales_setting FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS doc_workflow_read ON erp.doc_workflow;
CREATE POLICY doc_workflow_read ON erp.doc_workflow FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('sales')) OR (SELECT erp.can_read('finance'))));

-- Sales Orders list: SAP, sample and Super ERP orders side by side. security_invoker = the reader's own row rules apply.
CREATE OR REPLACE VIEW erp.sales_order_list WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status,
       w.state, d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total, d.vat_total,
       d.source, d.created_on
  FROM erp.document d
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type = 17;
REVOKE ALL ON erp.sales_order_list FROM PUBLIC, anon;
GRANT SELECT ON erp.sales_order_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
CREATE OR REPLACE FUNCTION erp._num(p text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = erp, pg_temp AS $$
BEGIN
  RETURN nullif(btrim(p), '')::numeric;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION erp._date(p text) RETURNS date LANGUAGE plpgsql STABLE SET search_path = erp, pg_temp AS $$
BEGIN
  RETURN nullif(btrim(p), '')::date;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION erp._money(p numeric) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT to_char(round(coalesce(p, 0), 2), 'FM999,999,999,999,990.00')
$$;

CREATE OR REPLACE FUNCTION erp._pct(p numeric) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT trim_scale(p)::text
$$;

-- Who is calling, and may they read (p_write = false) or change (p_write = true) sales orders in this company?
CREATE OR REPLACE FUNCTION erp._so_guard(p_company varchar, p_write boolean) RETURNS erp.app_user
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
  IF p_write AND NOT erp.can_write('sales') THEN
    IF erp.can_read('sales') THEN
      RAISE EXCEPTION 'You have read-only access to Sales. Ask the system admin for full access to create or change orders.' USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Your position does not include Sales. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF NOT p_write AND NOT (erp.can_read('sales') OR erp.can_read('finance')) THEN
    RAISE EXCEPTION 'Your position does not include Sales. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Validate, price and check one order (header + lines). Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, line, value, limit, message}],
--    lines:[…computed], header:{…normalised}, totals:{before_discount, discount, net, vat, total, currency}, credit:{…}}
-- p_position = the requester's position (rules are looked up for it); p_doc_entry = the order being edited (excluded from open orders).
CREATE OR REPLACE FUNCTION erp._so_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
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
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'The delivery date is not a valid date.');
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'The delivery date can''t be before the posting date.');
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
      -- No price sent: the server takes it from the price list
      SELECT price INTO v_price FROM erp.item_price WHERE company_code = p_company AND list_num = v_pl AND item_code = v_code;
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has no price in the customer''s price list. Enter a price.', v_code));
        v_ok := false;
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
      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.sales_uom, 'qty', v_qty, 'price', v_price,
        'discount_pct', v_disc, 'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs,
        'line_total', v_lt, 'vat', v_lv, 'cost', v_cost, 'available', v_avail);
    END IF;
  END LOOP;

  -- Credit position (shown on the form even when no rule applies)
  IF v_bp_ok THEN
    SELECT coalesce(sum(total), 0) INTO v_open FROM erp.document
     WHERE company_code = p_company AND obj_type = 17 AND status = 'open' AND card_code = v_card AND doc_entry IS DISTINCT FROM p_doc_entry;
    v_credit := jsonb_build_object('limit', bp.credit_limit, 'balance', coalesce(bp.balance, 0), 'open_orders', v_open,
                                   'this_order', v_net + v_vat, 'left', bp.credit_limit - coalesce(bp.balance, 0) - v_open);
  END IF;

  -- Rule checks (only for an order that is otherwise valid)
  IF jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 17 AND ar.active
                AND (ar.position_code = p_position OR (ar.position_code IS NULL AND ar.rule_code <> 'discount_pct'))
              ORDER BY ar.step, ar.rule_code LOOP
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
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date,
                                 'due_date', v_due, 'price_list', v_pl, 'payment_terms', v_terms, 'slp_code', v_slp, 'whs_code', v_whs,
                                 'branch_id', v_branch, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('before_discount', v_gross, 'discount', v_gross - v_net, 'net', v_net, 'vat', v_vat,
                                 'total', v_net + v_vat, 'currency', v_cur),
    'credit', v_credit);
END $$;

-- The stored order as save-function input (used to re-check it on submit).
CREATE OR REPLACE FUNCTION erp._so_stored(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('card_code', d.card_code, 'doc_date', d.doc_date, 'due_date', d.due_date, 'price_list', w.price_list,
                                 'payment_terms', w.payment_terms, 'slp_code', d.slp_code, 'whs_code', w.whs_code,
                                 'customer_ref', d.customer_ref, 'comments', d.comments),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', l.item_code, 'qty', l.quantity, 'price', l.price,
                                                          'discount_pct', l.discount_pct, 'tax_code', l.tax_code, 'whs_code', l.whs_code)
                                        ORDER BY l.line_num)
                         FROM erp.document_line l
                        WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry), '[]'::jsonb))
    FROM erp.document d
    JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = 17 AND d.doc_entry = p_doc_entry
$$;

-- Lock and load an ERP sales order for a change. Raises the user-facing message when it is missing or from SAP.
CREATE OR REPLACE FUNCTION erp._so_lock(p_company varchar, p_doc_entry integer) RETURNS erp.doc_workflow
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d erp.document;
  w erp.doc_workflow;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sales order % was not found in company %.', p_doc_entry, p_company USING ERRCODE = 'P0001';
  END IF;
  IF d.source <> 'erp' THEN
    RAISE EXCEPTION 'This order came from %, so it is read-only in Super ERP.',
      CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sales order % has no workflow record. Ask the system admin to check it.', p_doc_entry USING ERRCODE = 'P0001';
  END IF;
  RETURN w;
END $$;

-- ============ API functions ============
-- Lists and defaults for the order form. Sales users cannot read tax_code directly (finance table), so it comes from here.
CREATE OR REPLACE FUNCTION erp.sales_order_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
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
                   WHERE company_code = p_company AND obj_type = 17 AND active),
    'my_discount_limit', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 17 AND active
                            AND rule_code = 'discount_pct' AND position_code = u.position_code ORDER BY step LIMIT 1),
    'can_write', erp.can_write('sales'));
END $$;

-- Live preview while typing: all problems and the rules the order would trigger. Writes nothing.
CREATE OR REPLACE FUNCTION erp.sales_order_checks(p_company varchar, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._so_guard(p_company, false);
  RETURN erp._so_eval(p_company, p_header, p_lines, u.position_code, p_doc_entry);
END $$;

-- Create (p_doc_entry NULL) or replace a draft owned by the caller. The server prices, totals and numbers the order.
CREATE OR REPLACE FUNCTION erp.sales_order_save(p_company varchar, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  e      jsonb;
  hd     jsonb;
  ns     erp.number_series;
  v_new  boolean := p_doc_entry IS NULL;
  v_entry integer;
  v_num  integer;
  v_no   text;
  v_nerr integer;
BEGIN
  u := erp._so_guard(p_company, true);
  IF NOT v_new THEN
    w := erp._so_lock(p_company, p_doc_entry);
    IF w.state = 'pending_approval' THEN
      RAISE EXCEPTION 'This order is waiting for approval and can''t be edited. Ask the approver to reject it first.' USING ERRCODE = 'P0001';
    ELSIF w.state = 'approved' THEN
      RAISE EXCEPTION 'This order is approved and can''t be edited.' USING ERRCODE = 'P0001';
    ELSIF w.state = 'cancelled' THEN
      RAISE EXCEPTION 'This order is cancelled and can''t be edited.' USING ERRCODE = 'P0001';
    ELSIF w.created_by <> u.user_id THEN
      RAISE EXCEPTION 'Only the person who created this order can change it.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  e := erp._so_eval(p_company, p_header, p_lines, u.position_code, p_doc_entry);
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this order.', v_nerr - 1) ELSE '' END;
  END IF;
  hd := e->'header';

  IF v_new THEN
    SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = 17 AND active FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Sales order numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).', p_company
        USING ERRCODE = 'P0001';
    END IF;
    v_num := ns.next_num;
    v_no := ns.prefix || lpad(v_num::text, ns.pad, '0');
    UPDATE erp.number_series SET next_num = next_num + 1 WHERE company_code = p_company AND obj_type = 17;
    v_entry := nextval('erp.erp_doc_entry_seq');
    INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                              customer_ref, currency, fx_rate, total, vat_total, paid, slp_code, branch_id, comments, created_on, source)
    VALUES (p_company, 17, v_entry, v_num, 'sales_order', 'draft', (hd->>'doc_date')::date, (hd->>'due_date')::date, (hd->>'doc_date')::date,
            hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', 1, (e->'totals'->>'total')::numeric,
            (e->'totals'->>'vat')::numeric, 0, (hd->>'slp_code')::integer, (hd->>'branch_id')::integer, hd->>'comments', current_date, 'erp');
    INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, price_list, payment_terms, whs_code)
    VALUES (p_company, 17, v_entry, v_no, 'draft', u.user_id, (hd->>'price_list')::integer, (hd->>'payment_terms')::integer, hd->>'whs_code');
  ELSE
    v_entry := p_doc_entry;
    v_no := w.doc_no;
    SELECT doc_num INTO v_num FROM erp.document WHERE company_code = p_company AND obj_type = 17 AND doc_entry = v_entry;
    UPDATE erp.document
       SET status = 'draft', doc_date = (hd->>'doc_date')::date, due_date = (hd->>'due_date')::date, tax_date = (hd->>'doc_date')::date,
           card_code = hd->>'card_code', card_name = hd->>'card_name', customer_ref = hd->>'customer_ref',
           total = (e->'totals'->>'total')::numeric, vat_total = (e->'totals'->>'vat')::numeric, slp_code = (hd->>'slp_code')::integer,
           branch_id = (hd->>'branch_id')::integer, comments = hd->>'comments'
     WHERE company_code = p_company AND obj_type = 17 AND doc_entry = v_entry AND source = 'erp';
    UPDATE erp.doc_workflow
       SET state = 'draft', updated_at = now(), price_list = (hd->>'price_list')::integer,
           payment_terms = (hd->>'payment_terms')::integer, whs_code = hd->>'whs_code'
     WHERE company_code = p_company AND obj_type = 17 AND doc_entry = v_entry;
    DELETE FROM erp.document_line WHERE company_code = p_company AND obj_type = 17 AND doc_entry = v_entry;
  END IF;

  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                 discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code)
  SELECT p_company, 17, v_entry, x.line_num, x.item_code, x.description, x.qty, x.qty, x.uom, x.price, e->'totals'->>'currency',
         x.discount_pct, x.line_total, x.tax_code, x.vat, x.whs_code, 'O', x.cost, x.cost, (hd->>'slp_code')::integer
    FROM jsonb_to_recordset(e->'lines') AS x(line_num int, item_code text, description text, uom text, qty numeric, price numeric,
                                             discount_pct numeric, tax_code text, whs_code text, line_total numeric, vat numeric, cost numeric);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_new THEN 'sales_order_create' ELSE 'sales_order_update' END, 'sales_order', v_entry::text,
          jsonb_build_object('doc_no', v_no, 'card_code', hd->>'card_code', 'total', e->'totals'->'total',
                             'lines', jsonb_array_length(e->'lines'), 'checks', jsonb_array_length(e->'checks')));

  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_num', v_num, 'doc_no', v_no, 'state', 'draft',
                            'totals', e->'totals', 'checks', e->'checks', 'lines', e->'lines');
END $$;

-- Run the rules: none triggered → approved and open. Otherwise pending_approval with one approval row per rule / step / approver.
CREATE OR REPLACE FUNCTION erp.sales_order_submit(p_company varchar, p_doc_entry integer, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  inp    jsonb;
  e      jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_rules text;
BEGIN
  u := erp._so_guard(p_company, true);
  w := erp._so_lock(p_company, p_doc_entry);
  IF w.state = 'pending_approval' THEN
    RAISE EXCEPTION 'This order is already waiting for approval.' USING ERRCODE = 'P0001';
  ELSIF w.state = 'approved' THEN
    RAISE EXCEPTION 'This order is already approved.' USING ERRCODE = 'P0001';
  ELSIF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This order is cancelled and can''t be submitted.' USING ERRCODE = 'P0001';
  ELSIF w.created_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who created this order can submit it.' USING ERRCODE = 'P0001';
  END IF;

  inp := erp._so_stored(p_company, p_doc_entry);
  e := erp._so_eval(p_company, inp->'header', inp->'lines', u.position_code, p_doc_entry);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Open the draft, fix it and save it again.';
  END IF;

  -- Anything still open from an earlier round is closed without a decision.
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;

  IF jsonb_array_length(e->'checks') = 0 THEN
    UPDATE erp.doc_workflow SET state = 'approved', submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
    UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry AND source = 'erp';
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'sales_order_submit', 'sales_order', p_doc_entry::text,
            jsonb_build_object('doc_no', w.doc_no, 'result', 'approved', 'checks', '[]'::jsonb, 'total', e->'totals'->'total'));
    RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'approved', 'status', 'open', 'checks', '[]'::jsonb);
  END IF;

  IF v_reason IS NULL THEN
    SELECT string_agg(DISTINCT CASE c->>'rule_code' WHEN 'discount_pct' THEN 'discount above your limit'
                                                  WHEN 'credit_limit' THEN 'over the credit limit'
                                                  ELSE 'price below cost' END, ', ')
      INTO v_rules FROM jsonb_array_elements(e->'checks') c;
    RAISE EXCEPTION 'This order needs approval (%). Add a reason for the approver.', v_rules USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  SELECT p_company, 'sales_order', p_doc_entry::text, (c->>'step')::smallint, c->>'approver_position', c->>'rule_code', u.user_id, now(),
         jsonb_build_object('checks', jsonb_agg(c),
                            'lines', coalesce(jsonb_agg(c->'line') FILTER (WHERE c->>'line' IS NOT NULL), '[]'::jsonb),
                            'max_value', max((c->>'value')::numeric), 'limit', max((c->>'limit')::numeric))
    FROM jsonb_array_elements(e->'checks') c
   GROUP BY c->>'rule_code', (c->>'step')::smallint, c->>'approver_position';

  UPDATE erp.doc_workflow SET state = 'pending_approval', submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = NULL, updated_at = now()
   WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'sales_order_submit', 'sales_order', p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'result', 'pending_approval', 'reason', v_reason, 'checks', e->'checks', 'total', e->'totals'->'total'));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'pending_approval', 'status', 'draft', 'checks', e->'checks');
END $$;

-- Approve or reject the current step. p_new_discount = "Approve at n %": lowers the flagged discounts to n and recalculates.
CREATE OR REPLACE FUNCTION erp.sales_order_decide(p_company varchar, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL,
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
BEGIN
  u := erp._so_guard(p_company, true);
  w := erp._so_lock(p_company, p_doc_entry);
  IF w.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This order is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF w.submitted_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own order.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own order. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;

  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND approver_position = u.position_code;
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT p.name, ' or ') INTO v_who FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = 'sales_order' AND a.object_ref = p_doc_entry::text AND a.decision IS NULL
       AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This order is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this order.' USING ERRCODE = 'P0001';
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
      RAISE EXCEPTION 'Your position has no discount limit set, so you can''t approve at a different discount. Approve or reject the order as it is.'
        USING ERRCODE = 'P0001';
    END IF;
    IF p_new_discount > v_limit THEN
      RAISE EXCEPTION '%', format('Discount %s%% is above your own limit of %s%%. Approve the order as it is, or choose a lower discount.',
        erp._pct(p_new_discount), erp._pct(v_limit)) USING ERRCODE = 'P0001';
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
     WHERE l.company_code = p_company AND l.obj_type = 17 AND l.doc_entry = p_doc_entry
       AND l.line_num + 1 = ANY (v_flag) AND l.discount_pct > p_new_discount;
    UPDATE erp.document d
       SET vat_total = s.vat, total = s.net + s.vat
      FROM (SELECT coalesce(sum(line_total), 0) AS net, coalesce(sum(vat), 0) AS vat FROM erp.document_line
             WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry) s
     WHERE d.company_code = p_company AND d.obj_type = 17 AND d.doc_entry = p_doc_entry AND d.source = 'erp';
  END IF;

  UPDATE erp.approval
     SET decision = p_decision, approver_user = u.user_id, decided_at = now(),
         note = coalesce(v_note, CASE WHEN p_new_discount IS NOT NULL THEN format('Approved at %s%%', erp._pct(p_new_discount)) END),
         detail = detail || CASE WHEN p_new_discount IS NOT NULL THEN jsonb_build_object('approved_at', p_new_discount) ELSE '{}'::jsonb END
   WHERE approval_id = ANY (v_mine);

  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    v_state := 'rejected';
    UPDATE erp.doc_workflow SET state = 'rejected', decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      v_state := 'approved';
      UPDATE erp.doc_workflow SET state = 'approved', decided_at = now(), updated_at = now()
       WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
      UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry AND source = 'erp';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'sales_order_approve' ELSE 'sales_order_reject' END,
          'sales_order', p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note,
                             'approved_at', p_new_discount, 'state', v_state));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', v_state,
                            'status', (SELECT status FROM erp.document WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry),
                            'total', (SELECT total FROM erp.document WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry));
END $$;

-- Cancel before any delivery: the creator or one of the order's approvers. A note is required.
CREATE OR REPLACE FUNCTION erp.sales_order_cancel(p_company varchar, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  v_note text := nullif(btrim(p_note), '');
BEGIN
  u := erp._so_guard(p_company, true);
  w := erp._so_lock(p_company, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This order is already cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND base_obj_type = 17 AND base_doc_entry = p_doc_entry) THEN
    RAISE EXCEPTION 'This order has a delivery and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (
       SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text
          AND approver_position = u.position_code) THEN
    RAISE EXCEPTION 'Only the person who created this order or one of its approvers can cancel it.' USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the order is cancelled.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_note, updated_at = now()
   WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry AND source = 'erp';
  UPDATE erp.document_line SET line_status = 'C' WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'sales_order_cancel', 'sales_order', p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'from_state', w.state, 'note', v_note));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled', 'status', 'cancelled');
END $$;

-- Everything the order page needs beyond the document itself: workflow, approvals, what the caller may do, activity.
-- NULL when the order does not exist or is not visible; {workflow:false} for SAP / sample orders.
CREATE OR REPLACE FUNCTION erp.sales_order_info(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  d        erp.document;
  w        erp.doc_workflow;
  v_write  boolean;
  v_step   smallint;
  v_mine   boolean;
  v_appr   boolean;
  v_deliv  boolean;
  v_sub_pos text;
BEGIN
  u := erp._so_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 17 AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN jsonb_build_object('workflow', false, 'source', d.source); END IF;

  v_write := erp.can_write('sales');
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'sales_order' AND object_ref = p_doc_entry::text
                       AND approver_position = u.position_code);
  v_deliv := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND base_obj_type = 17 AND base_doc_entry = p_doc_entry);
  SELECT position_code INTO v_sub_pos FROM erp.app_user WHERE user_id = w.submitted_by;

  RETURN jsonb_build_object(
    'workflow', true,
    'source', d.source,
    'doc_no', w.doc_no,
    'state', w.state,
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
    'can_cancel', v_write AND w.state <> 'cancelled' AND NOT v_deliv AND (w.created_by = u.user_id OR v_appr),
    'can_decide', v_write AND w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
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
       WHERE a.company_code = p_company AND a.object = 'sales_order' AND a.object_ref = p_doc_entry::text), '[]'::jsonb),
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l
        LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company AND l.object = 'sales_order' AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;

-- Approvals inbox (/approvals › Documents): waiting for me, sent by me, decided by me.
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
    WITH a AS (
      SELECT a.*, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency,
             p.name AS approver_position_name, ru.display_name AS requested_by_name, du.display_name AS decided_by_name,
             min(a.step) FILTER (WHERE a.decision IS NULL AND NOT a.superseded)
               OVER (PARTITION BY a.company_code, a.object_ref) AS current_step
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 17 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
        JOIN erp.position p ON p.position_code = a.approver_position
        LEFT JOIN erp.app_user ru ON ru.user_id = a.requested_by
        LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
       WHERE a.object = 'sales_order' AND erp.can_see(a.company_code)
    ), r AS (
      SELECT a.*, jsonb_build_object(
               'approval_id', a.approval_id, 'company_code', a.company_code, 'kind', 'sales_order', 'doc_entry', a.doc_entry,
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
REVOKE ALL ON FUNCTION erp._num(text), erp._date(text), erp._money(numeric), erp._pct(numeric), erp._so_guard(varchar, boolean),
  erp._so_eval(varchar, jsonb, jsonb, text, integer), erp._so_stored(varchar, integer), erp._so_lock(varchar, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.sales_order_setup(varchar), erp.sales_order_checks(varchar, integer, jsonb, jsonb),
  erp.sales_order_save(varchar, integer, jsonb, jsonb), erp.sales_order_submit(varchar, integer, text),
  erp.sales_order_decide(varchar, integer, text, text, numeric), erp.sales_order_cancel(varchar, integer, text),
  erp.sales_order_info(varchar, integer), erp.approval_inbox() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sales_order_setup(varchar), erp.sales_order_checks(varchar, integer, jsonb, jsonb),
  erp.sales_order_save(varchar, integer, jsonb, jsonb), erp.sales_order_submit(varchar, integer, text),
  erp.sales_order_decide(varchar, integer, text, text, numeric), erp.sales_order_cancel(varchar, integer, text),
  erp.sales_order_info(varchar, integer), erp.approval_inbox() TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Real companies get their numbering in A10 and their limits from Ashif (A2 walkthrough › Needs from Ashif).
INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', 17, 'SO-26-', 1, 5 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

INSERT INTO erp.sales_setting (company_code, default_tax_code, default_whs_code, note)
SELECT 'ZZ99', 'SR', 'WH01', 'SAMPLE values for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code) DO NOTHING;

INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', 17, v.rule_code, v.pos, v.lim, v.appr, 1, 'SAMPLE rule for test company ZZ99 only'
  FROM (VALUES ('discount_pct', 'QA_SALES'::text, 10::numeric, 'QA_SALES_MGR'),
               ('discount_pct', 'QA_SALES_MGR', 15, 'QA_ALL'),      -- the sales manager's own limit (caps "Approve at n %")
               ('credit_limit', NULL, NULL, 'QA_SALES_MGR'),
               ('below_cost',   NULL, NULL, 'QA_ALL')) AS v(rule_code, pos, lim, appr)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.appr)
   AND (v.pos IS NULL OR EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.pos))
ON CONFLICT (company_code, obj_type, rule_code, (coalesce(position_code, '')), step) DO NOTHING;
