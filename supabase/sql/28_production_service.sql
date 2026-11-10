-- A13 · Production and Service: bills of materials (components, quantities, warehouse, moulds and machines as resources),
-- production orders (planned → released → issue components → report output → closed; release blocked when components are
-- short, naming the purchase order that will arrive), mould shot counts and maintenance schedule, production cost (components +
-- resources, posted through A3), service calls (customer, item / serial, problem, technician, status, solution) with a warranty
-- check from the serial number and the invoice date, equipment cards, service contracts, and spare parts issued through A7's
-- goods issue. Safe to run twice. Does not edit 10–27 (earlier behaviour is changed here with CREATE OR REPLACE).
--
-- Every row made here is Super ERP data (source = 'erp'; ZZ99 seed rows 'sample'). SAP rows are never written.
--
-- Stock documents made by production are ordinary Super ERP stock documents, as in SAP:
--   Issue for production    = goods issue   (obj 60), lines based on the order (base_obj_type 202), line account = WIP
--                             → post_document: Dr WIP / Cr warehouse stock account (at average cost)
--   Receipt from production = goods receipt (obj 59), based on the order, line account = WIP
--                             → post_document: Dr warehouse stock account / Cr WIP (at the order's cost per unit)
--   Resource cost           = post_journal Dr WIP / Cr the resource's absorption account (trans_type 202)
--   Closing the order       = whatever is left in WIP → production variance account (trans_type 202)
-- Cost of one receipt = the share of the components issued and not yet received (qty / quantity still to report; the last
-- receipt takes all that is left) + the resources used for this quantity.
--
-- Objects:
--   erp.production_setting   – WIP account, variance account, mould life warning % (empty for real companies)
--   erp.prod_resource        – moulds, machines, labour as BOM resources; mould attributes from the fixed-asset design
--   erp.mould_maintenance    – maintenance log; view erp.mould_schedule (next due by shots / days, life used)
--   erp.bom / bom_line       – bills of materials (production / assembly / sales kit)
--   erp.prod_order / prod_order_line / prod_resource_use – production orders (SAP object 202)
--   erp.service_setting      – spare-parts reason (A7 inventory_reason) per company
--   erp.warranty_rule        – warranty months per item or item group (empty for real companies)
--   erp.equipment_card       – one card per sold serial number: customer, invoice, warranty dates
--   erp.service_contract / service_contract_line – service contracts (SAP object 190)
--   erp.service_call / service_call_part – service calls (SAP object 191) and the goods issues of their spare parts
--   views                    – bom_list, prod_order_list, mould_schedule, service_call_list, service_contract_list,
--                              equipment_card_list (security_invoker)
--   internal                 – _prd_guard, _svc_guard, _ps_number, _ps_acct_check, _prd_shortages, _prd_lock, _svc_warranty,
--                              _svc_months, _svc_invoice
--   API                      – production_setup, production_setting_set, prod_resource_save, mould_maintenance_record, bom_save,
--                              bom_delete, bom_info, prod_order_create, prod_order_checks, prod_order_release, prod_order_issue,
--                              prod_order_receipt, prod_order_close, prod_order_cancel, prod_order_info, service_setup,
--                              service_setting_set, warranty_rule_save, service_warranty, equipment_card_save,
--                              equipment_card_info, service_contract_save, service_contract_status, service_contract_info,
--                              service_call_save, service_call_status, service_call_parts_issue, service_call_info
--   replaced                 – _adm_doc_types (+ 202 Production Order, 191 Service Call, 190 Service Contract)
--
-- Business values (accounts, resource rates, warranty months, maintenance intervals, numbering, the spare-parts reason) are
-- seeded for the sample company ZZ99 only and marked SAMPLE. Real companies start empty (A13 walkthrough › Needs from Ashif).

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.production_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    wip_acct       varchar(15),                       -- work in progress (issues debit it, receipts credit it)
    variance_acct  varchar(15),                       -- what is left in WIP when an order closes
    life_warn_pct  numeric(5,2),                      -- warn when a mould has used this % of its rated life (NULL = no warning)
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.prod_resource (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    res_code       varchar(30) NOT NULL,
    name           text NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('mould', 'machine', 'labour', 'other')),
    unit           text NOT NULL DEFAULT 'hour' CHECK (unit IN ('shot', 'hour', 'unit')),
    unit_cost      numeric(19,6) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
    acct_code      varchar(15),                       -- absorption account credited with the resource cost
    cavities       integer CHECK (cavities > 0),      -- moulds: parts made per shot
    rated_life_shots bigint CHECK (rated_life_shots > 0),
    shots_done     bigint NOT NULL DEFAULT 0 CHECK (shots_done >= 0),
    location       text,                              -- where the mould is (own plant, factory)
    asset_no       text,                              -- fixed asset number, when the mould is in the asset register
    maint_every_shots bigint CHECK (maint_every_shots > 0),
    maint_every_days  integer CHECK (maint_every_days > 0),
    last_maint_on  date,
    last_maint_shots bigint NOT NULL DEFAULT 0,
    active         boolean NOT NULL DEFAULT true,
    source         text NOT NULL DEFAULT 'erp',
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, res_code)
);

CREATE TABLE IF NOT EXISTS erp.mould_maintenance (
    maint_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    res_code       varchar(30) NOT NULL,
    done_on        date NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('preventive', 'repair', 'inspection')),
    shots_at       bigint NOT NULL,
    note           text,
    done_by        uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, res_code) REFERENCES erp.prod_resource ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.bom (
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,              -- the finished (parent) item
    bom_type       text NOT NULL DEFAULT 'production' CHECK (bom_type IN ('production', 'assembly', 'sales')),
    qty            numeric(19,6) NOT NULL DEFAULT 1 CHECK (qty > 0),   -- the lines make this many of the parent
    whs_code       varchar(8),                        -- where the parent is received
    active         boolean NOT NULL DEFAULT true,
    note           text,
    source         text NOT NULL DEFAULT 'erp',
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, item_code),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item
);

CREATE TABLE IF NOT EXISTS erp.bom_line (
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    line_num       integer NOT NULL,
    comp_kind      text NOT NULL CHECK (comp_kind IN ('item', 'resource')),
    comp_code      varchar(50) NOT NULL,              -- component item or resource code
    qty            numeric(19,6) NOT NULL CHECK (qty > 0),   -- per bom.qty of the parent
    whs_code       varchar(8),                        -- items: issued from this warehouse
    note           text,
    PRIMARY KEY (company_code, item_code, line_num),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.bom ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.prod_order (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    order_id       integer NOT NULL,                  -- from erp_doc_entry_seq (base_doc_entry of its stock documents)
    doc_no         text NOT NULL,
    item_code      varchar(50) NOT NULL,
    planned_qty    numeric(19,6) NOT NULL CHECK (planned_qty > 0),
    completed_qty  numeric(19,6) NOT NULL DEFAULT 0,
    whs_code       varchar(8) NOT NULL,
    post_date      date NOT NULL,
    due_date       date NOT NULL,
    state          text NOT NULL DEFAULT 'planned' CHECK (state IN ('planned', 'released', 'closed', 'cancelled')),
    comments       text,
    issued_value   numeric(19,2) NOT NULL DEFAULT 0,  -- components issued (Dr WIP)
    comp_received_value numeric(19,2) NOT NULL DEFAULT 0,  -- component share already received into stock
    resource_value numeric(19,2) NOT NULL DEFAULT 0,  -- resources charged (Dr WIP)
    received_value numeric(19,2) NOT NULL DEFAULT 0,  -- finished stock received (Cr WIP)
    variance_value numeric(19,2),                     -- left in WIP at close (posted to the variance account)
    variance_trans integer,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    released_by    uuid,
    released_at    timestamptz,
    closed_by      uuid,
    closed_at      timestamptz,
    cancelled_by   uuid,
    cancelled_at   timestamptz,
    cancel_note    text,
    PRIMARY KEY (company_code, order_id),
    UNIQUE (company_code, doc_no),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item
);

CREATE TABLE IF NOT EXISTS erp.prod_order_line (
    company_code   varchar(8) NOT NULL,
    order_id       integer NOT NULL,
    line_num       integer NOT NULL,
    comp_kind      text NOT NULL CHECK (comp_kind IN ('item', 'resource')),
    comp_code      varchar(50) NOT NULL,
    base_qty       numeric(19,6) NOT NULL,            -- per one parent unit
    planned_qty    numeric(19,6) NOT NULL,
    issued_qty     numeric(19,6) NOT NULL DEFAULT 0,  -- items issued, or resource units used
    issued_value   numeric(19,2) NOT NULL DEFAULT 0,
    whs_code       varchar(8),
    PRIMARY KEY (company_code, order_id, line_num),
    FOREIGN KEY (company_code, order_id) REFERENCES erp.prod_order ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.prod_resource_use (
    use_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    order_id       integer NOT NULL,
    line_num       integer NOT NULL,
    receipt_entry  integer,                           -- the receipt from production (obj 59) it belongs to
    res_code       varchar(30) NOT NULL,
    qty            numeric(19,6) NOT NULL,
    unit_cost      numeric(19,6) NOT NULL,
    amount         numeric(19,2) NOT NULL,
    trans_id       integer,
    doc_date       date NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, order_id) REFERENCES erp.prod_order ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.service_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    parts_reason_code varchar(20),                    -- A7 goods issue reason used for spare parts (its account takes the cost)
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.warranty_rule (
    rule_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    item_code      varchar(50),
    group_code     integer,
    months         integer NOT NULL CHECK (months > 0),
    note           text,
    source         text NOT NULL DEFAULT 'erp',
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CHECK ((item_code IS NULL) <> (group_code IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS warranty_rule_key ON erp.warranty_rule (company_code, coalesce(item_code, ''), coalesce(group_code, -1));

CREATE TABLE IF NOT EXISTS erp.equipment_card (
    card_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    serial_no      text NOT NULL,
    card_code      varchar(20) NOT NULL,              -- the customer who has the unit
    invoice_entry  integer,                           -- the A/R invoice (obj 13) that sold it
    sold_on        date,
    warranty_start date,
    warranty_end   date,
    note           text,
    source         text NOT NULL DEFAULT 'erp',
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_code, item_code, serial_no),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item
);

CREATE TABLE IF NOT EXISTS erp.service_contract (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    contract_id    integer NOT NULL,
    doc_no         text NOT NULL,
    card_code      varchar(20) NOT NULL,
    starts_on      date NOT NULL,
    ends_on        date NOT NULL,
    response_hours numeric(9,2) CHECK (response_hours >= 0),
    covers_parts   boolean NOT NULL DEFAULT false,
    covers_labour  boolean NOT NULL DEFAULT false,
    covers_travel  boolean NOT NULL DEFAULT false,
    all_items      boolean NOT NULL DEFAULT false,   -- covers every item the customer has
    terms          text,
    state          text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'active', 'ended', 'cancelled')),
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    activated_by   uuid,
    activated_at   timestamptz,
    ended_by       uuid,
    ended_at       timestamptz,
    end_note       text,
    PRIMARY KEY (company_code, contract_id),
    UNIQUE (company_code, doc_no),
    CHECK (ends_on >= starts_on)
);

CREATE TABLE IF NOT EXISTS erp.service_contract_line (
    company_code   varchar(8) NOT NULL,
    contract_id    integer NOT NULL,
    line_num       integer NOT NULL,
    item_code      varchar(50) NOT NULL,
    serial_no      text,                              -- NULL = every unit of the item
    note           text,
    PRIMARY KEY (company_code, contract_id, line_num),
    FOREIGN KEY (company_code, contract_id) REFERENCES erp.service_contract ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.service_call (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    call_id        integer NOT NULL,
    doc_no         text NOT NULL,
    card_code      varchar(20) NOT NULL,
    contact        text,
    phone          text,
    item_code      varchar(50),
    serial_no      text,
    invoice_entry  integer,
    equipment_card_id integer,
    contract_id    integer,
    subject        text NOT NULL,
    problem        text,
    priority       text NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
    technician     uuid,
    technician_name text,
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved', 'closed', 'cancelled')),
    solution       text,
    warranty_status text,                             -- in_warranty | out_of_warranty | contract | no_rule | unknown | none
    warranty_end   date,
    warranty_note  text,
    flagged        boolean NOT NULL DEFAULT false,    -- out of warranty (and not under contract)
    opened_at      timestamptz NOT NULL DEFAULT now(),
    due_by         timestamptz,                       -- from the contract's response time
    resolved_at    timestamptz,
    closed_at      timestamptz,
    cancel_note    text,
    created_by     uuid NOT NULL,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, call_id),
    UNIQUE (company_code, doc_no)
);

CREATE TABLE IF NOT EXISTS erp.service_call_part (
    company_code   varchar(8) NOT NULL,
    call_id        integer NOT NULL,
    obj_type       integer NOT NULL DEFAULT 60,
    doc_entry      integer NOT NULL,
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, obj_type, doc_entry),
    FOREIGN KEY (company_code, call_id) REFERENCES erp.service_call ON DELETE CASCADE
);

-- ============ Read access (no write grants: writes go through the functions below) ============
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['production_setting', 'prod_resource', 'mould_maintenance', 'bom', 'bom_line', 'prod_order', 'prod_order_line',
                           'prod_resource_use', 'service_setting', 'warranty_rule', 'equipment_card', 'service_contract',
                           'service_contract_line', 'service_call', 'service_call_part'] LOOP
    EXECUTE format('ALTER TABLE erp.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON erp.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON erp.%I TO authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (%s))', t || '_read', t,
      CASE WHEN t IN ('production_setting', 'prod_resource', 'mould_maintenance', 'bom', 'bom_line', 'prod_order', 'prod_order_line', 'prod_resource_use')
           THEN '(SELECT erp.can_read(''production'')) OR (SELECT erp.can_read(''inventory''))'
           ELSE '(SELECT erp.can_read(''service'')) OR (SELECT erp.can_read(''sales''))' END);
  END LOOP;
END $$;

-- ============ Views ============
-- The list views run with the owner's rights and carry the module rule in WHERE (as A9's HR views do): Production and Service
-- users see item and customer names on their own records even when their position does not include Inventory or Business Partners.
CREATE OR REPLACE VIEW erp.bom_list WITH (security_invoker = false) AS
SELECT b.company_code, b.item_code, i.name AS item_name, b.bom_type, b.qty, b.whs_code, b.active, b.source, b.updated_at,
       (SELECT count(*) FROM erp.bom_line l WHERE l.company_code = b.company_code AND l.item_code = b.item_code AND l.comp_kind = 'item') AS n_items,
       (SELECT count(*) FROM erp.bom_line l WHERE l.company_code = b.company_code AND l.item_code = b.item_code AND l.comp_kind = 'resource') AS n_resources,
       (SELECT string_agg(l.comp_code, ', ' ORDER BY l.line_num) FROM erp.bom_line l
         WHERE l.company_code = b.company_code AND l.item_code = b.item_code AND l.comp_kind = 'resource') AS resources
  FROM erp.bom b
  LEFT JOIN erp.item i ON i.company_code = b.company_code AND i.item_code = b.item_code
 WHERE erp.can_see(b.company_code) AND ((SELECT erp.can_read('production')) OR (SELECT erp.can_read('inventory')));

CREATE OR REPLACE VIEW erp.prod_order_list WITH (security_invoker = false) AS
SELECT o.company_code, o.order_id, o.doc_no, o.item_code, i.name AS item_name, o.planned_qty, o.completed_qty, o.whs_code, o.post_date,
       o.due_date, o.state, (o.state IN ('planned', 'released') AND o.due_date < current_date) AS late,
       o.issued_value, o.resource_value, o.received_value, o.variance_value, o.comments, o.created_at
  FROM erp.prod_order o
  LEFT JOIN erp.item i ON i.company_code = o.company_code AND i.item_code = o.item_code
 WHERE erp.can_see(o.company_code) AND ((SELECT erp.can_read('production')) OR (SELECT erp.can_read('inventory')));

CREATE OR REPLACE VIEW erp.mould_schedule WITH (security_invoker = true) AS
SELECT r.company_code, r.res_code, r.name, r.kind, r.unit, r.unit_cost, r.cavities, r.rated_life_shots, r.shots_done, r.location, r.asset_no,
       r.maint_every_shots, r.maint_every_days, r.last_maint_on, r.last_maint_shots, r.active,
       r.shots_done - r.last_maint_shots AS shots_since,
       CASE WHEN r.maint_every_shots IS NOT NULL THEN r.last_maint_shots + r.maint_every_shots END AS next_due_shots,
       CASE WHEN r.maint_every_days IS NOT NULL AND r.last_maint_on IS NOT NULL THEN r.last_maint_on + r.maint_every_days END AS next_due_on,
       CASE WHEN r.rated_life_shots IS NOT NULL THEN round(100.0 * r.shots_done / r.rated_life_shots, 1) END AS life_pct,
       CASE WHEN r.maint_every_shots IS NULL AND r.maint_every_days IS NULL THEN 'not_scheduled'
            WHEN (r.maint_every_shots IS NOT NULL AND r.shots_done - r.last_maint_shots >= r.maint_every_shots)
              OR (r.maint_every_days IS NOT NULL AND r.last_maint_on IS NOT NULL AND r.last_maint_on + r.maint_every_days < current_date) THEN 'overdue'
            ELSE 'ok' END AS maint_status,
       (r.rated_life_shots IS NOT NULL AND s.life_warn_pct IS NOT NULL AND 100.0 * r.shots_done / r.rated_life_shots >= s.life_warn_pct) AS life_warn,
       r.source
  FROM erp.prod_resource r
  LEFT JOIN erp.production_setting s ON s.company_code = r.company_code;

CREATE OR REPLACE VIEW erp.service_call_list WITH (security_invoker = false) AS
SELECT c.company_code, c.call_id, c.doc_no, c.card_code, bp.name AS card_name, c.item_code, i.name AS item_name, c.serial_no, c.subject,
       c.priority, c.status, c.technician, c.technician_name, c.warranty_status, c.warranty_end, c.flagged, c.opened_at, c.due_by,
       (c.status IN ('open', 'in_progress') AND c.due_by IS NOT NULL AND c.due_by < now()) AS overdue, c.resolved_at, c.closed_at
  FROM erp.service_call c
  LEFT JOIN erp.business_partner bp ON bp.company_code = c.company_code AND bp.card_code = c.card_code
  LEFT JOIN erp.item i ON i.company_code = c.company_code AND i.item_code = c.item_code
 WHERE erp.can_see(c.company_code) AND ((SELECT erp.can_read('service')) OR (SELECT erp.can_read('sales')));

