-- A6 · Purchasing: the China flow. request → quotation (several suppliers, compared) → purchase order (approval) →
-- proforma invoice + deposit (A/P down payment, paid through A5) → QC inspection → shipment (ETA feeds ATP) →
-- goods receipt PO (stock in at PO price) → A/P invoice (draws the down payment) → landed costs (split, average cost).
-- Safe to run twice. Does not edit 10–20 (earlier behaviour is changed here with CREATE OR REPLACE, keeping its tests passing).
--
-- Every document made here is a Super ERP row (source = 'erp', ERP doc_entry from 900000000, own number range). SAP and
-- sample documents are never written and can't be copied on. Purchasing is in company currency only, like A4 and A5:
-- suppliers billed in USD / CNY are refused with a "later stage" message (A5 can't pay them yet).
--
-- Objects:
--   erp.china_office          – China offices per company (Shenzhen, Foshan, Dongguan, Ningbo from the design). ZZ99 sample only
--   erp.purchase_setting      – default purchase tax code and warehouse, require_qc_pass (shipment needs a passed QC)
--   erp.landed_cost_code      – landed cost codes and their split method (cbm / qty / value / weight). From SAP (OALC); ZZ99 sample only
--   erp.qc_checklist_item     – the QC checklist per company. ZZ99 sample only
--   erp.pi_status             – proforma invoice statuses per company (SAP's custom PI Status). ZZ99 sample only
--   erp.purchase_pi           – Super ERP proforma invoices. (erp.supplier_pi stays the SAP copy: the SAP sync upserts it by code,
--                               so Super ERP rows live in their own table and can never be overwritten by a sync.)
--   erp.qc_inspection         – QC inspections of a purchase order: pass / fail / rework, checklist, photos in Storage qc/<company>/<po>/
--   erp.purchase_shipment(_line) – container, shipping mark, mode, ETD / ETA, quantity per PO line and what has been received
--   erp.landed_cost(_line/_charge/_alloc) – landed cost documents (SAP object 69) and their exact split
--   erp.ap_dp_draw            – down payments drawn on A/P invoices
--   erp.doc_workflow          – existing (17); gets china_office
--   erp.approval_rule         – existing; rule_code gets po_amount and po_price_increase (obj_type 22)
--   erp.gl_posting_key        – existing (18); gets purchasing/grpo_clearing (goods received, not invoiced)
--   storage bucket qc         – QC photos; Purchasing reads, Purchasing with full access uploads
--   views                     – purchase_doc_list, landed_cost_list (security_invoker)
--   internal                  – _pd_name/_pd_noun/_pd_object/_pd_kind, _pd_guard, _pd_last_price, _pd_eval, _pd_stored, _pd_lock,
--                               _pd_number, _pd_order_status (trigger), _pd_base_lines, _pd_new_doc, _lc_eval, post_document (replaced:
--                               + 20, 204, 18), _atp (replaced: + containers in transit)
--   API                       – purchase_doc_setup / checks / save / submit / decide / cancel / info, purchase_copy_source,
--                               purchase_quotation_compare, purchase_pi_save, purchase_deposit_create, purchase_qc_save,
--                               purchase_shipment_save, purchase_grpo_create, purchase_invoice_create, landed_cost_preview,
--                               landed_cost_create, landed_cost_info, purchase_doc_flow, purchase_view, purchase_setting_set,
--                               purchase_list_save, landed_cost_code_save, approval_inbox (replaced: + purchase orders)
--
-- Business values (approval limits, the price-increase %, landed cost codes, QC checklist, PI statuses, offices, accounts,
-- numbering, two AED China suppliers) are seeded for the sample company ZZ99 only and marked SAMPLE. Real companies start
-- empty (A6 walkthrough › Needs from Ashif).

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.china_office (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    code           text NOT NULL,
    name           text NOT NULL,
    sort           smallint NOT NULL DEFAULT 0,
    active         boolean NOT NULL DEFAULT true,
    note           text,
    PRIMARY KEY (company_code, code)
);

CREATE TABLE IF NOT EXISTS erp.purchase_setting (
    company_code     varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    default_tax_code varchar(8),
    default_whs_code varchar(8),
    require_qc_pass  boolean NOT NULL DEFAULT false,   -- a shipment needs the PO's last QC inspection to be a pass
    note             text,
    updated_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.landed_cost_code (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    code           varchar(20) NOT NULL,
    name           text NOT NULL,
    split_method   text NOT NULL CHECK (split_method IN ('cbm', 'qty', 'value', 'weight')),
    active         boolean NOT NULL DEFAULT true,
    source         text NOT NULL DEFAULT 'erp',        -- 'sap' = from OALC (read-only), 'erp', 'sample' = ZZ99
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, code)
);

CREATE TABLE IF NOT EXISTS erp.qc_checklist_item (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    code           text NOT NULL,
    name           text NOT NULL,
    sort           smallint NOT NULL DEFAULT 0,
    active         boolean NOT NULL DEFAULT true,
    note           text,
    PRIMARY KEY (company_code, code)
);

CREATE TABLE IF NOT EXISTS erp.pi_status (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    code           text NOT NULL,
    name           text NOT NULL,
    sort           smallint NOT NULL DEFAULT 0,
    active         boolean NOT NULL DEFAULT true,
    note           text,
    PRIMARY KEY (company_code, code)
);

CREATE TABLE IF NOT EXISTS erp.purchase_pi (
    pi_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    po_doc_entry   integer NOT NULL,
    card_code      varchar(15) NOT NULL,
    vendor_pi_no   text NOT NULL,                     -- the supplier's PI number
    pi_date        date NOT NULL,
    amount         numeric(19,2),
    eta            date,
    status         text NOT NULL,
    deposit_doc_entry integer,                        -- A/P down payment invoice (204) raised for this PI
    note           text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, card_code, vendor_pi_no)
);

CREATE TABLE IF NOT EXISTS erp.qc_inspection (
    qc_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    po_doc_entry   integer NOT NULL,
    inspected_on   date NOT NULL,
    inspector      text,
    result         text NOT NULL CHECK (result IN ('pass', 'fail', 'rework')),
    checklist      jsonb NOT NULL DEFAULT '[]',       -- [{code, name, ok, note}]
    photos         text[] NOT NULL DEFAULT '{}',      -- Storage object names in bucket qc: <company>/<po>/<file>
    note           text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS qc_inspection_po_idx ON erp.qc_inspection (company_code, po_doc_entry, qc_id);

CREATE TABLE IF NOT EXISTS erp.purchase_shipment (
    shipment_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    po_doc_entry   integer NOT NULL,
    container_no   text,
    shipping_mark  text,
    shipment_mode  text,                              -- sea / air / road / courier (U_Shipment_Mode)
    etd            date,
    eta            date NOT NULL,
    status         text NOT NULL DEFAULT 'in_transit' CHECK (status IN ('in_transit', 'arrived')),
    note           text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS purchase_shipment_po_idx ON erp.purchase_shipment (company_code, po_doc_entry);

CREATE TABLE IF NOT EXISTS erp.purchase_shipment_line (
    shipment_id    integer NOT NULL REFERENCES erp.purchase_shipment ON DELETE CASCADE,
    po_line        integer NOT NULL,
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    whs_code       varchar(8),
    qty            numeric(19,6) NOT NULL CHECK (qty > 0),
    received_qty   numeric(19,6) NOT NULL DEFAULT 0,
    PRIMARY KEY (shipment_id, po_line)
);

CREATE TABLE IF NOT EXISTS erp.landed_cost (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    doc_entry      integer NOT NULL,
    doc_no         text NOT NULL,
    doc_date       date NOT NULL,
    card_code      varchar(15),                       -- broker / forwarder (information; their invoice clears the accrual)
    reference      text,
    comments       text,
    total          numeric(19,2) NOT NULL,
    to_inventory   numeric(19,2) NOT NULL,
    to_cogs        numeric(19,2) NOT NULL,
    currency       varchar(3),
    trans_id       integer,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, doc_entry),
    UNIQUE (company_code, doc_no)
);

CREATE TABLE IF NOT EXISTS erp.landed_cost_line (
    company_code   varchar(8) NOT NULL,
    doc_entry      integer NOT NULL,
    line_num       integer NOT NULL,
    grpo_entry     integer NOT NULL,
    grpo_line      integer NOT NULL,
    item_code      varchar(50) NOT NULL,
    whs_code       varchar(8) NOT NULL,
    qty            numeric(19,6) NOT NULL,
    value          numeric(19,2) NOT NULL,
    cbm            numeric(19,6),
    weight         numeric(19,6),
    allocated      numeric(19,2) NOT NULL,
    to_inventory   numeric(19,2) NOT NULL,
    to_cogs        numeric(19,2) NOT NULL,
    on_hand        numeric(19,6),
    avg_before     numeric(19,6),
    avg_after      numeric(19,6),
    PRIMARY KEY (company_code, doc_entry, line_num),
    FOREIGN KEY (company_code, doc_entry) REFERENCES erp.landed_cost ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.landed_cost_charge (
    company_code   varchar(8) NOT NULL,
    doc_entry      integer NOT NULL,
    charge_no      integer NOT NULL,
    code           varchar(20) NOT NULL,
    name           text,
    split_method   text NOT NULL,
    amount         numeric(19,2) NOT NULL,
    PRIMARY KEY (company_code, doc_entry, charge_no),
    FOREIGN KEY (company_code, doc_entry) REFERENCES erp.landed_cost ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.landed_cost_alloc (
    company_code   varchar(8) NOT NULL,
    doc_entry      integer NOT NULL,
    charge_no      integer NOT NULL,
    line_num       integer NOT NULL,
    basis          numeric(19,6) NOT NULL,
    amount         numeric(19,2) NOT NULL,
    PRIMARY KEY (company_code, doc_entry, charge_no, line_num),
    FOREIGN KEY (company_code, doc_entry) REFERENCES erp.landed_cost ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.ap_dp_draw (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    invoice_entry  integer NOT NULL,                  -- A/P invoice (18)
    dp_entry       integer NOT NULL,                  -- A/P down payment invoice (204)
    amount         numeric(19,2) NOT NULL CHECK (amount > 0),
    PRIMARY KEY (company_code, invoice_entry, dp_entry)
);

ALTER TABLE erp.doc_workflow ADD COLUMN IF NOT EXISTS china_office text;

-- Purchase order approval rules (SAP object 22).
ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount', 'payment_amount', 'bank_change',
                       'po_amount', 'po_price_increase'));

-- Goods received, not invoiced: the GRPO credits it, the A/P invoice clears it (SAP's allocation account).
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort) VALUES
  ('purchasing', 'grpo_clearing', 'Goods received, not invoiced', 23)
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort;

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.china_office ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.purchase_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.landed_cost_code ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.qc_checklist_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.pi_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.purchase_pi ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.qc_inspection ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.purchase_shipment ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.purchase_shipment_line ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.landed_cost ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.landed_cost_line ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.landed_cost_charge ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.landed_cost_alloc ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.ap_dp_draw ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.china_office, erp.purchase_setting, erp.landed_cost_code, erp.qc_checklist_item, erp.pi_status, erp.purchase_pi,
  erp.qc_inspection, erp.purchase_shipment, erp.purchase_shipment_line, erp.landed_cost, erp.landed_cost_line, erp.landed_cost_charge,
  erp.landed_cost_alloc, erp.ap_dp_draw FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.china_office, erp.purchase_setting, erp.landed_cost_code, erp.qc_checklist_item, erp.pi_status, erp.purchase_pi,
  erp.qc_inspection, erp.purchase_shipment, erp.purchase_shipment_line, erp.landed_cost, erp.landed_cost_line, erp.landed_cost_charge,
  erp.landed_cost_alloc, erp.ap_dp_draw TO authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['china_office', 'purchase_setting', 'landed_cost_code', 'qc_checklist_item', 'pi_status', 'purchase_pi',
                           'qc_inspection', 'purchase_shipment', 'purchase_shipment_line', 'landed_cost', 'landed_cost_line',
                           'landed_cost_charge', 'landed_cost_alloc', 'ap_dp_draw'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I FOR SELECT TO authenticated USING (erp.can_see(company_code) AND ((SELECT erp.can_read(''purchase'')) OR (SELECT erp.can_read(''finance''))))',
                   t || '_read', t);
  END LOOP;
END $$;

-- Purchasing users read the workflow rows (number, state, China office) of purchasing documents. 17's policy covers Sales and
-- Financials only; permissive policies add up.
DROP POLICY IF EXISTS doc_workflow_read_purchase ON erp.doc_workflow;
CREATE POLICY doc_workflow_read_purchase ON erp.doc_workflow FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND obj_type IN (1470000113, 540000006, 22, 20, 21, 204, 18, 19)
         AND ((SELECT erp.can_read('purchase')) OR (SELECT erp.can_read('finance'))));

-- QC photos: bucket qc, object names <company>/<po doc_entry>/<file>.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('qc', 'qc', false, 10485760)
ON CONFLICT (id) DO NOTHING;
DROP POLICY IF EXISTS qc_photos_insert ON storage.objects;
CREATE POLICY qc_photos_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'qc' AND erp.can_see(((storage.foldername(name))[1])::varchar) AND erp.can_write('purchase'));
DROP POLICY IF EXISTS qc_photos_select ON storage.objects;
CREATE POLICY qc_photos_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'qc' AND erp.can_see(((storage.foldername(name))[1])::varchar) AND (erp.can_read('purchase') OR erp.can_read('finance')));

-- Purchasing lists: SAP, sample and Super ERP documents side by side, with the Super ERP number, state and China office.
CREATE OR REPLACE VIEW erp.purchase_doc_list WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status,
       w.state, w.china_office, d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total,
       d.vat_total, d.paid, d.container_no, d.source, d.created_on
  FROM erp.document d
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (1470000113, 540000006, 22, 20, 21, 204, 18, 19);
CREATE OR REPLACE VIEW erp.landed_cost_list WITH (security_invoker = true) AS
SELECT l.company_code, l.doc_entry, l.doc_no, l.doc_date, l.card_code, bp.name AS card_name, l.reference, l.total, l.to_inventory, l.to_cogs,
       l.currency, l.trans_id, l.created_at,
       (SELECT string_agg(DISTINCT coalesce(w.doc_no, ll.grpo_entry::text), ', ')
          FROM erp.landed_cost_line ll
          LEFT JOIN erp.doc_workflow w ON w.company_code = ll.company_code AND w.obj_type = 20 AND w.doc_entry = ll.grpo_entry
         WHERE ll.company_code = l.company_code AND ll.doc_entry = l.doc_entry) AS grpos
  FROM erp.landed_cost l
  LEFT JOIN erp.business_partner bp ON bp.company_code = l.company_code AND bp.card_code = l.card_code;
