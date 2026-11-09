-- A7 · Inventory transactions: transfer request → inventory transfer, goods receipt / goods issue (reason + account, approval
-- above a value), inventory counting (blind count sheet, variance report, approval, posting), batches and serial numbers
-- (required on receipt, issue and transfer, with history), bin locations (put-away and pick by bin), item movement history.
-- Safe to run twice. Does not edit 10–21 (earlier behaviour is changed here with CREATE OR REPLACE, keeping its tests passing).
--
-- Every document made here is a Super ERP row (source = 'erp', ERP doc_entry from 900000000, own number range). SAP and sample
-- rows are never written. Stock moves through A4's _stock_move, so every stock_movement row carries the document's obj_type,
-- doc_entry and line (counts: obj 1470000065, doc_entry = count_id, line = count line).
--
-- Objects:
--   erp.warehouse_setting      – existing (19); gets bins_enabled and stock_acct (the warehouse's own stock account; NULL = the
--                                company's inventory account from G/L Account Determination)
--   erp.inventory_setting      – blind_count (count sheets hide the system quantity while counting)
--   erp.inventory_reason       – goods receipt / issue reasons and their default offset account. ZZ99 sample only
--   erp.bin_location / bin_stock / bin_move – bins per warehouse, quantity per bin and item, and every bin movement
--   erp.stock_lot / stock_lot_balance / stock_lot_move – Super ERP batches and serial numbers, quantity per warehouse, history.
--                                (erp.batch stays the SAP copy: the sync upserts it by abs_entry.)
--   erp.inv_line_detail        – per document line: bin(s) and batches / serials (kept while a document waits for approval)
--   erp.inv_count / inv_count_line – inventory counting (SAP object 1470000065)
--   erp.doc_workflow           – existing (17); gets reason_code
--   erp.approval_rule          – existing; rule_code gets stock_doc_amount (59 / 60), count_variance_pct, count_variance_value
--                                (1470000065): 11 codes
--   views                      – inventory_doc_list, inv_count_list, lot_list, item_movement_list (security_invoker)
--   internal                   – _inv_name/_inv_kind/_inv_object, _inv_guard, _inv_number, _inv_whs_acct, _inv_unbinned,
--                                _inv_eval, _inv_stored, _inv_execute, _inv_lot_apply, _inv_bin_apply, _tr_eval, _count_eval,
--                                _count_post, post_document (replaced: + 59, 60, 67; 15 / 20 / 14 use the warehouse stock account)
--   API                        – inventory_setup, inventory_doc_checks / create / decide / cancel / info, transfer_request_create,
--                                transfer_request_cancel, transfer_checks, transfer_create, transfer_source, inv_count_create /
--                                sheet / save / submit / decide / cancel / info, lot_history, item_history, bin_save,
--                                warehouse_inv_set, inventory_reason_save, inventory_setting_set, approval_inbox (replaced: + goods
--                                receipts, goods issues, inventory counts)
--
-- Business values (approval limits, the count variance rule, reasons and accounts, bins, numbering) are seeded for the sample
-- company ZZ99 only and marked SAMPLE. Real companies start empty (A7 walkthrough › Needs from Ashif).

-- ============ Tables ============
ALTER TABLE erp.warehouse_setting ADD COLUMN IF NOT EXISTS bins_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE erp.warehouse_setting ADD COLUMN IF NOT EXISTS stock_acct varchar(15);
ALTER TABLE erp.doc_workflow ADD COLUMN IF NOT EXISTS reason_code text;

CREATE TABLE IF NOT EXISTS erp.inventory_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    blind_count    boolean NOT NULL DEFAULT true,       -- count sheets don't show the system quantity while counting
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.inventory_reason (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    code           varchar(20) NOT NULL,
    name           text NOT NULL,
    direction      text NOT NULL CHECK (direction IN ('in', 'out', 'both')),   -- goods receipt, goods issue, or both
    acct_code      varchar(15),                       -- default offset account (Financials may change it per document)
    active         boolean NOT NULL DEFAULT true,
    source         text NOT NULL DEFAULT 'erp',        -- 'erp', 'sample' = ZZ99
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, code)
);

CREATE TABLE IF NOT EXISTS erp.bin_location (
    bin_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    whs_code       varchar(8) NOT NULL,
    bin_code       varchar(40) NOT NULL,              -- e.g. WH02-A-01-L1 (zone-aisle-rack-level)
    name           text,
    active         boolean NOT NULL DEFAULT true,
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, bin_code),
    FOREIGN KEY (company_code, whs_code) REFERENCES erp.warehouse ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.bin_stock (
    bin_id         integer NOT NULL REFERENCES erp.bin_location ON DELETE CASCADE,
    item_code      varchar(50) NOT NULL,
    company_code   varchar(8) NOT NULL,
    qty            numeric(19,6) NOT NULL DEFAULT 0 CHECK (qty >= 0),
    PRIMARY KEY (bin_id, item_code)
);

CREATE TABLE IF NOT EXISTS erp.bin_move (
    move_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    bin_id         integer NOT NULL REFERENCES erp.bin_location ON DELETE CASCADE,
    item_code      varchar(50) NOT NULL,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,
    doc_line       integer NOT NULL,
    doc_date       date NOT NULL,
    qty_in         numeric(19,6) NOT NULL DEFAULT 0,
    qty_out        numeric(19,6) NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bin_move_doc_idx ON erp.bin_move (company_code, obj_type, doc_entry);

CREATE TABLE IF NOT EXISTS erp.stock_lot (
    lot_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    kind           char(1) NOT NULL CHECK (kind IN ('B', 'S')),   -- batch or serial
    item_code      varchar(50) NOT NULL,
    number         text NOT NULL,
    made_on        date,
    expires_on     date,
    received_on    date,
    note           text,
    source         text NOT NULL DEFAULT 'erp',
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, kind, item_code, number),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item
);

CREATE TABLE IF NOT EXISTS erp.stock_lot_balance (
    lot_id         integer NOT NULL REFERENCES erp.stock_lot ON DELETE CASCADE,
    whs_code       varchar(8) NOT NULL,
    company_code   varchar(8) NOT NULL,
    qty            numeric(19,6) NOT NULL DEFAULT 0 CHECK (qty >= 0),
    PRIMARY KEY (lot_id, whs_code)
);

CREATE TABLE IF NOT EXISTS erp.stock_lot_move (
    move_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id         integer NOT NULL REFERENCES erp.stock_lot ON DELETE CASCADE,
    company_code   varchar(8) NOT NULL,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,
    doc_line       integer NOT NULL,
    whs_code       varchar(8) NOT NULL,
    doc_date       date NOT NULL,
    qty_in         numeric(19,6) NOT NULL DEFAULT 0,
    qty_out        numeric(19,6) NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stock_lot_move_lot_idx ON erp.stock_lot_move (lot_id, move_id);
CREATE INDEX IF NOT EXISTS stock_lot_move_doc_idx ON erp.stock_lot_move (company_code, obj_type, doc_entry);

CREATE TABLE IF NOT EXISTS erp.inv_line_detail (
    company_code   varchar(8) NOT NULL,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,
    line_num       integer NOT NULL,
    bin_code       varchar(40),                       -- put-away (receipt, transfer in) or pick (issue)
    from_bin_code  varchar(40),                       -- transfers: pick bin in the from-warehouse
    lots           jsonb NOT NULL DEFAULT '[]',       -- [{number, qty, made_on, expires_on}]
    PRIMARY KEY (company_code, obj_type, doc_entry, line_num),
    FOREIGN KEY (company_code, obj_type, doc_entry, line_num) REFERENCES erp.document_line ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.inv_count (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    count_id       integer NOT NULL,                  -- from erp_doc_entry_seq (stock_movement.doc_entry for obj 1470000065)
    doc_no         text NOT NULL,
    whs_code       varchar(8) NOT NULL,
    item_group     integer,
    count_date     date NOT NULL,
    state          text NOT NULL DEFAULT 'counting' CHECK (state IN ('counting', 'pending_approval', 'posted', 'rejected', 'cancelled')),
    comments       text,
    reason         text,                              -- the submitter's reason when approval is needed
    n_lines        integer NOT NULL DEFAULT 0,
    n_counted      integer NOT NULL DEFAULT 0,
    gain_value     numeric(19,2),
    loss_value     numeric(19,2),
    trans_id       integer,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    submitted_by   uuid,
    submitted_at   timestamptz,
    decided_at     timestamptz,
    posted_at      timestamptz,
    cancelled_by   uuid,
    cancelled_at   timestamptz,
    cancel_note    text,
    PRIMARY KEY (company_code, count_id),
    UNIQUE (company_code, doc_no),
    FOREIGN KEY (company_code, whs_code) REFERENCES erp.warehouse
);

CREATE TABLE IF NOT EXISTS erp.inv_count_line (
    company_code   varchar(8) NOT NULL,
    count_id       integer NOT NULL,
    line_num       integer NOT NULL,
    item_code      varchar(50) NOT NULL,
    bin_id         integer REFERENCES erp.bin_location,   -- NULL = stock outside bins (or a warehouse without bins)
    system_qty     numeric(19,6) NOT NULL,            -- in the warehouse (or bin) when the count started
    avg_cost       numeric(19,6),
    counted_qty    numeric(19,6) CHECK (counted_qty >= 0),
    counted_by     uuid,
    counted_at     timestamptz,
    added          boolean NOT NULL DEFAULT false,    -- added by a counter (found an item not on the sheet)
    PRIMARY KEY (company_code, count_id, line_num),
    UNIQUE NULLS NOT DISTINCT (company_code, count_id, item_code, bin_id),
    FOREIGN KEY (company_code, count_id) REFERENCES erp.inv_count ON DELETE CASCADE
);

-- Approval rules: goods receipt / issue value above the requester's limit; count variance above n % (a line) or n AED (total).
ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount', 'payment_amount', 'bank_change',
                       'po_amount', 'po_price_increase', 'stock_doc_amount', 'count_variance_pct', 'count_variance_value'));

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.inventory_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.inventory_reason ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bin_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bin_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bin_move ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.stock_lot ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.stock_lot_balance ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.stock_lot_move ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.inv_line_detail ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.inv_count ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.inv_count_line ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.inventory_setting, erp.inventory_reason, erp.bin_location, erp.bin_stock, erp.bin_move, erp.stock_lot,
  erp.stock_lot_balance, erp.stock_lot_move, erp.inv_line_detail, erp.inv_count, erp.inv_count_line FROM PUBLIC, anon, authenticated;
-- inv_count_line is not readable directly: the count sheet (inv_count_sheet) hides the system quantity during a blind count.
GRANT SELECT ON erp.inventory_setting, erp.inventory_reason, erp.bin_location, erp.bin_stock, erp.bin_move, erp.stock_lot,
  erp.stock_lot_balance, erp.stock_lot_move, erp.inv_line_detail, erp.inv_count TO authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['inventory_setting', 'inventory_reason', 'bin_location', 'bin_stock', 'bin_move', 'stock_lot',
                           'stock_lot_balance', 'stock_lot_move', 'inv_line_detail', 'inv_count'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (%s))', t || '_read', t,
      CASE WHEN t IN ('stock_lot', 'stock_lot_balance', 'bin_location', 'bin_stock')
           THEN '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'
           ELSE '(SELECT erp.can_read(''inventory''))' END);
  END LOOP;
END $$;

-- Inventory users read the workflow rows (number, state, reason) of inventory documents. 17 / 21 cover the other modules.
DROP POLICY IF EXISTS doc_workflow_read_inventory ON erp.doc_workflow;
CREATE POLICY doc_workflow_read_inventory ON erp.doc_workflow FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND obj_type IN (1250000001, 67, 59, 60) AND (SELECT erp.can_read('inventory')));

-- ============ Views ============
CREATE OR REPLACE VIEW erp.inventory_doc_list WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status,
       w.state, w.reason_code, coalesce(d.from_whs, (SELECT min(l.from_whs) FROM erp.document_line l WHERE l.company_code = d.company_code
                                                      AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry)) AS from_whs,
       coalesce(d.to_whs, w.whs_code) AS to_whs, d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments,
       d.currency, d.total, d.vat_total, d.paid, d.source, d.created_on
  FROM erp.document d
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (1250000001, 67, 59, 60);

CREATE OR REPLACE VIEW erp.inv_count_list WITH (security_invoker = true) AS
SELECT c.company_code, c.count_id, c.doc_no, c.whs_code, wh.name AS whs_name, c.item_group, g.name AS item_group_name, c.count_date,
       c.state, c.n_lines, c.n_counted, c.gain_value, c.loss_value, c.trans_id, c.comments, c.created_at, c.submitted_at, c.posted_at,
       u.display_name AS created_by_name
  FROM erp.inv_count c
  LEFT JOIN erp.warehouse wh ON wh.company_code = c.company_code AND wh.whs_code = c.whs_code
  LEFT JOIN erp.item_group g ON g.company_code = c.company_code AND g.group_code = c.item_group
  LEFT JOIN erp.app_user u ON u.user_id = c.created_by;

-- Batches and serial numbers: Super ERP lots (with quantity per warehouse) and the SAP copy (erp.batch, no quantities).
CREATE OR REPLACE VIEW erp.lot_list WITH (security_invoker = true) AS
SELECT l.company_code, 'erp:' || l.lot_id AS lot_key, l.lot_id, l.kind, l.item_code, i.name AS item_name, l.number, l.made_on, l.expires_on,
       l.received_on, coalesce(b.qty, 0) AS qty, b.whs AS whs_codes, CASE WHEN coalesce(b.qty, 0) > 0 THEN 'in_stock' ELSE 'out' END AS status,
       l.source, l.created_at
  FROM erp.stock_lot l
  LEFT JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
  LEFT JOIN LATERAL (SELECT sum(qty) AS qty, string_agg(whs_code, ', ' ORDER BY whs_code) FILTER (WHERE qty > 0) AS whs
                       FROM erp.stock_lot_balance sb WHERE sb.lot_id = l.lot_id) b ON true
UNION ALL
SELECT s.company_code, 'sap:' || s.abs_entry, NULL, s.kind, s.item_code, i.name, s.number, s.made_on, s.expires_on, s.received_on,
       NULL, NULL, s.status, 'sap', NULL
  FROM erp.batch s
  LEFT JOIN erp.item i ON i.company_code = s.company_code AND i.item_code = s.item_code;

-- Item history: every warehouse-journal row with the number of the document that made it.
CREATE OR REPLACE VIEW erp.item_movement_list WITH (security_invoker = true) AS
SELECT m.company_code, m.item_code, m.trans_seq, m.trans_type, m.doc_entry, m.doc_line, m.doc_date, m.whs_code, m.qty_in, m.qty_out,
       m.price, m.currency, coalesce(w.doc_no, c.doc_no, d.doc_num::text, m.doc_entry::text) AS doc_no, d.doc_kind,
       CASE WHEN m.trans_seq >= 900000000 THEN 'erp' ELSE coalesce(d.source, 'sap') END AS source
  FROM erp.stock_movement m
  LEFT JOIN erp.document d ON d.company_code = m.company_code AND d.obj_type = m.trans_type AND d.doc_entry = m.doc_entry
  LEFT JOIN erp.doc_workflow w ON w.company_code = m.company_code AND w.obj_type = m.trans_type AND w.doc_entry = m.doc_entry
  LEFT JOIN erp.inv_count c ON m.trans_type = 1470000065 AND c.company_code = m.company_code AND c.count_id = m.doc_entry;