CREATE OR REPLACE VIEW erp.service_contract_list WITH (security_invoker = false) AS
SELECT k.company_code, k.contract_id, k.doc_no, k.card_code, bp.name AS card_name, k.starts_on, k.ends_on, k.response_hours,
       k.covers_parts, k.covers_labour, k.covers_travel, k.all_items, k.state,
       (k.state = 'active' AND k.ends_on < current_date) AS expired,
       (SELECT count(*) FROM erp.service_contract_line l WHERE l.company_code = k.company_code AND l.contract_id = k.contract_id) AS n_lines
  FROM erp.service_contract k
  LEFT JOIN erp.business_partner bp ON bp.company_code = k.company_code AND bp.card_code = k.card_code
 WHERE erp.can_see(k.company_code) AND ((SELECT erp.can_read('service')) OR (SELECT erp.can_read('sales')));

CREATE OR REPLACE VIEW erp.equipment_card_list WITH (security_invoker = false) AS
SELECT e.company_code, e.card_id, e.item_code, i.name AS item_name, e.serial_no, e.card_code, bp.name AS card_name, e.invoice_entry,
       e.sold_on, e.warranty_start, e.warranty_end,
       CASE WHEN e.warranty_end IS NULL THEN 'unknown' WHEN e.warranty_end >= current_date THEN 'in_warranty' ELSE 'out_of_warranty' END AS warranty_status,
       (SELECT count(*) FROM erp.service_call c WHERE c.company_code = e.company_code AND c.equipment_card_id = e.card_id) AS n_calls,
       e.source
  FROM erp.equipment_card e
  LEFT JOIN erp.item i ON i.company_code = e.company_code AND i.item_code = e.item_code
  LEFT JOIN erp.business_partner bp ON bp.company_code = e.company_code AND bp.card_code = e.card_code
 WHERE erp.can_see(e.company_code) AND ((SELECT erp.can_read('service')) OR (SELECT erp.can_read('sales')));

REVOKE ALL ON erp.bom_list, erp.prod_order_list, erp.mould_schedule, erp.service_call_list, erp.service_contract_list, erp.equipment_card_list FROM PUBLIC, anon;
GRANT SELECT ON erp.bom_list, erp.prod_order_list, erp.mould_schedule, erp.service_call_list, erp.service_contract_list, erp.equipment_card_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
-- Who is calling, and may they read (Production or Inventory) or change (Production full) production in this company?
CREATE OR REPLACE FUNCTION erp._prd_guard(p_company varchar, p_write boolean, p_what text DEFAULT 'production') RETURNS erp.app_user
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
  IF NOT (erp.can_read('production') OR erp.can_read('inventory')) THEN
    RAISE EXCEPTION 'Your position does not include Production. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_write AND NOT erp.can_write('production') THEN
    RAISE EXCEPTION 'You have read-only access to Production. Ask the system admin for full access to %.', p_what USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Same for Service (read: Service or Sales; change: Service full).
CREATE OR REPLACE FUNCTION erp._svc_guard(p_company varchar, p_write boolean, p_what text DEFAULT 'service') RETURNS erp.app_user
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
  IF NOT (erp.can_read('service') OR erp.can_read('sales')) THEN
    RAISE EXCEPTION 'Your position does not include Service. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_write AND NOT erp.can_write('service') THEN
    RAISE EXCEPTION 'You have read-only access to Service. Ask the system admin for full access to %.', p_what USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Next number for a production order (202), service call (191) or service contract (190), row-locked.
CREATE OR REPLACE FUNCTION erp._ps_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns erp.number_series;
BEGIN
  SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      CASE p_obj WHEN 202 THEN 'Production order' WHEN 191 THEN 'Service call' WHEN 190 THEN 'Service contract' ELSE 'Document' END,
      p_company USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.number_series SET next_num = next_num + 1 WHERE company_code = p_company AND obj_type = p_obj;
  RETURN jsonb_build_object('num', ns.next_num, 'no', ns.prefix || lpad(ns.next_num::text, ns.pad, '0'), 'entry', nextval('erp.erp_doc_entry_seq'));
END $$;

-- NULL when the account can take postings; otherwise the problem in one sentence.
CREATE OR REPLACE FUNCTION erp._ps_acct_check(p_company varchar, p_acct text, p_label text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  a erp.account;
BEGIN
  IF p_acct IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO a FROM erp.account WHERE company_code = p_company AND acct_code = p_acct;
  IF NOT FOUND THEN
    RETURN format('%s: account %s does not exist in company %s.', p_label, p_acct, p_company);
  ELSIF NOT coalesce(a.postable, false) THEN
    RETURN format('%s: account %s is a title account. Choose an account you can post to.', p_label, p_acct);
  ELSIF coalesce(a.is_control, false) THEN
    RETURN format('%s: account %s is a control account (customers or suppliers). Choose another account.', p_label, p_acct);
  ELSIF coalesce(a.frozen, false) THEN
    RETURN format('%s: account %s is frozen. Choose another account.', p_label, p_acct);
  END IF;
  RETURN NULL;
END $$;

-- Component shortages of a production order: what is still to issue against what is free in the warehouse (on hand − committed
-- to sales − still to issue on other released orders), each with the next open purchase order for the item.
CREATE OR REPLACE FUNCTION erp._prd_shortages(p_company varchar, p_order integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('line_num', s.line_num, 'item_code', s.comp_code, 'item_name', s.item_name, 'whs_code', s.whs_code,
                                               'needed', s.needed, 'available', s.avail, 'short', s.needed - greatest(s.avail, 0), 'next_po', s.po)
                            ORDER BY s.line_num), '[]'::jsonb)
    FROM (
      SELECT l.line_num, l.comp_code, i.name AS item_name, l.whs_code, l.planned_qty - l.issued_qty AS needed,
             coalesce(sb.on_hand, 0) - coalesce(sb.committed, 0)
               - coalesce((SELECT sum(greatest(ol.planned_qty - ol.issued_qty, 0)) FROM erp.prod_order_line ol
                             JOIN erp.prod_order oo ON oo.company_code = ol.company_code AND oo.order_id = ol.order_id
                            WHERE ol.company_code = l.company_code AND ol.comp_kind = 'item' AND ol.comp_code = l.comp_code
                              AND ol.whs_code = l.whs_code AND oo.state = 'released' AND oo.order_id <> l.order_id), 0) AS avail,
             (SELECT jsonb_build_object('doc_entry', p.doc_entry, 'doc_no', p.doc_no, 'date', p.arrives, 'qty', p.open_qty)
                FROM (SELECT d.doc_entry, coalesce(w.doc_no, d.doc_num::text) AS doc_no, pl.open_qty,
                             coalesce((SELECT min(sh.eta) FROM erp.purchase_shipment_line sl
                                         JOIN erp.purchase_shipment sh ON sh.shipment_id = sl.shipment_id
                                        WHERE sh.company_code = d.company_code AND sh.po_doc_entry = d.doc_entry AND sl.po_line = pl.line_num
                                          AND sl.qty > coalesce(sl.received_qty, 0) AND sh.eta IS NOT NULL), d.due_date) AS arrives
                        FROM erp.document_line pl
                        JOIN erp.document d ON d.company_code = pl.company_code AND d.obj_type = pl.obj_type AND d.doc_entry = pl.doc_entry
                        LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
                       WHERE pl.company_code = l.company_code AND pl.obj_type = 22 AND pl.item_code = l.comp_code AND d.status = 'open'
                         AND coalesce(pl.open_qty, 0) > 0 AND coalesce(pl.line_status, 'O') = 'O') p
               ORDER BY p.arrives NULLS LAST, p.doc_entry LIMIT 1) AS po
        FROM erp.prod_order_line l
        LEFT JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.comp_code
        LEFT JOIN erp.stock_balance sb ON sb.company_code = l.company_code AND sb.item_code = l.comp_code AND sb.whs_code = l.whs_code
       WHERE l.company_code = p_company AND l.order_id = p_order AND l.comp_kind = 'item' AND l.planned_qty > l.issued_qty) s
   WHERE s.needed > greatest(s.avail, 0)
$$;

-- One shortage as a sentence ("SMP-RAW-PP is short by 40 in WH01 (needs 100, free 60). Purchase order PO-26-00002 brings 500 on 13 Nov 2026.").
CREATE OR REPLACE FUNCTION erp._prd_short_msg(s jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT format('%s is short by %s in %s (needs %s, free %s). ', s->>'item_code', trim_scale((s->>'short')::numeric), s->>'whs_code',
                trim_scale((s->>'needed')::numeric), trim_scale(greatest((s->>'available')::numeric, 0)))
      || CASE WHEN s->'next_po' IS NULL OR jsonb_typeof(s->'next_po') = 'null' THEN 'No open purchase order brings it yet.'
              ELSE format('Purchase order %s brings %s%s.', s->'next_po'->>'doc_no', trim_scale((s->'next_po'->>'qty')::numeric),
                          coalesce(' on ' || to_char((s->'next_po'->>'date')::date, 'DD Mon YYYY'), '')) END
$$;

CREATE OR REPLACE FUNCTION erp._prd_lock(p_company varchar, p_order integer) RETURNS erp.prod_order
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  o erp.prod_order;
BEGIN
  SELECT * INTO o FROM erp.prod_order WHERE company_code = p_company AND order_id = p_order FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Production order % was not found in company %.', p_order, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN o;
END $$;

-- The production WIP account of a company, or a clear refusal.
CREATE OR REPLACE FUNCTION erp._prd_wip(p_company varchar) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v text;
BEGIN
  SELECT wip_acct INTO v FROM erp.production_setting WHERE company_code = p_company;
  IF v IS NULL THEN
    RAISE EXCEPTION 'The work-in-progress account is not set for company %. Ask Finance to set it in Production Setup.', p_company
      USING ERRCODE = 'P0001';
  END IF;
  RETURN v;
END $$;

-- A Super ERP stock document (59 receipt / 60 issue) made by production or service, already validated. Writes document,
-- doc_workflow (approved), lines (with base and account) and line details. Returns {entry, no}.
-- p_lines: [{line_num, item_code, description, uom, qty, price, whs_code, acct_code, base_line, bin_code, lots}]
CREATE OR REPLACE FUNCTION erp._prd_stock_doc(p_company varchar, p_obj integer, p_date date, p_ref text, p_comments text, p_base_entry integer,
                                              p_lines jsonb, p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb    jsonb;
  v_e   integer;
  x     jsonb;
  v_cur text;
  v_whs text;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT CASE WHEN count(DISTINCT value->>'whs_code') = 1 THEN min(value->>'whs_code') END INTO v_whs FROM jsonb_array_elements(p_lines);
  nb := erp._inv_number(p_company, p_obj);
  v_e := (nb->>'entry')::integer;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, customer_ref, currency, fx_rate,
                            total, vat_total, paid, from_whs, to_whs, comments, created_on, source)
  VALUES (p_company, p_obj, v_e, (nb->>'num')::integer, CASE p_obj WHEN 59 THEN 'goods_receipt' ELSE 'goods_issue' END, 'closed', p_date, p_date, p_date,
          p_ref, v_cur, 1, 0, 0, 0, CASE WHEN p_obj = 60 THEN v_whs END, CASE WHEN p_obj = 59 THEN v_whs END, p_comments, current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code)
  VALUES (p_company, p_obj, v_e, nb->>'no', 'approved', p_user, p_user, now(), now(), v_whs);
  FOR x IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, vat, whs_code, acct_code, base_obj_type, base_doc_entry, base_line, line_status,
                                   gross_buy_price, stock_price)
    VALUES (p_company, p_obj, v_e, (x->>'line_num')::integer, x->>'item_code', x->>'description', (x->>'qty')::numeric, 0, x->>'uom',
            (x->>'price')::numeric, v_cur, 0, round((x->>'qty')::numeric * (x->>'price')::numeric, 2), 0, x->>'whs_code', x->>'acct_code',
            202, p_base_entry, (x->>'base_line')::integer, 'C', (x->>'price')::numeric, (x->>'price')::numeric);
    INSERT INTO erp.inv_line_detail (company_code, obj_type, doc_entry, line_num, bin_code, lots)
    VALUES (p_company, p_obj, v_e, (x->>'line_num')::integer, nullif(x->>'bin_code', ''), coalesce(x->'lots', '[]'::jsonb));
    PERFORM erp._stock_move(p_company, x->>'item_code', x->>'whs_code', CASE WHEN p_obj = 59 THEN (x->>'qty')::numeric ELSE 0 END,
                            CASE WHEN p_obj = 59 THEN 0 ELSE (x->>'qty')::numeric END, (x->>'price')::numeric, p_obj, v_e, (x->>'line_num')::integer, p_date);
    PERFORM erp._inv_bin_apply(p_company, x->>'whs_code', nullif(x->>'bin_code', ''), x->>'item_code', CASE WHEN p_obj = 59 THEN (x->>'qty')::numeric ELSE 0 END,
                               CASE WHEN p_obj = 59 THEN 0 ELSE (x->>'qty')::numeric END, p_obj, v_e, (x->>'line_num')::integer, p_date);
    IF coalesce((x->>'serial')::boolean, false) OR coalesce((x->>'batch')::boolean, false) THEN
      PERFORM erp._inv_lot_apply(p_company, x->>'item_code', CASE WHEN (x->>'serial')::boolean THEN 'S' ELSE 'B' END, x->>'whs_code', x->'lots',
                                 CASE WHEN p_obj = 59 THEN 1 ELSE -1 END, p_obj, v_e, (x->>'line_num')::integer, p_date, p_user);
    END IF;
  END LOOP;
  PERFORM erp._sd_retotal(p_company, p_obj, v_e);
  RETURN jsonb_build_object('entry', v_e, 'no', nb->>'no');
END $$;

-- ============ Production: setup ============
CREATE OR REPLACE FUNCTION erp.production_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  s erp.production_setting;
BEGIN
  u := erp._prd_guard(p_company, false);
  SELECT * INTO s FROM erp.production_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', w.whs_code, 'name', w.name,
                              'bins', coalesce((SELECT bins_enabled FROM erp.warehouse_setting ws WHERE ws.company_code = w.company_code AND ws.whs_code = w.whs_code), false))
                              ORDER BY w.whs_code) FROM erp.warehouse w WHERE w.company_code = p_company AND w.active AND NOT coalesce(w.locked, false)), '[]'::jsonb),
    'resources', coalesce((SELECT jsonb_agg(jsonb_build_object('code', r.res_code, 'name', r.name, 'kind', r.kind, 'unit', r.unit, 'unit_cost', r.unit_cost,
                              'acct_code', r.acct_code, 'active', r.active) ORDER BY r.res_code) FROM erp.prod_resource r WHERE r.company_code = p_company), '[]'::jsonb),
    'accounts', CASE WHEN erp.can_read('finance') OR erp.can_write('production') THEN coalesce((SELECT jsonb_agg(jsonb_build_object('code', a.acct_code, 'name', a.name) ORDER BY a.acct_code)
                   FROM erp.account a WHERE a.company_code = p_company AND a.postable AND NOT coalesce(a.is_control, false) AND NOT coalesce(a.frozen, false)), '[]'::jsonb) ELSE '[]'::jsonb END,
    'setting', jsonb_build_object('wip_acct', s.wip_acct, 'variance_acct', s.variance_acct, 'life_warn_pct', s.life_warn_pct, 'note', s.note),
    'numbering', (SELECT prefix FROM erp.number_series WHERE company_code = p_company AND obj_type = 202 AND active),
    'can_write', erp.can_write('production'),
    'can_finance', erp.can_write('finance'));
END $$;

-- p_setting: {wip_acct, variance_acct, life_warn_pct, note}. Keys left out keep their value. Accounts also need Financials full.
CREATE OR REPLACE FUNCTION erp.production_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  old   erp.production_setting;
  v_wip text;
  v_var text;
  v_pct numeric;
  v_msg text;
BEGIN
  u := erp._prd_guard(p_company, true, 'change production settings');
  SELECT * INTO old FROM erp.production_setting WHERE company_code = p_company;
  v_wip := CASE WHEN p_setting ? 'wip_acct' THEN nullif(btrim(p_setting->>'wip_acct'), '') ELSE old.wip_acct END;
  v_var := CASE WHEN p_setting ? 'variance_acct' THEN nullif(btrim(p_setting->>'variance_acct'), '') ELSE old.variance_acct END;
  IF (v_wip IS DISTINCT FROM old.wip_acct OR v_var IS DISTINCT FROM old.variance_acct) AND NOT erp.can_write('finance') THEN
    RAISE EXCEPTION 'Changing the production accounts also needs Financials full access.' USING ERRCODE = '42501';
  END IF;
  v_msg := coalesce(erp._ps_acct_check(p_company, v_wip, 'Work in progress'), erp._ps_acct_check(p_company, v_var, 'Production variance'));
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;
  IF v_wip IS NOT NULL AND v_wip = v_var THEN
    RAISE EXCEPTION 'The work-in-progress and variance accounts must be different.' USING ERRCODE = 'P0001';
  END IF;
  IF p_setting ? 'life_warn_pct' THEN
    v_pct := erp._num(p_setting->>'life_warn_pct');
    IF nullif(btrim(p_setting->>'life_warn_pct'), '') IS NOT NULL AND (v_pct IS NULL OR v_pct <= 0 OR v_pct > 100) THEN
      RAISE EXCEPTION 'The mould life warning must be a percentage between 1 and 100.' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    v_pct := old.life_warn_pct;
  END IF;
  INSERT INTO erp.production_setting (company_code, wip_acct, variance_acct, life_warn_pct, note, updated_by, updated_at)
  VALUES (p_company, v_wip, v_var, v_pct, CASE WHEN p_setting ? 'note' THEN nullif(btrim(p_setting->>'note'), '') ELSE old.note END, u.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET wip_acct = EXCLUDED.wip_acct, variance_acct = EXCLUDED.variance_acct, life_warn_pct = EXCLUDED.life_warn_pct,
    note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'production_setting_set', 'production_setting', p_company,
          jsonb_build_object('before', to_jsonb(old) - 'updated_by' - 'updated_at', 'wip_acct', v_wip, 'variance_acct', v_var, 'life_warn_pct', v_pct));
  RETURN jsonb_build_object('wip_acct', v_wip, 'variance_acct', v_var, 'life_warn_pct', v_pct);
END $$;

