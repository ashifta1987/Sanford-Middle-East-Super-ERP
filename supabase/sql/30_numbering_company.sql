-- B1 · Pilot company AE05, Document Numbering (SAP Business One style) and the rule changes Ashif decided on 10 Nov 2026
-- (docs/decisions-2026-11-10.md §1, §2 C1, §3). Safe to run twice. Does not edit 10–29: earlier behaviour is changed here
-- with CREATE OR REPLACE, and every earlier message is kept unless a decision changes it.
--
-- 1. Company AE05 · UAE - ATMM GENERAL TRADING LLC (pilot). erp.company + sap._company (only where that table exists), so it
--    shows in the migration console and the go-live checklist. Further companies are created in Administration ›
--    Choose/Create Company (company_list, company_save). erp.company.licence_type may now be empty ("to be confirmed").
--
-- 2. Document Numbering (C1). Several series per document type and company, each with name, prefix, first_num / next_num /
--    last_num, pad, period_from / period_to, branch_id, whs_code, locked and remarks:
--      erp.number_series  – keeps its key (company, type) and now holds the company's DEFAULT series of the type
--                           (`active` keeps A10's meaning: numbering switched on), so 17–29 still re-run cleanly;
--      erp.doc_series     – the other series; view erp.doc_series_all shows both (one series_id sequence).
--    erp.series_user_default – default series per user, company and type.
--    One allocator, erp._series_take(company, obj): the series picked on the form (the transaction setting erp.series,
--    set by the p_series overloads below) → the user's default → the company default; period and warehouse aware; the
--    series row is locked (SELECT … FOR UPDATE) and next_num only moves forward, so numbers are gap-free under
--    concurrency (a rolled-back document gives its number back). Locked, out-of-period, wrong-warehouse and used-up
--    series are refused with a clear message. Every numbering function of A2–A13 now takes its number from it:
--      _sd_number, _bk_number, _pd_number, _inv_number, _ps_number, _md_next_code, hr_employee_save (employee codes),
--      item codes (item_save with an empty code), and payment drafts remember the series picked at submit.
--    New overloads with p_series (old signatures unchanged): sales_doc_save, sales_delivery_create, sales_invoice_create,
--    sales_credit_memo_create, payment_submit, deposit_create, purchase_doc_save, purchase_deposit_create,
--    purchase_grpo_create, purchase_invoice_create, landed_cost_create, inventory_doc_create, transfer_request_create,
--    transfer_create, inv_count_create, bp_save, item_save, hr_employee_save, prod_order_create, service_contract_save,
--    service_call_save.
--    API: doc_numbering_setup, doc_series_save, doc_series_delete, series_user_default_save, doc_series_options.
--    A10's number_series_setup / number_series_save keep working on the default series.
--
-- 3. Rules decided (§3):
--    expired quotation  – a Super ERP order line can't be copied from a quotation whose valid-until date has passed
--                         (trigger erp._sd_quote_expiry; sales_copy_source refuses it too)
--    QC                 – a shipment always needs the purchase order's last QC inspection to be a pass
--                         (purchase_shipment_save; purchase_setting.require_qc_pass is always on)
--    BP duplicates      – the name-similarity warning is removed (_bp_eval); same TRN / phone still warn. OEM/ODM stay
--                         configurable sourcing types (master_setting.sourcing_types)
--    landed costs       – the share on goods already sold posts to the price difference account (inventory/price_difference)
--    credit memos       – approval through an approval template (rule credit_memo_amount, amount condition); direct
--                         service invoices use the sales-order discount template (discount_pct). Both go through
--                         erp.sales_doc_request: the final approval creates the document.
--    spare parts        – who may issue them is configurable (service_setting.parts_positions / parts_users); default =
--                         the service manager position (service_setting.manager_position)
--    moulds             – new moulds default to maintenance every 50,000 shots, rated life 500,000 shots and a warning at
--                         80 % (prod_resource.warn_pct, editable per mould); mould_schedule shows due_soon
--
-- Replaces (CREATE OR REPLACE): _adm_doc_types (copied from 28 + 6 types), _adm_rule_spec (+ credit_memo_amount),
--   approval_inbox (13 kinds: + sales_doc_request), number_series_save, _sd_number, _bk_number,
--   _pd_number, _inv_number, _ps_number, _md_next_code, hr_employee_save, _pay_post, payment_submit (overload only),
--   sales_invoice_create, sales_credit_memo_create, sales_copy_source, purchase_shipment_save, purchase_setting_set,
--   _bp_eval, landed_cost_create, service_setup, service_setting_set, service_call_parts_issue, prod_resource_save,
--   view mould_schedule, _health_files (+ 30).
--
-- Company-specific values (series, prefixes, limits, accounts) are not invented: AE01–AE05 start empty and are entered
-- in the front end. The marked SAMPLE values are for ZZ99 only.

-- ============ 1. Companies ============
ALTER TABLE erp.company ALTER COLUMN licence_type DROP NOT NULL;   -- AE05: licence type to be confirmed

INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema, is_parent, active)
VALUES ('AE05', 'UAE - ATMM GENERAL TRADING LLC', 'ATMM General Trading', 'AE', 'AED', NULL, NULL, false, true)
ON CONFLICT (company_code) DO NOTHING;

-- The migration register (Supabase: the real sap._company; local stack: the stand-in). Skipped where it doesn't exist.
DO $$
BEGIN
  IF to_regclass('sap._company') IS NOT NULL THEN
    BEGIN
      EXECUTE $q$INSERT INTO sap._company (company_code, legal_name, country, currency, licence_type, sap_schema)
                 VALUES ('AE05', 'UAE - ATMM GENERAL TRADING LLC', 'AE', 'AED', NULL, NULL) ON CONFLICT (company_code) DO NOTHING$q$;
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'AE05 was not added to sap._company (%). Add it in the migration console.', SQLERRM;
    END;
  END IF;
END $$;

-- ============ 2. Document numbering: tables ============
-- erp.number_series keeps one row per company and document type (its key is unchanged, so 17–29 still re-run cleanly):
-- that row is the company's DEFAULT series. Its `active` flag keeps A10's meaning (numbering switched on).
-- Further series of the same type live in erp.doc_series. Both share one series_id sequence; erp.doc_series_all shows
-- them together. Making another series the default swaps the two rows' contents (series ids move with them).
CREATE SEQUENCE IF NOT EXISTS erp.doc_series_id_seq AS bigint START WITH 1;
ALTER TABLE erp.number_series
  ADD COLUMN IF NOT EXISTS series_id   bigint,
  ADD COLUMN IF NOT EXISTS name        text,
  ADD COLUMN IF NOT EXISTS first_num   integer,
  ADD COLUMN IF NOT EXISTS last_num    integer,
  ADD COLUMN IF NOT EXISTS period_from date,
  ADD COLUMN IF NOT EXISTS period_to   date,
  ADD COLUMN IF NOT EXISTS branch_id   integer,
  ADD COLUMN IF NOT EXISTS whs_code    varchar(8),
  ADD COLUMN IF NOT EXISTS locked      boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS remarks     text,
  ADD COLUMN IF NOT EXISTS updated_by  uuid,
  ADD COLUMN IF NOT EXISTS updated_at  timestamptz NOT NULL DEFAULT now();
ALTER TABLE erp.number_series ALTER COLUMN series_id SET DEFAULT nextval('erp.doc_series_id_seq'),
                              ALTER COLUMN name SET DEFAULT 'Primary', ALTER COLUMN first_num SET DEFAULT 1;
UPDATE erp.number_series SET series_id = nextval('erp.doc_series_id_seq') WHERE series_id IS NULL;
UPDATE erp.number_series SET name = 'Primary' WHERE name IS NULL;
UPDATE erp.number_series SET first_num = least(1, next_num) WHERE first_num IS NULL;
ALTER TABLE erp.number_series ALTER COLUMN series_id SET NOT NULL, ALTER COLUMN name SET NOT NULL, ALTER COLUMN first_num SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS number_series_series_id_uniq ON erp.number_series (series_id);
ALTER TABLE erp.number_series DROP CONSTRAINT IF EXISTS number_series_range_check;
ALTER TABLE erp.number_series ADD CONSTRAINT number_series_range_check
  CHECK (first_num >= 1 AND next_num >= first_num AND (last_num IS NULL OR (last_num >= first_num AND next_num <= last_num + 1))
         AND (period_to IS NULL OR period_from IS NULL OR period_to >= period_from));
COMMENT ON TABLE erp.number_series IS 'Default numbering series per company and document type (A2; B1 adds name, range, period, warehouse, lock). Other series: erp.doc_series.';

CREATE TABLE IF NOT EXISTS erp.doc_series (
    series_id      bigint PRIMARY KEY DEFAULT nextval('erp.doc_series_id_seq'),
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    obj_type       integer NOT NULL,
    name           text NOT NULL,
    prefix         text NOT NULL,
    first_num      integer NOT NULL DEFAULT 1,
    next_num       integer NOT NULL DEFAULT 1,
    last_num       integer,
    pad            smallint NOT NULL DEFAULT 5 CHECK (pad BETWEEN 1 AND 10),
    period_from    date,
    period_to      date,
    branch_id      integer,
    whs_code       varchar(8),
    locked         boolean NOT NULL DEFAULT false,      -- SAP B1 "Locked": stays visible, numbers no new document
    remarks        text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CHECK (first_num >= 1 AND next_num >= first_num AND (last_num IS NULL OR (last_num >= first_num AND next_num <= last_num + 1))
           AND (period_to IS NULL OR period_from IS NULL OR period_to >= period_from))
);
CREATE INDEX IF NOT EXISTS doc_series_type_idx ON erp.doc_series (company_code, obj_type);
ALTER TABLE erp.doc_series ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.doc_series FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.doc_series TO authenticated;
DROP POLICY IF EXISTS doc_series_read ON erp.doc_series;
CREATE POLICY doc_series_read ON erp.doc_series FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- Every series, default or not. `active` = numbering switched on (A10); always true for non-default series.
CREATE OR REPLACE VIEW erp.doc_series_all WITH (security_invoker = true) AS
SELECT n.series_id, n.company_code, n.obj_type, n.name, n.prefix, n.first_num, n.next_num, n.last_num, n.pad::integer AS pad, n.period_from, n.period_to,
       n.branch_id, n.whs_code, n.locked, n.remarks, true AS is_default, n.active, n.updated_at
  FROM erp.number_series n
UNION ALL
SELECT d.series_id, d.company_code, d.obj_type, d.name, d.prefix, d.first_num, d.next_num, d.last_num, d.pad::integer, d.period_from, d.period_to,
       d.branch_id, d.whs_code, d.locked, d.remarks, false, true, d.updated_at
  FROM erp.doc_series d;
REVOKE ALL ON erp.doc_series_all FROM PUBLIC, anon;
GRANT SELECT ON erp.doc_series_all TO authenticated;

CREATE TABLE IF NOT EXISTS erp.series_user_default (
    user_id        uuid NOT NULL REFERENCES erp.app_user ON DELETE CASCADE,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    obj_type       integer NOT NULL,
    series_id      bigint NOT NULL,                   -- erp.number_series or erp.doc_series (erp.doc_series_all)
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, company_code, obj_type)
);

-- Payment drafts remember the series picked at submit (the number is taken when the last approval posts the payment).
ALTER TABLE erp.payment_draft ADD COLUMN IF NOT EXISTS series_id bigint;

ALTER TABLE erp.series_user_default ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.series_user_default FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.series_user_default TO authenticated;
DROP POLICY IF EXISTS series_user_default_read ON erp.series_user_default;
CREATE POLICY series_user_default_read ON erp.series_user_default FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (user_id = erp.current_user_id() OR (SELECT erp.module_level('admin')) IS NOT NULL
                                        OR (SELECT erp.module_level('it')) IS NOT NULL));

-- Document types that can have numbering (copied from 28 + Return, A/R down payment, Goods Return, A/P credit memo,
-- Journal Entry and Item code). `used` = Super ERP creates this document today; the others keep their series ready.
CREATE OR REPLACE FUNCTION erp._adm_doc_types() RETURNS TABLE (obj_type integer, label text, module text, sort integer)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    (23, 'Sales Quotation', 'sales', 1), (17, 'Sales Order', 'sales', 2), (15, 'Delivery', 'sales', 3), (16, 'Return', 'sales', 4),
    (203, 'A/R Down Payment Invoice', 'sales', 5), (13, 'A/R Invoice', 'sales', 6), (14, 'A/R Credit Memo', 'sales', 7),
    (1470000113, 'Purchase Request', 'purchase', 10), (540000006, 'Purchase Quotation', 'purchase', 11), (22, 'Purchase Order', 'purchase', 12),
    (20, 'Goods Receipt PO', 'purchase', 13), (21, 'Goods Return', 'purchase', 14), (204, 'A/P Down Payment Invoice', 'purchase', 15),
    (18, 'A/P Invoice', 'purchase', 16), (19, 'A/P Credit Memo', 'purchase', 17), (69, 'Landed Costs', 'purchase', 18),
    (24, 'Incoming Payment', 'banking', 20), (46, 'Outgoing Payment', 'banking', 21), (25, 'Deposit', 'banking', 22),
    (30, 'Journal Entry', 'finance', 25),
    (1250000001, 'Inventory Transfer Request', 'inventory', 30), (67, 'Inventory Transfer', 'inventory', 31),
    (59, 'Goods Receipt', 'inventory', 32), (60, 'Goods Issue', 'inventory', 33), (1470000065, 'Inventory Counting', 'inventory', 34),
    (2001, 'Customer code', 'bp', 40), (2002, 'Supplier code', 'bp', 41), (2003, 'Lead code', 'bp', 42), (4, 'Item code', 'inventory', 45),
    (171, 'Employee code', 'hr', 50),
    (202, 'Production Order', 'production', 60),
    (191, 'Service Call', 'service', 70), (190, 'Service Contract', 'service', 71)) AS v(obj_type, label, module, sort)
