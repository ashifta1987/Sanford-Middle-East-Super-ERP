-- Sanford ERP - app layer ("erp" schema). Run after the raw SAP layer (00-06).
-- The React app reads and writes only this schema, through the Supabase API and RLS.
-- Rules:
--   * Every business table carries company_code; one company = one SAP database.
--   * SAP codes and numbers are kept as the keys people know: card_code, item_code, whs_code,
--     acct_code, doc_entry + doc_num, trans_id. Re-running a sync updates rows, never duplicates.
--   * source = 'sap' for rows that came from SAP, 'erp' for rows made in the new system.
--   * Posted journals cannot be edited or deleted, only reversed (trigger below).
CREATE SCHEMA IF NOT EXISTS erp;

-- ============ Who is asking (works on Supabase and plain Postgres) ============
CREATE OR REPLACE FUNCTION erp.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;

-- ============ Companies, branches, people and access ============
CREATE TABLE erp.company (
    company_code   varchar(8) PRIMARY KEY,
    legal_name     text NOT NULL,
    short_name     text NOT NULL,
    country        char(2) NOT NULL,
    currency       char(3) NOT NULL,
    licence_type   text NOT NULL CHECK (licence_type IN ('free_zone', 'mainland', 'foreign')),
    licence_authority text,                         -- e.g. Dubai South (DWC), DED Dubai
    tax_id         text,                            -- TRN / VAT number
    sap_schema     text,                            -- HANA schema it was migrated from
    is_parent      boolean NOT NULL DEFAULT false,
    active         boolean NOT NULL DEFAULT true
);

CREATE TABLE erp.branch (
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    branch_id      integer NOT NULL,                -- SAP OBPL.BPLId
    name           text NOT NULL,
    foreign_name   text,
    tax_id         text,
    address        text,
    is_main        boolean NOT NULL DEFAULT false,
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, branch_id)
);

CREATE TABLE erp.position (                         -- what a person can do: Area Sales Manager, Merchandiser, HR Admin...
    position_code  text PRIMARY KEY,
    name           text NOT NULL,
    module_access  text[] NOT NULL DEFAULT '{}',    -- e.g. {sales,field,trade}
    approval_limit numeric(19,2)                    -- in company currency
);

CREATE TABLE erp.app_user (                         -- one row per sign-in (Supabase auth.users.id)
    user_id        uuid PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company,   -- home company
    emp_id         integer,                         -- links to erp.employee
    display_name   text NOT NULL,
    email          text,
    mobile         text,
    position_code  text NOT NULL REFERENCES erp.position,
    language       text NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'ar')),
    active         boolean NOT NULL DEFAULT true
);

CREATE TABLE erp.user_company (                     -- which companies a user may see
    user_id        uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    PRIMARY KEY (user_id, company_code)
);

CREATE OR REPLACE FUNCTION erp.can_see(p_company varchar) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp AS $$
  SELECT EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = erp.current_user_id() AND uc.company_code = p_company)
$$;

-- ============ Finance masters ============
CREATE TABLE erp.account (                          -- SAP OACT
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    acct_code      varchar(15) NOT NULL,
    format_code    varchar(210),                    -- the account number people see, e.g. 1-100-01
    name           text NOT NULL,
    parent_code    varchar(15),
    level          smallint,
    postable       boolean NOT NULL,
    account_type   text,                            -- SAP ActType: N other, I revenue, E expense
    group_mask     smallint,                        -- 1 assets .. 9 other
    currency       varchar(3),
    is_control     boolean NOT NULL DEFAULT false,  -- receivable/payable control account
    frozen         boolean NOT NULL DEFAULT false,
    balance_local  numeric(19,6),
    source         text NOT NULL DEFAULT 'sap',
    PRIMARY KEY (company_code, acct_code)
);

CREATE TABLE erp.cost_centre (                      -- SAP OPRC (dimensions 1-5)
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    code           varchar(8) NOT NULL,
    name           text NOT NULL,
    dimension      smallint NOT NULL DEFAULT 1,
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, code)
);

CREATE TABLE erp.tax_code (                         -- SAP OVTG
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    code           varchar(8) NOT NULL,
    name           text,
    rate           numeric(9,4) NOT NULL,
    category       char(1),                         -- I input / O output
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, code)
);

CREATE TABLE erp.fx_rate (                          -- SAP ORTT
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    rate_date      date NOT NULL,
    currency       varchar(3) NOT NULL,
    rate           numeric(19,6) NOT NULL,
    PRIMARY KEY (company_code, rate_date, currency)
);

-- ============ Customers and suppliers ============
CREATE TABLE erp.salesperson (                      -- SAP OSLP
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    slp_code       integer NOT NULL,
    name           text NOT NULL,
    email          text,
    mobile         text,
    commission_pct numeric(9,4),
    emp_id         integer,
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, slp_code)
);