-- p_res: {res_code, name, kind, unit, unit_cost, acct_code, cavities, rated_life_shots, shots_done (new only), location, asset_no,
--         maint_every_shots, maint_every_days, last_maint_on, active, note, edit: true to change an existing one}.
-- Changing the account needs Financials full.
CREATE OR REPLACE FUNCTION erp.prod_resource_save(p_company varchar, p_res jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  old    erp.prod_resource;
  v_code text := upper(nullif(btrim(p_res->>'res_code'), ''));
  v_name text := nullif(btrim(p_res->>'name'), '');
  v_kind text := coalesce(nullif(btrim(p_res->>'kind'), ''), 'machine');
  v_unit text := coalesce(nullif(btrim(p_res->>'unit'), ''), CASE WHEN coalesce(nullif(btrim(p_res->>'kind'), ''), 'machine') = 'mould' THEN 'shot' ELSE 'hour' END);
  v_cost numeric := coalesce(erp._num(p_res->>'unit_cost'), 0);
  v_acct text := nullif(btrim(p_res->>'acct_code'), '');
  v_edit boolean := coalesce((p_res->>'edit')::boolean, false);
  v_msg  text;
  v_int  bigint;
  v_min  integer;
  k      text;
BEGIN
  u := erp._prd_guard(p_company, true, 'change resources and moulds');
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Enter the resource code.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.prod_resource WHERE company_code = p_company AND res_code = v_code;
  IF FOUND AND NOT v_edit THEN
    RAISE EXCEPTION 'Resource % already exists. Open it to change it.', v_code USING ERRCODE = 'P0001';
  ELSIF NOT FOUND AND v_edit THEN
    RAISE EXCEPTION 'Resource % was not found in company %.', v_code, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the resource name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind NOT IN ('mould', 'machine', 'labour', 'other') THEN
    RAISE EXCEPTION 'Choose the kind: mould, machine, labour or other.' USING ERRCODE = 'P0001';
  END IF;
  IF v_unit NOT IN ('shot', 'hour', 'unit') THEN
    RAISE EXCEPTION 'Choose the unit: shot, hour or unit.' USING ERRCODE = 'P0001';
  END IF;
  IF v_cost < 0 THEN
    RAISE EXCEPTION 'The cost per % must be zero or more.', v_unit USING ERRCODE = 'P0001';
  END IF;
  IF v_acct IS DISTINCT FROM old.acct_code AND NOT erp.can_write('finance') THEN
    RAISE EXCEPTION 'Changing the resource account also needs Financials full access.' USING ERRCODE = '42501';
  END IF;
  v_msg := erp._ps_acct_check(p_company, v_acct, 'Resource account');
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;
  IF v_cost > 0 AND v_acct IS NULL THEN
    RAISE EXCEPTION 'Resource % has a cost, so it needs the account its cost is credited to. Ask Finance to set it.', v_code USING ERRCODE = 'P0001';
  END IF;
  FOREACH k IN ARRAY ARRAY['cavities', 'rated_life_shots', 'maint_every_shots', 'maint_every_days', 'shots_done'] LOOP
    IF nullif(btrim(p_res->>k), '') IS NOT NULL THEN
      v_int := erp._num(p_res->>k);
      v_min := CASE WHEN k = 'shots_done' THEN 0 ELSE 1 END;
      IF v_int IS NULL OR v_int < v_min OR v_int <> erp._num(p_res->>k) THEN
        RAISE EXCEPTION '%', CASE k WHEN 'cavities' THEN 'Cavities must be a whole number above zero.'
                                    WHEN 'rated_life_shots' THEN 'The rated life must be a whole number of shots above zero.'
                                    WHEN 'maint_every_shots' THEN 'Maintenance every n shots must be a whole number above zero.'
                                    WHEN 'maint_every_days' THEN 'Maintenance every n days must be a whole number above zero.'
                                    ELSE 'Shots done must be a whole number, zero or more.' END USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END LOOP;
  IF old.res_code IS NULL THEN
    INSERT INTO erp.prod_resource (company_code, res_code, name, kind, unit, unit_cost, acct_code, cavities, rated_life_shots, shots_done, location, asset_no,
                                   maint_every_shots, maint_every_days, last_maint_on, last_maint_shots, active, note, updated_by)
    VALUES (p_company, v_code, v_name, v_kind, v_unit, v_cost, v_acct, erp._num(p_res->>'cavities')::integer, erp._num(p_res->>'rated_life_shots')::bigint,
            coalesce(erp._num(p_res->>'shots_done')::bigint, 0), nullif(btrim(p_res->>'location'), ''), nullif(btrim(p_res->>'asset_no'), ''),
            erp._num(p_res->>'maint_every_shots')::bigint, erp._num(p_res->>'maint_every_days')::integer, erp._date(p_res->>'last_maint_on'),
            coalesce(erp._num(p_res->>'shots_done')::bigint, 0), coalesce((p_res->>'active')::boolean, true), nullif(btrim(p_res->>'note'), ''), u.user_id);
  ELSE
    -- Shots done only change through receipts from production (the counter is the mould's history).
    UPDATE erp.prod_resource SET name = v_name, kind = v_kind, unit = v_unit, unit_cost = v_cost, acct_code = v_acct,
           cavities = erp._num(p_res->>'cavities')::integer, rated_life_shots = erp._num(p_res->>'rated_life_shots')::bigint,
           location = nullif(btrim(p_res->>'location'), ''), asset_no = nullif(btrim(p_res->>'asset_no'), ''),
           maint_every_shots = erp._num(p_res->>'maint_every_shots')::bigint, maint_every_days = erp._num(p_res->>'maint_every_days')::integer,
           active = coalesce((p_res->>'active')::boolean, active), note = nullif(btrim(p_res->>'note'), ''), updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND res_code = v_code;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.res_code IS NULL THEN 'prod_resource_create' ELSE 'prod_resource_update' END, 'prod_resource', v_code,
          jsonb_build_object('before', CASE WHEN old.res_code IS NOT NULL THEN to_jsonb(old) - 'updated_by' - 'updated_at' END, 'input', p_res - 'edit'));
  RETURN jsonb_build_object('res_code', v_code);
END $$;

-- Record maintenance of a mould or machine: resets the schedule counters (shots since and days since).
-- p_maint: {done_on, kind (preventive | repair | inspection), note}
CREATE OR REPLACE FUNCTION erp.mould_maintenance_record(p_company varchar, p_res_code text, p_maint jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  r      erp.prod_resource;
  v_on   date := erp._date(p_maint->>'done_on');
  v_kind text := coalesce(nullif(btrim(p_maint->>'kind'), ''), 'preventive');
  v_id   integer;
BEGIN
  u := erp._prd_guard(p_company, true, 'record maintenance');
  SELECT * INTO r FROM erp.prod_resource WHERE company_code = p_company AND res_code = p_res_code FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Resource % was not found in company %.', p_res_code, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_on IS NULL THEN
    RAISE EXCEPTION 'Enter the date the maintenance was done.' USING ERRCODE = 'P0001';
  ELSIF v_on > current_date THEN
    RAISE EXCEPTION 'The maintenance date can''t be in the future.' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind NOT IN ('preventive', 'repair', 'inspection') THEN
    RAISE EXCEPTION 'Choose the kind of maintenance: preventive, repair or inspection.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.mould_maintenance (company_code, res_code, done_on, kind, shots_at, note, done_by)
  VALUES (p_company, r.res_code, v_on, v_kind, r.shots_done, nullif(btrim(p_maint->>'note'), ''), u.user_id) RETURNING maint_id INTO v_id;
  IF v_kind <> 'inspection' THEN
    UPDATE erp.prod_resource SET last_maint_shots = shots_done, last_maint_on = greatest(coalesce(last_maint_on, v_on), v_on), updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND res_code = r.res_code;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'mould_maintenance_record', 'prod_resource', r.res_code,
          jsonb_build_object('maint_id', v_id, 'done_on', v_on, 'kind', v_kind, 'shots_at', r.shots_done));
  RETURN jsonb_build_object('maint_id', v_id, 'shots_at', r.shots_done);
END $$;

-- ============ Production: bills of materials ============
-- p_bom: {item_code, bom_type, qty, whs_code, active, note, edit (true to change), lines:[{comp_kind, comp_code, qty, whs_code, note}]}
CREATE OR REPLACE FUNCTION erp.bom_save(p_company varchar, p_bom jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  old    erp.bom;
  it     erp.item;
  ci     erp.item;
  rs     erp.prod_resource;
  v_item text := nullif(btrim(p_bom->>'item_code'), '');
  v_type text := coalesce(nullif(btrim(p_bom->>'bom_type'), ''), 'production');
  v_qty  numeric := coalesce(erp._num(p_bom->>'qty'), 1);
  v_whs  text := nullif(btrim(p_bom->>'whs_code'), '');
  v_edit boolean := coalesce((p_bom->>'edit')::boolean, false);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_bom->'lines') = 'array' THEN p_bom->'lines' ELSE '[]'::jsonb END;
  l      jsonb;
  i      integer := 0;
  v_kind text;
  v_code text;
  v_lq   numeric;
  v_lw   text;
  v_seen jsonb := '{}';
  v_items integer := 0;
  v_before jsonb;
BEGIN
  u := erp._prd_guard(p_company, true, 'change bills of materials');
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Choose the finished item.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_item;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item % does not exist in company %.', v_item, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.bom WHERE company_code = p_company AND item_code = v_item FOR UPDATE;
  IF FOUND AND NOT v_edit THEN
    RAISE EXCEPTION 'A bill of materials for % already exists. Open it to change it.', v_item USING ERRCODE = 'P0001';
  ELSIF NOT FOUND AND v_edit THEN
    RAISE EXCEPTION 'There is no bill of materials for % in company %.', v_item, p_company USING ERRCODE = 'P0001';
  END IF;
  IF old.item_code IS NOT NULL THEN
    v_before := to_jsonb(old) - 'company_code' || jsonb_build_object('lines', (SELECT jsonb_agg(to_jsonb(b) - 'company_code' - 'item_code' ORDER BY b.line_num)
                                                                            FROM erp.bom_line b WHERE b.company_code = p_company AND b.item_code = v_item));
  END IF;
  IF v_type NOT IN ('production', 'assembly', 'sales') THEN
    RAISE EXCEPTION 'Choose the BOM type: production, assembly or sales kit.' USING ERRCODE = 'P0001';
  END IF;
  IF v_type = 'production' AND NOT coalesce(it.is_stock, false) THEN
    RAISE EXCEPTION '% is not a stock item, so it can''t be produced into stock. Use a sales kit, or make it a stock item first.', v_item USING ERRCODE = 'P0001';
  END IF;
  IF v_qty IS NULL OR v_qty <= 0 THEN
    RAISE EXCEPTION 'The quantity the BOM makes must be above zero.' USING ERRCODE = 'P0001';
  END IF;
  IF v_whs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_whs, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_type = 'production' AND v_whs IS NULL THEN
    RAISE EXCEPTION 'Choose the warehouse the finished item is received into.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one component.' USING ERRCODE = 'P0001';
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    v_kind := coalesce(nullif(btrim(l->>'comp_kind'), ''), 'item');
    v_code := nullif(btrim(l->>'comp_code'), '');
    v_lq := erp._num(l->>'qty');
    v_lw := nullif(btrim(l->>'whs_code'), '');
    IF v_kind NOT IN ('item', 'resource') THEN
      RAISE EXCEPTION 'Line %: choose item or resource.', i USING ERRCODE = 'P0001';
    END IF;
    IF v_code IS NULL THEN
      RAISE EXCEPTION 'Line %: choose the %.', i, CASE v_kind WHEN 'item' THEN 'component item' ELSE 'resource' END USING ERRCODE = 'P0001';
    END IF;
    IF v_lq IS NULL OR v_lq <= 0 THEN
      RAISE EXCEPTION 'Line %: enter a quantity above zero.', i USING ERRCODE = 'P0001';
    END IF;
    IF v_seen ? (v_kind || ':' || v_code) THEN
      RAISE EXCEPTION 'Line %: % is already on line %.', i, v_code, v_seen->>(v_kind || ':' || v_code) USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || jsonb_build_object(v_kind || ':' || v_code, i);
    IF v_kind = 'item' THEN
      v_items := v_items + 1;
      IF v_code = v_item THEN
        RAISE EXCEPTION 'Line %: % can''t be a component of itself.', i, v_code USING ERRCODE = 'P0001';
      END IF;
      SELECT * INTO ci FROM erp.item WHERE company_code = p_company AND item_code = v_code;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Line %: item % does not exist in company %.', i, v_code, p_company USING ERRCODE = 'P0001';
      ELSIF NOT ci.active THEN
        RAISE EXCEPTION 'Line %: item % is inactive.', i, v_code USING ERRCODE = 'P0001';
      ELSIF v_type = 'production' AND NOT coalesce(ci.is_stock, false) THEN
        RAISE EXCEPTION 'Line %: % is not a stock item, so it can''t be issued for production.', i, v_code USING ERRCODE = 'P0001';
      END IF;
      -- No loops: the component's own BOM (at any depth) must not use the finished item.
      IF EXISTS (WITH RECURSIVE t(code) AS (
                   SELECT bl.comp_code FROM erp.bom_line bl WHERE bl.company_code = p_company AND bl.item_code = v_code AND bl.comp_kind = 'item'
                   UNION SELECT bl.comp_code FROM erp.bom_line bl JOIN t ON bl.item_code = t.code WHERE bl.company_code = p_company AND bl.comp_kind = 'item')
                 SELECT 1 FROM t WHERE code = v_item) THEN
        RAISE EXCEPTION 'Line %: the bill of materials of % already uses %, so this would make a loop.', i, v_code, v_item USING ERRCODE = 'P0001';
      END IF;
      v_lw := coalesce(v_lw, v_whs);
      IF v_lw IS NULL AND v_type = 'production' THEN
        RAISE EXCEPTION 'Line %: choose the warehouse % is issued from.', i, v_code USING ERRCODE = 'P0001';
      ELSIF v_lw IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lw AND active) THEN
        RAISE EXCEPTION 'Line %: warehouse % does not exist or is inactive.', i, v_lw USING ERRCODE = 'P0001';
      END IF;
    ELSE
      SELECT * INTO rs FROM erp.prod_resource WHERE company_code = p_company AND res_code = v_code;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Line %: resource % does not exist in company %. Add it under Moulds and resources.', i, v_code, p_company USING ERRCODE = 'P0001';
      ELSIF NOT rs.active THEN
        RAISE EXCEPTION 'Line %: resource % is inactive.', i, v_code USING ERRCODE = 'P0001';
      END IF;
      v_lw := NULL;
    END IF;
  END LOOP;
  IF v_items = 0 AND v_type <> 'production' THEN
    RAISE EXCEPTION 'Add at least one component item.' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO erp.bom (company_code, item_code, bom_type, qty, whs_code, active, note, created_by, updated_by)
  VALUES (p_company, v_item, v_type, v_qty, v_whs, coalesce((p_bom->>'active')::boolean, true), nullif(btrim(p_bom->>'note'), ''), u.user_id, u.user_id)
  ON CONFLICT (company_code, item_code) DO UPDATE SET bom_type = EXCLUDED.bom_type, qty = EXCLUDED.qty, whs_code = EXCLUDED.whs_code,
    active = EXCLUDED.active, note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now();
  DELETE FROM erp.bom_line WHERE company_code = p_company AND item_code = v_item;
  i := 0;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    v_kind := coalesce(nullif(btrim(l->>'comp_kind'), ''), 'item');
    INSERT INTO erp.bom_line (company_code, item_code, line_num, comp_kind, comp_code, qty, whs_code, note)
    VALUES (p_company, v_item, i, v_kind, btrim(l->>'comp_code'), erp._num(l->>'qty'),
            CASE WHEN v_kind = 'item' THEN coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs) END, nullif(btrim(l->>'note'), ''));
    i := i + 1;
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.item_code IS NULL THEN 'bom_create' ELSE 'bom_update' END, 'bom', v_item,
          jsonb_build_object('bom_type', v_type, 'qty', v_qty, 'whs_code', v_whs, 'lines', v_lines,
                             'before', v_before));
  RETURN jsonb_build_object('item_code', v_item, 'lines', i);
END $$;

CREATE OR REPLACE FUNCTION erp.bom_delete(p_company varchar, p_item text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u    erp.app_user;
  v_no text;
BEGIN
  u := erp._prd_guard(p_company, true, 'change bills of materials');
  IF NOT EXISTS (SELECT 1 FROM erp.bom WHERE company_code = p_company AND item_code = p_item) THEN
    RAISE EXCEPTION 'There is no bill of materials for % in company %.', p_item, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT doc_no INTO v_no FROM erp.prod_order WHERE company_code = p_company AND item_code = p_item AND state IN ('planned', 'released') ORDER BY order_id LIMIT 1;
  IF v_no IS NOT NULL THEN
    RAISE EXCEPTION 'Production order % for % is still open. Close or cancel it first.', v_no, p_item USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bom_delete', 'bom', p_item,
          jsonb_build_object('lines', (SELECT jsonb_agg(to_jsonb(l) - 'company_code' ORDER BY l.line_num) FROM erp.bom_line l WHERE l.company_code = p_company AND l.item_code = p_item)));
  DELETE FROM erp.bom WHERE company_code = p_company AND item_code = p_item;
  RETURN jsonb_build_object('deleted', p_item);
END $$;