REVOKE ALL ON erp.purchase_doc_list, erp.landed_cost_list FROM PUBLIC, anon;
GRANT SELECT ON erp.purchase_doc_list, erp.landed_cost_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
CREATE OR REPLACE FUNCTION erp._pd_name(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 1470000113 THEN 'Purchase request' WHEN 540000006 THEN 'Purchase quotation' WHEN 22 THEN 'Purchase order'
                    WHEN 20 THEN 'Goods receipt PO' WHEN 204 THEN 'A/P down payment invoice' WHEN 18 THEN 'A/P invoice'
                    WHEN 19 THEN 'A/P credit memo' WHEN 69 THEN 'Landed costs' ELSE 'Document' END
$$;
CREATE OR REPLACE FUNCTION erp._pd_noun(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 1470000113 THEN 'request' WHEN 540000006 THEN 'quotation' WHEN 22 THEN 'purchase order'
                    WHEN 20 THEN 'goods receipt' WHEN 204 THEN 'down payment invoice' WHEN 18 THEN 'A/P invoice' ELSE 'document' END
$$;
-- erp.approval.object / erp.audit_log.object for each purchasing document type.
CREATE OR REPLACE FUNCTION erp._pd_object(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 1470000113 THEN 'purchase_request' WHEN 540000006 THEN 'purchase_quotation' WHEN 22 THEN 'purchase_order'
                    WHEN 20 THEN 'grpo' WHEN 204 THEN 'ap_down_payment' WHEN 18 THEN 'ap_invoice' ELSE 'document' END
$$;
-- erp.document.doc_kind (same names as the SAP sync and src/features/erp/modules.ts › DOC_KINDS).
CREATE OR REPLACE FUNCTION erp._pd_kind(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 1470000113 THEN 'purchase_request' WHEN 540000006 THEN 'purchase_quotation' WHEN 22 THEN 'purchase_order'
                    WHEN 20 THEN 'goods_receipt_po' WHEN 204 THEN 'ap_down_payment' WHEN 18 THEN 'ap_invoice' ELSE 'document' END
$$;

-- Who is calling, and may they read or change purchasing in this company?
--   p_write = false: Purchasing or Financials, read or full.
--   p_write = true:  Purchasing with full access; p_finance_ok also accepts Financials with full access (A/P invoice, landed
--                    costs); p_request = true accepts Purchasing read access (a purchase request: any staff member).
CREATE OR REPLACE FUNCTION erp._pd_guard(p_company varchar, p_write boolean, p_what text DEFAULT 'create purchasing documents',
                                         p_finance_ok boolean DEFAULT false, p_request boolean DEFAULT false) RETURNS erp.app_user
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
  IF NOT (erp.can_read('purchase') OR erp.can_read('finance')) THEN
    RAISE EXCEPTION 'Your position does not include Purchasing. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_write THEN
    IF p_request AND erp.can_read('purchase') THEN
      RETURN u;
    END IF;
    IF NOT (erp.can_write('purchase') OR (p_finance_ok AND erp.can_write('finance'))) THEN
      IF NOT erp.can_read('purchase') AND NOT p_finance_ok THEN
        RAISE EXCEPTION 'Your position does not include Purchasing. Ask the system admin if you need it.' USING ERRCODE = '42501';
      END IF;
      RAISE EXCEPTION 'You have read-only access to Purchasing. Ask the system admin for full access to %.', p_what USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN u;
END $$;

-- The last purchase price of an item: the newest PO / GRPO / A/P invoice line with a price (SAP history included),
-- other than p_doc_entry. NULL when the item was never bought.
CREATE OR REPLACE FUNCTION erp._pd_last_price(p_company varchar, p_item text, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('price', l.price, 'doc_no', coalesce(w.doc_no, d.doc_num::text), 'doc_date', d.doc_date, 'obj_type', d.obj_type,
                            'card_code', d.card_code)
    FROM erp.document_line l
    JOIN erp.document d ON d.company_code = l.company_code AND d.obj_type = l.obj_type AND d.doc_entry = l.doc_entry
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE l.company_code = p_company AND l.item_code = p_item AND l.obj_type IN (22, 20, 18) AND l.price > 0
     AND d.status NOT IN ('draft', 'cancelled', 'cancellation') AND NOT (d.obj_type = 22 AND d.doc_entry IS NOT DISTINCT FROM p_doc_entry)
   ORDER BY d.doc_date DESC, d.doc_entry DESC, l.line_num
   LIMIT 1
$$;

-- Validate, price and check one purchase request (1470000113), quotation (540000006) or order (22). Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, line, value, limit, message}],
--    lines:[…computed, with last_price], header:{…normalised}, totals:{net, vat, total, currency}}
-- Lines can be copied from a request (quotation, order) or a quotation (order): [{…, base_obj_type, base_doc_entry, base_line}].
CREATE OR REPLACE FUNCTION erp._pd_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_req    boolean := p_obj = 1470000113;
  v_po     boolean := p_obj = 22;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  bp       erp.business_partner;
  v_bp_ok  boolean := false;
  st       erp.purchase_setting;
  v_doc_date date;
  v_due    date;
  v_terms  integer;
  v_whs    text;
  v_branch integer;
  v_office text := nullif(btrim(h->>'china_office'), '');
  l        jsonb;
  i        integer := 0;
  n        text;
  it       erp.item;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_tax    text;
  v_tc     erp.tax_code;
  v_lwhs   text;
  v_cbm    numeric;
  v_ok     boolean;
  v_lt     numeric;
  v_lv     numeric;
  v_net    numeric := 0;
  v_vat    numeric := 0;
  v_last   jsonb;
  v_bobj   integer;
  v_bentry integer;
  v_bline  integer;
  bd       erp.document;
  bw       erp.doc_workflow;
  bl       erp.document_line;
  v_bno    text;
  r        record;
  x        record;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;

  -- Supplier (quotations and orders; a request has none)
  IF v_req THEN
    v_card := NULL;
  ELSIF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', 'Choose a supplier.');
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Supplier %s does not exist in company %s. Check the code.', v_card, p_company));
    ELSIF bp.kind <> 'supplier' THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a supplier. Choose a supplier.', v_card));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Supplier %s is inactive. Choose an active supplier.', v_card));
    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message',
        format('Supplier %s is billed in %s. Purchasing in a foreign currency comes in a later stage.', v_card, bp.currency));
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
  IF nullif(btrim(h->>'due_date'), '') IS NULL THEN
    IF v_req THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'Choose the date the goods are needed by.');
    END IF;
  ELSE
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN v_req THEN 'The needed-by date is not a valid date.' WHEN v_po THEN 'The delivery date is not a valid date.' ELSE 'The valid-until date is not a valid date.' END);
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN v_req THEN 'The needed-by date can''t be before the posting date.' WHEN v_po THEN 'The delivery date can''t be before the posting date.'
             ELSE 'The valid-until date can''t be before the posting date.' END);
    END IF;
  END IF;

  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);
  IF v_terms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_terms) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'payment_terms', 'message', format('Payment terms %s do not exist.', v_terms));
  END IF;

  IF v_office IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.china_office WHERE company_code = p_company AND code = v_office AND active) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'china_office', 'message', format('China office %s is not set up for %s.', v_office, p_company));
  END IF;

  -- Header warehouse: the receiving warehouse (lines use it unless they name their own)
  v_whs := coalesce(nullif(btrim(h->>'whs_code'), ''), st.default_whs_code);
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
    v_code := nullif(btrim(l->>'item_code'), '');
    it := NULL;
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
      ELSIF NOT coalesce(it.is_bought, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a purchase item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_stock, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a stock item. Buying services comes in a later stage.', v_code));
        v_ok := false;
      END IF;
    END IF;

    v_qty := erp._num(l->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || 'quantity must be more than 0.');
      v_ok := false;
    END IF;

    v_lwhs := coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs);
    IF v_lwhs IS NULL THEN
      IF v_po THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || 'choose the warehouse the goods are received into.');
        v_ok := false;
      END IF;
    ELSIF v_lwhs IS DISTINCT FROM v_whs AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs AND active) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s does not exist or is inactive.', v_lwhs));
      v_ok := false;
    END IF;

    v_cbm := NULL;
    IF nullif(btrim(l->>'cbm'), '') IS NOT NULL THEN
      v_cbm := erp._num(l->>'cbm');
      IF v_cbm IS NULL OR v_cbm < 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'cbm', 'message', n || 'volume (CBM) must be a number of 0 or more.');
        v_ok := false;
      END IF;
    END IF;

    v_last := CASE WHEN v_code IS NOT NULL THEN erp._pd_last_price(p_company, v_code, p_doc_entry) END;
    v_tc := NULL;
    v_tax := NULL;
    v_price := NULL;
    IF NOT v_req THEN
      v_tax := coalesce(nullif(btrim(l->>'tax_code'), ''), st.default_tax_code);
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
        ELSIF v_tc.category = 'O' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is for sales. Choose a purchase tax code.', v_tax));
          v_ok := false;
        END IF;
      END IF;
      IF nullif(btrim(l->>'price'), '') IS NOT NULL THEN
        v_price := erp._num(l->>'price');
        IF v_price IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price must be a number.');
          v_ok := false;
        ELSIF v_price < 0 THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price can''t be negative.');
          v_ok := false;
        END IF;
      ELSIF v_code IS NOT NULL THEN
        v_price := (v_last->>'price')::numeric;
        IF v_price IS NULL AND it.item_code IS NOT NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has never been bought, so there is no last price. Enter a price.', v_code));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    -- Copied from a request (quotation, order) or a quotation (order): Super ERP, approved and open, same item, enough left.
    v_bobj := erp._num(l->>'base_obj_type')::integer;
    v_bentry := erp._num(l->>'base_doc_entry')::integer;
    v_bline := erp._num(l->>'base_line')::integer;
    IF v_bentry IS NOT NULL OR v_bobj IS NOT NULL THEN
      IF v_req OR v_bentry IS NULL OR v_bline IS NULL OR NOT (v_bobj = 1470000113 OR (v_po AND v_bobj = 540000006)) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'a quotation is copied from a request, and an order from a request or a quotation.');
        v_ok := false;
      ELSE
        SELECT * INTO bd FROM erp.document WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry;
        SELECT * INTO bw FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry;
        v_bno := coalesce(bw.doc_no, bd.doc_num::text);
        SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry AND line_num = v_bline;
        IF bd.doc_entry IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s was not found in company %s.', lower(erp._pd_name(v_bobj)), v_bentry, p_company));
          v_ok := false;
        ELSIF bd.source <> 'erp' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s came from %s. Only Super ERP documents can be copied.',
            lower(erp._pd_name(v_bobj)), v_bno, CASE bd.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
          v_ok := false;
        ELSIF bw.state IS DISTINCT FROM 'approved' OR bd.status <> 'open' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s is not open, so it can''t be copied.', lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        ELSIF v_bobj = 540000006 AND bd.card_code IS DISTINCT FROM v_card THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'card_code', 'message', n || format('quotation %s is from supplier %s. Copy it to an order for the same supplier.', v_bno, bd.card_code));
          v_ok := false;
        ELSIF bl.line_num IS NULL OR bl.item_code IS DISTINCT FROM v_code THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('the item does not match line %s of %s %s.', v_bline + 1, lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        ELSIF v_po AND v_qty IS NOT NULL AND (coalesce(bl.line_status, 'O') <> 'O' OR v_qty > coalesce(bl.open_qty, 0)) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || format('only %s of %s are still open on %s %s.',
            trim_scale(CASE WHEN coalesce(bl.line_status, 'O') = 'O' THEN coalesce(bl.open_qty, 0) ELSE 0 END), v_code, lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    IF v_ok THEN
      v_lt := CASE WHEN v_req THEN 0 ELSE round(v_qty * v_price, 2) END;
      v_lv := CASE WHEN v_req THEN 0 ELSE round(v_lt * v_tc.rate / 100, 2) END;
      v_net := v_net + v_lt;
      v_vat := v_vat + v_lv;
      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.purchase_uom, 'qty', v_qty, 'price', v_price,
        'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs, 'cbm', v_cbm, 'line_total', v_lt, 'vat', v_lv,
        'last_price', v_last->'price', 'last_doc_no', v_last->>'doc_no', 'last_doc_date', v_last->>'doc_date',
        'base_obj_type', CASE WHEN v_bentry IS NOT NULL THEN v_bobj END, 'base_doc_entry', v_bentry,
        'base_line', CASE WHEN v_bentry IS NOT NULL THEN v_bline END);
    END IF;
  END LOOP;

  -- Purchase order rules (only for an order that is otherwise valid)
  IF v_po AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 22 AND ar.active AND ar.limit_value IS NOT NULL
                AND ar.rule_code IN ('po_amount', 'po_price_increase')
                AND (ar.position_code = p_position OR ar.position_code IS NULL)
              ORDER BY ar.step, ar.rule_code LOOP
      IF r.rule_code = 'po_amount' THEN
        IF v_net + v_vat > r.limit_value THEN
          v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
            'approver_name', r.approver_name, 'line', NULL, 'value', v_net + v_vat, 'limit', r.limit_value,
            'message', format('Purchase order total %s %s is above your limit of %s %s.', erp._money(v_net + v_vat), v_cur, erp._money(r.limit_value), v_cur));
        END IF;
      ELSE
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, item_code text, price numeric, last_price numeric, last_doc_no text)
                  WHERE t.last_price > 0 AND t.price > round(t.last_price * (1 + r.limit_value / 100), 6) LOOP
          v_checks := v_checks || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
            'approver_name', r.approver_name, 'line', x.line_num + 1, 'value', round((x.price / x.last_price - 1) * 100, 2), 'limit', r.limit_value,
            'message', format('Line %s: price %s for %s is %s%% above the last purchase price of %s (%s). The limit is %s%%.',
                              x.line_num + 1, erp._money(x.price), x.item_code, erp._pct(round((x.price / x.last_price - 1) * 100, 2)),
                              erp._money(x.last_price), x.last_doc_no, erp._pct(r.limit_value)));
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date, 'due_date', v_due,
                                 'payment_terms', v_terms, 'whs_code', v_whs, 'branch_id', v_branch, 'china_office', v_office,
                                 'customer_ref', nullif(btrim(h->>'customer_ref'), ''), 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('net', v_net, 'vat', v_vat, 'total', v_net + v_vat, 'currency', v_cur));
END $$;

-- The stored request / quotation / order as save-function input (used to re-check it on submit).
CREATE OR REPLACE FUNCTION erp._pd_stored(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('card_code', d.card_code, 'doc_date', d.doc_date, 'due_date', d.due_date, 'payment_terms', w.payment_terms,
                                 'whs_code', w.whs_code, 'china_office', w.china_office, 'customer_ref', d.customer_ref, 'comments', d.comments),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', l.item_code, 'qty', l.quantity, 'price', l.price, 'tax_code', l.tax_code,
                                                          'whs_code', l.whs_code, 'cbm', l.cbm, 'base_obj_type', l.base_obj_type,
                                                          'base_doc_entry', l.base_doc_entry, 'base_line', l.base_line) ORDER BY l.line_num)
                         FROM erp.document_line l
                        WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry), '[]'::jsonb))
    FROM erp.document d
    JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_doc_entry
$$;