CREATE TABLE erp.payment_terms (                    -- SAP OCTG
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    group_num      integer NOT NULL,
    name           text NOT NULL,
    extra_days     integer,
    extra_months   integer,
    PRIMARY KEY (company_code, group_num)
);

CREATE TABLE erp.bp_group (                         -- SAP OCRG
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    group_code     integer NOT NULL,
    name           text NOT NULL,
    kind           char(1),                         -- C customer / S supplier
    PRIMARY KEY (company_code, group_code)
);

CREATE TABLE erp.business_partner (                 -- SAP OCRD (+ Sanford user fields)
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    card_code      varchar(15) NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('customer', 'supplier', 'lead')),
    name           text NOT NULL,
    foreign_name   text,                            -- Arabic name
    group_code     integer,
    bp_category    text,                            -- U_BP_Category (Hypermarket, Retail, Wholesale...)
    currency       varchar(3),
    credit_limit   numeric(19,6),
    balance        numeric(19,6),
    trn            text,                            -- LicTradNum
    phone          text,
    mobile         text,
    email          text,
    slp_code       integer,
    price_list     integer,
    payment_terms  integer,
    region         text,                            -- U_Region
    city           text,                            -- U_City
    province       text,                            -- U_Province
    country        text,                            -- U_Country
    territory      integer,
    ic_partner_company varchar(8),                  -- U_CTX_ICPC: this BP is another group company
    salesforce_id  text,                            -- U_SFID
    inflow_target  numeric(19,6),                   -- U_InflowTarget
    outflow_target numeric(19,6),                   -- U_OutflowTarget
    rent_terms     text,                            -- U_Rent (display rent agreed)
    incentive_terms text,                           -- U_Incentive
    discount_terms text,                            -- U_Discount
    tpl_storage_rate  numeric(19,6),                -- U_TPL_StorageRate (3PL client)
    tpl_handling_fee  numeric(19,6),                -- U_TPL_HandlingFee
    active         boolean NOT NULL DEFAULT true,
    created_on     date,
    source         text NOT NULL DEFAULT 'sap',
    PRIMARY KEY (company_code, card_code)
);
CREATE INDEX ON erp.business_partner (company_code, kind, name);

CREATE TABLE erp.bp_address (                       -- SAP CRD1
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    address_name   varchar(50) NOT NULL,
    kind           char(1) NOT NULL,                -- B bill to / S ship to
    street text, block text, building text, city text, state text, zip text, country varchar(3),
    PRIMARY KEY (company_code, card_code, address_name, kind),
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);

CREATE TABLE erp.bp_merchandiser (                  -- U_Merchandiser_Code .. _Code4 on the customer
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    slot           smallint NOT NULL CHECK (slot BETWEEN 1 AND 4),
    merchandiser_code text NOT NULL,
    merchandiser_name text,
    valid_from     date NOT NULL DEFAULT current_date,
    valid_to       date,                            -- set when a placement move ends it
    PRIMARY KEY (company_code, card_code, slot, valid_from),
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);

-- ============ Products ============
CREATE TABLE erp.item_group (                       -- SAP OITB
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    group_code     integer NOT NULL,
    name           text NOT NULL,
    PRIMARY KEY (company_code, group_code)
);

CREATE TABLE erp.brand (                            -- SAP OMRC (manufacturer)
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    firm_code      integer NOT NULL,
    name           text NOT NULL,
    PRIMARY KEY (company_code, firm_code)
);

CREATE TABLE erp.group_item (                       -- one product across all companies (U_ConsolidateMasterCode)
    master_item_code varchar(50) PRIMARY KEY,
    name           text NOT NULL,
    category       text,
    subcategory    text
);

CREATE TABLE erp.item (                             -- SAP OITM (+ Sanford user fields)
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    item_code      varchar(50) NOT NULL,
    name           text NOT NULL,
    foreign_name   text,
    group_code     integer,
    firm_code      integer,
    master_item_code varchar(50) REFERENCES erp.group_item,
    category       text,  subcategory text,         -- U_Category, U_SubCategory
    level1         text,  level2 text, level3 text, -- U_Level1..3 (product classification)
    segment        text,                            -- U_Item_Segment
    odm_division   text,                            -- U_ODMDivi
    sourcing_type  text,                            -- U_SourcingType (OEM / ODM)
    item_type      text,                            -- U_ItemType
    movement_status text,                           -- U_MovementStatus (fast / slow / non-moving)
    hs_code        varchar(15),                     -- U_HSCodes
    moq            numeric(19,6),                   -- U_MOQ
    artwork_ref    text,                            -- U_ArtWork
    barcode        text,
    sales_uom      text, purchase_uom text, inventory_uom text,
    is_stock       boolean, is_sold boolean, is_bought boolean,
    batch_managed  boolean NOT NULL DEFAULT false,
    serial_managed boolean NOT NULL DEFAULT false,
    pcs_20gp       integer, pcs_40gp integer, pcs_40hq integer,   -- container loading
    rated_voltage  text, capacity text,
    avg_cost       numeric(19,6),
    preferred_supplier varchar(15),
    supplier_part_no text,
    active         boolean NOT NULL DEFAULT true,
    created_on     date,
    source         text NOT NULL DEFAULT 'sap',
    PRIMARY KEY (company_code, item_code)
);
CREATE INDEX ON erp.item (company_code, category, subcategory);