-- One BOM with its lines (names, unit costs, stock), the cost of one parent unit from current average costs, and where it is used.
CREATE OR REPLACE FUNCTION erp.bom_info(p_company varchar, p_item text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  b erp.bom;
  v_lines jsonb;
BEGIN
  u := erp._prd_guard(p_company, false);
  SELECT * INTO b FROM erp.bom WHERE company_code = p_company AND item_code = p_item;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'There is no bill of materials for % in company %.', p_item, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('line_num', l.line_num, 'comp_kind', l.comp_kind, 'comp_code', l.comp_code, 'qty', l.qty, 'whs_code', l.whs_code,
           'note', l.note, 'name', coalesce(i.name, r.name), 'uom', CASE WHEN l.comp_kind = 'item' THEN i.inventory_uom ELSE r.unit END,
           'unit_cost', CASE WHEN l.comp_kind = 'item' THEN coalesce(sb.avg_cost, i.avg_cost, 0) ELSE coalesce(r.unit_cost, 0) END,
           'on_hand', sb.on_hand, 'kind', r.kind,
           'cost', round(l.qty * CASE WHEN l.comp_kind = 'item' THEN coalesce(sb.avg_cost, i.avg_cost, 0) ELSE coalesce(r.unit_cost, 0) END, 2)) ORDER BY l.line_num), '[]'::jsonb)
    INTO v_lines
    FROM erp.bom_line l
    LEFT JOIN erp.item i ON l.comp_kind = 'item' AND i.company_code = l.company_code AND i.item_code = l.comp_code
    LEFT JOIN erp.stock_balance sb ON l.comp_kind = 'item' AND sb.company_code = l.company_code AND sb.item_code = l.comp_code AND sb.whs_code = l.whs_code
    LEFT JOIN erp.prod_resource r ON l.comp_kind = 'resource' AND r.company_code = l.company_code AND r.res_code = l.comp_code
   WHERE l.company_code = p_company AND l.item_code = p_item;
  RETURN jsonb_build_object(
    'bom', to_jsonb(b) || jsonb_build_object('item_name', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = p_item),
                                             'uom', (SELECT inventory_uom FROM erp.item WHERE company_code = p_company AND item_code = p_item),
                                             'created_by_name', erp._adm_name(b.created_by), 'updated_by_name', erp._adm_name(b.updated_by)),
    'lines', v_lines,
    'unit_cost', round((SELECT coalesce(sum((x->>'cost')::numeric), 0) FROM jsonb_array_elements(v_lines) x) / b.qty, 4),
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'used_in', coalesce((SELECT jsonb_agg(DISTINCT l.item_code) FROM erp.bom_line l WHERE l.company_code = p_company AND l.comp_kind = 'item' AND l.comp_code = p_item), '[]'::jsonb),
    'open_orders', coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', o.order_id, 'doc_no', o.doc_no, 'state', o.state, 'planned_qty', o.planned_qty) ORDER BY o.order_id)
                               FROM erp.prod_order o WHERE o.company_code = p_company AND o.item_code = p_item AND o.state IN ('planned', 'released')), '[]'::jsonb),
    'can_write', erp.can_write('production'));
END $$;

-- ============ Production: orders ============
-- p_header: {item_code, planned_qty, due_date, post_date (default today), whs_code (default the BOM's), comments}
-- Lines are copied from the item's production BOM (per parent unit = BOM qty / BOM batch qty).
CREATE OR REPLACE FUNCTION erp.prod_order_create(p_company varchar, p_header jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  b      erp.bom;
  it     erp.item;
  v_item text := nullif(btrim(p_header->>'item_code'), '');
  v_qty  numeric := erp._num(p_header->>'planned_qty');
  v_due  date := erp._date(p_header->>'due_date');
  v_post date := coalesce(erp._date(p_header->>'post_date'), current_date);
  v_whs  text;
  nb     jsonb;
  v_id   integer;
BEGIN
  u := erp._prd_guard(p_company, true, 'create production orders');
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Choose the item to make.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_item;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item % does not exist in company %.', v_item, p_company USING ERRCODE = 'P0001';
  ELSIF NOT it.active THEN
    RAISE EXCEPTION 'Item % is inactive.', v_item USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO b FROM erp.bom WHERE company_code = p_company AND item_code = v_item;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% has no bill of materials. Create the BOM first.', v_item USING ERRCODE = 'P0001';
  ELSIF b.bom_type <> 'production' THEN
    RAISE EXCEPTION 'The bill of materials of % is a % BOM. Only production BOMs make production orders.', v_item,
      CASE b.bom_type WHEN 'sales' THEN 'sales kit' ELSE b.bom_type END USING ERRCODE = 'P0001';
  ELSIF NOT b.active THEN
    RAISE EXCEPTION 'The bill of materials of % is inactive.', v_item USING ERRCODE = 'P0001';
  END IF;
  IF v_qty IS NULL OR v_qty <= 0 THEN
    RAISE EXCEPTION 'Enter a planned quantity above zero.' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(it.serial_managed, false) AND v_qty <> trunc(v_qty) THEN
    RAISE EXCEPTION '% is serial-managed, so the planned quantity must be a whole number.', v_item USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_header->>'due_date'), '') IS NULL THEN
    RAISE EXCEPTION 'Choose the due date.' USING ERRCODE = 'P0001';
  ELSIF v_due IS NULL THEN
    RAISE EXCEPTION 'The due date is not a valid date.' USING ERRCODE = 'P0001';
  ELSIF v_due < v_post THEN
    RAISE EXCEPTION 'The due date can''t be before the order date.' USING ERRCODE = 'P0001';
  END IF;
  v_whs := coalesce(nullif(btrim(p_header->>'whs_code'), ''), b.whs_code);
  IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', coalesce(v_whs, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  nb := erp._ps_number(p_company, 202);
  v_id := (nb->>'entry')::integer;
  INSERT INTO erp.prod_order (company_code, order_id, doc_no, item_code, planned_qty, whs_code, post_date, due_date, comments, created_by)
  VALUES (p_company, v_id, nb->>'no', v_item, v_qty, v_whs, v_post, v_due, nullif(btrim(p_header->>'comments'), ''), u.user_id);
  INSERT INTO erp.prod_order_line (company_code, order_id, line_num, comp_kind, comp_code, base_qty, planned_qty, whs_code)
  SELECT p_company, v_id, l.line_num, l.comp_kind, l.comp_code, round(l.qty / b.qty, 6), round(l.qty / b.qty * v_qty, 6), l.whs_code
    FROM erp.bom_line l WHERE l.company_code = p_company AND l.item_code = v_item;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'prod_order_create', 'prod_order', v_id::text,
          jsonb_build_object('doc_no', nb->>'no', 'item_code', v_item, 'planned_qty', v_qty, 'due_date', v_due, 'whs_code', v_whs));
  RETURN jsonb_build_object('order_id', v_id, 'doc_no', nb->>'no', 'state', 'planned');
END $$;

CREATE OR REPLACE FUNCTION erp.prod_order_checks(p_company varchar, p_order integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  s jsonb;
BEGIN
  u := erp._prd_guard(p_company, false);
  IF NOT EXISTS (SELECT 1 FROM erp.prod_order WHERE company_code = p_company AND order_id = p_order) THEN
    RAISE EXCEPTION 'Production order % was not found in company %.', p_order, p_company USING ERRCODE = 'P0001';
  END IF;
  s := erp._prd_shortages(p_company, p_order);
  RETURN jsonb_build_object('shortages', s, 'messages', coalesce((SELECT jsonb_agg(erp._prd_short_msg(x)) FROM jsonb_array_elements(s) x), '[]'::jsonb));
END $$;

-- planned → released. Refused while a component is short; the message names the purchase order that will bring it.
CREATE OR REPLACE FUNCTION erp.prod_order_release(p_company varchar, p_order integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  o erp.prod_order;
  s jsonb;
BEGIN
  u := erp._prd_guard(p_company, true, 'release production orders');
  o := erp._prd_lock(p_company, p_order);
  IF o.state <> 'planned' THEN
    RAISE EXCEPTION 'Production order % is %, so it can''t be released.', o.doc_no, o.state USING ERRCODE = 'P0001';
  END IF;
  s := erp._prd_shortages(p_company, p_order);
  IF jsonb_array_length(s) > 0 THEN
    RAISE EXCEPTION '%', format('Can''t release %s: %s%s', o.doc_no, erp._prd_short_msg(s->0),
      CASE WHEN jsonb_array_length(s) > 1 THEN format(' (%s more component(s) short.)', jsonb_array_length(s) - 1) ELSE '' END)
      USING ERRCODE = 'P0001', HINT = 'Release it when the stock has arrived, or lower the planned quantity.';
  END IF;
  UPDATE erp.prod_order SET state = 'released', released_by = u.user_id, released_at = now() WHERE company_code = p_company AND order_id = p_order;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'prod_order_release', 'prod_order', p_order::text, jsonb_build_object('doc_no', o.doc_no));
  RETURN jsonb_build_object('order_id', p_order, 'state', 'released');
END $$;

-- Issue for production: a goods issue (60) based on the order. Dr WIP / Cr stock at average cost.
-- p_header: {doc_date, reason (needed when a line goes above its planned quantity), comments}
-- p_lines:  [{line_num, qty, bin_code, lots}]
CREATE OR REPLACE FUNCTION erp.prod_order_issue(p_company varchar, p_order integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  o      erp.prod_order;
  ol     erp.prod_order_line;
  it     erp.item;
  v_wip  text;
  v_date date := erp._date(p_header->>'doc_date');
  v_reason text := nullif(btrim(p_header->>'reason'), '');
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_out  jsonb := '[]';
  l      jsonb;
  n      integer := 0;
  v_qty  numeric;
  v_bin  text;
  v_bins boolean;
  v_avail numeric;
  v_cost numeric;
  v_used jsonb := '{}';
  v_seen jsonb := '{}';
  v_lc   jsonb;
  v_serials text[] := '{}';
  v_extra boolean := false;
  d      jsonb;
  v_trans integer;
  v_value numeric := 0;
BEGIN
  u := erp._prd_guard(p_company, true, 'issue components');
  o := erp._prd_lock(p_company, p_order);
  IF o.state = 'planned' THEN
    RAISE EXCEPTION 'Release production order % first. Components are issued to released orders only.', o.doc_no USING ERRCODE = 'P0001';
  ELSIF o.state <> 'released' THEN
    RAISE EXCEPTION 'Production order % is %. Nothing more can be issued to it.', o.doc_no, o.state USING ERRCODE = 'P0001';
  END IF;
  v_wip := erp._prd_wip(p_company);
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Choose a valid posting date.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Enter the quantity to issue on at least one component.' USING ERRCODE = 'P0001';
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    v_qty := erp._num(l->>'qty');
    CONTINUE WHEN v_qty IS NOT NULL AND v_qty = 0;
    SELECT * INTO ol FROM erp.prod_order_line WHERE company_code = p_company AND order_id = p_order AND line_num = (l->>'line_num')::integer;
    IF NOT FOUND OR ol.comp_kind <> 'item' THEN
      RAISE EXCEPTION 'Line % is not a component item of %.', coalesce(l->>'line_num', '?'), o.doc_no USING ERRCODE = 'P0001';
    END IF;
    IF v_seen ? ol.line_num::text THEN
      RAISE EXCEPTION '% is entered twice. Enter it once.', ol.comp_code USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || jsonb_build_object(ol.line_num::text, true);
    IF v_qty IS NULL OR v_qty < 0 THEN
      RAISE EXCEPTION '%: enter a quantity above zero.', ol.comp_code USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = ol.comp_code;
    IF ol.issued_qty + v_qty > ol.planned_qty THEN
      v_extra := true;
    END IF;
    v_avail := coalesce((SELECT on_hand FROM erp.stock_balance WHERE company_code = p_company AND item_code = ol.comp_code AND whs_code = ol.whs_code), 0)
             - coalesce((v_used->>(ol.comp_code || '|' || ol.whs_code))::numeric, 0);
    IF v_qty > v_avail THEN
      RAISE EXCEPTION 'Only % of % in stock in %. You can''t issue %.', trim_scale(greatest(v_avail, 0)), ol.comp_code, ol.whs_code, trim_scale(v_qty)
        USING ERRCODE = 'P0001';
    END IF;
    v_used := v_used || jsonb_build_object(ol.comp_code || '|' || ol.whs_code, coalesce((v_used->>(ol.comp_code || '|' || ol.whs_code))::numeric, 0) + v_qty);
    v_bin := nullif(btrim(l->>'bin_code'), '');
    SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = ol.whs_code;
    IF NOT coalesce(v_bins, false) AND v_bin IS NOT NULL THEN
      RAISE EXCEPTION 'Warehouse % does not use bins. Clear the bin on %.', ol.whs_code, ol.comp_code USING ERRCODE = 'P0001';
    ELSIF coalesce(v_bins, false) AND v_bin IS NULL AND v_qty > erp._inv_unbinned(p_company, ol.comp_code, ol.whs_code) THEN
      RAISE EXCEPTION 'Only % of % are outside bins in %. Choose the bin to pick from.', trim_scale(greatest(erp._inv_unbinned(p_company, ol.comp_code, ol.whs_code), 0)),
        ol.comp_code, ol.whs_code USING ERRCODE = 'P0001';
    END IF;
    v_lc := erp._inv_lot_check(p_company, ol.comp_code, it.serial_managed, it.batch_managed, ol.whs_code, v_qty, l->'lots', -1, n + 1, v_serials);
    IF v_lc ? 'message' THEN
      RAISE EXCEPTION '%', v_lc->>'message' USING ERRCODE = 'P0001';
    END IF;
    v_cost := coalesce((SELECT avg_cost FROM erp.stock_balance WHERE company_code = p_company AND item_code = ol.comp_code AND whs_code = ol.whs_code), it.avg_cost, 0);
    v_out := v_out || jsonb_build_object('line_num', n, 'item_code', ol.comp_code, 'description', it.name, 'uom', it.inventory_uom, 'qty', v_qty,
                                         'price', round(v_cost, 6), 'whs_code', ol.whs_code, 'acct_code', v_wip, 'base_line', ol.line_num, 'bin_code', v_bin,
                                         'lots', v_lc->'lots', 'serial', coalesce(it.serial_managed, false), 'batch', coalesce(it.batch_managed, false));
    n := n + 1;
  END LOOP;
  IF n = 0 THEN
    RAISE EXCEPTION 'Enter the quantity to issue on at least one component.' USING ERRCODE = 'P0001';
  END IF;
  IF v_extra AND v_reason IS NULL THEN
    RAISE EXCEPTION 'This issue goes above the planned quantity of a component. Add a reason for the extra issue.' USING ERRCODE = 'P0001';
  END IF;

  d := erp._prd_stock_doc(p_company, 60, v_date, o.doc_no, coalesce(nullif(btrim(p_header->>'comments'), ''), 'Issue for production ' || o.doc_no)
                          || CASE WHEN v_extra THEN ' · Extra issue: ' || v_reason ELSE '' END, p_order, v_out, u.user_id);
  v_trans := erp.post_document(p_company, 60, (d->>'entry')::integer);
  FOR l IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    UPDATE erp.prod_order_line SET issued_qty = issued_qty + (l->>'qty')::numeric, issued_value = issued_value + round((l->>'qty')::numeric * (l->>'price')::numeric, 2)
     WHERE company_code = p_company AND order_id = p_order AND line_num = (l->>'base_line')::integer;
    v_value := v_value + round((l->>'qty')::numeric * (l->>'price')::numeric, 2);
  END LOOP;
  UPDATE erp.prod_order SET issued_value = issued_value + v_value WHERE company_code = p_company AND order_id = p_order;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'prod_order_issue', 'prod_order', p_order::text,
          jsonb_build_object('doc_no', o.doc_no, 'issue_entry', d->'entry', 'issue_no', d->'no', 'value', v_value, 'trans_id', v_trans,
                             'extra', v_extra, 'reason', v_reason, 'lines', v_out));
  RETURN jsonb_build_object('doc_entry', d->'entry', 'doc_no', d->'no', 'value', v_value, 'trans_id', v_trans);
END $$;

-- Receipt from production: resources used for this quantity are charged (Dr WIP / Cr resource account; mould shot counts go
-- up), then the finished item comes into stock at (component share + resources) / qty: Dr stock / Cr WIP.
-- p_header: {doc_date, qty, bin_code, lots, comments}
CREATE OR REPLACE FUNCTION erp.prod_order_receipt(p_company varchar, p_order integer, p_header jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  o      erp.prod_order;
  it     erp.item;
  r      record;
  v_wip  text;
  v_date date := erp._date(p_header->>'doc_date');
  v_qty  numeric := erp._num(p_header->>'qty');
  v_bin  text := nullif(btrim(p_header->>'bin_code'), '');
  v_bins boolean;
  v_left numeric;
  v_lc   jsonb;
  v_res  jsonb := '[]';
  v_res_total numeric := 0;
  v_rq   numeric;
  v_amt  numeric;
  v_share numeric;
  v_unit numeric;
  v_booked numeric;
  v_rtrans integer;
  v_trans integer;
  d      jsonb;
  x      jsonb;
BEGIN
  u := erp._prd_guard(p_company, true, 'report production output');
  o := erp._prd_lock(p_company, p_order);
  IF o.state = 'planned' THEN
    RAISE EXCEPTION 'Release production order % first.', o.doc_no USING ERRCODE = 'P0001';
  ELSIF o.state <> 'released' THEN
    RAISE EXCEPTION 'Production order % is %. No more output can be reported.', o.doc_no, o.state USING ERRCODE = 'P0001';
  END IF;
  v_wip := erp._prd_wip(p_company);
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Choose a valid posting date.' USING ERRCODE = 'P0001';
  END IF;
  v_left := o.planned_qty - o.completed_qty;
  IF v_qty IS NULL OR v_qty <= 0 THEN
    RAISE EXCEPTION 'Enter the quantity made (above zero).' USING ERRCODE = 'P0001';
  ELSIF v_qty > v_left THEN
    RAISE EXCEPTION 'Only % left to report on %. You can''t receive %.', trim_scale(v_left), o.doc_no, trim_scale(v_qty) USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.prod_order_line WHERE company_code = p_company AND order_id = p_order AND comp_kind = 'item')
     AND NOT EXISTS (SELECT 1 FROM erp.prod_order_line WHERE company_code = p_company AND order_id = p_order AND comp_kind = 'item' AND issued_qty > 0) THEN
    RAISE EXCEPTION 'Issue the components first: nothing has been issued to % yet.', o.doc_no USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = o.item_code;
  SELECT coalesce(bins_enabled, false) INTO v_bins FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = o.whs_code;
  IF coalesce(v_bins, false) AND v_bin IS NULL THEN
    RAISE EXCEPTION '% uses bins. Choose the bin to put % away in.', o.whs_code, o.item_code USING ERRCODE = 'P0001';
  ELSIF NOT coalesce(v_bins, false) AND v_bin IS NOT NULL THEN
    RAISE EXCEPTION 'Warehouse % does not use bins. Clear the bin.', o.whs_code USING ERRCODE = 'P0001';
  ELSIF v_bin IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.bin_location WHERE company_code = p_company AND whs_code = o.whs_code AND bin_code = v_bin AND active) THEN
    RAISE EXCEPTION 'Bin % does not exist or is inactive in %.', v_bin, o.whs_code USING ERRCODE = 'P0001';
  END IF;
  v_lc := erp._inv_lot_check(p_company, o.item_code, it.serial_managed, it.batch_managed, o.whs_code, v_qty, p_header->'lots', 1, 1, '{}');
  IF v_lc ? 'message' THEN
    RAISE EXCEPTION '%', replace(v_lc->>'message', 'Line 1: ', '') USING ERRCODE = 'P0001';
  END IF;

  -- Resources used for this quantity
  FOR r IN SELECT l.line_num, l.comp_code, l.base_qty, pr.unit, pr.unit_cost, pr.acct_code, pr.name
             FROM erp.prod_order_line l JOIN erp.prod_resource pr ON pr.company_code = l.company_code AND pr.res_code = l.comp_code
            WHERE l.company_code = p_company AND l.order_id = p_order AND l.comp_kind = 'resource' ORDER BY l.line_num LOOP
    v_rq := round(r.base_qty * v_qty, 6);
    v_amt := round(v_rq * r.unit_cost, 2);
    IF v_amt > 0 AND r.acct_code IS NULL THEN
      RAISE EXCEPTION 'Resource % has a cost but no account. Ask Finance to set it under Moulds and resources.', r.comp_code USING ERRCODE = 'P0001';
    END IF;
    v_res := v_res || jsonb_build_object('line_num', r.line_num, 'res_code', r.comp_code, 'unit', r.unit, 'qty', v_rq, 'unit_cost', r.unit_cost,
                                         'amount', v_amt, 'acct_code', r.acct_code);
    v_res_total := v_res_total + v_amt;
  END LOOP;
  IF v_res_total > 0 THEN
    v_rtrans := erp.post_journal(p_company, v_date, format('Resources for production order %s · %s %s', o.doc_no, trim_scale(v_qty), o.item_code),
      jsonb_build_array(jsonb_build_object('acct_code', v_wip, 'debit', v_res_total))
        || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
              FROM (SELECT e->>'acct_code' AS acct, sum((e->>'amount')::numeric) AS amt FROM jsonb_array_elements(v_res) e
                     WHERE (e->>'amount')::numeric > 0 GROUP BY 1) a),
      jsonb_build_object('trans_type', 202, 'base_ref', o.doc_no, 'ref1', o.doc_no, 'action', 'prod_order_resources', 'object', 'prod_order',
                         'object_ref', p_order::text));
  END IF;

  -- Cost of this receipt: the components' share still in WIP (all of it on the last receipt) + this receipt's resources.
  v_share := CASE WHEN v_qty >= v_left THEN o.issued_value - o.comp_received_value
                  ELSE round((o.issued_value - o.comp_received_value) * v_qty / v_left, 2) END;
  v_unit := round((v_share + v_res_total) / v_qty, 6);
  v_booked := round(v_qty * v_unit, 2);
  d := erp._prd_stock_doc(p_company, 59, v_date, o.doc_no, coalesce(nullif(btrim(p_header->>'comments'), ''), 'Receipt from production ' || o.doc_no), p_order,
                          jsonb_build_array(jsonb_build_object('line_num', 0, 'item_code', o.item_code, 'description', it.name, 'uom', it.inventory_uom,
                                                               'qty', v_qty, 'price', v_unit, 'whs_code', o.whs_code, 'acct_code', v_wip, 'base_line', NULL,
                                                               'bin_code', v_bin, 'lots', v_lc->'lots', 'serial', coalesce(it.serial_managed, false),
                                                               'batch', coalesce(it.batch_managed, false))), u.user_id);
  v_trans := erp.post_document(p_company, 59, (d->>'entry')::integer);

  FOR x IN SELECT value FROM jsonb_array_elements(v_res) LOOP
    INSERT INTO erp.prod_resource_use (company_code, order_id, line_num, receipt_entry, res_code, qty, unit_cost, amount, trans_id, doc_date)
    VALUES (p_company, p_order, (x->>'line_num')::integer, (d->>'entry')::integer, x->>'res_code', (x->>'qty')::numeric, (x->>'unit_cost')::numeric,
            (x->>'amount')::numeric, v_rtrans, v_date);
    UPDATE erp.prod_order_line SET issued_qty = issued_qty + (x->>'qty')::numeric, issued_value = issued_value + (x->>'amount')::numeric
     WHERE company_code = p_company AND order_id = p_order AND line_num = (x->>'line_num')::integer;
    IF x->>'unit' = 'shot' THEN
      UPDATE erp.prod_resource SET shots_done = shots_done + ceil((x->>'qty')::numeric)::bigint WHERE company_code = p_company AND res_code = x->>'res_code';
    END IF;
  END LOOP;
  UPDATE erp.prod_order SET completed_qty = completed_qty + v_qty, comp_received_value = comp_received_value + v_share,
         resource_value = resource_value + v_res_total, received_value = received_value + v_booked
   WHERE company_code = p_company AND order_id = p_order;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'prod_order_receipt', 'prod_order', p_order::text,
          jsonb_build_object('doc_no', o.doc_no, 'receipt_entry', d->'entry', 'receipt_no', d->'no', 'qty', v_qty, 'unit_cost', v_unit,
                             'component_share', v_share, 'resources', v_res, 'value', v_booked, 'trans_id', v_trans, 'resource_trans_id', v_rtrans));
  RETURN jsonb_build_object('doc_entry', d->'entry', 'doc_no', d->'no', 'qty', v_qty, 'unit_cost', v_unit, 'value', v_booked,
                            'component_share', v_share, 'resource_cost', v_res_total, 'trans_id', v_trans, 'resource_trans_id', v_rtrans);