REVOKE ALL ON erp.inventory_doc_list, erp.inv_count_list, erp.lot_list, erp.item_movement_list FROM PUBLIC, anon;
GRANT SELECT ON erp.inventory_doc_list, erp.inv_count_list, erp.lot_list, erp.item_movement_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
CREATE OR REPLACE FUNCTION erp._inv_name(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 1250000001 THEN 'Inventory transfer request' WHEN 67 THEN 'Inventory transfer' WHEN 59 THEN 'Goods receipt'
                    WHEN 60 THEN 'Goods issue' WHEN 1470000065 THEN 'Inventory count' ELSE 'Document' END
$$;
CREATE OR REPLACE FUNCTION erp._inv_kind(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 1250000001 THEN 'transfer_request' WHEN 67 THEN 'inventory_transfer' WHEN 59 THEN 'goods_receipt'
                    WHEN 60 THEN 'goods_issue' WHEN 1470000065 THEN 'inventory_count' ELSE 'document' END
$$;

-- Who is calling, and may they read (p_write = false) or change (true: Inventory with full access) inventory in this company?
CREATE OR REPLACE FUNCTION erp._inv_guard(p_company varchar, p_write boolean, p_what text DEFAULT 'post stock documents') RETURNS erp.app_user
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
  IF NOT erp.can_read('inventory') THEN
    RAISE EXCEPTION 'Your position does not include Inventory. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_write AND NOT erp.can_write('inventory') THEN
    RAISE EXCEPTION 'You have read-only access to Inventory. Ask the system admin for full access to %.', p_what USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Next number for a Super ERP inventory document or count (row-locked). Raises when the company has no numbering.
CREATE OR REPLACE FUNCTION erp._inv_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns erp.number_series;
BEGIN
  SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._inv_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.number_series SET next_num = next_num + 1 WHERE company_code = p_company AND obj_type = p_obj;
  RETURN jsonb_build_object('num', ns.next_num, 'no', ns.prefix || lpad(ns.next_num::text, ns.pad, '0'), 'entry', nextval('erp.erp_doc_entry_seq'));
END $$;

-- The stock account of a warehouse: its own (warehouse_setting.stock_acct) or the company's inventory account.
CREATE OR REPLACE FUNCTION erp._inv_whs_acct(p_company varchar, p_whs text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v text;
BEGIN
  SELECT stock_acct INTO v FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = p_whs;
  RETURN coalesce(v, erp.gl_account(p_company, 'inventory', 'inventory'));
END $$;

-- Stock of an item in a warehouse that is not in any bin (stock from before bins were turned on, or from documents that don't
-- choose bins yet: deliveries and goods receipt POs).
CREATE OR REPLACE FUNCTION erp._inv_unbinned(p_company varchar, p_item text, p_whs text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = p_company AND item_code = p_item AND whs_code = p_whs), 0)
       - coalesce((SELECT sum(bs.qty) FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                    WHERE b.company_code = p_company AND b.whs_code = p_whs AND bs.item_code = p_item), 0)
$$;

-- Batches / serials into or out of a warehouse, with their history row. Internal: callers have validated the numbers.
-- p_lots: [{number, qty, made_on, expires_on}]; p_dir = 1 in, -1 out.
CREATE OR REPLACE FUNCTION erp._inv_lot_apply(p_company varchar, p_item text, p_kind char, p_whs text, p_lots jsonb, p_dir integer,
                                              p_obj integer, p_entry integer, p_line integer, p_date date, p_user uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  x     jsonb;
  v_lot integer;
  v_q   numeric;
  v_bal numeric;
BEGIN
  FOR x IN SELECT value FROM jsonb_array_elements(coalesce(p_lots, '[]'::jsonb)) LOOP
    v_q := CASE WHEN p_kind = 'S' THEN 1 ELSE (x->>'qty')::numeric END;
    SELECT lot_id INTO v_lot FROM erp.stock_lot WHERE company_code = p_company AND kind = p_kind AND item_code = p_item AND number = x->>'number';
    IF v_lot IS NULL THEN
      IF p_dir < 0 THEN
        RAISE EXCEPTION '% % of % is not in stock.', CASE p_kind WHEN 'S' THEN 'Serial number' ELSE 'Batch' END, x->>'number', p_item USING ERRCODE = 'P0001';
      END IF;
      INSERT INTO erp.stock_lot (company_code, kind, item_code, number, made_on, expires_on, received_on, created_by)
      VALUES (p_company, p_kind, p_item, x->>'number', erp._date(x->>'made_on'), erp._date(x->>'expires_on'), p_date, p_user)
      RETURNING lot_id INTO v_lot;
    END IF;
    IF p_dir > 0 THEN
      INSERT INTO erp.stock_lot_balance (lot_id, whs_code, company_code, qty) VALUES (v_lot, p_whs, p_company, v_q)
      ON CONFLICT (lot_id, whs_code) DO UPDATE SET qty = erp.stock_lot_balance.qty + EXCLUDED.qty;
      IF p_kind = 'S' AND (SELECT sum(qty) FROM erp.stock_lot_balance WHERE lot_id = v_lot) > 1 THEN
        RAISE EXCEPTION 'Serial number % of % is already in stock.', x->>'number', p_item USING ERRCODE = 'P0001';
      END IF;
    ELSE
      SELECT qty INTO v_bal FROM erp.stock_lot_balance WHERE lot_id = v_lot AND whs_code = p_whs FOR UPDATE;
      IF coalesce(v_bal, 0) < v_q THEN
        RAISE EXCEPTION '% % of % has only % in %.', CASE p_kind WHEN 'S' THEN 'Serial number' ELSE 'Batch' END, x->>'number', p_item,
          trim_scale(coalesce(v_bal, 0)), p_whs USING ERRCODE = 'P0001';
      END IF;
      UPDATE erp.stock_lot_balance SET qty = qty - v_q WHERE lot_id = v_lot AND whs_code = p_whs;
    END IF;
    INSERT INTO erp.stock_lot_move (lot_id, company_code, obj_type, doc_entry, doc_line, whs_code, doc_date, qty_in, qty_out)
    VALUES (v_lot, p_company, p_obj, p_entry, p_line, p_whs, p_date, CASE WHEN p_dir > 0 THEN v_q ELSE 0 END, CASE WHEN p_dir < 0 THEN v_q ELSE 0 END);
  END LOOP;
END $$;

-- Quantity into / out of a bin, with its history row. NULL bin = stock outside bins (nothing to record). Internal.
CREATE OR REPLACE FUNCTION erp._inv_bin_apply(p_company varchar, p_whs text, p_bin text, p_item text, p_in numeric, p_out numeric,
                                              p_obj integer, p_entry integer, p_line integer, p_date date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_bin integer;
  v_bal numeric;
BEGIN
  IF p_bin IS NULL THEN
    RETURN;
  END IF;
  SELECT bin_id INTO v_bin FROM erp.bin_location WHERE company_code = p_company AND whs_code = p_whs AND bin_code = p_bin;
  IF v_bin IS NULL THEN
    RAISE EXCEPTION 'Bin % does not exist in warehouse %.', p_bin, p_whs USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.bin_stock (bin_id, item_code, company_code, qty) VALUES (v_bin, p_item, p_company, 0) ON CONFLICT DO NOTHING;
  SELECT qty INTO v_bal FROM erp.bin_stock WHERE bin_id = v_bin AND item_code = p_item FOR UPDATE;
  IF v_bal + coalesce(p_in, 0) - coalesce(p_out, 0) < 0 THEN
    RAISE EXCEPTION 'Bin % holds only % of %.', p_bin, trim_scale(v_bal), p_item USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.bin_stock SET qty = qty + coalesce(p_in, 0) - coalesce(p_out, 0) WHERE bin_id = v_bin AND item_code = p_item;
  INSERT INTO erp.bin_move (company_code, bin_id, item_code, obj_type, doc_entry, doc_line, doc_date, qty_in, qty_out)
  VALUES (p_company, v_bin, p_item, p_obj, p_entry, p_line, p_date, coalesce(p_in, 0), coalesce(p_out, 0));
END $$;

-- Check the batches / serial numbers given for one line. Returns {message} on the first problem, or {lots: normalised}.
--   p_dir = 1 (receipt, transfer in: new numbers), -1 (issue, transfer out: numbers in stock in p_whs).
--   p_used: serial numbers already used by earlier lines of the same document (refused twice).
CREATE OR REPLACE FUNCTION erp._inv_lot_check(p_company varchar, p_item text, p_serial boolean, p_batch boolean, p_whs text, p_qty numeric,
                                              p_lots jsonb, p_dir integer, p_n integer, p_used text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_lots jsonb := CASE WHEN jsonb_typeof(p_lots) = 'array' THEN p_lots ELSE '[]'::jsonb END;
  v_out  jsonb := '[]';
  x      jsonb;
  v_no   text;
  v_q    numeric;
  v_sum  numeric := 0;
  v_bal  numeric;
  v_kind char(1) := CASE WHEN p_serial THEN 'S' ELSE 'B' END;
  v_seen text[] := '{}';
BEGIN
  IF NOT p_serial AND NOT p_batch THEN
    IF jsonb_array_length(v_lots) > 0 THEN
      RETURN jsonb_build_object('message', format('Line %s: %s is not managed by batches or serial numbers. Remove the numbers.', p_n, p_item));
    END IF;
    RETURN jsonb_build_object('lots', '[]'::jsonb);
  END IF;
  IF p_serial AND p_qty <> trunc(p_qty) THEN
    RETURN jsonb_build_object('message', format('Line %s: %s is serial-managed, so the quantity must be a whole number.', p_n, p_item));
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(v_lots) LOOP
    v_no := nullif(btrim(x->>'number'), '');
    CONTINUE WHEN v_no IS NULL;
    IF v_no = ANY (v_seen) OR (p_serial AND p_item || ':' || v_no = ANY (coalesce(p_used, '{}'))) THEN
      RETURN jsonb_build_object('message', format('Line %s: %s %s is entered twice.', p_n, CASE WHEN p_serial THEN 'serial number' ELSE 'batch' END, v_no));
    END IF;
    v_seen := v_seen || v_no;
    IF p_serial THEN
      v_q := 1;
    ELSE
      v_q := erp._num(x->>'qty');
      IF v_q IS NULL OR v_q <= 0 THEN
        RETURN jsonb_build_object('message', format('Line %s: enter the quantity of batch %s.', p_n, v_no));
      END IF;
    END IF;
    IF p_dir < 0 THEN
      SELECT sb.qty INTO v_bal FROM erp.stock_lot l JOIN erp.stock_lot_balance sb ON sb.lot_id = l.lot_id AND sb.whs_code = p_whs
       WHERE l.company_code = p_company AND l.kind = v_kind AND l.item_code = p_item AND l.number = v_no;
      IF coalesce(v_bal, 0) < v_q THEN
        RETURN jsonb_build_object('message', CASE WHEN p_serial
          THEN format('Line %s: serial number %s of %s is not in stock in %s.', p_n, v_no, p_item, p_whs)
          ELSE format('Line %s: batch %s of %s has only %s in %s.', p_n, v_no, p_item, trim_scale(coalesce(v_bal, 0)), p_whs) END);
      END IF;
    ELSIF p_serial AND EXISTS (SELECT 1 FROM erp.stock_lot l JOIN erp.stock_lot_balance sb ON sb.lot_id = l.lot_id
                                WHERE l.company_code = p_company AND l.kind = 'S' AND l.item_code = p_item AND l.number = v_no AND sb.qty > 0) THEN
      RETURN jsonb_build_object('message', format('Line %s: serial number %s of %s is already in stock.', p_n, v_no, p_item));
    END IF;
    v_sum := v_sum + v_q;
    v_out := v_out || jsonb_strip_nulls(jsonb_build_object('number', v_no, 'qty', v_q, 'made_on', erp._date(x->>'made_on'), 'expires_on', erp._date(x->>'expires_on')));
  END LOOP;
  IF v_sum <> p_qty THEN
    RETURN jsonb_build_object('message', CASE WHEN p_serial
      THEN format('Line %s: %s is serial-managed. Enter %s serial number(s) (%s entered).', p_n, p_item, trim_scale(p_qty), trim_scale(v_sum))
      ELSE format('Line %s: %s is batch-managed. The batches add up to %s, not %s.', p_n, p_item, trim_scale(v_sum), trim_scale(p_qty)) END);
  END IF;
  RETURN jsonb_build_object('lots', v_out);
END $$;

-- Validate, cost and check one goods receipt (59) or goods issue (60). Never writes. Returns
--   {errors:[{line, field, message}], checks:[{rule_code, step, approver_position, approver_name, value, limit, message}],
--    lines:[{line_num, item_code, description, uom, qty, price, line_total, bin_code, lots, serial, batch, on_hand}],
--    header:{doc_date, whs_code, whs_name, bins, reason_code, reason_name, acct_code, acct_name, customer_ref, comments},
--    totals:{value, currency}}
-- p_header: {doc_date, whs_code, reason_code, acct_code (optional: the reason's account), customer_ref, comments}
-- p_lines:  [{item_code, qty, price (receipt: unit cost; empty = current average cost), bin_code, lots:[{number, qty, made_on, expires_on}]}]
-- p_position = NULL skips the approval rules (used when an approved document is posted).
CREATE OR REPLACE FUNCTION erp._inv_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_in     boolean := p_obj = 59;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_cur    text;
  v_date   date;
  v_whs    text := nullif(btrim(h->>'whs_code'), '');
  wh       erp.warehouse;
  v_bins   boolean := false;
  v_rcode  text := nullif(btrim(h->>'reason_code'), '');
  rs       erp.inventory_reason;
  v_acct   text := nullif(btrim(h->>'acct_code'), '');
  ac       erp.account;
  l        jsonb;
  i        integer := 0;
  n        integer;
  it       erp.item;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_bin    text;
  v_onhand numeric;
  v_avail  numeric;
  v_lc     jsonb;
  v_used   jsonb := '{}';     -- item → quantity already taken by earlier lines
  v_ubin   jsonb := '{}';     -- item|bin → quantity already taken from a bin
  v_serials text[] := '{}';
  v_lt     numeric;
  v_total  numeric := 0;
  r        record;
  v_noun   text := lower(erp._inv_name(p_obj));
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'doc_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;

  IF v_whs IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', 'Choose a warehouse.');
  ELSE
    SELECT * INTO wh FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND OR NOT wh.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist or is inactive in company %s.', v_whs, p_company));
      v_whs := NULL;
    ELSIF wh.locked THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is locked. Ask Inventory to unlock it first.', v_whs));
      v_whs := NULL;
    ELSE
      SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_whs;
      v_bins := coalesce(v_bins, false);
    END IF;
  END IF;

  IF v_rcode IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'reason_code', 'message', format('Choose the reason for this %s.', v_noun));
  ELSE
    SELECT * INTO rs FROM erp.inventory_reason WHERE company_code = p_company AND code = v_rcode;
    IF NOT FOUND OR NOT rs.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'reason_code', 'message', format('Reason %s does not exist or is inactive. Choose another reason.', v_rcode));
    ELSIF rs.direction <> 'both' AND rs.direction <> (CASE WHEN v_in THEN 'in' ELSE 'out' END) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'reason_code', 'message',
        format('Reason %s is for %s only.', rs.name, CASE rs.direction WHEN 'in' THEN 'goods receipts' ELSE 'goods issues' END));
    ELSE
      v_acct := coalesce(v_acct, rs.acct_code);
    END IF;
  END IF;

  IF v_acct IS NULL THEN
    IF v_rcode IS NOT NULL AND rs.code IS NOT NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message',
        format('Reason %s has no account. Choose the account, or ask Finance to set one in Inventory Setup.', rs.name));
    END IF;
  ELSE
    SELECT * INTO ac FROM erp.account WHERE company_code = p_company AND acct_code = v_acct;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s does not exist in company %s.', v_acct, p_company));
    ELSIF NOT coalesce(ac.postable, false) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s is a title account. Choose an account you can post to.', v_acct));
    ELSIF coalesce(ac.is_control, false) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s is a control account (customers or suppliers). Choose another account.', v_acct));
    ELSIF coalesce(ac.frozen, false) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message', format('Account %s is frozen. Choose another account.', v_acct));
    END IF;
  END IF;

  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one item.');
  END IF;

  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    n := i + 1;
    v_code := nullif(btrim(l->>'item_code'), '');
    v_qty := erp._num(l->>'qty');
    v_price := erp._num(l->>'price');
    v_bin := nullif(btrim(l->>'bin_code'), '');
    it := NULL;
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: choose an item.', n));
      i := i + 1; CONTINUE;
    END IF;
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: item %s does not exist in company %s.', n, v_code, p_company));
      i := i + 1; CONTINUE;
    ELSIF NOT it.active THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: item %s is inactive.', n, v_code));
    ELSIF NOT coalesce(it.is_stock, false) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: %s is not a stock item, so it has no stock to move.', n, v_code));
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', format('Line %s: enter a quantity above zero.', n));
      v_qty := NULL;
    END IF;
    SELECT on_hand, avg_cost INTO r FROM erp.stock_balance WHERE company_code = p_company AND item_code = v_code AND whs_code = v_whs;
    v_onhand := coalesce(r.on_hand, 0);
    IF v_in THEN
      IF (l->>'price') IS NOT NULL AND btrim(l->>'price') <> '' AND (v_price IS NULL OR v_price < 0) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', format('Line %s: the unit cost must be zero or more.', n));
      END IF;
      v_price := coalesce(v_price, r.avg_cost, it.avg_cost, 0);
    ELSE
      v_price := coalesce(r.avg_cost, it.avg_cost, 0);
    END IF;

    IF v_qty IS NOT NULL AND v_whs IS NOT NULL THEN
      IF NOT v_in THEN
        v_avail := v_onhand - coalesce((v_used->>v_code)::numeric, 0);
        IF v_qty > v_avail THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message',
            format('Line %s: only %s of %s in stock in %s. You can''t issue %s.', n, trim_scale(greatest(v_avail, 0)), v_code, v_whs, trim_scale(v_qty)));
        END IF;
        v_used := jsonb_set(v_used, ARRAY[v_code], to_jsonb(coalesce((v_used->>v_code)::numeric, 0) + v_qty));
      END IF;
      -- Bins: put-away (receipt) needs a bin; a pick (issue) takes from the bin, or from stock outside bins.
      IF NOT v_bins THEN
        IF v_bin IS NOT NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', format('Line %s: warehouse %s does not use bins. Clear the bin.', n, v_whs));
        END IF;
      ELSIF v_in AND v_bin IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', format('Line %s: %s uses bins. Choose the bin to put %s away in.', n, v_whs, v_code));
      ELSIF v_bin IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = p_company AND whs_code = v_whs AND bin_code = v_bin AND active) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', format('Line %s: bin %s does not exist or is inactive in %s.', n, v_bin, v_whs));
      ELSIF NOT v_in THEN
        v_avail := CASE WHEN v_bin IS NULL THEN erp._inv_unbinned(p_company, v_code, v_whs)
                        ELSE coalesce((SELECT bs.qty FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                                        WHERE b.company_code = p_company AND b.bin_code = v_bin AND bs.item_code = v_code), 0) END
                   - coalesce((v_ubin->>(v_code || '|' || coalesce(v_bin, ''))::text)::numeric, 0);
        IF v_qty > v_avail THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'bin_code', 'message', CASE WHEN v_bin IS NULL
            THEN format('Line %s: only %s of %s are outside bins in %s. Choose the bin to pick from.', n, trim_scale(greatest(v_avail, 0)), v_code, v_whs)
            ELSE format('Line %s: bin %s holds only %s of %s.', n, v_bin, trim_scale(greatest(v_avail, 0)), v_code) END);
        END IF;
        v_ubin := jsonb_set(v_ubin, ARRAY[v_code || '|' || coalesce(v_bin, '')], to_jsonb(coalesce((v_ubin->>(v_code || '|' || coalesce(v_bin, '')))::numeric, 0) + v_qty));
      END IF;
      -- Batches and serial numbers
      v_lc := erp._inv_lot_check(p_company, v_code, it.serial_managed, it.batch_managed, v_whs, v_qty, l->'lots', CASE WHEN v_in THEN 1 ELSE -1 END, n, v_serials);
      IF v_lc ? 'message' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'lots', 'message', v_lc->>'message');
      ELSIF it.serial_managed THEN
        v_serials := v_serials || ARRAY(SELECT v_code || ':' || (z->>'number') FROM jsonb_array_elements(v_lc->'lots') z);
      END IF;
    END IF;

    v_lt := round(coalesce(v_qty, 0) * v_price, 2);
    v_total := v_total + v_lt;
    v_out := v_out || jsonb_build_object('line_num', i, 'item_code', v_code, 'description', it.name, 'uom', it.inventory_uom, 'qty', v_qty,
                                         'price', round(v_price, 6), 'line_total', v_lt, 'bin_code', v_bin, 'lots', coalesce(v_lc->'lots', '[]'::jsonb),
                                         'serial', coalesce(it.serial_managed, false), 'batch', coalesce(it.batch_managed, false), 'on_hand', v_onhand);
    i := i + 1;
  END LOOP;

  -- Approval: value above the requester's limit for this document type (SAMPLE limits for ZZ99 only).
  IF p_position IS NOT NULL THEN
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = p_obj AND ar.rule_code = 'stock_doc_amount' AND ar.active
                AND ar.position_code = p_position AND v_total > coalesce(ar.limit_value, 0)
              ORDER BY ar.step LOOP
      v_checks := v_checks || jsonb_build_object('rule_code', 'stock_doc_amount', 'step', r.step, 'approver_position', r.approver_position,
        'approver_name', r.approver_name, 'line', NULL, 'value', v_total, 'limit', r.limit_value,
        'message', format('Value %s %s is above your limit of %s %s for %ss. %s approves it.', erp._money(v_total), v_cur, erp._money(r.limit_value), v_cur,
                          v_noun, r.approver_name));
    END LOOP;
  END IF;

  RETURN jsonb_build_object('errors', v_err, 'checks', v_checks, 'lines', v_out,
    'header', jsonb_build_object('doc_date', v_date, 'whs_code', v_whs, 'whs_name', wh.name, 'bins', v_bins, 'reason_code', rs.code, 'reason_name', rs.name,
                                 'acct_code', v_acct, 'acct_name', ac.name, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('value', v_total, 'currency', v_cur));
END $$;

-- The stored input of a Super ERP goods receipt / issue (for posting it once approved).
CREATE OR REPLACE FUNCTION erp._inv_stored(p_company varchar, p_obj integer, p_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('doc_date', d.doc_date, 'whs_code', w.whs_code, 'reason_code', w.reason_code,
                                 'acct_code', (SELECT min(acct_code) FROM erp.document_line l WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry),
                                 'customer_ref', d.customer_ref, 'comments', d.comments),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', l.item_code, 'qty', l.quantity, 'price', CASE WHEN d.obj_type = 59 THEN l.price END,
                                                          'bin_code', x.bin_code, 'lots', coalesce(x.lots, '[]'::jsonb)) ORDER BY l.line_num)
                         FROM erp.document_line l
                         LEFT JOIN erp.inv_line_detail x ON x.company_code = l.company_code AND x.obj_type = l.obj_type AND x.doc_entry = l.doc_entry AND x.line_num = l.line_num
                        WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry), '[]'::jsonb))
    FROM erp.document d
    JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_entry