CREATE TABLE erp.item_certificate (                 -- ESMA / SABER / G-Mark / RoHS / SASO / CB / DHA
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    scheme         text NOT NULL CHECK (scheme IN ('ESMA', 'SABER', 'GMARK', 'ROHS', 'SASO', 'CB', 'DHA')),
    status         text,
    certificate_no text,
    application_no text,
    applied_on     date,
    expires_on     date,
    rejected_on    date,
    remarks        text,
    PRIMARY KEY (company_code, item_code, scheme),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item ON DELETE CASCADE
);

CREATE TABLE erp.item_market_price (                -- U_UAE_MR, U_KSA_MR ... reference price per market
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    market         text NOT NULL CHECK (market IN ('UAE', 'KSA', 'KWT', 'QTR', 'BHR', 'OMN', 'SHOP', 'EXPORT')),
    price          numeric(19,6) NOT NULL,
    PRIMARY KEY (company_code, item_code, market),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item ON DELETE CASCADE
);

CREATE TABLE erp.item_tag (                         -- Top 100 (@TOP_100), Fast 50, new launch...
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    tag            text NOT NULL,
    PRIMARY KEY (company_code, item_code, tag),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item ON DELETE CASCADE
);

CREATE TABLE erp.price_list (                       -- SAP OPLN
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    list_num       integer NOT NULL,
    name           text NOT NULL,
    base_list      integer,
    factor         numeric(19,6),
    PRIMARY KEY (company_code, list_num)
);

CREATE TABLE erp.item_price (                       -- SAP ITM1
    company_code   varchar(8) NOT NULL,
    list_num       integer NOT NULL,
    item_code      varchar(50) NOT NULL,
    price          numeric(19,6),
    currency       varchar(3),
    PRIMARY KEY (company_code, list_num, item_code),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item ON DELETE CASCADE,
    FOREIGN KEY (company_code, list_num) REFERENCES erp.price_list
);

-- ============ Warehouses and stock ============
CREATE TABLE erp.warehouse (                        -- SAP OWHS
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    whs_code       varchar(8) NOT NULL,
    name           text NOT NULL,
    branch_id      integer,
    classification text,                            -- U_Classifications
    city text, country varchar(3),
    is_free_zone   boolean,                         -- goods leaving to mainland pay 5% duty
    locked         boolean NOT NULL DEFAULT false,
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, whs_code)
);

CREATE TABLE erp.stock_balance (                    -- SAP OITW, kept current by the app
    company_code   varchar(8) NOT NULL,
    item_code      varchar(50) NOT NULL,
    whs_code       varchar(8) NOT NULL,
    on_hand        numeric(19,6) NOT NULL DEFAULT 0,
    committed      numeric(19,6) NOT NULL DEFAULT 0,
    on_order       numeric(19,6) NOT NULL DEFAULT 0,
    avg_cost       numeric(19,6),
    min_stock      numeric(19,6),
    max_stock      numeric(19,6),
    PRIMARY KEY (company_code, item_code, whs_code),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item,
    FOREIGN KEY (company_code, whs_code) REFERENCES erp.warehouse
);

CREATE TABLE erp.batch (                            -- SAP OBTN / OSRN
    company_code   varchar(8) NOT NULL,
    kind           char(1) NOT NULL CHECK (kind IN ('B', 'S')),   -- batch or serial
    abs_entry      integer NOT NULL,
    item_code      varchar(50) NOT NULL,
    number         text NOT NULL,                   -- DistNumber
    sys_number     integer,
    made_on date, received_on date, expires_on date,
    status         text,
    PRIMARY KEY (company_code, kind, abs_entry),
    FOREIGN KEY (company_code, item_code) REFERENCES erp.item
);