END $$;

-- released → closed. What is left in WIP (components issued + resources − finished stock received) goes to the variance account.
CREATE OR REPLACE FUNCTION erp.prod_order_close(p_company varchar, p_order integer, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  o       erp.prod_order;
  v_var   numeric;
  v_wip   text;
  v_vacct text;
  v_trans integer;
BEGIN
  u := erp._prd_guard(p_company, true, 'close production orders');
  o := erp._prd_lock(p_company, p_order);
  IF o.state = 'planned' THEN
    RAISE EXCEPTION 'Production order % was never released. Cancel it instead.', o.doc_no USING ERRCODE = 'P0001';
  ELSIF o.state <> 'released' THEN
    RAISE EXCEPTION 'Production order % is already %.', o.doc_no, o.state USING ERRCODE = 'P0001';
  END IF;
  v_var := o.issued_value + o.resource_value - o.received_value;
  IF v_var <> 0 THEN
    v_wip := erp._prd_wip(p_company);
    SELECT variance_acct INTO v_vacct FROM erp.production_setting WHERE company_code = p_company;
    IF v_vacct IS NULL THEN
      RAISE EXCEPTION '% % is still in work in progress, and the production variance account is not set for company %. Ask Finance to set it in Production Setup.',
        erp._money(abs(v_var)), (SELECT currency FROM erp.company WHERE company_code = p_company), p_company USING ERRCODE = 'P0001';
    END IF;
    v_trans := erp.post_journal(p_company, current_date, format('Production order %s closed · variance', o.doc_no),
      CASE WHEN v_var > 0 THEN jsonb_build_array(jsonb_build_object('acct_code', v_vacct, 'debit', v_var), jsonb_build_object('acct_code', v_wip, 'credit', v_var))
           ELSE jsonb_build_array(jsonb_build_object('acct_code', v_wip, 'debit', -v_var), jsonb_build_object('acct_code', v_vacct, 'credit', -v_var)) END,
      jsonb_build_object('trans_type', 202, 'base_ref', o.doc_no, 'ref1', o.doc_no, 'action', 'prod_order_variance', 'object', 'prod_order',
                         'object_ref', p_order::text));
  END IF;
  UPDATE erp.prod_order SET state = 'closed', closed_by = u.user_id, closed_at = now(), variance_value = v_var, variance_trans = v_trans,
         comments = coalesce(comments, '') || CASE WHEN nullif(btrim(p_note), '') IS NOT NULL THEN CASE WHEN comments IS NULL THEN '' ELSE E'\n' END || btrim(p_note) ELSE '' END
   WHERE company_code = p_company AND order_id = p_order;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'prod_order_close', 'prod_order', p_order::text,
          jsonb_build_object('doc_no', o.doc_no, 'completed_qty', o.completed_qty, 'variance', v_var, 'trans_id', v_trans, 'note', nullif(btrim(p_note), '')));
  RETURN jsonb_build_object('order_id', p_order, 'state', 'closed', 'variance', v_var, 'trans_id', v_trans);
END $$;

-- planned (or released with nothing issued or received) → cancelled. Needs a note.
CREATE OR REPLACE FUNCTION erp.prod_order_cancel(p_company varchar, p_order integer, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  o erp.prod_order;
BEGIN
  u := erp._prd_guard(p_company, true, 'cancel production orders');
  o := erp._prd_lock(p_company, p_order);
  IF nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the order is cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF o.state NOT IN ('planned', 'released') THEN
    RAISE EXCEPTION 'Production order % is already %.', o.doc_no, o.state USING ERRCODE = 'P0001';
  END IF;
  IF o.issued_value <> 0 OR o.completed_qty <> 0 OR EXISTS (SELECT 1 FROM erp.prod_order_line WHERE company_code = p_company AND order_id = p_order AND issued_qty > 0) THEN
    RAISE EXCEPTION 'Components were issued or output was reported on %, so it can''t be cancelled. Close it instead.', o.doc_no USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.prod_order SET state = 'cancelled', cancelled_by = u.user_id, cancelled_at = now(), cancel_note = btrim(p_note)
   WHERE company_code = p_company AND order_id = p_order;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'prod_order_cancel', 'prod_order', p_order::text, jsonb_build_object('doc_no', o.doc_no, 'note', btrim(p_note)));
  RETURN jsonb_build_object('order_id', p_order, 'state', 'cancelled');
END $$;

-- The order, its lines (with stock and bins), shortages (with the next PO), stock documents, resource use, cost summary and activity.
CREATE OR REPLACE FUNCTION erp.prod_order_info(p_company varchar, p_order integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  o erp.prod_order;
  s jsonb;
BEGIN
  u := erp._prd_guard(p_company, false);
  SELECT * INTO o FROM erp.prod_order WHERE company_code = p_company AND order_id = p_order;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Production order % was not found in company %.', p_order, p_company USING ERRCODE = 'P0001';
  END IF;
  s := CASE WHEN o.state IN ('planned', 'released') THEN erp._prd_shortages(p_company, p_order) ELSE '[]'::jsonb END;
  RETURN jsonb_build_object(
    'order', to_jsonb(o) || jsonb_build_object(
      'item_name', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = o.item_code),
      'uom', (SELECT inventory_uom FROM erp.item WHERE company_code = p_company AND item_code = o.item_code),
      'serial', (SELECT coalesce(serial_managed, false) FROM erp.item WHERE company_code = p_company AND item_code = o.item_code),
      'batch', (SELECT coalesce(batch_managed, false) FROM erp.item WHERE company_code = p_company AND item_code = o.item_code),
      'bins', coalesce((SELECT bins_enabled FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = o.whs_code), false),
      'created_by_name', erp._adm_name(o.created_by), 'released_by_name', erp._adm_name(o.released_by), 'closed_by_name', erp._adm_name(o.closed_by),
      'wip', o.issued_value + o.resource_value - o.received_value, 'late', o.state IN ('planned', 'released') AND o.due_date < current_date),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'comp_kind', l.comp_kind, 'comp_code', l.comp_code,
                         'name', coalesce(i.name, r.name), 'uom', CASE WHEN l.comp_kind = 'item' THEN i.inventory_uom ELSE r.unit END, 'base_qty', l.base_qty,
                         'planned_qty', l.planned_qty, 'issued_qty', l.issued_qty, 'issued_value', l.issued_value, 'whs_code', l.whs_code,
                         'on_hand', sb.on_hand, 'avg_cost', CASE WHEN l.comp_kind = 'item' THEN coalesce(sb.avg_cost, i.avg_cost) ELSE r.unit_cost END,
                         'serial', coalesce(i.serial_managed, false), 'batch', coalesce(i.batch_managed, false),
                         'bins', coalesce((SELECT bins_enabled FROM erp.warehouse_setting ws WHERE ws.company_code = l.company_code AND ws.whs_code = l.whs_code), false),
                         'res_kind', r.kind) ORDER BY l.line_num)
                       FROM erp.prod_order_line l
                       LEFT JOIN erp.item i ON l.comp_kind = 'item' AND i.company_code = l.company_code AND i.item_code = l.comp_code
                       LEFT JOIN erp.stock_balance sb ON l.comp_kind = 'item' AND sb.company_code = l.company_code AND sb.item_code = l.comp_code AND sb.whs_code = l.whs_code
                       LEFT JOIN erp.prod_resource r ON l.comp_kind = 'resource' AND r.company_code = l.company_code AND r.res_code = l.comp_code
                      WHERE l.company_code = p_company AND l.order_id = p_order), '[]'::jsonb),
    'shortages', s,
    'shortage_messages', coalesce((SELECT jsonb_agg(erp._prd_short_msg(x)) FROM jsonb_array_elements(s) x), '[]'::jsonb),
    'documents', coalesce((SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'doc_entry', d.doc_entry, 'doc_no', w.doc_no, 'doc_date', d.doc_date,
                             'total', d.total, 'qty', (SELECT sum(quantity) FROM erp.document_line x WHERE x.company_code = d.company_code AND x.obj_type = d.obj_type AND x.doc_entry = d.doc_entry),
                             'trans_id', (SELECT trans_id FROM erp.document_posting dp WHERE dp.company_code = d.company_code AND dp.obj_type = d.obj_type AND dp.doc_entry = d.doc_entry))
                             ORDER BY d.doc_entry)
                           FROM erp.document d JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
                          WHERE d.company_code = p_company AND d.obj_type IN (59, 60) AND d.source = 'erp'
                            AND EXISTS (SELECT 1 FROM erp.document_line x WHERE x.company_code = d.company_code AND x.obj_type = d.obj_type AND x.doc_entry = d.doc_entry
                                          AND x.base_obj_type = 202 AND x.base_doc_entry = p_order)), '[]'::jsonb),
    'resource_use', coalesce((SELECT jsonb_agg(to_jsonb(ru) - 'company_code' ORDER BY ru.use_id) FROM erp.prod_resource_use ru
                               WHERE ru.company_code = p_company AND ru.order_id = p_order), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', erp._adm_name(nullif(a.actor, '')::uuid),
                            'detail', a.detail - 'lines' - 'resources') ORDER BY a.at, a.audit_id)
                           FROM erp.audit_log a WHERE a.company_code = p_company AND a.object = 'prod_order' AND a.object_ref = p_order::text
                            AND a.actor ~ '^[0-9a-f-]{36}$'), '[]'::jsonb),
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('production'));
END $$;

-- ============ Service: setup ============
CREATE OR REPLACE FUNCTION erp.service_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  s erp.service_setting;
BEGIN
  u := erp._svc_guard(p_company, false);
  SELECT * INTO s FROM erp.service_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'setting', jsonb_build_object('parts_reason_code', s.parts_reason_code, 'note', s.note),
    'reasons', coalesce((SELECT jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'acct_code', r.acct_code) ORDER BY r.code)
                           FROM erp.inventory_reason r WHERE r.company_code = p_company AND r.active AND r.direction IN ('out', 'both')), '[]'::jsonb),
    'warranty_rules', coalesce((SELECT jsonb_agg(jsonb_build_object('rule_id', w.rule_id, 'item_code', w.item_code, 'group_code', w.group_code, 'months', w.months,
                                  'note', w.note, 'source', w.source,
                                  'name', coalesce((SELECT name FROM erp.item i WHERE i.company_code = w.company_code AND i.item_code = w.item_code),
                                                   (SELECT name FROM erp.item_group g WHERE g.company_code = w.company_code AND g.group_code = w.group_code)))
                                  ORDER BY w.group_code NULLS LAST, w.item_code) FROM erp.warranty_rule w WHERE w.company_code = p_company), '[]'::jsonb),
    'item_groups', coalesce((SELECT jsonb_agg(jsonb_build_object('code', g.group_code, 'name', g.name) ORDER BY g.group_code) FROM erp.item_group g WHERE g.company_code = p_company), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', w.whs_code, 'name', w.name,
                              'bins', coalesce((SELECT bins_enabled FROM erp.warehouse_setting ws WHERE ws.company_code = w.company_code AND ws.whs_code = w.whs_code), false))
                              ORDER BY w.whs_code) FROM erp.warehouse w WHERE w.company_code = p_company AND w.active AND NOT coalesce(w.locked, false)), '[]'::jsonb),
    'technicians', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', a.user_id, 'name', a.display_name) ORDER BY a.display_name)
                               FROM erp.app_user a WHERE a.active AND erp._adm_level(a.position_code, 'service') IS NOT NULL
                                AND (a.company_code = p_company OR EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = a.user_id AND uc.company_code = p_company))), '[]'::jsonb),
    'numbering', jsonb_build_object('call', (SELECT prefix FROM erp.number_series WHERE company_code = p_company AND obj_type = 191 AND active),
                                    'contract', (SELECT prefix FROM erp.number_series WHERE company_code = p_company AND obj_type = 190 AND active)),
    'me', u.user_id,
    'can_write', erp.can_write('service'),
    'can_inventory', erp.can_write('inventory'));
END $$;

-- p_setting: {parts_reason_code, note}. The reason's account is Finance's (Inventory Setup).
CREATE OR REPLACE FUNCTION erp.service_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  old erp.service_setting;
  v_r text;
  rs  erp.inventory_reason;
BEGIN
  u := erp._svc_guard(p_company, true, 'change service settings');
  SELECT * INTO old FROM erp.service_setting WHERE company_code = p_company;
  v_r := CASE WHEN p_setting ? 'parts_reason_code' THEN nullif(btrim(p_setting->>'parts_reason_code'), '') ELSE old.parts_reason_code END;
  IF v_r IS NOT NULL THEN
    SELECT * INTO rs FROM erp.inventory_reason WHERE company_code = p_company AND code = v_r;
    IF NOT FOUND OR NOT rs.active THEN
      RAISE EXCEPTION 'Reason % does not exist or is inactive. Ask Finance to add it in Inventory Setup.', v_r USING ERRCODE = 'P0001';
    ELSIF rs.direction = 'in' THEN
      RAISE EXCEPTION 'Reason % is for goods receipts only. Choose a goods issue reason.', rs.name USING ERRCODE = 'P0001';
    END IF;
  END IF;
  INSERT INTO erp.service_setting (company_code, parts_reason_code, note, updated_by, updated_at)
  VALUES (p_company, v_r, CASE WHEN p_setting ? 'note' THEN nullif(btrim(p_setting->>'note'), '') ELSE old.note END, u.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET parts_reason_code = EXCLUDED.parts_reason_code, note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'service_setting_set', 'service_setting', p_company, jsonb_build_object('before', old.parts_reason_code, 'parts_reason_code', v_r));
  RETURN jsonb_build_object('parts_reason_code', v_r);