-- Lock and load a Super ERP purchasing document for a change.
CREATE OR REPLACE FUNCTION erp._pd_lock(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS erp.doc_workflow
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d erp.document;
  w erp.doc_workflow;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% % was not found in company %.', erp._pd_name(p_obj), p_doc_entry, p_company USING ERRCODE = 'P0001';
  END IF;
  IF d.source <> 'erp' THEN
    RAISE EXCEPTION 'This % came from %, so it is read-only in Super ERP.', erp._pd_noun(p_obj),
      CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% % has no workflow record. Ask the system admin to check it.', erp._pd_name(p_obj), p_doc_entry USING ERRCODE = 'P0001';
  END IF;
  RETURN w;
END $$;

-- Next number for a Super ERP purchasing document or landed cost (row-locked). Raises when the company has no numbering.
CREATE OR REPLACE FUNCTION erp._pd_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns erp.number_series;
BEGIN
  SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._pd_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.number_series SET next_num = next_num + 1 WHERE company_code = p_company AND obj_type = p_obj;
  RETURN jsonb_build_object('num', ns.next_num, 'no', ns.prefix || lpad(ns.next_num::text, ns.pad, '0'), 'entry', nextval('erp.erp_doc_entry_seq'));
END $$;

-- A Super ERP purchase order changes status:
--   opens (approved) → takes its quantities off the quotation / request lines it was copied from (a quotation line also takes
--                      it off the request line the quotation came from) and puts the open quantity on order (stock_balance.on_order);
--   cancelled while open → gives both back.
-- Several suppliers may quote the same request, so a quotation itself never uses up the request: only the order does.
CREATE OR REPLACE FUNCTION erp._pd_order_status() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r     record;
  v_dir integer;
BEGIN
  IF NEW.status = 'open' AND OLD.status = 'draft' THEN
    v_dir := -1;
  ELSIF NEW.status = 'cancelled' AND OLD.status = 'open' THEN
    v_dir := 1;
  ELSE
    RETURN NULL;
  END IF;
  FOR r IN SELECT l.line_num, l.item_code, CASE WHEN v_dir = -1 THEN l.quantity ELSE l.open_qty END AS qty, l.base_obj_type, l.base_doc_entry, l.base_line,
                  bl.open_qty AS b_open, bl.line_status AS b_status, bd.status AS b_doc_status, bw.state AS b_state, coalesce(bw.doc_no, bd.doc_num::text) AS b_no,
                  bl.base_obj_type AS r_obj, bl.base_doc_entry AS r_entry, bl.base_line AS r_line
             FROM erp.document_line l
             JOIN erp.document_line bl ON bl.company_code = l.company_code AND bl.obj_type = l.base_obj_type AND bl.doc_entry = l.base_doc_entry AND bl.line_num = l.base_line
             JOIN erp.document bd ON bd.company_code = bl.company_code AND bd.obj_type = bl.obj_type AND bd.doc_entry = bl.doc_entry
             LEFT JOIN erp.doc_workflow bw ON bw.company_code = bd.company_code AND bw.obj_type = bd.obj_type AND bw.doc_entry = bd.doc_entry
            WHERE l.company_code = NEW.company_code AND l.obj_type = 22 AND l.doc_entry = NEW.doc_entry AND l.base_obj_type IN (1470000113, 540000006)
            ORDER BY l.line_num LOOP
    IF v_dir = -1 THEN
      IF r.b_doc_status IS DISTINCT FROM 'open' OR r.b_state IS DISTINCT FROM 'approved' THEN
        RAISE EXCEPTION 'Line %: % % is no longer open, so the order can''t be opened. Remove the copied lines or copy again.',
          r.line_num + 1, lower(erp._pd_name(r.base_obj_type)), r.b_no USING ERRCODE = 'P0001';
      END IF;
      IF coalesce(r.b_status, 'O') <> 'O' OR coalesce(r.b_open, 0) < r.qty THEN
        RAISE EXCEPTION 'Line %: only % of % are still open on % %.', r.line_num + 1,
          trim_scale(CASE WHEN coalesce(r.b_status, 'O') = 'O' THEN coalesce(r.b_open, 0) ELSE 0 END), r.item_code, lower(erp._pd_name(r.base_obj_type)), r.b_no
          USING ERRCODE = 'P0001';
      END IF;
    END IF;
    UPDATE erp.document_line
       SET open_qty = least(greatest(open_qty + v_dir * r.qty, 0), quantity),
           line_status = CASE WHEN least(greatest(open_qty + v_dir * r.qty, 0), quantity) <= 0 THEN 'C' ELSE 'O' END
     WHERE company_code = NEW.company_code AND obj_type = r.base_obj_type AND doc_entry = r.base_doc_entry AND line_num = r.base_line;
    IF r.base_obj_type = 540000006 AND r.r_obj = 1470000113 THEN
      UPDATE erp.document_line
         SET open_qty = least(greatest(open_qty + v_dir * r.qty, 0), quantity),
             line_status = CASE WHEN least(greatest(open_qty + v_dir * r.qty, 0), quantity) <= 0 THEN 'C' ELSE 'O' END
       WHERE company_code = NEW.company_code AND obj_type = 1470000113 AND doc_entry = r.r_entry AND line_num = r.r_line;
    END IF;
  END LOOP;
  -- Base documents with nothing left close; given back, they open again.
  UPDATE erp.document b
     SET status = CASE WHEN EXISTS (SELECT 1 FROM erp.document_line bl WHERE bl.company_code = b.company_code AND bl.obj_type = b.obj_type
                                       AND bl.doc_entry = b.doc_entry AND coalesce(bl.line_status, 'O') = 'O') THEN 'open' ELSE 'closed' END
   WHERE b.company_code = NEW.company_code AND b.source = 'erp' AND b.status IN ('open', 'closed')
     AND (b.obj_type, b.doc_entry) IN (SELECT l.base_obj_type, l.base_doc_entry FROM erp.document_line l
                                        WHERE l.company_code = NEW.company_code AND l.obj_type = 22 AND l.doc_entry = NEW.doc_entry
                                          AND l.base_obj_type IN (1470000113, 540000006)
                                       UNION
                                       SELECT ql.base_obj_type, ql.base_doc_entry FROM erp.document_line l
                                         JOIN erp.document_line ql ON ql.company_code = l.company_code AND ql.obj_type = 540000006
                                                                  AND ql.doc_entry = l.base_doc_entry AND ql.line_num = l.base_line
                                        WHERE l.company_code = NEW.company_code AND l.obj_type = 22 AND l.doc_entry = NEW.doc_entry
                                          AND l.base_obj_type = 540000006 AND ql.base_obj_type = 1470000113);
  -- On order (stock items, in the receiving warehouse)
  IF v_dir = -1 THEN
    INSERT INTO erp.stock_balance (company_code, item_code, whs_code, on_order)
    SELECT l.company_code, l.item_code, l.whs_code, sum(l.quantity)
      FROM erp.document_line l
     WHERE l.company_code = NEW.company_code AND l.obj_type = 22 AND l.doc_entry = NEW.doc_entry AND l.whs_code IS NOT NULL
     GROUP BY 1, 2, 3
    ON CONFLICT (company_code, item_code, whs_code) DO UPDATE SET on_order = erp.stock_balance.on_order + EXCLUDED.on_order;
  ELSE
    UPDATE erp.stock_balance sb SET on_order = greatest(sb.on_order - s.qty, 0)
      FROM (SELECT l.item_code, l.whs_code, sum(l.open_qty) AS qty FROM erp.document_line l
             WHERE l.company_code = NEW.company_code AND l.obj_type = 22 AND l.doc_entry = NEW.doc_entry GROUP BY 1, 2) s
     WHERE sb.company_code = NEW.company_code AND sb.item_code = s.item_code AND sb.whs_code = s.whs_code;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS pd_order_status ON erp.document;
CREATE TRIGGER pd_order_status AFTER UPDATE OF status ON erp.document FOR EACH ROW
  WHEN (NEW.source = 'erp' AND NEW.obj_type = 22 AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION erp._pd_order_status();

-- Post a Super ERP document (replaces 19's; 13, 14 and 15 are exactly as there). Internal: the document functions call it.
--   20  Goods receipt PO:       Dr inventory / Cr goods received, not invoiced — at the PO price (line stock_price)
--   204 A/P down payment inv.:  Dr down payments (deposits) / Cr payable (supplier)
--   18  A/P invoice:            Dr goods received, not invoiced (net) + Dr input VAT per tax code / Cr payable (supplier, gross);
--                               down payments drawn: Dr payable (supplier) / Cr down payments
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
  v_ap    text;
  v_clr   text;
  v_dp    text;
  v_net   numeric;
  v_vatsum numeric;
  v_cost  numeric;
  v_drawn numeric;
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
  IF p_obj_type NOT IN (13, 14, 15, 20, 204, 18) THEN
    RAISE EXCEPTION 'Posting for this document type comes in a later phase.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  v_ref := coalesce(w.doc_no, d.doc_num::text);

  -- ---------- Purchasing (A6) ----------
  IF p_obj_type = 20 THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 20 AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing of value received (zero-price lines): no journal
    END IF;
    v_inv := erp.gl_account(p_company, 'inventory', 'inventory');
    v_clr := erp.gl_account(p_company, 'purchasing', 'grpo_clearing');
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_inv, 'debit', v_cost),
                                 jsonb_build_object('acct_code', v_clr, 'credit', v_cost));
    v_trans := erp.post_journal(p_company, d.doc_date, format('Goods receipt PO %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 20, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('20/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 20, p_doc_entry, v_trans);
    RETURN v_trans;
  ELSIF p_obj_type = 204 THEN
    IF coalesce(d.total, 0) <= 0 THEN
      RAISE EXCEPTION 'Down payment invoice % has no amount to post.', v_ref USING ERRCODE = 'P0001';
    END IF;
    v_dp := erp.gl_account(p_company, 'purchasing', 'down_payments');
    v_ap := erp.gl_account(p_company, 'purchasing', 'domestic_ap');
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_dp, 'debit', round(d.total, 2)),
                                 jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'credit', round(d.total, 2)));
    v_trans := erp.post_journal(p_company, d.doc_date, format('A/P down payment invoice %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 204, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'due_date', d.due_date, 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('204/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 204, p_doc_entry, v_trans);
    RETURN v_trans;
  ELSIF p_obj_type = 18 THEN
    SELECT coalesce(sum(line_total), 0), coalesce(sum(vat), 0) INTO v_net, v_vatsum
      FROM erp.document_line WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry;
    SELECT coalesce(sum(amount), 0) INTO v_drawn FROM erp.ap_dp_draw WHERE company_code = p_company AND invoice_entry = p_doc_entry;
    IF v_net + v_vatsum <= 0 THEN
      RAISE EXCEPTION 'A/P invoice % has no amount to post.', v_ref USING ERRCODE = 'P0001';
    END IF;
    v_clr := erp.gl_account(p_company, 'purchasing', 'grpo_clearing');
    v_ap := erp.gl_account(p_company, 'purchasing', 'domestic_ap');
    IF v_vatsum <> 0 THEN
      v_vat := erp.gl_account(p_company, 'purchasing', 'input_vat');
    END IF;
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'debit', round(v_net, 2)));
    v_lines := v_lines || coalesce((
      SELECT jsonb_agg(jsonb_build_object('acct_code', v_vat, 'debit', round(t.vat, 2), 'tax_code', t.tax_code) ORDER BY t.tax_code)
        FROM (SELECT tax_code, sum(vat) AS vat FROM erp.document_line
               WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry GROUP BY tax_code HAVING sum(vat) <> 0) t), '[]'::jsonb);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'credit', round(v_net + v_vatsum, 2)));
    IF v_drawn > 0 THEN
      v_dp := erp.gl_account(p_company, 'purchasing', 'down_payments');
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'debit', round(v_drawn, 2), 'memo', 'Down payment drawn'),
                                              jsonb_build_object('acct_code', v_dp, 'credit', round(v_drawn, 2), 'memo', 'Down payment drawn'));
    END IF;
    v_trans := erp.post_journal(p_company, d.doc_date, format('A/P invoice %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 18, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'due_date', d.due_date,
                         'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('18/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 18, p_doc_entry, v_trans);
    RETURN v_trans;
  END IF;

  -- ---------- Sales (A3 / A4, unchanged) ----------
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

-- Available-to-Promise (replaces 19's). With include_in_transit, containers on the water count by their ETA, and the same
-- quantity is no longer counted again as an open purchase order line (the PO part then excludes what is already shipped).
CREATE OR REPLACE FUNCTION erp._atp(p_company varchar, p_item text, p_whs text, p_date date, r erp.atp_rule) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_all   boolean := r.whs_scope = 'all_whs';
  v_oh    numeric := 0;
  v_cm    numeric := 0;
  v_po    numeric := 0;
  v_tr    numeric := 0;
  v_it    numeric := 0;
  v_ship  numeric := 0;
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
  IF r.include_in_transit THEN
    -- Shipped, not yet received, arriving by the date.
    SELECT coalesce(sum(sl.qty - sl.received_qty), 0) INTO v_it
      FROM erp.purchase_shipment s JOIN erp.purchase_shipment_line sl ON sl.shipment_id = s.shipment_id
     WHERE s.company_code = p_company AND s.status = 'in_transit' AND sl.item_code = p_item AND (v_all OR sl.whs_code = p_whs)
       AND sl.qty > sl.received_qty AND s.eta <= p_date;
    IF r.include_purchase_orders THEN
      -- Open PO quantity already on a container (any ETA) is counted by the container, not by the PO due date.
      SELECT coalesce(sum(sl.qty - sl.received_qty), 0) INTO v_ship
        FROM erp.purchase_shipment s JOIN erp.purchase_shipment_line sl ON sl.shipment_id = s.shipment_id
        JOIN erp.document d ON d.company_code = s.company_code AND d.obj_type = 22 AND d.doc_entry = s.po_doc_entry
       WHERE s.company_code = p_company AND s.status = 'in_transit' AND sl.item_code = p_item AND (v_all OR sl.whs_code = p_whs)
         AND sl.qty > sl.received_qty AND d.status = 'open' AND coalesce(d.due_date, d.doc_date) <= p_date;
      v_po := greatest(v_po - v_ship, 0);
    END IF;
  END IF;
  RETURN jsonb_build_object('rule_code', r.rule_code, 'rule_name', r.name, 'no_check', false, 'date', p_date,
    'scope', r.whs_scope, 'on_hand', v_oh, 'committed', CASE WHEN r.subtract_committed THEN v_cm ELSE 0 END,
    'purchase_orders', v_po, 'transfers', v_tr, 'in_transit', v_it,
    'available', v_oh - CASE WHEN r.subtract_committed THEN v_cm ELSE 0 END + v_po + v_tr + v_it);
END $$;

-- ============ API: purchase requests (1470000113), quotations (540000006) and orders (22) ============
CREATE OR REPLACE FUNCTION erp._pd_check_obj(p_obj integer) RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = erp, pg_temp AS $$
BEGIN
  IF p_obj IS NULL OR p_obj NOT IN (1470000113, 540000006, 22) THEN
    RAISE EXCEPTION 'Only purchase requests, purchase quotations and purchase orders are edited this way.' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Lists and defaults for the purchasing forms (purchasing users cannot read tax_code directly, so it comes from here).
CREATE OR REPLACE FUNCTION erp.purchase_doc_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  st erp.purchase_setting;
BEGIN
  u := erp._pd_guard(p_company, false);
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'tax_codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name, 'rate', rate) ORDER BY code)
                             FROM erp.tax_code WHERE company_code = p_company AND active AND coalesce(category, 'I') <> 'O'), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', whs_code, 'name', name) ORDER BY whs_code)
                              FROM erp.warehouse WHERE company_code = p_company AND active), '[]'::jsonb),
    'payment_terms', coalesce((SELECT jsonb_agg(jsonb_build_object('code', group_num, 'name', name, 'days', extra_days) ORDER BY group_num)
                                 FROM erp.payment_terms WHERE company_code = p_company), '[]'::jsonb),
    'offices', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort, code)
                           FROM erp.china_office WHERE company_code = p_company AND active), '[]'::jsonb),
    'pi_statuses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort, code)
                               FROM erp.pi_status WHERE company_code = p_company AND active), '[]'::jsonb),
    'qc_checklist', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort, code)
                                FROM erp.qc_checklist_item WHERE company_code = p_company AND active), '[]'::jsonb),
    'landed_cost_codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name, 'split_method', split_method) ORDER BY code)
                                     FROM erp.landed_cost_code WHERE company_code = p_company AND active), '[]'::jsonb),
    'default_tax_code', st.default_tax_code,
    'default_whs_code', st.default_whs_code,
    'require_qc_pass', coalesce(st.require_qc_pass, false),
    'numbering', (SELECT jsonb_object_agg(obj_type::text, prefix) FROM erp.number_series
                   WHERE company_code = p_company AND active AND obj_type IN (1470000113, 540000006, 22, 20, 204, 18, 69)),
    'my_po_limit', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 22 AND active AND rule_code = 'po_amount'
                      AND (position_code = u.position_code OR position_code IS NULL) ORDER BY limit_value NULLS LAST, step LIMIT 1),
    'price_increase_pct', (SELECT limit_value FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 22 AND active
                             AND rule_code = 'po_price_increase' AND (position_code = u.position_code OR position_code IS NULL)
                           ORDER BY limit_value NULLS LAST, step LIMIT 1),
    'can_write', erp.can_write('purchase'),
    'can_request', erp.can_read('purchase'),
    'can_finance', erp.can_write('finance'));
END $$;

-- Live preview while typing. Writes nothing.
CREATE OR REPLACE FUNCTION erp.purchase_doc_checks(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, false);
  RETURN erp._pd_eval(p_company, p_obj, p_header, p_lines, u.position_code, p_doc_entry);
END $$;

-- Create (p_doc_entry NULL) or replace a draft owned by the caller. The server prices, totals and numbers the document.
CREATE OR REPLACE FUNCTION erp.purchase_doc_save(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
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
  v_noun text := erp._pd_noun(p_obj);
  v_obj  text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, CASE p_obj WHEN 22 THEN 'create purchase orders' ELSE 'create purchase quotations' END, false, p_obj = 1470000113);
  IF NOT v_new THEN
    w := erp._pd_lock(p_company, p_obj, p_doc_entry);
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

  e := erp._pd_eval(p_company, p_obj, p_header, p_lines, u.position_code, p_doc_entry);
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this %s.', v_nerr - 1, v_noun) ELSE '' END;
  END IF;
  hd := e->'header';

  IF v_new THEN
    nb := erp._pd_number(p_company, p_obj);
    v_num := (nb->>'num')::integer;
    v_no := nb->>'no';
    v_entry := (nb->>'entry')::integer;
    INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                              customer_ref, currency, fx_rate, total, vat_total, paid, branch_id, comments, created_on, source)
    VALUES (p_company, p_obj, v_entry, v_num, erp._pd_kind(p_obj), 'draft', (hd->>'doc_date')::date, (hd->>'due_date')::date, (hd->>'doc_date')::date,
            hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', 1, (e->'totals'->>'total')::numeric,
            (e->'totals'->>'vat')::numeric, 0, (hd->>'branch_id')::integer, hd->>'comments', current_date, 'erp');
    INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, payment_terms, whs_code, china_office)
    VALUES (p_company, p_obj, v_entry, v_no, 'draft', u.user_id, (hd->>'payment_terms')::integer, hd->>'whs_code', hd->>'china_office');
  ELSE
    v_entry := p_doc_entry;
    v_no := w.doc_no;
    SELECT doc_num INTO v_num FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    UPDATE erp.document
       SET status = 'draft', doc_date = (hd->>'doc_date')::date, due_date = (hd->>'due_date')::date, tax_date = (hd->>'doc_date')::date,
           card_code = hd->>'card_code', card_name = hd->>'card_name', customer_ref = hd->>'customer_ref',
           total = (e->'totals'->>'total')::numeric, vat_total = (e->'totals'->>'vat')::numeric,
           branch_id = (hd->>'branch_id')::integer, comments = hd->>'comments'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry AND source = 'erp';
    UPDATE erp.doc_workflow
       SET state = 'draft', updated_at = now(), payment_terms = (hd->>'payment_terms')::integer, whs_code = hd->>'whs_code',
           china_office = hd->>'china_office'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    DELETE FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
  END IF;

  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                 discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, cbm,
                                 base_obj_type, base_doc_entry, base_line)
  SELECT p_company, p_obj, v_entry, x.line_num, x.item_code, x.description, x.qty, x.qty, x.uom, x.price, e->'totals'->>'currency',
         0, x.line_total, x.tax_code, x.vat, x.whs_code, 'O', x.price, x.price, x.cbm, x.base_obj_type, x.base_doc_entry, x.base_line
    FROM jsonb_to_recordset(e->'lines') AS x(line_num int, item_code text, description text, uom text, qty numeric, price numeric,
                                             tax_code text, whs_code text, cbm numeric, line_total numeric, vat numeric,
                                             base_obj_type int, base_doc_entry int, base_line int);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN v_new THEN '_create' ELSE '_update' END, v_obj, v_entry::text,
          jsonb_build_object('doc_no', v_no, 'card_code', hd->>'card_code', 'total', e->'totals'->'total',
                             'lines', jsonb_array_length(e->'lines'), 'checks', jsonb_array_length(e->'checks'),
                             'copied_from', (SELECT jsonb_agg(DISTINCT x.base_doc_entry) FROM jsonb_to_recordset(e->'lines') AS x(base_doc_entry int)
                                              WHERE x.base_doc_entry IS NOT NULL)));

  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_num', v_num, 'doc_no', v_no, 'state', 'draft',
                            'totals', e->'totals', 'checks', e->'checks', 'lines', e->'lines');
END $$;

-- Run the rules: none triggered → approved and open. Otherwise pending_approval with one approval row per rule / step / approver.
-- Requests and quotations have no approval rules: they open straight away.
CREATE OR REPLACE FUNCTION erp.purchase_doc_submit(p_company varchar, p_obj integer, p_doc_entry integer, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  inp    jsonb;
  e      jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_rules text;
  v_noun text := erp._pd_noun(p_obj);
  v_obj  text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, CASE p_obj WHEN 22 THEN 'create purchase orders' ELSE 'create purchase quotations' END, false, p_obj = 1470000113);
  w := erp._pd_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'pending_approval' THEN
    RAISE EXCEPTION 'This % is already waiting for approval.', v_noun USING ERRCODE = 'P0001';
  ELSIF w.state = 'approved' THEN
    RAISE EXCEPTION 'This % is already approved.', v_noun USING ERRCODE = 'P0001';
  ELSIF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is cancelled and can''t be submitted.', v_noun USING ERRCODE = 'P0001';
  ELSIF w.created_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who created this % can submit it.', v_noun USING ERRCODE = 'P0001';
  END IF;

  inp := erp._pd_stored(p_company, p_obj, p_doc_entry);
  e := erp._pd_eval(p_company, p_obj, inp->'header', inp->'lines', u.position_code, p_doc_entry);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Open the draft, fix it and save it again.';
  END IF;
  IF jsonb_array_length(e->'checks') > 0 AND v_reason IS NULL THEN
    SELECT string_agg(DISTINCT CASE c->>'rule_code' WHEN 'po_amount' THEN 'total above your limit' ELSE 'price above the last purchase price' END, ', ')
      INTO v_rules FROM jsonb_array_elements(e->'checks') c;
    RAISE EXCEPTION 'This % needs approval (%). Add a reason for the approver.', v_noun, v_rules USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;

  IF jsonb_array_length(e->'checks') = 0 THEN
    UPDATE erp.doc_workflow SET state = 'approved', submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = now(), updated_at = now()
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    UPDATE erp.document SET status = 'open' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp';
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, v_obj || '_submit', v_obj, p_doc_entry::text,
            jsonb_build_object('doc_no', w.doc_no, 'result', 'approved', 'checks', '[]'::jsonb, 'total', e->'totals'->'total', 'reason', v_reason));
    RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'approved', 'status', 'open', 'checks', '[]'::jsonb);
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
          jsonb_build_object('doc_no', w.doc_no, 'result', 'pending_approval', 'reason', v_reason, 'checks', e->'checks', 'total', e->'totals'->'total'));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'pending_approval', 'status', 'draft', 'checks', e->'checks');
END $$;

-- Approve or reject the current step of a purchase order.
CREATE OR REPLACE FUNCTION erp.purchase_doc_decide(p_company varchar, p_obj integer, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  w        erp.doc_workflow;
  v_note   text := nullif(btrim(p_note), '');
  v_step   smallint;
  v_mine   bigint[];
  v_who    text;
  v_left   integer;
  v_state  text;
  v_noun   text := erp._pd_noun(p_obj);
  v_obj    text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, 'approve purchase orders');
  w := erp._pd_lock(p_company, p_obj, p_doc_entry);
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

  UPDATE erp.approval SET decision = p_decision, approver_user = u.user_id, decided_at = now(), note = v_note WHERE approval_id = ANY (v_mine);
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
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN p_decision = 'approved' THEN '_approve' ELSE '_reject' END, v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', v_state,
                            'status', (SELECT status FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry));
END $$;

-- Cancel: the creator or one of the document's approvers, with a note. A document already copied on (an order with a
-- receipt, a down payment invoice or a shipment; a request or quotation in a live order) can't be cancelled.
CREATE OR REPLACE FUNCTION erp.purchase_doc_cancel(p_company varchar, p_obj integer, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  v_note text := nullif(btrim(p_note), '');
  v_noun text := erp._pd_noun(p_obj);
  v_obj  text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, 'cancel purchasing documents', false, p_obj = 1470000113);
  w := erp._pd_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is already cancelled.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 22 AND EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                             WHERE l.company_code = p_company AND l.base_obj_type = 22 AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled') THEN
    RAISE EXCEPTION 'This purchase order has a goods receipt or a down payment invoice and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF p_obj = 22 AND EXISTS (SELECT 1 FROM erp.purchase_shipment WHERE company_code = p_company AND po_doc_entry = p_doc_entry) THEN
    RAISE EXCEPTION 'This purchase order has a shipment and can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF p_obj IN (1470000113, 540000006) AND EXISTS (
       SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
        WHERE l.company_code = p_company AND l.obj_type = 22 AND l.base_obj_type = p_obj AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled') THEN
    RAISE EXCEPTION 'This % was copied to a purchase order and can''t be cancelled. Cancel the order first.', v_noun USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (
       SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND approver_position = u.position_code) THEN
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
  VALUES (u.user_id::text, p_company, v_obj || '_cancel', v_obj, p_doc_entry::text, jsonb_build_object('doc_no', w.doc_no, 'from_state', w.state, 'note', v_note));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled', 'status', 'cancelled');