$$;
CREATE OR REPLACE FUNCTION erp._adm_doc_used(p_obj integer) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_obj NOT IN (16, 203, 21, 19, 30)
$$;
CREATE OR REPLACE FUNCTION erp._adm_doc_label(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((SELECT label FROM erp._adm_doc_types() WHERE obj_type = p_obj), 'Document ' || p_obj)
$$;

-- ============ 2. Document numbering: the allocator ============
-- Number shown for a series and a number.
CREATE OR REPLACE FUNCTION erp._series_no(ns erp.doc_series_all, p_num integer) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT ns.prefix || lpad(p_num::text, ns.pad, '0')
$$;
-- Highest number a series can give: its last number, or what fits in its digits.
CREATE OR REPLACE FUNCTION erp._series_max(ns erp.doc_series_all) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT least(coalesce(ns.last_num::bigint, 2147483647), (10::bigint ^ ns.pad)::bigint - 1, 2147483647)
$$;
-- Why a series can't number a document dated p_date for warehouse p_whs / branch p_branch (NULL = it can).
CREATE OR REPLACE FUNCTION erp._series_problem(ns erp.doc_series_all, p_date date, p_whs text, p_branch integer) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN ns.locked OR NOT ns.active
      THEN format('%s series %s is locked. Choose another series or ask the system admin to unlock it (Administration › System Initialization › Document Numbering).',
                  erp._adm_doc_label(ns.obj_type), ns.name)
    WHEN (ns.period_from IS NOT NULL AND p_date < ns.period_from) OR (ns.period_to IS NOT NULL AND p_date > ns.period_to)
      THEN format('%s series %s is for documents dated %s to %s, not %s. Choose a series for this period.', erp._adm_doc_label(ns.obj_type), ns.name,
                  coalesce(to_char(ns.period_from, 'DD Mon YYYY'), 'any date'), coalesce(to_char(ns.period_to, 'DD Mon YYYY'), 'any date'),
                  to_char(p_date, 'DD Mon YYYY'))
    WHEN ns.whs_code IS NOT NULL AND p_whs IS NOT NULL AND ns.whs_code <> p_whs
      THEN format('%s series %s is for warehouse %s, not %s. Choose a series for %s or one without a warehouse.', erp._adm_doc_label(ns.obj_type),
                  ns.name, ns.whs_code, p_whs, p_whs)
    WHEN ns.branch_id IS NOT NULL AND p_branch IS NOT NULL AND ns.branch_id <> p_branch
      THEN format('%s series %s is for branch %s, not %s. Choose a series for this branch or one without a branch.', erp._adm_doc_label(ns.obj_type),
                  ns.name, ns.branch_id, p_branch)
  END
$$;

-- Lock one series row (default or not) and return it as it is now. NULL when it doesn't exist.
CREATE OR REPLACE FUNCTION erp._series_lock(p_id bigint) RETURNS erp.doc_series_all
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns erp.doc_series_all;
BEGIN
  PERFORM 1 FROM erp.number_series WHERE series_id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM 1 FROM erp.doc_series WHERE series_id = p_id FOR UPDATE;
  END IF;
  SELECT * INTO ns FROM erp.doc_series_all WHERE series_id = p_id;
  RETURN ns;
END $$;

-- Next number for a new document of type p_obj in p_company (row-locked, forward only). Order of choice:
--   1. the series picked on the form (setting erp.series, when it belongs to this company and type) – strict;
--   2. the user's default series (erp.series_user_default; setting erp.series_user names the user when a document is
--      numbered at approval time on behalf of its requester) – skipped when it can't number this document;
--   3. the company default series (erp.number_series, numbering switched on);
--   4. when the default can't number this date / warehouse / branch: the first unlocked series of the type that can.
-- Returns NULL when the company has no default (switched on) and no usable user default: the caller raises its own
-- "numbering is not set up" message. p_skip 'bp' | 'emp' | 'item' skips codes that already exist (typed by hand).
CREATE OR REPLACE FUNCTION erp._series_take(p_company varchar, p_obj integer, p_skip text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ns       erp.doc_series_all;
  v_id     bigint;
  v_pick   bigint := nullif(current_setting('erp.series', true), '')::bigint;
  v_user   uuid := coalesce(nullif(current_setting('erp.series_user', true), '')::uuid, erp.current_user_id());
  v_date   date := coalesce(nullif(current_setting('erp.series_date', true), '')::date, current_date);
  v_whs    text := nullif(current_setting('erp.series_whs', true), '');
  v_branch integer := nullif(current_setting('erp.series_branch', true), '')::integer;
  v_msg    text;
  v_n      bigint;
  v_max    bigint;
  v_code   text;
BEGIN
  IF v_pick IS NOT NULL AND EXISTS (SELECT 1 FROM erp.doc_series_all WHERE series_id = v_pick AND company_code = p_company AND obj_type = p_obj) THEN
    ns := erp._series_lock(v_pick);
    v_msg := erp._series_problem(ns, v_date, v_whs, v_branch);
    IF v_msg IS NOT NULL THEN
      RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF ns.series_id IS NULL AND v_user IS NOT NULL THEN
    SELECT d.series_id INTO v_id FROM erp.series_user_default d WHERE d.user_id = v_user AND d.company_code = p_company AND d.obj_type = p_obj;
    IF v_id IS NOT NULL THEN
      ns := erp._series_lock(v_id);
      IF ns.series_id IS NULL OR ns.company_code <> p_company OR ns.obj_type <> p_obj OR erp._series_problem(ns, v_date, v_whs, v_branch) IS NOT NULL THEN
        ns := NULL;
      END IF;
    END IF;
  END IF;
  IF ns.series_id IS NULL THEN
    SELECT series_id INTO v_id FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active;
    IF v_id IS NULL THEN
      RETURN NULL;
    END IF;
    ns := erp._series_lock(v_id);
    v_msg := erp._series_problem(ns, v_date, v_whs, v_branch);
    IF v_msg IS NOT NULL THEN
      SELECT a.series_id INTO v_id FROM erp.doc_series_all a
       WHERE a.company_code = p_company AND a.obj_type = p_obj AND erp._series_problem(a, v_date, v_whs, v_branch) IS NULL AND a.next_num <= erp._series_max(a)
       ORDER BY (a.whs_code IS NOT NULL OR a.branch_id IS NOT NULL) DESC, a.series_id
       LIMIT 1;
      IF v_id IS NULL THEN
        RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
      END IF;
      ns := erp._series_lock(v_id);
    END IF;
  END IF;

  v_max := erp._series_max(ns);
  v_n := ns.next_num;
  IF p_skip IS NOT NULL THEN
    LOOP
      EXIT WHEN v_n > v_max;
      v_code := erp._series_no(ns, v_n::integer);
      EXIT WHEN NOT CASE p_skip
        WHEN 'bp' THEN EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_code)
        WHEN 'emp' THEN EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND hr_code = v_code)
        WHEN 'item' THEN EXISTS (SELECT 1 FROM erp.item WHERE company_code = p_company AND item_code = v_code)
        ELSE false END;
      v_n := v_n + 1;
    END LOOP;
  END IF;
  IF v_n > v_max THEN
    RAISE EXCEPTION '% series % has used its last number (%). Ask the system admin to add a new series (Administration › System Initialization › Document Numbering).',
      erp._adm_doc_label(p_obj), ns.name, erp._series_no(ns, v_max::integer) USING ERRCODE = 'P0001';
  END IF;
  IF ns.is_default THEN
    UPDATE erp.number_series SET next_num = (v_n + 1)::integer WHERE series_id = ns.series_id;
  ELSE
    UPDATE erp.doc_series SET next_num = (v_n + 1)::integer WHERE series_id = ns.series_id;
  END IF;
  RETURN jsonb_build_object('num', v_n, 'no', erp._series_no(ns, v_n::integer), 'series_id', ns.series_id, 'series', ns.name);
END $$;

-- The overloads call this first: remember the picked series (and date / warehouse / branch) for this transaction only.
-- Not SECURITY DEFINER: anyone may set their own transaction settings; the allocator checks the series again.
CREATE OR REPLACE FUNCTION erp._series_ctx(p_series bigint, p_header jsonb) RETURNS void
LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE
  v_date date;
BEGIN
  BEGIN
    v_date := nullif(btrim(coalesce(p_header->>'doc_date', p_header->>'post_date', p_header->>'deposit_date', p_header->>'count_date',
                                    p_header->>'opened_on', '')), '')::date;
  EXCEPTION WHEN others THEN
    v_date := NULL;      -- the document's own check names the bad date
  END;
  PERFORM set_config('erp.series', coalesce(p_series::text, ''), true);
  PERFORM set_config('erp.series_date', coalesce(v_date::text, ''), true);
  PERFORM set_config('erp.series_whs', coalesce(nullif(btrim(p_header->>'whs_code'), ''), ''), true);
  PERFORM set_config('erp.series_branch', coalesce(CASE WHEN p_header->>'branch_id' ~ '^\d{1,9}$' THEN p_header->>'branch_id' END, ''), true);
END $$;
CREATE OR REPLACE FUNCTION erp._series_clear() RETURNS void
LANGUAGE sql SET search_path = erp, pg_temp AS $$
  SELECT set_config('erp.series', '', true), set_config('erp.series_date', '', true), set_config('erp.series_whs', '', true),
         set_config('erp.series_branch', '', true), set_config('erp.series_user', '', true);
$$;

-- ============ 2. Numbering functions of A2–A13 now use the allocator (messages unchanged) ============
CREATE OR REPLACE FUNCTION erp._sd_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb := erp._series_take(p_company, p_obj);
BEGIN
  IF nb IS NULL THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._sd_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN nb || jsonb_build_object('entry', nextval('erp.erp_doc_entry_seq'));
END $$;

CREATE OR REPLACE FUNCTION erp._bk_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb := erp._series_take(p_company, p_obj);
BEGIN
  IF nb IS NULL THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._bk_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN nb || jsonb_build_object('entry', nextval('erp.erp_doc_entry_seq'));
END $$;

CREATE OR REPLACE FUNCTION erp._pd_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb := erp._series_take(p_company, p_obj);
BEGIN
  IF nb IS NULL THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._pd_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN nb || jsonb_build_object('entry', nextval('erp.erp_doc_entry_seq'));
END $$;

CREATE OR REPLACE FUNCTION erp._inv_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb := erp._series_take(p_company, p_obj);
BEGIN
  IF nb IS NULL THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      erp._inv_name(p_obj), p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN nb || jsonb_build_object('entry', nextval('erp.erp_doc_entry_seq'));
END $$;

CREATE OR REPLACE FUNCTION erp._ps_number(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb := erp._series_take(p_company, p_obj);
BEGIN
  IF nb IS NULL THEN
    RAISE EXCEPTION '% numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      CASE p_obj WHEN 202 THEN 'Production order' WHEN 191 THEN 'Service call' WHEN 190 THEN 'Service contract' ELSE 'Document' END,
      p_company USING ERRCODE = 'P0001';
  END IF;
  RETURN nb || jsonb_build_object('entry', nextval('erp.erp_doc_entry_seq'));
END $$;

-- Next free partner code from the company's series for this type (row-locked; skips codes that already exist).
CREATE OR REPLACE FUNCTION erp._md_next_code(p_company varchar, p_kind text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb := erp._series_take(p_company, CASE p_kind WHEN 'customer' THEN 2001 WHEN 'supplier' THEN 2002 ELSE 2003 END, 'bp');
BEGIN
  IF nb IS NULL THEN
    RAISE EXCEPTION 'Partner numbering for % is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      CASE p_kind WHEN 'customer' THEN 'customers' WHEN 'supplier' THEN 'suppliers' ELSE 'leads' END, p_company USING ERRCODE = 'P0001';
  END IF;
  IF length(nb->>'no') > 15 THEN
    RAISE EXCEPTION 'The next partner code % is longer than 15 characters. Ask the system admin to shorten the series.', nb->>'no' USING ERRCODE = 'P0001';
  END IF;
  RETURN nb->>'no';
END $$;

-- ============ 3. Tables and columns for the rule changes ============
-- Credit memos and direct service invoices that need approval wait here; the last approval creates the document.
CREATE TABLE IF NOT EXISTS erp.sales_doc_request (
    request_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    obj_type       integer NOT NULL CHECK (obj_type IN (13, 14)),
    card_code      varchar(15),
    card_name      text,
    total          numeric(19,2),
    currency       varchar(3),
    header         jsonb NOT NULL,
    lines          jsonb NOT NULL,
    checks         jsonb NOT NULL DEFAULT '[]'::jsonb,
    series_id      bigint,                            -- the series picked on the form (the number is taken at approval)
    state          text NOT NULL DEFAULT 'pending_approval' CHECK (state IN ('pending_approval', 'approved', 'rejected', 'cancelled')),
    reason         text,
    requested_by   uuid NOT NULL,
    requested_at   timestamptz NOT NULL DEFAULT now(),
    decided_at     timestamptz,
    doc_entry      integer,
    doc_no         text,
    note           text
);
CREATE INDEX IF NOT EXISTS sales_doc_request_state_idx ON erp.sales_doc_request (company_code, state);
ALTER TABLE erp.sales_doc_request ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sales_doc_request FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sales_doc_request TO authenticated;
DROP POLICY IF EXISTS sales_doc_request_read ON erp.sales_doc_request;
CREATE POLICY sales_doc_request_read ON erp.sales_doc_request FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('sales')) OR (SELECT erp.can_read('finance'))));

ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount', 'payment_amount', 'bank_change',
                       'po_amount', 'po_price_increase', 'stock_doc_amount', 'count_variance_pct', 'count_variance_value',
                       'bp_credit_limit', 'bp_bank_detail', 'credit_memo_amount'));

-- Who may issue spare parts (C8). Both lists empty = the service manager position.
ALTER TABLE erp.service_setting
  ADD COLUMN IF NOT EXISTS manager_position text REFERENCES erp.position ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS parts_positions  text[],
  ADD COLUMN IF NOT EXISTS parts_users      uuid[];

-- Mould warning % (of the maintenance interval and of the rated life), editable per mould. NULL = the company's
-- production_setting.life_warn_pct, else 80. mould_schedule keeps 28's columns (so 28 re-runs cleanly) and gains
-- maint_status 'due_soon'.
ALTER TABLE erp.prod_resource ADD COLUMN IF NOT EXISTS warn_pct numeric(5,2);
ALTER TABLE erp.prod_resource DROP CONSTRAINT IF EXISTS prod_resource_warn_pct_check;
ALTER TABLE erp.prod_resource ADD CONSTRAINT prod_resource_warn_pct_check CHECK (warn_pct IS NULL OR (warn_pct > 0 AND warn_pct <= 100));

-- QC must pass before goods can ship (always on).
ALTER TABLE erp.purchase_setting ALTER COLUMN require_qc_pass SET DEFAULT true;
UPDATE erp.purchase_setting SET require_qc_pass = true WHERE NOT require_qc_pass;

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
            WHEN (r.maint_every_shots IS NOT NULL AND 100.0 * (r.shots_done - r.last_maint_shots) >= r.maint_every_shots * coalesce(r.warn_pct, s.life_warn_pct, 80))
              OR (r.maint_every_days IS NOT NULL AND r.last_maint_on IS NOT NULL
                  AND 100.0 * (current_date - r.last_maint_on) >= r.maint_every_days * coalesce(r.warn_pct, s.life_warn_pct, 80)) THEN 'due_soon'
            ELSE 'ok' END AS maint_status,
       (r.rated_life_shots IS NOT NULL AND 100.0 * r.shots_done / r.rated_life_shots >= coalesce(r.warn_pct, s.life_warn_pct, 80)) AS life_warn,
       r.source
  FROM erp.prod_resource r
  LEFT JOIN erp.production_setting s ON s.company_code = r.company_code;
REVOKE ALL ON erp.mould_schedule FROM PUBLIC, anon;
GRANT SELECT ON erp.mould_schedule TO authenticated;

-- ============ 3. Expired quotations can't be copied to an order ============
CREATE OR REPLACE FUNCTION erp._sd_quote_expired_msg(p_no text, p_until date) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT format('Quotation %s expired on %s. An expired quotation can''t be copied to an order. Raise a new quotation.', p_no, to_char(p_until, 'DD Mon YYYY'))
$$;

-- Super ERP order lines copied from a quotation: the quotation's valid-until date (document.due_date) must not have passed.
-- SAP rows (the sync) and sample rows are never checked.
CREATE OR REPLACE FUNCTION erp._sd_quote_expiry() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  q    erp.document;
  v_no text;
BEGIN
  IF NEW.obj_type <> 17 OR NEW.base_obj_type IS DISTINCT FROM 23 OR NEW.base_doc_entry IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.base_obj_type IS NOT DISTINCT FROM NEW.base_obj_type AND OLD.base_doc_entry IS NOT DISTINCT FROM NEW.base_doc_entry THEN
    RETURN NEW;
  END IF;
  IF coalesce(current_setting('erp.sync', true), '') = 'on'
     OR NOT EXISTS (SELECT 1 FROM erp.document WHERE company_code = NEW.company_code AND obj_type = 17 AND doc_entry = NEW.doc_entry AND source = 'erp') THEN
    RETURN NEW;
  END IF;
  SELECT * INTO q FROM erp.document WHERE company_code = NEW.company_code AND obj_type = 23 AND doc_entry = NEW.base_doc_entry;
  IF FOUND AND q.due_date < current_date THEN
    SELECT doc_no INTO v_no FROM erp.doc_workflow WHERE company_code = q.company_code AND obj_type = 23 AND doc_entry = q.doc_entry;
    RAISE EXCEPTION 'Line %: %', NEW.line_num + 1, erp._sd_quote_expired_msg(coalesce(v_no, q.doc_num::text), q.due_date) USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b1_sd_quote_expiry ON erp.document_line;
CREATE TRIGGER b1_sd_quote_expiry BEFORE INSERT OR UPDATE OF base_obj_type, base_doc_entry ON erp.document_line
  FOR EACH ROW EXECUTE FUNCTION erp._sd_quote_expiry();

-- ============ 3. Spare parts: who may issue them ============
-- NULL when the user may issue spare parts in the company, else why not.
CREATE OR REPLACE FUNCTION erp._svc_parts_ok(p_company varchar, u erp.app_user) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s erp.service_setting;
BEGIN
  SELECT * INTO s FROM erp.service_setting WHERE company_code = p_company;
  IF coalesce(cardinality(s.parts_positions), 0) > 0 OR coalesce(cardinality(s.parts_users), 0) > 0 THEN
    IF u.position_code = ANY (coalesce(s.parts_positions, '{}')) OR u.user_id = ANY (coalesce(s.parts_users, '{}')) THEN
      RETURN NULL;
    END IF;
    RETURN format('Your position can''t issue spare parts in company %s. Ask the service manager to add you in Service Setup (who may issue spare parts).', p_company);
  END IF;
  IF s.manager_position IS NULL THEN
    RETURN format('Nobody may issue spare parts in company %s yet. Ask the service manager to set who may issue them in Service Setup.', p_company);
  END IF;
  IF u.position_code = s.manager_position THEN
    RETURN NULL;
  END IF;
  RETURN format('Only the service manager position (%s) may issue spare parts in company %s. Ask the service manager to add you in Service Setup.',
                coalesce((SELECT name FROM erp.position WHERE position_code = s.manager_position), s.manager_position), p_company);
END $$;

-- ============ 2. Document numbering: administration ============
CREATE OR REPLACE FUNCTION erp._series_json(n erp.doc_series_all) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'series_id', n.series_id, 'obj_type', n.obj_type, 'name', n.name, 'prefix', n.prefix, 'first_num', n.first_num, 'next_num', n.next_num,
    'last_num', n.last_num, 'pad', n.pad, 'period_from', n.period_from, 'period_to', n.period_to, 'branch_id', n.branch_id, 'whs_code', n.whs_code,
    'locked', n.locked OR NOT n.active, 'is_default', n.is_default, 'remarks', n.remarks, 'used', n.next_num > n.first_num,
    'example', CASE WHEN n.next_num <= erp._series_max(n) THEN erp._series_no(n, n.next_num) END,
    'left', greatest(erp._series_max(n) - n.next_num + 1, 0),
    'users', (SELECT count(*) FROM erp.series_user_default d WHERE d.series_id = n.series_id))