$$;

-- Move the stock of a stored goods receipt / issue and post it: re-checked at this moment (stock may have changed while it
-- waited for approval), issue lines re-costed at today's average cost, stock / bins / batches / serials moved, journal posted
-- (receipt: Dr warehouse stock account / Cr reason account; issue: the reverse), document closed. Returns the trans_id.
CREATE OR REPLACE FUNCTION erp._inv_execute(p_company varchar, p_obj integer, p_entry integer, p_user uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  inp   jsonb;
  e     jsonb;
  x     jsonb;
  hd    jsonb;
  v_in  boolean := p_obj = 59;
  v_trans integer;
BEGIN
  inp := erp._inv_stored(p_company, p_obj, p_entry);
  e := erp._inv_eval(p_company, p_obj, inp->'header', inp->'lines', NULL);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001', HINT = 'Stock changed since the document was entered. Cancel it and enter a new one.';
  END IF;
  hd := e->'header';
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') LOOP
    UPDATE erp.document_line SET price = (x->>'price')::numeric, stock_price = (x->>'price')::numeric, gross_buy_price = (x->>'price')::numeric,
                                 line_total = (x->>'line_total')::numeric, open_qty = 0, line_status = 'C'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry AND line_num = (x->>'line_num')::integer;
    PERFORM erp._stock_move(p_company, x->>'item_code', hd->>'whs_code', CASE WHEN v_in THEN (x->>'qty')::numeric ELSE 0 END,
                            CASE WHEN v_in THEN 0 ELSE (x->>'qty')::numeric END, (x->>'price')::numeric, p_obj, p_entry, (x->>'line_num')::integer, (hd->>'doc_date')::date);
    PERFORM erp._inv_bin_apply(p_company, hd->>'whs_code', x->>'bin_code', x->>'item_code', CASE WHEN v_in THEN (x->>'qty')::numeric ELSE 0 END,
                               CASE WHEN v_in THEN 0 ELSE (x->>'qty')::numeric END, p_obj, p_entry, (x->>'line_num')::integer, (hd->>'doc_date')::date);
    IF (x->>'serial')::boolean OR (x->>'batch')::boolean THEN
      PERFORM erp._inv_lot_apply(p_company, x->>'item_code', CASE WHEN (x->>'serial')::boolean THEN 'S' ELSE 'B' END, hd->>'whs_code', x->'lots',
                                 CASE WHEN v_in THEN 1 ELSE -1 END, p_obj, p_entry, (x->>'line_num')::integer, (hd->>'doc_date')::date, p_user);
    END IF;
  END LOOP;
  PERFORM erp._sd_retotal(p_company, p_obj, p_entry);
  UPDATE erp.document SET status = 'closed' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry AND source = 'erp';
  v_trans := erp.post_document(p_company, p_obj, p_entry);
  RETURN v_trans;
END $$;

-- Validate one inventory transfer request (1250000001) or inventory transfer (67). Never writes. Returns
--   {errors:[{line, field, message}], lines:[{line_num, item_code, description, uom, qty, from_whs, to_whs, from_bin, to_bin, lots, price,
--    line_total, serial, batch, on_hand, base_doc_entry, base_line, base_doc_no}], header:{…}, totals:{qty, value, currency}}
-- p_header: {doc_date, due_date (request: needed by), from_whs, to_whs, customer_ref, comments}
-- p_lines:  [{item_code, qty, from_whs?, to_whs?, from_bin?, to_bin?, lots?, base_doc_entry?, base_line? (transfer from a request line)}]
-- A transfer may stay inside one warehouse only to move stock between bins.
CREATE OR REPLACE FUNCTION erp._tr_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_req    boolean := p_obj = 1250000001;
  v_err    jsonb := '[]';
  v_out    jsonb := '[]';
  v_cur    text;
  v_date   date;
  v_due    date;
  v_hfrom  text := nullif(btrim(h->>'from_whs'), '');
  v_hto    text := nullif(btrim(h->>'to_whs'), '');
  l        jsonb;
  i        integer := 0;
  n        integer;
  it       erp.item;
  v_code   text;
  v_qty    numeric;
  v_from   text;
  v_to     text;
  v_fbin   text;
  v_tbin   text;
  v_fbins  boolean;
  v_tbins  boolean;
  v_bentry integer;
  v_bline  integer;
  bl       record;
  v_bno    text;
  v_onhand numeric;
  v_cost   numeric;
  v_avail  numeric;
  v_lc     jsonb;
  v_used   jsonb := '{}';
  v_ubin   jsonb := '{}';
  v_ubase  jsonb := '{}';
  v_serials text[] := '{}';
  v_tq     numeric := 0;
  v_tv     numeric := 0;
  v_k      text;
  w        record;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'doc_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF v_req AND nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'The needed-by date is not a valid date.');
    ELSIF v_date IS NOT NULL AND v_due < v_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'The needed-by date can''t be before the posting date.');
    END IF;
  END IF;
  FOR w IN SELECT k, c FROM (VALUES ('from_whs', v_hfrom), ('to_whs', v_hto)) AS v(k, c) WHERE c IS NOT NULL LOOP
    IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = w.c AND active AND NOT locked) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', w.k, 'message', format('Warehouse %s does not exist, is inactive or is locked.', w.c));
    END IF;
  END LOOP;
  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one item.');
  END IF;

  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    n := i + 1;
    v_code := nullif(btrim(l->>'item_code'), '');
    v_qty := erp._num(l->>'qty');
    v_from := coalesce(nullif(btrim(l->>'from_whs'), ''), v_hfrom);
    v_to := coalesce(nullif(btrim(l->>'to_whs'), ''), v_hto);
    v_fbin := CASE WHEN v_req THEN NULL ELSE nullif(btrim(l->>'from_bin'), '') END;
    v_tbin := CASE WHEN v_req THEN NULL ELSE nullif(btrim(l->>'to_bin'), '') END;
    v_bentry := CASE WHEN v_req THEN NULL ELSE (l->>'base_doc_entry')::integer END;
    v_bline := CASE WHEN v_req THEN NULL ELSE (l->>'base_line')::integer END;
    v_bno := NULL;
    it := NULL;
    v_lc := NULL;
    -- Copied from a transfer request line: it must be a Super ERP request that is open, with enough left.
    IF v_bentry IS NOT NULL THEN
      SELECT rl.item_code, rl.open_qty, rl.line_status, rl.from_whs AS b_from, rl.whs_code AS b_to, d.status, d.source, coalesce(rw.doc_no, d.doc_num::text) AS doc_no
        INTO bl
        FROM erp.document_line rl JOIN erp.document d ON d.company_code = rl.company_code AND d.obj_type = rl.obj_type AND d.doc_entry = rl.doc_entry
        LEFT JOIN erp.doc_workflow rw ON rw.company_code = d.company_code AND rw.obj_type = d.obj_type AND rw.doc_entry = d.doc_entry
       WHERE rl.company_code = p_company AND rl.obj_type = 1250000001 AND rl.doc_entry = v_bentry AND rl.line_num = v_bline;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'base', 'message', format('Line %s: the transfer request line was not found.', n));
        i := i + 1; CONTINUE;
      ELSIF bl.source <> 'erp' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'base', 'message', format('Line %s: transfer request %s came from %s. Only Super ERP requests can be copied.', n, bl.doc_no,
          CASE bl.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
        i := i + 1; CONTINUE;
      ELSIF bl.status <> 'open' OR coalesce(bl.line_status, 'O') <> 'O' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'base', 'message', format('Line %s: transfer request %s is no longer open.', n, bl.doc_no));
        i := i + 1; CONTINUE;
      END IF;
      v_bno := bl.doc_no;
      v_code := coalesce(v_code, bl.item_code);
      IF v_code <> bl.item_code THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: the request line is for %s, not %s.', n, bl.item_code, v_code));
      END IF;
      v_from := coalesce(nullif(btrim(l->>'from_whs'), ''), bl.b_from, v_hfrom);
      v_to := coalesce(nullif(btrim(l->>'to_whs'), ''), bl.b_to, v_hto);
      v_k := v_bentry || ':' || v_bline;
      IF v_qty IS NOT NULL AND v_qty > coalesce(bl.open_qty, 0) - coalesce((v_ubase->>v_k)::numeric, 0) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message',
          format('Line %s: only %s of %s are still open on transfer request %s.', n, trim_scale(greatest(coalesce(bl.open_qty, 0) - coalesce((v_ubase->>v_k)::numeric, 0), 0)), v_code, bl.doc_no));
      END IF;
      v_ubase := jsonb_set(v_ubase, ARRAY[v_k], to_jsonb(coalesce((v_ubase->>v_k)::numeric, 0) + coalesce(v_qty, 0)));
    END IF;

    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: choose an item.', n));
      i := i + 1; CONTINUE;
    END IF;
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: item %s does not exist in company %s.', n, v_code, p_company));
      i := i + 1; CONTINUE;
    ELSIF NOT it.active OR NOT coalesce(it.is_stock, false) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', format('Line %s: %s is inactive or not a stock item.', n, v_code));
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', format('Line %s: enter a quantity above zero.', n));
      v_qty := NULL;
    END IF;
    IF v_from IS NULL OR v_to IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs', 'message', format('Line %s: choose the from and to warehouses.', n));
      i := i + 1; CONTINUE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_from AND active AND NOT locked)
       OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_to AND active AND NOT locked) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs', 'message', format('Line %s: warehouse %s or %s does not exist, is inactive or is locked.', n, v_from, v_to));
      i := i + 1; CONTINUE;
    END IF;
    SELECT coalesce(bins_enabled, false) INTO v_fbins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_from;
    SELECT coalesce(bins_enabled, false) INTO v_tbins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_to;
    v_fbins := coalesce(v_fbins, false);
    v_tbins := coalesce(v_tbins, false);
    IF v_from = v_to AND (v_req OR NOT v_fbins OR v_fbin IS NOT DISTINCT FROM v_tbin) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs', 'message',
        format('Line %s: the from and to warehouse are both %s. Choose another warehouse%s.', n, v_from, CASE WHEN v_fbins AND NOT v_req THEN ', or two different bins' ELSE '' END));
    END IF;
    SELECT on_hand, avg_cost INTO w FROM erp.stock_balance WHERE company_code = p_company AND item_code = v_code AND whs_code = v_from;
    v_onhand := coalesce(w.on_hand, 0);
    v_cost := coalesce(w.avg_cost, it.avg_cost, 0);

    IF NOT v_req AND v_qty IS NOT NULL THEN
      v_k := v_code || '|' || v_from;
      v_avail := v_onhand - coalesce((v_used->>v_k)::numeric, 0);
      IF v_qty > v_avail THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message',
          format('Line %s: only %s of %s in stock in %s. You can''t transfer %s.', n, trim_scale(greatest(v_avail, 0)), v_code, v_from, trim_scale(v_qty)));
      END IF;
      v_used := jsonb_set(v_used, ARRAY[v_k], to_jsonb(coalesce((v_used->>v_k)::numeric, 0) + v_qty));
      -- Pick bin (from) and put-away bin (to)
      IF NOT v_fbins AND v_fbin IS NOT NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'from_bin', 'message', format('Line %s: warehouse %s does not use bins. Clear the from bin.', n, v_from));
      ELSIF v_fbins THEN
        IF v_fbin IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = p_company AND whs_code = v_from AND bin_code = v_fbin) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'from_bin', 'message', format('Line %s: bin %s does not exist in %s.', n, v_fbin, v_from));
        ELSE
          v_k := v_code || '|' || v_from || '|' || coalesce(v_fbin, '');
          v_avail := CASE WHEN v_fbin IS NULL THEN erp._inv_unbinned(p_company, v_code, v_from)
                          ELSE coalesce((SELECT bs.qty FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                                          WHERE b.company_code = p_company AND b.bin_code = v_fbin AND bs.item_code = v_code), 0) END
                     - coalesce((v_ubin->>v_k)::numeric, 0);
          IF v_qty > v_avail THEN
            v_err := v_err || jsonb_build_object('line', i, 'field', 'from_bin', 'message', CASE WHEN v_fbin IS NULL
              THEN format('Line %s: only %s of %s are outside bins in %s. Choose the bin to pick from.', n, trim_scale(greatest(v_avail, 0)), v_code, v_from)
              ELSE format('Line %s: bin %s holds only %s of %s.', n, v_fbin, trim_scale(greatest(v_avail, 0)), v_code) END);
          END IF;
          v_ubin := jsonb_set(v_ubin, ARRAY[v_k], to_jsonb(coalesce((v_ubin->>v_k)::numeric, 0) + v_qty));
        END IF;
      END IF;
      IF NOT v_tbins AND v_tbin IS NOT NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'to_bin', 'message', format('Line %s: warehouse %s does not use bins. Clear the to bin.', n, v_to));
      ELSIF v_tbins AND v_tbin IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'to_bin', 'message', format('Line %s: %s uses bins. Choose the bin to put %s away in.', n, v_to, v_code));
      ELSIF v_tbins AND NOT EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = p_company AND whs_code = v_to AND bin_code = v_tbin AND active) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'to_bin', 'message', format('Line %s: bin %s does not exist or is inactive in %s.', n, v_tbin, v_to));
      END IF;
      -- Batches and serial numbers leave the from-warehouse and arrive in the to-warehouse.
      v_lc := erp._inv_lot_check(p_company, v_code, it.serial_managed, it.batch_managed, v_from, v_qty, l->'lots', -1, n, v_serials);
      IF v_lc ? 'message' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'lots', 'message', v_lc->>'message');
      ELSIF it.serial_managed THEN
        v_serials := v_serials || ARRAY(SELECT v_code || ':' || (z->>'number') FROM jsonb_array_elements(v_lc->'lots') z);
      END IF;
    END IF;

    v_tq := v_tq + coalesce(v_qty, 0);
    v_tv := v_tv + round(coalesce(v_qty, 0) * v_cost, 2);
    v_out := v_out || jsonb_build_object('line_num', i, 'item_code', v_code, 'description', it.name, 'uom', it.inventory_uom, 'qty', v_qty,
                                         'from_whs', v_from, 'to_whs', v_to, 'from_bin', v_fbin, 'to_bin', v_tbin, 'lots', coalesce(v_lc->'lots', '[]'::jsonb),
                                         'price', round(v_cost, 6), 'line_total', round(coalesce(v_qty, 0) * v_cost, 2),
                                         'serial', coalesce(it.serial_managed, false), 'batch', coalesce(it.batch_managed, false), 'on_hand', v_onhand,
                                         'base_doc_entry', v_bentry, 'base_line', v_bline, 'base_doc_no', v_bno);
    i := i + 1;
  END LOOP;

  RETURN jsonb_build_object('errors', v_err, 'lines', v_out,
    'header', jsonb_build_object('doc_date', v_date, 'due_date', v_due, 'from_whs', v_hfrom, 'to_whs', v_hto,
                                 'customer_ref', nullif(btrim(h->>'customer_ref'), ''), 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('qty', v_tq, 'value', v_tv, 'currency', v_cur));
END $$;

-- Post a Super ERP document (replaces 21's). Internal: the document functions call it. A7 changes:
--   59  Goods receipt:       Dr warehouse stock account / Cr the document's offset account (reason account), at the entered cost
--   60  Goods issue:         Dr offset account / Cr warehouse stock account, at average cost
--   67  Inventory transfer:  only when the two warehouses use different stock accounts: Dr to-account / Cr from-account
--   15 / 20 / 14 (stock return): the inventory side uses each line's warehouse stock account (warehouse_setting.stock_acct, else
--   the company inventory account), so with no warehouse accounts set the journals are exactly as before.
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
  IF p_obj_type NOT IN (13, 14, 15, 20, 204, 18, 59, 60, 67) THEN
    RAISE EXCEPTION 'Posting for this document type comes in a later phase.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  v_ref := coalesce(w.doc_no, d.doc_num::text);

  -- ---------- Inventory (A7) ----------
  IF p_obj_type IN (59, 60) THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing of value moved (zero cost): no journal
    END IF;
    SELECT jsonb_agg(x ORDER BY ord, acct) INTO v_lines FROM (
      SELECT 1 AS ord, a.acct, jsonb_build_object('acct_code', a.acct, CASE WHEN p_obj_type = 59 THEN 'debit' ELSE 'credit' END, a.amt) AS x
        FROM (SELECT erp._inv_whs_acct(p_company, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a
      UNION ALL
      SELECT 2, o.acct, jsonb_build_object('acct_code', o.acct, CASE WHEN p_obj_type = 59 THEN 'credit' ELSE 'debit' END, o.amt)
        FROM (SELECT l.acct_code AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) o) s;
    v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s%s', CASE p_obj_type WHEN 59 THEN 'Goods receipt' ELSE 'Goods issue' END, v_ref,
                                                              coalesce(' · ' || (SELECT name FROM erp.inventory_reason WHERE company_code = p_company AND code = w.reason_code), '')), v_lines,
      jsonb_build_object('trans_type', p_obj_type, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
    RETURN v_trans;
  ELSIF p_obj_type = 67 THEN
    -- Same stock account on both sides (the usual case): stock moved, nothing to post.
    IF NOT EXISTS (SELECT 1 FROM erp.document_line l
                     LEFT JOIN erp.warehouse_setting fs ON fs.company_code = l.company_code AND fs.whs_code = l.from_whs
                     LEFT JOIN erp.warehouse_setting ts ON ts.company_code = l.company_code AND ts.whs_code = l.whs_code
                    WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry AND fs.stock_acct IS DISTINCT FROM ts.stock_acct) THEN
      RETURN NULL;
    END IF;
    SELECT jsonb_agg(x ORDER BY ord, acct) INTO v_lines FROM (
      SELECT 1 AS ord, t.acct, jsonb_build_object('acct_code', t.acct, 'debit', t.amt) AS x
        FROM (SELECT erp._inv_whs_acct(p_company, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry
                 AND erp._inv_whs_acct(p_company, l.whs_code) <> erp._inv_whs_acct(p_company, l.from_whs)
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) t
      UNION ALL
      SELECT 2, f.acct, jsonb_build_object('acct_code', f.acct, 'credit', f.amt)
        FROM (SELECT erp._inv_whs_acct(p_company, l.from_whs) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry
                 AND erp._inv_whs_acct(p_company, l.whs_code) <> erp._inv_whs_acct(p_company, l.from_whs)
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) f) s;
    IF v_lines IS NULL THEN
      RETURN NULL;
    END IF;
    v_trans := erp.post_journal(p_company, d.doc_date, format('Inventory transfer %s', v_ref), v_lines,
      jsonb_build_object('trans_type', 67, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('67/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 67, p_doc_entry, v_trans);
    RETURN v_trans;
  END IF;

  -- ---------- Purchasing (A6; inventory side per warehouse stock account) ----------
  IF p_obj_type = 20 THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 20 AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing of value received (zero-price lines): no journal
    END IF;
    SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct) INTO v_lines
      FROM (SELECT erp._inv_whs_acct(p_company, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 20 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a;
    v_clr := erp.gl_account(p_company, 'purchasing', 'grpo_clearing');
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'credit', v_cost));
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
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_cogs, 'debit', v_cost));
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
      FROM (SELECT erp._inv_whs_acct(p_company, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
             WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
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
      v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct)
        FROM (SELECT erp._inv_whs_acct(p_company, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
               WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
      v_cogs := erp.gl_account(p_company, 'inventory', 'cogs');
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_cogs, 'credit', v_cost));
    END IF;
  END IF;

  v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s · %s', v_name, v_ref, coalesce(d.card_name, d.card_code)), v_lines,
    jsonb_build_object('trans_type', p_obj_type, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                       'due_date', d.due_date, 'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                       'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
  RETURN v_trans;
END $$;

-- Approvals of one object (same shape as purchase_doc_info.approvals) and its activity (audit rows).
CREATE OR REPLACE FUNCTION erp._inv_approvals(p_company varchar, p_object text, p_ref text, p_user erp.app_user) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH cur AS (SELECT min(step) AS s FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code, 'approver_position', a.approver_position,
           'approver_position_name', p.name, 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
           'decided_by_name', du.display_name, 'decided_by_me', a.approver_user = p_user.user_id,
           'requested_by_name', ru.display_name, 'requested_at', a.requested_at, 'detail', a.detail, 'superseded', a.superseded,
           'current', a.decision IS NULL AND NOT a.superseded AND a.step = (SELECT s FROM cur),
           'mine', a.approver_position = p_user.position_code) ORDER BY a.approval_id), '[]'::jsonb)
    FROM erp.approval a
    JOIN erp.position p ON p.position_code = a.approver_position
    LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
    LEFT JOIN erp.app_user ru ON ru.user_id = a.requested_by
   WHERE a.company_code = p_company AND a.object = p_object AND a.object_ref = p_ref
$$;
CREATE OR REPLACE FUNCTION erp._inv_activity(p_company varchar, p_object text, p_ref text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                            ORDER BY l.at, l.audit_id), '[]'::jsonb)
    FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
   WHERE l.company_code = p_company AND l.object = p_object AND l.object_ref = p_ref
$$;

-- Approve or reject the current step of an approval (shared by goods receipt / issue and counts). Returns the remaining count
-- of open approvals after the decision (0 = fully approved), or -1 when rejected. Raises when the user can't decide.
CREATE OR REPLACE FUNCTION erp._inv_decide(p_company varchar, p_object text, p_ref text, p_noun text, p_submitted_by uuid, p_user erp.app_user,
                                           p_decision text, p_note text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_note text := nullif(btrim(p_note), '');
  v_step smallint;
  v_mine bigint[];
  v_who  text;
  v_left integer;
BEGIN
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF p_submitted_by = p_user.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own %.', p_noun USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own %. Cancel it instead if it is no longer needed.', p_noun USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded AND step = v_step
     AND approver_position = p_user.position_code;
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT p.name, ' or ') INTO v_who FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = p_object AND a.object_ref = p_ref AND a.decision IS NULL AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This % is waiting for approval from %. Your position can''t decide it.', p_noun, coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this %.', p_noun USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET decision = p_decision, approver_user = p_user.user_id, decided_at = now(), note = v_note WHERE approval_id = ANY (v_mine);
  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded;
    RETURN -1;
  END IF;
  SELECT count(*) INTO v_left FROM erp.approval WHERE company_code = p_company AND object = p_object AND object_ref = p_ref AND decision IS NULL AND NOT superseded;
  RETURN v_left;
END $$;

-- ============ API: setup ============
-- Everything the inventory screens need: warehouses (bins, stock account), bins, reasons and the accounts a goods receipt /
-- issue may use (postable, not control, not frozen), item groups, numbering, the caller's limits and the count rules.
CREATE OR REPLACE FUNCTION erp.inventory_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._inv_guard(p_company, false);
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', w.whs_code, 'name', w.name, 'bins', coalesce(s.bins_enabled, false),
                                                                 'stock_acct', s.stock_acct, 'allow_negative', coalesce(s.allow_negative, false),
                                                                 'locked', w.locked) ORDER BY w.whs_code)
                              FROM erp.warehouse w LEFT JOIN erp.warehouse_setting s ON s.company_code = w.company_code AND s.whs_code = w.whs_code
                             WHERE w.company_code = p_company AND w.active), '[]'::jsonb),
    'bins', coalesce((SELECT jsonb_agg(jsonb_build_object('code', b.bin_code, 'whs_code', b.whs_code, 'name', b.name, 'active', b.active,
                                                           'qty', (SELECT coalesce(sum(qty), 0) FROM erp.bin_stock bs WHERE bs.bin_id = b.bin_id)) ORDER BY b.bin_code)
                        FROM erp.bin_location b WHERE b.company_code = p_company), '[]'::jsonb),
    'reasons', coalesce((SELECT jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'direction', r.direction, 'acct_code', r.acct_code,
                                                              'acct_name', a.name, 'active', r.active, 'source', r.source) ORDER BY r.code)
                           FROM erp.inventory_reason r LEFT JOIN erp.account a ON a.company_code = r.company_code AND a.acct_code = r.acct_code
                          WHERE r.company_code = p_company), '[]'::jsonb),
    'accounts', coalesce((SELECT jsonb_agg(jsonb_build_object('code', a.acct_code, 'name', a.name) ORDER BY a.acct_code)
                            FROM erp.account a WHERE a.company_code = p_company AND a.postable AND NOT coalesce(a.is_control, false) AND NOT coalesce(a.frozen, false)), '[]'::jsonb),
    'item_groups', coalesce((SELECT jsonb_agg(jsonb_build_object('code', g.group_code, 'name', g.name) ORDER BY g.group_code)
                               FROM erp.item_group g WHERE g.company_code = p_company), '[]'::jsonb),
    'numbering', (SELECT jsonb_object_agg(obj_type::text, prefix) FROM erp.number_series WHERE company_code = p_company AND active
                     AND obj_type IN (1250000001, 67, 59, 60, 1470000065)),
    'my_limits', (SELECT jsonb_object_agg(obj_type::text, limit_value) FROM erp.approval_rule
                   WHERE company_code = p_company AND rule_code = 'stock_doc_amount' AND active AND position_code = u.position_code AND step = 1),
    'count_rules', jsonb_build_object(
       'pct', (SELECT min(limit_value) FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 1470000065 AND rule_code = 'count_variance_pct' AND active
                  AND (position_code IS NULL OR position_code = u.position_code)),
       'value', (SELECT min(limit_value) FROM erp.approval_rule WHERE company_code = p_company AND obj_type = 1470000065 AND rule_code = 'count_variance_value' AND active
                  AND (position_code IS NULL OR position_code = u.position_code))),
    'blind_count', coalesce((SELECT blind_count FROM erp.inventory_setting WHERE company_code = p_company), true),
    'can_write', erp.can_write('inventory'),
    'can_finance', erp.can_write('finance'));