END $$;

-- What the request / quotation / order page needs beyond the document. NULL when not visible; {workflow:false} for SAP / sample.
-- A purchase order also gets its proforma invoices, down payments, QC inspections and shipments.
CREATE OR REPLACE FUNCTION erp.purchase_doc_info(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  d        erp.document;
  w        erp.doc_workflow;
  st       erp.purchase_setting;
  v_write  boolean;
  v_step   smallint;
  v_mine   boolean;
  v_appr   boolean;
  v_live_child boolean;
  v_open   boolean;
  v_obj    text := erp._pd_object(p_obj);
  v_lastqc text;
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN jsonb_build_object('workflow', false, 'source', d.source); END IF;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;

  v_write := erp.can_write('purchase') OR (p_obj = 1470000113 AND erp.can_read('purchase'));
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND approver_position = u.position_code);
  v_live_child := EXISTS (SELECT 1 FROM erp.document_line l JOIN erp.document o ON o.company_code = l.company_code AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry
                           WHERE l.company_code = p_company AND l.base_obj_type = p_obj AND l.base_doc_entry = p_doc_entry AND o.status <> 'cancelled'
                             AND (p_obj = 22 OR l.obj_type = 22))
                  OR (p_obj = 22 AND EXISTS (SELECT 1 FROM erp.purchase_shipment WHERE company_code = p_company AND po_doc_entry = p_doc_entry));
  v_open := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND coalesce(line_status, 'O') = 'O');
  SELECT result INTO v_lastqc FROM erp.qc_inspection WHERE company_code = p_company AND po_doc_entry = p_doc_entry ORDER BY qc_id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'workflow', true,
    'obj_type', p_obj,
    'source', d.source,
    'doc_no', w.doc_no,
    'state', w.state,
    'status', d.status,
    'china_office', w.china_office,
    'china_office_name', (SELECT name FROM erp.china_office WHERE company_code = p_company AND code = w.china_office),
    'whs_code', w.whs_code, 'payment_terms', w.payment_terms,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.submitted_by),
    'submitted_at', w.submitted_at,
    'reason', w.reason,
    'cancel_note', w.cancel_note,
    'cancelled_at', w.cancelled_at,
    'is_creator', w.created_by = u.user_id,
    'is_submitter', w.submitted_by = u.user_id,
    'can_edit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_submit', v_write AND w.created_by = u.user_id AND w.state IN ('draft', 'rejected'),
    'can_cancel', v_write AND w.state <> 'cancelled' AND NOT v_live_child AND (w.created_by = u.user_id OR v_appr),
    'can_decide', erp.can_write('purchase') AND w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_copy', erp.can_write('purchase') AND w.state = 'approved' AND d.status = 'open' AND v_open,
    'copy_block', CASE WHEN w.state <> 'approved' THEN 'not_approved' WHEN d.status <> 'open' OR NOT v_open THEN 'closed'
                       WHEN NOT erp.can_write('purchase') THEN 'read_only' END,
    'can_write', erp.can_write('purchase'),
    'can_finance', erp.can_write('finance'),
    'require_qc_pass', coalesce(st.require_qc_pass, false),
    'last_qc', v_lastqc,
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
    'pis', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('pi_id', pi.pi_id, 'vendor_pi_no', pi.vendor_pi_no, 'pi_date', pi.pi_date, 'amount', pi.amount, 'eta', pi.eta,
               'status', pi.status, 'status_name', ps.name, 'deposit_doc_entry', pi.deposit_doc_entry, 'note', pi.note, 'updated_at', pi.updated_at,
               'deposit_doc_no', (SELECT doc_no FROM erp.doc_workflow WHERE company_code = pi.company_code AND obj_type = 204 AND doc_entry = pi.deposit_doc_entry))
             ORDER BY pi.pi_id)
        FROM erp.purchase_pi pi LEFT JOIN erp.pi_status ps ON ps.company_code = pi.company_code AND ps.code = pi.status
       WHERE pi.company_code = p_company AND pi.po_doc_entry = p_doc_entry), '[]'::jsonb) END,
    'deposits', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('doc_entry', dd.doc_entry, 'doc_no', dw.doc_no, 'doc_date', dd.doc_date, 'total', dd.total, 'paid', coalesce(dd.paid, 0),
               'drawn', (SELECT coalesce(sum(x.amount), 0) FROM erp.ap_dp_draw x WHERE x.company_code = dd.company_code AND x.dp_entry = dd.doc_entry),
               'status', dd.status) ORDER BY dd.doc_entry)
        FROM erp.document dd JOIN erp.doc_workflow dw ON dw.company_code = dd.company_code AND dw.obj_type = dd.obj_type AND dw.doc_entry = dd.doc_entry
       WHERE dd.company_code = p_company AND dd.obj_type = 204 AND dd.source = 'erp' AND dd.status <> 'cancelled'
         AND EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = dd.company_code AND l.obj_type = 204 AND l.doc_entry = dd.doc_entry
                        AND l.base_obj_type = 22 AND l.base_doc_entry = p_doc_entry)), '[]'::jsonb) END,
    'qcs', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('qc_id', q.qc_id, 'inspected_on', q.inspected_on, 'inspector', q.inspector, 'result', q.result,
               'checklist', q.checklist, 'photos', to_jsonb(q.photos), 'note', q.note, 'created_at', q.created_at,
               'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = q.created_by)) ORDER BY q.qc_id)
        FROM erp.qc_inspection q WHERE q.company_code = p_company AND q.po_doc_entry = p_doc_entry), '[]'::jsonb) END,
    'shipments', CASE WHEN p_obj = 22 THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('shipment_id', s.shipment_id, 'container_no', s.container_no, 'shipping_mark', s.shipping_mark,
               'shipment_mode', s.shipment_mode, 'etd', s.etd, 'eta', s.eta, 'status', s.status, 'note', s.note,
               'lines', (SELECT jsonb_agg(jsonb_build_object('po_line', sl.po_line, 'item_code', sl.item_code, 'whs_code', sl.whs_code,
                                                              'qty', sl.qty, 'received_qty', sl.received_qty) ORDER BY sl.po_line)
                           FROM erp.purchase_shipment_line sl WHERE sl.shipment_id = s.shipment_id)) ORDER BY s.shipment_id)
        FROM erp.purchase_shipment s WHERE s.company_code = p_company AND s.po_doc_entry = p_doc_entry), '[]'::jsonb) END,
    'activity', coalesce((
      SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                       ORDER BY l.at, l.audit_id)
        FROM erp.audit_log l
        LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
       WHERE l.company_code = p_company
         AND ((l.object = v_obj AND l.object_ref = p_doc_entry::text)
              OR (p_obj = 22 AND l.object IN ('purchase_pi', 'qc_inspection', 'purchase_shipment') AND l.detail->>'po_doc_entry' = p_doc_entry::text))), '[]'::jsonb));
END $$;

-- Open lines that can be copied on: from one Super ERP document (p_doc_entry), or every open one of a supplier (p_card_code).
-- Requests (1470000113) → quotation / order; quotations (540000006) and requests → order; orders (22) → goods receipt;
-- goods receipts (20) → A/P invoice.
CREATE OR REPLACE FUNCTION erp.purchase_copy_source(p_company varchar, p_obj integer, p_doc_entry integer, p_card_code text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u    erp.app_user;
  d    erp.document;
  w    erp.doc_workflow;
  v_no text;
BEGIN
  u := erp._pd_guard(p_company, false);
  IF p_obj IS NULL OR p_obj NOT IN (1470000113, 540000006, 22, 20) THEN
    RAISE EXCEPTION 'Copy to works from purchase requests, quotations, orders and goods receipts only.' USING ERRCODE = 'P0001';
  END IF;
  IF p_doc_entry IS NOT NULL THEN
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% % was not found in company %.', erp._pd_name(p_obj), p_doc_entry, p_company USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    v_no := coalesce(w.doc_no, d.doc_num::text);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION '% % came from %. Copy to works on Super ERP documents only.', erp._pd_name(p_obj), v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION '% % is not approved yet, so it can''t be copied.', erp._pd_name(p_obj), v_no USING ERRCODE = 'P0001';
    END IF;
    IF d.status <> 'open' THEN
      RAISE EXCEPTION '% % is %, so nothing is left to copy.', erp._pd_name(p_obj), v_no, d.status USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN jsonb_build_object(
    'obj_type', p_obj,
    'header', CASE WHEN p_doc_entry IS NOT NULL THEN jsonb_build_object(
                'doc_entry', d.doc_entry, 'doc_no', v_no, 'card_code', d.card_code, 'card_name', d.card_name, 'doc_date', d.doc_date,
                'due_date', d.due_date, 'payment_terms', w.payment_terms, 'whs_code', w.whs_code, 'china_office', w.china_office,
                'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'total', d.total) END,
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'base_obj_type', l.obj_type, 'base_doc_entry', l.doc_entry, 'base_line', l.line_num, 'base_doc_no', coalesce(lw.doc_no, ld.doc_num::text),
               'base_doc_date', ld.doc_date, 'card_code', ld.card_code, 'item_code', l.item_code, 'description', l.description, 'uom', l.uom,
               'quantity', l.quantity, 'open_qty', l.open_qty, 'price', l.price, 'discount_pct', 0, 'tax_code', l.tax_code,
               'tax_rate', (SELECT t.rate FROM erp.tax_code t WHERE t.company_code = l.company_code AND t.code = l.tax_code),
               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cbm', l.cbm, 'cost', l.stock_price, 'is_stock', true,
               'on_hand', (SELECT sb.on_hand FROM erp.stock_balance sb WHERE sb.company_code = l.company_code AND sb.item_code = l.item_code AND sb.whs_code = l.whs_code),
               'in_transit', CASE WHEN l.obj_type = 22 THEN (SELECT coalesce(sum(sl.qty - sl.received_qty), 0) FROM erp.purchase_shipment s
                                                              JOIN erp.purchase_shipment_line sl ON sl.shipment_id = s.shipment_id
                                                             WHERE s.company_code = l.company_code AND s.po_doc_entry = l.doc_entry
                                                               AND sl.po_line = l.line_num AND s.status = 'in_transit') END)
             ORDER BY ld.doc_date, l.doc_entry, l.line_num)
        FROM erp.document_line l
        JOIN erp.document ld ON ld.company_code = l.company_code AND ld.obj_type = l.obj_type AND ld.doc_entry = l.doc_entry
        JOIN erp.doc_workflow lw ON lw.company_code = l.company_code AND lw.obj_type = l.obj_type AND lw.doc_entry = l.doc_entry AND lw.state = 'approved'
       WHERE l.company_code = p_company AND l.obj_type = p_obj AND ld.source = 'erp' AND ld.status = 'open'
         AND coalesce(l.line_status, 'O') = 'O' AND l.open_qty > 0
         AND (CASE WHEN p_doc_entry IS NOT NULL THEN l.doc_entry = p_doc_entry ELSE ld.card_code = p_card_code END)), '[]'::jsonb));
END $$;

-- Purchase Quotation Comparison: every quotation copied from one request, line by line, side by side (cheapest marked).
CREATE OR REPLACE FUNCTION erp.purchase_quotation_compare(p_company varchar, p_request integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  d erp.document;
  w erp.doc_workflow;
BEGIN
  u := erp._pd_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 1470000113 AND doc_entry = p_request;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Purchase request % was not found in company %.', p_request, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 1470000113 AND doc_entry = p_request;
  RETURN jsonb_build_object(
    'request', jsonb_build_object('doc_entry', d.doc_entry, 'doc_no', coalesce(w.doc_no, d.doc_num::text), 'doc_date', d.doc_date, 'due_date', d.due_date,
                                  'status', d.status, 'state', w.state, 'source', d.source, 'currency', d.currency, 'comments', d.comments,
                                  'china_office', w.china_office),
    'quotations', coalesce((
      SELECT jsonb_agg(jsonb_build_object('doc_entry', q.doc_entry, 'doc_no', qw.doc_no, 'card_code', q.card_code, 'card_name', q.card_name,
                                          'doc_date', q.doc_date, 'due_date', q.due_date, 'status', q.status, 'state', qw.state, 'total', q.total,
                                          'customer_ref', q.customer_ref) ORDER BY q.total, q.doc_entry)
        FROM erp.document q JOIN erp.doc_workflow qw ON qw.company_code = q.company_code AND qw.obj_type = q.obj_type AND qw.doc_entry = q.doc_entry
       WHERE q.company_code = p_company AND q.obj_type = 540000006 AND q.status <> 'cancelled'
         AND EXISTS (SELECT 1 FROM erp.document_line ql WHERE ql.company_code = q.company_code AND ql.obj_type = q.obj_type AND ql.doc_entry = q.doc_entry
                        AND ql.base_obj_type = 1470000113 AND ql.base_doc_entry = p_request)), '[]'::jsonb),
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'line_num', rl.line_num, 'item_code', rl.item_code, 'description', rl.description, 'quantity', rl.quantity, 'open_qty', rl.open_qty,
               'uom', rl.uom, 'last_price', (erp._pd_last_price(p_company, rl.item_code, NULL))->'price',
               'offers', coalesce((
                 SELECT jsonb_agg(o.j ORDER BY o.price, o.doc_entry) FROM (
                   SELECT ql.price, q.doc_entry,
                          jsonb_build_object('doc_entry', ql.doc_entry, 'line_num', ql.line_num, 'card_code', q.card_code, 'card_name', q.card_name,
                                             'doc_no', qw.doc_no, 'price', ql.price, 'qty', ql.quantity, 'open_qty', ql.open_qty, 'line_total', ql.line_total,
                                             'status', q.status, 'state', qw.state, 'best', ql.price = min(ql.price) OVER ()) AS j
                     FROM erp.document_line ql
                     JOIN erp.document q ON q.company_code = ql.company_code AND q.obj_type = ql.obj_type AND q.doc_entry = ql.doc_entry
                     JOIN erp.doc_workflow qw ON qw.company_code = q.company_code AND qw.obj_type = q.obj_type AND qw.doc_entry = q.doc_entry
                    WHERE ql.company_code = p_company AND ql.obj_type = 540000006 AND ql.base_obj_type = 1470000113 AND ql.base_doc_entry = p_request
                      AND ql.base_line = rl.line_num AND q.status <> 'cancelled') o), '[]'::jsonb)) ORDER BY rl.line_num)
        FROM erp.document_line rl WHERE rl.company_code = p_company AND rl.obj_type = 1470000113 AND rl.doc_entry = p_request), '[]'::jsonb));
END $$;

-- A purchase order the next China steps hang on: Super ERP, approved, not cancelled. Raises otherwise. Internal.
CREATE OR REPLACE FUNCTION erp._pd_po(p_company varchar, p_po integer, p_what text, p_need_open boolean DEFAULT true) RETURNS erp.document
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d erp.document;
  w erp.doc_workflow;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 22 AND doc_entry = p_po FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Purchase order % was not found in company %.', coalesce(p_po::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 22 AND doc_entry = p_po;
  IF d.source <> 'erp' THEN
    RAISE EXCEPTION 'Purchase order % came from %. % works on Super ERP purchase orders only.', d.doc_num,
      CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END, p_what USING ERRCODE = 'P0001';
  END IF;
  IF w.state IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION 'Purchase order % is not approved yet (%). % needs an approved order.', w.doc_no, replace(coalesce(w.state, d.status), '_', ' '), p_what
      USING ERRCODE = 'P0001';
  END IF;
  IF d.status = 'cancelled' OR (p_need_open AND d.status <> 'open') THEN
    RAISE EXCEPTION 'Purchase order % is %. % needs an open order.', w.doc_no, d.status, p_what USING ERRCODE = 'P0001';
  END IF;
  RETURN d;
END $$;

-- ============ API: proforma invoice (PI) and deposit ============
-- Add (p_pi_id NULL) or update a supplier's proforma invoice on a purchase order. Every status change is in the activity.
-- p_data: {po_doc_entry, vendor_pi_no, pi_date, amount, eta, status, note}
CREATE OR REPLACE FUNCTION erp.purchase_pi_save(p_company varchar, p_pi_id integer, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  h      jsonb := coalesce(p_data, '{}'::jsonb);
  pi     erp.purchase_pi;
  d      erp.document;
  v_po   integer;
  v_no   text := nullif(btrim(h->>'vendor_pi_no'), '');
  v_date date;
  v_eta  date;
  v_amt  numeric;
  v_st   text := nullif(btrim(h->>'status'), '');
  v_id   integer;
BEGIN
  u := erp._pd_guard(p_company, true, 'record proforma invoices');
  IF p_pi_id IS NOT NULL THEN
    SELECT * INTO pi FROM erp.purchase_pi WHERE company_code = p_company AND pi_id = p_pi_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Proforma invoice % was not found in company %.', p_pi_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_po := pi.po_doc_entry;
  ELSE
    v_po := erp._num(h->>'po_doc_entry')::integer;
  END IF;
  d := erp._pd_po(p_company, v_po, 'A proforma invoice', false);
  IF v_no IS NULL THEN
    RAISE EXCEPTION 'Enter the supplier''s PI number.' USING ERRCODE = 'P0001';
  END IF;
  v_date := erp._date(h->>'pi_date');
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Enter the PI date.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(h->>'eta'), '') IS NOT NULL THEN
    v_eta := erp._date(h->>'eta');
    IF v_eta IS NULL THEN
      RAISE EXCEPTION 'The ETA is not a valid date.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF nullif(btrim(h->>'amount'), '') IS NOT NULL THEN
    v_amt := erp._num(h->>'amount');
    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'The PI amount must be more than 0.' USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(v_amt, 2);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.pi_status WHERE company_code = p_company AND active) THEN
    RAISE EXCEPTION 'PI statuses are not set up for %. Ask Purchasing to add them in Purchasing › Purchasing Setup.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_st IS NULL THEN
    RAISE EXCEPTION 'Choose the PI status.' USING ERRCODE = 'P0001';
  ELSIF NOT EXISTS (SELECT 1 FROM erp.pi_status WHERE company_code = p_company AND code = v_st AND active) THEN
    RAISE EXCEPTION 'PI status % is not set up for %.', v_st, p_company USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.purchase_pi WHERE company_code = p_company AND card_code = d.card_code AND vendor_pi_no = v_no AND pi_id IS DISTINCT FROM p_pi_id) THEN
    RAISE EXCEPTION 'PI % of supplier % is already recorded.', v_no, d.card_code USING ERRCODE = 'P0001';
  END IF;

  IF p_pi_id IS NULL THEN
    INSERT INTO erp.purchase_pi (company_code, po_doc_entry, card_code, vendor_pi_no, pi_date, amount, eta, status, note, created_by, updated_by)
    VALUES (p_company, v_po, d.card_code, v_no, v_date, v_amt, v_eta, v_st, nullif(btrim(h->>'note'), ''), u.user_id, u.user_id)
    RETURNING pi_id INTO v_id;
  ELSE
    v_id := p_pi_id;
    UPDATE erp.purchase_pi SET vendor_pi_no = v_no, pi_date = v_date, amount = v_amt, eta = v_eta, status = v_st, note = nullif(btrim(h->>'note'), ''),
                               updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND pi_id = p_pi_id;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_pi_id IS NULL THEN 'purchase_pi_create' ELSE 'purchase_pi_update' END, 'purchase_pi', v_id::text,
          jsonb_build_object('po_doc_entry', v_po, 'vendor_pi_no', v_no, 'amount', v_amt, 'eta', v_eta, 'status', v_st,
                             'from_status', CASE WHEN p_pi_id IS NOT NULL THEN pi.status END));
  RETURN jsonb_build_object('pi_id', v_id, 'status', v_st, 'vendor_pi_no', v_no);