END $$;

-- p_rule: {rule_id (edit / delete), item_code | group_code, months, note, delete: true}
CREATE OR REPLACE FUNCTION erp.warranty_rule_save(p_company varchar, p_rule jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  old    erp.warranty_rule;
  v_id   integer := erp._num(p_rule->>'rule_id')::integer;
  v_item text := nullif(btrim(p_rule->>'item_code'), '');
  v_grp  integer := erp._num(p_rule->>'group_code')::integer;
  v_m    numeric := erp._num(p_rule->>'months');
BEGIN
  u := erp._svc_guard(p_company, true, 'change warranty periods');
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.warranty_rule WHERE company_code = p_company AND rule_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Warranty rule % was not found in company %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF coalesce((p_rule->>'delete')::boolean, false) THEN
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Choose the warranty rule to delete.' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM erp.warranty_rule WHERE company_code = p_company AND rule_id = v_id;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'warranty_rule_delete', 'warranty_rule', v_id::text, to_jsonb(old) - 'updated_by' - 'updated_at');
    RETURN jsonb_build_object('deleted', v_id);
  END IF;
  IF (v_item IS NULL) = (v_grp IS NULL) THEN
    RAISE EXCEPTION 'Choose an item or an item group (one of them).' USING ERRCODE = 'P0001';
  END IF;
  IF v_item IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.item WHERE company_code = p_company AND item_code = v_item) THEN
    RAISE EXCEPTION 'Item % does not exist in company %.', v_item, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_grp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND group_code = v_grp) THEN
    RAISE EXCEPTION 'Item group % does not exist in company %.', v_grp, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_m IS NULL OR v_m <= 0 OR v_m <> trunc(v_m) THEN
    RAISE EXCEPTION 'The warranty period must be a whole number of months above zero.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.warranty_rule WHERE company_code = p_company AND rule_id IS DISTINCT FROM v_id
              AND item_code IS NOT DISTINCT FROM v_item AND group_code IS NOT DISTINCT FROM v_grp) THEN
    RAISE EXCEPTION 'A warranty period for this % is already set. Change that one instead.', CASE WHEN v_item IS NOT NULL THEN 'item' ELSE 'item group' END
      USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO erp.warranty_rule (company_code, item_code, group_code, months, note, updated_by)
    VALUES (p_company, v_item, v_grp, v_m::integer, nullif(btrim(p_rule->>'note'), ''), u.user_id) RETURNING rule_id INTO v_id;
  ELSE
    UPDATE erp.warranty_rule SET item_code = v_item, group_code = v_grp, months = v_m::integer, note = nullif(btrim(p_rule->>'note'), ''),
           updated_by = u.user_id, updated_at = now() WHERE company_code = p_company AND rule_id = v_id;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.rule_id IS NULL THEN 'warranty_rule_create' ELSE 'warranty_rule_update' END, 'warranty_rule', v_id::text,
          jsonb_build_object('item_code', v_item, 'group_code', v_grp, 'months', v_m, 'before', CASE WHEN old.rule_id IS NOT NULL THEN old.months END));
  RETURN jsonb_build_object('rule_id', v_id);
END $$;

-- Warranty months of an item: its own rule, else its group's rule, else NULL (not set).
CREATE OR REPLACE FUNCTION erp._svc_months(p_company varchar, p_item text) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT months FROM erp.warranty_rule WHERE company_code = p_company AND item_code = p_item),
                  (SELECT w.months FROM erp.warranty_rule w JOIN erp.item i ON i.company_code = w.company_code AND i.group_code = w.group_code
                    WHERE w.company_code = p_company AND i.item_code = p_item))
$$;

-- An A/R invoice (obj 13, any source) of the customer that has the item. NULL when it doesn't match.
CREATE OR REPLACE FUNCTION erp._svc_invoice(p_company varchar, p_entry integer, p_card text, p_item text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('doc_entry', d.doc_entry, 'doc_no', coalesce(w.doc_no, d.doc_num::text), 'doc_date', d.doc_date, 'source', d.source)
    FROM erp.document d
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = 13 AND d.doc_entry = p_entry AND d.card_code = p_card
     AND EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = d.company_code AND l.obj_type = 13 AND l.doc_entry = d.doc_entry AND l.item_code = p_item)
$$;

-- Warranty check. p: {card_code, item_code, serial_no, invoice_entry, on_date}. Never writes. Returns
--   {status: in_warranty | out_of_warranty | contract | no_rule | unknown | none, flagged, warranty_start, warranty_end, basis
--    (equipment_card | invoice), card_id, invoice{doc_entry, doc_no, doc_date}, months, contract{contract_id, doc_no, ends_on, response_hours},
--    serial_known, messages[]}
CREATE OR REPLACE FUNCTION erp._svc_warranty(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_card   text := nullif(btrim(p->>'card_code'), '');
  v_item   text := nullif(btrim(p->>'item_code'), '');
  v_serial text := nullif(btrim(p->>'serial_no'), '');
  v_inv    integer := erp._num(p->>'invoice_entry')::integer;
  v_on     date := coalesce(erp._date(p->>'on_date'), current_date);
  e        erp.equipment_card;
  k        erp.service_contract;
  v_invj   jsonb;
  v_start  date;
  v_end    date;
  v_months integer;
  v_basis  text;
  v_status text;
  v_msgs   jsonb := '[]';
  v_known  boolean := false;
BEGIN
  IF v_item IS NULL THEN
    RETURN jsonb_build_object('status', 'none', 'flagged', false, 'messages', '[]'::jsonb);
  END IF;
  v_months := erp._svc_months(p_company, v_item);
  IF v_serial IS NOT NULL THEN
    SELECT * INTO e FROM erp.equipment_card WHERE company_code = p_company AND item_code = v_item AND serial_no = v_serial;
    v_known := e.card_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM erp.stock_lot WHERE company_code = p_company AND kind = 'S' AND item_code = v_item AND number = v_serial)
      OR EXISTS (SELECT 1 FROM erp.batch WHERE company_code = p_company AND kind = 'S' AND item_code = v_item AND number = v_serial);
    IF NOT v_known THEN
      v_msgs := v_msgs || to_jsonb(format('Serial number %s of %s is not known in company %s. Check the number on the unit.', v_serial, v_item, p_company));
    END IF;
    IF EXISTS (SELECT 1 FROM erp.stock_lot l JOIN erp.stock_lot_balance b ON b.lot_id = l.lot_id
                WHERE l.company_code = p_company AND l.kind = 'S' AND l.item_code = v_item AND l.number = v_serial AND b.qty > 0) THEN
      v_msgs := v_msgs || to_jsonb(format('Serial number %s is still in our stock, so it has not been sold.', v_serial));
    END IF;
  END IF;
  IF e.card_id IS NOT NULL THEN
    v_basis := 'equipment_card';
    v_start := coalesce(e.warranty_start, e.sold_on);
    v_end := coalesce(e.warranty_end, CASE WHEN v_months IS NOT NULL AND v_start IS NOT NULL THEN (v_start + make_interval(months => v_months))::date END);
    IF e.invoice_entry IS NOT NULL THEN
      v_invj := erp._svc_invoice(p_company, e.invoice_entry, e.card_code, v_item);
    END IF;
    IF v_card IS NOT NULL AND e.card_code <> v_card THEN
      v_msgs := v_msgs || to_jsonb(format('The equipment card shows serial %s with customer %s, not %s.', v_serial, e.card_code, v_card));
    END IF;
  ELSIF v_inv IS NOT NULL THEN
    v_invj := erp._svc_invoice(p_company, v_inv, v_card, v_item);
    IF v_invj IS NULL THEN
      v_msgs := v_msgs || to_jsonb(format('A/R invoice %s is not an invoice of customer %s for %s. Choose the invoice that sold this unit.', v_inv, coalesce(v_card, '?'), v_item));
    ELSE
      v_basis := 'invoice';
      v_start := (v_invj->>'doc_date')::date;
      IF v_months IS NOT NULL THEN
        v_end := (v_start + make_interval(months => v_months))::date;
      END IF;
    END IF;
  END IF;

  IF v_card IS NOT NULL THEN
    SELECT * INTO k FROM erp.service_contract c
     WHERE c.company_code = p_company AND c.card_code = v_card AND c.state = 'active' AND v_on BETWEEN c.starts_on AND c.ends_on
       AND (c.all_items OR EXISTS (SELECT 1 FROM erp.service_contract_line cl WHERE cl.company_code = c.company_code AND cl.contract_id = c.contract_id
                                     AND cl.item_code = v_item AND (cl.serial_no IS NULL OR cl.serial_no = v_serial)))
     ORDER BY c.ends_on DESC LIMIT 1;
  END IF;

  IF v_end IS NOT NULL AND v_end >= v_on THEN
    v_status := 'in_warranty';
  ELSIF k.contract_id IS NOT NULL THEN
    v_status := 'contract';
  ELSIF v_end IS NOT NULL THEN
    v_status := 'out_of_warranty';
    v_msgs := v_msgs || to_jsonb(format('Out of warranty: the warranty of %s%s ended on %s.', v_item, coalesce(' serial ' || v_serial, ''), to_char(v_end, 'DD Mon YYYY')));
  ELSIF v_start IS NOT NULL AND v_months IS NULL THEN
    v_status := 'no_rule';
    v_msgs := v_msgs || to_jsonb(format('No warranty period is set for %s. Ask the service manager to set it in Service Setup.', v_item));
  ELSE
    v_status := 'unknown';
    IF v_serial IS NOT NULL OR v_inv IS NULL THEN
      v_msgs := v_msgs || to_jsonb('No sale found for this unit. Choose the A/R invoice that sold it, or create its equipment card.'::text);
    END IF;
  END IF;
  RETURN jsonb_build_object('status', v_status, 'flagged', v_status = 'out_of_warranty', 'warranty_start', v_start, 'warranty_end', v_end, 'basis', v_basis,
    'card_id', e.card_id, 'invoice', v_invj, 'months', v_months, 'serial_known', v_known,
    'contract', CASE WHEN k.contract_id IS NOT NULL THEN jsonb_build_object('contract_id', k.contract_id, 'doc_no', k.doc_no, 'ends_on', k.ends_on,
                       'response_hours', k.response_hours, 'covers_parts', k.covers_parts, 'covers_labour', k.covers_labour) END,
    'messages', v_msgs);
END $$;

CREATE OR REPLACE FUNCTION erp.service_warranty(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._svc_guard(p_company, false);
  RETURN erp._svc_warranty(p_company, p);
END $$;

-- ============ Service: equipment cards ============
-- p_card: {card_id (edit), item_code, serial_no, card_code, invoice_entry, sold_on, warranty_end (override), note}
-- warranty_start = the invoice date (or sold_on); warranty_end = start + the item's warranty months, unless given.
CREATE OR REPLACE FUNCTION erp.equipment_card_save(p_company varchar, p_card jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  old      erp.equipment_card;
  v_id     integer := erp._num(p_card->>'card_id')::integer;
  v_item   text := nullif(btrim(p_card->>'item_code'), '');
  v_serial text := nullif(btrim(p_card->>'serial_no'), '');
  v_card   text := nullif(btrim(p_card->>'card_code'), '');
  v_inv    integer := erp._num(p_card->>'invoice_entry')::integer;
  v_sold   date := erp._date(p_card->>'sold_on');
  v_end    date := erp._date(p_card->>'warranty_end');
  v_invj   jsonb;
  v_months integer;
BEGIN
  u := erp._svc_guard(p_company, true, 'change equipment cards');
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.equipment_card WHERE company_code = p_company AND card_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Equipment card % was not found in company %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_item IS NULL OR NOT EXISTS (SELECT 1 FROM erp.item WHERE company_code = p_company AND item_code = v_item) THEN
    RAISE EXCEPTION 'Choose an item that exists in company %.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_serial IS NULL THEN
    RAISE EXCEPTION 'Enter the serial number.' USING ERRCODE = 'P0001';
  END IF;
  IF v_card IS NULL OR NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card AND kind = 'customer') THEN
    RAISE EXCEPTION 'Choose the customer who has the unit.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.equipment_card WHERE company_code = p_company AND item_code = v_item AND serial_no = v_serial AND card_id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'Serial number % of % already has an equipment card.', v_serial, v_item USING ERRCODE = 'P0001';
  END IF;
  IF v_inv IS NOT NULL THEN
    v_invj := erp._svc_invoice(p_company, v_inv, v_card, v_item);
    IF v_invj IS NULL THEN
      RAISE EXCEPTION 'A/R invoice % is not an invoice of customer % for %. Choose the invoice that sold this unit.', v_inv, v_card, v_item USING ERRCODE = 'P0001';
    END IF;
    v_sold := (v_invj->>'doc_date')::date;
  END IF;
  IF v_sold IS NOT NULL AND v_sold > current_date THEN
    RAISE EXCEPTION 'The sale date can''t be in the future.' USING ERRCODE = 'P0001';
  END IF;
  v_months := erp._svc_months(p_company, v_item);
  IF v_end IS NULL AND v_sold IS NOT NULL AND v_months IS NOT NULL THEN
    v_end := (v_sold + make_interval(months => v_months))::date;
  END IF;
  IF v_end IS NOT NULL AND v_sold IS NOT NULL AND v_end < v_sold THEN
    RAISE EXCEPTION 'The warranty end can''t be before the sale date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO erp.equipment_card (company_code, item_code, serial_no, card_code, invoice_entry, sold_on, warranty_start, warranty_end, note, created_by, updated_by)
    VALUES (p_company, v_item, v_serial, v_card, v_inv, v_sold, v_sold, v_end, nullif(btrim(p_card->>'note'), ''), u.user_id, u.user_id) RETURNING card_id INTO v_id;
  ELSE
    UPDATE erp.equipment_card SET item_code = v_item, serial_no = v_serial, card_code = v_card, invoice_entry = v_inv, sold_on = v_sold, warranty_start = v_sold,
           warranty_end = v_end, note = nullif(btrim(p_card->>'note'), ''), updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND card_id = v_id;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.card_id IS NULL THEN 'equipment_card_create' ELSE 'equipment_card_update' END, 'equipment_card', v_id::text,
          jsonb_build_object('item_code', v_item, 'serial_no', v_serial, 'card_code', v_card, 'invoice_entry', v_inv, 'sold_on', v_sold, 'warranty_end', v_end,
                             'before', CASE WHEN old.card_id IS NOT NULL THEN to_jsonb(old) - 'updated_by' - 'updated_at' END));
  RETURN jsonb_build_object('card_id', v_id, 'warranty_end', v_end);
END $$;

CREATE OR REPLACE FUNCTION erp.equipment_card_info(p_company varchar, p_card_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  e erp.equipment_card;
BEGIN
  u := erp._svc_guard(p_company, false);
  SELECT * INTO e FROM erp.equipment_card WHERE company_code = p_company AND card_id = p_card_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Equipment card % was not found in company %.', p_card_id, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'card', to_jsonb(e) || jsonb_build_object('item_name', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = e.item_code),
                                              'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = e.card_code),
                                              'invoice', CASE WHEN e.invoice_entry IS NOT NULL THEN erp._svc_invoice(p_company, e.invoice_entry, e.card_code, e.item_code) END),
    'warranty', erp._svc_warranty(p_company, jsonb_build_object('card_code', e.card_code, 'item_code', e.item_code, 'serial_no', e.serial_no)),
    'calls', coalesce((SELECT jsonb_agg(jsonb_build_object('call_id', c.call_id, 'doc_no', c.doc_no, 'subject', c.subject, 'status', c.status, 'opened_at', c.opened_at,
                                                          'warranty_status', c.warranty_status) ORDER BY c.opened_at DESC)
                         FROM erp.service_call c WHERE c.company_code = p_company AND (c.equipment_card_id = e.card_id OR (c.item_code = e.item_code AND c.serial_no = e.serial_no))), '[]'::jsonb),
    'can_write', erp.can_write('service'));
END $$;

-- ============ Service: contracts ============
-- p_c: {contract_id (edit a draft), card_code, starts_on, ends_on, response_hours, covers_parts, covers_labour, covers_travel, all_items,
--       terms, lines:[{item_code, serial_no, note}]}
CREATE OR REPLACE FUNCTION erp.service_contract_save(p_company varchar, p_c jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  old    erp.service_contract;
  v_id   integer := erp._num(p_c->>'contract_id')::integer;
  v_card text := nullif(btrim(p_c->>'card_code'), '');
  v_from date := erp._date(p_c->>'starts_on');
  v_to   date := erp._date(p_c->>'ends_on');
  v_resp numeric := erp._num(p_c->>'response_hours');
  v_all  boolean := coalesce((p_c->>'all_items')::boolean, false);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_c->'lines') = 'array' THEN p_c->'lines' ELSE '[]'::jsonb END;
  l      jsonb;
  i      integer := 0;
  nb     jsonb;
  v_no   text;
  v_seen text[] := '{}';