END $$;

-- ============ API: goods receipt (59) / goods issue (60) ============
CREATE OR REPLACE FUNCTION erp._inv_check_gr(p_obj integer) RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = erp, pg_temp AS $$
BEGIN
  IF p_obj IS NULL OR p_obj NOT IN (59, 60) THEN
    RAISE EXCEPTION 'Choose a goods receipt or a goods issue.' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Live check for the form (never writes): errors, approval checks, costed lines, total value.
CREATE OR REPLACE FUNCTION erp.inventory_doc_checks(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  PERFORM erp._inv_check_gr(p_obj);
  u := erp._inv_guard(p_company, false);
  RETURN erp._inv_eval(p_company, p_obj, p_header, p_lines, u.position_code);
END $$;

-- Create a goods receipt / issue. Within the requester's limit it posts at once (stock moves, journal posts, document closed).
-- Above it, it is kept unposted, waiting for approval (p_reason required); the approver's decision posts it.
CREATE OR REPLACE FUNCTION erp.inventory_doc_create(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  e       jsonb;
  hd      jsonb;
  x       jsonb;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_reason text := nullif(btrim(p_reason), '');
  v_obj   text := erp._inv_kind(p_obj);
  v_noun  text := lower(erp._inv_name(p_obj));
  v_wait  boolean;
BEGIN
  PERFORM erp._inv_check_gr(p_obj);
  u := erp._inv_guard(p_company, true, CASE p_obj WHEN 59 THEN 'post goods receipts' ELSE 'post goods issues' END);
  e := erp._inv_eval(p_company, p_obj, p_header, p_lines, u.position_code);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  v_wait := jsonb_array_length(e->'checks') > 0;
  IF v_wait AND v_reason IS NULL THEN
    RAISE EXCEPTION 'This % needs approval (value above your limit). Add a reason for the approver.', v_noun USING ERRCODE = 'P0001';
  END IF;
  hd := e->'header';
  nb := erp._inv_number(p_company, p_obj);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, customer_ref, currency, fx_rate,
                            total, vat_total, paid, from_whs, to_whs, comments, created_on, source)
  VALUES (p_company, p_obj, v_entry, (nb->>'num')::integer, v_obj, 'draft', (hd->>'doc_date')::date, (hd->>'doc_date')::date, (hd->>'doc_date')::date,
          hd->>'customer_ref', e->'totals'->>'currency', 1, (e->'totals'->>'value')::numeric, 0, 0,
          CASE WHEN p_obj = 60 THEN hd->>'whs_code' END, CASE WHEN p_obj = 59 THEN hd->>'whs_code' END, hd->>'comments', current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, reason, whs_code, reason_code)
  VALUES (p_company, p_obj, v_entry, nb->>'no', CASE WHEN v_wait THEN 'pending_approval' ELSE 'approved' END, u.user_id, u.user_id, now(), v_reason,
          hd->>'whs_code', hd->>'reason_code');
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, vat, whs_code, acct_code, line_status, gross_buy_price, stock_price)
    VALUES (p_company, p_obj, v_entry, (x->>'line_num')::integer, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric,
            x->>'uom', (x->>'price')::numeric, e->'totals'->>'currency', 0, (x->>'line_total')::numeric, 0, hd->>'whs_code', hd->>'acct_code', 'O',
            (x->>'price')::numeric, (x->>'price')::numeric);
    INSERT INTO erp.inv_line_detail (company_code, obj_type, doc_entry, line_num, bin_code, lots)
    VALUES (p_company, p_obj, v_entry, (x->>'line_num')::integer, x->>'bin_code', coalesce(x->'lots', '[]'::jsonb));
  END LOOP;

  IF v_wait THEN
    INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
    SELECT p_company, v_obj, v_entry::text, (c->>'step')::smallint, c->>'approver_position', c->>'rule_code', u.user_id, now(),
           jsonb_build_object('checks', jsonb_agg(c), 'max_value', max((c->>'value')::numeric), 'limit', max((c->>'limit')::numeric))
      FROM jsonb_array_elements(e->'checks') c
     GROUP BY c->>'rule_code', (c->>'step')::smallint, c->>'approver_position';
  ELSE
    UPDATE erp.doc_workflow SET decided_at = now() WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    v_trans := erp._inv_execute(p_company, p_obj, v_entry, u.user_id);
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_create', v_obj, v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'result', CASE WHEN v_wait THEN 'pending_approval' ELSE 'posted' END, 'whs_code', hd->>'whs_code',
                             'reason_code', hd->>'reason_code', 'acct_code', hd->>'acct_code', 'value', e->'totals'->'value',
                             'lines', jsonb_array_length(e->'lines'), 'reason', v_reason, 'checks', e->'checks', 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'state', CASE WHEN v_wait THEN 'pending_approval' ELSE 'approved' END,
                            'status', CASE WHEN v_wait THEN 'draft' ELSE 'closed' END, 'value', e->'totals'->'value', 'trans_id', v_trans, 'checks', e->'checks');