END $$;

-- Deposit: an A/P down payment invoice (204) for the supplier, based on the purchase order. It posts Dr down payments /
-- Cr payable, and is then paid through Banking › Outgoing Payments (A5 allocates to it). Deposits can't exceed the order.
-- p_header: {doc_date, amount | pct (of the order total), due_date, pi_id, comments}
CREATE OR REPLACE FUNCTION erp.purchase_deposit_create(p_company varchar, p_po integer, p_header jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  d       erp.document;
  w       erp.doc_workflow;
  v_date  date;
  v_due   date;
  v_amt   numeric;
  v_pct   numeric;
  v_prev  numeric;
  v_pi    integer := erp._num(h->>'pi_id')::integer;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_cur   text;
BEGIN
  u := erp._pd_guard(p_company, true, 'raise deposits');
  d := erp._pd_po(p_company, p_po, 'A deposit');
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 22 AND doc_entry = p_po;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  v_date := erp._sd_doc_date(h);
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL OR v_due < v_date THEN
      RAISE EXCEPTION 'The due date must be a valid date on or after the posting date.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF nullif(btrim(h->>'amount'), '') IS NOT NULL THEN
    v_amt := erp._num(h->>'amount');
  ELSIF nullif(btrim(h->>'pct'), '') IS NOT NULL THEN
    v_pct := erp._num(h->>'pct');
    IF v_pct IS NULL OR v_pct <= 0 OR v_pct > 100 THEN
      RAISE EXCEPTION 'The deposit percentage must be more than 0 and at most 100.' USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(d.total * v_pct / 100, 2);
  END IF;
  IF v_amt IS NULL OR v_amt <= 0 THEN
    RAISE EXCEPTION 'Enter the deposit amount (or a percentage of the order).' USING ERRCODE = 'P0001';
  END IF;
  v_amt := round(v_amt, 2);
  SELECT coalesce(sum(dd.total), 0) INTO v_prev
    FROM erp.document dd
   WHERE dd.company_code = p_company AND dd.obj_type = 204 AND dd.source = 'erp' AND dd.status <> 'cancelled'
     AND EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = dd.company_code AND l.obj_type = 204 AND l.doc_entry = dd.doc_entry
                    AND l.base_obj_type = 22 AND l.base_doc_entry = p_po);
  IF v_prev + v_amt > d.total THEN
    RAISE EXCEPTION '%', format('Deposits on %s would be %s %s, more than the order total of %s %s (%s %s already raised).',
      w.doc_no, erp._money(v_prev + v_amt), v_cur, erp._money(d.total), v_cur, erp._money(v_prev), v_cur) USING ERRCODE = 'P0001';
  END IF;
  IF v_pi IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.purchase_pi WHERE company_code = p_company AND pi_id = v_pi AND po_doc_entry = p_po) THEN
    RAISE EXCEPTION 'Proforma invoice % does not belong to purchase order %.', v_pi, w.doc_no USING ERRCODE = 'P0001';
  END IF;

  nb := erp._pd_number(p_company, 204);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                            customer_ref, currency, fx_rate, total, vat_total, paid, branch_id, comments, created_on, source)
  VALUES (p_company, 204, v_entry, (nb->>'num')::integer, 'ap_down_payment', 'open', v_date, coalesce(v_due, v_date), v_date, d.card_code, d.card_name,
          coalesce((SELECT vendor_pi_no FROM erp.purchase_pi WHERE pi_id = v_pi), d.customer_ref), v_cur, 1, v_amt, 0, 0, d.branch_id,
          nullif(btrim(h->>'comments'), ''), current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, china_office)
  VALUES (p_company, 204, v_entry, nb->>'no', 'approved', u.user_id, u.user_id, now(), now(), w.china_office);
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, description, quantity, open_qty, price, currency, discount_pct,
                                 line_total, vat, line_status, base_obj_type, base_doc_entry)
  VALUES (p_company, 204, v_entry, 0, format('Deposit for %s', w.doc_no), 1, 0, v_amt, v_cur, 0, v_amt, 0, 'C', 22, p_po);
  v_trans := erp.post_document(p_company, 204, v_entry);
  PERFORM erp._bp_balance_add(p_company, d.card_code, -v_amt);
  IF v_pi IS NOT NULL THEN
    UPDATE erp.purchase_pi SET deposit_doc_entry = v_entry, updated_by = u.user_id, updated_at = now() WHERE company_code = p_company AND pi_id = v_pi;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ap_down_payment_create', 'ap_down_payment', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', d.card_code, 'total', v_amt, 'po_doc_entry', p_po, 'po_doc_no', w.doc_no,
                             'pi_id', v_pi, 'trans_id', v_trans));
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'purchase_order_deposit', 'purchase_order', p_po::text,
          jsonb_build_object('doc_no', w.doc_no, 'deposit_doc_no', nb->>'no', 'total', v_amt));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_amt, 'trans_id', v_trans, 'card_code', d.card_code);
END $$;

-- ============ API: QC inspection and shipment ============
-- Record a QC inspection of a purchase order. p_data: {po_doc_entry, inspected_on, inspector, result (pass|fail|rework),
-- checklist:[{code, ok, note}], photos:[object names in bucket qc: <company>/<po>/<file>], note}. Fail and rework need a note.
CREATE OR REPLACE FUNCTION erp.purchase_qc_save(p_company varchar, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  h      jsonb := coalesce(p_data, '{}'::jsonb);
  d      erp.document;
  v_po   integer := erp._num(h->>'po_doc_entry')::integer;
  v_on   date;
  v_res  text := nullif(btrim(h->>'result'), '');
  v_note text := nullif(btrim(h->>'note'), '');
  v_list jsonb := '[]';
  v_ph   text[] := '{}';
  x      jsonb;
  ci     erp.qc_checklist_item;
  v_p    text;
  v_id   integer;
  v_no   text;
BEGIN
  u := erp._pd_guard(p_company, true, 'record QC inspections');
  d := erp._pd_po(p_company, v_po, 'A QC inspection');
  v_no := erp._sd_no(p_company, 22, v_po);
  v_on := erp._date(h->>'inspected_on');
  IF v_on IS NULL THEN
    RAISE EXCEPTION 'Enter the inspection date.' USING ERRCODE = 'P0001';
  ELSIF v_on > current_date THEN
    RAISE EXCEPTION 'The inspection date can''t be in the future.' USING ERRCODE = 'P0001';
  END IF;
  IF v_res IS NULL OR v_res NOT IN ('pass', 'fail', 'rework') THEN
    RAISE EXCEPTION 'Choose the result: pass, fail or rework.' USING ERRCODE = 'P0001';
  END IF;
  IF v_res <> 'pass' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying what failed or needs rework.' USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(h->'checklist') = 'array' THEN h->'checklist' ELSE '[]'::jsonb END) LOOP
    SELECT * INTO ci FROM erp.qc_checklist_item WHERE company_code = p_company AND code = x->>'code';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'QC checklist item % is not set up for %.', coalesce(x->>'code', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    v_list := v_list || jsonb_build_object('code', ci.code, 'name', ci.name, 'ok', coalesce((x->>'ok')::boolean, false), 'note', nullif(btrim(x->>'note'), ''));
  END LOOP;
  IF v_res = 'pass' AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) c WHERE NOT (c->>'ok')::boolean) THEN
    RAISE EXCEPTION 'A checklist item is not ticked, so the result can''t be pass. Tick it, or choose fail or rework.' USING ERRCODE = 'P0001';
  END IF;
  FOR v_p IN SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(h->'photos') = 'array' THEN h->'photos' ELSE '[]'::jsonb END) LOOP
    IF v_p NOT LIKE p_company || '/' || v_po || '/%' OR v_p LIKE '%..%' THEN
      RAISE EXCEPTION 'Photo % is not stored under qc/%/%/. Upload it again from this page.', v_p, p_company, v_po USING ERRCODE = 'P0001';
    END IF;
    v_ph := v_ph || v_p;
  END LOOP;
  INSERT INTO erp.qc_inspection (company_code, po_doc_entry, inspected_on, inspector, result, checklist, photos, note, created_by)
  VALUES (p_company, v_po, v_on, nullif(btrim(h->>'inspector'), ''), v_res, v_list, v_ph, v_note, u.user_id)
  RETURNING qc_id INTO v_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'qc_inspection_create', 'qc_inspection', v_id::text,
          jsonb_build_object('po_doc_entry', v_po, 'doc_no', v_no, 'result', v_res, 'photos', cardinality(v_ph), 'note', v_note));
  RETURN jsonb_build_object('qc_id', v_id, 'result', v_res);
END $$;

-- Record a shipment (container) for a purchase order, or change its header (p_shipment_id: container, mark, mode, ETD / ETA).
-- p_header: {po_doc_entry, container_no, shipping_mark, shipment_mode, etd, eta, note}; p_lines: [{po_line, qty}] (new only).
-- With purchase_setting.require_qc_pass, the order's last QC inspection must be a pass.
CREATE OR REPLACE FUNCTION erp.purchase_shipment_save(p_company varchar, p_shipment_id integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  h      jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  s      erp.purchase_shipment;
  d      erp.document;
  st     erp.purchase_setting;
  v_po   integer;
  v_no   text;
  v_etd  date;
  v_eta  date;
  v_qc   text;
  v_mode text := nullif(btrim(h->>'shipment_mode'), '');
  x      jsonb;
  pl     erp.document_line;
  v_qty  numeric;
  v_ship numeric;
  v_ln   integer;
  i      integer := 0;
  v_id   integer;
BEGIN
  u := erp._pd_guard(p_company, true, 'record shipments');
  IF p_shipment_id IS NOT NULL THEN
    SELECT * INTO s FROM erp.purchase_shipment WHERE company_code = p_company AND shipment_id = p_shipment_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Shipment % was not found in company %.', p_shipment_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_po := s.po_doc_entry;
  ELSE
    v_po := erp._num(h->>'po_doc_entry')::integer;
  END IF;
  d := erp._pd_po(p_company, v_po, 'A shipment', p_shipment_id IS NULL);
  v_no := erp._sd_no(p_company, 22, v_po);
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;
  IF nullif(btrim(h->>'eta'), '') IS NULL THEN
    RAISE EXCEPTION 'Enter the ETA (expected arrival date).' USING ERRCODE = 'P0001';
  END IF;
  v_eta := erp._date(h->>'eta');
  IF v_eta IS NULL THEN
    RAISE EXCEPTION 'The ETA is not a valid date.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(h->>'etd'), '') IS NOT NULL THEN
    v_etd := erp._date(h->>'etd');
    IF v_etd IS NULL THEN
      RAISE EXCEPTION 'The ETD is not a valid date.' USING ERRCODE = 'P0001';
    ELSIF v_eta < v_etd THEN
      RAISE EXCEPTION 'The ETA can''t be before the ETD.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_mode IS NOT NULL AND v_mode NOT IN ('sea', 'air', 'road', 'courier') THEN
    RAISE EXCEPTION 'Choose the shipment mode: sea, air, road or courier.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mode = 'sea' AND nullif(btrim(h->>'container_no'), '') IS NULL THEN
    RAISE EXCEPTION 'Enter the container number for a sea shipment.' USING ERRCODE = 'P0001';
  END IF;

  IF p_shipment_id IS NOT NULL THEN
    UPDATE erp.purchase_shipment SET container_no = nullif(btrim(h->>'container_no'), ''), shipping_mark = nullif(btrim(h->>'shipping_mark'), ''),
                                     shipment_mode = v_mode, etd = v_etd, eta = v_eta, note = nullif(btrim(h->>'note'), ''),
                                     updated_by = u.user_id, updated_at = now()
     WHERE shipment_id = p_shipment_id;
    v_id := p_shipment_id;
  ELSE
    IF coalesce(st.require_qc_pass, false) THEN
      SELECT result INTO v_qc FROM erp.qc_inspection WHERE company_code = p_company AND po_doc_entry = v_po ORDER BY qc_id DESC LIMIT 1;
      IF v_qc IS NULL THEN
        RAISE EXCEPTION 'Purchase order % has no QC inspection yet. Record a passed inspection before shipping.', v_no USING ERRCODE = 'P0001';
      ELSIF v_qc <> 'pass' THEN
        RAISE EXCEPTION 'The last QC inspection of % was %. Record a passed inspection before shipping.', v_no, v_qc USING ERRCODE = 'P0001';
      END IF;
    END IF;
    IF jsonb_array_length(v_lines) = 0 THEN
      RAISE EXCEPTION 'Add at least one line to the shipment.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.purchase_shipment (company_code, po_doc_entry, container_no, shipping_mark, shipment_mode, etd, eta, note, created_by, updated_by)
    VALUES (p_company, v_po, nullif(btrim(h->>'container_no'), ''), nullif(btrim(h->>'shipping_mark'), ''), v_mode, v_etd, v_eta,
            nullif(btrim(h->>'note'), ''), u.user_id, u.user_id)
    RETURNING shipment_id INTO v_id;
    FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
      i := i + 1;
      v_ln := erp._num(x->>'po_line')::integer;
      v_qty := erp._num(x->>'qty');
      SELECT * INTO pl FROM erp.document_line WHERE company_code = p_company AND obj_type = 22 AND doc_entry = v_po AND line_num = v_ln;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Line %: purchase order % has no line %.', i, v_no, coalesce((v_ln + 1)::text, '(none)') USING ERRCODE = 'P0001';
      END IF;
      IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'Line %: quantity must be more than 0.', i USING ERRCODE = 'P0001';
      END IF;
      SELECT coalesce(sum(sl.qty - sl.received_qty), 0) INTO v_ship
        FROM erp.purchase_shipment ps JOIN erp.purchase_shipment_line sl ON sl.shipment_id = ps.shipment_id
       WHERE ps.company_code = p_company AND ps.po_doc_entry = v_po AND sl.po_line = v_ln AND ps.status = 'in_transit';
      IF v_qty > coalesce(pl.open_qty, 0) - v_ship THEN
        RAISE EXCEPTION '%', format('Line %s: you are shipping %s of %s but only %s are open on %s and not on a shipment yet.', i, trim_scale(v_qty),
          pl.item_code, trim_scale(greatest(coalesce(pl.open_qty, 0) - v_ship, 0)), v_no) USING ERRCODE = 'P0001';
      END IF;
      INSERT INTO erp.purchase_shipment_line (shipment_id, po_line, company_code, item_code, whs_code, qty)
      VALUES (v_id, v_ln, p_company, pl.item_code, pl.whs_code, v_qty);
    END LOOP;
  END IF;
  -- The order shows its latest container (SAP U_ContainerNum / U_ShippingMark / U_Shipment_Mode).
  UPDATE erp.document SET container_no = nullif(btrim(h->>'container_no'), ''), shipping_mark = nullif(btrim(h->>'shipping_mark'), ''), shipment_mode = v_mode
   WHERE company_code = p_company AND obj_type = 22 AND doc_entry = v_po AND source = 'erp';
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_shipment_id IS NULL THEN 'purchase_shipment_create' ELSE 'purchase_shipment_update' END,
          'purchase_shipment', v_id::text,
          jsonb_build_object('po_doc_entry', v_po, 'doc_no', v_no, 'container_no', nullif(btrim(h->>'container_no'), ''), 'eta', v_eta,
                             'from_eta', CASE WHEN p_shipment_id IS NOT NULL THEN s.eta END, 'lines', jsonb_array_length(v_lines)));
  RETURN jsonb_build_object('shipment_id', v_id, 'eta', v_eta);
END $$;

-- ============ Goods receipt PO (20) and A/P invoice (18) ============
-- Base lines of a goods receipt (from PO lines) or an A/P invoice (from goods receipt lines), checked and locked. Internal.
-- p_lines: [{base_doc_entry, base_line, qty, whs_code?}]. Returns the lines with the base data, or raises the first problem.
CREATE OR REPLACE FUNCTION erp._pd_base_lines(p_company varchar, p_base_obj integer, p_lines jsonb, p_verb text) RETURNS jsonb
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
  v_base  text := CASE p_base_obj WHEN 22 THEN 'Purchase order' ELSE 'Goods receipt' END;
  v_lb    text := CASE p_base_obj WHEN 22 THEN 'purchase order' ELSE 'goods receipt' END;
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
      RAISE EXCEPTION '%', format('%s %s came from %s, so it can''t be %sed in Super ERP.', v_base, v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END, p_verb) USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' OR d.status <> 'open' THEN
      RAISE EXCEPTION '%', format('%s %s is not open (%s). Only approved, open documents can be %sed.', v_base, v_no,
        CASE WHEN w.state IS DISTINCT FROM 'approved' THEN replace(coalesce(w.state, d.status), '_', ' ') ELSE d.status END, p_verb) USING ERRCODE = 'P0001';
    END IF;
    IF v_card IS NULL THEN
      v_card := d.card_code;
    ELSIF v_card IS DISTINCT FROM d.card_code THEN
      RAISE EXCEPTION 'All lines must be for the same supplier: % is for %, not %.', v_no, d.card_code, v_card USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry AND line_num = v_line FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', n || format('%s %s has no line %s.', v_lb, v_no, v_line + 1) USING ERRCODE = 'P0001';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '%', n || 'quantity must be more than 0.' USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(sum(erp._num(x->>'qty')), 0) INTO v_sum FROM jsonb_array_elements(v_lines) x
     WHERE erp._num(x->>'base_doc_entry')::integer = v_entry AND erp._num(x->>'base_line')::integer = v_line;
    IF coalesce(bl.line_status, 'O') <> 'O' OR v_sum > coalesce(bl.open_qty, 0) THEN
      RAISE EXCEPTION '%', n || format('you are %sing %s of %s but only %s %s still open on %s %s.', p_verb, trim_scale(v_sum), bl.item_code,
        trim_scale(CASE WHEN coalesce(bl.line_status, 'O') = 'O' THEN coalesce(bl.open_qty, 0) ELSE 0 END),
        CASE WHEN coalesce(bl.open_qty, 0) = 1 THEN 'is' ELSE 'are' END, v_lb, v_no) USING ERRCODE = 'P0001';
    END IF;
    v_out := v_out || jsonb_build_object('n', i, 'base_doc_entry', v_entry, 'base_line', v_line, 'base_doc_no', v_no, 'qty', v_qty,
      'whs_code', nullif(btrim(l->>'whs_code'), ''), 'item_code', bl.item_code, 'description', bl.description, 'uom', bl.uom,
      'price', bl.price, 'tax_code', bl.tax_code, 'base_whs', bl.whs_code, 'base_qty', bl.quantity, 'cbm', bl.cbm,
      'card_code', d.card_code, 'card_name', d.card_name, 'branch_id', d.branch_id, 'customer_ref', d.customer_ref,
      'china_office', w.china_office, 'payment_terms', w.payment_terms);
  END LOOP;
  RETURN v_out;