CREATE TABLE erp.stock_movement (                   -- SAP OIVL (warehouse journal)
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    trans_seq      bigint NOT NULL,
    trans_type     integer NOT NULL,                -- SAP object type of the document
    doc_entry      integer,
    doc_line       integer,
    doc_date       date NOT NULL,
    item_code      varchar(50) NOT NULL,
    whs_code       varchar(8),
    qty_in         numeric(19,6) NOT NULL DEFAULT 0,
    qty_out        numeric(19,6) NOT NULL DEFAULT 0,
    price          numeric(19,6),
    currency       varchar(3),
    PRIMARY KEY (company_code, trans_seq)
);
CREATE INDEX ON erp.stock_movement (company_code, item_code, doc_date);

-- ============ Sales, purchase and stock documents ============
-- One table for all SAP marketing documents. obj_type is SAP's own number:
--   23 quotation, 17 sales order, 15 delivery, 16 return, 13 A/R invoice, 14 A/R credit note,
--   203 A/R down payment, 1470000113 purchase request, 540000006 purchase quotation,
--   22 purchase order, 20 goods receipt PO, 21 goods return, 18 A/P invoice, 19 A/P credit note,
--   204 A/P down payment, 1250000001 transfer request, 67 transfer, 59 goods receipt, 60 goods issue.
CREATE TABLE erp.document (
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,                -- SAP internal number
    doc_num        integer NOT NULL,                -- number people see
    series         integer,
    doc_kind       text NOT NULL,
    status         text NOT NULL CHECK (status IN ('draft', 'open', 'closed', 'cancelled', 'cancellation')),  -- cancellation = the document that cancels another (SAP CANCELED = 'C')
    doc_date       date NOT NULL,
    due_date       date,
    tax_date       date,
    card_code      varchar(15),
    card_name      text,
    customer_ref   text,                            -- NumAtCard (their PO / invoice number)
    currency       varchar(3),
    fx_rate        numeric(19,6),
    total          numeric(19,6),
    total_fc       numeric(19,6),
    vat_total      numeric(19,6),
    paid           numeric(19,6),
    slp_code       integer,
    branch_id      integer,
    project        text,
    from_whs       varchar(8),                      -- transfers
    to_whs         varchar(8),
    comments       text,
    salesforce_order_id text,                       -- U_SOID
    shipping_mark  text,                            -- U_ShippingMark
    shipment_mode  text,                            -- U_Shipment_Mode
    container_no   text,                            -- U_ContainerNum
    tpl_job_no     text,                            -- U_TPL_JobNumber
    ic_reference   text,                            -- U_InterComReference (CTX inter-company)
    created_on     date,
    source         text NOT NULL DEFAULT 'sap',
    -- +1 or -1: credit notes and returns are stored positive in SAP; multiply by sign before adding up
    sign           smallint GENERATED ALWAYS AS (CASE WHEN obj_type IN (14, 16, 19, 21) THEN -1 ELSE 1 END) STORED,
    PRIMARY KEY (company_code, obj_type, doc_entry)
);
CREATE INDEX ON erp.document (company_code, obj_type, series, doc_num);
CREATE INDEX ON erp.document (company_code, card_code, doc_date);
CREATE INDEX ON erp.document (company_code, obj_type, status, doc_date);

CREATE TABLE erp.document_line (
    company_code   varchar(8) NOT NULL,
    obj_type       integer NOT NULL,
    doc_entry      integer NOT NULL,
    line_num       integer NOT NULL,
    item_code      varchar(50),
    description    text,
    quantity       numeric(19,6),
    open_qty       numeric(19,6),
    uom            text,
    price          numeric(19,6),
    currency       varchar(3),
    discount_pct   numeric(9,4),
    line_total     numeric(19,6),
    line_total_fc  numeric(19,6),
    tax_code       varchar(8),
    vat            numeric(19,6),
    whs_code       varchar(8),
    from_whs       varchar(8),
    acct_code      varchar(15),
    cost_centre    varchar(8),
    cost_centre2   varchar(8),
    project        text,
    base_obj_type  integer,                         -- copied from (e.g. order -> delivery -> invoice)
    base_doc_entry integer,
    base_line      integer,
    line_status    char(1),
    gross_buy_price numeric(19,6),                  -- cost for gross profit
    stock_price    numeric(19,6),
    slp_code       integer,
    cbm            numeric(19,6),                   -- U_CBM
    hs_code        varchar(15),                     -- U_HSCodes
    salesforce_line_id text,                        -- U_SFLineId
    PRIMARY KEY (company_code, obj_type, doc_entry, line_num),
    FOREIGN KEY (company_code, obj_type, doc_entry) REFERENCES erp.document ON DELETE CASCADE
);
CREATE INDEX ON erp.document_line (company_code, item_code);
CREATE INDEX ON erp.document_line (company_code, base_obj_type, base_doc_entry);