BEGIN
  u := erp._svc_guard(p_company, true, 'change service contracts');
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.service_contract WHERE company_code = p_company AND contract_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Service contract % was not found in company %.', v_id, p_company USING ERRCODE = 'P0001';
    ELSIF old.state <> 'draft' THEN
      RAISE EXCEPTION 'Service contract % is %. Only draft contracts can be changed.', old.doc_no, old.state USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_card IS NULL OR NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card AND kind = 'customer') THEN
    RAISE EXCEPTION 'Choose the customer.' USING ERRCODE = 'P0001';
  END IF;
  IF v_from IS NULL OR v_to IS NULL THEN
    RAISE EXCEPTION 'Enter the start and end dates.' USING ERRCODE = 'P0001';
  ELSIF v_to < v_from THEN
    RAISE EXCEPTION 'The end date can''t be before the start date.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_c->>'response_hours'), '') IS NOT NULL AND (v_resp IS NULL OR v_resp < 0) THEN
    RAISE EXCEPTION 'The response time must be a number of hours, zero or more.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_all AND jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add the items or serial numbers the contract covers, or tick "All items".' USING ERRCODE = 'P0001';
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    IF nullif(btrim(l->>'item_code'), '') IS NULL OR NOT EXISTS (SELECT 1 FROM erp.item WHERE company_code = p_company AND item_code = btrim(l->>'item_code')) THEN
      RAISE EXCEPTION 'Line %: choose an item that exists in company %.', i, p_company USING ERRCODE = 'P0001';
    END IF;
    IF (btrim(l->>'item_code') || '|' || coalesce(nullif(btrim(l->>'serial_no'), ''), '*')) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Line %: % is entered twice.', i, btrim(l->>'item_code') || coalesce(' ' || nullif(btrim(l->>'serial_no'), ''), '') USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || (btrim(l->>'item_code') || '|' || coalesce(nullif(btrim(l->>'serial_no'), ''), '*'));
  END LOOP;
  IF v_id IS NULL THEN
    nb := erp._ps_number(p_company, 190);
    v_id := (nb->>'entry')::integer;
    v_no := nb->>'no';
    INSERT INTO erp.service_contract (company_code, contract_id, doc_no, card_code, starts_on, ends_on, response_hours, covers_parts, covers_labour, covers_travel,
                                      all_items, terms, created_by, updated_by)
    VALUES (p_company, v_id, v_no, v_card, v_from, v_to, v_resp, coalesce((p_c->>'covers_parts')::boolean, false), coalesce((p_c->>'covers_labour')::boolean, false),
            coalesce((p_c->>'covers_travel')::boolean, false), v_all, nullif(btrim(p_c->>'terms'), ''), u.user_id, u.user_id);
  ELSE
    v_no := old.doc_no;
    UPDATE erp.service_contract SET card_code = v_card, starts_on = v_from, ends_on = v_to, response_hours = v_resp,
           covers_parts = coalesce((p_c->>'covers_parts')::boolean, false), covers_labour = coalesce((p_c->>'covers_labour')::boolean, false),
           covers_travel = coalesce((p_c->>'covers_travel')::boolean, false), all_items = v_all, terms = nullif(btrim(p_c->>'terms'), ''),
           updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND contract_id = v_id;
    DELETE FROM erp.service_contract_line WHERE company_code = p_company AND contract_id = v_id;
  END IF;
  i := 0;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    INSERT INTO erp.service_contract_line (company_code, contract_id, line_num, item_code, serial_no, note)
    VALUES (p_company, v_id, i, btrim(l->>'item_code'), nullif(btrim(l->>'serial_no'), ''), nullif(btrim(l->>'note'), ''));
    i := i + 1;
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.contract_id IS NULL THEN 'service_contract_create' ELSE 'service_contract_update' END, 'service_contract', v_id::text,
          jsonb_build_object('doc_no', v_no, 'input', p_c));
  RETURN jsonb_build_object('contract_id', v_id, 'doc_no', v_no, 'state', 'draft');
END $$;

-- p_action: activate (draft → active), end (active → ended, note needed), cancel (draft → cancelled, note needed).
CREATE OR REPLACE FUNCTION erp.service_contract_status(p_company varchar, p_contract integer, p_action text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  k   erp.service_contract;
  v_to text;
BEGIN
  u := erp._svc_guard(p_company, true, 'change service contracts');
  SELECT * INTO k FROM erp.service_contract WHERE company_code = p_company AND contract_id = p_contract FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service contract % was not found in company %.', p_contract, p_company USING ERRCODE = 'P0001';
  END IF;
  IF p_action = 'activate' AND k.state = 'draft' THEN
    IF k.ends_on < current_date THEN
      RAISE EXCEPTION 'Service contract % ended on %. Change the dates before activating it.', k.doc_no, to_char(k.ends_on, 'DD Mon YYYY') USING ERRCODE = 'P0001';
    END IF;
    v_to := 'active';
    UPDATE erp.service_contract SET state = 'active', activated_by = u.user_id, activated_at = now() WHERE company_code = p_company AND contract_id = p_contract;
  ELSIF (p_action = 'end' AND k.state = 'active') OR (p_action = 'cancel' AND k.state = 'draft') THEN
    IF nullif(btrim(p_note), '') IS NULL THEN
      RAISE EXCEPTION 'Add a note saying why.' USING ERRCODE = 'P0001';
    END IF;
    v_to := CASE p_action WHEN 'end' THEN 'ended' ELSE 'cancelled' END;
    UPDATE erp.service_contract SET state = v_to, ended_by = u.user_id, ended_at = now(), end_note = btrim(p_note) WHERE company_code = p_company AND contract_id = p_contract;
  ELSE
    RAISE EXCEPTION 'Service contract % is %, so it can''t be %.', k.doc_no, k.state,
      CASE p_action WHEN 'activate' THEN 'activated' WHEN 'end' THEN 'ended' WHEN 'cancel' THEN 'cancelled' ELSE 'changed that way' END USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'service_contract_' || p_action, 'service_contract', p_contract::text,
          jsonb_build_object('doc_no', k.doc_no, 'from', k.state, 'to', v_to, 'note', nullif(btrim(p_note), '')));
  RETURN jsonb_build_object('contract_id', p_contract, 'state', v_to);
END $$;

CREATE OR REPLACE FUNCTION erp.service_contract_info(p_company varchar, p_contract integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  k erp.service_contract;
BEGIN
  u := erp._svc_guard(p_company, false);
  SELECT * INTO k FROM erp.service_contract WHERE company_code = p_company AND contract_id = p_contract;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service contract % was not found in company %.', p_contract, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'contract', to_jsonb(k) || jsonb_build_object('card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = k.card_code),
                                                  'created_by_name', erp._adm_name(k.created_by), 'activated_by_name', erp._adm_name(k.activated_by),
                                                  'expired', k.state = 'active' AND k.ends_on < current_date),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'item_code', l.item_code, 'serial_no', l.serial_no, 'note', l.note,
                                                          'item_name', (SELECT name FROM erp.item i WHERE i.company_code = l.company_code AND i.item_code = l.item_code)) ORDER BY l.line_num)
                         FROM erp.service_contract_line l WHERE l.company_code = p_company AND l.contract_id = p_contract), '[]'::jsonb),
    'calls', coalesce((SELECT jsonb_agg(jsonb_build_object('call_id', c.call_id, 'doc_no', c.doc_no, 'subject', c.subject, 'status', c.status, 'opened_at', c.opened_at) ORDER BY c.opened_at DESC)
                         FROM erp.service_call c WHERE c.company_code = p_company AND c.contract_id = p_contract), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', erp._adm_name(nullif(a.actor, '')::uuid), 'note', a.detail->>'note') ORDER BY a.at)
                            FROM erp.audit_log a WHERE a.company_code = p_company AND a.object = 'service_contract' AND a.object_ref = p_contract::text
                             AND a.actor ~ '^[0-9a-f-]{36}$'), '[]'::jsonb),
    'can_write', erp.can_write('service'));
END $$;

-- ============ Service: calls ============
-- p_call: {call_id (edit), card_code, contact, phone, item_code, serial_no, invoice_entry, subject, problem, priority, technician}
-- The warranty is checked on every save (at the date the call was opened) and stored on the call; out of warranty = flagged.
-- A serial with an invoice and no equipment card gets one.
CREATE OR REPLACE FUNCTION erp.service_call_save(p_company varchar, p_call jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  old      erp.service_call;
  it       erp.item;
  tech     erp.app_user;
  v_id     integer := erp._num(p_call->>'call_id')::integer;
  v_card   text := nullif(btrim(p_call->>'card_code'), '');
  v_item   text := nullif(btrim(p_call->>'item_code'), '');
  v_serial text := nullif(btrim(p_call->>'serial_no'), '');
  v_inv    integer := erp._num(p_call->>'invoice_entry')::integer;
  v_subj   text := nullif(btrim(p_call->>'subject'), '');
  v_prio   text := coalesce(nullif(btrim(p_call->>'priority'), ''), 'medium');
  v_tech   uuid;
  v_opened timestamptz;
  w        jsonb;
  v_ecard  integer;
  nb       jsonb;
  v_no     text;
  v_due    timestamptz;
BEGIN
  u := erp._svc_guard(p_company, true, 'log service calls');
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.service_call WHERE company_code = p_company AND call_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Service call % was not found in company %.', v_id, p_company USING ERRCODE = 'P0001';
    ELSIF old.status IN ('closed', 'cancelled') THEN
      RAISE EXCEPTION 'Service call % is %. It can''t be changed.', old.doc_no, old.status USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_card IS NULL THEN
    RAISE EXCEPTION 'Choose the customer.' USING ERRCODE = 'P0001';
  ELSIF NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card AND kind = 'customer') THEN
    RAISE EXCEPTION 'Customer % does not exist in company %.', v_card, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_subj IS NULL THEN
    RAISE EXCEPTION 'Describe the problem in a few words (subject).' USING ERRCODE = 'P0001';
  END IF;
  IF v_prio NOT IN ('low', 'medium', 'high') THEN
    RAISE EXCEPTION 'Choose the priority: low, medium or high.' USING ERRCODE = 'P0001';
  END IF;
  IF v_item IS NOT NULL THEN
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_item;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item % does not exist in company %.', v_item, p_company USING ERRCODE = 'P0001';
    END IF;
    IF coalesce(it.serial_managed, false) AND v_serial IS NULL THEN
      RAISE EXCEPTION '% is serial-managed. Enter the serial number from the unit.', v_item USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_serial IS NOT NULL OR v_inv IS NOT NULL THEN
    RAISE EXCEPTION 'Choose the item the serial number or invoice is for.' USING ERRCODE = 'P0001';
  END IF;
  IF v_inv IS NOT NULL AND erp._svc_invoice(p_company, v_inv, v_card, v_item) IS NULL THEN
    RAISE EXCEPTION 'A/R invoice % is not an invoice of customer % for %. Choose the invoice that sold this unit.', v_inv, v_card, v_item USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(p_call->>'technician'), '') IS NOT NULL THEN
    BEGIN
      v_tech := (p_call->>'technician')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Choose the technician from the list.' USING ERRCODE = 'P0001';
    END;
    SELECT * INTO tech FROM erp.app_user a WHERE a.user_id = v_tech AND a.active AND erp._adm_level(a.position_code, 'service') IS NOT NULL
       AND (a.company_code = p_company OR EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = a.user_id AND uc.company_code = p_company));
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The technician must be an active user with Service access in company %.', p_company USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_opened := coalesce(old.opened_at, now());
  w := erp._svc_warranty(p_company, jsonb_build_object('card_code', v_card, 'item_code', v_item, 'serial_no', v_serial, 'invoice_entry', v_inv,
                                                       'on_date', (v_opened AT TIME ZONE 'Asia/Dubai')::date));
  v_ecard := (w->>'card_id')::integer;
  IF v_ecard IS NULL AND v_serial IS NOT NULL AND w->'invoice' IS NOT NULL AND jsonb_typeof(w->'invoice') = 'object' THEN
    INSERT INTO erp.equipment_card (company_code, item_code, serial_no, card_code, invoice_entry, sold_on, warranty_start, warranty_end, note, created_by, updated_by)
    VALUES (p_company, v_item, v_serial, v_card, v_inv, (w->'invoice'->>'doc_date')::date, (w->>'warranty_start')::date, (w->>'warranty_end')::date,
            'Created from a service call', u.user_id, u.user_id)
    RETURNING card_id INTO v_ecard;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'equipment_card_create', 'equipment_card', v_ecard::text,
            jsonb_build_object('item_code', v_item, 'serial_no', v_serial, 'card_code', v_card, 'invoice_entry', v_inv, 'from', 'service_call'));
  END IF;
  IF w->'contract' IS NOT NULL AND jsonb_typeof(w->'contract') = 'object' AND (w->'contract'->>'response_hours') IS NOT NULL THEN
    v_due := v_opened + make_interval(secs => (w->'contract'->>'response_hours')::numeric * 3600);
  END IF;

  IF v_id IS NULL THEN
    nb := erp._ps_number(p_company, 191);
    v_id := (nb->>'entry')::integer;
    v_no := nb->>'no';
    INSERT INTO erp.service_call (company_code, call_id, doc_no, card_code, contact, phone, item_code, serial_no, invoice_entry, equipment_card_id, contract_id,
                                  subject, problem, priority, technician, technician_name, warranty_status, warranty_end, warranty_note, flagged, opened_at,
                                  due_by, created_by, updated_by)
    VALUES (p_company, v_id, v_no, v_card, nullif(btrim(p_call->>'contact'), ''), nullif(btrim(p_call->>'phone'), ''), v_item, v_serial, v_inv, v_ecard,
            (w->'contract'->>'contract_id')::integer, v_subj, nullif(btrim(p_call->>'problem'), ''), v_prio, v_tech, tech.display_name, w->>'status',
            (w->>'warranty_end')::date, (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(w->'messages') x), (w->>'flagged')::boolean, v_opened,
            v_due, u.user_id, u.user_id);
  ELSE
    v_no := old.doc_no;
    UPDATE erp.service_call SET card_code = v_card, contact = nullif(btrim(p_call->>'contact'), ''), phone = nullif(btrim(p_call->>'phone'), ''),
           item_code = v_item, serial_no = v_serial, invoice_entry = v_inv, equipment_card_id = v_ecard, contract_id = (w->'contract'->>'contract_id')::integer,
           subject = v_subj, problem = nullif(btrim(p_call->>'problem'), ''), priority = v_prio, technician = v_tech, technician_name = tech.display_name,
           warranty_status = w->>'status', warranty_end = (w->>'warranty_end')::date,
           warranty_note = (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(w->'messages') x), flagged = (w->>'flagged')::boolean, due_by = v_due,
           updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND call_id = v_id;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.call_id IS NULL THEN 'service_call_create' ELSE 'service_call_update' END, 'service_call', v_id::text,
          jsonb_build_object('doc_no', v_no, 'card_code', v_card, 'item_code', v_item, 'serial_no', v_serial, 'technician', v_tech,
                             'warranty_status', w->>'status', 'flagged', w->'flagged',
                             'before', CASE WHEN old.call_id IS NOT NULL THEN jsonb_build_object('technician', old.technician, 'priority', old.priority,
                                                                                                    'warranty_status', old.warranty_status) END));
  RETURN jsonb_build_object('call_id', v_id, 'doc_no', v_no, 'warranty', w, 'equipment_card_id', v_ecard);
END $$;

-- open → in_progress → resolved (needs the solution) → closed; resolved → in_progress (reopen); open / in_progress → cancelled (note).
CREATE OR REPLACE FUNCTION erp.service_call_status(p_company varchar, p_call integer, p_status text, p_text text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  c erp.service_call;
  v_txt text := nullif(btrim(p_text), '');
BEGIN
  u := erp._svc_guard(p_company, true, 'update service calls');
  SELECT * INTO c FROM erp.service_call WHERE company_code = p_company AND call_id = p_call FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service call % was not found in company %.', p_call, p_company USING ERRCODE = 'P0001';
  END IF;
  IF NOT ((c.status = 'open' AND p_status IN ('in_progress', 'resolved', 'cancelled'))
       OR (c.status = 'in_progress' AND p_status IN ('resolved', 'cancelled'))
       OR (c.status = 'resolved' AND p_status IN ('closed', 'in_progress'))) THEN
    RAISE EXCEPTION 'Service call % is %, so it can''t be moved to %.', c.doc_no, replace(c.status, '_', ' '), replace(coalesce(p_status, '?'), '_', ' ')
      USING ERRCODE = 'P0001';
  END IF;
  IF p_status = 'resolved' AND coalesce(v_txt, c.solution) IS NULL THEN
    RAISE EXCEPTION 'Enter the solution before marking the call resolved.' USING ERRCODE = 'P0001';
  END IF;
  IF p_status = 'cancelled' AND v_txt IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why the call is cancelled.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.service_call SET status = p_status,
         solution = CASE WHEN p_status = 'resolved' THEN coalesce(v_txt, solution) ELSE solution END,
         cancel_note = CASE WHEN p_status = 'cancelled' THEN v_txt ELSE cancel_note END,
         resolved_at = CASE WHEN p_status = 'resolved' THEN now() WHEN p_status = 'in_progress' THEN NULL ELSE resolved_at END,
         closed_at = CASE WHEN p_status = 'closed' THEN now() ELSE closed_at END, updated_by = u.user_id, updated_at = now()
   WHERE company_code = p_company AND call_id = p_call;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'service_call_' || p_status, 'service_call', p_call::text,
          jsonb_build_object('doc_no', c.doc_no, 'from', c.status, 'to', p_status, 'text', v_txt));
  RETURN jsonb_build_object('call_id', p_call, 'status', p_status);
END $$;