END $$;

-- Insert the header + workflow row of a Super ERP goods receipt / A/P invoice. Internal.
CREATE OR REPLACE FUNCTION erp._pd_new_doc(p_company varchar, p_obj integer, p_user uuid, p_card text, p_card_name text, p_date date, p_due date,
                                           p_ref text, p_comments text, p_branch integer, p_whs text, p_office text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb;
BEGIN
  nb := erp._pd_number(p_company, p_obj);
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                            customer_ref, currency, fx_rate, total, vat_total, paid, branch_id, comments, created_on, source)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, (nb->>'num')::integer, erp._pd_kind(p_obj), 'open', p_date, coalesce(p_due, p_date), p_date,
          p_card, p_card_name, p_ref, (SELECT currency FROM erp.company WHERE company_code = p_company), 1, 0, 0, 0, p_branch, p_comments,
          current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code, china_office)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, nb->>'no', 'approved', p_user, p_user, now(), now(), p_whs, p_office);
  RETURN nb;
END $$;

-- Goods receipt PO: from approved, open Super ERP purchase order lines of one supplier. Stock comes in at the PO price
-- (average cost updated), the order lines close by quantity, containers in transit for those lines are marked received
-- (oldest ETA first), and Dr inventory / Cr goods received, not invoiced posts. Receiving more than is open is refused.
-- p_header: {doc_date, whs_code (all lines, optional), customer_ref (delivery note), comments}; p_lines: [{base_doc_entry, base_line, qty, whs_code?}]
CREATE OR REPLACE FUNCTION erp.purchase_grpo_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_date  date;
  v_hwhs  text := nullif(btrim(h->>'whs_code'), '');
  bl      jsonb;
  x       jsonb;
  s       record;
  v_whs   text;
  v_rate  numeric;
  v_lt    numeric;
  v_left  numeric;
  v_take  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_cur   text;
  i       integer := 0;
BEGIN
  u := erp._pd_guard(p_company, true, 'receive goods');
  v_date := erp._sd_doc_date(h);
  bl := erp._pd_base_lines(p_company, 22, p_lines, 'receiv');
  IF v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    v_whs := coalesce(x->>'whs_code', v_hwhs, x->>'base_whs');
    IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      RAISE EXCEPTION 'Line %: warehouse % does not exist or is inactive.', x->>'n', coalesce(v_whs, '(none)') USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  nb := erp._pd_new_doc(p_company, 20, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        nullif(btrim(h->>'customer_ref'), ''), nullif(btrim(h->>'comments'), ''), (bl->0->>'branch_id')::integer, v_hwhs,
                        bl->0->>'china_office');
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    v_whs := coalesce(x->>'whs_code', v_hwhs, x->>'base_whs');
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric, 2);
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, cbm,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 20, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, v_cur, 0, v_lt, x->>'tax_code', round(v_lt * coalesce(v_rate, 0) / 100, 2), v_whs, 'O',
            (x->>'price')::numeric, (x->>'price')::numeric,
            CASE WHEN (x->>'cbm') IS NOT NULL AND (x->>'base_qty')::numeric > 0
                 THEN round((x->>'cbm')::numeric * (x->>'qty')::numeric / (x->>'base_qty')::numeric, 6) END,
            22, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    PERFORM erp._stock_move(p_company, x->>'item_code', v_whs, (x->>'qty')::numeric, 0, (x->>'price')::numeric, 20, v_entry, i, v_date);
    -- Off order in the warehouse the order expected it.
    UPDATE erp.stock_balance SET on_order = greatest(on_order - (x->>'qty')::numeric, 0)
     WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'base_whs';
    -- Containers in transit for this order line: received, oldest ETA first.
    v_left := (x->>'qty')::numeric;
    FOR s IN SELECT sl.shipment_id, sl.po_line, sl.qty - sl.received_qty AS open_q
               FROM erp.purchase_shipment ps JOIN erp.purchase_shipment_line sl ON sl.shipment_id = ps.shipment_id
              WHERE ps.company_code = p_company AND ps.po_doc_entry = (x->>'base_doc_entry')::integer AND sl.po_line = (x->>'base_line')::integer
                AND ps.status = 'in_transit' AND sl.qty > sl.received_qty
              ORDER BY ps.eta, ps.shipment_id FOR UPDATE OF sl LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_left, s.open_q);
      UPDATE erp.purchase_shipment_line SET received_qty = received_qty + v_take WHERE shipment_id = s.shipment_id AND po_line = s.po_line;
      v_left := v_left - v_take;
    END LOOP;
    i := i + 1;
  END LOOP;
  UPDATE erp.purchase_shipment ps SET status = 'arrived', updated_at = now()
   WHERE ps.company_code = p_company AND ps.status = 'in_transit'
     AND ps.po_doc_entry IN (SELECT (y->>'base_doc_entry')::integer FROM jsonb_array_elements(bl) y)
     AND NOT EXISTS (SELECT 1 FROM erp.purchase_shipment_line sl WHERE sl.shipment_id = ps.shipment_id AND sl.received_qty < sl.qty);
  v_total := erp._sd_retotal(p_company, 20, v_entry);
  PERFORM erp._sd_consume(p_company, 22, bl);
  v_trans := erp.post_document(p_company, 20, v_entry);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'grpo_create', 'grpo', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(bl),
                             'orders', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);
END $$;

-- A/P invoice: from open Super ERP goods receipt lines of one supplier, at the received price. Clears goods received, not
-- invoiced, books input VAT and the payable, and draws paid down payments (header.down_payments). The invoice total is the
-- amount still due (gross − drawn), paid = 0: A5's outgoing payment pays it.
-- p_header: {doc_date, due_date?, customer_ref (supplier invoice no.), comments, down_payments:[{doc_entry, amount}]}
-- p_lines:  [{base_doc_entry, base_line, qty}]
CREATE OR REPLACE FUNCTION erp.purchase_invoice_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_dps   jsonb := CASE WHEN jsonb_typeof(h->'down_payments') = 'array' THEN h->'down_payments' ELSE '[]'::jsonb END;
  bl      jsonb;
  x       jsonb;
  bp      erp.business_partner;
  dp      erp.document;
  v_date  date;
  v_due   date;
  v_card  text;
  v_cur   text;
  v_rate  numeric;
  v_lt    numeric;
  v_net   numeric := 0;
  v_vat   numeric := 0;
  v_gross numeric;
  v_amt   numeric;
  v_avail numeric;
  v_drawn numeric := 0;
  v_draws jsonb := '[]';
  v_seen  integer[] := '{}';
  v_dpno  text;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  i       integer := 0;
BEGIN
  u := erp._pd_guard(p_company, true, 'post A/P invoices', true);
  v_date := erp._sd_doc_date(h);
  bl := erp._pd_base_lines(p_company, 20, p_lines, 'invoic');
  v_card := bl->0->>'card_code';
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
  IF bp.card_code IS NULL THEN
    RAISE EXCEPTION 'Supplier % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
    RAISE EXCEPTION 'Supplier % is billed in %. Purchasing in a foreign currency comes in a later stage.', v_card, bp.currency USING ERRCODE = 'P0001';
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
      FROM erp.payment_terms pt WHERE pt.company_code = p_company AND pt.group_num = coalesce((bl->0->>'payment_terms')::integer, bp.payment_terms);
    v_due := coalesce(v_due, v_date);
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric, 2);
    v_net := v_net + v_lt;
    v_vat := v_vat + round(v_lt * coalesce(v_rate, 0) / 100, 2);
  END LOOP;
  v_gross := v_net + v_vat;

  -- Down payments drawn: Super ERP 204 of this supplier, paid, not yet drawn.
  FOR x IN SELECT value FROM jsonb_array_elements(v_dps) LOOP
    IF erp._num(x->>'doc_entry') IS NULL AND erp._num(x->>'amount') IS NULL THEN CONTINUE; END IF;
    SELECT * INTO dp FROM erp.document WHERE company_code = p_company AND obj_type = 204 AND doc_entry = erp._num(x->>'doc_entry')::integer FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Down payment invoice % was not found in company %.', coalesce(x->>'doc_entry', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    v_dpno := erp._sd_no(p_company, 204, dp.doc_entry);
    IF dp.source <> 'erp' THEN
      RAISE EXCEPTION 'Down payment invoice % came from %, so it can''t be drawn in Super ERP.', v_dpno,
        CASE dp.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    ELSIF dp.card_code IS DISTINCT FROM v_card THEN
      RAISE EXCEPTION 'Down payment invoice % belongs to %, not %.', v_dpno, dp.card_code, v_card USING ERRCODE = 'P0001';
    ELSIF dp.status = 'cancelled' THEN
      RAISE EXCEPTION 'Down payment invoice % is cancelled.', v_dpno USING ERRCODE = 'P0001';
    ELSIF dp.doc_entry = ANY (v_seen) THEN
      RAISE EXCEPTION 'Down payment invoice % is listed twice.', v_dpno USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || dp.doc_entry;
    v_amt := round(erp._num(x->>'amount'), 2);
    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'Enter the amount to draw from down payment invoice %.', v_dpno USING ERRCODE = 'P0001';
    END IF;
    v_avail := round(coalesce(dp.paid, 0) - coalesce((SELECT sum(amount) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2);
    IF coalesce(dp.paid, 0) <= 0 THEN
      RAISE EXCEPTION 'Down payment invoice % is not paid yet. Pay it first in Banking › Outgoing Payments, then draw it.', v_dpno USING ERRCODE = 'P0001';
    ELSIF v_amt > v_avail THEN
      RAISE EXCEPTION '%', format('You are drawing %s %s from down payment invoice %s, but only %s %s of it is paid and not drawn yet.',
        erp._money(v_amt), v_cur, v_dpno, erp._money(greatest(v_avail, 0)), v_cur) USING ERRCODE = 'P0001';
    END IF;
    v_drawn := v_drawn + v_amt;
    v_draws := v_draws || jsonb_build_object('dp_entry', dp.doc_entry, 'doc_no', v_dpno, 'amount', v_amt);
  END LOOP;
  IF v_drawn > v_gross THEN
    RAISE EXCEPTION '%', format('Down payments drawn (%s %s) are more than the invoice total of %s %s.', erp._money(v_drawn), v_cur, erp._money(v_gross), v_cur)
      USING ERRCODE = 'P0001';
  END IF;

  nb := erp._pd_new_doc(p_company, 18, u.user_id, v_card, bp.name, v_date, v_due,
                        nullif(btrim(h->>'customer_ref'), ''), nullif(btrim(h->>'comments'), ''), (bl->0->>'branch_id')::integer, NULL,
                        bl->0->>'china_office');
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric, 2);
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, cbm,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 18, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, v_cur, 0, v_lt, x->>'tax_code', round(v_lt * coalesce(v_rate, 0) / 100, 2), x->>'base_whs', 'O',
            (x->>'price')::numeric, (x->>'price')::numeric, NULL, 20, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    i := i + 1;
  END LOOP;
  INSERT INTO erp.ap_dp_draw (company_code, invoice_entry, dp_entry, amount)
  SELECT p_company, v_entry, (y->>'dp_entry')::integer, (y->>'amount')::numeric FROM jsonb_array_elements(v_draws) y;
  PERFORM erp._sd_retotal(p_company, 18, v_entry);
  UPDATE erp.document SET total = round(total - v_drawn, 2)
   WHERE company_code = p_company AND obj_type = 18 AND doc_entry = v_entry AND source = 'erp'
  RETURNING total INTO v_total;
  -- Down payment invoices fully drawn are closed.
  UPDATE erp.document dd SET status = 'closed'
   WHERE dd.company_code = p_company AND dd.obj_type = 204 AND dd.source = 'erp' AND dd.status = 'open'
     AND dd.doc_entry = ANY (v_seen)
     AND (SELECT coalesce(sum(amount), 0) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dd.doc_entry) >= dd.total;
  PERFORM erp._sd_consume(p_company, 20, bl);
  v_trans := erp.post_document(p_company, 18, v_entry);
  PERFORM erp._bp_balance_add(p_company, v_card, -v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ap_invoice_create', 'ap_invoice', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', v_card, 'gross', v_gross, 'drawn', v_drawn, 'total', v_total,
                             'lines', jsonb_array_length(bl), 'down_payments', v_draws,
                             'receipts', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'gross', v_gross, 'drawn', v_drawn, 'total', v_total,
                            'trans_id', v_trans, 'due_date', v_due);
END $$;

-- ============ Landed costs (SAP object 69) ============
-- Split landed costs over goods receipt lines. Never writes; raises the first problem. Each charge is split by its code's
-- method (cbm, qty, value, weight) in proportion; amounts are rounded to 2 decimals and the rounding remainder goes on the
-- last line that takes part, so every charge adds up exactly. For each line, the share of the quantity still on hand goes to
-- inventory (and raises average cost); the share already sold goes to cost of goods sold.
-- p_header: {doc_date, card_code (broker, optional), reference, comments}
-- p_lines:  [{grpo_entry, grpo_line, weight?, cbm?}]; p_charges: [{code, amount}]
CREATE OR REPLACE FUNCTION erp._lc_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_chg    jsonb := CASE WHEN jsonb_typeof(p_charges) = 'array' THEN p_charges ELSE '[]'::jsonb END;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  v_date   date;
  v_cur    text;
  x        jsonb;
  ln       jsonb;
  d        erp.document;
  gl       erp.document_line;
  lc       erp.landed_cost_code;
  v_out    jsonb := '[]';
  v_charges jsonb := '[]';
  v_allocs jsonb := '[]';
  v_seen   text[] := '{}';
  v_codes  text[] := '{}';
  v_no     text;
  v_w      numeric;
  v_cbm    numeric;
  i        integer := 0;
  k        integer := 0;
  v_amt    numeric;
  v_sum    numeric;
  v_last   integer;
  v_acc    numeric;
  v_a      numeric;
  v_b      numeric;
  v_alloc  numeric[];
  v_total  numeric := 0;
  v_key    text;
  v_pool   jsonb := '{}';
  v_avgm   jsonb := '{}';
  v_oh     numeric;
  v_avg    numeric;
  v_share  numeric;
  v_inv    numeric;
  v_after  numeric;
  v_ti     numeric := 0;
  v_tc     numeric := 0;
  v_res    jsonb := '[]';
  j        integer;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  v_date := erp._sd_doc_date(h);
  IF v_card IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card AND kind = 'supplier') THEN
    RAISE EXCEPTION 'Supplier % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one goods receipt line.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_chg) = 0 THEN
    RAISE EXCEPTION 'Add at least one landed cost.' USING ERRCODE = 'P0001';
  END IF;

  -- Lines
  FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 20 AND doc_entry = erp._num(x->>'grpo_entry')::integer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Line %: goods receipt % was not found in company %.', i, coalesce(x->>'grpo_entry', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    v_no := erp._sd_no(p_company, 20, d.doc_entry);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION 'Line %: goods receipt % came from %. Landed costs work on Super ERP goods receipts only.', i, v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    ELSIF d.status = 'cancelled' THEN
      RAISE EXCEPTION 'Line %: goods receipt % is cancelled.', i, v_no USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO gl FROM erp.document_line WHERE company_code = p_company AND obj_type = 20 AND doc_entry = d.doc_entry
                                                AND line_num = erp._num(x->>'grpo_line')::integer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Line %: goods receipt % has no line %.', i, v_no, coalesce((erp._num(x->>'grpo_line') + 1)::text, '(none)') USING ERRCODE = 'P0001';
    END IF;
    IF (d.doc_entry || ':' || gl.line_num) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Line %: line % of goods receipt % is listed twice.', i, gl.line_num + 1, v_no USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || (d.doc_entry || ':' || gl.line_num);
    v_w := NULL;
    IF nullif(btrim(x->>'weight'), '') IS NOT NULL THEN
      v_w := erp._num(x->>'weight');
      IF v_w IS NULL OR v_w < 0 THEN
        RAISE EXCEPTION 'Line %: weight must be a number of 0 or more.', i USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_cbm := gl.cbm;
    IF nullif(btrim(x->>'cbm'), '') IS NOT NULL THEN
      v_cbm := erp._num(x->>'cbm');
      IF v_cbm IS NULL OR v_cbm < 0 THEN
        RAISE EXCEPTION 'Line %: volume (CBM) must be a number of 0 or more.', i USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_out := v_out || jsonb_build_object('line_num', i - 1, 'grpo_entry', d.doc_entry, 'grpo_line', gl.line_num, 'grpo_no', v_no,
      'item_code', gl.item_code, 'description', gl.description, 'whs_code', gl.whs_code, 'qty', gl.quantity,
      'value', round(gl.quantity * gl.price, 2), 'cbm', v_cbm, 'weight', v_w, 'price', gl.price);
  END LOOP;

  -- Charges: split each one exactly.
  FOR x IN SELECT value FROM jsonb_array_elements(v_chg) LOOP
    k := k + 1;
    SELECT * INTO lc FROM erp.landed_cost_code WHERE company_code = p_company AND code = nullif(btrim(x->>'code'), '');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Landed cost %: code % is not set up for %. Ask Purchasing to add it in Purchasing › Purchasing Setup.',
        k, coalesce(nullif(btrim(x->>'code'), ''), '(none)'), p_company USING ERRCODE = 'P0001';
    ELSIF NOT lc.active THEN
      RAISE EXCEPTION 'Landed cost %: code % is inactive.', k, lc.code USING ERRCODE = 'P0001';
    ELSIF lc.code = ANY (v_codes) THEN
      RAISE EXCEPTION 'Landed cost %: code % is listed twice. Add the amounts together.', k, lc.code USING ERRCODE = 'P0001';
    END IF;
    v_codes := v_codes || lc.code::text;
    v_amt := erp._num(x->>'amount');
    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'Landed cost % (%): enter an amount above 0.', k, lc.name USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(v_amt, 2);
    v_sum := 0;
    v_last := NULL;
    FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
      ln := v_out->j;
      v_b := coalesce(CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric ELSE (ln->>'weight')::numeric END, 0);
      v_sum := v_sum + v_b;
      IF v_b > 0 THEN v_last := j; END IF;
    END LOOP;
    IF v_sum <= 0 THEN
      RAISE EXCEPTION 'Landed cost % (%) is split by %, but none of the lines has %. Enter it on the lines.', k, lc.name,
        CASE lc.split_method WHEN 'cbm' THEN 'volume (CBM)' WHEN 'qty' THEN 'quantity' WHEN 'value' THEN 'value' ELSE 'weight' END,
        CASE lc.split_method WHEN 'cbm' THEN 'a volume' WHEN 'qty' THEN 'a quantity' WHEN 'value' THEN 'a value' ELSE 'a weight' END USING ERRCODE = 'P0001';
    END IF;
    v_acc := 0;
    FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
      ln := v_out->j;
      v_b := coalesce(CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric ELSE (ln->>'weight')::numeric END, 0);
      IF j = v_last THEN
        v_a := v_amt - v_acc;                      -- the rounding remainder
      ELSE
        v_a := round(v_amt * v_b / v_sum, 2);
      END IF;
      v_acc := v_acc + v_a;
      v_allocs := v_allocs || jsonb_build_object('charge_no', k - 1, 'line_num', j, 'basis', v_b, 'amount', v_a);
    END LOOP;
    v_charges := v_charges || jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt);
    v_total := v_total + v_amt;
  END LOOP;

  -- Per line: allocated, the on-hand share to inventory (average cost), the rest to cost of goods sold.
  FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
    ln := v_out->j;
    SELECT coalesce(sum((a->>'amount')::numeric), 0) INTO v_a FROM jsonb_array_elements(v_allocs) a WHERE (a->>'line_num')::integer = j;
    v_key := (ln->>'item_code') || '|' || (ln->>'whs_code');
    SELECT sb.on_hand, sb.avg_cost INTO v_oh, v_avg FROM erp.stock_balance sb
     WHERE sb.company_code = p_company AND sb.item_code = ln->>'item_code' AND sb.whs_code = ln->>'whs_code';
    v_oh := greatest(coalesce(v_oh, 0), 0);
    IF NOT (v_pool ? v_key) THEN
      v_pool := v_pool || jsonb_build_object(v_key, v_oh);
      v_avgm := v_avgm || jsonb_build_object(v_key, coalesce(v_avg, (ln->>'price')::numeric));
    END IF;
    v_share := least((v_pool->>v_key)::numeric, (ln->>'qty')::numeric);
    v_pool := v_pool || jsonb_build_object(v_key, (v_pool->>v_key)::numeric - v_share);
    v_inv := CASE WHEN v_share >= (ln->>'qty')::numeric THEN v_a ELSE round(v_a * v_share / (ln->>'qty')::numeric, 2) END;
    v_avg := (v_avgm->>v_key)::numeric;
    v_after := CASE WHEN v_oh > 0 THEN round((v_oh * v_avg + v_inv) / v_oh, 6) ELSE v_avg END;
    v_avgm := v_avgm || jsonb_build_object(v_key, v_after);
    v_ti := v_ti + v_inv;
    v_tc := v_tc + (v_a - v_inv);
    v_res := v_res || (ln || jsonb_build_object('allocated', v_a, 'to_inventory', v_inv, 'to_cogs', v_a - v_inv, 'on_hand', v_oh,
                                                'avg_before', v_avg, 'avg_after', v_after));
  END LOOP;

  RETURN jsonb_build_object('header', jsonb_build_object('doc_date', v_date, 'card_code', v_card, 'reference', nullif(btrim(h->>'reference'), ''),
                                                         'comments', nullif(btrim(h->>'comments'), '')),
                            'lines', v_res, 'charges', v_charges, 'allocs', v_allocs,
                            'totals', jsonb_build_object('total', v_total, 'to_inventory', v_ti, 'to_cogs', v_tc, 'currency', v_cur));