$$;

-- Administration › System Initialization › Document Numbering: every document type with its series, and the users'
-- default series. Read = Administration / IT / owner; write = Administration full.
CREATE OR REPLACE FUNCTION erp.doc_numbering_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'types', (SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'label', d.label, 'module', d.module, 'used', erp._adm_doc_used(d.obj_type),
                'series', coalesce((SELECT jsonb_agg(erp._series_json(n) ORDER BY n.is_default DESC, n.series_id) FROM erp.doc_series_all n
                                     WHERE n.company_code = p_company AND n.obj_type = d.obj_type), '[]'::jsonb)) ORDER BY d.sort)
                FROM erp._adm_doc_types() d),
    'users', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', a.user_id, 'display_name', a.display_name, 'email', a.email,
                         'position_name', p.name) ORDER BY a.display_name)
                         FROM erp.app_user a JOIN erp.position p ON p.position_code = a.position_code
                        WHERE a.active AND EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = a.user_id AND uc.company_code = p_company)), '[]'::jsonb),
    'user_defaults', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', d.user_id, 'obj_type', d.obj_type, 'series_id', d.series_id))
                                 FROM erp.series_user_default d WHERE d.company_code = p_company), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('code', w.whs_code, 'name', w.name) ORDER BY w.whs_code)
                              FROM erp.warehouse w WHERE w.company_code = p_company AND w.active), '[]'::jsonb),
    'branches', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.branch_id, 'name', b.name) ORDER BY b.branch_id)
                            FROM erp.branch b WHERE b.company_code = p_company AND b.active), '[]'::jsonb));
END $$;

-- Create (no series_id) or change a series.
-- p_s: {series_id?, obj_type, name, prefix, first_num, next_num, last_num, pad, period_from, period_to, branch_id, whs_code, locked,
--       is_default, remarks}. The first series of a type becomes its default. Numbers only move forward; once a series has
-- numbered documents its prefix and first number are fixed.
CREATE OR REPLACE FUNCTION erp.doc_series_save(p_company varchar, p_s jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me      erp.app_user := erp._adm_guard(true);
  s       jsonb := coalesce(p_s, '{}'::jsonb);
  old     erp.doc_series_all;
  n       erp.doc_series_all;
  dft     erp.number_series;
  x       erp.doc_series;
  v_id    bigint := erp._num(nullif(btrim(s->>'series_id'), ''))::bigint;
  v_new   bigint;
  v_obj   integer;
  v_lab   text;
  v_name  text := btrim(coalesce(s->>'name', ''));
  v_pre   text := btrim(coalesce(s->>'prefix', ''));
  v_first integer;
  v_next  integer;
  v_last  integer;
  v_pad   integer;
  v_from  date;
  v_to    date;
  v_br    integer;
  v_whs   text := nullif(upper(btrim(s->>'whs_code')), '');
  v_lock  boolean := coalesce((s->>'locked')::boolean, false);
  v_def   boolean;
  v_has   boolean;
  v_other text;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF v_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM erp.doc_series_all WHERE series_id = v_id AND company_code = p_company) THEN
      RAISE EXCEPTION 'Series % was not found in company %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
    old := erp._series_lock(v_id);
    v_obj := old.obj_type;
  ELSE
    v_obj := erp._num(nullif(btrim(s->>'obj_type'), ''))::integer;
  END IF;
  SELECT label INTO v_lab FROM erp._adm_doc_types() WHERE obj_type = v_obj;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document type % has no numbering in Super ERP.', coalesce(v_obj::text, '(none)') USING ERRCODE = 'P0001';
  END IF;
  IF length(v_name) NOT BETWEEN 1 AND 40 THEN
    RAISE EXCEPTION 'Enter a series name (1 to 40 characters).' USING ERRCODE = 'P0001';
  END IF;
  IF v_pre !~ '^[A-Za-z0-9/_-]{1,20}$' THEN
    RAISE EXCEPTION 'Use letters, digits, - / or _ in the prefix (1 to 20 characters).' USING ERRCODE = 'P0001';
  END IF;
  v_pad := coalesce(erp._num(nullif(btrim(s->>'pad'), ''))::integer, old.pad, 5);
  IF v_pad NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'Digits must be between 1 and 10.' USING ERRCODE = 'P0001';
  END IF;
  v_first := coalesce(erp._num(nullif(btrim(s->>'first_num'), ''))::integer, old.first_num, 1);
  v_next := coalesce(erp._num(nullif(btrim(s->>'next_num'), ''))::integer, old.next_num, v_first);
  v_last := erp._num(nullif(btrim(s->>'last_num'), ''))::integer;
  IF v_first < 1 THEN
    RAISE EXCEPTION 'The first number must be 1 or more.' USING ERRCODE = 'P0001';
  END IF;
  IF v_next < v_first THEN
    RAISE EXCEPTION 'The next number can''t be below the first number %.', v_first USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NOT NULL AND v_last < v_first THEN
    RAISE EXCEPTION 'The last number must be at least the first number.' USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NOT NULL AND v_next > v_last + 1 THEN
    RAISE EXCEPTION 'The next number % is past the last number %.', v_next, v_last USING ERRCODE = 'P0001';
  END IF;
  IF length(v_next::text) > v_pad THEN
    RAISE EXCEPTION 'The next number % has more digits than the % set. Add digits or lower the number.', v_next, v_pad USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NOT NULL AND length(v_last::text) > v_pad THEN
    RAISE EXCEPTION 'The last number % has more digits than the % set. Add digits or lower the number.', v_last, v_pad USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(s->>'period_from'), '') IS NOT NULL THEN
    v_from := erp._date(s->>'period_from');
    IF v_from IS NULL THEN RAISE EXCEPTION 'The period start is not a valid date.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF nullif(btrim(s->>'period_to'), '') IS NOT NULL THEN
    v_to := erp._date(s->>'period_to');
    IF v_to IS NULL THEN RAISE EXCEPTION 'The period end is not a valid date.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF v_to < v_from THEN
    RAISE EXCEPTION 'The period ends before it starts. Check the dates.' USING ERRCODE = 'P0001';
  END IF;
  IF v_whs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_whs, p_company USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(s->>'branch_id'), '') IS NOT NULL THEN
    v_br := erp._num(s->>'branch_id')::integer;
    IF v_br IS NULL OR NOT EXISTS (SELECT 1 FROM erp.branch WHERE company_code = p_company AND branch_id = v_br) THEN
      RAISE EXCEPTION 'Branch % does not exist in company %.', s->>'branch_id', p_company USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM erp.doc_series_all WHERE company_code = p_company AND obj_type = v_obj AND lower(name) = lower(v_name)
                                                 AND series_id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'Series name % is already used for %. Choose another name.', v_name, v_lab USING ERRCODE = 'P0001';
  END IF;
  SELECT erp._adm_doc_label(a.obj_type) || ' (' || a.name || ')' INTO v_other FROM erp.doc_series_all a
   WHERE a.company_code = p_company AND upper(a.prefix) = upper(v_pre) AND a.series_id IS DISTINCT FROM v_id LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'Prefix % is already used by %. Choose a different prefix.', v_pre, v_other USING ERRCODE = 'P0001';
  END IF;
  IF old.series_id IS NOT NULL AND old.next_num > old.first_num THEN
    IF v_pre <> old.prefix THEN
      RAISE EXCEPTION 'The prefix of series % can''t change: it has already numbered documents. Add a new series instead.', old.name USING ERRCODE = 'P0001';
    END IF;
    IF v_first <> old.first_num THEN
      RAISE EXCEPTION 'The first number of series % can''t change: it has already numbered documents.', old.name USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF old.series_id IS NOT NULL AND v_pre = old.prefix AND v_next < old.next_num THEN
    RAISE EXCEPTION 'Numbers only move forward: % series % has already reached %. Use a higher number or a new series.',
      v_lab, old.name, erp._series_no(old, old.next_num) USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = v_obj AND doc_no = v_pre || lpad(v_next::text, v_pad, '0')) THEN
    RAISE EXCEPTION 'Number % is already used. Choose a higher next number.', v_pre || lpad(v_next::text, v_pad, '0') USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO dft FROM erp.number_series WHERE company_code = p_company AND obj_type = v_obj FOR UPDATE;
  v_has := FOUND;
  v_def := NOT v_has OR coalesce((s->>'is_default')::boolean, old.is_default, false);
  IF v_def AND v_lock THEN
    RAISE EXCEPTION 'A locked series can''t be the default. Unlock it or make another series the default.' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(old.is_default, false) AND NOT v_def THEN
    RAISE EXCEPTION 'Every document type keeps one default series. Make another series the default instead.' USING ERRCODE = 'P0001';
  END IF;

  IF old.series_id IS NULL AND NOT v_has THEN
    INSERT INTO erp.number_series (company_code, obj_type, name, prefix, first_num, next_num, last_num, pad, period_from, period_to, branch_id,
                                   whs_code, locked, active, remarks, updated_by, updated_at)
    VALUES (p_company, v_obj, v_name, v_pre, v_first, v_next, v_last, v_pad, v_from, v_to, v_br, v_whs, false, true,
            nullif(btrim(s->>'remarks'), ''), me.user_id, now())
    RETURNING series_id INTO v_new;
  ELSIF old.series_id IS NULL THEN
    INSERT INTO erp.doc_series (company_code, obj_type, name, prefix, first_num, next_num, last_num, pad, period_from, period_to, branch_id,
                                whs_code, locked, remarks, updated_by, updated_at)
    VALUES (p_company, v_obj, v_name, v_pre, v_first, v_next, v_last, v_pad, v_from, v_to, v_br, v_whs, v_lock,
            nullif(btrim(s->>'remarks'), ''), me.user_id, now())
    RETURNING series_id INTO v_new;
  ELSIF old.is_default THEN
    v_new := v_id;
    UPDATE erp.number_series SET name = v_name, prefix = v_pre, first_num = v_first, next_num = v_next, last_num = v_last, pad = v_pad,
           period_from = v_from, period_to = v_to, branch_id = v_br, whs_code = v_whs, locked = false, active = true,
           remarks = nullif(btrim(s->>'remarks'), ''), updated_by = me.user_id, updated_at = now()
     WHERE series_id = v_id;
  ELSE
    v_new := v_id;
    UPDATE erp.doc_series SET name = v_name, prefix = v_pre, first_num = v_first, next_num = v_next, last_num = v_last, pad = v_pad,
           period_from = v_from, period_to = v_to, branch_id = v_br, whs_code = v_whs, locked = v_lock,
           remarks = nullif(btrim(s->>'remarks'), ''), updated_by = me.user_id, updated_at = now()
     WHERE series_id = v_id;
  END IF;
  -- Becoming the default: swap the contents of the default row and this series (each keeps its series_id).
  IF v_def AND v_has AND v_new IS DISTINCT FROM dft.series_id THEN
    SELECT * INTO x FROM erp.doc_series WHERE series_id = v_new FOR UPDATE;
    DELETE FROM erp.doc_series WHERE series_id = v_new;
    INSERT INTO erp.doc_series (series_id, company_code, obj_type, name, prefix, first_num, next_num, last_num, pad, period_from, period_to,
                                branch_id, whs_code, locked, remarks, updated_by, updated_at)
    VALUES (dft.series_id, dft.company_code, dft.obj_type, dft.name, dft.prefix, dft.first_num, dft.next_num, dft.last_num, dft.pad, dft.period_from,
            dft.period_to, dft.branch_id, dft.whs_code, dft.locked OR NOT dft.active, dft.remarks, me.user_id, now());
    UPDATE erp.number_series SET series_id = x.series_id, name = x.name, prefix = x.prefix, first_num = x.first_num, next_num = x.next_num,
           last_num = x.last_num, pad = x.pad, period_from = x.period_from, period_to = x.period_to, branch_id = x.branch_id, whs_code = x.whs_code,
           locked = false, active = true, remarks = x.remarks, updated_by = me.user_id, updated_at = now()
     WHERE company_code = p_company AND obj_type = v_obj;
  END IF;
  SELECT * INTO n FROM erp.doc_series_all WHERE series_id = v_new;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'doc_series_save', 'number_series', v_obj::text,
          jsonb_build_object('series_id', v_new, 'before', CASE WHEN old.series_id IS NULL THEN NULL ELSE to_jsonb(old) - 'updated_at' END,
                             'after', to_jsonb(n) - 'updated_at'));
  RETURN erp._series_json(n);
END $$;