END $$;

-- Lock a Super ERP inventory document for a change.
CREATE OR REPLACE FUNCTION erp._inv_lock(p_company varchar, p_obj integer, p_entry integer) RETURNS erp.doc_workflow
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d erp.document;
  w erp.doc_workflow;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% % was not found in company %.', erp._inv_name(p_obj), p_entry, p_company USING ERRCODE = 'P0001';
  END IF;
  IF d.source <> 'erp' THEN
    RAISE EXCEPTION 'This % came from %, so it is read-only in Super ERP.', lower(erp._inv_name(p_obj)),
      CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% % has no workflow record. Ask the system admin to check it.', erp._inv_name(p_obj), p_entry USING ERRCODE = 'P0001';
  END IF;
  RETURN w;
END $$;

-- Approve (the last step posts it) or reject a goods receipt / issue waiting for approval.
CREATE OR REPLACE FUNCTION erp.inventory_doc_decide(p_company varchar, p_obj integer, p_doc_entry integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  w       erp.doc_workflow;
  v_left  integer;
  v_state text;
  v_trans integer;
  v_obj   text := erp._inv_kind(p_obj);
BEGIN
  PERFORM erp._inv_check_gr(p_obj);
  u := erp._inv_guard(p_company, false);
  w := erp._inv_lock(p_company, p_obj, p_doc_entry);
  IF w.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This % is not waiting for approval.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  END IF;
  v_left := erp._inv_decide(p_company, v_obj, p_doc_entry::text, lower(erp._inv_name(p_obj)), w.submitted_by, u, p_decision, p_note);
  IF v_left < 0 THEN
    v_state := 'rejected';
    UPDATE erp.doc_workflow SET state = 'rejected', decided_at = now(), updated_at = now() WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  ELSIF v_left = 0 THEN
    v_state := 'approved';
    UPDATE erp.doc_workflow SET state = 'approved', decided_at = now(), updated_at = now() WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    v_trans := erp._inv_execute(p_company, p_obj, p_doc_entry, u.user_id);
  ELSE
    v_state := 'pending_approval';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN p_decision = 'approved' THEN '_approve' ELSE '_reject' END, v_obj, p_doc_entry::text,
          jsonb_build_object('doc_no', w.doc_no, 'note', nullif(btrim(p_note), ''), 'state', v_state, 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', v_state, 'trans_id', v_trans,
                            'status', (SELECT status FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry));
END $$;

-- Cancel a goods receipt / issue that has not posted (waiting for approval, or rejected): the creator or an approver, with a note.
-- A posted one can't be cancelled: enter the opposite document (issue for a receipt, receipt for an issue).
CREATE OR REPLACE FUNCTION erp.inventory_doc_cancel(p_company varchar, p_obj integer, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  w     erp.doc_workflow;
  v_obj text := erp._inv_kind(p_obj);
BEGIN
  PERFORM erp._inv_check_gr(p_obj);
  u := erp._inv_guard(p_company, true, 'cancel stock documents');
  w := erp._inv_lock(p_company, p_obj, p_doc_entry);
  IF w.state = 'cancelled' THEN
    RAISE EXCEPTION 'This % is already cancelled.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  ELSIF w.state = 'approved' THEN
    RAISE EXCEPTION 'This % is posted, so it can''t be cancelled. Enter a % to reverse it.', lower(erp._inv_name(p_obj)),
      CASE p_obj WHEN 59 THEN 'goods issue' ELSE 'goods receipt' END USING ERRCODE = 'P0001';
  END IF;
  IF w.created_by <> u.user_id AND NOT EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                                                   AND approver_position = u.position_code) THEN
    RAISE EXCEPTION 'Only the person who entered this % or its approver can cancel it.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are cancelling this %.', lower(erp._inv_name(p_obj)) USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = btrim(p_note), updated_at = now()
   WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || '_cancel', v_obj, p_doc_entry::text, jsonb_build_object('doc_no', w.doc_no, 'note', btrim(p_note)));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'state', 'cancelled');
END $$;

-- Everything an inventory document page shows (59, 60, 67, 1250000001): workflow, approvals, line details (bins, batches /
-- serials), warehouse-journal rows, the journal, the transfer flow (request ↔ transfers) and activity.
CREATE OR REPLACE FUNCTION erp.inventory_doc_info(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  d      erp.document;
  w      erp.doc_workflow;
  v_obj  text := erp._inv_kind(p_obj);
  v_step smallint;
  v_mine boolean;
  v_appr boolean;
  v_trans integer;
BEGIN
  IF p_obj IS NULL OR p_obj NOT IN (59, 60, 67, 1250000001) THEN
    RAISE EXCEPTION 'Choose an inventory document.' USING ERRCODE = 'P0001';
  END IF;
  u := erp._inv_guard(p_company, false);
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  SELECT trans_id INTO v_trans FROM erp.document_posting WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  v_appr := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = v_obj AND object_ref = p_doc_entry::text AND approver_position = u.position_code);
  RETURN jsonb_build_object(
    'workflow', w.doc_no IS NOT NULL,
    'obj_type', p_obj,
    'source', d.source,
    'doc_no', coalesce(w.doc_no, d.doc_num::text),
    'state', w.state,
    'status', d.status,
    'whs_code', w.whs_code,
    'reason_code', w.reason_code,
    'reason_name', (SELECT name FROM erp.inventory_reason WHERE company_code = p_company AND code = w.reason_code),
    'acct_code', (SELECT min(acct_code) FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry),
    'acct_name', (SELECT a.name FROM erp.account a WHERE a.company_code = p_company AND a.acct_code =
                   (SELECT min(acct_code) FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry)),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.created_by),
    'created_at', w.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = w.submitted_by),
    'submitted_at', w.submitted_at,
    'reason', w.reason,
    'cancel_note', w.cancel_note,
    'cancelled_at', w.cancelled_at,
    'is_creator', w.created_by = u.user_id,
    'is_submitter', w.submitted_by = u.user_id,
    'can_decide', w.state = 'pending_approval' AND w.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_cancel', erp.can_write('inventory') AND d.source = 'erp' AND (
                    (p_obj IN (59, 60) AND w.state IN ('pending_approval', 'rejected') AND (w.created_by = u.user_id OR v_appr))
                 OR (p_obj = 1250000001 AND d.status = 'open' AND NOT EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = p_company
                        AND l.obj_type = 1250000001 AND l.doc_entry = p_doc_entry AND l.open_qty < l.quantity))),
    'can_copy', p_obj = 1250000001 AND d.source = 'erp' AND d.status = 'open' AND erp.can_write('inventory'),
    'can_write', erp.can_write('inventory'),
    'trans_id', v_trans,
    'can_read_journal', erp.can_read('finance'),
    'approvals', erp._inv_approvals(p_company, v_obj, p_doc_entry::text, u),
    'details', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', x.line_num, 'bin_code', x.bin_code, 'from_bin_code', x.from_bin_code, 'lots', x.lots) ORDER BY x.line_num)
                           FROM erp.inv_line_detail x WHERE x.company_code = p_company AND x.obj_type = p_obj AND x.doc_entry = p_doc_entry), '[]'::jsonb),
    'movements', coalesce((SELECT jsonb_agg(jsonb_build_object('trans_seq', m.trans_seq, 'doc_line', m.doc_line, 'item_code', m.item_code, 'whs_code', m.whs_code,
                                                                'qty_in', m.qty_in, 'qty_out', m.qty_out, 'price', m.price) ORDER BY m.trans_seq)
                             FROM erp.stock_movement m WHERE m.company_code = p_company AND m.trans_type = p_obj AND m.doc_entry = p_doc_entry), '[]'::jsonb),
    'flow', coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_object('obj_type', o.obj_type, 'doc_entry', o.doc_entry, 'doc_no', coalesce(ow.doc_no, o.doc_num::text),
                                                                   'doc_date', o.doc_date, 'status', o.status))
                        FROM erp.document_line l
                        JOIN erp.document o ON o.company_code = l.company_code
                         AND ((p_obj = 1250000001 AND o.obj_type = l.obj_type AND o.doc_entry = l.doc_entry AND l.base_obj_type = 1250000001 AND l.base_doc_entry = p_doc_entry)
                           OR (p_obj = 67 AND l.obj_type = 67 AND l.doc_entry = p_doc_entry AND o.obj_type = 1250000001 AND o.doc_entry = l.base_doc_entry))
                        LEFT JOIN erp.doc_workflow ow ON ow.company_code = o.company_code AND ow.obj_type = o.obj_type AND ow.doc_entry = o.doc_entry
                       WHERE l.company_code = p_company AND p_obj IN (67, 1250000001)), '[]'::jsonb),
    'activity', erp._inv_activity(p_company, v_obj, p_doc_entry::text));
END $$;

-- ============ API: inventory transfer request (1250000001) / inventory transfer (67) ============
CREATE OR REPLACE FUNCTION erp.transfer_checks(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF p_obj IS NULL OR p_obj NOT IN (67, 1250000001) THEN
    RAISE EXCEPTION 'Choose a transfer request or a transfer.' USING ERRCODE = 'P0001';
  END IF;
  PERFORM erp._inv_guard(p_company, false);
  RETURN erp._tr_eval(p_company, p_obj, p_header, p_lines);
END $$;

-- Ask for stock to move between warehouses. Opens at once; the transfer copies its lines. No stock moves yet.
CREATE OR REPLACE FUNCTION erp.transfer_request_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  e       jsonb;
  hd      jsonb;
  x       jsonb;
  nb      jsonb;
  v_entry integer;
  v_from  text;
  v_to    text;
BEGIN
  u := erp._inv_guard(p_company, true, 'request transfers');
  e := erp._tr_eval(p_company, 1250000001, p_header, p_lines);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  hd := e->'header';
  SELECT CASE WHEN count(DISTINCT z->>'from_whs') = 1 THEN min(z->>'from_whs') END, CASE WHEN count(DISTINCT z->>'to_whs') = 1 THEN min(z->>'to_whs') END
    INTO v_from, v_to FROM jsonb_array_elements(e->'lines') z;
  nb := erp._inv_number(p_company, 1250000001);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, customer_ref, currency, fx_rate,
                            total, vat_total, paid, from_whs, to_whs, comments, created_on, source)
  VALUES (p_company, 1250000001, v_entry, (nb->>'num')::integer, 'transfer_request', 'open', (hd->>'doc_date')::date,
          coalesce((hd->>'due_date')::date, (hd->>'doc_date')::date), (hd->>'doc_date')::date, hd->>'customer_ref', e->'totals'->>'currency', 1,
          0, 0, 0, v_from, v_to, hd->>'comments', current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code)
  VALUES (p_company, 1250000001, v_entry, nb->>'no', 'approved', u.user_id, u.user_id, now(), now(), v_to);
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, vat, whs_code, from_whs, line_status, stock_price)
    VALUES (p_company, 1250000001, v_entry, (x->>'line_num')::integer, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric,
            x->>'uom', 0, e->'totals'->>'currency', 0, 0, 0, x->>'to_whs', x->>'from_whs', 'O', (x->>'price')::numeric);
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'transfer_request_create', 'transfer_request', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'from_whs', v_from, 'to_whs', v_to, 'qty', e->'totals'->'qty', 'lines', jsonb_array_length(e->'lines')));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'status', 'open');
END $$;

-- Cancel a transfer request nothing has been transferred from yet.
CREATE OR REPLACE FUNCTION erp.transfer_request_cancel(p_company varchar, p_doc_entry integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  w  erp.doc_workflow;
  st text;
BEGIN
  u := erp._inv_guard(p_company, true, 'cancel transfer requests');
  w := erp._inv_lock(p_company, 1250000001, p_doc_entry);
  SELECT status INTO st FROM erp.document WHERE company_code = p_company AND obj_type = 1250000001 AND doc_entry = p_doc_entry;
  IF st <> 'open' THEN
    RAISE EXCEPTION 'This transfer request is % and can''t be cancelled.', st USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.document_line WHERE company_code = p_company AND obj_type = 1250000001 AND doc_entry = p_doc_entry AND open_qty < quantity) THEN
    RAISE EXCEPTION 'Stock was already transferred from this request, so it can''t be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are cancelling this transfer request.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.document SET status = 'cancelled' WHERE company_code = p_company AND obj_type = 1250000001 AND doc_entry = p_doc_entry;
  UPDATE erp.document_line SET line_status = 'C' WHERE company_code = p_company AND obj_type = 1250000001 AND doc_entry = p_doc_entry;
  UPDATE erp.doc_workflow SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = btrim(p_note), updated_at = now()
   WHERE company_code = p_company AND obj_type = 1250000001 AND doc_entry = p_doc_entry;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'transfer_request_cancel', 'transfer_request', p_doc_entry::text, jsonb_build_object('doc_no', w.doc_no, 'note', btrim(p_note)));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'doc_no', w.doc_no, 'status', 'cancelled');
END $$;

-- Open lines of a Super ERP transfer request, ready to copy into a transfer, with stock in the from-warehouse.
CREATE OR REPLACE FUNCTION erp.transfer_source(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._inv_guard(p_company, false);
  RETURN (
    SELECT jsonb_build_object(
      'header', jsonb_build_object('doc_entry', d.doc_entry, 'doc_no', coalesce(w.doc_no, d.doc_num::text), 'doc_date', d.doc_date, 'due_date', d.due_date,
                                   'from_whs', d.from_whs, 'to_whs', d.to_whs, 'status', d.status, 'source', d.source, 'comments', d.comments),
      'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('base_doc_entry', l.doc_entry, 'base_line', l.line_num, 'item_code', l.item_code,
                                                            'description', l.description, 'uom', l.uom, 'quantity', l.quantity, 'open_qty', l.open_qty,
                                                            'from_whs', l.from_whs, 'to_whs', l.whs_code,
                                                            'on_hand', coalesce((SELECT on_hand FROM erp.stock_balance sb WHERE sb.company_code = l.company_code
                                                                                   AND sb.item_code = l.item_code AND sb.whs_code = l.from_whs), 0),
                                                            'serial', coalesce(i.serial_managed, false), 'batch', coalesce(i.batch_managed, false)) ORDER BY l.line_num)
                           FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
                          WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry
                            AND coalesce(l.line_status, 'O') = 'O' AND l.open_qty > 0), '[]'::jsonb))
      FROM erp.document d LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
     WHERE d.company_code = p_company AND d.obj_type = 1250000001 AND d.doc_entry = p_doc_entry);
END $$;

-- Move stock between warehouses (or between bins of one warehouse): out of the from-warehouse and into the to-warehouse at the
-- from-warehouse's average cost, so the total quantity never changes. Batches / serials and bins move with it; request lines
-- it was copied from are used up; a journal posts only when the two warehouses use different stock accounts.
CREATE OR REPLACE FUNCTION erp.transfer_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  e       jsonb;
  hd      jsonb;
  x       jsonb;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_date  date;
  v_from  text;
  v_to    text;
  v_base  jsonb;
  v_n     integer;