-- ============ Journals and payments ============
CREATE TABLE erp.journal_entry (                    -- SAP OJDT
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    trans_id       integer NOT NULL,
    number         integer,
    ref_date       date NOT NULL,                   -- posting date
    due_date       date,
    tax_date       date,
    memo           text,
    ref1 text, ref2 text, ref3 text,
    trans_type     integer,                         -- object that created it (13 invoice, 30 manual...)
    base_ref       text,
    trans_code     text,
    total_local    numeric(19,6),
    total_sys      numeric(19,6),
    currency       varchar(3),
    reversal_of    integer,                         -- StornoToTr
    project        text,
    source         text NOT NULL DEFAULT 'sap',
    created_on     date,
    PRIMARY KEY (company_code, trans_id)
);
CREATE INDEX ON erp.journal_entry (company_code, ref_date);

CREATE TABLE erp.journal_line (                     -- SAP JDT1
    company_code   varchar(8) NOT NULL,
    trans_id       integer NOT NULL,
    line_id        integer NOT NULL,
    acct_code      varchar(15) NOT NULL,
    short_name     varchar(15),                     -- BP code when the account is a control account
    contra_acct    varchar(15),
    debit          numeric(19,6) NOT NULL DEFAULT 0,
    credit         numeric(19,6) NOT NULL DEFAULT 0,
    fc_debit       numeric(19,6),
    fc_credit      numeric(19,6),
    fc_currency    varchar(3),
    sys_debit      numeric(19,6),
    sys_credit     numeric(19,6),
    memo           text,
    cost_centre    varchar(8), cost_centre2 varchar(8), cost_centre3 varchar(8),
    project        text,
    ref_date       date,
    due_date       date,
    branch_id      integer,
    tax_code       varchar(8),
    match_no       integer,                         -- internal reconciliation number
    PRIMARY KEY (company_code, trans_id, line_id),
    FOREIGN KEY (company_code, trans_id) REFERENCES erp.journal_entry,
    FOREIGN KEY (company_code, acct_code) REFERENCES erp.account
);
CREATE INDEX ON erp.journal_line (company_code, acct_code, ref_date);
CREATE INDEX ON erp.journal_line (company_code, short_name);

CREATE TABLE erp.payment (                          -- SAP ORCT (incoming) / OVPM (outgoing)
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    direction      char(1) NOT NULL CHECK (direction IN ('I', 'O')),
    doc_entry      integer NOT NULL,
    doc_num        integer NOT NULL,
    doc_type       char(1),                         -- SAP DocType: C customer, S supplier, A account (lines in SAP RCT4, kept in the raw layer)
    doc_date       date NOT NULL,
    card_code      varchar(15),
    card_name      text,
    currency       varchar(3),
    fx_rate        numeric(19,6),
    total          numeric(19,6),
    cash numeric(19,6), transfer numeric(19,6), cheque numeric(19,6), card numeric(19,6),
    on_account     numeric(19,6),
    cancelled      boolean NOT NULL DEFAULT false,
    trans_id       integer,
    branch_id      integer,
    memo           text,
    source         text NOT NULL DEFAULT 'sap',
    PRIMARY KEY (company_code, direction, doc_entry)
);

CREATE TABLE erp.payment_allocation (               -- SAP RCT2 / VPM2
    company_code   varchar(8) NOT NULL,
    direction      char(1) NOT NULL,
    doc_entry      integer NOT NULL,
    line_no        integer NOT NULL,
    target_obj_type integer,                        -- 13 invoice, 14 credit note (sign -1), 30 journal entry...
    target_doc_entry integer,
    target_line    integer,                         -- journal line when the target is a journal entry (DocLine)
    applied        numeric(19,6),
    applied_fc     numeric(19,6),
    PRIMARY KEY (company_code, direction, doc_entry, line_no),
    FOREIGN KEY (company_code, direction, doc_entry) REFERENCES erp.payment ON DELETE CASCADE
);

-- ============ Inter-company (replaces the CTX add-on) ============
CREATE TABLE erp.ic_account_map (                   -- @CTX_ACCMAP: company account -> group account
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    acct_code      varchar(15) NOT NULL,
    group_acct_code varchar(15) NOT NULL,
    group_acct_name text,
    PRIMARY KEY (company_code, acct_code)
);