-- Delete a series that never numbered a document (and isn't the default). Used series are locked instead.
CREATE OR REPLACE FUNCTION erp.doc_series_delete(p_company varchar, p_series_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  old erp.doc_series_all;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF NOT EXISTS (SELECT 1 FROM erp.doc_series_all WHERE series_id = p_series_id AND company_code = p_company) THEN
    RAISE EXCEPTION 'Series % was not found in company %.', coalesce(p_series_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  old := erp._series_lock(p_series_id);
  IF old.next_num > old.first_num THEN
    RAISE EXCEPTION 'Series % has already numbered documents (next number %), so it can''t be deleted. Lock it instead.',
      old.name, erp._series_no(old, old.next_num) USING ERRCODE = 'P0001';
  END IF;
  IF old.is_default THEN
    RAISE EXCEPTION 'Series % is the default for %. Make another series the default first.', old.name, erp._adm_doc_label(old.obj_type) USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM erp.series_user_default WHERE series_id = p_series_id;
  DELETE FROM erp.doc_series WHERE series_id = p_series_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'doc_series_delete', 'number_series', old.obj_type::text, jsonb_build_object('before', to_jsonb(old) - 'updated_at'));
  RETURN jsonb_build_object('series_id', p_series_id, 'deleted', true);
END $$;

-- A user's default series for a document type (p_series NULL = back to the company default).
CREATE OR REPLACE FUNCTION erp.series_user_default_save(p_company varchar, p_user uuid, p_obj integer, p_series bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  a   erp.app_user;
  n   erp.doc_series_all;
  v_old bigint;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO a FROM erp.app_user WHERE user_id = p_user;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM erp.user_company WHERE user_id = p_user AND company_code = p_company) THEN
    RAISE EXCEPTION 'User % has no access to company %.', coalesce(a.display_name, p_user::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp._adm_doc_types() WHERE obj_type = p_obj) THEN
    RAISE EXCEPTION 'Document type % has no numbering in Super ERP.', coalesce(p_obj::text, '(none)') USING ERRCODE = 'P0001';
  END IF;
  SELECT series_id INTO v_old FROM erp.series_user_default WHERE user_id = p_user AND company_code = p_company AND obj_type = p_obj;
  IF p_series IS NULL THEN
    DELETE FROM erp.series_user_default WHERE user_id = p_user AND company_code = p_company AND obj_type = p_obj;
  ELSE
    SELECT * INTO n FROM erp.doc_series_all WHERE series_id = p_series AND company_code = p_company AND obj_type = p_obj;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Series % is not a % series of company %.', p_series, erp._adm_doc_label(p_obj), p_company USING ERRCODE = 'P0001';
    END IF;
    IF n.locked OR NOT n.active THEN
      RAISE EXCEPTION 'Series % is locked, so it can''t be a default. Unlock it first.', n.name USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.series_user_default (user_id, company_code, obj_type, series_id, updated_by, updated_at)
    VALUES (p_user, p_company, p_obj, p_series, me.user_id, now())
    ON CONFLICT (user_id, company_code, obj_type) DO UPDATE SET series_id = EXCLUDED.series_id, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'series_user_default_save', 'number_series', p_obj::text,
          jsonb_build_object('user_id', p_user, 'user', a.display_name, 'before', v_old, 'after', p_series));
  RETURN jsonb_build_object('user_id', p_user, 'obj_type', p_obj, 'series_id', p_series);
END $$;

-- Series a user may pick on a new document of type p_obj, and the one picked for them by default.
CREATE OR REPLACE FUNCTION erp.doc_series_options(p_company varchar, p_obj integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_me   uuid := erp.current_user_id();
  v_mine bigint;
  v_def  bigint;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  SELECT d.series_id INTO v_mine FROM erp.series_user_default d JOIN erp.doc_series_all n ON n.series_id = d.series_id
   WHERE d.user_id = v_me AND d.company_code = p_company AND d.obj_type = p_obj AND NOT n.locked AND n.active;
  SELECT series_id INTO v_def FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active AND NOT locked;
  RETURN jsonb_build_object(
    'obj_type', p_obj, 'label', erp._adm_doc_label(p_obj), 'default_id', coalesce(v_mine, v_def), 'mine', v_mine,
    'series', coalesce((SELECT jsonb_agg(jsonb_build_object('series_id', n.series_id, 'name', n.name, 'prefix', n.prefix,
                          'example', CASE WHEN n.next_num <= erp._series_max(n) THEN erp._series_no(n, n.next_num) END,
                          'period_from', n.period_from, 'period_to', n.period_to, 'whs_code', n.whs_code, 'branch_id', n.branch_id,
                          'is_default', n.is_default, 'full', n.next_num > erp._series_max(n)) ORDER BY n.is_default DESC, n.name)
                          FROM erp.doc_series_all n WHERE n.company_code = p_company AND n.obj_type = p_obj AND NOT n.locked AND n.active), '[]'::jsonb));
END $$;

-- A10's numbering call, kept (the default series): its prefix check now covers every series, and a last number is respected.
CREATE OR REPLACE FUNCTION erp.number_series_save(p_company varchar, p_obj integer, p_prefix text, p_next integer, p_pad integer, p_active boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  old    erp.number_series;
  v_lab  text;
  v_pre  text := btrim(coalesce(p_prefix, ''));
  v_pad  integer := coalesce(p_pad, 5);
  v_other text;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT label INTO v_lab FROM erp._adm_doc_types() WHERE obj_type = p_obj;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document type % has no numbering in Super ERP.', coalesce(p_obj::text, '(none)') USING ERRCODE = 'P0001';
  END IF;
  IF v_pre !~ '^[A-Za-z0-9/_-]{1,20}$' THEN
    RAISE EXCEPTION 'Use letters, digits, - / or _ in the prefix (1 to 20 characters).' USING ERRCODE = 'P0001';
  END IF;
  IF p_next IS NULL OR p_next < 1 THEN
    RAISE EXCEPTION 'The next number must be 1 or more.' USING ERRCODE = 'P0001';
  END IF;
  IF v_pad NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'Digits must be between 1 and 10.' USING ERRCODE = 'P0001';
  END IF;
  IF length(p_next::text) > v_pad THEN
    RAISE EXCEPTION 'The next number % has more digits than the % set. Add digits or lower the number.', p_next, v_pad USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj FOR UPDATE;
  SELECT d.label INTO v_other FROM erp.doc_series_all n JOIN erp._adm_doc_types() d ON d.obj_type = n.obj_type
   WHERE n.company_code = p_company AND n.series_id IS DISTINCT FROM old.series_id AND upper(n.prefix) = upper(v_pre) LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'Prefix % is already used by %. Choose a different prefix.', v_pre, v_other USING ERRCODE = 'P0001';
  END IF;
  IF old.series_id IS NOT NULL AND old.prefix = v_pre AND p_next < old.next_num THEN
    RAISE EXCEPTION 'Numbers only move forward: % has already reached %. Use a higher number or a new prefix.',
      v_lab, old.prefix || lpad(old.next_num::text, old.pad, '0') USING ERRCODE = 'P0001';
  END IF;
  IF old.last_num IS NOT NULL AND p_next > old.last_num + 1 THEN
    RAISE EXCEPTION 'The next number % is past the last number %.', p_next, old.last_num USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_no = v_pre || lpad(p_next::text, v_pad, '0')) THEN
    RAISE EXCEPTION 'Number % is already used. Choose a higher next number.', v_pre || lpad(p_next::text, v_pad, '0') USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad, active, first_num, updated_by, updated_at)
  VALUES (p_company, p_obj, v_pre, p_next, v_pad, coalesce(p_active, true), p_next, me.user_id, now())
  ON CONFLICT (company_code, obj_type) DO UPDATE SET prefix = EXCLUDED.prefix, next_num = EXCLUDED.next_num, pad = EXCLUDED.pad, active = EXCLUDED.active,
         first_num = least(number_series.first_num, EXCLUDED.next_num), updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'number_series_save', 'number_series', p_obj::text,
          jsonb_build_object('before', CASE WHEN old.obj_type IS NULL THEN NULL ELSE to_jsonb(old) - 'updated_by' - 'updated_at' END,
                             'after', jsonb_build_object('prefix', v_pre, 'next_num', p_next, 'pad', v_pad, 'active', coalesce(p_active, true))));
  RETURN jsonb_build_object('obj_type', p_obj, 'example', v_pre || lpad(p_next::text, v_pad, '0'));
END $$;