BEGIN
  u := erp._inv_guard(p_company, true, 'transfer stock');
  e := erp._tr_eval(p_company, 67, p_header, p_lines);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  hd := e->'header';
  v_date := (hd->>'doc_date')::date;
  SELECT CASE WHEN count(DISTINCT z->>'from_whs') = 1 THEN min(z->>'from_whs') END, CASE WHEN count(DISTINCT z->>'to_whs') = 1 THEN min(z->>'to_whs') END
    INTO v_from, v_to FROM jsonb_array_elements(e->'lines') z;
  -- Lock the request lines being copied (the check above ran without locks).
  PERFORM 1 FROM erp.document_line l
   WHERE l.company_code = p_company AND l.obj_type = 1250000001
     AND (l.doc_entry, l.line_num) IN (SELECT (z->>'base_doc_entry')::integer, (z->>'base_line')::integer FROM jsonb_array_elements(e->'lines') z
                                        WHERE z->>'base_doc_entry' IS NOT NULL)
   FOR UPDATE;
  nb := erp._inv_number(p_company, 67);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, customer_ref, currency, fx_rate,
                            total, vat_total, paid, from_whs, to_whs, comments, created_on, source)
  VALUES (p_company, 67, v_entry, (nb->>'num')::integer, 'inventory_transfer', 'open', v_date, v_date, v_date, hd->>'customer_ref', e->'totals'->>'currency', 1,
          0, 0, 0, v_from, v_to, hd->>'comments', current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code)
  VALUES (p_company, 67, v_entry, nb->>'no', 'approved', u.user_id, u.user_id, now(), now(), v_to);
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') LOOP
    v_n := (x->>'line_num')::integer;
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, vat, whs_code, from_whs, line_status, gross_buy_price, stock_price,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 67, v_entry, v_n, x->>'item_code', x->>'description', (x->>'qty')::numeric, 0, x->>'uom', (x->>'price')::numeric,
            e->'totals'->>'currency', 0, (x->>'line_total')::numeric, 0, x->>'to_whs', x->>'from_whs', 'C', (x->>'price')::numeric, (x->>'price')::numeric,
            CASE WHEN x->>'base_doc_entry' IS NOT NULL THEN 1250000001 END, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    INSERT INTO erp.inv_line_detail (company_code, obj_type, doc_entry, line_num, bin_code, from_bin_code, lots)
    VALUES (p_company, 67, v_entry, v_n, x->>'to_bin', x->>'from_bin', coalesce(x->'lots', '[]'::jsonb));
    PERFORM erp._stock_move(p_company, x->>'item_code', x->>'from_whs', 0, (x->>'qty')::numeric, (x->>'price')::numeric, 67, v_entry, v_n, v_date);
    PERFORM erp._stock_move(p_company, x->>'item_code', x->>'to_whs', (x->>'qty')::numeric, 0, (x->>'price')::numeric, 67, v_entry, v_n, v_date);
    PERFORM erp._inv_bin_apply(p_company, x->>'from_whs', x->>'from_bin', x->>'item_code', 0, (x->>'qty')::numeric, 67, v_entry, v_n, v_date);
    PERFORM erp._inv_bin_apply(p_company, x->>'to_whs', x->>'to_bin', x->>'item_code', (x->>'qty')::numeric, 0, 67, v_entry, v_n, v_date);
    IF (x->>'serial')::boolean OR (x->>'batch')::boolean THEN
      PERFORM erp._inv_lot_apply(p_company, x->>'item_code', CASE WHEN (x->>'serial')::boolean THEN 'S' ELSE 'B' END, x->>'from_whs', x->'lots', -1, 67, v_entry, v_n, v_date, u.user_id);
      PERFORM erp._inv_lot_apply(p_company, x->>'item_code', CASE WHEN (x->>'serial')::boolean THEN 'S' ELSE 'B' END, x->>'to_whs', x->'lots', 1, 67, v_entry, v_n, v_date, u.user_id);
    END IF;
  END LOOP;
  PERFORM erp._sd_retotal(p_company, 67, v_entry);
  UPDATE erp.document SET status = 'closed' WHERE company_code = p_company AND obj_type = 67 AND doc_entry = v_entry;
  SELECT jsonb_agg(jsonb_build_object('base_doc_entry', z->'base_doc_entry', 'base_line', z->'base_line', 'qty', z->'qty'))
    INTO v_base FROM jsonb_array_elements(e->'lines') z WHERE z->>'base_doc_entry' IS NOT NULL;
  IF v_base IS NOT NULL THEN
    PERFORM erp._sd_consume(p_company, 1250000001, v_base);
  END IF;
  v_trans := erp.post_document(p_company, 67, v_entry);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_transfer_create', 'inventory_transfer', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'from_whs', v_from, 'to_whs', v_to, 'qty', e->'totals'->'qty', 'value', e->'totals'->'value',
                             'lines', jsonb_array_length(e->'lines'), 'trans_id', v_trans,
                             'requests', (SELECT jsonb_agg(DISTINCT z->>'base_doc_no') FROM jsonb_array_elements(e->'lines') z WHERE z->>'base_doc_no' IS NOT NULL)));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'status', 'closed', 'qty', e->'totals'->'qty', 'value', e->'totals'->'value', 'trans_id', v_trans);
END $$;

-- ============ API: inventory counting (1470000065) ============
-- Quantity of an item in a warehouse, or in one bin, or outside bins (p_unbinned) of a bins warehouse, right now.
CREATE OR REPLACE FUNCTION erp._count_qty(p_company varchar, p_item text, p_whs text, p_bin integer, p_bins boolean) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN p_bin IS NOT NULL THEN coalesce((SELECT qty FROM erp.bin_stock WHERE bin_id = p_bin AND item_code = p_item), 0)
              WHEN p_bins THEN erp._inv_unbinned(p_company, p_item, p_whs)
              ELSE coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = p_company AND item_code = p_item AND whs_code = p_whs), 0) END
$$;

-- Start a count for a warehouse (optionally one item group): one line per item with stock there (per bin, plus stock outside
-- bins, in a bins warehouse), with the quantity in the system now. One open count per warehouse at a time.
-- p_header: {whs_code, item_group?, count_date, comments}
CREATE OR REPLACE FUNCTION erp.inv_count_create(p_company varchar, p_header jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_whs   text := nullif(btrim(h->>'whs_code'), '');
  v_grp   integer;
  v_date  date;
  v_bins  boolean;
  v_open  text;
  nb      jsonb;
  v_id    integer;
  v_n     integer;
BEGIN
  u := erp._inv_guard(p_company, true, 'count stock');
  IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
    RAISE EXCEPTION 'Choose an active warehouse to count.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(h->>'count_date'), '') IS NULL THEN
    RAISE EXCEPTION 'Choose the count date.' USING ERRCODE = 'P0001';
  END IF;
  v_date := erp._date(h->>'count_date');
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'The count date is not a valid date.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(h->>'item_group'), '') IS NOT NULL THEN
    v_grp := erp._num(h->>'item_group')::integer;
    IF v_grp IS NULL OR NOT EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND group_code = v_grp) THEN
      RAISE EXCEPTION 'Item group % does not exist in company %.', h->>'item_group', p_company USING ERRCODE = 'P0001';
    END IF;
  END IF;
  SELECT doc_no INTO v_open FROM erp.inv_count WHERE company_code = p_company AND whs_code = v_whs AND state IN ('counting', 'pending_approval', 'rejected') LIMIT 1;
  IF v_open IS NOT NULL THEN
    RAISE EXCEPTION 'Count % is still open for warehouse %. Post or cancel it first.', v_open, v_whs USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_whs;
  v_bins := coalesce(v_bins, false);

  nb := erp._inv_number(p_company, 1470000065);
  v_id := (nb->>'entry')::integer;
  INSERT INTO erp.inv_count (company_code, count_id, doc_no, whs_code, item_group, count_date, comments, created_by)
  VALUES (p_company, v_id, nb->>'no', v_whs, v_grp, v_date, nullif(btrim(h->>'comments'), ''), u.user_id);
  INSERT INTO erp.inv_count_line (company_code, count_id, line_num, item_code, bin_id, system_qty, avg_cost)
  SELECT p_company, v_id, (row_number() OVER (ORDER BY s.item_code, s.bin_code NULLS FIRST) - 1)::integer, s.item_code, s.bin_id, s.qty, s.avg_cost
    FROM (SELECT sb.item_code, NULL::integer AS bin_id, NULL::text AS bin_code,
                 CASE WHEN v_bins THEN erp._inv_unbinned(p_company, sb.item_code, v_whs) ELSE sb.on_hand END AS qty, coalesce(sb.avg_cost, i.avg_cost) AS avg_cost
            FROM erp.stock_balance sb JOIN erp.item i ON i.company_code = sb.company_code AND i.item_code = sb.item_code
           WHERE sb.company_code = p_company AND sb.whs_code = v_whs AND coalesce(i.is_stock, false) AND i.active AND (v_grp IS NULL OR i.group_code = v_grp)
          UNION ALL
          SELECT bs.item_code, b.bin_id, b.bin_code, bs.qty, coalesce(sb.avg_cost, i.avg_cost)
            FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
            JOIN erp.item i ON i.company_code = b.company_code AND i.item_code = bs.item_code
            LEFT JOIN erp.stock_balance sb ON sb.company_code = b.company_code AND sb.item_code = bs.item_code AND sb.whs_code = b.whs_code
           WHERE v_bins AND b.company_code = p_company AND b.whs_code = v_whs AND bs.qty > 0 AND coalesce(i.is_stock, false) AND i.active
             AND (v_grp IS NULL OR i.group_code = v_grp)) s
   WHERE s.qty <> 0;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Nothing to count: no items with stock in % %.', v_whs, CASE WHEN v_grp IS NOT NULL THEN 'in this item group' ELSE '' END USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.inv_count SET n_lines = v_n WHERE company_code = p_company AND count_id = v_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_count_create', 'inventory_count', v_id::text,
          jsonb_build_object('doc_no', nb->>'no', 'whs_code', v_whs, 'item_group', v_grp, 'count_date', v_date, 'lines', v_n));
  RETURN jsonb_build_object('count_id', v_id, 'doc_no', nb->>'no', 'lines', v_n, 'state', 'counting');
END $$;

-- Lock a count for a change.
CREATE OR REPLACE FUNCTION erp._count_lock(p_company varchar, p_id integer) RETURNS erp.inv_count
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c erp.inv_count;
BEGIN
  SELECT * INTO c FROM erp.inv_count WHERE company_code = p_company AND count_id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inventory count % was not found in company %.', p_id, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN c;
END $$;

-- Enter counted quantities (any number of lines; empty clears). A line for an item that is not on the sheet is added (found stock),
-- with the system quantity at that moment. A rejected count goes back to counting.
-- p_lines: [{line_num? | item_code + bin_code?, counted_qty}]
CREATE OR REPLACE FUNCTION erp.inv_count_save(p_company varchar, p_count_id integer, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  c      erp.inv_count;
  x      jsonb;
  ln     erp.inv_count_line;
  it     erp.item;
  v_bins boolean;
  v_bin  integer;
  v_code text;
  v_q    numeric;
  v_raw  text;
  v_n    integer := 0;
  v_add  integer := 0;
BEGIN
  u := erp._inv_guard(p_company, true, 'count stock');
  c := erp._count_lock(p_company, p_count_id);
  IF c.state NOT IN ('counting', 'rejected') THEN
    RAISE EXCEPTION 'Count % is %, so counts can''t be changed.', c.doc_no, replace(c.state, '_', ' ') USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = c.whs_code;
  v_bins := coalesce(v_bins, false);
  FOR x IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) LOOP
    ln := NULL;
    v_bin := NULL;
    v_raw := nullif(btrim(x->>'counted_qty'), '');
    v_q := erp._num(v_raw);
    IF v_raw IS NOT NULL AND (v_q IS NULL OR v_q < 0) THEN
      RAISE EXCEPTION 'Enter a counted quantity of zero or more.' USING ERRCODE = 'P0001';
    END IF;
    IF x->>'line_num' IS NOT NULL THEN
      SELECT * INTO ln FROM erp.inv_count_line WHERE company_code = p_company AND count_id = p_count_id AND line_num = (x->>'line_num')::integer;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Line % is not on count %.', (x->>'line_num')::integer + 1, c.doc_no USING ERRCODE = 'P0001';
      END IF;
    ELSE
      v_code := nullif(btrim(x->>'item_code'), '');
      SELECT * INTO it FROM erp.item WHERE company_code = p_company AND (item_code = v_code OR barcode = v_code) ORDER BY item_code = v_code DESC LIMIT 1;
      IF NOT FOUND OR NOT it.active OR NOT coalesce(it.is_stock, false) THEN
        RAISE EXCEPTION 'No active stock item has the code or barcode %.', coalesce(v_code, '(empty)') USING ERRCODE = 'P0001';
      END IF;
      IF nullif(btrim(x->>'bin_code'), '') IS NOT NULL THEN
        IF NOT v_bins THEN
          RAISE EXCEPTION 'Warehouse % does not use bins. Clear the bin.', c.whs_code USING ERRCODE = 'P0001';
        END IF;
        SELECT bin_id INTO v_bin FROM erp.bin_location WHERE company_code = p_company AND whs_code = c.whs_code AND bin_code = btrim(x->>'bin_code');
        IF v_bin IS NULL THEN
          RAISE EXCEPTION 'Bin % does not exist in warehouse %.', btrim(x->>'bin_code'), c.whs_code USING ERRCODE = 'P0001';
        END IF;
      END IF;
      SELECT * INTO ln FROM erp.inv_count_line WHERE company_code = p_company AND count_id = p_count_id AND item_code = it.item_code AND bin_id IS NOT DISTINCT FROM v_bin;
      IF NOT FOUND THEN
        INSERT INTO erp.inv_count_line (company_code, count_id, line_num, item_code, bin_id, system_qty, avg_cost, added)
        VALUES (p_company, p_count_id, (SELECT coalesce(max(line_num), -1) + 1 FROM erp.inv_count_line WHERE company_code = p_company AND count_id = p_count_id),
                it.item_code, v_bin, erp._count_qty(p_company, it.item_code, c.whs_code, v_bin, v_bins),
                coalesce((SELECT avg_cost FROM erp.stock_balance WHERE company_code = p_company AND item_code = it.item_code AND whs_code = c.whs_code), it.avg_cost), true)
        RETURNING * INTO ln;
        v_add := v_add + 1;
      END IF;
    END IF;
    IF v_q IS NOT NULL AND v_q <> trunc(v_q) AND (SELECT serial_managed FROM erp.item WHERE company_code = p_company AND item_code = ln.item_code) THEN
      RAISE EXCEPTION '% is serial-managed, so the count must be a whole number.', ln.item_code USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.inv_count_line SET counted_qty = v_q, counted_by = CASE WHEN v_q IS NULL THEN NULL ELSE u.user_id END,
                                  counted_at = CASE WHEN v_q IS NULL THEN NULL ELSE now() END
     WHERE company_code = p_company AND count_id = p_count_id AND line_num = ln.line_num;
    v_n := v_n + 1;
  END LOOP;
  UPDATE erp.inv_count SET state = 'counting',
         n_lines = (SELECT count(*) FROM erp.inv_count_line WHERE company_code = p_company AND count_id = p_count_id),
         n_counted = (SELECT count(*) FROM erp.inv_count_line WHERE company_code = p_company AND count_id = p_count_id AND counted_qty IS NOT NULL)
   WHERE company_code = p_company AND count_id = p_count_id
  RETURNING * INTO c;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_count_save', 'inventory_count', p_count_id::text,
          jsonb_build_object('doc_no', c.doc_no, 'lines', v_n, 'added', v_add, 'counted', c.n_counted, 'of', c.n_lines));
  RETURN jsonb_build_object('count_id', p_count_id, 'doc_no', c.doc_no, 'state', c.state, 'n_lines', c.n_lines, 'n_counted', c.n_counted, 'saved', v_n, 'added', v_add);
END $$;