CREATE TABLE erp.ic_transaction (                   -- one sale in company A = one purchase in company B
    ic_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_company varchar(8) NOT NULL REFERENCES erp.company,
    seller_obj_type integer NOT NULL,
    seller_doc_entry integer NOT NULL,
    buyer_company  varchar(8) NOT NULL REFERENCES erp.company,
    buyer_obj_type integer,
    buyer_doc_entry integer,
    status         text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'received', 'matched', 'difference')),
    difference     numeric(19,6),
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- ============ HR (from the ALT_HR add-on) ============
CREATE TABLE erp.hr_org_unit (                      -- payroll area, personnel area/subarea, division/subdivision, employee group/subgroup, grade
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    kind           text NOT NULL CHECK (kind IN ('payroll_area', 'personnel_area', 'personnel_subarea', 'division', 'subdivision', 'employee_group', 'employee_subgroup', 'grade', 'position')),
    code           varchar(50) NOT NULL,
    name           text,
    parent_code    varchar(50),                     -- subarea -> area, subdivision -> division, subgroup -> group
    attrs          jsonb NOT NULL DEFAULT '{}',     -- e.g. payroll frequency, year start
    PRIMARY KEY (company_code, kind, code)
);

CREATE TABLE erp.employee (                         -- SAP OHEM + @ALT_HR_EMD
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    emp_id         integer NOT NULL,                -- OHEM.empID
    hr_code        varchar(50),                     -- ALT_HR employee number (U_ALTEMPID)
    first_name text, middle_name text, last_name text,
    job_title      text,
    position_code  text,
    department     integer,
    branch_id      integer,
    manager_emp_id integer,
    slp_code       integer,
    mobile text, office_phone text, email text,
    gender         text,
    birth_date     date,
    nationality    varchar(3),
    passport_no    text,
    passport_expires date,
    gov_id         text,                            -- Emirates ID / Iqama / civil ID
    joined_on      date,
    left_on        date,
    status         text,
    payroll_area   varchar(50),
    personnel_area varchar(50),
    personnel_subarea varchar(50),
    division       varchar(50),
    subdivision    varchar(50),
    sponsor        text,                            -- visa sponsor company (U_ALTSPON)
    pay_currency   varchar(3),
    active         boolean NOT NULL DEFAULT true,
    source         text NOT NULL DEFAULT 'sap',
    PRIMARY KEY (company_code, emp_id),
    UNIQUE (company_code, hr_code)
);

CREATE TABLE erp.employee_document (                -- @ALT_HR_IDENDETH/D: passport, visa, Emirates ID, labour card...
    company_code   varchar(8) NOT NULL,
    hr_code        varchar(50) NOT NULL,
    doc_type       text NOT NULL,
    doc_no         text,
    issued_on      date,
    expires_on     date,
    issued_by      text,
    PRIMARY KEY (company_code, hr_code, doc_type, doc_no)
);
CREATE INDEX ON erp.employee_document (company_code, expires_on);

CREATE TABLE erp.wage_type (                        -- @ALT_HR_WAGETYPE
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    code           varchar(50) NOT NULL,
    name           text,
    is_earning     boolean,
    is_deduction   boolean,
    is_loan        boolean,
    calc_type      text,
    gl_account     varchar(15),
    PRIMARY KEY (company_code, code)
);

CREATE TABLE erp.employee_pay (                     -- @ALT_HR_WAGE lines: basic, housing, transport...
    company_code   varchar(8) NOT NULL,
    hr_code        varchar(50) NOT NULL,
    wage_type      varchar(50) NOT NULL,
    amount         numeric(19,6) NOT NULL,
    currency       varchar(3),
    valid_from     date NOT NULL DEFAULT '1900-01-01',
    PRIMARY KEY (company_code, hr_code, wage_type, valid_from)
);

CREATE TABLE erp.leave_type (                       -- @ALT_HR_ABSTYPE
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    code           varchar(50) NOT NULL,
    name           text,
    paid           boolean,
    unit           text,
    max_days       numeric(9,2),
    min_days       numeric(9,2),
    loss_of_pay    boolean,
    counts_for_eos boolean,                         -- does it count towards gratuity
    PRIMARY KEY (company_code, code)
);

CREATE TABLE erp.payroll_result (                   -- @ALT_HR_PRRT unpivoted: one row per employee, period, wage code
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    period         varchar(20) NOT NULL,
    hr_code        varchar(50) NOT NULL,
    wage_code      varchar(20) NOT NULL,
    amount         numeric(19,6) NOT NULL,
    PRIMARY KEY (company_code, period, hr_code, wage_code)
);

CREATE TABLE erp.air_ticket_accrual (               -- @ALT_HR_TKTACRL
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    doc_entry      integer NOT NULL,
    hr_code        varchar(50),
    home_city      text,
    eligible       text,
    tickets        numeric(9,2),
    opening        numeric(19,6),
    closing        numeric(19,6),
    next_due       date,
    PRIMARY KEY (company_code, doc_entry)
);