-- ============ 2. The series picked on the form: p_series overloads (old signatures unchanged) ============
CREATE OR REPLACE FUNCTION erp.sales_doc_save(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.sales_doc_save(p_company, p_obj, p_doc_entry, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.sales_delivery_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.sales_delivery_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.sales_invoice_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.sales_invoice_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.sales_credit_memo_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.sales_credit_memo_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

-- A payment above a limit waits for approval and is numbered when the last approval posts it: the draft keeps the series.
CREATE OR REPLACE FUNCTION erp.payment_submit(p_company varchar, p_dir text, p_header jsonb, p_lines jsonb, p_reason text, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.payment_submit(p_company, p_dir, p_header, p_lines, p_reason);
  IF r->>'state' = 'pending_approval' AND p_series IS NOT NULL THEN
    UPDATE erp.payment_draft SET series_id = p_series WHERE company_code = p_company AND draft_id = (r->>'draft_id')::integer;
  END IF;
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.deposit_create(p_company varchar, p_header jsonb, p_cheques jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.deposit_create(p_company, p_header, p_cheques);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.purchase_doc_save(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.purchase_doc_save(p_company, p_obj, p_doc_entry, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.purchase_deposit_create(p_company varchar, p_po integer, p_header jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.purchase_deposit_create(p_company, p_po, p_header);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.purchase_grpo_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.purchase_grpo_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.purchase_invoice_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.purchase_invoice_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.landed_cost_create(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.landed_cost_create(p_company, p_header, p_lines, p_charges);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.inventory_doc_create(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_reason text, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.inventory_doc_create(p_company, p_obj, p_header, p_lines, p_reason);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.transfer_request_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header - 'whs_code');
  r := erp.transfer_request_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.transfer_create(p_company varchar, p_header jsonb, p_lines jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header - 'whs_code');
  r := erp.transfer_create(p_company, p_header, p_lines);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.inv_count_create(p_company varchar, p_header jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.inv_count_create(p_company, p_header);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.bp_save(p_company varchar, p_bp jsonb, p_dup_reason text, p_reason text, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, '{}'::jsonb);
  r := erp.bp_save(p_company, p_bp, p_dup_reason, p_reason);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

-- Item codes: a new item with an empty code takes the next code from the item code series (SAP "Manual Master Data Series").
-- Without an item series the code stays mandatory (A8's message).
CREATE OR REPLACE FUNCTION erp.item_save(p_company varchar, p_item jsonb, p_dup_reason text, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r  jsonb;
  nb jsonb;
  v  jsonb := coalesce(p_item, '{}'::jsonb);
BEGIN
  IF NOT coalesce((v->>'edit')::boolean, false) AND nullif(btrim(v->>'item_code'), '') IS NULL THEN
    PERFORM erp._md_item_guard(p_company, true);
    PERFORM erp._series_ctx(p_series, '{}'::jsonb);
    nb := erp._series_take(p_company, 4, 'item');
    IF nb IS NOT NULL THEN
      v := v || jsonb_build_object('item_code', nb->>'no');
    END IF;
  END IF;
  r := erp.item_save(p_company, v, p_dup_reason);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.hr_employee_save(p_company varchar, p_emp jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, '{}'::jsonb || jsonb_build_object('branch_id', p_emp->>'branch_id'));
  r := erp.hr_employee_save(p_company, p_emp);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.prod_order_create(p_company varchar, p_header jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, p_header);
  r := erp.prod_order_create(p_company, p_header);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.service_contract_save(p_company varchar, p_c jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, '{}'::jsonb);
  r := erp.service_contract_save(p_company, p_c);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION erp.service_call_save(p_company varchar, p_call jsonb, p_series bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE r jsonb;
BEGIN
  PERFORM erp._series_ctx(p_series, '{}'::jsonb);
  r := erp.service_call_save(p_company, p_call);
  PERFORM erp._series_clear();
  RETURN r;
END $$;

-- ============ 2. Employee codes (copied from 24; the number comes from erp._series_take) ============
-- ============ API: employees ============
-- Create or change a Super ERP employee (HR full). New when emp_id is left out. SAP and sample employees are refused: change
-- them in SAP until the company goes live. Keys left out keep their value.
CREATE OR REPLACE FUNCTION erp.hr_employee_save(p_company varchar, p_emp jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  e      erp.employee;
  v_new  boolean := (p_emp->>'emp_id') IS NULL;
  v_id   integer;
  v_code text;
  nb     jsonb;
  v_first text; v_last text; v_join date; v_left date; v_mgr integer; v_email text; v_gov text; v_status text; v_birth date;
  v_cur  integer;
  v_n    integer := 0;
BEGIN
  u := erp._hr_guard(p_company, 'full');
  IF p_emp IS NULL OR jsonb_typeof(p_emp) <> 'object' THEN
    RAISE EXCEPTION 'Send the employee details.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_new THEN
    SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = (p_emp->>'emp_id')::integer FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Employee % was not found in company %.', p_emp->>'emp_id', p_company USING ERRCODE = 'P0001';
    END IF;
    IF e.source <> 'erp' THEN
      RAISE EXCEPTION 'This employee comes from SAP. Change it in SAP until % goes live on Super ERP. HR details (shift, site, WPS, tickets) can still be changed here.', p_company
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_first := CASE WHEN p_emp ? 'first_name' THEN nullif(btrim(p_emp->>'first_name'), '') ELSE e.first_name END;
  v_last  := CASE WHEN p_emp ? 'last_name' THEN nullif(btrim(p_emp->>'last_name'), '') ELSE e.last_name END;
  v_join  := CASE WHEN p_emp ? 'joined_on' THEN erp._date(p_emp->>'joined_on') ELSE e.joined_on END;
  v_left  := CASE WHEN p_emp ? 'left_on' THEN erp._date(p_emp->>'left_on') ELSE e.left_on END;
  v_birth := CASE WHEN p_emp ? 'birth_date' THEN erp._date(p_emp->>'birth_date') ELSE e.birth_date END;
  v_mgr   := CASE WHEN p_emp ? 'manager_emp_id' THEN (nullif(p_emp->>'manager_emp_id', ''))::integer ELSE e.manager_emp_id END;
  v_email := CASE WHEN p_emp ? 'email' THEN nullif(btrim(p_emp->>'email'), '') ELSE e.email END;
  v_gov   := CASE WHEN p_emp ? 'gov_id' THEN nullif(regexp_replace(coalesce(p_emp->>'gov_id', ''), '[\s-]', '', 'g'), '') ELSE e.gov_id END;
  v_status := CASE WHEN p_emp ? 'status' THEN coalesce(nullif(p_emp->>'status', ''), 'active') ELSE coalesce(e.status, 'active') END;
  IF v_first IS NULL THEN
    RAISE EXCEPTION 'Enter the first name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NULL THEN
    RAISE EXCEPTION 'Enter the last name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_join IS NULL THEN
    RAISE EXCEPTION 'Enter the joining date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_left IS NOT NULL AND v_left < v_join THEN
    RAISE EXCEPTION 'The leaving date can''t be before the joining date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_birth IS NOT NULL AND v_birth >= v_join THEN
    RAISE EXCEPTION 'The date of birth must be before the joining date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('active', 'on_leave', 'left') THEN
    RAISE EXCEPTION 'Status must be active, on leave or left.' USING ERRCODE = 'P0001';
  END IF;
  IF v_status = 'left' AND v_left IS NULL THEN
    RAISE EXCEPTION 'Enter the leaving date for an employee who has left.' USING ERRCODE = 'P0001';
  END IF;
  IF v_email IS NOT NULL AND v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'The e-mail % doesn''t look right. Check it.', v_email USING ERRCODE = 'P0001';
  END IF;
  IF v_gov IS NOT NULL AND v_gov !~ '^784[0-9]{12}$' THEN
    RAISE EXCEPTION 'The Emirates ID must be 15 digits starting with 784.' USING ERRCODE = 'P0001';
  END IF;
  IF p_emp ? 'nationality' AND nullif(p_emp->>'nationality', '') IS NOT NULL AND p_emp->>'nationality' !~ '^[A-Za-z]{2,3}$' THEN
    RAISE EXCEPTION 'Nationality is a 2- or 3-letter country code, e.g. AE or IND.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mgr IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = v_mgr) THEN
      RAISE EXCEPTION 'The manager (employee %) was not found in company %.', v_mgr, p_company USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_new THEN
      v_cur := v_mgr;
      WHILE v_cur IS NOT NULL AND v_n < 50 LOOP
        IF v_cur = e.emp_id THEN
          RAISE EXCEPTION 'An employee can''t report to themself or to someone who reports to them.' USING ERRCODE = 'P0001';
        END IF;
        SELECT manager_emp_id INTO v_cur FROM erp.employee WHERE company_code = p_company AND emp_id = v_cur;
        v_n := v_n + 1;
      END LOOP;
    END IF;
  END IF;
  IF p_emp ? 'branch_id' AND nullif(p_emp->>'branch_id', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM erp.branch WHERE company_code = p_company AND branch_id = (p_emp->>'branch_id')::integer) THEN
    RAISE EXCEPTION 'Branch % does not exist in company %.', p_emp->>'branch_id', p_company USING ERRCODE = 'P0001';
  END IF;

  IF v_new THEN
    nb := erp._series_take(p_company, 171, 'emp');
    IF nb IS NULL THEN
      RAISE EXCEPTION 'Employee numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).', p_company
        USING ERRCODE = 'P0001';
    END IF;
    v_code := nb->>'no';
    v_id := nextval('erp.erp_emp_seq');
    INSERT INTO erp.employee (company_code, emp_id, hr_code, first_name, middle_name, last_name, job_title, division, branch_id, manager_emp_id,
                              mobile, office_phone, email, gender, birth_date, nationality, passport_no, passport_expires, gov_id, joined_on,
                              left_on, status, sponsor, pay_currency, active, source)
    VALUES (p_company, v_id, v_code, v_first, nullif(btrim(p_emp->>'middle_name'), ''), v_last, nullif(btrim(p_emp->>'job_title'), ''),
            nullif(btrim(p_emp->>'division'), ''), (nullif(p_emp->>'branch_id', ''))::integer, v_mgr, nullif(btrim(p_emp->>'mobile'), ''),
            nullif(btrim(p_emp->>'office_phone'), ''), v_email, nullif(p_emp->>'gender', ''), v_birth, upper(nullif(p_emp->>'nationality', '')),
            nullif(btrim(p_emp->>'passport_no'), ''), erp._date(p_emp->>'passport_expires'), v_gov, v_join, v_left, v_status,
            nullif(btrim(p_emp->>'sponsor'), ''), (SELECT currency FROM erp.company WHERE company_code = p_company), v_status <> 'left', 'erp');
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'employee_create', 'employee', v_id::text, jsonb_build_object('hr_code', v_code, 'name', v_first || ' ' || v_last));
  ELSE
    v_id := e.emp_id;
    v_code := e.hr_code;
    UPDATE erp.employee SET
      first_name = v_first, last_name = v_last,
      middle_name = CASE WHEN p_emp ? 'middle_name' THEN nullif(btrim(p_emp->>'middle_name'), '') ELSE middle_name END,
      job_title = CASE WHEN p_emp ? 'job_title' THEN nullif(btrim(p_emp->>'job_title'), '') ELSE job_title END,
      division = CASE WHEN p_emp ? 'division' THEN nullif(btrim(p_emp->>'division'), '') ELSE division END,
      branch_id = CASE WHEN p_emp ? 'branch_id' THEN (nullif(p_emp->>'branch_id', ''))::integer ELSE branch_id END,
      manager_emp_id = v_mgr,
      mobile = CASE WHEN p_emp ? 'mobile' THEN nullif(btrim(p_emp->>'mobile'), '') ELSE mobile END,
      office_phone = CASE WHEN p_emp ? 'office_phone' THEN nullif(btrim(p_emp->>'office_phone'), '') ELSE office_phone END,
      email = v_email,
      gender = CASE WHEN p_emp ? 'gender' THEN nullif(p_emp->>'gender', '') ELSE gender END,
      birth_date = v_birth,
      nationality = CASE WHEN p_emp ? 'nationality' THEN upper(nullif(p_emp->>'nationality', '')) ELSE nationality END,
      passport_no = CASE WHEN p_emp ? 'passport_no' THEN nullif(btrim(p_emp->>'passport_no'), '') ELSE passport_no END,
      passport_expires = CASE WHEN p_emp ? 'passport_expires' THEN erp._date(p_emp->>'passport_expires') ELSE passport_expires END,
      gov_id = v_gov, joined_on = v_join, left_on = v_left, status = v_status, active = v_status <> 'left',
      sponsor = CASE WHEN p_emp ? 'sponsor' THEN nullif(btrim(p_emp->>'sponsor'), '') ELSE sponsor END
    WHERE company_code = p_company AND emp_id = v_id;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'employee_update', 'employee', v_id::text,
            jsonb_build_object('hr_code', v_code, 'fields', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_emp - 'emp_id' - 'extra') k)));
  END IF;
  IF jsonb_typeof(p_emp->'extra') = 'object' THEN
    PERFORM erp.hr_employee_extra_save(p_company, v_id, p_emp->'extra');
  END IF;
  RETURN jsonb_build_object('emp_id', v_id, 'hr_code', v_code);
END $$;

-- ============ 2. Payments posted at approval (copied from 20; numbered from the series kept on the draft) ============
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
  IF p_draft_id IS NOT NULL THEN
    PERFORM set_config('erp.series', coalesce((SELECT series_id::text FROM erp.payment_draft WHERE draft_id = p_draft_id), ''), true);
    PERFORM set_config('erp.series_user', coalesce(p_user::text, ''), true);
    PERFORM set_config('erp.series_date', coalesce(h->>'doc_date', ''), true);
  END IF;
  nb := erp._bk_number(p_company, v_obj);
  IF p_draft_id IS NOT NULL THEN
    PERFORM erp._series_clear();
  END IF;
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

-- ============ 3. A/R invoice executor (copied from 19 sales_invoice_create; internal, called after the checks or the last approval) ============
-- From open Super ERP delivery lines of one customer, and/or directly for service (non-stock) items. Posts A/R, revenue
-- and VAT through post_document and adds the total to the customer balance.
-- p_header: {card_code (needed for service-only invoices), doc_date, due_date?, customer_ref, comments}
-- p_lines:  [{base_doc_entry, base_line, qty}] (delivery lines) or [{item_code, qty, price?, discount_pct?, tax_code?}] (services)
CREATE OR REPLACE FUNCTION erp._sd_inv_exec(p_company varchar, p_header jsonb, p_lines jsonb, p_user uuid) RETURNS jsonb
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
  SELECT * INTO u FROM erp.app_user WHERE user_id = p_user;
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

-- ============ 3. A/R credit memo executor (copied from 19 sales_credit_memo_create; internal, called after the checks or the last approval) ============
-- Based on open Super ERP invoice lines. Reverses revenue and VAT; with return_stock the goods go back into stock at the
-- cost they left with (inventory up, COGS down). The customer balance goes down by the total.
-- p_header: {doc_date, return_stock (bool), whs_code (return warehouse, optional), customer_ref, comments}
-- p_lines:  [{base_doc_entry, base_line, qty}]
CREATE OR REPLACE FUNCTION erp._sd_cm_exec(p_company varchar, p_header jsonb, p_lines jsonb, p_user uuid) RETURNS jsonb
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
  SELECT * INTO u FROM erp.app_user WHERE user_id = p_user;
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

-- ============ 3. Copy to: expired quotations are refused (copied from 19) ============
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
    IF p_obj = 23 AND d.due_date < current_date THEN
      RAISE EXCEPTION '%', erp._sd_quote_expired_msg(v_no, d.due_date) USING ERRCODE = 'P0001';
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
         AND NOT (p_obj = 23 AND ld.due_date < current_date)
         AND (CASE WHEN p_doc_entry IS NOT NULL THEN l.doc_entry = p_doc_entry ELSE ld.card_code = p_card_code END)), '[]'::jsonb));
END $$;

-- ============ 3. Shipments always need a passed QC (copied from 21) ============
-- Record a shipment (container) for a purchase order, or change its header (p_shipment_id: container, mark, mode, ETD / ETA).
-- p_header: {po_doc_entry, container_no, shipping_mark, shipment_mode, etd, eta, note}; p_lines: [{po_line, qty}] (new only).
-- B1: always the order's last QC inspection must be a pass.
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
    IF true THEN   -- B1 decision: QC must pass before goods can ship (no longer a setting)
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

-- ============ 3. Purchasing setup: require_qc_pass stays on (copied from 21) ============
-- Purchasing › Purchasing Setup: default tax code and warehouse (Purchasing, full access). Shipping always needs a passed QC (B1).
-- p_setting: {default_tax_code, default_whs_code, require_qc_pass}
CREATE OR REPLACE FUNCTION erp.purchase_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  s     jsonb := coalesce(p_setting, '{}'::jsonb);
  v_tax text := nullif(btrim(s->>'default_tax_code'), '');
  v_whs text := nullif(btrim(s->>'default_whs_code'), '');
  v_qc  boolean := true;   -- B1 decision: QC must pass before shipping, always
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

-- ============ 3. Business partners: name-similarity duplicate warning removed (copied from 23) ============
-- ============ Business partners: evaluate (all checks, no writes) ============
-- Returns {errors:[{field, message}], duplicates:[{card_code, name, kind, match, similarity}], approvals:[{rule_code, step,
--          approver_position, approver_name, message}], values:{…normalised…}, contacts, addresses, is_new, old}.
-- Raises only for problems that stop the whole form: unknown partner, SAP partner.
CREATE OR REPLACE FUNCTION erp._bp_eval(p_company varchar, p_bp jsonb, p_user erp.app_user) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  b       jsonb := coalesce(p_bp, '{}'::jsonb);
  v_code  text := nullif(upper(btrim(b->>'card_code')), '');
  old     erp.business_partner;
  v_new   boolean := true;
  m       jsonb;
  co      erp.company;
  st      erp.master_setting;
  g       erp.bp_group;
  v_err   jsonb := '[]'::jsonb;
  v_dups  jsonb := '[]'::jsonb;
  v_appr  jsonb := '[]'::jsonb;
  v_kind  text; v_name text; v_fname text; v_group integer; v_cur text; v_country text; v_trn text; v_phone text; v_mobile text;
  v_email text; v_pt integer; v_pl integer; v_slp integer; v_credit numeric; v_active boolean; v_city text;
  v_contacts jsonb; v_addr jsonb; c jsonb; i integer; v_seen text[] := '{}'; v_def boolean := false; f text;
  v_rules jsonb; v_check_dups boolean; v_ta text[]; v_thr numeric; r record; v_raw text;
BEGIN
  SELECT * INTO co FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.master_setting WHERE company_code = p_company;
  v_thr := coalesce(st.dup_name_similarity, 0.8);
  IF v_code IS NOT NULL THEN
    SELECT * INTO old FROM erp.business_partner WHERE company_code = p_company AND card_code = v_code;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Business partner % does not exist in company %. Check the code.', v_code, p_company USING ERRCODE = 'P0001';
    END IF;
    IF old.source <> 'erp' THEN
      RAISE EXCEPTION '%', erp._md_sap_msg('partner', p_company) USING ERRCODE = 'P0001',
        HINT = 'SAP partners stay read-only in Super ERP during the soft switch.';
    END IF;
    v_new := false;
  END IF;
  m := CASE WHEN v_new THEN '{}'::jsonb ELSE to_jsonb(old) END
       || (b - 'card_code' - 'company_code' - 'contacts' - 'addresses' - 'source' - 'balance' - 'created_on');

  -- type
  v_kind := nullif(btrim(m->>'kind'), '');
  IF v_kind IS NULL OR v_kind NOT IN ('customer', 'supplier', 'lead') THEN
    v_err := v_err || jsonb_build_object('field', 'kind', 'message', 'Choose the partner type: customer, supplier or lead.');
  ELSIF NOT v_new AND v_kind <> old.kind AND NOT (old.kind = 'lead' AND v_kind = 'customer') THEN
    v_err := v_err || jsonb_build_object('field', 'kind', 'message', 'A partner''s type can only change from lead to customer.');
  END IF;
  -- names
  v_name := nullif(btrim(m->>'name'), '');
  IF v_name IS NULL THEN
    v_err := v_err || jsonb_build_object('field', 'name', 'message', 'Enter the partner name.');
  ELSIF length(v_name) > 100 THEN
    v_err := v_err || jsonb_build_object('field', 'name', 'message', 'The name is too long (100 characters at most).');
  END IF;
  v_fname := nullif(btrim(m->>'foreign_name'), '');
  -- group
  v_raw := nullif(btrim(m->>'group_code'), '');
  IF v_raw IS NOT NULL THEN
    v_group := erp._num(v_raw)::integer;
    SELECT * INTO g FROM erp.bp_group WHERE company_code = p_company AND group_code = v_group;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('field', 'group_code', 'message', format('Group %s does not exist in company %s.', v_raw, p_company));
    ELSIF g.kind IS NOT NULL AND v_kind IS NOT NULL AND g.kind <> (CASE WHEN v_kind = 'supplier' THEN 'S' ELSE 'C' END) THEN
      v_err := v_err || jsonb_build_object('field', 'group_code', 'message',
        format('Group %s is for %s. Choose a %s group.', g.name, CASE g.kind WHEN 'S' THEN 'suppliers' ELSE 'customers' END,
               CASE WHEN v_kind = 'supplier' THEN 'supplier' ELSE 'customer' END));
    END IF;
  END IF;
  -- country, currency
  v_country := nullif(upper(btrim(m->>'country')), '');
  IF v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$' THEN
    v_err := v_err || jsonb_build_object('field', 'country', 'message', 'Country must be a 2-letter code, e.g. AE.');
  END IF;
  v_cur := coalesce(nullif(upper(btrim(m->>'currency')), ''), CASE WHEN v_new THEN co.currency END);
  IF v_cur IS NOT NULL THEN
    IF v_cur !~ '^[A-Z]{3}$' THEN
      v_err := v_err || jsonb_build_object('field', 'currency', 'message', 'Currency must be a 3-letter code, e.g. AED or USD.');
    ELSIF v_cur <> co.currency AND NOT EXISTS (SELECT 1 FROM erp.fx_rate WHERE company_code = p_company AND currency = v_cur)
          AND NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND currency = v_cur) THEN
      v_err := v_err || jsonb_build_object('field', 'currency', 'message',
        format('Currency %s is not used in company %s. Ask Finance to add its exchange rate first.', v_cur, p_company));
    ELSIF NOT v_new AND v_cur IS DISTINCT FROM old.currency
          AND EXISTS (SELECT 1 FROM erp.document WHERE company_code = p_company AND card_code = old.card_code) THEN
      v_err := v_err || jsonb_build_object('field', 'currency', 'message',
        format('%s already has documents in %s. Its currency can''t change.', old.card_code, old.currency));
    END IF;
  END IF;
  -- TRN: 15 digits for UAE partners
  v_raw := nullif(btrim(m->>'trn'), '');
  IF v_raw IS NOT NULL THEN
    IF coalesce(v_country, '') = 'AE' THEN
      IF v_raw !~ '^[0-9 -]+$' OR length(erp._md_digits(v_raw)) <> 15 THEN
        v_err := v_err || jsonb_build_object('field', 'trn', 'message', 'The TRN must be 15 digits for a UAE partner, e.g. 100123456700003.');
      END IF;
      v_trn := erp._md_digits(v_raw);
    ELSE
      v_trn := upper(v_raw);
    END IF;
  END IF;
  -- phones, e-mail
  v_phone := nullif(btrim(m->>'phone'), '');
  v_mobile := nullif(btrim(m->>'mobile'), '');
  IF v_phone IS NOT NULL AND (v_phone !~ '^\+?[0-9 ()-]+$' OR length(erp._md_digits(v_phone)) < 7) THEN
    v_err := v_err || jsonb_build_object('field', 'phone', 'message', 'Enter the phone number with digits only, e.g. +971 4 123 4567.');
  END IF;
  IF v_mobile IS NOT NULL AND (v_mobile !~ '^\+?[0-9 ()-]+$' OR length(erp._md_digits(v_mobile)) < 7) THEN
    v_err := v_err || jsonb_build_object('field', 'mobile', 'message', 'Enter the mobile number with digits only, e.g. +971 50 123 4567.');
  END IF;
  v_email := nullif(lower(btrim(m->>'email')), '');
  IF v_email IS NOT NULL AND v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    v_err := v_err || jsonb_build_object('field', 'email', 'message', format('The e-mail address %s is not valid.', v_email));
  END IF;
  -- payment terms, price list, salesperson
  v_raw := nullif(btrim(m->>'payment_terms'), '');
  IF v_raw IS NOT NULL THEN
    v_pt := erp._num(v_raw)::integer;
    IF NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_pt) THEN
      v_err := v_err || jsonb_build_object('field', 'payment_terms', 'message', format('Payment terms %s do not exist in company %s.', v_raw, p_company));
    END IF;
  END IF;
  v_raw := nullif(btrim(m->>'price_list'), '');
  IF v_raw IS NOT NULL THEN
    v_pl := erp._num(v_raw)::integer;
    IF NOT EXISTS (SELECT 1 FROM erp.price_list WHERE company_code = p_company AND list_num = v_pl) THEN
      v_err := v_err || jsonb_build_object('field', 'price_list', 'message', format('Price list %s does not exist in company %s.', v_raw, p_company));
    END IF;
  END IF;
  v_raw := nullif(btrim(m->>'slp_code'), '');
  IF v_raw IS NOT NULL THEN
    v_slp := erp._num(v_raw)::integer;
    IF NOT EXISTS (SELECT 1 FROM erp.salesperson WHERE company_code = p_company AND slp_code = v_slp AND active) THEN
      v_err := v_err || jsonb_build_object('field', 'slp_code', 'message', format('Salesperson %s does not exist or is inactive.', v_raw));
    END IF;
  END IF;
  -- credit limit
  v_raw := nullif(btrim(m->>'credit_limit'), '');
  IF v_raw IS NOT NULL THEN
    v_credit := erp._num(v_raw);
    IF v_credit IS NULL THEN
      v_err := v_err || jsonb_build_object('field', 'credit_limit', 'message', 'Enter the credit limit as a number.');
    ELSIF v_credit < 0 THEN
      v_err := v_err || jsonb_build_object('field', 'credit_limit', 'message', 'The credit limit can''t be negative.');
    END IF;
    v_credit := round(v_credit, 2);
  END IF;
  v_active := coalesce((m->>'active')::boolean, true);
  v_city := nullif(btrim(m->>'city'), '');

  -- contacts
  v_contacts := CASE WHEN b ? 'contacts' THEN coalesce(b->'contacts', '[]'::jsonb)
                     WHEN v_new THEN '[]'::jsonb
                     ELSE (SELECT coalesce(jsonb_agg(jsonb_build_object('name', name, 'role', role, 'phone', phone, 'mobile', mobile, 'email', email,
                                                                        'is_default', is_default) ORDER BY contact_id), '[]'::jsonb)
                             FROM erp.bp_contact WHERE company_code = p_company AND card_code = v_code) END;
  IF jsonb_typeof(v_contacts) <> 'array' THEN v_contacts := '[]'::jsonb; END IF;
  FOR i IN 0 .. jsonb_array_length(v_contacts) - 1 LOOP
    c := v_contacts->i;
    IF nullif(btrim(c->>'name'), '') IS NULL THEN
      v_err := v_err || jsonb_build_object('field', 'contacts', 'line', i, 'message', format('Contact %s: enter the name.', i + 1));
    END IF;
    IF nullif(btrim(c->>'email'), '') IS NOT NULL AND lower(btrim(c->>'email')) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
      v_err := v_err || jsonb_build_object('field', 'contacts', 'line', i, 'message', format('Contact %s: the e-mail address %s is not valid.', i + 1, btrim(c->>'email')));
    END IF;
    IF (nullif(btrim(c->>'phone'), '') IS NOT NULL AND length(coalesce(erp._md_digits(c->>'phone'), '')) < 7)
       OR (nullif(btrim(c->>'mobile'), '') IS NOT NULL AND length(coalesce(erp._md_digits(c->>'mobile'), '')) < 7) THEN
      v_err := v_err || jsonb_build_object('field', 'contacts', 'line', i, 'message', format('Contact %s: enter the phone number with digits only.', i + 1));
    END IF;
    IF coalesce((c->>'is_default')::boolean, false) THEN
      IF v_def THEN
        v_err := v_err || jsonb_build_object('field', 'contacts', 'line', i, 'message', 'Only one contact can be the main contact.');
      END IF;
      v_def := true;
    END IF;
  END LOOP;
  -- addresses
  v_addr := CASE WHEN b ? 'addresses' THEN coalesce(b->'addresses', '[]'::jsonb)
                 WHEN v_new THEN '[]'::jsonb
                 ELSE (SELECT coalesce(jsonb_agg(to_jsonb(a) - 'company_code' - 'card_code' ORDER BY a.kind, a.address_name), '[]'::jsonb)
                         FROM erp.bp_address a WHERE a.company_code = p_company AND a.card_code = v_code) END;
  IF jsonb_typeof(v_addr) <> 'array' THEN v_addr := '[]'::jsonb; END IF;
  FOR i IN 0 .. jsonb_array_length(v_addr) - 1 LOOP
    c := v_addr->i;
    IF nullif(btrim(c->>'address_name'), '') IS NULL THEN
      v_err := v_err || jsonb_build_object('field', 'addresses', 'line', i, 'message', format('Address %s: enter the address name, e.g. Head office.', i + 1));
    ELSIF length(btrim(c->>'address_name')) > 50 THEN
      v_err := v_err || jsonb_build_object('field', 'addresses', 'line', i, 'message', format('Address %s: the name is too long (50 characters at most).', i + 1));
    END IF;
    IF coalesce(c->>'kind', '') NOT IN ('B', 'S') THEN
      v_err := v_err || jsonb_build_object('field', 'addresses', 'line', i, 'message', format('Address %s: choose bill-to or ship-to.', i + 1));
    ELSIF nullif(btrim(c->>'address_name'), '') IS NOT NULL THEN
      IF (c->>'kind') || '|' || lower(btrim(c->>'address_name')) = ANY (v_seen) THEN
        v_err := v_err || jsonb_build_object('field', 'addresses', 'line', i, 'message',
          format('Address %s: "%s" is already used for another %s address.', i + 1, btrim(c->>'address_name'), CASE c->>'kind' WHEN 'B' THEN 'bill-to' ELSE 'ship-to' END));
      END IF;
      v_seen := v_seen || ((c->>'kind') || '|' || lower(btrim(c->>'address_name')));
    END IF;
    IF nullif(btrim(c->>'country'), '') IS NOT NULL AND upper(btrim(c->>'country')) !~ '^[A-Z]{2,3}$' THEN
      v_err := v_err || jsonb_build_object('field', 'addresses', 'line', i, 'message', format('Address %s: country must be a 2-letter code, e.g. AE.', i + 1));
    END IF;
  END LOOP;

  -- fields this company made mandatory
  FOREACH f IN ARRAY coalesce(st.bp_required, '{}') LOOP
    IF (f = 'contacts' AND jsonb_array_length(v_contacts) = 0) OR (f = 'addresses' AND jsonb_array_length(v_addr) = 0)
       OR (f NOT IN ('contacts', 'addresses') AND nullif(btrim(coalesce(m->>f, CASE f WHEN 'currency' THEN v_cur END)), '') IS NULL) THEN
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_err) e WHERE e->>'field' = f) THEN
        v_err := v_err || jsonb_build_object('field', f, 'message', format('Enter the %s. It is mandatory in company %s.', erp._md_label(f), p_company));
      END IF;
    END IF;
  END LOOP;

  -- possible duplicates: same TRN or same phone / mobile (only when one of those is new or changed). B1: no name similarity.
  v_check_dups := v_new OR v_name IS DISTINCT FROM old.name OR v_trn IS DISTINCT FROM old.trn
                  OR v_phone IS DISTINCT FROM old.phone OR v_mobile IS DISTINCT FROM old.mobile;
  IF v_check_dups AND (v_trn IS NOT NULL OR v_phone IS NOT NULL OR v_mobile IS NOT NULL) THEN
    FOR r IN
      SELECT x.card_code, x.name, x.kind, x.match, x.sim FROM (
        SELECT p.card_code, p.name, p.kind,
               CASE WHEN v_trn IS NOT NULL AND erp._md_digits(p.trn) IS NOT NULL AND coalesce(erp._md_digits(p.trn), p.trn) = coalesce(erp._md_digits(v_trn), v_trn) THEN 'trn'
                    WHEN coalesce(length(erp._md_digits(p.phone)), 0) >= 7 AND erp._md_digits(p.phone) IN (erp._md_digits(v_phone), erp._md_digits(v_mobile)) THEN 'phone'
                    WHEN coalesce(length(erp._md_digits(p.mobile)), 0) >= 7 AND erp._md_digits(p.mobile) IN (erp._md_digits(v_phone), erp._md_digits(v_mobile)) THEN 'phone'
                    END AS match,
               NULL::numeric AS sim
          FROM erp.business_partner p
         WHERE p.company_code = p_company AND p.card_code IS DISTINCT FROM v_code) x
       WHERE x.match IS NOT NULL
       ORDER BY CASE x.match WHEN 'trn' THEN 1 ELSE 2 END, x.card_code
       LIMIT 10
    LOOP
      v_dups := v_dups || jsonb_build_object('card_code', r.card_code, 'name', r.name, 'kind', r.kind, 'match', r.match, 'similarity', r.sim);
    END LOOP;
  END IF;

  -- credit limit approval
  IF (v_new AND coalesce(v_credit, 0) > 0) OR (NOT v_new AND v_credit IS DISTINCT FROM old.credit_limit) THEN
    IF NOT v_new AND EXISTS (SELECT 1 FROM erp.bp_change_request WHERE company_code = p_company AND card_code = v_code AND kind = 'credit_limit'
                                                                  AND state = 'pending_approval') THEN
      v_err := v_err || jsonb_build_object('field', 'credit_limit', 'message',
        format('A credit limit change for %s is already waiting for approval. Wait for the decision or cancel it.', v_code));
    ELSE
      v_rules := erp._md_rules(p_company, 'bp_credit_limit', p_user.position_code);
      IF jsonb_array_length(v_rules) > 0 THEN
        SELECT jsonb_agg(x || jsonb_build_object('message',
                 format('Credit limit %s %s (was %s) needs approval from %s.',
                        CASE WHEN v_credit IS NULL THEN 'none' ELSE erp._money(v_credit) END, coalesce(v_cur, ''),
                        CASE WHEN v_new OR old.credit_limit IS NULL THEN 'none' ELSE erp._money(old.credit_limit) END,
                        (SELECT string_agg(y->>'approver_name', ' then ' ORDER BY (y->>'step')::int) FROM jsonb_array_elements(v_rules) y))))
          INTO v_appr FROM jsonb_array_elements(v_rules) x;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'is_new', v_new, 'errors', v_err, 'duplicates', v_dups, 'approvals', coalesce(v_appr, '[]'::jsonb),
    'old', CASE WHEN v_new THEN NULL ELSE to_jsonb(old) END,
    'contacts', v_contacts, 'addresses', v_addr,
    'values', jsonb_build_object('card_code', v_code, 'kind', v_kind, 'name', v_name, 'foreign_name', v_fname, 'group_code', v_group,
                                 'currency', v_cur, 'trn', v_trn, 'phone', v_phone, 'mobile', v_mobile, 'email', v_email,
                                 'payment_terms', v_pt, 'price_list', v_pl, 'slp_code', v_slp, 'credit_limit', v_credit,
                                 'city', v_city, 'country', v_country, 'region', nullif(btrim(m->>'region'), ''),
                                 'bp_category', nullif(btrim(m->>'bp_category'), ''), 'active', v_active));
END $$;

-- ============ 3. Landed costs: the share on goods already sold posts to the price difference account (copied from 21) ============
-- Post landed costs: the split as previewed, average cost raised, Dr inventory (+ Dr price difference for goods already sold, B1) /
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
    v_cogs := erp.gl_account(p_company, 'inventory', 'price_difference');
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
    v_lines := v_lines || jsonb_build_object('acct_code', v_cogs, 'debit', v_tc, 'memo', 'Landed costs on goods already sold (price difference)');
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

-- ============ 3. Service setup: who may issue spare parts (copied from 28) ============
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
    'setting', jsonb_build_object('parts_reason_code', s.parts_reason_code, 'note', s.note, 'manager_position', s.manager_position,
                                  'parts_positions', coalesce(to_jsonb(s.parts_positions), '[]'::jsonb), 'parts_users', coalesce(to_jsonb(s.parts_users), '[]'::jsonb)),
    'positions', coalesce((SELECT jsonb_agg(jsonb_build_object('position_code', p.position_code, 'name', p.name) ORDER BY p.name) FROM erp.position p), '[]'::jsonb),
    'users', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', a.user_id, 'name', a.display_name, 'position_code', a.position_code) ORDER BY a.display_name)
                         FROM erp.app_user a WHERE a.active AND EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = a.user_id AND uc.company_code = p_company)), '[]'::jsonb),
    'can_issue_parts', erp._svc_parts_ok(p_company, u) IS NULL,
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