END $$;

-- Preview the split while typing. Writes nothing.
CREATE OR REPLACE FUNCTION erp.landed_cost_preview(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._pd_guard(p_company, false);
  RETURN erp._lc_eval(p_company, p_header, p_lines, p_charges);
END $$;

-- Post landed costs: the split as previewed, average cost raised, Dr inventory (+ Dr COGS for goods already sold) /
-- Cr landed cost clearing (the forwarder's / broker's A/P invoice clears it later).
CREATE OR REPLACE FUNCTION erp.landed_cost_create(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  e       jsonb;
  nb      jsonb;
  v_entry integer;
  v_lines jsonb := '[]';
  v_trans integer;
  v_inv   text;
  v_cogs  text;
  v_clr   text;
  v_ti    numeric;
  v_tc    numeric;
  v_tot   numeric;
  x       jsonb;
BEGIN
  u := erp._pd_guard(p_company, true, 'post landed costs', true);
  -- Lock the stock rows the split reads, then split.
  PERFORM 1 FROM erp.stock_balance sb
    JOIN erp.document_line gl ON gl.company_code = sb.company_code AND gl.item_code = sb.item_code AND gl.whs_code = sb.whs_code AND gl.obj_type = 20
   WHERE sb.company_code = p_company
     AND (gl.doc_entry, gl.line_num) IN (SELECT erp._num(y->>'grpo_entry')::integer, erp._num(y->>'grpo_line')::integer
                                           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) y)
   FOR UPDATE OF sb;
  e := erp._lc_eval(p_company, p_header, p_lines, p_charges);
  v_ti := (e->'totals'->>'to_inventory')::numeric;
  v_tc := (e->'totals'->>'to_cogs')::numeric;
  v_tot := (e->'totals'->>'total')::numeric;
  v_inv := erp.gl_account(p_company, 'inventory', 'inventory');
  v_clr := erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing');
  IF v_tc > 0 THEN
    v_cogs := erp.gl_account(p_company, 'inventory', 'cogs');
  END IF;

  nb := erp._pd_number(p_company, 69);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.landed_cost (company_code, doc_entry, doc_no, doc_date, card_code, reference, comments, total, to_inventory, to_cogs, currency, created_by)
  VALUES (p_company, v_entry, nb->>'no', (e->'header'->>'doc_date')::date, e->'header'->>'card_code', e->'header'->>'reference',
          e->'header'->>'comments', v_tot, v_ti, v_tc, e->'totals'->>'currency', u.user_id);
  INSERT INTO erp.landed_cost_line (company_code, doc_entry, line_num, grpo_entry, grpo_line, item_code, whs_code, qty, value, cbm, weight,
                                    allocated, to_inventory, to_cogs, on_hand, avg_before, avg_after)
  SELECT p_company, v_entry, y.line_num, y.grpo_entry, y.grpo_line, y.item_code, y.whs_code, y.qty, y.value, y.cbm, y.weight,
         y.allocated, y.to_inventory, y.to_cogs, y.on_hand, y.avg_before, y.avg_after
    FROM jsonb_to_recordset(e->'lines') AS y(line_num int, grpo_entry int, grpo_line int, item_code text, whs_code text, qty numeric, value numeric,
                                             cbm numeric, weight numeric, allocated numeric, to_inventory numeric, to_cogs numeric, on_hand numeric,
                                             avg_before numeric, avg_after numeric);
  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric);
  INSERT INTO erp.landed_cost_alloc (company_code, doc_entry, charge_no, line_num, basis, amount)
  SELECT p_company, v_entry, y.charge_no, y.line_num, y.basis, y.amount
    FROM jsonb_to_recordset(e->'allocs') AS y(charge_no int, line_num int, basis numeric, amount numeric);

  -- Average cost: lines are chained per item and warehouse, so the last line of each carries the final value.
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') ORDER BY (value->>'line_num')::integer LOOP
    IF (x->>'to_inventory')::numeric > 0 THEN
      UPDATE erp.stock_balance SET avg_cost = (x->>'avg_after')::numeric
       WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'whs_code';
    END IF;
  END LOOP;

  IF v_ti > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_inv, 'debit', v_ti, 'memo', 'Landed costs on stock');
  END IF;
  IF v_tc > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_cogs, 'debit', v_tc, 'memo', 'Landed costs on goods already sold');
  END IF;
  v_lines := v_lines || jsonb_build_object('acct_code', v_clr, 'credit', v_tot);
  v_trans := erp.post_journal(p_company, (e->'header'->>'doc_date')::date, format('Landed costs %s', nb->>'no'), v_lines,
    jsonb_build_object('trans_type', 69, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'ref2', e->'header'->>'reference', 'allow_control', true,
                       'action', 'document_post', 'object', 'landed_cost', 'object_ref', v_entry::text));
  UPDATE erp.landed_cost SET trans_id = v_trans WHERE company_code = p_company AND doc_entry = v_entry;
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 69, v_entry, v_trans);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'landed_cost_create', 'landed_cost', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'lines', jsonb_array_length(e->'lines'),
                             'charges', e->'charges', 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'trans_id', v_trans);
END $$;

-- Landed cost page: header, lines with their split, charges, the journal and the activity.
CREATE OR REPLACE FUNCTION erp.landed_cost_info(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  lc erp.landed_cost;
BEGIN
  u := erp._pd_guard(p_company, false);
  SELECT * INTO lc FROM erp.landed_cost WHERE company_code = p_company AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'doc_entry', lc.doc_entry, 'doc_no', lc.doc_no, 'doc_date', lc.doc_date, 'card_code', lc.card_code,
    'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = lc.card_code),
    'reference', lc.reference, 'comments', lc.comments, 'total', lc.total, 'to_inventory', lc.to_inventory, 'to_cogs', lc.to_cogs,
    'currency', lc.currency, 'trans_id', lc.trans_id, 'can_read_journal', erp.can_read('finance'),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = lc.created_by), 'created_at', lc.created_at,
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'grpo_entry', l.grpo_entry, 'grpo_line', l.grpo_line,
                                         'grpo_no', erp._sd_no(p_company, 20, l.grpo_entry), 'item_code', l.item_code,
                                         'description', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = l.item_code),
                                         'whs_code', l.whs_code, 'qty', l.qty, 'value', l.value, 'cbm', l.cbm, 'weight', l.weight,
                                         'allocated', l.allocated, 'to_inventory', l.to_inventory, 'to_cogs', l.to_cogs, 'on_hand', l.on_hand,
                                         'avg_before', l.avg_before, 'avg_after', l.avg_after,
                                         'allocs', (SELECT jsonb_object_agg(a.charge_no::text, a.amount) FROM erp.landed_cost_alloc a
                                                     WHERE a.company_code = l.company_code AND a.doc_entry = l.doc_entry AND a.line_num = l.line_num))
                                       ORDER BY l.line_num)
                         FROM erp.landed_cost_line l WHERE l.company_code = p_company AND l.doc_entry = p_doc_entry), '[]'::jsonb),
    'charges', coalesce((SELECT jsonb_agg(jsonb_build_object('charge_no', c.charge_no, 'code', c.code, 'name', c.name, 'split_method', c.split_method,
                                           'amount', c.amount) ORDER BY c.charge_no)
                           FROM erp.landed_cost_charge c WHERE c.company_code = p_company AND c.doc_entry = p_doc_entry), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor)) ORDER BY l.at, l.audit_id)
                            FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                           WHERE l.company_code = p_company AND l.object = 'landed_cost' AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;

-- ============ API: document flow, view info, setup ============
-- Every purchasing document linked to this one through base links (both directions), plus the order's proforma invoices,
-- QC inspections, shipments, the outgoing payments on its down payments / invoices, and the landed costs on its receipts.
CREATE OR REPLACE FUNCTION erp.purchase_doc_flow(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  v_set text[];
  v_new text[];
  v_add text[];
  v_pos integer[];
  v_grs integer[];
  k     integer := 0;
BEGIN
  u := erp._pd_guard(p_company, false);
  IF p_obj = 69 THEN
    -- A landed cost: start from its goods receipts.
    SELECT array_agg(DISTINCT '20:' || grpo_entry) INTO v_set FROM erp.landed_cost_line WHERE company_code = p_company AND doc_entry = p_doc_entry;
    v_set := coalesce(v_set, '{}');
  ELSIF EXISTS (SELECT 1 FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry) THEN
    v_set := ARRAY[p_obj || ':' || p_doc_entry];
  ELSE
    RETURN jsonb_build_object('docs', '[]'::jsonb);
  END IF;
  v_new := v_set;
  WHILE coalesce(array_length(v_new, 1), 0) > 0 AND k < 10 LOOP
    k := k + 1;
    SELECT array_agg(DISTINCT x) INTO v_add FROM (
      SELECT l.base_obj_type || ':' || l.base_doc_entry AS x
        FROM erp.document_line l
       WHERE l.company_code = p_company AND (l.obj_type || ':' || l.doc_entry) = ANY (v_new)
         AND l.base_obj_type IN (1470000113, 540000006, 22, 20, 204, 18, 19) AND l.base_doc_entry IS NOT NULL
      UNION
      SELECT l.obj_type || ':' || l.doc_entry
        FROM erp.document_line l
        JOIN unnest(v_new) AS s(key) ON split_part(s.key, ':', 1)::integer = l.base_obj_type AND split_part(s.key, ':', 2)::integer = l.base_doc_entry
       WHERE l.company_code = p_company AND l.obj_type IN (1470000113, 540000006, 22, 20, 204, 18, 19)) q
     WHERE NOT (x = ANY (v_set));
    v_new := coalesce(v_add, '{}');
    v_set := v_set || v_new;
  END LOOP;
  SELECT array_agg(split_part(s, ':', 2)::integer) FILTER (WHERE split_part(s, ':', 1) = '22'),
         array_agg(split_part(s, ':', 2)::integer) FILTER (WHERE split_part(s, ':', 1) = '20')
    INTO v_pos, v_grs FROM unnest(v_set) s;
  RETURN jsonb_build_object(
    'docs', coalesce((
      SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'doc_entry', d.doc_entry, 'doc_no', coalesce(w.doc_no, d.doc_num::text),
               'doc_date', d.doc_date, 'status', d.status, 'state', w.state, 'total', d.total, 'paid', d.paid, 'currency', d.currency,
               'source', d.source, 'card_name', d.card_name, 'trans_id', dp.trans_id, 'current', d.obj_type = p_obj AND d.doc_entry = p_doc_entry)
             ORDER BY array_position(ARRAY[1470000113, 540000006, 22, 204, 20, 18, 19], d.obj_type), d.doc_date, d.doc_entry)
        FROM erp.document d
        LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
        LEFT JOIN erp.document_posting dp ON dp.company_code = d.company_code AND dp.obj_type = d.obj_type AND dp.doc_entry = d.doc_entry
       WHERE d.company_code = p_company AND (d.obj_type || ':' || d.doc_entry) = ANY (v_set)), '[]'::jsonb),
    'pis', coalesce((SELECT jsonb_agg(jsonb_build_object('pi_id', pi_id, 'vendor_pi_no', vendor_pi_no, 'status', status, 'po_doc_entry', po_doc_entry) ORDER BY pi_id)
                       FROM erp.purchase_pi WHERE company_code = p_company AND po_doc_entry = ANY (coalesce(v_pos, '{}'))), '[]'::jsonb),
    'qcs', coalesce((SELECT jsonb_agg(jsonb_build_object('qc_id', qc_id, 'result', result, 'inspected_on', inspected_on, 'po_doc_entry', po_doc_entry) ORDER BY qc_id)
                       FROM erp.qc_inspection WHERE company_code = p_company AND po_doc_entry = ANY (coalesce(v_pos, '{}'))), '[]'::jsonb),
    'shipments', coalesce((SELECT jsonb_agg(jsonb_build_object('shipment_id', shipment_id, 'container_no', container_no, 'eta', eta, 'status', status,
                                                               'po_doc_entry', po_doc_entry) ORDER BY shipment_id)
                             FROM erp.purchase_shipment WHERE company_code = p_company AND po_doc_entry = ANY (coalesce(v_pos, '{}'))), '[]'::jsonb),
    'payments', coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_object('doc_entry', p.doc_entry, 'doc_no', coalesce(x.doc_no, p.doc_num::text),
                                                                       'doc_date', p.doc_date, 'total', p.total, 'cancelled', p.cancelled))
                            FROM erp.payment_allocation a
                            JOIN erp.payment p ON p.company_code = a.company_code AND p.direction = a.direction AND p.doc_entry = a.doc_entry
                            LEFT JOIN erp.payment_extra x ON x.company_code = p.company_code AND x.direction = p.direction AND x.doc_entry = p.doc_entry
                           WHERE a.company_code = p_company AND a.direction = 'O' AND a.target_obj_type IN (204, 18)
                             AND (a.target_obj_type || ':' || a.target_doc_entry) = ANY (v_set)), '[]'::jsonb),
    'landed_costs', coalesce((SELECT jsonb_agg(jsonb_build_object('doc_entry', lc.doc_entry, 'doc_no', lc.doc_no, 'doc_date', lc.doc_date, 'total', lc.total,
                                                                  'current', p_obj = 69 AND lc.doc_entry = p_doc_entry) ORDER BY lc.doc_entry)
                                FROM erp.landed_cost lc
                               WHERE lc.company_code = p_company
                                 AND (EXISTS (SELECT 1 FROM erp.landed_cost_line l WHERE l.company_code = lc.company_code AND l.doc_entry = lc.doc_entry
                                                AND l.grpo_entry = ANY (coalesce(v_grs, '{}')))
                                      OR (p_obj = 69 AND lc.doc_entry = p_doc_entry))), '[]'::jsonb));
END $$;