-- ============ Sanford add-ons and custom tables ============
CREATE TABLE erp.tpl_contract (                     -- @TPL_JOBS: 3PL client job and its rates
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    job_code       varchar(50) NOT NULL,
    client_code    varchar(20),
    client_name    text,
    status         text,
    active         boolean,
    starts_on date, ends_on date, extended_to date,
    storage_fee    numeric(19,6),
    min_storage_fee numeric(19,6),
    min_handling_fee numeric(19,6),
    fixed_handling boolean,
    handling_rates jsonb NOT NULL DEFAULT '{}',     -- in/out x 20ft/40ft/40HC/LCL, palletised or not
    slp_code       integer,
    PRIMARY KEY (company_code, job_code)
);

CREATE TABLE erp.artwork_request (                  -- @ARTWORKMASTER: packaging artwork for a PO
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    doc_entry      integer NOT NULL,
    doc_num        integer,
    status         text,
    po_doc_num     integer,                         -- U_SAP_PO
    po_date        date,
    po_amount      numeric(19,6),
    contact        text,
    remark         text,
    created_on     date,
    PRIMARY KEY (company_code, doc_entry)
);

CREATE TABLE erp.artwork_line (                     -- @ARTWORKMASTER_GIFTB / _MCT
    company_code   varchar(8) NOT NULL,
    doc_entry      integer NOT NULL,
    part           text NOT NULL CHECK (part IN ('gift_box', 'master_carton')),
    line_id        integer NOT NULL,
    model_no       text,
    image_ref      text,
    status         text,
    approved_by    text,
    approved_on    date,
    PRIMARY KEY (company_code, doc_entry, part, line_id),
    FOREIGN KEY (company_code, doc_entry) REFERENCES erp.artwork_request ON DELETE CASCADE
);

CREATE TABLE erp.supplier_pi (                      -- @PISTATUS: supplier proforma invoices
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    code           varchar(50) NOT NULL,
    vendor_pi_no   text,
    vendor_name    text,
    item_code      varchar(50),
    product_name   text,
    pi_qty         numeric(19,6),
    qty            numeric(19,6),
    eta            text,
    status         text,
    doc_date       date,
    PRIMARY KEY (company_code, code)
);

CREATE TABLE erp.trademark (                        -- @TRADEMARK
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    code           varchar(50) NOT NULL,
    trademark_no   text,
    description    text,
    class          integer,
    country        text,
    valid_from     date,
    valid_to       date,
    PRIMARY KEY (company_code, code)
);

-- ============ New modules (no SAP source) ============
CREATE TABLE erp.shop_visit (                       -- merchandiser / salesman visit
    visit_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    card_code      varchar(15) NOT NULL,
    emp_id         integer NOT NULL,
    role           text NOT NULL CHECK (role IN ('merchandiser', 'salesman', 'coordinator', 'manager')),
    checked_in_at  timestamptz NOT NULL,
    checked_out_at timestamptz,
    lat numeric(9,6), lng numeric(9,6),
    distance_m     integer,
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'sent', 'reviewed')),
    synced_at      timestamptz,                     -- offline visits sync later
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner
);

CREATE TABLE erp.shop_visit_item (                  -- stock, price and listing seen on the shelf
    visit_id       bigint NOT NULL REFERENCES erp.shop_visit ON DELETE CASCADE,
    item_code      varchar(50) NOT NULL,
    on_shelf       numeric(19,6),
    in_store_room  numeric(19,6),
    shelf_price    numeric(19,6),
    sold_today     numeric(19,6),
    listed         boolean,
    feedback       text,
    PRIMARY KEY (visit_id, item_code)
);

CREATE TABLE erp.trade_budget (
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    year           smallint NOT NULL,
    scope          text NOT NULL,                   -- 'area:Dubai', 'group:LULU', 'card:C0001'
    amount         numeric(19,2) NOT NULL,
    PRIMARY KEY (company_code, year, scope)
);

CREATE TABLE erp.trade_request (                    -- display rent, flyer, promotion, listing fee
    request_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    card_code      varchar(15) NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('display_rent', 'flyer', 'promotion', 'listing_fee', 'other')),
    amount         numeric(19,2) NOT NULL,
    period_from    date, period_to date,
    one_time       boolean NOT NULL DEFAULT true,
    status         text NOT NULL DEFAULT 'submitted' CHECK (status IN ('draft', 'submitted', 'asm_ok', 'sm_ok', 'finance_ok', 'rejected', 'settled')),
    requested_by   uuid REFERENCES erp.app_user,
    ap_doc_entry   integer,                         -- shop invoice booked as A/P invoice (obj 18)
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner
);

CREATE TABLE erp.vehicle (
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    plate          text NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('truck', 'van', 'prime_mover', 'trailer', 'car')),
    assigned_emp_id integer,
    registration_expires date,
    insurance_expires date,
    asset_code     varchar(50),                     -- fixed asset item in SAP
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, plate)
);