-- ============ 3. Service settings: spare-parts issuers (copied from 28) ============
-- p_setting: {parts_reason_code, note, manager_position, parts_positions[], parts_users[]}. Keys left out keep their value.
-- The reason's account is Finance's (Inventory Setup).
CREATE OR REPLACE FUNCTION erp.service_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  old erp.service_setting;
  v_r text;
  rs  erp.inventory_reason;
  v_mgr text;
  v_pos text[];
  v_usr uuid[];
  x   text;
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
  v_mgr := CASE WHEN p_setting ? 'manager_position' THEN nullif(btrim(p_setting->>'manager_position'), '') ELSE old.manager_position END;
  IF v_mgr IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_mgr) THEN
    RAISE EXCEPTION 'Position % does not exist. Choose the service manager position from the list.', v_mgr USING ERRCODE = 'P0001';
  END IF;
  IF p_setting ? 'parts_positions' THEN
    IF jsonb_typeof(p_setting->'parts_positions') NOT IN ('array', 'null') THEN
      RAISE EXCEPTION 'Send the positions that may issue spare parts as a list.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT btrim(v)) INTO v_pos FROM jsonb_array_elements_text(coalesce(nullif(p_setting->'parts_positions', 'null'::jsonb), '[]'::jsonb)) v
     WHERE btrim(v) <> '';
    FOREACH x IN ARRAY coalesce(v_pos, '{}') LOOP
      IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = x) THEN
        RAISE EXCEPTION 'Position % does not exist. Choose positions from the list.', x USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
  ELSE
    v_pos := old.parts_positions;
  END IF;
  IF p_setting ? 'parts_users' THEN
    IF jsonb_typeof(p_setting->'parts_users') NOT IN ('array', 'null') THEN
      RAISE EXCEPTION 'Send the users who may issue spare parts as a list.' USING ERRCODE = 'P0001';
    END IF;
    FOR x IN SELECT btrim(v) FROM jsonb_array_elements_text(coalesce(nullif(p_setting->'parts_users', 'null'::jsonb), '[]'::jsonb)) v WHERE btrim(v) <> '' LOOP
      IF x !~ '^[0-9a-fA-F-]{36}$' OR NOT EXISTS (SELECT 1 FROM erp.user_company WHERE user_id = x::uuid AND company_code = p_company) THEN
        RAISE EXCEPTION 'User % has no access to company %. Choose users from the list.', x, p_company USING ERRCODE = 'P0001';
      END IF;
      v_usr := array_append(v_usr, x::uuid);
    END LOOP;
  ELSE
    v_usr := old.parts_users;
  END IF;
  INSERT INTO erp.service_setting (company_code, parts_reason_code, note, manager_position, parts_positions, parts_users, updated_by, updated_at)
  VALUES (p_company, v_r, CASE WHEN p_setting ? 'note' THEN nullif(btrim(p_setting->>'note'), '') ELSE old.note END, v_mgr, v_pos, v_usr, u.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET parts_reason_code = EXCLUDED.parts_reason_code, note = EXCLUDED.note, manager_position = EXCLUDED.manager_position,
           parts_positions = EXCLUDED.parts_positions, parts_users = EXCLUDED.parts_users, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'service_setting_set', 'service_setting', p_company, jsonb_build_object('before', old.parts_reason_code, 'parts_reason_code', v_r,
          'before_issuers', jsonb_build_object('manager_position', old.manager_position, 'positions', old.parts_positions, 'users', old.parts_users),
          'issuers', jsonb_build_object('manager_position', v_mgr, 'positions', v_pos, 'users', v_usr)));
  RETURN jsonb_build_object('parts_reason_code', v_r, 'manager_position', v_mgr, 'parts_positions', to_jsonb(v_pos), 'parts_users', to_jsonb(v_usr));
END $$;

-- ============ 3. Spare parts: only the positions / users allowed in Service Setup (copied from 28) ============
-- Spare parts for a call: an A7 goods issue (inventory_doc_create: needs Service full, Inventory full and, since B1, a position or
-- user allowed in Service Setup; the requester's goods
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
  -- Module rights first (the goods issue names a missing Inventory right), then who may issue spare parts (B1, Service Setup).
  IF erp.can_write('inventory') THEN
    v_r := erp._svc_parts_ok(p_company, u);
    IF v_r IS NOT NULL THEN
      RAISE EXCEPTION '%', v_r USING ERRCODE = 'P0001';
    END IF;
  END IF;
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

-- ============ 3. Moulds: defaults for new moulds and a warning % per mould (copied from 28) ============
-- p_res: {res_code, name, kind, unit, unit_cost, acct_code, cavities, rated_life_shots, shots_done (new only), location, asset_no,
--         maint_every_shots, maint_every_days, last_maint_on, warn_pct, active, note, edit: true to change an existing one}.
-- B1: a new mould left without them gets maintenance every 50,000 shots, a rated life of 500,000 shots and a warning at 80 %.
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
  v_warn numeric;
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
  IF nullif(btrim(p_res->>'warn_pct'), '') IS NOT NULL THEN
    v_warn := erp._num(p_res->>'warn_pct');
    IF v_warn IS NULL OR v_warn <= 0 OR v_warn > 100 THEN
      RAISE EXCEPTION 'Warn at must be a percentage above 0 and up to 100.' USING ERRCODE = 'P0001';
    END IF;
  ELSIF old.res_code IS NULL AND v_kind = 'mould' THEN
    v_warn := 80;
  END IF;
  IF old.res_code IS NULL THEN
    INSERT INTO erp.prod_resource (company_code, res_code, name, kind, unit, unit_cost, acct_code, cavities, rated_life_shots, shots_done, location, asset_no,
                                   maint_every_shots, maint_every_days, last_maint_on, last_maint_shots, active, note, updated_by, warn_pct)
    VALUES (p_company, v_code, v_name, v_kind, v_unit, v_cost, v_acct, erp._num(p_res->>'cavities')::integer, coalesce(erp._num(p_res->>'rated_life_shots')::bigint, CASE WHEN v_kind = 'mould' THEN 500000 END),
            coalesce(erp._num(p_res->>'shots_done')::bigint, 0), nullif(btrim(p_res->>'location'), ''), nullif(btrim(p_res->>'asset_no'), ''),
            coalesce(erp._num(p_res->>'maint_every_shots')::bigint, CASE WHEN v_kind = 'mould' THEN 50000 END), erp._num(p_res->>'maint_every_days')::integer, erp._date(p_res->>'last_maint_on'),
            coalesce(erp._num(p_res->>'shots_done')::bigint, 0), coalesce((p_res->>'active')::boolean, true), nullif(btrim(p_res->>'note'), ''), u.user_id, v_warn);
  ELSE
    -- Shots done only change through receipts from production (the counter is the mould's history).
    UPDATE erp.prod_resource SET name = v_name, kind = v_kind, unit = v_unit, unit_cost = v_cost, acct_code = v_acct,
           cavities = erp._num(p_res->>'cavities')::integer, rated_life_shots = erp._num(p_res->>'rated_life_shots')::bigint,
           location = nullif(btrim(p_res->>'location'), ''), asset_no = nullif(btrim(p_res->>'asset_no'), ''),
           maint_every_shots = erp._num(p_res->>'maint_every_shots')::bigint, maint_every_days = erp._num(p_res->>'maint_every_days')::integer,
           warn_pct = CASE WHEN p_res ? 'warn_pct' THEN v_warn ELSE warn_pct END,
           active = coalesce((p_res->>'active')::boolean, active), note = nullif(btrim(p_res->>'note'), ''), updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND res_code = v_code;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN old.res_code IS NULL THEN 'prod_resource_create' ELSE 'prod_resource_update' END, 'prod_resource', v_code,
          jsonb_build_object('before', CASE WHEN old.res_code IS NOT NULL THEN to_jsonb(old) - 'updated_by' - 'updated_at' END, 'input', p_res - 'edit'));
  RETURN jsonb_build_object('res_code', v_code);
END $$;

-- ============ 3. Credit memos and direct service invoices: approval through templates ============
-- Does any approval rule apply to this credit memo / invoice for the requester's position? (cheap test before the full check)
CREATE OR REPLACE FUNCTION erp._sd_req_rules_apply(p_company varchar, p_obj integer, p_lines jsonb, p_position text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj
    WHEN 14 THEN EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.company_code = p_company AND ar.obj_type = 14 AND ar.rule_code = 'credit_memo_amount'
                                                             AND ar.active AND (ar.position_code = p_position OR ar.position_code IS NULL))
    WHEN 13 THEN EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.company_code = p_company AND ar.obj_type = 17 AND ar.rule_code = 'discount_pct'
                                                             AND ar.active AND ar.position_code = p_position)
             AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) l
                          WHERE nullif(l->>'base_doc_entry', '') IS NULL AND coalesce(erp._num(nullif(btrim(l->>'discount_pct'), '')), 0) > 0)
    ELSE false END
$$;