-- Spare parts for a call: an A7 goods issue (inventory_doc_create: needs Service full and Inventory full; the requester's goods
-- issue limit applies), with the company's spare-parts reason and the call number as reference, linked to the call.
-- p_header: {doc_date, whs_code, comments}; p_lines: [{item_code, qty, bin_code, lots}]
CREATE OR REPLACE FUNCTION erp.service_call_parts_issue(p_company varchar, p_call integer, p_header jsonb, p_lines jsonb, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  c  erp.service_call;
  v_r text;
  r  jsonb;
BEGIN
  u := erp._svc_guard(p_company, true, 'issue spare parts');
  SELECT * INTO c FROM erp.service_call WHERE company_code = p_company AND call_id = p_call FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service call % was not found in company %.', p_call, p_company USING ERRCODE = 'P0001';
  ELSIF c.status IN ('closed', 'cancelled') THEN
    RAISE EXCEPTION 'Service call % is %. Parts can''t be issued to it.', c.doc_no, c.status USING ERRCODE = 'P0001';
  END IF;
  SELECT parts_reason_code INTO v_r FROM erp.service_setting WHERE company_code = p_company;
  IF v_r IS NULL THEN
    RAISE EXCEPTION 'No spare-parts reason is set for company %. Ask the service manager to set it in Service Setup.', p_company USING ERRCODE = 'P0001';
  END IF;
  r := erp.inventory_doc_create(p_company, 60,
         coalesce(p_header, '{}'::jsonb) || jsonb_build_object('reason_code', v_r, 'acct_code', NULL, 'customer_ref', c.doc_no,
           'comments', coalesce(nullif(btrim(p_header->>'comments'), ''), format('Spare parts for service call %s · %s', c.doc_no, c.card_code))),
         p_lines, p_reason);
  INSERT INTO erp.service_call_part (company_code, call_id, obj_type, doc_entry, created_by) VALUES (p_company, p_call, 60, (r->>'doc_entry')::integer, u.user_id);
  IF c.status = 'open' THEN
    UPDATE erp.service_call SET status = 'in_progress', updated_by = u.user_id, updated_at = now() WHERE company_code = p_company AND call_id = p_call;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'service_call_parts', 'service_call', p_call::text,
          jsonb_build_object('doc_no', c.doc_no, 'issue_entry', r->'doc_entry', 'issue_no', r->'doc_no', 'state', r->'state', 'value', r->'value'));
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.service_call_info(p_company varchar, p_call integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  c erp.service_call;
BEGIN
  u := erp._svc_guard(p_company, false);
  SELECT * INTO c FROM erp.service_call WHERE company_code = p_company AND call_id = p_call;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service call % was not found in company %.', p_call, p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'call', to_jsonb(c) || jsonb_build_object(
      'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = c.card_code),
      'item_name', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = c.item_code),
      'serial_managed', (SELECT coalesce(serial_managed, false) FROM erp.item WHERE company_code = p_company AND item_code = c.item_code),
      'invoice', CASE WHEN c.invoice_entry IS NOT NULL THEN erp._svc_invoice(p_company, c.invoice_entry, c.card_code, c.item_code) END,
      'contract_no', (SELECT doc_no FROM erp.service_contract k WHERE k.company_code = p_company AND k.contract_id = c.contract_id),
      'created_by_name', erp._adm_name(c.created_by),
      'overdue', c.status IN ('open', 'in_progress') AND c.due_by IS NOT NULL AND c.due_by < now()),
    'parts', coalesce((SELECT jsonb_agg(jsonb_build_object('doc_entry', d.doc_entry, 'doc_no', w.doc_no, 'doc_date', d.doc_date, 'total', d.total, 'state', w.state,
                                                          'status', d.status) ORDER BY d.doc_entry)
                         FROM erp.service_call_part p
                         JOIN erp.document d ON d.company_code = p.company_code AND d.obj_type = p.obj_type AND d.doc_entry = p.doc_entry
                         JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
                        WHERE p.company_code = p_company AND p.call_id = p_call), '[]'::jsonb),
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object('call_id', o.call_id, 'doc_no', o.doc_no, 'subject', o.subject, 'status', o.status, 'opened_at', o.opened_at) ORDER BY o.opened_at DESC)
                           FROM erp.service_call o WHERE o.company_code = p_company AND o.call_id <> c.call_id AND c.serial_no IS NOT NULL
                            AND o.item_code = c.item_code AND o.serial_no = c.serial_no), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', erp._adm_name(nullif(a.actor, '')::uuid),
                            'text', coalesce(a.detail->>'text', a.detail->>'issue_no')) ORDER BY a.at, a.audit_id)
                           FROM erp.audit_log a WHERE a.company_code = p_company AND a.object = 'service_call' AND a.object_ref = p_call::text
                            AND a.actor ~ '^[0-9a-f-]{36}$'), '[]'::jsonb),
    'can_write', erp.can_write('service'),
    'can_inventory', erp.can_write('inventory'));
END $$;

-- ============ Lookups for the production and service screens ============
-- Comboboxes on these screens need customers, items and invoices that a Production- or Service-only position can't read directly
-- (A1 module policies). p: {kind: customer | item | invoice, q, card_code, item_code}. Read only, at most 8 rows (invoices 20).
CREATE OR REPLACE FUNCTION erp.ps_lookup(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_q    text := '%' || coalesce(btrim(p->>'q'), '') || '%';
  v_kind text := p->>'kind';
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF NOT (erp.can_read('production') OR erp.can_read('service') OR erp.can_read('inventory') OR erp.can_read('sales')) THEN
    RAISE EXCEPTION 'Your position does not include Production or Service. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF v_kind = 'customer' THEN
    IF NOT (erp.can_read('service') OR erp.can_read('sales')) THEN
      RAISE EXCEPTION 'Your position does not include Service. Ask the system admin if you need it.' USING ERRCODE = '42501';
    END IF;
    RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('card_code', card_code, 'name', name, 'city', city, 'phone', phone) ORDER BY card_code)
                       FROM (SELECT * FROM erp.business_partner WHERE company_code = p_company AND kind = 'customer' AND active
                               AND (card_code ILIKE v_q OR name ILIKE v_q OR phone ILIKE v_q) ORDER BY card_code LIMIT 8) b), '[]'::jsonb);
  ELSIF v_kind = 'item' THEN
    RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', item_code, 'name', name, 'inventory_uom', inventory_uom, 'is_stock', coalesce(is_stock, false),
                                                         'serial_managed', coalesce(serial_managed, false), 'batch_managed', coalesce(batch_managed, false)) ORDER BY item_code)
                       FROM (SELECT * FROM erp.item WHERE company_code = p_company AND active
                               AND (item_code ILIKE v_q OR name ILIKE v_q OR barcode ILIKE v_q) ORDER BY item_code LIMIT 8) i), '[]'::jsonb);
  ELSIF v_kind = 'invoice' THEN
    IF NOT (erp.can_read('service') OR erp.can_read('sales')) THEN
      RAISE EXCEPTION 'Your position does not include Service. Ask the system admin if you need it.' USING ERRCODE = '42501';
    END IF;
    RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('doc_entry', doc_entry, 'doc_num', doc_num, 'doc_date', doc_date, 'source', source) ORDER BY doc_date DESC, doc_entry DESC)
                       FROM (SELECT d.* FROM erp.document d WHERE d.company_code = p_company AND d.obj_type = 13 AND d.card_code = p->>'card_code'
                               AND EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = d.company_code AND l.obj_type = 13 AND l.doc_entry = d.doc_entry
                                             AND l.item_code = p->>'item_code')
                              ORDER BY d.doc_date DESC LIMIT 20) x), '[]'::jsonb);
  END IF;
  RAISE EXCEPTION 'Unknown lookup %.', coalesce(v_kind, '(none)') USING ERRCODE = 'P0001';
END $$;
REVOKE ALL ON FUNCTION erp.ps_lookup(varchar, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.ps_lookup(varchar, jsonb) TO authenticated;

-- ============ Replaced: document types with numbering (A10) ============
CREATE OR REPLACE FUNCTION erp._adm_doc_types() RETURNS TABLE (obj_type integer, label text, module text, sort integer)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    (23, 'Sales Quotation', 'sales', 1), (17, 'Sales Order', 'sales', 2), (15, 'Delivery', 'sales', 3),
    (13, 'A/R Invoice', 'sales', 4), (14, 'A/R Credit Memo', 'sales', 5),
    (1470000113, 'Purchase Request', 'purchase', 10), (540000006, 'Purchase Quotation', 'purchase', 11), (22, 'Purchase Order', 'purchase', 12),
    (20, 'Goods Receipt PO', 'purchase', 13), (204, 'A/P Down Payment Invoice', 'purchase', 14), (18, 'A/P Invoice', 'purchase', 15),
    (69, 'Landed Costs', 'purchase', 16),
    (24, 'Incoming Payment', 'banking', 20), (46, 'Outgoing Payment', 'banking', 21), (25, 'Deposit', 'banking', 22),
    (1250000001, 'Inventory Transfer Request', 'inventory', 30), (67, 'Inventory Transfer', 'inventory', 31),
    (59, 'Goods Receipt', 'inventory', 32), (60, 'Goods Issue', 'inventory', 33), (1470000065, 'Inventory Counting', 'inventory', 34),
    (2001, 'Customer code', 'bp', 40), (2002, 'Supplier code', 'bp', 41), (2003, 'Lead code', 'bp', 42),
    (171, 'Employee code', 'hr', 50),
    (202, 'Production Order', 'production', 60),
    (191, 'Service Call', 'service', 70), (190, 'Service Contract', 'service', 71)) AS v(obj_type, label, module, sort)
$$;

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._prd_guard(varchar, boolean, text), erp._svc_guard(varchar, boolean, text), erp._ps_number(varchar, integer),
  erp._ps_acct_check(varchar, text, text), erp._prd_shortages(varchar, integer), erp._prd_short_msg(jsonb), erp._prd_lock(varchar, integer),
  erp._prd_wip(varchar), erp._prd_stock_doc(varchar, integer, date, text, text, integer, jsonb, uuid), erp._svc_months(varchar, text),
  erp._svc_invoice(varchar, integer, text, text), erp._svc_warranty(varchar, jsonb), erp._adm_doc_types()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.production_setup(varchar), erp.production_setting_set(varchar, jsonb), erp.prod_resource_save(varchar, jsonb),
  erp.mould_maintenance_record(varchar, text, jsonb), erp.bom_save(varchar, jsonb), erp.bom_delete(varchar, text), erp.bom_info(varchar, text),
  erp.prod_order_create(varchar, jsonb), erp.prod_order_checks(varchar, integer), erp.prod_order_release(varchar, integer),
  erp.prod_order_issue(varchar, integer, jsonb, jsonb), erp.prod_order_receipt(varchar, integer, jsonb), erp.prod_order_close(varchar, integer, text),
  erp.prod_order_cancel(varchar, integer, text), erp.prod_order_info(varchar, integer),
  erp.service_setup(varchar), erp.service_setting_set(varchar, jsonb), erp.warranty_rule_save(varchar, jsonb), erp.service_warranty(varchar, jsonb),
  erp.equipment_card_save(varchar, jsonb), erp.equipment_card_info(varchar, integer), erp.service_contract_save(varchar, jsonb),
  erp.service_contract_status(varchar, integer, text, text), erp.service_contract_info(varchar, integer), erp.service_call_save(varchar, jsonb),
  erp.service_call_status(varchar, integer, text, text), erp.service_call_parts_issue(varchar, integer, jsonb, jsonb, text), erp.service_call_info(varchar, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.production_setup(varchar), erp.production_setting_set(varchar, jsonb), erp.prod_resource_save(varchar, jsonb),
  erp.mould_maintenance_record(varchar, text, jsonb), erp.bom_save(varchar, jsonb), erp.bom_delete(varchar, text), erp.bom_info(varchar, text),
  erp.prod_order_create(varchar, jsonb), erp.prod_order_checks(varchar, integer), erp.prod_order_release(varchar, integer),
  erp.prod_order_issue(varchar, integer, jsonb, jsonb), erp.prod_order_receipt(varchar, integer, jsonb), erp.prod_order_close(varchar, integer, text),
  erp.prod_order_cancel(varchar, integer, text), erp.prod_order_info(varchar, integer),
  erp.service_setup(varchar), erp.service_setting_set(varchar, jsonb), erp.warranty_rule_save(varchar, jsonb), erp.service_warranty(varchar, jsonb),
  erp.equipment_card_save(varchar, jsonb), erp.equipment_card_info(varchar, integer), erp.service_contract_save(varchar, jsonb),
  erp.service_contract_status(varchar, integer, text, text), erp.service_contract_info(varchar, integer), erp.service_call_save(varchar, jsonb),
  erp.service_call_status(varchar, integer, text, text), erp.service_call_parts_issue(varchar, integer, jsonb, jsonb, text), erp.service_call_info(varchar, integer)
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Accounts: work in progress, production variances, production overhead absorbed (resources), warranty and service parts.
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', v.code, v.code, v.name, v.parent, 2, true, 'other', v.grp, 'AED', false, false, 0, 'sample'
  FROM (VALUES ('1360', 'Work in progress (SAMPLE)', '1000', 1), ('5310', 'Production variances (SAMPLE)', '5000', 5),
               ('5320', 'Production overhead absorbed (SAMPLE)', '5000', 5), ('5330', 'Warranty and service parts (SAMPLE)', '5000', 5)) AS v(code, name, parent, grp)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT DO NOTHING;

INSERT INTO erp.production_setting (company_code, wip_acct, variance_acct, life_warn_pct, note)
SELECT 'ZZ99', '1360', '5310', 90, 'SAMPLE values for the test company'
 WHERE EXISTS (SELECT 1 FROM erp.account WHERE company_code = 'ZZ99' AND acct_code = '1360')
ON CONFLICT (company_code) DO NOTHING;

INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', v.obj, v.prefix, 1, 5
  FROM (VALUES (202, 'PRD-26-'), (191, 'SC-26-'), (190, 'SCT-26-')) AS v(obj, prefix)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

-- A made-in-house item and its components (sample stock in WH01).
INSERT INTO erp.item (company_code, item_code, name, group_code, sales_uom, purchase_uom, inventory_uom, is_stock, is_sold, is_bought, batch_managed,
                      serial_managed, avg_cost, active, created_on, source)
SELECT 'ZZ99', v.code, v.name, v.grp, v.uom, v.uom, v.uom, true, v.sold, NOT v.sold, false, false, v.cost, true, DATE '2026-01-01', 'sample'
  FROM (VALUES ('SMP-PRD-100', 'Kettle body 1.7 L (moulded in-house)', 101, 'PCS', true, 0::numeric),
               ('SMP-RAW-PP', 'PP resin, food grade', 104, 'KG', false, 6.5),
               ('SMP-RAW-EL', 'Heating element 2200 W', 104, 'PCS', false, 9)) AS v(code, name, grp, uom, sold, cost)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = 'ZZ99' AND group_code = 104)
ON CONFLICT DO NOTHING;

INSERT INTO erp.stock_balance (company_code, item_code, whs_code, on_hand, committed, on_order, avg_cost)
SELECT 'ZZ99', v.code, 'WH01', v.qty, 0, 0, v.cost
  FROM (VALUES ('SMP-RAW-PP', 500::numeric, 6.5::numeric), ('SMP-RAW-EL', 100, 9)) AS v(code, qty, cost)
 WHERE EXISTS (SELECT 1 FROM erp.item WHERE company_code = 'ZZ99' AND item_code = v.code)
ON CONFLICT DO NOTHING;

-- Moulds and a machine (mould attributes as in the fixed-asset design: cavities, rated life, shots done).
INSERT INTO erp.prod_resource (company_code, res_code, name, kind, unit, unit_cost, acct_code, cavities, rated_life_shots, shots_done, location, asset_no,
                               maint_every_shots, maint_every_days, last_maint_on, last_maint_shots, source, note)
SELECT 'ZZ99', v.code, v.name, v.kind, v.unit, v.cost, '5320', v.cav, v.life, v.shots, v.loc, v.asset, v.every, v.days, v.last_on, v.last_shots, 'sample', 'SAMPLE'
  FROM (VALUES ('MLD-KET-2', 'Kettle body mould, 2-cavity', 'mould', 'shot', 0.40, 2, 500000::bigint, 412000::bigint, 'WH01 moulding bay', 'FA-MLD-0001',
                50000::bigint, 180, DATE '2026-06-01', 380000::bigint),
               ('MLD-CAP-4', 'Cap mould, 4-cavity', 'mould', 'shot', 0.15, 4, 500000, 455000, 'Dongguan factory', 'FA-MLD-0002', 50000, 180, DATE '2026-03-15', 400000),
               ('INJ-250', 'Injection moulding machine 250T', 'machine', 'hour', 35, NULL, NULL, 0, 'WH01 moulding bay', 'FA-MCH-0001', NULL, 90, DATE '2026-09-01', 0))
       AS v(code, name, kind, unit, cost, cav, life, shots, loc, asset, every, days, last_on, last_shots)
 WHERE EXISTS (SELECT 1 FROM erp.account WHERE company_code = 'ZZ99' AND acct_code = '5320')
ON CONFLICT DO NOTHING;

-- BOM: 2 kettle bodies = 1.2 kg resin + 2 heating elements + 2 gift boxes, 1 shot of the 2-cavity mould, 0.02 h of the machine.
INSERT INTO erp.bom (company_code, item_code, bom_type, qty, whs_code, note, source)
SELECT 'ZZ99', 'SMP-PRD-100', 'production', 2, 'WH01', 'SAMPLE', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.item WHERE company_code = 'ZZ99' AND item_code = 'SMP-PRD-100')
ON CONFLICT DO NOTHING;
INSERT INTO erp.bom_line (company_code, item_code, line_num, comp_kind, comp_code, qty, whs_code)
SELECT 'ZZ99', 'SMP-PRD-100', v.n, v.kind, v.code, v.qty, v.whs
  FROM (VALUES (0, 'item', 'SMP-RAW-PP', 1.2, 'WH01'), (1, 'item', 'SMP-RAW-EL', 2, 'WH01'), (2, 'item', 'SMP-1220', 2, 'WH01'),
               (3, 'resource', 'MLD-KET-2', 1, NULL), (4, 'resource', 'INJ-250', 0.02, NULL)) AS v(n, kind, code, qty, whs)
 WHERE EXISTS (SELECT 1 FROM erp.bom WHERE company_code = 'ZZ99' AND item_code = 'SMP-PRD-100')
   AND EXISTS (SELECT 1 FROM erp.prod_resource WHERE company_code = 'ZZ99' AND res_code = 'INJ-250')
ON CONFLICT DO NOTHING;

-- Service: spare-parts reason (A7 goods issue reason → 5330), warranty 12 months for group 101 (small appliances), and two
-- equipment cards: one sold in 2024 (warranty ended), one from sample A/R invoice 100070 (in warranty).
INSERT INTO erp.inventory_reason (company_code, code, name, direction, acct_code, source, note)
SELECT 'ZZ99', 'SERVICE', 'Spare parts for service calls', 'out', '5330', 'sample', 'SAMPLE'
 WHERE EXISTS (SELECT 1 FROM erp.account WHERE company_code = 'ZZ99' AND acct_code = '5330')
ON CONFLICT DO NOTHING;
INSERT INTO erp.service_setting (company_code, parts_reason_code, note)
SELECT 'ZZ99', 'SERVICE', 'SAMPLE values for the test company'
 WHERE EXISTS (SELECT 1 FROM erp.inventory_reason WHERE company_code = 'ZZ99' AND code = 'SERVICE')
ON CONFLICT (company_code) DO NOTHING;
INSERT INTO erp.warranty_rule (company_code, group_code, months, note, source)
SELECT 'ZZ99', 101, 12, 'SAMPLE', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = 'ZZ99' AND group_code = 101)
ON CONFLICT DO NOTHING;
INSERT INTO erp.equipment_card (company_code, item_code, serial_no, card_code, invoice_entry, sold_on, warranty_start, warranty_end, note, source)
SELECT 'ZZ99', 'SMP-1020', 'KT-SMP-0001', 'C0003', NULL, DATE '2024-09-15', DATE '2024-09-15', DATE '2025-09-15', 'SAMPLE: sold before Super ERP', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = 'ZZ99' AND card_code = 'C0003')
ON CONFLICT DO NOTHING;
INSERT INTO erp.equipment_card (company_code, item_code, serial_no, card_code, invoice_entry, sold_on, warranty_start, warranty_end, note, source)
SELECT 'ZZ99', 'SMP-1030', 'BL-SMP-0100', d.card_code, d.doc_entry, d.doc_date, d.doc_date, (d.doc_date + interval '12 months')::date, 'SAMPLE', 'sample'
  FROM erp.document d WHERE d.company_code = 'ZZ99' AND d.obj_type = 13 AND d.doc_num = 100070
ON CONFLICT DO NOTHING;