CREATE TABLE erp.trip (                             -- driver app
    trip_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    plate          text NOT NULL,
    driver_emp_id  integer NOT NULL,
    helper_emp_id  integer,
    trip_date      date NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('delivery', 'container', 'transfer', 'pickup')),
    status         text NOT NULL DEFAULT 'planned',
    FOREIGN KEY (company_code, plate) REFERENCES erp.vehicle
);

CREATE TABLE erp.trip_stop (
    trip_id        bigint NOT NULL REFERENCES erp.trip ON DELETE CASCADE,
    seq            smallint NOT NULL,
    obj_type       integer,                         -- 15 delivery, 67 transfer...
    doc_entry      integer,
    card_code      varchar(15),
    arrived_at     timestamptz,
    done_at        timestamptz,
    received_by    text,
    proof_photo    text,                            -- storage path
    signature      text,
    result         text CHECK (result IN ('delivered', 'partial', 'refused', 'not_home')),
    PRIMARY KEY (trip_id, seq)
);

CREATE TABLE erp.approval (                         -- every approval in every module
    approval_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    object         text NOT NULL,                   -- 'document', 'trade_request', 'leave', 'salary_change'...
    object_ref     text NOT NULL,
    step           smallint NOT NULL,
    approver_position text NOT NULL REFERENCES erp.position,
    approver_user  uuid REFERENCES erp.app_user,
    decision       text CHECK (decision IN ('approved', 'rejected', 'delegated')),
    note           text,
    decided_at     timestamptz
);

CREATE TABLE erp.audit_log (                        -- nobody can change or delete these rows
    audit_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at             timestamptz NOT NULL DEFAULT now(),
    actor          text NOT NULL,                   -- user id, or ai:<agent>, or system:<job>
    company_code   varchar(8),
    action         text NOT NULL,
    object         text,
    object_ref     text,
    detail         jsonb
);

CREATE TABLE erp.sync_log (                         -- what each sap -> erp run did
    sync_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    step           text NOT NULL,
    rows_written   bigint,
    started_at     timestamptz NOT NULL,
    finished_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    error          text
);

-- ============ Guards ============
-- Posted journals are permanent: nobody updates or deletes them except the SAP sync (erp.sync = 'on').
-- Statement-level, so the check costs nothing per row during a bulk sync.
CREATE OR REPLACE FUNCTION erp.block_journal_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(current_setting('erp.sync', true), '') = 'on' THEN
    RETURN NULL;
  END IF;
  RAISE EXCEPTION 'posted journals cannot be changed or deleted - post a reversal instead';
END $$;
CREATE TRIGGER journal_entry_lock BEFORE UPDATE OR DELETE ON erp.journal_entry FOR EACH STATEMENT EXECUTE FUNCTION erp.block_journal_change();
CREATE TRIGGER journal_line_lock  BEFORE UPDATE OR DELETE ON erp.journal_line  FOR EACH STATEMENT EXECUTE FUNCTION erp.block_journal_change();

CREATE OR REPLACE FUNCTION erp.block_audit_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'the audit log cannot be changed'; END $$;
CREATE TRIGGER audit_lock BEFORE UPDATE OR DELETE ON erp.audit_log FOR EACH ROW EXECUTE FUNCTION erp.block_audit_change();

-- A journal must balance, and lines can only be added to a journal in the same statement that posts it.
-- Checked once per INSERT statement over the journals it touched; skipped during the SAP sync.
CREATE OR REPLACE FUNCTION erp.check_journal_balance() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE bad record;
BEGIN
  IF coalesce(current_setting('erp.sync', true), '') = 'on' THEN RETURN NULL; END IF;
  SELECT l.company_code, l.trans_id, sum(l.debit) d, sum(l.credit) c INTO bad
    FROM erp.journal_line l
    JOIN (SELECT DISTINCT company_code, trans_id FROM new_lines) n USING (company_code, trans_id)
   GROUP BY 1, 2 HAVING round(sum(l.debit) - sum(l.credit), 2) <> 0 LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'journal % % does not balance: debit % credit %', bad.company_code, bad.trans_id, bad.d, bad.c;
  END IF;
  SELECT n.company_code, n.trans_id INTO bad FROM new_lines n
   WHERE EXISTS (SELECT 1 FROM erp.journal_line o WHERE o.company_code = n.company_code AND o.trans_id = n.trans_id
                    AND (o.company_code, o.trans_id, o.line_id) NOT IN (SELECT company_code, trans_id, line_id FROM new_lines))
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'journal % % is already posted - lines cannot be added', bad.company_code, bad.trans_id;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER journal_balanced AFTER INSERT ON erp.journal_line REFERENCING NEW TABLE AS new_lines
  FOR EACH STATEMENT EXECUTE FUNCTION erp.check_journal_balance();