-- The approvals a valid credit memo (total = p_total) or direct service invoice needs. Same shape as A2's checks.
--   credit memo: template credit_memo_amount (obj 14) – the total above the limit (no limit = always)
--   invoice:     the sales-order discount template discount_pct (obj 17) on each service line (lines without a base)
CREATE OR REPLACE FUNCTION erp._sd_req_checks(p_company varchar, p_obj integer, p_lines jsonb, p_position text, p_total numeric) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r      record;
  x      record;
  v_out  jsonb := '[]'::jsonb;
  v_cur  text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_nbase integer;
BEGIN
  IF p_obj = 14 THEN
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 14 AND ar.rule_code = 'credit_memo_amount' AND ar.active
                AND (ar.position_code = p_position OR ar.position_code IS NULL)
              ORDER BY ar.step, ar.rule_id LOOP
      IF r.limit_value IS NULL OR p_total > r.limit_value THEN
        v_out := v_out || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
          'approver_name', r.approver_name, 'line', NULL, 'value', p_total, 'limit', r.limit_value,
          'message', CASE WHEN r.limit_value IS NULL THEN format('Every credit memo needs approval from %s.', r.approver_name)
                          ELSE format('Credit memo total %s %s is above the limit of %s %s. It needs approval from %s.',
                                      erp._money(p_total), v_cur, erp._money(r.limit_value), v_cur, r.approver_name) END);
      END IF;
    END LOOP;
  ELSIF p_obj = 13 THEN
    SELECT count(*) INTO v_nbase FROM jsonb_array_elements(v_lines) l WHERE nullif(l->>'base_doc_entry', '') IS NOT NULL;
    FOR r IN SELECT ar.*, p.name AS approver_name FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
              WHERE ar.company_code = p_company AND ar.obj_type = 17 AND ar.rule_code = 'discount_pct' AND ar.active AND ar.position_code = p_position
              ORDER BY ar.step, ar.rule_id LOOP
      FOR x IN SELECT v_nbase + row_number() OVER () AS n, coalesce(erp._num(nullif(btrim(l->>'discount_pct'), '')), 0) AS d
                 FROM jsonb_array_elements(v_lines) l WHERE nullif(l->>'base_doc_entry', '') IS NULL LOOP
        IF x.d > r.limit_value THEN
          v_out := v_out || jsonb_build_object('rule_code', r.rule_code, 'step', r.step, 'approver_position', r.approver_position,
            'approver_name', r.approver_name, 'line', x.n, 'value', x.d, 'limit', r.limit_value,
            'message', format('Line %s: Discount %s%% is above your limit of %s%%. Submit it for approval or lower the discount.',
                              x.n, erp._pct(x.d), erp._pct(r.limit_value)));
        END IF;
      END LOOP;
    END LOOP;
  END IF;
  RETURN v_out;
END $$;

-- Run the executor and roll it back: the document must be valid before it goes for approval. Returns the executor's result.
CREATE OR REPLACE FUNCTION erp._sd_req_dry_run(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r jsonb;
BEGIN
  BEGIN
    r := CASE p_obj WHEN 13 THEN erp._sd_inv_exec(p_company, p_header, p_lines, p_user) ELSE erp._sd_cm_exec(p_company, p_header, p_lines, p_user) END;
    RAISE EXCEPTION USING ERRCODE = 'B1D01', MESSAGE = r::text;
  EXCEPTION WHEN SQLSTATE 'B1D01' THEN
    r := SQLERRM::jsonb;
  END;
  RETURN r;
END $$;

-- Open a request with its approval steps (one row per step and approver position, as A2).
CREATE OR REPLACE FUNCTION erp._sd_req_open(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_checks jsonb, p_total numeric, u erp.app_user)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h      jsonb := coalesce(p_header, '{}'::jsonb);
  v_card text := nullif(btrim(h->>'card_code'), '');
  v_first integer;
  v_id   bigint;
  x      record;
BEGIN
  IF v_card IS NULL THEN
    SELECT erp._num(l->>'base_doc_entry')::integer INTO v_first FROM jsonb_array_elements(p_lines) l WHERE nullif(l->>'base_doc_entry', '') IS NOT NULL LIMIT 1;
    SELECT card_code INTO v_card FROM erp.document WHERE company_code = p_company AND obj_type = CASE p_obj WHEN 14 THEN 13 ELSE 15 END AND doc_entry = v_first;
  END IF;
  INSERT INTO erp.sales_doc_request (company_code, obj_type, card_code, card_name, total, currency, header, lines, checks, series_id, reason, requested_by)
  VALUES (p_company, p_obj, v_card, (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card), p_total,
          (SELECT currency FROM erp.company WHERE company_code = p_company), h - 'approval_reason', p_lines, p_checks,
          nullif(current_setting('erp.series', true), '')::bigint, nullif(btrim(h->>'approval_reason'), ''), u.user_id)
  RETURNING request_id INTO v_id;
  FOR x IN SELECT (c->>'step')::smallint AS step, c->>'approver_position' AS pos, min(c->>'rule_code') AS rule_code, jsonb_agg(c) AS checks
             FROM jsonb_array_elements(p_checks) c GROUP BY 1, 2 ORDER BY 1, 2 LOOP
    INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
    VALUES (p_company, 'sales_doc_request', v_id::text, x.step, x.pos, x.rule_code, u.user_id, now(), jsonb_build_object('checks', x.checks, 'obj_type', p_obj));
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'sales_doc_request_submit', 'sales_doc_request', v_id::text,
          jsonb_build_object('obj_type', p_obj, 'card_code', v_card, 'total', p_total, 'checks', p_checks));
  RETURN jsonb_build_object('state', 'pending_approval', 'request_id', v_id, 'doc_no', 'REQ-' || v_id, 'obj_type', p_obj, 'checks', p_checks, 'total', p_total);
END $$;

-- ============ API: A/R invoice (13), replaced ============
-- As A4 (delivery lines and/or service lines), plus B1: service lines whose discount is above the requester's sales-order
-- discount limit (template discount_pct) go for approval as a request; the last approval creates the invoice.
-- p_header: {card_code, doc_date, due_date?, customer_ref, comments, approval_reason?}
-- Returns the invoice, or {state: 'pending_approval', request_id, checks, total}.
CREATE OR REPLACE FUNCTION erp.sales_invoice_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  r   jsonb;
  chk jsonb;
BEGIN
  u := erp._sd_guard(p_company, true, 13);
  IF NOT erp._sd_req_rules_apply(p_company, 13, p_lines, u.position_code) THEN
    RETURN erp._sd_inv_exec(p_company, p_header - 'approval_reason', p_lines, u.user_id);
  END IF;
  r := erp._sd_req_dry_run(p_company, 13, p_header - 'approval_reason', p_lines, u.user_id);
  chk := erp._sd_req_checks(p_company, 13, p_lines, u.position_code, (r->>'total')::numeric);
  IF jsonb_array_length(chk) = 0 THEN
    RETURN erp._sd_inv_exec(p_company, p_header - 'approval_reason', p_lines, u.user_id);
  END IF;
  RETURN erp._sd_req_open(p_company, 13, p_header, p_lines, chk, (r->>'total')::numeric, u);
END $$;

-- ============ API: A/R credit memo (14), replaced ============
-- As A4, plus B1: when an approval template credit_memo_amount covers the requester and the total is above its limit, the
-- credit memo goes for approval as a request; the last approval creates it.
CREATE OR REPLACE FUNCTION erp.sales_credit_memo_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  r   jsonb;
  chk jsonb;
BEGIN
  u := erp._sd_guard(p_company, true, 14);
  IF NOT erp._sd_req_rules_apply(p_company, 14, p_lines, u.position_code) THEN
    RETURN erp._sd_cm_exec(p_company, p_header - 'approval_reason', p_lines, u.user_id);
  END IF;
  r := erp._sd_req_dry_run(p_company, 14, p_header - 'approval_reason', p_lines, u.user_id);
  chk := erp._sd_req_checks(p_company, 14, p_lines, u.position_code, (r->>'total')::numeric);
  IF jsonb_array_length(chk) = 0 THEN
    RETURN erp._sd_cm_exec(p_company, p_header - 'approval_reason', p_lines, u.user_id);
  END IF;
  RETURN erp._sd_req_open(p_company, 14, p_header, p_lines, chk, (r->>'total')::numeric, u);
END $$;

-- Read guard for requests: Sales or Financials, on a company the user can see.
CREATE OR REPLACE FUNCTION erp._sd_req_guard(p_company varchar) RETURNS erp.app_user
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
  IF NOT (erp.can_read('sales') OR erp.can_read('finance')) THEN
    RAISE EXCEPTION 'Your position does not include Sales. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Approve or reject the current step. The last approval creates the document (as its requester, from the series picked).
CREATE OR REPLACE FUNCTION erp.sales_doc_request_decide(p_company varchar, p_request_id bigint, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user := erp._sd_req_guard(p_company);
  q       erp.sales_doc_request;
  v_note  text := nullif(btrim(p_note), '');
  v_step  smallint;
  v_mine  bigint[];
  v_who   text;
  v_left  integer;
  v_state text;
  r       jsonb;
BEGIN
  SELECT * INTO q FROM erp.sales_doc_request WHERE company_code = p_company AND request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request % was not found in company %.', coalesce(p_request_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF q.requested_by = u.user_id THEN
    IF p_decision = 'approved' THEN
      RAISE EXCEPTION 'You can''t approve your own request.' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'You can''t reject your own request. Cancel it instead if it is no longer needed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded
     AND step = v_step AND approver_position = u.position_code;
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT ps.name, ' or ') INTO v_who FROM erp.approval a JOIN erp.position ps ON ps.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = 'sales_doc_request' AND a.object_ref = p_request_id::text AND a.decision IS NULL
       AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This request is waiting for approval from %. Your position can''t decide it.', coalesce(v_who, 'another position') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this request.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE erp.approval SET decision = p_decision, approver_user = u.user_id, decided_at = now(), note = v_note WHERE approval_id = ANY (v_mine);
  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true
     WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.sales_doc_request SET state = 'rejected', decided_at = now(), note = v_note WHERE request_id = p_request_id;
    v_state := 'rejected';
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval
     WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      PERFORM set_config('erp.series', coalesce(q.series_id::text, ''), true);
      PERFORM set_config('erp.series_user', q.requested_by::text, true);
      PERFORM set_config('erp.series_date', coalesce(q.header->>'doc_date', ''), true);
      r := CASE q.obj_type WHEN 13 THEN erp._sd_inv_exec(p_company, q.header, q.lines, q.requested_by)
                           ELSE erp._sd_cm_exec(p_company, q.header, q.lines, q.requested_by) END;
      PERFORM erp._series_clear();
      UPDATE erp.sales_doc_request SET state = 'approved', decided_at = now(), doc_entry = (r->>'doc_entry')::integer, doc_no = r->>'doc_no'
       WHERE request_id = p_request_id;
      v_state := 'approved';
    ELSE
      v_state := 'pending_approval';
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'approved' THEN 'sales_doc_request_approve' ELSE 'sales_doc_request_reject' END,
          'sales_doc_request', p_request_id::text, jsonb_build_object('step', v_step, 'approvals', to_jsonb(v_mine), 'note', v_note, 'state', v_state,
                                                                      'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no', 'trans_id', r->'trans_id'));
  RETURN jsonb_build_object('request_id', p_request_id, 'state', v_state, 'obj_type', q.obj_type, 'doc_entry', r->'doc_entry', 'doc_no', r->'doc_no',
                            'trans_id', r->'trans_id');
END $$;

-- The requester cancels a waiting or rejected request.
CREATE OR REPLACE FUNCTION erp.sales_doc_request_cancel(p_company varchar, p_request_id bigint, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._sd_req_guard(p_company);
  q erp.sales_doc_request;
BEGIN
  SELECT * INTO q FROM erp.sales_doc_request WHERE company_code = p_company AND request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request % was not found in company %.', coalesce(p_request_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.requested_by <> u.user_id THEN
    RAISE EXCEPTION 'Only the person who sent this request can cancel it.' USING ERRCODE = 'P0001';
  END IF;
  IF q.state NOT IN ('pending_approval', 'rejected') THEN
    RAISE EXCEPTION 'This request is % and can''t be cancelled.', replace(q.state, '_', ' ') USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
  UPDATE erp.sales_doc_request SET state = 'cancelled', decided_at = now(), note = coalesce(nullif(btrim(p_note), ''), note) WHERE request_id = p_request_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'sales_doc_request_cancel', 'sales_doc_request', p_request_id::text, jsonb_build_object('note', nullif(btrim(p_note), '')));
  RETURN jsonb_build_object('request_id', p_request_id, 'state', 'cancelled');
END $$;

-- Request page: what was asked, why it needs approval, the steps and who may decide now.
CREATE OR REPLACE FUNCTION erp.sales_doc_request_info(p_company varchar, p_request_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user := erp._sd_req_guard(p_company);
  q      erp.sales_doc_request;
  v_step smallint;
BEGIN
  SELECT * INTO q FROM erp.sales_doc_request WHERE company_code = p_company AND request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request % was not found in company %.', coalesce(p_request_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval
   WHERE company_code = p_company AND object = 'sales_doc_request' AND object_ref = p_request_id::text AND decision IS NULL AND NOT superseded;
  RETURN jsonb_build_object(
    'request', to_jsonb(q) - 'series_id' || jsonb_build_object('doc_no_req', 'REQ-' || q.request_id,
                 'requested_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = q.requested_by),
                 'series', (SELECT name FROM erp.number_series WHERE series_id = q.series_id)),
    'approvals', coalesce((SELECT jsonb_agg(jsonb_build_object('step', a.step, 'approver_position', a.approver_position, 'approver_name', p.name,
                             'decision', a.decision, 'decided_at', a.decided_at, 'decided_by_name', du.display_name, 'note', a.note, 'superseded', a.superseded,
                             'rule_code', a.rule_code) ORDER BY a.step, a.approval_id)
                             FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
                             LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
                            WHERE a.company_code = p_company AND a.object = 'sales_doc_request' AND a.object_ref = p_request_id::text), '[]'::jsonb),
    'is_requester', q.requested_by = u.user_id,
    'can_decide', q.state = 'pending_approval' AND q.requested_by <> u.user_id
                  AND EXISTS (SELECT 1 FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'sales_doc_request'
                                 AND a.object_ref = p_request_id::text AND a.decision IS NULL AND NOT a.superseded AND a.step = v_step
                                 AND a.approver_position = u.position_code));
END $$;

-- ============ 1. Companies: list and create / change (Administration › Choose/Create Company) ============
CREATE OR REPLACE FUNCTION erp._company_in_register(p_company varchar) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v boolean := false;
BEGIN
  IF to_regclass('sap._company') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM sap._company WHERE company_code = $1)' INTO v USING p_company;
  END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION erp.company_list() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'companies', coalesce((SELECT jsonb_agg(jsonb_build_object(
                   'company_code', c.company_code, 'legal_name', c.legal_name, 'short_name', c.short_name, 'country', c.country, 'currency', c.currency,
                   'licence_type', c.licence_type, 'licence_authority', c.licence_authority, 'tax_id', c.tax_id, 'sap_schema', c.sap_schema,
                   'active', c.active, 'in_register', erp._company_in_register(c.company_code),
                   'live', EXISTS (SELECT 1 FROM erp.company_cutover k WHERE k.company_code = c.company_code),
                   'users', (SELECT count(*) FROM erp.user_company uc JOIN erp.app_user a ON a.user_id = uc.user_id AND a.active WHERE uc.company_code = c.company_code),
                   'series', (SELECT count(*) FROM erp.number_series n WHERE n.company_code = c.company_code),
                   'has_documents', EXISTS (SELECT 1 FROM erp.document d WHERE d.company_code = c.company_code)
                                    OR EXISTS (SELECT 1 FROM erp.journal_entry j WHERE j.company_code = c.company_code))
                   ORDER BY c.company_code)
                   FROM erp.company c WHERE erp.can_see(c.company_code)), '[]'::jsonb));
END $$;

-- p: {company_code, legal_name, short_name, country, currency, licence_type, licence_authority, tax_id, sap_schema, active,
--     edit: true to change an existing company}. Administration full. A new company is added to the migration register
-- (sap._company, where it exists) and the creator gets access to it. Print details (logo, address …) stay in Company Details.
CREATE OR REPLACE FUNCTION erp.company_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  b      jsonb := coalesce(p, '{}'::jsonb);
  v_edit boolean := coalesce((b->>'edit')::boolean, false);
  v_code text := upper(btrim(coalesce(b->>'company_code', '')));
  old    erp.company;
  n      erp.company;
  v_legal text := btrim(coalesce(b->>'legal_name', ''));
  v_short text;
  v_cty  text := upper(btrim(coalesce(b->>'country', 'AE')));
  v_cur  text := upper(btrim(coalesce(b->>'currency', 'AED')));
  v_lic  text := nullif(btrim(b->>'licence_type'), '');
  v_tax  text := nullif(regexp_replace(coalesce(b->>'tax_id', ''), '\s', '', 'g'), '');
  v_sch  text := nullif(btrim(b->>'sap_schema'), '');
  v_reg  boolean := false;