-- The variance report of a count, its problems and its approval checks. Never writes. p_position NULL skips the rules.
--   errors: lines not counted, stock that moved since the count started, a variance on a batch / serial item
--   checks: count_variance_pct (one per line above the % limit; system 0 with a count counts as above), count_variance_value (total)
CREATE OR REPLACE FUNCTION erp._count_eval(p_company varchar, p_count_id integer, p_position text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c        erp.inv_count;
  v_bins   boolean;
  v_cur    text;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_lines  jsonb := '[]';
  v_gain   numeric := 0;
  v_loss   numeric := 0;
  v_unc    integer := 0;
  r        record;
  ar       record;
  v_now    numeric;
  v_var    numeric;
  v_pct    numeric;
  v_cost   numeric;
  v_val    numeric;
BEGIN
  SELECT * INTO c FROM erp.inv_count WHERE company_code = p_company AND count_id = p_count_id;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = c.whs_code;
  v_bins := coalesce(v_bins, false);
  FOR r IN SELECT l.*, i.name, i.serial_managed, i.batch_managed, i.avg_cost AS item_cost, b.bin_code,
                  (SELECT avg_cost FROM erp.stock_balance sb WHERE sb.company_code = l.company_code AND sb.item_code = l.item_code AND sb.whs_code = c.whs_code) AS whs_cost
             FROM erp.inv_count_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
             LEFT JOIN erp.bin_location b ON b.bin_id = l.bin_id
            WHERE l.company_code = p_company AND l.count_id = p_count_id ORDER BY l.line_num LOOP
    IF r.counted_qty IS NULL THEN
      v_unc := v_unc + 1;
      CONTINUE;
    END IF;
    v_now := erp._count_qty(p_company, r.item_code, c.whs_code, r.bin_id, v_bins);
    -- (A posted or cancelled count is history: the stock has moved on, so there is nothing to compare.)
    IF c.state NOT IN ('posted', 'cancelled') AND v_now <> r.system_qty THEN
      v_err := v_err || jsonb_build_object('line', r.line_num, 'field', 'system_qty', 'message',
        format('Line %s: stock of %s%s changed since the count started (%s then, %s now). Cancel this count and start a new one.',
               r.line_num + 1, r.item_code, coalesce(' in bin ' || r.bin_code, ''), trim_scale(r.system_qty), trim_scale(v_now)));
    END IF;
    v_var := r.counted_qty - r.system_qty;
    IF v_var <> 0 AND (r.serial_managed OR r.batch_managed) THEN
      v_err := v_err || jsonb_build_object('line', r.line_num, 'field', 'counted_qty', 'message',
        format('Line %s: %s is managed by %s. Post the difference with a goods receipt or goods issue that names them, then recount.',
               r.line_num + 1, r.item_code, CASE WHEN r.serial_managed THEN 'serial numbers' ELSE 'batches' END));
    END IF;
    v_pct := CASE WHEN r.system_qty <> 0 THEN round(v_var / abs(r.system_qty) * 100, 2) END;
    v_cost := coalesce(r.whs_cost, r.avg_cost, r.item_cost, 0);
    v_val := round(v_var * v_cost, 2);
    IF v_val > 0 THEN v_gain := v_gain + v_val; ELSE v_loss := v_loss - v_val; END IF;
    v_lines := v_lines || jsonb_build_object('line_num', r.line_num, 'item_code', r.item_code, 'description', r.name, 'bin_code', r.bin_code,
                                             'system_qty', r.system_qty, 'counted_qty', r.counted_qty, 'variance', v_var, 'pct', v_pct, 'cost', v_cost, 'value', v_val);
    IF p_position IS NOT NULL AND v_var <> 0 THEN
      FOR ar IN SELECT a.*, p.name AS approver_name FROM erp.approval_rule a JOIN erp.position p ON p.position_code = a.approver_position
                 WHERE a.company_code = p_company AND a.obj_type = 1470000065 AND a.rule_code = 'count_variance_pct' AND a.active
                   AND (a.position_code IS NULL OR a.position_code = p_position) AND (v_pct IS NULL OR abs(v_pct) > coalesce(a.limit_value, 0))
                 ORDER BY a.step LOOP
        v_checks := v_checks || jsonb_build_object('rule_code', 'count_variance_pct', 'step', ar.step, 'approver_position', ar.approver_position,
          'approver_name', ar.approver_name, 'line', r.line_num, 'value', v_pct, 'limit', ar.limit_value,
          'message', format('Line %s: %s counted %s, expected %s (%s), above the %s %% variance limit. %s approves it.', r.line_num + 1, r.item_code,
                            trim_scale(r.counted_qty), trim_scale(r.system_qty), CASE WHEN v_pct IS NULL THEN 'none expected' ELSE trim_scale(v_pct) || ' %' END,
                            trim_scale(ar.limit_value), ar.approver_name));
      END LOOP;
    END IF;
  END LOOP;
  IF v_unc > 0 THEN
    v_err := jsonb_build_array(jsonb_build_object('line', NULL, 'field', 'counted_qty', 'message',
               format('%s line(s) are not counted yet. Count them, or enter 0 when there is none.', v_unc))) || v_err;
  END IF;
  IF p_position IS NOT NULL AND v_gain + v_loss > 0 THEN
    FOR ar IN SELECT a.*, p.name AS approver_name FROM erp.approval_rule a JOIN erp.position p ON p.position_code = a.approver_position
               WHERE a.company_code = p_company AND a.obj_type = 1470000065 AND a.rule_code = 'count_variance_value' AND a.active
                 AND (a.position_code IS NULL OR a.position_code = p_position) AND v_gain + v_loss > coalesce(a.limit_value, 0)
               ORDER BY a.step LOOP
      v_checks := v_checks || jsonb_build_object('rule_code', 'count_variance_value', 'step', ar.step, 'approver_position', ar.approver_position,
        'approver_name', ar.approver_name, 'line', NULL, 'value', v_gain + v_loss, 'limit', ar.limit_value,
        'message', format('The variance adds up to %s %s (gains %s, losses %s), above the limit of %s %s. %s approves it.', erp._money(v_gain + v_loss), v_cur,
                          erp._money(v_gain), erp._money(v_loss), erp._money(ar.limit_value), v_cur, ar.approver_name));
    END LOOP;
  END IF;
  RETURN jsonb_build_object('errors', v_err, 'checks', v_checks, 'lines', v_lines,
                            'totals', jsonb_build_object('gain', v_gain, 'loss', v_loss, 'net', v_gain - v_loss, 'currency', v_cur, 'uncounted', v_unc));
END $$;

-- Post a count: stock (and bins) adjusted to the counted quantities at average cost, and the variance posted through A3:
-- gains Dr warehouse stock account / Cr count variance; losses Dr count variance / Cr warehouse stock account.
CREATE OR REPLACE FUNCTION erp._count_post(p_company varchar, p_count_id integer, p_user uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c       erp.inv_count;
  e       jsonb;
  x       jsonb;
  v_var   numeric;
  v_stock text;
  v_vacct text;
  v_lines jsonb := '[]';
  v_trans integer;
  v_gain  numeric;
  v_loss  numeric;
BEGIN
  SELECT * INTO c FROM erp.inv_count WHERE company_code = p_company AND count_id = p_count_id;
  e := erp._count_eval(p_company, p_count_id, NULL);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') WHERE (value->>'variance')::numeric <> 0 LOOP
    v_var := (x->>'variance')::numeric;
    PERFORM erp._stock_move(p_company, x->>'item_code', c.whs_code, greatest(v_var, 0), greatest(-v_var, 0), (x->>'cost')::numeric,
                            1470000065, p_count_id, (x->>'line_num')::integer, c.count_date);
    PERFORM erp._inv_bin_apply(p_company, c.whs_code, x->>'bin_code', x->>'item_code', greatest(v_var, 0), greatest(-v_var, 0),
                               1470000065, p_count_id, (x->>'line_num')::integer, c.count_date);
  END LOOP;
  v_gain := (e->'totals'->>'gain')::numeric;
  v_loss := (e->'totals'->>'loss')::numeric;
  IF v_gain > 0 OR v_loss > 0 THEN
    v_stock := erp._inv_whs_acct(p_company, c.whs_code);
    v_vacct := erp.gl_account(p_company, 'inventory', 'count_variance');
    IF v_gain > 0 THEN
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_stock, 'debit', v_gain, 'memo', 'Count gains'),
                                              jsonb_build_object('acct_code', v_vacct, 'credit', v_gain, 'memo', 'Count gains'));
    END IF;
    IF v_loss > 0 THEN
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_vacct, 'debit', v_loss, 'memo', 'Count losses'),
                                              jsonb_build_object('acct_code', v_stock, 'credit', v_loss, 'memo', 'Count losses'));
    END IF;
    v_trans := erp.post_journal(p_company, c.count_date, format('Inventory count %s · %s', c.doc_no, c.whs_code), v_lines,
      jsonb_build_object('trans_type', 1470000065, 'base_ref', c.doc_no, 'ref1', c.doc_no,
                         'action', 'document_post', 'object', 'inventory_count', 'object_ref', p_count_id::text));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 1470000065, p_count_id, v_trans);
  END IF;
  UPDATE erp.inv_count SET state = 'posted', posted_at = now(), trans_id = v_trans, gain_value = v_gain, loss_value = v_loss
   WHERE company_code = p_company AND count_id = p_count_id;
  RETURN v_trans;
END $$;

-- Submit a fully counted count: the variance report is checked against the rules. Within them it posts at once; above them it
-- waits for approval (p_reason required) and the approver's decision posts it.
CREATE OR REPLACE FUNCTION erp.inv_count_submit(p_company varchar, p_count_id integer, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  c       erp.inv_count;
  e       jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_trans integer;
  v_state text;
BEGIN
  u := erp._inv_guard(p_company, true, 'count stock');
  c := erp._count_lock(p_company, p_count_id);
  IF c.state NOT IN ('counting', 'rejected') THEN
    RAISE EXCEPTION 'Count % is %, so it can''t be submitted.', c.doc_no, replace(c.state, '_', ' ') USING ERRCODE = 'P0001';
  END IF;
  e := erp._count_eval(p_company, p_count_id, u.position_code);
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(e->'checks') > 0 AND v_reason IS NULL THEN
    RAISE EXCEPTION 'This count needs approval (variance above the limit). Add a reason for the approver.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'inventory_count' AND object_ref = p_count_id::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.inv_count SET submitted_by = u.user_id, submitted_at = now(), reason = v_reason, decided_at = NULL,
         gain_value = (e->'totals'->>'gain')::numeric, loss_value = (e->'totals'->>'loss')::numeric
   WHERE company_code = p_company AND count_id = p_count_id;
  IF jsonb_array_length(e->'checks') = 0 THEN
    v_trans := erp._count_post(p_company, p_count_id, u.user_id);
    v_state := 'posted';
  ELSE
    INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
    SELECT p_company, 'inventory_count', p_count_id::text, (ch->>'step')::smallint, ch->>'approver_position', ch->>'rule_code', u.user_id, now(),
           jsonb_build_object('checks', jsonb_agg(ch),
                              'lines', coalesce(jsonb_agg(ch->'line') FILTER (WHERE ch->>'line' IS NOT NULL), '[]'::jsonb),
                              'max_value', max((ch->>'value')::numeric), 'limit', max((ch->>'limit')::numeric))
      FROM jsonb_array_elements(e->'checks') ch
     GROUP BY ch->>'rule_code', (ch->>'step')::smallint, ch->>'approver_position';
    UPDATE erp.inv_count SET state = 'pending_approval' WHERE company_code = p_company AND count_id = p_count_id;
    v_state := 'pending_approval';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_count_submit', 'inventory_count', p_count_id::text,
          jsonb_build_object('doc_no', c.doc_no, 'result', v_state, 'reason', v_reason, 'checks', e->'checks', 'gain', e->'totals'->'gain',
                             'loss', e->'totals'->'loss', 'trans_id', v_trans));
  RETURN jsonb_build_object('count_id', p_count_id, 'doc_no', c.doc_no, 'state', v_state, 'trans_id', v_trans, 'checks', e->'checks', 'totals', e->'totals');
END $$;

-- Approve (the last step posts it) or reject (counts can be corrected and submitted again) a count waiting for approval.
CREATE OR REPLACE FUNCTION erp.inv_count_decide(p_company varchar, p_count_id integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  c       erp.inv_count;
  v_left  integer;
  v_state text;
  v_trans integer;
BEGIN
  u := erp._inv_guard(p_company, false);
  c := erp._count_lock(p_company, p_count_id);
  IF c.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This count is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  v_left := erp._inv_decide(p_company, 'inventory_count', p_count_id::text, 'count', c.submitted_by, u, p_decision, p_note);
  IF v_left < 0 THEN
    v_state := 'rejected';
    UPDATE erp.inv_count SET state = 'rejected', decided_at = now() WHERE company_code = p_company AND count_id = p_count_id;
  ELSIF v_left = 0 THEN
    UPDATE erp.inv_count SET decided_at = now() WHERE company_code = p_company AND count_id = p_count_id;
    v_trans := erp._count_post(p_company, p_count_id, u.user_id);
    v_state := 'posted';
  ELSE
    v_state := 'pending_approval';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_count_' || CASE WHEN p_decision = 'approved' THEN 'approve' ELSE 'reject' END, 'inventory_count', p_count_id::text,
          jsonb_build_object('doc_no', c.doc_no, 'note', nullif(btrim(p_note), ''), 'state', v_state, 'trans_id', v_trans));
  RETURN jsonb_build_object('count_id', p_count_id, 'doc_no', c.doc_no, 'state', v_state, 'trans_id', v_trans);
END $$;

-- Cancel a count that has not posted, with a note.
CREATE OR REPLACE FUNCTION erp.inv_count_cancel(p_company varchar, p_count_id integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  c erp.inv_count;
BEGIN
  u := erp._inv_guard(p_company, true, 'cancel counts');
  c := erp._count_lock(p_company, p_count_id);
  IF c.state IN ('posted', 'cancelled') THEN
    RAISE EXCEPTION 'Count % is %, so it can''t be cancelled.', c.doc_no, c.state USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are cancelling this count.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'inventory_count' AND object_ref = p_count_id::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.inv_count SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = btrim(p_note)
   WHERE company_code = p_company AND count_id = p_count_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_count_cancel', 'inventory_count', p_count_id::text, jsonb_build_object('doc_no', c.doc_no, 'note', btrim(p_note)));
  RETURN jsonb_build_object('count_id', p_count_id, 'doc_no', c.doc_no, 'state', 'cancelled');
END $$;

-- The count sheet and variance report. During a blind count (inventory_setting.blind_count, the default) the system quantity and
-- the variance are hidden until the count is submitted.
CREATE OR REPLACE FUNCTION erp.inv_count_info(p_company varchar, p_count_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  c      erp.inv_count;
  v_blind boolean;
  v_hide boolean;
  v_step smallint;
  v_mine boolean;
  e      jsonb;
BEGIN
  u := erp._inv_guard(p_company, false);
  SELECT * INTO c FROM erp.inv_count WHERE company_code = p_company AND count_id = p_count_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_blind := coalesce((SELECT blind_count FROM erp.inventory_setting WHERE company_code = p_company), true);
  v_hide := v_blind AND c.state IN ('counting', 'rejected');
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = 'inventory_count' AND object_ref = p_count_id::text AND decision IS NULL AND NOT superseded;
  v_mine := EXISTS (SELECT 1 FROM erp.approval WHERE company_code = p_company AND object = 'inventory_count' AND object_ref = p_count_id::text
                       AND decision IS NULL AND NOT superseded AND step = v_step AND approver_position = u.position_code);
  IF NOT v_hide THEN
    e := erp._count_eval(p_company, p_count_id, NULL);
  END IF;
  RETURN jsonb_build_object(
    'count_id', c.count_id, 'doc_no', c.doc_no, 'whs_code', c.whs_code,
    'whs_name', (SELECT name FROM erp.warehouse WHERE company_code = p_company AND whs_code = c.whs_code),
    'bins', coalesce((SELECT bins_enabled FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = c.whs_code), false),
    'item_group', c.item_group, 'item_group_name', (SELECT name FROM erp.item_group WHERE company_code = p_company AND group_code = c.item_group),
    'count_date', c.count_date, 'state', c.state, 'comments', c.comments, 'reason', c.reason, 'n_lines', c.n_lines, 'n_counted', c.n_counted,
    'gain_value', c.gain_value, 'loss_value', c.loss_value, 'trans_id', c.trans_id, 'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = c.created_by), 'created_at', c.created_at,
    'submitted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = c.submitted_by), 'submitted_at', c.submitted_at,
    'posted_at', c.posted_at, 'cancel_note', c.cancel_note, 'cancelled_at', c.cancelled_at,
    'blind', v_hide,
    'is_submitter', c.submitted_by = u.user_id,
    'can_count', erp.can_write('inventory') AND c.state IN ('counting', 'rejected'),
    'can_cancel', erp.can_write('inventory') AND c.state IN ('counting', 'rejected', 'pending_approval'),
    'can_decide', c.state = 'pending_approval' AND c.submitted_by IS DISTINCT FROM u.user_id AND v_mine,
    'can_read_journal', erp.can_read('finance'),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'item_code', l.item_code, 'description', i.name, 'barcode', i.barcode,
                                                          'uom', i.inventory_uom, 'bin_code', b.bin_code, 'counted_qty', l.counted_qty, 'added', l.added,
                                                          'counted_by_name', cu.display_name, 'counted_at', l.counted_at,
                                                          'serial', coalesce(i.serial_managed, false), 'batch', coalesce(i.batch_managed, false),
                                                          'system_qty', CASE WHEN v_hide THEN NULL ELSE l.system_qty END,
                                                          'variance', CASE WHEN v_hide OR l.counted_qty IS NULL THEN NULL ELSE l.counted_qty - l.system_qty END)
                                        ORDER BY l.line_num)
                         FROM erp.inv_count_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
                         LEFT JOIN erp.bin_location b ON b.bin_id = l.bin_id
                         LEFT JOIN erp.app_user cu ON cu.user_id = l.counted_by
                        WHERE l.company_code = p_company AND l.count_id = p_count_id), '[]'::jsonb),
    'report', CASE WHEN v_hide THEN NULL ELSE jsonb_build_object('lines', e->'lines', 'totals', e->'totals', 'errors', e->'errors') END,
    'approvals', erp._inv_approvals(p_company, 'inventory_count', p_count_id::text, u),
    'activity', erp._inv_activity(p_company, 'inventory_count', p_count_id::text));
END $$;

-- ============ API: batches / serial numbers history ============
CREATE OR REPLACE FUNCTION erp.lot_history(p_company varchar, p_lot_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  l erp.stock_lot;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF NOT (erp.can_read('inventory') OR erp.can_read('sales') OR erp.can_read('purchase')) THEN
    RAISE EXCEPTION 'Your position does not include Inventory. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM erp.stock_lot WHERE company_code = p_company AND lot_id = p_lot_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'lot_id', l.lot_id, 'kind', l.kind, 'item_code', l.item_code, 'number', l.number, 'made_on', l.made_on, 'expires_on', l.expires_on,
    'received_on', l.received_on, 'source', l.source, 'created_at', l.created_at,
    'item_name', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = l.item_code),
    'balances', coalesce((SELECT jsonb_agg(jsonb_build_object('whs_code', b.whs_code, 'qty', b.qty) ORDER BY b.whs_code)
                            FROM erp.stock_lot_balance b WHERE b.lot_id = l.lot_id AND b.qty > 0), '[]'::jsonb),
    'moves', coalesce((SELECT jsonb_agg(jsonb_build_object('move_id', m.move_id, 'obj_type', m.obj_type, 'doc_entry', m.doc_entry, 'doc_line', m.doc_line,
                                                          'doc_no', coalesce(w.doc_no, m.doc_entry::text), 'doc_date', m.doc_date, 'whs_code', m.whs_code,
                                                          'qty_in', m.qty_in, 'qty_out', m.qty_out) ORDER BY m.move_id)
                         FROM erp.stock_lot_move m
                         LEFT JOIN erp.doc_workflow w ON w.company_code = m.company_code AND w.obj_type = m.obj_type AND w.doc_entry = m.doc_entry
                        WHERE m.lot_id = l.lot_id), '[]'::jsonb));