-- Goods receipt / A/P down payment invoice / A/P invoice page: number, who made it, the journal, what can be copied on,
-- down payments drawn, what is still open to pay, landed costs on a receipt, activity.
CREATE OR REPLACE FUNCTION erp.purchase_view(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  d      erp.document;
  w      erp.doc_workflow;
  v_open boolean;
  v_wr   boolean;
  v_obj  text := erp._pd_object(p_obj);
BEGIN
  u := erp._pd_guard(p_company, false);
  IF p_obj IS NULL OR p_obj NOT IN (20, 204, 18) THEN
    RAISE EXCEPTION 'This page shows goods receipts, A/P down payment invoices and A/P invoices only.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  v_open := EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry
                       AND coalesce(line_status, 'O') = 'O' AND open_qty > 0);
  v_wr := erp.can_write('purchase') OR erp.can_write('finance');
  RETURN jsonb_build_object(
    'workflow', w.doc_entry IS NOT NULL,
    'source', d.source,
    'doc_no', coalesce(w.doc_no, d.doc_num::text),
    'status', d.status,
    'china_office', w.china_office,
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'trans_id', (SELECT trans_id FROM erp.document_posting WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry),
    'can_read_journal', erp.can_read('finance'),
    'can_copy', d.source = 'erp' AND p_obj = 20 AND d.status = 'open' AND v_open AND v_wr,
    'can_landed_cost', d.source = 'erp' AND p_obj = 20 AND d.status <> 'cancelled' AND v_wr,
    'copy_block', CASE WHEN d.source <> 'erp' THEN 'source' WHEN d.status <> 'open' OR NOT v_open THEN 'closed' WHEN NOT v_wr THEN 'read_only' END,
    'gross', CASE WHEN p_obj = 18 THEN (SELECT coalesce(sum(line_total + coalesce(vat, 0)), 0) FROM erp.document_line
                                          WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry) END,
    'open_amount', CASE WHEN p_obj IN (18, 204) AND d.source = 'erp' THEN erp._bk_doc_open(p_company, p_obj, p_doc_entry) END,
    'draws', CASE WHEN p_obj = 18 THEN coalesce((SELECT jsonb_agg(jsonb_build_object('dp_entry', x.dp_entry, 'doc_no', erp._sd_no(p_company, 204, x.dp_entry),
                                                                                      'amount', x.amount) ORDER BY x.dp_entry)
                                                   FROM erp.ap_dp_draw x WHERE x.company_code = p_company AND x.invoice_entry = p_doc_entry), '[]'::jsonb) END,
    'drawn_by', CASE WHEN p_obj = 204 THEN coalesce((SELECT jsonb_agg(jsonb_build_object('invoice_entry', x.invoice_entry, 'doc_no', erp._sd_no(p_company, 18, x.invoice_entry),
                                                                                          'amount', x.amount) ORDER BY x.invoice_entry)
                                                       FROM erp.ap_dp_draw x WHERE x.company_code = p_company AND x.dp_entry = p_doc_entry), '[]'::jsonb) END,
    'po_doc_entry', CASE WHEN p_obj = 204 THEN (SELECT base_doc_entry FROM erp.document_line WHERE company_code = p_company AND obj_type = 204
                                                  AND doc_entry = p_doc_entry AND base_obj_type = 22 LIMIT 1) END,
    'landed_costs', CASE WHEN p_obj = 20 THEN coalesce((SELECT jsonb_agg(jsonb_build_object('doc_entry', lc.doc_entry, 'doc_no', lc.doc_no, 'total', lc.total) ORDER BY lc.doc_entry)
                                                         FROM erp.landed_cost lc WHERE lc.company_code = p_company
                                                          AND EXISTS (SELECT 1 FROM erp.landed_cost_line l WHERE l.company_code = lc.company_code
                                                                         AND l.doc_entry = lc.doc_entry AND l.grpo_entry = p_doc_entry)), '[]'::jsonb) END,
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                                           ORDER BY l.at, l.audit_id)
                            FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                           WHERE l.company_code = p_company AND l.object = v_obj AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;

-- Purchasing › Purchasing Setup: default tax code and warehouse, and whether shipping needs a passed QC (Purchasing, full access).
-- p_setting: {default_tax_code, default_whs_code, require_qc_pass}
CREATE OR REPLACE FUNCTION erp.purchase_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  s     jsonb := coalesce(p_setting, '{}'::jsonb);
  v_tax text := nullif(btrim(s->>'default_tax_code'), '');
  v_whs text := nullif(btrim(s->>'default_whs_code'), '');
  v_qc  boolean := coalesce((s->>'require_qc_pass')::boolean, false);
  old   erp.purchase_setting;
BEGIN
  u := erp._pd_guard(p_company, true, 'change the purchasing setup');
  IF v_tax IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.tax_code WHERE company_code = p_company AND code = v_tax AND active AND coalesce(category, 'I') <> 'O') THEN
    RAISE EXCEPTION 'Tax code % is not an active purchase tax code in %.', v_tax, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_whs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in %.', v_whs, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.purchase_setting WHERE company_code = p_company;
  INSERT INTO erp.purchase_setting (company_code, default_tax_code, default_whs_code, require_qc_pass, updated_by, updated_at)
  VALUES (p_company, v_tax, v_whs, v_qc, u.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET default_tax_code = EXCLUDED.default_tax_code, default_whs_code = EXCLUDED.default_whs_code,
                                           require_qc_pass = EXCLUDED.require_qc_pass, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'purchase_setting_set', 'purchase_setting', p_company,
          jsonb_build_object('from', to_jsonb(old) - 'updated_by' - 'updated_at', 'to', jsonb_build_object('default_tax_code', v_tax, 'default_whs_code', v_whs,
                                                                                                          'require_qc_pass', v_qc)));
  RETURN jsonb_build_object('default_tax_code', v_tax, 'default_whs_code', v_whs, 'require_qc_pass', v_qc);
END $$;

-- Add or change one entry of a purchasing list (Purchasing, full access): p_kind 'china_office' | 'pi_status' | 'qc_check'.
-- p_item: {code, name, sort, active}. Entries are never deleted, only made inactive.
CREATE OR REPLACE FUNCTION erp.purchase_list_save(p_company varchar, p_kind text, p_item jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  i      jsonb := coalesce(p_item, '{}'::jsonb);
  v_code text := nullif(btrim(i->>'code'), '');
  v_name text := nullif(btrim(i->>'name'), '');
  v_sort smallint := coalesce(erp._num(i->>'sort')::smallint, 0);
  v_act  boolean := coalesce((i->>'active')::boolean, true);
  v_tbl  text;
BEGIN
  u := erp._pd_guard(p_company, true, 'change the purchasing setup');
  v_tbl := CASE p_kind WHEN 'china_office' THEN 'china_office' WHEN 'pi_status' THEN 'pi_status' WHEN 'qc_check' THEN 'qc_checklist_item' END;
  IF v_tbl IS NULL THEN
    RAISE EXCEPTION 'Choose which list to change: China offices, PI statuses or the QC checklist.' USING ERRCODE = 'P0001';
  END IF;
  IF v_code IS NULL OR v_code !~ '^[A-Za-z0-9_-]{1,20}$' THEN
    RAISE EXCEPTION 'Enter a code of up to 20 letters, digits, - or _.' USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter a name.' USING ERRCODE = 'P0001';
  END IF;
  EXECUTE format('INSERT INTO erp.%I (company_code, code, name, sort, active) VALUES ($1, $2, $3, $4, $5)
                  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, sort = EXCLUDED.sort, active = EXCLUDED.active', v_tbl)
    USING p_company, v_code, v_name, v_sort, v_act;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'purchase_list_save', v_tbl, v_code, jsonb_build_object('name', v_name, 'sort', v_sort, 'active', v_act));
  RETURN jsonb_build_object('kind', p_kind, 'code', v_code, 'name', v_name, 'active', v_act);
END $$;

-- Add or change a landed cost code (Purchasing or Financials, full access). Codes that came from SAP are read-only.
-- p_code: {code, name, split_method (cbm|qty|value|weight), active}
CREATE OR REPLACE FUNCTION erp.landed_cost_code_save(p_company varchar, p_code jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  c      jsonb := coalesce(p_code, '{}'::jsonb);
  v_code text := upper(nullif(btrim(c->>'code'), ''));
  v_name text := nullif(btrim(c->>'name'), '');
  v_m    text := nullif(btrim(c->>'split_method'), '');
  v_act  boolean := coalesce((c->>'active')::boolean, true);
  old    erp.landed_cost_code;
BEGIN
  u := erp._pd_guard(p_company, true, 'change landed cost codes', true);
  IF v_code IS NULL OR v_code !~ '^[A-Z0-9_-]{1,20}$' THEN
    RAISE EXCEPTION 'Enter a code of up to 20 letters, digits, - or _.' USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter a name for landed cost %.', v_code USING ERRCODE = 'P0001';
  END IF;
  IF v_m IS NULL OR v_m NOT IN ('cbm', 'qty', 'value', 'weight') THEN
    RAISE EXCEPTION 'Choose how % is split: volume (CBM), quantity, value or weight.', v_code USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.landed_cost_code WHERE company_code = p_company AND code = v_code;
  IF old.source = 'sap' THEN
    RAISE EXCEPTION 'Landed cost % came from SAP Business One, so it is read-only in Super ERP.', v_code USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.landed_cost_code (company_code, code, name, split_method, active, source, updated_by, updated_at)
  VALUES (p_company, v_code, v_name, v_m, v_act, 'erp', u.user_id, now())
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, split_method = EXCLUDED.split_method, active = EXCLUDED.active,
                                                 updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'landed_cost_code_save', 'landed_cost_code', v_code,
          jsonb_build_object('from', CASE WHEN old.code IS NOT NULL THEN jsonb_build_object('name', old.name, 'split_method', old.split_method, 'active', old.active) END,
                             'to', jsonb_build_object('name', v_name, 'split_method', v_m, 'active', v_act)));
  RETURN jsonb_build_object('code', v_code, 'name', v_name, 'split_method', v_m, 'active', v_act);
END $$;

-- ============ Approvals inbox (replaces 20's): sales orders, quotations, journals and payments exactly as before, plus purchase orders ============
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
      UNION ALL
      SELECT a.*, 'purchase_order'::text, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 22 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'purchase_order' AND erp.can_see(a.company_code) AND (erp.can_read('purchase') OR erp.can_read('finance'))
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
REVOKE ALL ON FUNCTION erp._pd_name(integer), erp._pd_noun(integer), erp._pd_object(integer), erp._pd_kind(integer),
  erp._pd_guard(varchar, boolean, text, boolean, boolean), erp._pd_last_price(varchar, text, integer),
  erp._pd_eval(varchar, integer, jsonb, jsonb, text, integer), erp._pd_stored(varchar, integer, integer), erp._pd_lock(varchar, integer, integer),
  erp._pd_number(varchar, integer), erp._pd_order_status(), erp._pd_check_obj(integer), erp._pd_po(varchar, integer, text, boolean),
  erp._pd_base_lines(varchar, integer, jsonb, text),
  erp._pd_new_doc(varchar, integer, uuid, text, text, date, date, text, text, integer, text, text),
  erp._lc_eval(varchar, jsonb, jsonb, jsonb), erp.post_document(varchar, integer, integer), erp._atp(varchar, text, text, date, erp.atp_rule)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.purchase_doc_setup(varchar), erp.purchase_doc_checks(varchar, integer, integer, jsonb, jsonb),
  erp.purchase_doc_save(varchar, integer, integer, jsonb, jsonb), erp.purchase_doc_submit(varchar, integer, integer, text),
  erp.purchase_doc_decide(varchar, integer, integer, text, text), erp.purchase_doc_cancel(varchar, integer, integer, text),
  erp.purchase_doc_info(varchar, integer, integer), erp.purchase_copy_source(varchar, integer, integer, text),
  erp.purchase_quotation_compare(varchar, integer), erp.purchase_pi_save(varchar, integer, jsonb), erp.purchase_deposit_create(varchar, integer, jsonb),
  erp.purchase_qc_save(varchar, jsonb), erp.purchase_shipment_save(varchar, integer, jsonb, jsonb), erp.purchase_grpo_create(varchar, jsonb, jsonb),
  erp.purchase_invoice_create(varchar, jsonb, jsonb), erp.landed_cost_preview(varchar, jsonb, jsonb, jsonb), erp.landed_cost_create(varchar, jsonb, jsonb, jsonb),
  erp.landed_cost_info(varchar, integer), erp.purchase_doc_flow(varchar, integer, integer), erp.purchase_view(varchar, integer, integer),
  erp.purchase_setting_set(varchar, jsonb), erp.purchase_list_save(varchar, text, jsonb), erp.landed_cost_code_save(varchar, jsonb), erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.purchase_doc_setup(varchar), erp.purchase_doc_checks(varchar, integer, integer, jsonb, jsonb),
  erp.purchase_doc_save(varchar, integer, integer, jsonb, jsonb), erp.purchase_doc_submit(varchar, integer, integer, text),
  erp.purchase_doc_decide(varchar, integer, integer, text, text), erp.purchase_doc_cancel(varchar, integer, integer, text),
  erp.purchase_doc_info(varchar, integer, integer), erp.purchase_copy_source(varchar, integer, integer, text),
  erp.purchase_quotation_compare(varchar, integer), erp.purchase_pi_save(varchar, integer, jsonb), erp.purchase_deposit_create(varchar, integer, jsonb),
  erp.purchase_qc_save(varchar, jsonb), erp.purchase_shipment_save(varchar, integer, jsonb, jsonb), erp.purchase_grpo_create(varchar, jsonb, jsonb),
  erp.purchase_invoice_create(varchar, jsonb, jsonb), erp.landed_cost_preview(varchar, jsonb, jsonb, jsonb), erp.landed_cost_create(varchar, jsonb, jsonb, jsonb),
  erp.landed_cost_info(varchar, integer), erp.purchase_doc_flow(varchar, integer, integer), erp.purchase_view(varchar, integer, integer),
  erp.purchase_setting_set(varchar, jsonb), erp.purchase_list_save(varchar, text, jsonb), erp.landed_cost_code_save(varchar, jsonb), erp.approval_inbox()
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Clearing accounts in ZZ99's sample chart: supplier down payments, goods received not invoiced, landed costs accrued.
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', v.code, v.code, v.name, v.parent, 2, true, 'other', v.mask, 'AED', false, false, 0, 'sample'
  FROM (VALUES ('1350', 'Supplier down payments (SAMPLE)', '1000', 1), ('2120', 'Goods received, not invoiced (SAMPLE)', '2000', 2),
               ('2130', 'Landed costs accrued (SAMPLE)', '2000', 2)) AS v(code, name, parent, mask)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, acct_code) DO NOTHING;

INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', v.area, v.k, v.acct, 'sample'
  FROM (VALUES ('purchasing', 'down_payments', '1350'), ('purchasing', 'grpo_clearing', '2120'),
               ('purchasing', 'landed_cost_clearing', '2130')) AS v(area, k, acct)
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = v.acct)
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

-- Two China factories billed in AED (the four sample factories are billed in USD, which comes in a later stage).
INSERT INTO erp.business_partner (company_code, card_code, kind, name, currency, balance, payment_terms, city, country, active, created_on, source)
SELECT 'ZZ99', v.code, 'supplier', v.name, 'AED', 0, (SELECT min(group_num) FROM erp.payment_terms WHERE company_code = 'ZZ99'), v.city, 'CN', true, current_date, 'sample'
  FROM (VALUES ('S0009', 'Sample Factory Shenzhen AED (SAMPLE)', 'Shenzhen'), ('S0010', 'Sample Factory Ningbo AED (SAMPLE)', 'Ningbo')) AS v(code, name, city)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, card_code) DO NOTHING;

INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', v.obj, v.prefix, 1, 5
  FROM (VALUES (1470000113, 'PR-26-'), (540000006, 'PQ-26-'), (22, 'PO-26-'), (20, 'GR-26-'), (204, 'DPI-26-'), (18, 'AP-26-'), (69, 'LC-26-')) AS v(obj, prefix)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

INSERT INTO erp.purchase_setting (company_code, default_tax_code, default_whs_code, require_qc_pass, note)
SELECT 'ZZ99', 'IP', 'WH01', true, 'SAMPLE setting for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.tax_code WHERE company_code = 'ZZ99' AND code = 'IP')
   AND EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = 'ZZ99' AND whs_code = 'WH01')
ON CONFLICT (company_code) DO NOTHING;

INSERT INTO erp.china_office (company_code, code, name, sort, note)
SELECT 'ZZ99', v.code, v.name, v.sort, 'SAMPLE office list for test company ZZ99 only'
  FROM (VALUES ('SZ', 'Shenzhen', 1), ('FS', 'Foshan', 2), ('DG', 'Dongguan', 3), ('NB', 'Ningbo', 4)) AS v(code, name, sort)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, code) DO NOTHING;

INSERT INTO erp.pi_status (company_code, code, name, sort, note)
SELECT 'ZZ99', v.code, v.name, v.sort, 'SAMPLE status for test company ZZ99 only'
  FROM (VALUES ('received', 'PI received', 1), ('confirmed', 'PI confirmed', 2), ('deposit_paid', 'Deposit paid', 3),
               ('in_production', 'In production', 4), ('ready', 'Ready to ship', 5), ('shipped', 'Shipped', 6)) AS v(code, name, sort)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, code) DO NOTHING;

INSERT INTO erp.qc_checklist_item (company_code, code, name, sort, note)
SELECT 'ZZ99', v.code, v.name, v.sort, 'SAMPLE checklist for test company ZZ99 only'
  FROM (VALUES ('qty', 'Quantity counted against the PO', 1), ('function', 'Function test passed', 2), ('look', 'Appearance and finish', 3),
               ('label', 'Labels, rating plate and barcode', 4), ('carton', 'Gift box, master carton and shipping mark', 5)) AS v(code, name, sort)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, code) DO NOTHING;

INSERT INTO erp.landed_cost_code (company_code, code, name, split_method, source, note)
SELECT 'ZZ99', v.code, v.name, v.m, 'sample', 'SAMPLE code for test company ZZ99 only'
  FROM (VALUES ('FREIGHT', 'Sea freight', 'cbm'), ('DUTY', 'Customs duty', 'value'), ('INSURANCE', 'Insurance', 'value'),
               ('CLEARING', 'Clearing charges', 'qty'), ('TRANSPORT', 'Local transport', 'weight')) AS v(code, name, m)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, code) DO NOTHING;

-- Purchase orders above 50,000 AED raised by QA · purchasing need QA · purchasing manager; a price more than 10 % above the
-- last purchase price needs QA · purchasing manager for every position (design: "purchase price over last +10 %"). SAMPLE rules.
INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', 22, v.rule, v.pos, v.lim, v.appr, 1, 'SAMPLE rule for test company ZZ99 only'
  FROM (VALUES ('po_amount', 'QA_PURCHASE', 50000, 'QA_PURCH_MGR'), ('po_price_increase', NULL, 10, 'QA_PURCH_MGR')) AS v(rule, pos, lim, appr)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.appr)
   AND (v.pos IS NULL OR EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.pos))
ON CONFLICT (company_code, obj_type, rule_code, (coalesce(position_code, '')), step) DO NOTHING;

-- ATP for the sample company counts containers in transit (A4's sample rule gets the A6 part switched on).
UPDATE erp.atp_rule SET include_in_transit = true, note = coalesce(note || ' ', '') || '(In transit: A6 shipments.)'
 WHERE company_code = 'ZZ99' AND is_default AND NOT include_in_transit;