BEGIN
  IF v_code !~ '^[A-Z0-9]{2,8}$' THEN
    RAISE EXCEPTION 'Use 2 to 8 capital letters or digits for the company code, e.g. AE06.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.company WHERE company_code = v_code FOR UPDATE;
  IF v_edit THEN
    old := erp._adm_company(v_code);
  ELSIF FOUND THEN
    RAISE EXCEPTION 'Company % already exists. Open it to change it.', v_code USING ERRCODE = 'P0001';
  END IF;
  IF length(v_legal) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Enter the legal name (up to 200 characters).' USING ERRCODE = 'P0001';
  END IF;
  v_short := coalesce(nullif(btrim(b->>'short_name'), ''), left(v_legal, 60));
  IF length(v_short) > 60 THEN
    RAISE EXCEPTION 'Keep the short name to 60 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF v_cty !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'Use the two-letter country code, e.g. AE.' USING ERRCODE = 'P0001';
  END IF;
  IF v_cur !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Use the three-letter currency code, e.g. AED.' USING ERRCODE = 'P0001';
  END IF;
  IF v_lic IS NOT NULL AND v_lic NOT IN ('free_zone', 'mainland', 'foreign') THEN
    RAISE EXCEPTION 'Choose the licence type: free zone, mainland or foreign (or leave it empty until it is confirmed).' USING ERRCODE = 'P0001';
  END IF;
  IF v_tax IS NOT NULL AND v_cty = 'AE' AND v_tax !~ '^\d{15}$' THEN
    RAISE EXCEPTION 'A UAE TRN has 15 digits. Check the number on the VAT certificate.' USING ERRCODE = 'P0001';
  END IF;
  IF v_sch IS NOT NULL AND v_sch !~ '^[A-Za-z0-9_]{1,63}$' THEN
    RAISE EXCEPTION 'Use letters, digits or _ in the SAP schema name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_edit AND v_cur <> old.currency
     AND (EXISTS (SELECT 1 FROM erp.document WHERE company_code = v_code) OR EXISTS (SELECT 1 FROM erp.journal_entry WHERE company_code = v_code)
          OR EXISTS (SELECT 1 FROM erp.payment WHERE company_code = v_code)) THEN
    RAISE EXCEPTION 'The currency of % can''t change: it already has documents or journal entries.', v_code USING ERRCODE = 'P0001';
  END IF;

  IF v_edit THEN
    UPDATE erp.company SET legal_name = v_legal, short_name = v_short, country = v_cty, currency = v_cur, licence_type = v_lic,
           licence_authority = nullif(btrim(b->>'licence_authority'), ''), tax_id = v_tax, sap_schema = v_sch,
           active = coalesce((b->>'active')::boolean, active)
     WHERE company_code = v_code RETURNING * INTO n;
  ELSE
    INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, licence_authority, tax_id, sap_schema, is_parent, active)
    VALUES (v_code, v_legal, v_short, v_cty, v_cur, v_lic, nullif(btrim(b->>'licence_authority'), ''), v_tax, v_sch, false,
            coalesce((b->>'active')::boolean, true))
    RETURNING * INTO n;
    INSERT INTO erp.user_company (user_id, company_code) VALUES (me.user_id, v_code) ON CONFLICT DO NOTHING;
  END IF;
  -- The migration register follows the basics (it is where the SAP backup is uploaded later).
  IF to_regclass('sap._company') IS NOT NULL THEN
    BEGIN
      EXECUTE 'INSERT INTO sap._company (company_code, legal_name, country, currency, licence_type, sap_schema) VALUES ($1, $2, $3, $4, $5, $6)
               ON CONFLICT (company_code) DO UPDATE SET legal_name = EXCLUDED.legal_name, country = EXCLUDED.country, currency = EXCLUDED.currency,
                                                        licence_type = EXCLUDED.licence_type, sap_schema = coalesce(EXCLUDED.sap_schema, sap._company.sap_schema)'
        USING v_code, v_legal, v_cty, v_cur, v_lic, v_sch;
      v_reg := true;
    EXCEPTION WHEN others THEN
      v_reg := erp._company_in_register(v_code);
    END;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, v_code, CASE WHEN v_edit THEN 'company_save' ELSE 'company_create' END, 'company', v_code,
          jsonb_build_object('before', CASE WHEN v_edit THEN to_jsonb(old) END, 'after', to_jsonb(n), 'in_register', v_reg));
  RETURN jsonb_build_object('company_code', v_code, 'created', NOT v_edit, 'in_register', v_reg);
END $$;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Price difference account for landed costs on goods already sold.
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', '5340', '5340', 'Price difference (SAMPLE)', '5000', 2, true, 'other', 5, 'AED', false, false, 0, 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT DO NOTHING;
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', 'inventory', 'price_difference', '5340', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = '5340')
ON CONFLICT (company_code, area, posting_key) DO NOTHING;
-- Credit memos by QA_SALES above 5,000 AED need the sales manager.
INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', 14, 'credit_memo_amount', 'QA_SALES', 5000, 'QA_SALES_MGR', 1, 'SAMPLE rule for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_SALES')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_SALES_MGR')
ON CONFLICT DO NOTHING;
-- Spare parts: the service manager position of the sample company.
UPDATE erp.service_setting SET manager_position = 'QA_SERVICE'
 WHERE company_code = 'ZZ99' AND manager_position IS NULL AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_SERVICE');

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._adm_doc_used(integer), erp._adm_doc_label(integer), erp._series_no(erp.doc_series_all, integer),
  erp._series_max(erp.doc_series_all), erp._series_problem(erp.doc_series_all, date, text, integer), erp._series_take(varchar, integer, text),
  erp._series_json(erp.doc_series_all), erp._series_lock(bigint), erp._sd_inv_exec(varchar, jsonb, jsonb, uuid), erp._sd_cm_exec(varchar, jsonb, jsonb, uuid),
  erp._sd_req_rules_apply(varchar, integer, jsonb, text), erp._sd_req_checks(varchar, integer, jsonb, text, numeric),
  erp._sd_req_dry_run(varchar, integer, jsonb, jsonb, uuid), erp._sd_req_open(varchar, integer, jsonb, jsonb, jsonb, numeric, erp.app_user),
  erp._sd_req_guard(varchar), erp._sd_quote_expired_msg(text, date), erp._sd_quote_expiry(), erp._svc_parts_ok(varchar, erp.app_user),
  erp._company_in_register(varchar)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp._series_ctx(bigint, jsonb), erp._series_clear() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._series_ctx(bigint, jsonb), erp._series_clear() TO authenticated;
REVOKE ALL ON FUNCTION erp.doc_numbering_setup(varchar), erp.doc_series_save(varchar, jsonb), erp.doc_series_delete(varchar, bigint),
  erp.series_user_default_save(varchar, uuid, integer, bigint), erp.doc_series_options(varchar, integer),
  erp.sales_doc_save(varchar, integer, integer, jsonb, jsonb, bigint), erp.sales_delivery_create(varchar, jsonb, jsonb, bigint),
  erp.sales_invoice_create(varchar, jsonb, jsonb, bigint), erp.sales_credit_memo_create(varchar, jsonb, jsonb, bigint),
  erp.payment_submit(varchar, text, jsonb, jsonb, text, bigint), erp.deposit_create(varchar, jsonb, jsonb, bigint),
  erp.purchase_doc_save(varchar, integer, integer, jsonb, jsonb, bigint), erp.purchase_deposit_create(varchar, integer, jsonb, bigint),
  erp.purchase_grpo_create(varchar, jsonb, jsonb, bigint), erp.purchase_invoice_create(varchar, jsonb, jsonb, bigint),
  erp.landed_cost_create(varchar, jsonb, jsonb, jsonb, bigint), erp.inventory_doc_create(varchar, integer, jsonb, jsonb, text, bigint),
  erp.transfer_request_create(varchar, jsonb, jsonb, bigint), erp.transfer_create(varchar, jsonb, jsonb, bigint),
  erp.inv_count_create(varchar, jsonb, bigint), erp.bp_save(varchar, jsonb, text, text, bigint), erp.item_save(varchar, jsonb, text, bigint),
  erp.hr_employee_save(varchar, jsonb, bigint), erp.prod_order_create(varchar, jsonb, bigint), erp.service_contract_save(varchar, jsonb, bigint),
  erp.service_call_save(varchar, jsonb, bigint), erp.sales_doc_request_decide(varchar, bigint, text, text),
  erp.sales_doc_request_cancel(varchar, bigint, text), erp.sales_doc_request_info(varchar, bigint), erp.company_list(), erp.company_save(jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.doc_numbering_setup(varchar), erp.doc_series_save(varchar, jsonb), erp.doc_series_delete(varchar, bigint),
  erp.series_user_default_save(varchar, uuid, integer, bigint), erp.doc_series_options(varchar, integer),
  erp.sales_doc_save(varchar, integer, integer, jsonb, jsonb, bigint), erp.sales_delivery_create(varchar, jsonb, jsonb, bigint),
  erp.sales_invoice_create(varchar, jsonb, jsonb, bigint), erp.sales_credit_memo_create(varchar, jsonb, jsonb, bigint),
  erp.payment_submit(varchar, text, jsonb, jsonb, text, bigint), erp.deposit_create(varchar, jsonb, jsonb, bigint),
  erp.purchase_doc_save(varchar, integer, integer, jsonb, jsonb, bigint), erp.purchase_deposit_create(varchar, integer, jsonb, bigint),
  erp.purchase_grpo_create(varchar, jsonb, jsonb, bigint), erp.purchase_invoice_create(varchar, jsonb, jsonb, bigint),
  erp.landed_cost_create(varchar, jsonb, jsonb, jsonb, bigint), erp.inventory_doc_create(varchar, integer, jsonb, jsonb, text, bigint),
  erp.transfer_request_create(varchar, jsonb, jsonb, bigint), erp.transfer_create(varchar, jsonb, jsonb, bigint),
  erp.inv_count_create(varchar, jsonb, bigint), erp.bp_save(varchar, jsonb, text, text, bigint), erp.item_save(varchar, jsonb, text, bigint),
  erp.hr_employee_save(varchar, jsonb, bigint), erp.prod_order_create(varchar, jsonb, bigint), erp.service_contract_save(varchar, jsonb, bigint),
  erp.service_call_save(varchar, jsonb, bigint), erp.sales_doc_request_decide(varchar, bigint, text, text),
  erp.sales_doc_request_cancel(varchar, bigint, text), erp.sales_doc_request_info(varchar, bigint), erp.company_list(), erp.company_save(jsonb)
  TO authenticated;

COMMENT ON TABLE erp.series_user_default IS 'B1 Document Numbering: default series per user, company and document type.';
COMMENT ON TABLE erp.sales_doc_request IS 'B1: credit memos and direct service invoices waiting for approval; the last approval creates the document.';

-- ============ Approvals inbox (copied from 25: the 12 earlier kinds + sales_doc_request) ============
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
      UNION ALL
      -- A8: credit limit / bank detail changes (doc_no and card_code = partner code, total = new credit limit)
      SELECT a.*, 'bp_change'::text, q.card_code::text, q.state, q.reason, q.requested_by, q.request_id, q.card_code::varchar, bp.name,
             CASE WHEN q.kind = 'credit_limit' THEN (q.after->>'credit_limit')::numeric END, bp.currency
        FROM erp.approval a
        JOIN erp.bp_change_request q ON q.company_code = a.company_code AND q.request_id::text = a.object_ref
        JOIN erp.business_partner bp ON bp.company_code = q.company_code AND bp.card_code = q.card_code
       WHERE a.object = 'bp_change' AND erp.can_see(a.company_code)
         AND (erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance') OR erp.can_read('banking'))
      UNION ALL
      -- A9: leave requests (doc_no = request id, card_code = employee code, card_name = employee name, total = days).
      SELECT a.*, 'leave'::text, q.request_id::text, q.state, q.reason, q.requested_by, q.request_id, e.hr_code::varchar,
             concat_ws(' ', e.first_name, e.last_name), q.days, NULL::varchar
        FROM erp.approval a
        JOIN erp.leave_request q ON q.company_code = a.company_code AND q.request_id::text = a.object_ref
        JOIN erp.employee e ON e.company_code = q.company_code AND e.emp_id = q.emp_id
       WHERE a.object = 'leave' AND erp.can_see(a.company_code)
      UNION ALL
      -- A10: company details changes (doc_no = request id, card_code = company, card_name = legal name; no amount).
      SELECT a.*, 'company_details'::text, q.request_id::text, q.state, q.reason, q.requested_by, q.request_id, q.company_code::varchar,
             co.legal_name, NULL::numeric, NULL::varchar
        FROM erp.approval a
        JOIN erp.company_change_request q ON q.company_code = a.company_code AND q.request_id::text = a.object_ref
        JOIN erp.company co ON co.company_code = q.company_code
       WHERE a.object = 'company_details' AND erp.can_see(a.company_code)
      UNION ALL
      -- B1: credit memos and direct service invoices waiting for approval (doc_no = REQ-<id>, total = document total).
      SELECT a.*, 'sales_doc_request'::text, 'REQ-' || q.request_id, q.state, q.reason, q.requested_by, q.request_id::integer, q.card_code,
             q.card_name, q.total, q.currency
        FROM erp.approval a
        JOIN erp.sales_doc_request q ON q.company_code = a.company_code AND q.request_id::text = a.object_ref
       WHERE a.object = 'sales_doc_request' AND erp.can_see(a.company_code) AND (erp.can_read('sales') OR erp.can_read('finance'))
    ), a AS (
      SELECT b.*, b.detail->>'for_user' AS for_user, p.name AS approver_position_name, ru.display_name AS requested_by_name, du.display_name AS decided_by_name,
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
      'is_approver', EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.approver_position = u.position_code AND ar.active AND erp.can_see(ar.company_code))
                     OR EXISTS (SELECT 1 FROM erp.hr_setting hs WHERE u.position_code IN (hs.hr_approver_position, hs.owner_position) AND erp.can_see(hs.company_code))
                     OR EXISTS (SELECT 1 FROM erp.approval ap WHERE ap.detail->>'for_user' = u.user_id::text)
                     OR EXISTS (SELECT 1 FROM erp.admin_setting s WHERE s.owner_position = u.position_code AND erp.can_see(s.company_code)),
      'waiting', coalesce((SELECT jsonb_agg(j ORDER BY requested_at) FROM r
                            WHERE decision IS NULL AND NOT superseded AND state = 'pending_approval' AND step = current_step
                              AND approver_position = u.position_code AND submitted_by IS DISTINCT FROM u.user_id
                              AND (for_user IS NULL OR for_user = u.user_id::text)), '[]'::jsonb),
      'sent', coalesce((SELECT jsonb_agg(j ORDER BY requested_at DESC, approval_id) FROM (SELECT * FROM r WHERE requested_by = u.user_id
                         ORDER BY requested_at DESC LIMIT 100) s), '[]'::jsonb),
      'decided', coalesce((SELECT jsonb_agg(j ORDER BY decided_at DESC) FROM (SELECT * FROM r WHERE approver_user = u.user_id AND decision IS NOT NULL
                            ORDER BY decided_at DESC LIMIT 100) s), '[]'::jsonb)));
END $$;

-- ============ Approval template catalogue (copied from 25 + credit_memo_amount) ============
-- Approval rule catalogue: which documents each rule code applies to and what its limit means.
CREATE OR REPLACE FUNCTION erp._adm_rule_spec() RETURNS TABLE (rule_code text, obj_types integer[], position_required boolean, limit_kind text, sort integer)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('discount_pct', ARRAY[17], true, 'pct', 1), ('credit_limit', ARRAY[17], false, 'none', 2), ('below_cost', ARRAY[17], false, 'none', 3),
    ('po_amount', ARRAY[22], false, 'amount', 4), ('po_price_increase', ARRAY[22], false, 'pct_any', 5),
    ('payment_amount', ARRAY[46], false, 'amount', 6), ('bank_change', ARRAY[46], false, 'days', 7),
    ('journal_amount', ARRAY[30], false, 'amount', 8),
    ('stock_doc_amount', ARRAY[59, 60], false, 'amount', 9),
    ('count_variance_pct', ARRAY[1470000065], false, 'pct', 10), ('count_variance_value', ARRAY[1470000065], false, 'amount', 11),
    ('bp_credit_limit', ARRAY[2], false, 'none', 12), ('bp_bank_detail', ARRAY[2], false, 'none', 13),
    ('credit_memo_amount', ARRAY[14], false, 'amount', 14)
  ) AS v(rule_code, obj_types, position_required, limit_kind, sort)
$$;

-- ============ System health: marker for this file (copied from 29) ============
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health'),
    ('30_numbering_company.sql', 'doc_series_save')
  ) AS v(file_name, object)
$$;