END $$;

-- ============ API: bins, warehouse settings, reasons, inventory settings ============
-- Create or change a bin (Inventory with full access). A bin that holds stock can't be deactivated.
-- p_bin: {bin_code, whs_code, name, active}
CREATE OR REPLACE FUNCTION erp.bin_save(p_company varchar, p_bin jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  v_code text := upper(nullif(btrim(p_bin->>'bin_code'), ''));
  v_whs  text := nullif(btrim(p_bin->>'whs_code'), '');
  v_act  boolean := coalesce((p_bin->>'active')::boolean, true);
  b      erp.bin_location;
BEGIN
  u := erp._inv_guard(p_company, true, 'set up bins');
  IF v_code IS NULL OR v_code !~ '^[A-Z0-9][A-Z0-9._/-]{0,39}$' THEN
    RAISE EXCEPTION 'Enter a bin code of up to 40 letters, digits, dots, dashes or slashes, e.g. WH02-A-01-L1.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO b FROM erp.bin_location WHERE company_code = p_company AND bin_code = v_code;
  IF FOUND THEN
    IF v_whs IS NOT NULL AND v_whs <> b.whs_code THEN
      RAISE EXCEPTION 'Bin % belongs to warehouse %. A bin can''t move to another warehouse.', v_code, b.whs_code USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_act AND EXISTS (SELECT 1 FROM erp.bin_stock WHERE bin_id = b.bin_id AND qty > 0) THEN
      RAISE EXCEPTION 'Bin % still holds stock. Move it to another bin before deactivating it.', v_code USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.bin_location SET name = coalesce(nullif(btrim(p_bin->>'name'), ''), name), active = v_act WHERE bin_id = b.bin_id;
  ELSE
    IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      RAISE EXCEPTION 'Choose the warehouse the bin is in.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.bin_location (company_code, whs_code, bin_code, name, active, created_by)
    VALUES (p_company, v_whs, v_code, nullif(btrim(p_bin->>'name'), ''), v_act, u.user_id) RETURNING * INTO b;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bin_save', 'bin_location', v_code, jsonb_build_object('whs_code', b.whs_code, 'name', p_bin->>'name', 'active', v_act));
  RETURN jsonb_build_object('bin_code', v_code, 'whs_code', b.whs_code, 'active', v_act);
END $$;

-- Warehouse inventory settings. p_setting keys applied only when present:
--   bins_enabled (Inventory full; can't be turned off while bins hold stock), stock_acct (Financials full; '' clears).
CREATE OR REPLACE FUNCTION erp.warehouse_inv_set(p_company varchar, p_whs text, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  s     jsonb := coalesce(p_setting, '{}'::jsonb);
  old   erp.warehouse_setting;
  ac    erp.account;
  v_acct text;
BEGIN
  u := erp._inv_guard(p_company, false);
  IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = p_whs) THEN
    RAISE EXCEPTION 'Warehouse % does not exist in company %.', coalesce(p_whs, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = p_whs;
  INSERT INTO erp.warehouse_setting (company_code, whs_code, allow_negative, updated_by, updated_at) VALUES (p_company, p_whs, false, u.user_id, now())
  ON CONFLICT (company_code, whs_code) DO NOTHING;
  IF s ? 'bins_enabled' THEN
    IF NOT erp.can_write('inventory') THEN
      RAISE EXCEPTION 'You have read-only access to Inventory. Ask the system admin for full access to set up bins.' USING ERRCODE = '42501';
    END IF;
    IF NOT coalesce((s->>'bins_enabled')::boolean, false) AND EXISTS (SELECT 1 FROM erp.bin_stock bs JOIN erp.bin_location b ON b.bin_id = bs.bin_id
                                                                         WHERE b.company_code = p_company AND b.whs_code = p_whs AND bs.qty > 0) THEN
      RAISE EXCEPTION 'Bins in % still hold stock, so bins can''t be turned off.', p_whs USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.warehouse_setting SET bins_enabled = coalesce((s->>'bins_enabled')::boolean, false), updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND whs_code = p_whs;
  END IF;
  IF s ? 'stock_acct' THEN
    IF NOT erp.can_write('finance') THEN
      RAISE EXCEPTION 'Only Financials with full access can change a warehouse''s stock account.' USING ERRCODE = '42501';
    END IF;
    v_acct := nullif(btrim(s->>'stock_acct'), '');
    IF v_acct IS NOT NULL THEN
      SELECT * INTO ac FROM erp.account WHERE company_code = p_company AND acct_code = v_acct;
      IF NOT FOUND OR NOT coalesce(ac.postable, false) OR coalesce(ac.is_control, false) OR coalesce(ac.frozen, false) THEN
        RAISE EXCEPTION 'Account % can''t be a stock account: it must exist, be postable, not frozen and not a control account.', v_acct USING ERRCODE = 'P0001';
      END IF;
    END IF;
    UPDATE erp.warehouse_setting SET stock_acct = v_acct, updated_by = u.user_id, updated_at = now() WHERE company_code = p_company AND whs_code = p_whs;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'warehouse_inv_set', 'warehouse', p_whs,
          jsonb_build_object('set', s, 'before', jsonb_build_object('bins_enabled', coalesce(old.bins_enabled, false), 'stock_acct', old.stock_acct)));
  RETURN (SELECT jsonb_build_object('whs_code', whs_code, 'bins_enabled', bins_enabled, 'stock_acct', stock_acct)
            FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = p_whs);
END $$;

-- Goods receipt / issue reasons and their account (Financials with full access: the account decides where stock value posts).
-- p_reason: {code, name, direction ('in' | 'out' | 'both'), acct_code, active}
CREATE OR REPLACE FUNCTION erp.inventory_reason_save(p_company varchar, p_reason jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  v_code text := upper(nullif(btrim(p_reason->>'code'), ''));
  v_name text := nullif(btrim(p_reason->>'name'), '');
  v_dir  text := coalesce(nullif(btrim(p_reason->>'direction'), ''), 'both');
  v_acct text := nullif(btrim(p_reason->>'acct_code'), '');
  ac     erp.account;
BEGIN
  u := erp._inv_guard(p_company, false);
  IF NOT erp.can_write('finance') THEN
    RAISE EXCEPTION 'Only Financials with full access can change goods receipt and issue reasons (they decide the account).' USING ERRCODE = '42501';
  END IF;
  IF v_code IS NULL OR v_code !~ '^[A-Z0-9_-]{1,20}$' THEN
    RAISE EXCEPTION 'Enter a reason code of up to 20 letters, digits, dashes or underscores.' USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the reason name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_dir NOT IN ('in', 'out', 'both') THEN
    RAISE EXCEPTION 'Choose whether the reason is for goods receipts, goods issues or both.' USING ERRCODE = 'P0001';
  END IF;
  IF v_acct IS NOT NULL THEN
    SELECT * INTO ac FROM erp.account WHERE company_code = p_company AND acct_code = v_acct;
    IF NOT FOUND OR NOT coalesce(ac.postable, false) OR coalesce(ac.is_control, false) OR coalesce(ac.frozen, false) THEN
      RAISE EXCEPTION 'Account % can''t be used: it must exist, be postable, not frozen and not a control account.', v_acct USING ERRCODE = 'P0001';
    END IF;
  END IF;
  INSERT INTO erp.inventory_reason (company_code, code, name, direction, acct_code, active, source, updated_by, updated_at)
  VALUES (p_company, v_code, v_name, v_dir, v_acct, coalesce((p_reason->>'active')::boolean, true), 'erp', u.user_id, now())
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, direction = EXCLUDED.direction, acct_code = EXCLUDED.acct_code,
    active = EXCLUDED.active, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_reason_save', 'inventory_reason', v_code, jsonb_build_object('name', v_name, 'direction', v_dir, 'acct_code', v_acct));
  RETURN jsonb_build_object('code', v_code, 'name', v_name, 'direction', v_dir, 'acct_code', v_acct);
END $$;

-- p_setting: {blind_count}
CREATE OR REPLACE FUNCTION erp.inventory_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  v boolean := (p_setting->>'blind_count')::boolean;
BEGIN
  u := erp._inv_guard(p_company, true, 'change inventory settings');
  IF v IS NULL THEN
    RAISE EXCEPTION 'Choose whether count sheets hide the system quantity.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.inventory_setting (company_code, blind_count, updated_by, updated_at) VALUES (p_company, v, u.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET blind_count = EXCLUDED.blind_count, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_setting_set', 'inventory_setting', p_company, jsonb_build_object('blind_count', v));
  RETURN jsonb_build_object('blind_count', v);
END $$;

-- ============ Approvals inbox (replaces 21's): the 6 earlier branches exactly as before, plus goods receipts, goods issues, counts ============
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
      UNION ALL
      -- A7: goods receipts / issues (card_code = warehouse, card_name = reason) and counts (card_code = warehouse, total = variance value)
      SELECT a.*, a.object, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, w.whs_code::varchar,
             (SELECT name FROM erp.inventory_reason r WHERE r.company_code = w.company_code AND r.code = w.reason_code), d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = CASE a.object WHEN 'goods_receipt' THEN 59 ELSE 60 END
                               AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object IN ('goods_receipt', 'goods_issue') AND erp.can_see(a.company_code) AND erp.can_read('inventory')
      UNION ALL
      SELECT a.*, 'inventory_count'::text, c.doc_no, c.state, c.reason, c.submitted_by, c.count_id, c.whs_code::varchar,
             (SELECT name FROM erp.warehouse wh WHERE wh.company_code = c.company_code AND wh.whs_code = c.whs_code),
             coalesce(c.gain_value, 0) + coalesce(c.loss_value, 0), (SELECT currency FROM erp.company co WHERE co.company_code = c.company_code)
        FROM erp.approval a
        JOIN erp.inv_count c ON c.company_code = a.company_code AND c.count_id::text = a.object_ref
       WHERE a.object = 'inventory_count' AND erp.can_see(a.company_code) AND erp.can_read('inventory')
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
REVOKE ALL ON FUNCTION erp._inv_name(integer), erp._inv_kind(integer), erp._inv_guard(varchar, boolean, text), erp._inv_number(varchar, integer),
  erp._inv_whs_acct(varchar, text), erp._inv_unbinned(varchar, text, text),
  erp._inv_lot_apply(varchar, text, char, text, jsonb, integer, integer, integer, integer, date, uuid),
  erp._inv_bin_apply(varchar, text, text, text, numeric, numeric, integer, integer, integer, date),
  erp._inv_lot_check(varchar, text, boolean, boolean, text, numeric, jsonb, integer, integer, text[]),
  erp._inv_eval(varchar, integer, jsonb, jsonb, text), erp._inv_stored(varchar, integer, integer), erp._inv_execute(varchar, integer, integer, uuid),
  erp._tr_eval(varchar, integer, jsonb, jsonb), erp.post_document(varchar, integer, integer),
  erp._inv_approvals(varchar, text, text, erp.app_user), erp._inv_activity(varchar, text, text),
  erp._inv_decide(varchar, text, text, text, uuid, erp.app_user, text, text), erp._inv_check_gr(integer), erp._inv_lock(varchar, integer, integer),
  erp._count_qty(varchar, text, text, integer, boolean), erp._count_lock(varchar, integer), erp._count_eval(varchar, integer, text),
  erp._count_post(varchar, integer, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.inventory_setup(varchar), erp.inventory_doc_checks(varchar, integer, jsonb, jsonb),
  erp.inventory_doc_create(varchar, integer, jsonb, jsonb, text), erp.inventory_doc_decide(varchar, integer, integer, text, text),
  erp.inventory_doc_cancel(varchar, integer, integer, text), erp.inventory_doc_info(varchar, integer, integer),
  erp.transfer_checks(varchar, integer, jsonb, jsonb), erp.transfer_request_create(varchar, jsonb, jsonb), erp.transfer_request_cancel(varchar, integer, text),
  erp.transfer_source(varchar, integer), erp.transfer_create(varchar, jsonb, jsonb),
  erp.inv_count_create(varchar, jsonb), erp.inv_count_save(varchar, integer, jsonb), erp.inv_count_submit(varchar, integer, text),
  erp.inv_count_decide(varchar, integer, text, text), erp.inv_count_cancel(varchar, integer, text), erp.inv_count_info(varchar, integer),
  erp.lot_history(varchar, integer), erp.bin_save(varchar, jsonb), erp.warehouse_inv_set(varchar, text, jsonb),
  erp.inventory_reason_save(varchar, jsonb), erp.inventory_setting_set(varchar, jsonb), erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.inventory_setup(varchar), erp.inventory_doc_checks(varchar, integer, jsonb, jsonb),
  erp.inventory_doc_create(varchar, integer, jsonb, jsonb, text), erp.inventory_doc_decide(varchar, integer, integer, text, text),
  erp.inventory_doc_cancel(varchar, integer, integer, text), erp.inventory_doc_info(varchar, integer, integer),
  erp.transfer_checks(varchar, integer, jsonb, jsonb), erp.transfer_request_create(varchar, jsonb, jsonb), erp.transfer_request_cancel(varchar, integer, text),
  erp.transfer_source(varchar, integer), erp.transfer_create(varchar, jsonb, jsonb),
  erp.inv_count_create(varchar, jsonb), erp.inv_count_save(varchar, integer, jsonb), erp.inv_count_submit(varchar, integer, text),
  erp.inv_count_decide(varchar, integer, text, text), erp.inv_count_cancel(varchar, integer, text), erp.inv_count_info(varchar, integer),
  erp.lot_history(varchar, integer), erp.bin_save(varchar, jsonb), erp.warehouse_inv_set(varchar, text, jsonb),
  erp.inventory_reason_save(varchar, jsonb), erp.inventory_setting_set(varchar, jsonb), erp.approval_inbox()
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Stock count variance account in ZZ99's sample chart, and its G/L determination row.
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', '5300', '5300', 'Stock count variance and write-offs (SAMPLE)', '5000', 2, true, 'other', 5, 'AED', false, false, 0, 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, acct_code) DO NOTHING;
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', 'inventory', 'count_variance', '5300', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = '5300')
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', v.obj, v.prefix, 1, 5
  FROM (VALUES (1250000001, 'TRQ-26-'), (67, 'TR-26-'), (59, 'GRC-26-'), (60, 'GI-26-'), (1470000065, 'IC-26-')) AS v(obj, prefix)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

INSERT INTO erp.inventory_setting (company_code, blind_count, note)
SELECT 'ZZ99', true, 'SAMPLE setting for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code) DO NOTHING;

INSERT INTO erp.inventory_reason (company_code, code, name, direction, acct_code, source, note)
SELECT 'ZZ99', v.code, v.name, v.dir, v.acct, 'sample', 'SAMPLE reason for test company ZZ99 only'
  FROM (VALUES ('FOUND', 'Found stock', 'in', '5300'), ('DAMAGE', 'Damaged, written off', 'out', '5300'),
               ('SAMPLE', 'Samples to customers', 'out', '6400'), ('ADJUST', 'Stock adjustment', 'both', '5300')) AS v(code, name, dir, acct)
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = v.acct)
ON CONFLICT (company_code, code) DO NOTHING;

-- Bins in the Jebel Ali store (WH02): turned on the first time only, so a later change in Inventory Setup is kept.
INSERT INTO erp.warehouse_setting (company_code, whs_code, allow_negative, bins_enabled, note)
SELECT 'ZZ99', 'WH02', false, true, 'SAMPLE: bins for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = 'ZZ99' AND whs_code = 'WH02')
   AND NOT EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, whs_code) DO UPDATE SET bins_enabled = true;
INSERT INTO erp.bin_location (company_code, whs_code, bin_code, name)
SELECT 'ZZ99', 'WH02', v.code, v.name || ' (SAMPLE)'
  FROM (VALUES ('WH02-A-01-L1', 'Zone A, rack 01, level 1'), ('WH02-A-01-L2', 'Zone A, rack 01, level 2'),
               ('WH02-B-01-L1', 'Zone B, rack 01, level 1')) AS v(code, name)
 WHERE EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = 'ZZ99' AND whs_code = 'WH02')
ON CONFLICT (company_code, bin_code) DO NOTHING;

-- Goods receipts / issues above 10,000 AED raised by QA · stock need QA · stock manager; a count with any line more than 1 % off
-- (the A7 phase rule) or a total variance above 5,000 AED (the design: "posting with approval above AED 5,000") needs QA · stock manager.
INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', v.obj, v.rule, v.pos, v.lim, v.appr, 1, 'SAMPLE rule for test company ZZ99 only'
  FROM (VALUES (59, 'stock_doc_amount', 'QA_STOCK', 10000, 'QA_STOCK_MGR'), (60, 'stock_doc_amount', 'QA_STOCK', 10000, 'QA_STOCK_MGR'),
               (1470000065, 'count_variance_pct', NULL, 1, 'QA_STOCK_MGR'), (1470000065, 'count_variance_value', NULL, 5000, 'QA_STOCK_MGR')) AS v(obj, rule, pos, lim, appr)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.appr)
   AND (v.pos IS NULL OR EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.pos))
ON CONFLICT (company_code, obj_type, rule_code, (coalesce(position_code, '')), step) DO NOTHING;
