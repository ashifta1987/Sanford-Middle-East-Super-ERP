-- B3 · G/L Account Determination and setup windows (warehouses, item groups, landed costs, production resources, goods
-- receipt / issue reasons, bank statement matching). Safe to run twice. Does not edit 10–31: earlier behaviour is changed
-- here with CREATE OR REPLACE, keeping the earlier tests passing.
--
-- Decisions of 10 Nov 2026 (docs/decisions-2026-11-10.md): §2 C2, C4, C5, C6, C7 and §3 (GR/GI reasons, bank statement
-- matching). Accounts and other company-specific values are entered by Sanford in these screens; AE01–AE05 start empty.
--
-- Objects:
--   erp.gl_posting_key           – existing (18); gets tab (the SAP B1 tab it shows on), ctx (item group / warehouse may
--                                  override it), store (the key lives in an existing setting column), control_ok (receivable /
--                                  payable keys may use control accounts), used_in (where Super ERP posts it). New keys for
--                                  Banking, Production, Service, Payroll and the goods receipt / issue reasons.
--   erp.gl_determination_group   – account per item group and key (overrides the company default)
--   erp.gl_determination_whs     – account per warehouse and key (overrides item group and company; the warehouse stock
--                                  account stays in warehouse_setting.stock_acct from A7)
--   erp.warehouse_setting        – existing; gets origin ('erp' = created in Super ERP, general data editable here)
--   erp.warehouse_series_default – default numbering series per warehouse and document type (B1 doc_series)
--   erp.item_group_setting       – management method (none / batch / serial) and origin per item group; warranty months stay
--                                  in A13's warranty_rule (group rows)
--   erp.landed_cost_code         – existing (21); split_method + 'equal', acct_code (the account the cost is credited to)
--   erp.landed_cost_charge       – existing; gets acct_code (the account credited when posted)
--   erp.inventory_reason         – existing (22); gets gl_area / gl_key (the G/L determination key used when the reason has
--                                  no account of its own). Standard reasons seeded for AE01–AE05 (accounts empty).
--   erp.bank_statement_format    – the CSV column mapping saved per house bank account
--   internal                     – _gl_default, gl_account (6 arguments; the A3 4-argument one delegates), _gl_item_acct,
--                                  _gl_acct_problem, _gl_set_one, _inv_whs_acct (replaced), _seed_std_reasons, _bk_norm_ref,
--                                  _bk_jl_refs; replaced posting: post_document, _count_post, _inv_eval, _lc_eval,
--                                  landed_cost_create, prod_order_receipt; replaced setup: prod_resource_save,
--                                  inventory_reason_save, landed_cost_code_save, gl_determination_set, _series_take,
--                                  bank_statement_auto_match, _health_files
--   API                          – gl_setup, gl_determination_save, gl_override_save, warehouse_setup, warehouse_save,
--                                  warehouse_series_set, item_group_setup, item_group_save, landed_cost_setup,
--                                  bank_statement_format_save, bank_statement_activity
--
-- Account resolution: warehouse (Accounting tab) → item group → company default (G/L Account Determination). Only keys with
-- ctx = true look at the item group and warehouse. With no overrides set, every journal is exactly as before.

-- ============ 1. Posting keys ============
ALTER TABLE erp.gl_posting_key DROP CONSTRAINT IF EXISTS gl_posting_key_area_check;
ALTER TABLE erp.gl_posting_key ADD CONSTRAINT gl_posting_key_area_check
  CHECK (area IN ('sales', 'purchasing', 'general', 'inventory', 'resources', 'banking', 'production', 'service', 'payroll'));
ALTER TABLE erp.gl_posting_key ADD COLUMN IF NOT EXISTS tab text;
ALTER TABLE erp.gl_posting_key ADD COLUMN IF NOT EXISTS ctx boolean NOT NULL DEFAULT false;
ALTER TABLE erp.gl_posting_key ADD COLUMN IF NOT EXISTS store text;
ALTER TABLE erp.gl_posting_key ADD COLUMN IF NOT EXISTS control_ok boolean NOT NULL DEFAULT false;
ALTER TABLE erp.gl_posting_key ADD COLUMN IF NOT EXISTS used_in text;
ALTER TABLE erp.gl_posting_key DROP CONSTRAINT IF EXISTS gl_posting_key_store_check;
ALTER TABLE erp.gl_posting_key ADD CONSTRAINT gl_posting_key_store_check
  CHECK (store IS NULL OR store IN ('banking_setting.cash_acct', 'banking_setting.cheque_acct', 'banking_setting.card_acct',
                                    'production_setting.wip_acct', 'production_setting.variance_acct', 'hr_setting.payable_acct'));

-- Every key Super ERP posts (18–31) plus the ones SAP's window shows. used_in says where each one is posted today.
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort, tab, ctx, store, control_ok, used_in) VALUES
  ('sales', 'domestic_ar', 'Domestic accounts receivable', 1, 'sales', false, NULL, true, 'A/R invoices, A/R credit memos, incoming payments'),
  ('sales', 'revenue', 'Revenue', 2, 'sales', true, NULL, false, 'A/R invoices'),
  ('sales', 'sales_returns', 'Sales returns', 3, 'sales', true, NULL, false, 'A/R credit memos'),
  ('sales', 'down_payment_clearing', 'Down payment clearing', 4, 'sales', false, NULL, false, NULL),
  ('sales', 'output_vat', 'Output VAT', 5, 'sales', false, NULL, false, 'A/R invoices, A/R credit memos'),
  ('sales', 'fx_gain', 'Exchange rate gains', 6, 'sales', false, NULL, false, NULL),
  ('purchasing', 'domestic_ap', 'Domestic accounts payable', 7, 'purchasing', false, NULL, true, 'A/P invoices, A/P down payment invoices, outgoing payments'),
  ('purchasing', 'foreign_ap', 'Foreign accounts payable', 8, 'purchasing', false, NULL, true, NULL),
  ('purchasing', 'down_payments', 'Down payments (deposits)', 9, 'purchasing', false, NULL, false, 'A/P down payment invoices, deposits drawn on A/P invoices'),
  ('purchasing', 'input_vat', 'Input VAT', 10, 'purchasing', false, NULL, false, 'A/P invoices'),
  ('purchasing', 'goods_in_transit', 'Goods in transit', 11, 'purchasing', false, NULL, false, NULL),
  ('purchasing', 'grpo_clearing', 'Goods received, not invoiced', 12, 'purchasing', false, NULL, false, 'Goods receipt POs, A/P invoices'),
  ('purchasing', 'fx_loss', 'Exchange rate losses', 13, 'purchasing', false, NULL, false, NULL),
  ('inventory', 'inventory', 'Inventory', 20, 'inventory', true, NULL, false,
     'Goods receipts and issues, transfers, deliveries, returns, goods receipt POs, counts, landed costs, production'),
  ('inventory', 'cogs', 'Cost of goods sold', 21, 'inventory', true, NULL, false, 'Deliveries, A/R credit memos that return stock'),
  ('inventory', 'count_variance', 'Stock count variance', 22, 'inventory', true, NULL, false, 'Inventory counts'),
  ('inventory', 'inventory_revaluation', 'Inventory revaluation', 23, 'inventory', true, NULL, false, NULL),
  ('inventory', 'offset_increase', 'Inventory offset – increase', 24, 'inventory', true, NULL, false, 'Goods receipt reasons mapped to it (found stock)'),
  ('inventory', 'offset_decrease', 'Inventory offset – decrease', 25, 'inventory', true, NULL, false, 'Goods issue reasons mapped to it'),
  ('inventory', 'write_off', 'Stock write-off', 26, 'inventory', true, NULL, false, 'Goods issue reasons mapped to it (damage, write-off)'),
  ('inventory', 'samples', 'Samples', 27, 'inventory', true, NULL, false, 'Goods issue reasons mapped to it (samples)'),
  ('inventory', 'internal_use', 'Internal use', 28, 'inventory', true, NULL, false, 'Goods issue reasons mapped to it (internal use)'),
  ('banking', 'cash', 'Cash on hand', 30, 'banking', false, 'banking_setting.cash_acct', false, 'Payments in cash, cash deposits'),
  ('banking', 'cheques_received', 'Cheques received, not deposited', 31, 'banking', false, 'banking_setting.cheque_acct', false, 'Incoming cheques, deposits'),
  ('banking', 'card_clearing', 'Card receipts clearing', 32, 'banking', false, 'banking_setting.card_acct', false, 'Incoming card payments'),
  ('general', 'bank_charges', 'Bank charges', 33, 'banking', false, NULL, false, NULL),
  ('production', 'wip', 'Work in progress', 40, 'production', false, 'production_setting.wip_acct', false, 'Issue for production, receipt from production, resource cost'),
  ('production', 'variance', 'Production variance', 41, 'production', false, 'production_setting.variance_acct', false, 'Closing production orders'),
  ('resources', 'resource_cost', 'Resource absorption', 42, 'production', false, NULL, false, 'Receipt from production: resources without their own account'),
  ('production', 'spare_parts', 'Spare parts for moulds and machines', 43, 'production', true, NULL, false, 'Goods issue reasons mapped to it'),
  ('service', 'spare_parts', 'Spare parts used in service', 50, 'service', true, NULL, false, 'Spare parts issued to service calls (reasons mapped to it)'),
  ('payroll', 'payable', 'Salaries payable', 60, 'payroll', false, 'hr_setting.payable_acct', false, 'Payroll posting'),
  ('purchasing', 'landed_cost_clearing', 'Landed cost clearing', 70, 'landed_costs', false, NULL, false, 'Landed costs (types without their own account)'),
  ('inventory', 'price_difference', 'Price difference', 71, 'landed_costs', true, NULL, false, 'Landed costs on goods already sold'),
  ('general', 'rounding', 'Rounding', 80, 'general', false, NULL, false, NULL),
  ('general', 'opening_balances', 'Opening balances', 81, 'general', false, NULL, false, 'Goods receipt reasons mapped to it (opening stock)')
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, tab = EXCLUDED.tab, ctx = EXCLUDED.ctx,
  store = EXCLUDED.store, control_ok = EXCLUDED.control_ok, used_in = EXCLUDED.used_in;

-- Keys that live in a setting column never get a gl_determination row (a stray one would hide the setting).
DELETE FROM erp.gl_determination g USING erp.gl_posting_key k
 WHERE k.area = g.area AND k.posting_key = g.posting_key AND k.store IS NOT NULL AND g.source <> 'sap';

-- ============ 2. Tables ============
CREATE TABLE IF NOT EXISTS erp.gl_determination_group (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    group_code     integer NOT NULL,                  -- erp.item_group (no FK: the sync owns that table)
    area           text NOT NULL,
    posting_key    text NOT NULL,
    acct_code      varchar(15) NOT NULL,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, group_code, area, posting_key),
    FOREIGN KEY (area, posting_key) REFERENCES erp.gl_posting_key,
    FOREIGN KEY (company_code, acct_code) REFERENCES erp.account ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.gl_determination_whs (
    company_code   varchar(8) NOT NULL,
    whs_code       varchar(8) NOT NULL,
    area           text NOT NULL,
    posting_key    text NOT NULL,
    acct_code      varchar(15) NOT NULL,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, whs_code, area, posting_key),
    FOREIGN KEY (company_code, whs_code) REFERENCES erp.warehouse ON DELETE CASCADE,
    FOREIGN KEY (area, posting_key) REFERENCES erp.gl_posting_key,
    FOREIGN KEY (company_code, acct_code) REFERENCES erp.account ON DELETE CASCADE
);

ALTER TABLE erp.warehouse_setting ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'sap';
ALTER TABLE erp.warehouse_setting DROP CONSTRAINT IF EXISTS warehouse_setting_origin_check;
ALTER TABLE erp.warehouse_setting ADD CONSTRAINT warehouse_setting_origin_check CHECK (origin IN ('sap', 'erp'));

CREATE TABLE IF NOT EXISTS erp.warehouse_series_default (
    company_code   varchar(8) NOT NULL,
    whs_code       varchar(8) NOT NULL,
    obj_type       integer NOT NULL,
    series_id      bigint NOT NULL,                   -- erp.doc_series_all (removed with the series)
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, whs_code, obj_type),
    FOREIGN KEY (company_code, whs_code) REFERENCES erp.warehouse ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.item_group_setting (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    group_code     integer NOT NULL,
    manage_method  text NOT NULL DEFAULT 'none' CHECK (manage_method IN ('none', 'batch', 'serial')),
    origin         text NOT NULL DEFAULT 'sap' CHECK (origin IN ('sap', 'erp')),   -- 'erp' = created in Super ERP
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, group_code)
);

ALTER TABLE erp.landed_cost_code DROP CONSTRAINT IF EXISTS landed_cost_code_split_method_check;
ALTER TABLE erp.landed_cost_code ADD CONSTRAINT landed_cost_code_split_method_check CHECK (split_method IN ('cbm', 'qty', 'value', 'weight', 'equal'));
ALTER TABLE erp.landed_cost_code ADD COLUMN IF NOT EXISTS acct_code varchar(15);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS acct_code varchar(15);

ALTER TABLE erp.inventory_reason ADD COLUMN IF NOT EXISTS gl_area text;
ALTER TABLE erp.inventory_reason ADD COLUMN IF NOT EXISTS gl_key text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inventory_reason_gl_key_fkey') THEN
    ALTER TABLE erp.inventory_reason ADD CONSTRAINT inventory_reason_gl_key_fkey FOREIGN KEY (gl_area, gl_key) REFERENCES erp.gl_posting_key (area, posting_key);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS erp.bank_statement_format (
    company_code   varchar(8) NOT NULL,
    bank_code      text NOT NULL,
    mapping        jsonb NOT NULL,                    -- {mode, date, amount, debit, credit, reference, description, date_format, decimal_sep}
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, bank_code),
    FOREIGN KEY (company_code, bank_code) REFERENCES erp.bank_account ON DELETE CASCADE
);

-- ============ 3. Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.gl_determination_group ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.gl_determination_whs ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.warehouse_series_default ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.item_group_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bank_statement_format ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.gl_determination_group, erp.gl_determination_whs, erp.warehouse_series_default, erp.item_group_setting,
  erp.bank_statement_format FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.gl_determination_group, erp.gl_determination_whs, erp.warehouse_series_default, erp.item_group_setting,
  erp.bank_statement_format TO authenticated;
DROP POLICY IF EXISTS gl_determination_group_read ON erp.gl_determination_group;
CREATE POLICY gl_determination_group_read ON erp.gl_determination_group FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.can_read('finance')));
DROP POLICY IF EXISTS gl_determination_whs_read ON erp.gl_determination_whs;
CREATE POLICY gl_determination_whs_read ON erp.gl_determination_whs FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.can_read('finance')));
DROP POLICY IF EXISTS warehouse_series_default_read ON erp.warehouse_series_default;
CREATE POLICY warehouse_series_default_read ON erp.warehouse_series_default FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS item_group_setting_read ON erp.item_group_setting;
CREATE POLICY item_group_setting_read ON erp.item_group_setting FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS bank_statement_format_read ON erp.bank_statement_format;
CREATE POLICY bank_statement_format_read ON erp.bank_statement_format FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('banking')) OR (SELECT erp.can_read('finance'))));

-- ============ 4. Account resolution ============
-- The company default of a key: its setting column (store) or its gl_determination row. Internal.
CREATE OR REPLACE FUNCTION erp._gl_default(p_company varchar, p_area text, p_key text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_store text;
  v text;
BEGIN
  SELECT store INTO v_store FROM erp.gl_posting_key WHERE area = p_area AND posting_key = p_key;
  CASE v_store
    WHEN 'banking_setting.cash_acct' THEN SELECT cash_acct INTO v FROM erp.banking_setting WHERE company_code = p_company;
    WHEN 'banking_setting.cheque_acct' THEN SELECT cheque_acct INTO v FROM erp.banking_setting WHERE company_code = p_company;
    WHEN 'banking_setting.card_acct' THEN SELECT card_acct INTO v FROM erp.banking_setting WHERE company_code = p_company;
    WHEN 'production_setting.wip_acct' THEN SELECT wip_acct INTO v FROM erp.production_setting WHERE company_code = p_company;
    WHEN 'production_setting.variance_acct' THEN SELECT variance_acct INTO v FROM erp.production_setting WHERE company_code = p_company;
    WHEN 'hr_setting.payable_acct' THEN SELECT payable_acct INTO v FROM erp.hr_setting WHERE company_code = p_company;
    ELSE SELECT acct_code INTO v FROM erp.gl_determination WHERE company_code = p_company AND area = p_area AND posting_key = p_key;
  END CASE;
  RETURN v;
END $$;

-- The account for a posting key in a context: warehouse (its Accounting tab) → item group → company default. Only keys
-- with ctx look at the item group and warehouse; for inventory/inventory the warehouse account is warehouse_setting.stock_acct.
-- p_raise = true raises the A3 "not set" message.
CREATE OR REPLACE FUNCTION erp.gl_account(p_company varchar, p_area text, p_key text, p_raise boolean, p_item_group integer, p_whs text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  k  erp.gl_posting_key;
  v  text;
BEGIN
  SELECT * INTO k FROM erp.gl_posting_key WHERE area = p_area AND posting_key = p_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown posting key %/%.', p_area, p_key USING ERRCODE = 'P0001';
  END IF;
  IF k.ctx AND p_whs IS NOT NULL THEN
    IF p_area = 'inventory' AND p_key = 'inventory' THEN
      SELECT stock_acct INTO v FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = p_whs;
    ELSE
      SELECT acct_code INTO v FROM erp.gl_determination_whs WHERE company_code = p_company AND whs_code = p_whs AND area = p_area AND posting_key = p_key;
    END IF;
  END IF;
  IF v IS NULL AND k.ctx AND p_item_group IS NOT NULL THEN
    SELECT acct_code INTO v FROM erp.gl_determination_group WHERE company_code = p_company AND group_code = p_item_group AND area = p_area AND posting_key = p_key;
  END IF;
  IF v IS NULL THEN
    v := erp._gl_default(p_company, p_area, p_key);
  END IF;
  IF v IS NULL AND p_raise THEN
    RAISE EXCEPTION '%', format('G/L account for ''%s'' is not set for %s. Ask Finance to set it in Setup › Financials › G/L Account Determination.',
                                k.label, p_company) USING ERRCODE = 'P0001';
  END IF;
  RETURN v;
END $$;

-- A3's signature (replaced): the company default, same messages.
CREATE OR REPLACE FUNCTION erp.gl_account(p_company varchar, p_area text, p_key text, p_raise boolean DEFAULT true) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp.gl_account(p_company, p_area, p_key, p_raise, NULL::integer, NULL::text)
$$;

-- The account for a key on a document line: the item's group and the line's warehouse. Raises when nothing is set.
CREATE OR REPLACE FUNCTION erp._gl_item_acct(p_company varchar, p_area text, p_key text, p_item text, p_whs text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp.gl_account(p_company, p_area, p_key, true,
                        (SELECT group_code FROM erp.item WHERE company_code = p_company AND item_code = p_item), p_whs)
$$;

-- The stock account of a warehouse (replaces 22's, same result): its own account, else the company inventory account.
CREATE OR REPLACE FUNCTION erp._inv_whs_acct(p_company varchar, p_whs text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp.gl_account(p_company, 'inventory', 'inventory', true, NULL::integer, p_whs)
$$;

-- Why an account can't be used for a key (NULL = it can). p_strict adds the control-account rule.
CREATE OR REPLACE FUNCTION erp._gl_acct_problem(p_company varchar, p_acct text, p_control_ok boolean, p_strict boolean) RETURNS text
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
  ELSIF p_strict AND a.is_control AND NOT p_control_ok THEN
    RETURN format('Account %s · %s is a control account for customers or suppliers. Only the receivable and payable keys can use it.', p_acct, a.name);
  END IF;
  RETURN NULL;
END $$;

-- Set (or clear, p_acct NULL) one key at one level: 'company' (G/L Account Determination), 'group' (item group p_ref) or
-- 'warehouse' (warehouse p_ref). Validates, writes the right table (or the setting column of a stored key) and the audit
-- row. Internal: callers check the user (Financials full). Returns {area, posting_key, acct_code, from, changed}.
CREATE OR REPLACE FUNCTION erp._gl_set_one(u erp.app_user, p_company varchar, p_level text, p_ref text, p_area text, p_key text, p_acct text, p_strict boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  k       erp.gl_posting_key;
  g       erp.gl_determination;
  v_acct  text := nullif(btrim(p_acct), '');
  v_from  text;
  v_msg   text;
  v_group integer;
  v_ref   text;
BEGIN
  SELECT * INTO k FROM erp.gl_posting_key WHERE area = p_area AND posting_key = p_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown posting key %/%.', coalesce(p_area, '(none)'), coalesce(p_key, '(none)') USING ERRCODE = 'P0001';
  END IF;
  IF v_acct IS NOT NULL THEN
    v_msg := erp._gl_acct_problem(p_company, v_acct, k.control_ok, p_strict);
    IF v_msg IS NOT NULL THEN
      RAISE EXCEPTION '%', CASE WHEN p_strict THEN k.label || ': ' || v_msg ELSE v_msg END USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_level = 'company' THEN
    v_ref := p_area || '/' || p_key;
    IF k.store IS NULL THEN
      SELECT * INTO g FROM erp.gl_determination WHERE company_code = p_company AND area = p_area AND posting_key = p_key FOR UPDATE;
      IF FOUND AND g.source = 'sap' THEN
        RAISE EXCEPTION 'The account for ''%'' comes from SAP Business One and is read-only during the soft switch.', k.label USING ERRCODE = 'P0001';
      END IF;
      v_from := g.acct_code;
      IF v_from IS NOT DISTINCT FROM v_acct THEN
        RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', v_from, 'changed', false);
      END IF;
      IF v_acct IS NULL THEN
        DELETE FROM erp.gl_determination WHERE company_code = p_company AND area = p_area AND posting_key = p_key;
      ELSE
        INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source, updated_by, updated_at)
        VALUES (p_company, p_area, p_key, v_acct, 'erp', u.user_id, now())
        ON CONFLICT (company_code, area, posting_key) DO UPDATE SET acct_code = EXCLUDED.acct_code, source = 'erp', updated_by = EXCLUDED.updated_by, updated_at = now();
      END IF;
    ELSE
      v_from := erp._gl_default(p_company, p_area, p_key);
      IF v_from IS NOT DISTINCT FROM v_acct THEN
        RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', v_from, 'changed', false);
      END IF;
      IF k.store LIKE 'banking_setting.%' THEN
        INSERT INTO erp.banking_setting (company_code, updated_by, updated_at) VALUES (p_company, u.user_id, now()) ON CONFLICT (company_code) DO NOTHING;
        EXECUTE format('UPDATE erp.banking_setting SET %I = $1, updated_by = $2, updated_at = now() WHERE company_code = $3', split_part(k.store, '.', 2))
          USING v_acct, u.user_id, p_company;
      ELSIF k.store LIKE 'production_setting.%' THEN
        INSERT INTO erp.production_setting (company_code, updated_by, updated_at) VALUES (p_company, u.user_id, now()) ON CONFLICT (company_code) DO NOTHING;
        EXECUTE format('UPDATE erp.production_setting SET %I = $1, updated_by = $2, updated_at = now() WHERE company_code = $3', split_part(k.store, '.', 2))
          USING v_acct, u.user_id, p_company;
      ELSE
        INSERT INTO erp.hr_setting (company_code) VALUES (p_company) ON CONFLICT (company_code) DO NOTHING;
        UPDATE erp.hr_setting SET payable_acct = v_acct WHERE company_code = p_company;
      END IF;
    END IF;
  ELSIF p_level IN ('group', 'warehouse') THEN
    IF NOT k.ctx THEN
      RAISE EXCEPTION '''%'' is set for the whole company only. Set it in G/L Account Determination.', k.label USING ERRCODE = 'P0001';
    END IF;
    IF p_level = 'group' THEN
      v_group := CASE WHEN p_ref ~ '^-?\d{1,9}$' THEN p_ref::integer END;
      IF v_group IS NULL OR NOT EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND group_code = v_group) THEN
        RAISE EXCEPTION 'Item group % does not exist in company %.', coalesce(p_ref, '(none)'), p_company USING ERRCODE = 'P0001';
      END IF;
      v_ref := format('group:%s:%s/%s', v_group, p_area, p_key);
      SELECT acct_code INTO v_from FROM erp.gl_determination_group WHERE company_code = p_company AND group_code = v_group AND area = p_area AND posting_key = p_key FOR UPDATE;
      IF v_from IS NOT DISTINCT FROM v_acct THEN
        RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', v_from, 'changed', false);
      END IF;
      IF v_acct IS NULL THEN
        DELETE FROM erp.gl_determination_group WHERE company_code = p_company AND group_code = v_group AND area = p_area AND posting_key = p_key;
      ELSE
        INSERT INTO erp.gl_determination_group (company_code, group_code, area, posting_key, acct_code, updated_by, updated_at)
        VALUES (p_company, v_group, p_area, p_key, v_acct, u.user_id, now())
        ON CONFLICT (company_code, group_code, area, posting_key) DO UPDATE SET acct_code = EXCLUDED.acct_code, updated_by = EXCLUDED.updated_by, updated_at = now();
      END IF;
    ELSE
      IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = p_ref) THEN
        RAISE EXCEPTION 'Warehouse % does not exist in company %.', coalesce(p_ref, '(none)'), p_company USING ERRCODE = 'P0001';
      END IF;
      v_ref := format('warehouse:%s:%s/%s', p_ref, p_area, p_key);
      IF p_area = 'inventory' AND p_key = 'inventory' THEN
        SELECT stock_acct INTO v_from FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = p_ref FOR UPDATE;
        IF v_from IS NOT DISTINCT FROM v_acct THEN
          RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', v_from, 'changed', false);
        END IF;
        INSERT INTO erp.warehouse_setting (company_code, whs_code, allow_negative, updated_by, updated_at) VALUES (p_company, p_ref, false, u.user_id, now())
        ON CONFLICT (company_code, whs_code) DO NOTHING;
        UPDATE erp.warehouse_setting SET stock_acct = v_acct, updated_by = u.user_id, updated_at = now() WHERE company_code = p_company AND whs_code = p_ref;
      ELSE
        SELECT acct_code INTO v_from FROM erp.gl_determination_whs WHERE company_code = p_company AND whs_code = p_ref AND area = p_area AND posting_key = p_key FOR UPDATE;
        IF v_from IS NOT DISTINCT FROM v_acct THEN
          RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', v_from, 'changed', false);
        END IF;
        IF v_acct IS NULL THEN
          DELETE FROM erp.gl_determination_whs WHERE company_code = p_company AND whs_code = p_ref AND area = p_area AND posting_key = p_key;
        ELSE
          INSERT INTO erp.gl_determination_whs (company_code, whs_code, area, posting_key, acct_code, updated_by, updated_at)
          VALUES (p_company, p_ref, p_area, p_key, v_acct, u.user_id, now())
          ON CONFLICT (company_code, whs_code, area, posting_key) DO UPDATE SET acct_code = EXCLUDED.acct_code, updated_by = EXCLUDED.updated_by, updated_at = now();
        END IF;
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'Choose where the account is set: company, item group or warehouse.' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_acct IS NULL THEN 'gl_determination_clear' ELSE 'gl_determination_set' END, 'gl_determination',
          v_ref, jsonb_build_object('from', v_from, 'to', v_acct, 'level', p_level, 'ref', p_ref, 'label', k.label));
  RETURN jsonb_build_object('area', p_area, 'posting_key', p_key, 'acct_code', v_acct, 'from', v_from, 'changed', true);
END $$;

-- A3's API (replaced): same checks and messages, now through the routing above (stored keys write their setting).
CREATE OR REPLACE FUNCTION erp.gl_determination_set(p_company varchar, p_area text, p_key text, p_acct text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  r jsonb;
BEGIN
  u := erp._je_guard(p_company, true, 'change G/L account determination');
  r := erp._gl_set_one(u, p_company, 'company', NULL, p_area, p_key, p_acct, false);
  IF NOT (r->>'changed')::boolean THEN
    -- Same value again: A3 still logged it.
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, CASE WHEN r->>'acct_code' IS NULL THEN 'gl_determination_clear' ELSE 'gl_determination_set' END, 'gl_determination',
            p_area || '/' || p_key, jsonb_build_object('from', r->'from', 'to', r->'acct_code'));
  END IF;
  RETURN r - 'changed';
END $$;

-- ============ 5. API: G/L Account Determination ============
-- Everything the screen needs: tabs, every key with its company default, the item group and warehouse overrides.
CREATE OR REPLACE FUNCTION erp.gl_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._je_guard(p_company, false);
  RETURN jsonb_build_object(
    'company', p_company,
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('finance'),
    'tabs', to_jsonb(ARRAY['sales', 'purchasing', 'inventory', 'banking', 'production', 'service', 'payroll', 'landed_costs', 'general']),
    'keys', coalesce((
      SELECT jsonb_agg(jsonb_build_object('area', k.area, 'posting_key', k.posting_key, 'label', k.label, 'sort', k.sort, 'tab', k.tab, 'ctx', k.ctx,
               'store', k.store, 'control_ok', k.control_ok, 'used_in', k.used_in,
               'acct_code', x.acct, 'acct_name', a.name,
               'source', CASE WHEN k.store IS NOT NULL THEN CASE WHEN x.acct IS NOT NULL THEN 'erp' END ELSE g.source END,
               'updated_at', g.updated_at,
               'overrides', (SELECT count(*) FROM erp.gl_determination_group o WHERE o.company_code = p_company AND o.area = k.area AND o.posting_key = k.posting_key)
                          + (SELECT count(*) FROM erp.gl_determination_whs o WHERE o.company_code = p_company AND o.area = k.area AND o.posting_key = k.posting_key)
                          + CASE WHEN k.area = 'inventory' AND k.posting_key = 'inventory'
                                 THEN (SELECT count(*) FROM erp.warehouse_setting s WHERE s.company_code = p_company AND s.stock_acct IS NOT NULL) ELSE 0 END)
               ORDER BY k.sort, k.area, k.posting_key)
        FROM erp.gl_posting_key k
        LEFT JOIN erp.gl_determination g ON g.company_code = p_company AND g.area = k.area AND g.posting_key = k.posting_key AND k.store IS NULL
        CROSS JOIN LATERAL (SELECT CASE WHEN k.store IS NULL THEN g.acct_code ELSE erp._gl_default(p_company, k.area, k.posting_key) END AS acct) x
        LEFT JOIN erp.account a ON a.company_code = p_company AND a.acct_code = x.acct), '[]'::jsonb),
    'groups', coalesce((SELECT jsonb_agg(jsonb_build_object('group_code', ig.group_code, 'name', ig.name) ORDER BY ig.name)
                          FROM erp.item_group ig WHERE ig.company_code = p_company), '[]'::jsonb),
    'warehouses', coalesce((SELECT jsonb_agg(jsonb_build_object('whs_code', w.whs_code, 'name', w.name) ORDER BY w.whs_code)
                              FROM erp.warehouse w WHERE w.company_code = p_company), '[]'::jsonb),
    'group_rows', coalesce((SELECT jsonb_agg(jsonb_build_object('group_code', o.group_code, 'area', o.area, 'posting_key', o.posting_key, 'acct_code', o.acct_code,
                                                                'acct_name', a.name, 'updated_at', o.updated_at) ORDER BY o.group_code, o.area, o.posting_key)
                              FROM erp.gl_determination_group o LEFT JOIN erp.account a ON a.company_code = o.company_code AND a.acct_code = o.acct_code
                             WHERE o.company_code = p_company), '[]'::jsonb),
    'warehouse_rows', coalesce((SELECT jsonb_agg(r ORDER BY r->>'whs_code', r->>'area', r->>'posting_key') FROM (
                                  SELECT jsonb_build_object('whs_code', o.whs_code, 'area', o.area, 'posting_key', o.posting_key, 'acct_code', o.acct_code,
                                                            'acct_name', a.name, 'updated_at', o.updated_at) AS r
                                    FROM erp.gl_determination_whs o LEFT JOIN erp.account a ON a.company_code = o.company_code AND a.acct_code = o.acct_code
                                   WHERE o.company_code = p_company
                                  UNION ALL
                                  SELECT jsonb_build_object('whs_code', s.whs_code, 'area', 'inventory', 'posting_key', 'inventory', 'acct_code', s.stock_acct,
                                                            'acct_name', a.name, 'updated_at', s.updated_at)
                                    FROM erp.warehouse_setting s LEFT JOIN erp.account a ON a.company_code = s.company_code AND a.acct_code = s.stock_acct
                                   WHERE s.company_code = p_company AND s.stock_acct IS NOT NULL) z), '[]'::jsonb));
END $$;

-- Save the company defaults of several keys at once (the editable grid). All or nothing: the first problem raises and
-- nothing is saved. p_rows: [{area, posting_key, acct_code ('' or null clears)}]. Returns {saved, changed}.
CREATE OR REPLACE FUNCTION erp.gl_determination_save(p_company varchar, p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  x   jsonb;
  r   jsonb;
  v_n integer := 0;
  v_c integer := 0;
BEGIN
  u := erp._je_guard(p_company, true, 'change G/L account determination');
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'Nothing to save. Change at least one account first.' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(p_rows) e) <> (SELECT count(DISTINCT (e->>'area', e->>'posting_key')) FROM jsonb_array_elements(p_rows) e) THEN
    RAISE EXCEPTION 'A key is listed twice. Save each key once.' USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    r := erp._gl_set_one(u, p_company, 'company', NULL, x->>'area', x->>'posting_key', x->>'acct_code', true);
    v_n := v_n + 1;
    IF (r->>'changed')::boolean THEN v_c := v_c + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('saved', v_n, 'changed', v_c);
END $$;

-- Save the accounts of one item group (p_level 'group', p_ref = group code) or one warehouse (p_level 'warehouse', p_ref =
-- warehouse code). p_rows: [{area, posting_key, acct_code ('' clears = use the next level)}]. All or nothing.
CREATE OR REPLACE FUNCTION erp.gl_override_save(p_company varchar, p_level text, p_ref text, p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  x   jsonb;
  r   jsonb;
  v_n integer := 0;
  v_c integer := 0;
BEGIN
  u := erp._je_guard(p_company, true, CASE p_level WHEN 'warehouse' THEN 'change warehouse accounts' ELSE 'change item group accounts' END);
  IF p_level IS NULL OR p_level NOT IN ('group', 'warehouse') THEN
    RAISE EXCEPTION 'Choose where the accounts are set: item group or warehouse.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'Nothing to save. Change at least one account first.' USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    r := erp._gl_set_one(u, p_company, p_level, p_ref, x->>'area', x->>'posting_key', x->>'acct_code', true);
    v_n := v_n + 1;
    IF (r->>'changed')::boolean THEN v_c := v_c + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('saved', v_n, 'changed', v_c);
END $$;


-- ============ 11. Posting with item group / warehouse accounts ============
-- ---- post_document: copied from 22_inventory.sql:978. B3: stock accounts per line (item group, warehouse), COGS per line
-- (15 / 14 with returned stock), revenue / returns per line (13 / 14); transfers (67) post only lines whose accounts differ.
-- With no item group or warehouse accounts set, every journal is exactly as before.
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
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
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
    SELECT jsonb_agg(x ORDER BY ord, acct) INTO v_lines FROM (
      SELECT 1 AS ord, t.acct, jsonb_build_object('acct_code', t.acct, 'debit', t.amt) AS x
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry
                 AND erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) <> erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs)
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) t
      UNION ALL
      SELECT 2, f.acct, jsonb_build_object('acct_code', f.acct, 'credit', f.amt)
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry
                 AND erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) <> erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs)
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
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
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
    v_lines := (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'cogs', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
             WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
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
    SELECT jsonb_agg(jsonb_build_object('acct_code', s.acct, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(s.net, 2)) ORDER BY s.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'sales', CASE p_obj_type WHEN 13 THEN 'revenue' ELSE 'sales_returns' END, l.item_code, l.whs_code) AS acct,
                   sum(l.line_total) AS net FROM erp.document_line l
             WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry GROUP BY 1 HAVING sum(l.line_total) <> 0) s), '[]'::jsonb);
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
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
               WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
      v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'cogs', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
               WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
    END IF;
  END IF;

  v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s · %s', v_name, v_ref, coalesce(d.card_name, d.card_code)), v_lines,
    jsonb_build_object('trans_type', p_obj_type, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                       'due_date', d.due_date, 'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                       'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
  RETURN v_trans;
END $$;

-- ---- _count_post: copied from 22_inventory.sql:2012. B3: stock and count variance accounts per line (item group, warehouse).
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
    -- Accounts per line (the item's group, the count's warehouse); grouped so one account gives one journal line.
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.count_acct (dir integer, stock text, vacct text, val numeric) ON COMMIT DROP;
    DELETE FROM pg_temp.count_acct;
    INSERT INTO pg_temp.count_acct
    SELECT CASE WHEN (cl->>'value')::numeric > 0 THEN 1 ELSE -1 END,
           erp._gl_item_acct(p_company, 'inventory', 'inventory', cl->>'item_code', c.whs_code),
           erp._gl_item_acct(p_company, 'inventory', 'count_variance', cl->>'item_code', c.whs_code), abs((cl->>'value')::numeric)
      FROM jsonb_array_elements(e->'lines') cl WHERE coalesce((cl->>'value')::numeric, 0) <> 0;
    IF v_gain > 0 THEN
      v_lines := v_lines || coalesce((SELECT jsonb_agg(jsonb_build_object('acct_code', stock, 'debit', amt, 'memo', 'Count gains') ORDER BY stock)
                                        FROM (SELECT stock, sum(val) AS amt FROM pg_temp.count_acct WHERE dir = 1 GROUP BY stock) s), '[]'::jsonb)
                         || coalesce((SELECT jsonb_agg(jsonb_build_object('acct_code', vacct, 'credit', amt, 'memo', 'Count gains') ORDER BY vacct)
                                        FROM (SELECT vacct, sum(val) AS amt FROM pg_temp.count_acct WHERE dir = 1 GROUP BY vacct) s), '[]'::jsonb);
    END IF;
    IF v_loss > 0 THEN
      v_lines := v_lines || coalesce((SELECT jsonb_agg(jsonb_build_object('acct_code', vacct, 'debit', amt, 'memo', 'Count losses') ORDER BY vacct)
                                        FROM (SELECT vacct, sum(val) AS amt FROM pg_temp.count_acct WHERE dir = -1 GROUP BY vacct) s), '[]'::jsonb)
                         || coalesce((SELECT jsonb_agg(jsonb_build_object('acct_code', stock, 'credit', amt, 'memo', 'Count losses') ORDER BY stock)
                                        FROM (SELECT stock, sum(val) AS amt FROM pg_temp.count_acct WHERE dir = -1 GROUP BY stock) s), '[]'::jsonb);
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

-- ---- _inv_eval: copied from 31_approvals.sql:1511. B3: a reason with no account uses its G/L determination key.
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
      -- B3: a reason without an account uses its G/L determination key (warehouse → company default).
      v_acct := coalesce(v_acct, rs.acct_code, CASE WHEN rs.gl_key IS NOT NULL THEN erp.gl_account(p_company, rs.gl_area, rs.gl_key, false, NULL::integer, v_whs) END);
    END IF;
  END IF;

  IF v_acct IS NULL THEN
    IF v_rcode IS NOT NULL AND rs.code IS NOT NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'acct_code', 'message',
        CASE WHEN rs.gl_key IS NOT NULL THEN format('Reason %s has no account, and G/L account for ''%s'' is not set for %s. Choose the account, or ask Finance to set it in Setup › Financials › G/L Account Determination.', rs.name, (SELECT label FROM erp.gl_posting_key WHERE area = rs.gl_area AND posting_key = rs.gl_key), p_company)
             ELSE format('Reason %s has no account. Choose the account, or ask Finance to set one in Inventory Setup.', rs.name) END);
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
    FOR r IN SELECT * FROM erp._apr_rules(p_company, p_obj, ARRAY['stock_doc_amount'], p_position) LOOP
      CONTINUE WHEN NOT (v_total > 0 AND erp._apr_hit(r.conds, jsonb_build_object('amount', v_total)));
      v_checks := v_checks || (r.ck || jsonb_build_object('rule_code', 'stock_doc_amount', 'line', NULL, 'value', v_total, 'limit', r.limit_value,
        'message', CASE WHEN r.std THEN format('Value %s %s is above your limit of %s %s for %ss. %s approves it.', erp._money(v_total), v_cur, erp._money(r.limit_value), v_cur,
                                               v_noun, r.approver_name)
                        ELSE erp._apr_msg(format('Value %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds) END));
    END LOOP;
  END IF;

  RETURN jsonb_build_object('errors', v_err, 'checks', v_checks, 'lines', v_out,
    'header', jsonb_build_object('doc_date', v_date, 'whs_code', v_whs, 'whs_name', wh.name, 'bins', v_bins, 'reason_code', rs.code, 'reason_name', rs.name,
                                 'acct_code', v_acct, 'acct_name', ac.name, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('value', v_total, 'currency', v_cur));
END $$;

-- ---- _lc_eval: copied from 21_purchasing.sql:2314. B3: split method 'equal' (the same share for every line); each charge
-- carries the account it is credited to (its type's account, else landed cost clearing).
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
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END, 0);
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
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END, 0);
      IF j = v_last THEN
        v_a := v_amt - v_acc;                      -- the rounding remainder
      ELSE
        v_a := round(v_amt * v_b / v_sum, 2);
      END IF;
      v_acc := v_acc + v_a;
      v_allocs := v_allocs || jsonb_build_object('charge_no', k - 1, 'line_num', j, 'basis', v_b, 'amount', v_a);
    END LOOP;
    v_charges := v_charges || jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt,
                                                 'acct_code', coalesce(lc.acct_code, erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false)));
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

-- ---- landed_cost_create: copied from 30_numbering_company.sql:2099. B3: inventory and price difference per line (item group,
-- warehouse); the credit goes to each landed cost type's account (empty = landed cost clearing).
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
  -- B3: every account is checked before anything is written, in the same order as before: stock (per line), landed cost
  -- clearing (only when a type has no account of its own), price difference (per line with goods already sold).
  PERFORM erp._gl_item_acct(p_company, 'inventory', 'inventory', y->>'item_code', y->>'whs_code') FROM jsonb_array_elements(e->'lines') y;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'charges') ch WHERE ch->>'acct_code' IS NULL) THEN
    v_clr := erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing');
  END IF;
  IF v_tc > 0 THEN
    PERFORM erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code')
       FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0;
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
  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount, acct_code)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount, y.acct_code
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric, acct_code text);
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

  -- Stock share and sold share per line (the item's group, the receipt's warehouse); credit per landed cost type account.
  IF v_ti > 0 THEN
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt, 'memo', 'Landed costs on stock') ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', y->>'item_code', y->>'whs_code') AS acct, sum((y->>'to_inventory')::numeric) AS amt
              FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_inventory')::numeric <> 0 GROUP BY 1) a);
  END IF;
  IF v_tc > 0 THEN
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt, 'memo', 'Landed costs on goods already sold (price difference)') ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code') AS acct, sum((y->>'to_cogs')::numeric) AS amt
              FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0 GROUP BY 1) a);
  END IF;
  v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.first_charge)
    FROM (SELECT coalesce(ch->>'acct_code', v_clr) AS acct, sum((ch->>'amount')::numeric) AS amt, min((ch->>'charge_no')::integer) AS first_charge
            FROM jsonb_array_elements(e->'charges') ch GROUP BY 1) a);
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

-- ---- prod_order_receipt: copied from 28_production_service.sql:1212. B3: a resource without its own account is credited to
-- the resource absorption key (G/L Account Determination › Production).
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
  FOR r IN SELECT l.line_num, l.comp_code, l.base_qty, pr.unit, pr.unit_cost,
                  coalesce(pr.acct_code, erp.gl_account(p_company, 'resources', 'resource_cost', false)) AS acct_code, pr.name
             FROM erp.prod_order_line l JOIN erp.prod_resource pr ON pr.company_code = l.company_code AND pr.res_code = l.comp_code
            WHERE l.company_code = p_company AND l.order_id = p_order AND l.comp_kind = 'resource' ORDER BY l.line_num LOOP
    v_rq := round(r.base_qty * v_qty, 6);
    v_amt := round(v_rq * r.unit_cost, 2);
    IF v_amt > 0 AND r.acct_code IS NULL THEN
      RAISE EXCEPTION 'Resource % has a cost but no account, and the resource absorption account is not set. Ask Finance to set it in G/L Account Determination (Production).', r.comp_code USING ERRCODE = 'P0001';
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

-- ---- prod_resource_save: copied from 30_numbering_company.sql:2338. B3: a resource with a cost may leave its account empty
-- when the resource absorption key is set (its cost is credited there).
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
  IF v_cost > 0 AND v_acct IS NULL AND erp.gl_account(p_company, 'resources', 'resource_cost', false) IS NULL THEN
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

-- ============ 6. API: warehouses (Inventory › Setup › Warehouses) ============
-- Warehouses with their general data, bins, accounts (Financials readers only) and default numbering series.
CREATE OR REPLACE FUNCTION erp.warehouse_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  v_fin  boolean;
BEGIN
  u := erp._inv_guard(p_company, false);
  v_fin := erp.can_read('finance');
  RETURN jsonb_build_object(
    'company', p_company,
    'can_write', erp.can_write('inventory'),
    'can_series', erp.can_write('inventory') OR erp.can_write('admin'),
    'can_finance', erp.can_write('finance'),
    'can_read_finance', v_fin,
    'warehouses', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'whs_code', w.whs_code, 'name', w.name, 'branch_id', w.branch_id, 'classification', w.classification, 'city', w.city, 'country', w.country,
               'is_free_zone', w.is_free_zone, 'locked', w.locked, 'active', w.active, 'origin', coalesce(s.origin, 'sap'),
               'bins_enabled', coalesce(s.bins_enabled, false), 'stock_acct', CASE WHEN v_fin THEN s.stock_acct END,
               'items_in_stock', (SELECT count(*) FROM erp.stock_balance sb WHERE sb.company_code = w.company_code AND sb.whs_code = w.whs_code AND sb.on_hand <> 0),
               'bins', coalesce((SELECT jsonb_agg(jsonb_build_object('bin_code', b.bin_code, 'name', b.name, 'active', b.active,
                                   'qty', (SELECT coalesce(sum(bs.qty), 0) FROM erp.bin_stock bs WHERE bs.bin_id = b.bin_id)) ORDER BY b.bin_code)
                                   FROM erp.bin_location b WHERE b.company_code = w.company_code AND b.whs_code = w.whs_code), '[]'::jsonb),
               'series', coalesce((SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'series_id', d.series_id, 'name', a.name, 'prefix', a.prefix,
                                                                       'missing', a.series_id IS NULL) ORDER BY d.obj_type)
                                     FROM erp.warehouse_series_default d LEFT JOIN erp.doc_series_all a ON a.series_id = d.series_id
                                    WHERE d.company_code = w.company_code AND d.whs_code = w.whs_code), '[]'::jsonb),
               'accounts', CASE WHEN v_fin THEN coalesce((
                             SELECT jsonb_agg(jsonb_build_object('area', o.area, 'posting_key', o.posting_key, 'acct_code', o.acct_code, 'acct_name', ac.name))
                               FROM erp.gl_determination_whs o LEFT JOIN erp.account ac ON ac.company_code = o.company_code AND ac.acct_code = o.acct_code
                              WHERE o.company_code = w.company_code AND o.whs_code = w.whs_code), '[]'::jsonb) ELSE '[]'::jsonb END)
             ORDER BY w.whs_code)
        FROM erp.warehouse w
        LEFT JOIN erp.warehouse_setting s ON s.company_code = w.company_code AND s.whs_code = w.whs_code
       WHERE w.company_code = p_company), '[]'::jsonb),
    'doc_types', coalesce((
      SELECT jsonb_agg(jsonb_build_object('obj_type', t.obj_type, 'label', t.label, 'module', t.module,
               'series', coalesce((SELECT jsonb_agg(jsonb_build_object('series_id', a.series_id, 'name', a.name, 'prefix', a.prefix, 'whs_code', a.whs_code,
                                                                     'is_default', a.is_default, 'locked', a.locked OR NOT a.active) ORDER BY a.is_default DESC, a.name)
                                    FROM erp.doc_series_all a WHERE a.company_code = p_company AND a.obj_type = t.obj_type), '[]'::jsonb))
             ORDER BY t.sort)
        FROM erp._adm_doc_types() t
       WHERE t.module IN ('sales', 'purchase', 'inventory', 'production') AND t.obj_type NOT IN (4, 2001, 2002, 2003) AND erp._adm_doc_used(t.obj_type)), '[]'::jsonb),
    'keys', CASE WHEN v_fin THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('area', k.area, 'posting_key', k.posting_key, 'label', k.label, 'tab', k.tab,
                                          'default_acct', erp._gl_default(p_company, k.area, k.posting_key)) ORDER BY k.sort)
        FROM erp.gl_posting_key k WHERE k.ctx), '[]'::jsonb) ELSE '[]'::jsonb END);
END $$;

-- Create a Super ERP warehouse, or change the general data of one created here. Warehouses that came from SAP keep their
-- general data from SAP (bins, accounts and numbering can still be set). Inventory with full access.
-- p_whs: {whs_code, name, branch_id, classification, city, country, is_free_zone, locked, active, edit (true = change)}
CREATE OR REPLACE FUNCTION erp.warehouse_save(p_company varchar, p_whs jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  x       jsonb := coalesce(p_whs, '{}'::jsonb);
  v_code  text := upper(nullif(btrim(x->>'whs_code'), ''));
  v_name  text := nullif(btrim(x->>'name'), '');
  v_edit  boolean := coalesce((x->>'edit')::boolean, false);
  v_act   boolean := coalesce((x->>'active')::boolean, true);
  v_lock  boolean := coalesce((x->>'locked')::boolean, false);
  v_br    integer;
  v_cty   text := upper(nullif(btrim(x->>'country'), ''));
  old     erp.warehouse;
  v_orig  text;
BEGIN
  u := erp._inv_guard(p_company, true, 'set up warehouses');
  IF v_code IS NULL OR v_code !~ '^[A-Z0-9_-]{1,8}$' THEN
    RAISE EXCEPTION 'Enter a warehouse code of up to 8 letters, digits, dashes or underscores.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_code;
  IF FOUND AND NOT v_edit THEN
    RAISE EXCEPTION 'Warehouse % already exists in %. Open it to change it.', v_code, p_company USING ERRCODE = 'P0001';
  ELSIF NOT FOUND AND v_edit THEN
    RAISE EXCEPTION 'Warehouse % does not exist in company %.', v_code, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_edit THEN
    SELECT origin INTO v_orig FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_code;
    IF coalesce(v_orig, 'sap') <> 'erp' THEN
      RAISE EXCEPTION 'Warehouse % comes from SAP Business One. Change its general data in SAP until % goes live on Super ERP.', v_code, p_company
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the warehouse name.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(x->>'branch_id'), '') IS NOT NULL THEN
    IF btrim(x->>'branch_id') !~ '^\d{1,9}$' THEN
      RAISE EXCEPTION 'The branch must be a whole number.' USING ERRCODE = 'P0001';
    END IF;
    v_br := btrim(x->>'branch_id')::integer;
  END IF;
  IF v_cty IS NOT NULL AND v_cty !~ '^[A-Z]{2,3}$' THEN
    RAISE EXCEPTION 'Enter the country as a 2-letter code, e.g. AE.' USING ERRCODE = 'P0001';
  END IF;
  IF v_edit AND NOT v_act AND old.active
     AND EXISTS (SELECT 1 FROM erp.stock_balance WHERE company_code = p_company AND whs_code = v_code AND on_hand <> 0) THEN
    RAISE EXCEPTION 'Warehouse % still holds stock. Move it out before deactivating the warehouse.', v_code USING ERRCODE = 'P0001';
  END IF;
  IF v_edit THEN
    UPDATE erp.warehouse SET name = v_name, branch_id = v_br, classification = nullif(btrim(x->>'classification'), ''), city = nullif(btrim(x->>'city'), ''),
           country = v_cty, is_free_zone = coalesce((x->>'is_free_zone')::boolean, false), locked = v_lock, active = v_act
     WHERE company_code = p_company AND whs_code = v_code;
  ELSE
    INSERT INTO erp.warehouse (company_code, whs_code, name, branch_id, classification, city, country, is_free_zone, locked, active)
    VALUES (p_company, v_code, v_name, v_br, nullif(btrim(x->>'classification'), ''), nullif(btrim(x->>'city'), ''), v_cty,
            coalesce((x->>'is_free_zone')::boolean, false), v_lock, v_act);
    INSERT INTO erp.warehouse_setting (company_code, whs_code, allow_negative, origin, updated_by, updated_at)
    VALUES (p_company, v_code, false, 'erp', u.user_id, now())
    ON CONFLICT (company_code, whs_code) DO UPDATE SET origin = 'erp', updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_edit THEN 'warehouse_update' ELSE 'warehouse_create' END, 'warehouse', v_code,
          jsonb_build_object('before', CASE WHEN v_edit THEN to_jsonb(old) END, 'input', x - 'edit'));
  RETURN jsonb_build_object('whs_code', v_code, 'name', v_name, 'active', v_act, 'locked', v_lock, 'created', NOT v_edit);
END $$;

-- The default numbering series of a document type for documents of one warehouse (NULL clears). Used after the user's own
-- default and before the company default (see _series_take). Inventory or Administration with full access.
CREATE OR REPLACE FUNCTION erp.warehouse_series_set(p_company varchar, p_whs text, p_obj integer, p_series bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  ns     erp.doc_series_all;
  v_from bigint;
BEGIN
  u := erp._inv_guard(p_company, false);
  IF NOT (erp.can_write('inventory') OR erp.can_write('admin')) THEN
    RAISE EXCEPTION 'You have read-only access to Inventory. Ask the system admin for full access to set warehouse numbering.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = p_whs) THEN
    RAISE EXCEPTION 'Warehouse % does not exist in company %.', coalesce(p_whs, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF p_obj IS NULL OR NOT EXISTS (SELECT 1 FROM erp._adm_doc_types() WHERE obj_type = p_obj) THEN
    RAISE EXCEPTION 'Choose a document type.' USING ERRCODE = 'P0001';
  END IF;
  SELECT series_id INTO v_from FROM erp.warehouse_series_default WHERE company_code = p_company AND whs_code = p_whs AND obj_type = p_obj;
  IF p_series IS NULL THEN
    DELETE FROM erp.warehouse_series_default WHERE company_code = p_company AND whs_code = p_whs AND obj_type = p_obj;
  ELSE
    SELECT * INTO ns FROM erp.doc_series_all WHERE series_id = p_series;
    IF ns.series_id IS NULL OR ns.company_code <> p_company OR ns.obj_type <> p_obj THEN
      RAISE EXCEPTION 'Series % is not a % series of company %.', p_series, erp._adm_doc_label(p_obj), p_company USING ERRCODE = 'P0001';
    ELSIF ns.locked OR NOT ns.active THEN
      RAISE EXCEPTION '% series % is locked. Choose another series.', erp._adm_doc_label(p_obj), ns.name USING ERRCODE = 'P0001';
    ELSIF ns.whs_code IS NOT NULL AND ns.whs_code <> p_whs THEN
      RAISE EXCEPTION '% series % is for warehouse %, not %. Choose a series for % or one without a warehouse.', erp._adm_doc_label(p_obj), ns.name,
        ns.whs_code, p_whs, p_whs USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.warehouse_series_default (company_code, whs_code, obj_type, series_id, updated_by, updated_at)
    VALUES (p_company, p_whs, p_obj, p_series, u.user_id, now())
    ON CONFLICT (company_code, whs_code, obj_type) DO UPDATE SET series_id = EXCLUDED.series_id, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'warehouse_series_set', 'warehouse', p_whs,
          jsonb_build_object('obj_type', p_obj, 'from', v_from, 'to', p_series, 'series', ns.name));
  RETURN jsonb_build_object('whs_code', p_whs, 'obj_type', p_obj, 'series_id', p_series, 'name', ns.name);
END $$;

-- ============ 7. API: item groups (Inventory › Setup › Item Groups) ============
CREATE OR REPLACE FUNCTION erp.item_group_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  v_fin boolean;
BEGIN
  u := erp._inv_guard(p_company, false);
  v_fin := erp.can_read('finance');
  RETURN jsonb_build_object(
    'company', p_company,
    'can_write', erp.can_write('inventory'),
    'can_finance', erp.can_write('finance'),
    'can_read_finance', v_fin,
    'groups', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'group_code', g.group_code, 'name', g.name, 'origin', coalesce(s.origin, 'sap'), 'manage_method', coalesce(s.manage_method, 'none'),
               'warranty_months', wr.months, 'warranty_source', wr.source,
               'items', (SELECT count(*) FROM erp.item i WHERE i.company_code = g.company_code AND i.group_code = g.group_code),
               'accounts', CASE WHEN v_fin THEN coalesce((
                             SELECT jsonb_agg(jsonb_build_object('area', o.area, 'posting_key', o.posting_key, 'acct_code', o.acct_code, 'acct_name', ac.name))
                               FROM erp.gl_determination_group o LEFT JOIN erp.account ac ON ac.company_code = o.company_code AND ac.acct_code = o.acct_code
                              WHERE o.company_code = g.company_code AND o.group_code = g.group_code), '[]'::jsonb) ELSE '[]'::jsonb END)
             ORDER BY g.name)
        FROM erp.item_group g
        LEFT JOIN erp.item_group_setting s ON s.company_code = g.company_code AND s.group_code = g.group_code
        LEFT JOIN erp.warranty_rule wr ON wr.company_code = g.company_code AND wr.group_code = g.group_code AND wr.item_code IS NULL
       WHERE g.company_code = p_company), '[]'::jsonb),
    'keys', CASE WHEN v_fin THEN coalesce((
      SELECT jsonb_agg(jsonb_build_object('area', k.area, 'posting_key', k.posting_key, 'label', k.label, 'tab', k.tab,
                                          'default_acct', erp._gl_default(p_company, k.area, k.posting_key)) ORDER BY k.sort)
        FROM erp.gl_posting_key k WHERE k.ctx), '[]'::jsonb) ELSE '[]'::jsonb END);
END $$;

-- Create a Super ERP item group, or set an item group's management method and warranty. Inventory with full access.
-- p_group: {group_code (empty = new), name, manage_method (none | batch | serial), warranty_months (empty = none)}
-- Warranty months are A13's warranty_rule group row (service calls read it). The management method is the default for new
-- Super ERP items of the group; existing items keep theirs.
CREATE OR REPLACE FUNCTION erp.item_group_save(p_company varchar, p_group jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  x       jsonb := coalesce(p_group, '{}'::jsonb);
  v_code  integer;
  v_name  text := nullif(btrim(x->>'name'), '');
  v_m     text := coalesce(nullif(btrim(x->>'manage_method'), ''), 'none');
  v_w     integer;
  g       erp.item_group;
  s       erp.item_group_setting;
  v_new   boolean := nullif(btrim(x->>'group_code'), '') IS NULL;
  v_wold  integer;
BEGIN
  u := erp._inv_guard(p_company, true, 'set up item groups');
  IF v_m NOT IN ('none', 'batch', 'serial') THEN
    RAISE EXCEPTION 'Choose the management method: none, batch or serial.' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(btrim(x->>'warranty_months'), '') IS NOT NULL THEN
    IF btrim(x->>'warranty_months') !~ '^\d{1,3}$' OR btrim(x->>'warranty_months')::integer NOT BETWEEN 1 AND 240 THEN
      RAISE EXCEPTION 'Warranty must be a whole number of months between 1 and 240, or empty.' USING ERRCODE = 'P0001';
    END IF;
    v_w := btrim(x->>'warranty_months')::integer;
  END IF;
  IF v_new THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'Enter the item group name.' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND lower(name) = lower(v_name)) THEN
      RAISE EXCEPTION 'Item group % already exists in %.', v_name, p_company USING ERRCODE = 'P0001';
    END IF;
    SELECT greatest(900000, coalesce(max(group_code), 0) + 1) INTO v_code FROM erp.item_group WHERE company_code = p_company;
    INSERT INTO erp.item_group (company_code, group_code, name) VALUES (p_company, v_code, v_name) RETURNING * INTO g;
  ELSE
    IF btrim(x->>'group_code') !~ '^-?\d{1,9}$' THEN
      RAISE EXCEPTION 'Item group % does not exist in company %.', x->>'group_code', p_company USING ERRCODE = 'P0001';
    END IF;
    v_code := btrim(x->>'group_code')::integer;
    SELECT * INTO g FROM erp.item_group WHERE company_code = p_company AND group_code = v_code FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item group % does not exist in company %.', v_code, p_company USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO s FROM erp.item_group_setting WHERE company_code = p_company AND group_code = v_code;
    IF v_name IS NOT NULL AND v_name <> g.name THEN
      IF coalesce(s.origin, 'sap') <> 'erp' THEN
        RAISE EXCEPTION 'Item group % comes from SAP Business One. Change its name in SAP until % goes live on Super ERP.', g.name, p_company
          USING ERRCODE = 'P0001';
      END IF;
      IF EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND lower(name) = lower(v_name) AND group_code <> v_code) THEN
        RAISE EXCEPTION 'Item group % already exists in %.', v_name, p_company USING ERRCODE = 'P0001';
      END IF;
      UPDATE erp.item_group SET name = v_name WHERE company_code = p_company AND group_code = v_code;
    END IF;
  END IF;
  INSERT INTO erp.item_group_setting (company_code, group_code, manage_method, origin, updated_by, updated_at)
  VALUES (p_company, v_code, v_m, CASE WHEN v_new THEN 'erp' ELSE 'sap' END, u.user_id, now())
  ON CONFLICT (company_code, group_code) DO UPDATE SET manage_method = EXCLUDED.manage_method, updated_by = EXCLUDED.updated_by, updated_at = now();

  SELECT months INTO v_wold FROM erp.warranty_rule WHERE company_code = p_company AND group_code = v_code AND item_code IS NULL;
  IF v_w IS NULL THEN
    DELETE FROM erp.warranty_rule WHERE company_code = p_company AND group_code = v_code AND item_code IS NULL;
  ELSE
    UPDATE erp.warranty_rule SET months = v_w, updated_by = u.user_id, updated_at = now()
     WHERE company_code = p_company AND group_code = v_code AND item_code IS NULL;
    IF NOT FOUND THEN
      INSERT INTO erp.warranty_rule (company_code, group_code, months, source, updated_by) VALUES (p_company, v_code, v_w, 'erp', u.user_id);
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_new THEN 'item_group_create' ELSE 'item_group_update' END, 'item_group', v_code::text,
          jsonb_build_object('name', coalesce(v_name, g.name), 'manage_method', jsonb_build_object('from', s.manage_method, 'to', v_m),
                             'warranty_months', jsonb_build_object('from', v_wold, 'to', v_w)));
  RETURN jsonb_build_object('group_code', v_code, 'name', coalesce(v_name, g.name), 'manage_method', v_m, 'warranty_months', v_w, 'created', v_new);
END $$;

-- New Super ERP items in a batch / serial group start with that management method (unless the item says otherwise).
CREATE OR REPLACE FUNCTION erp._item_group_method() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v text;
BEGIN
  IF NEW.source = 'erp' AND NOT NEW.batch_managed AND NOT NEW.serial_managed AND NEW.group_code IS NOT NULL THEN
    SELECT manage_method INTO v FROM erp.item_group_setting WHERE company_code = NEW.company_code AND group_code = NEW.group_code;
    IF v = 'batch' THEN NEW.batch_managed := true; ELSIF v = 'serial' THEN NEW.serial_managed := true; END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS item_group_method ON erp.item;
CREATE TRIGGER item_group_method BEFORE INSERT ON erp.item FOR EACH ROW EXECUTE FUNCTION erp._item_group_method();

-- ============ 8. API: landed cost types (Purchasing › Setup › Landed Costs) ============
CREATE OR REPLACE FUNCTION erp.landed_cost_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._pd_guard(p_company, false);
  RETURN jsonb_build_object(
    'company', p_company,
    'can_write', erp.can_write('purchase') OR erp.can_write('finance'),
    'can_finance', erp.can_write('finance'),
    'clearing_acct', erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false),
    'price_difference_acct', erp.gl_account(p_company, 'inventory', 'price_difference', false),
    'methods', to_jsonb(ARRAY['qty', 'weight', 'cbm', 'value', 'equal']),
    'codes', coalesce((SELECT jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'split_method', c.split_method, 'acct_code', c.acct_code,
                                                           'acct_name', a.name, 'active', c.active, 'source', c.source, 'updated_at', c.updated_at,
                                                           'used', EXISTS (SELECT 1 FROM erp.landed_cost_charge ch WHERE ch.company_code = c.company_code AND ch.code = c.code))
                                        ORDER BY c.code)
                         FROM erp.landed_cost_code c LEFT JOIN erp.account a ON a.company_code = c.company_code AND a.acct_code = c.acct_code
                        WHERE c.company_code = p_company), '[]'::jsonb));
END $$;

-- Add or change a landed cost type (replaces 21's). Purchasing or Financials with full access; the account also needs
-- Financials full. Codes that came from SAP are read-only.
-- p_code: {code, name, split_method (qty | quantity, weight, cbm | volume, value, equal), acct_code ('' = landed cost
--          clearing from G/L Account Determination; left out = unchanged), active}
CREATE OR REPLACE FUNCTION erp.landed_cost_code_save(p_company varchar, p_code jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  c      jsonb := coalesce(p_code, '{}'::jsonb);
  v_code text := upper(nullif(btrim(c->>'code'), ''));
  v_name text := nullif(btrim(c->>'name'), '');
  v_m    text := lower(nullif(btrim(c->>'split_method'), ''));
  v_act  boolean := coalesce((c->>'active')::boolean, true);
  v_acct text;
  v_msg  text;
  old    erp.landed_cost_code;
BEGIN
  u := erp._pd_guard(p_company, true, 'change landed cost codes', true);
  IF v_code IS NULL OR v_code !~ '^[A-Z0-9_-]{1,20}$' THEN
    RAISE EXCEPTION 'Enter a code of up to 20 letters, digits, - or _.' USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter a name for landed cost %.', v_code USING ERRCODE = 'P0001';
  END IF;
  v_m := CASE v_m WHEN 'quantity' THEN 'qty' WHEN 'volume' THEN 'cbm' ELSE v_m END;
  IF v_m IS NULL OR v_m NOT IN ('cbm', 'qty', 'value', 'weight', 'equal') THEN
    RAISE EXCEPTION 'Choose how % is split: quantity, weight, volume (CBM), value or equal.', v_code USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.landed_cost_code WHERE company_code = p_company AND code = v_code;
  IF old.source = 'sap' THEN
    RAISE EXCEPTION 'Landed cost % came from SAP Business One, so it is read-only in Super ERP.', v_code USING ERRCODE = 'P0001';
  END IF;
  v_acct := CASE WHEN c ? 'acct_code' THEN nullif(btrim(c->>'acct_code'), '') ELSE old.acct_code END;
  IF v_acct IS DISTINCT FROM old.acct_code THEN
    IF NOT erp.can_write('finance') THEN
      RAISE EXCEPTION 'Changing the account of a landed cost type also needs Financials full access.' USING ERRCODE = '42501';
    END IF;
    IF v_acct IS NOT NULL THEN
      v_msg := erp._gl_acct_problem(p_company, v_acct, false, true);
      IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'Landed cost %: %', v_code, v_msg USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END IF;
  INSERT INTO erp.landed_cost_code (company_code, code, name, split_method, acct_code, active, source, updated_by, updated_at)
  VALUES (p_company, v_code, v_name, v_m, v_acct, v_act, 'erp', u.user_id, now())
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, split_method = EXCLUDED.split_method, acct_code = EXCLUDED.acct_code,
                                                 active = EXCLUDED.active, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'landed_cost_code_save', 'landed_cost_code', v_code,
          jsonb_build_object('from', CASE WHEN old.code IS NOT NULL THEN jsonb_build_object('name', old.name, 'split_method', old.split_method, 'active', old.active,
                                                                                            'acct_code', old.acct_code) END,
                             'to', jsonb_build_object('name', v_name, 'split_method', v_m, 'active', v_act, 'acct_code', v_acct)));
  RETURN jsonb_build_object('code', v_code, 'name', v_name, 'split_method', v_m, 'active', v_act, 'acct_code', v_acct);
END $$;

-- ============ 9. Goods receipt / issue reasons ============
-- The standard reasons of a company (decisions §3): each mapped to a G/L determination key, no account of its own.
CREATE OR REPLACE FUNCTION erp._seed_std_reasons(p_company varchar) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_n integer;
BEGIN
  INSERT INTO erp.inventory_reason (company_code, code, name, direction, acct_code, gl_area, gl_key, source, note)
  SELECT p_company, v.code, v.name, v.dir, NULL, v.area, v.k, 'erp', 'Standard reason. The account comes from G/L Account Determination.'
    FROM (VALUES ('DAMAGE', 'Damaged goods', 'out', 'inventory', 'write_off'),
                 ('SAMPLE', 'Samples', 'out', 'inventory', 'samples'),
                 ('INTERNAL', 'Internal use', 'out', 'inventory', 'internal_use'),
                 ('WRITEOFF', 'Write-off', 'out', 'inventory', 'write_off'),
                 ('FOUND', 'Found stock', 'in', 'inventory', 'offset_increase'),
                 ('OPENING', 'Opening stock', 'in', 'general', 'opening_balances'),
                 ('SERVICE', 'Service spare parts', 'out', 'service', 'spare_parts')) AS v(code, name, dir, area, k)
  ON CONFLICT (company_code, code) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION erp._company_std_reasons() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF NEW.company_code NOT LIKE 'ZZ%' THEN      -- ZZ.. = sample and test companies
    PERFORM erp._seed_std_reasons(NEW.company_code);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS company_std_reasons ON erp.company;
CREATE TRIGGER company_std_reasons AFTER INSERT ON erp.company FOR EACH ROW EXECUTE FUNCTION erp._company_std_reasons();

SELECT erp._seed_std_reasons(company_code) FROM erp.company WHERE company_code IN ('AE01', 'AE02', 'AE03', 'AE04', 'AE05');

-- ZZ99 SAMPLE reasons keep their accounts; they get the matching key too.
UPDATE erp.inventory_reason r SET gl_area = v.area, gl_key = v.k
  FROM (VALUES ('FOUND', 'inventory', 'offset_increase'), ('DAMAGE', 'inventory', 'write_off'), ('SAMPLE', 'inventory', 'samples'),
               ('SERVICE', 'service', 'spare_parts')) AS v(code, area, k)
 WHERE r.company_code = 'ZZ99' AND r.code = v.code AND r.gl_key IS NULL;

-- Goods receipt / issue reasons (replaces 22's): + the G/L determination key. Financials with full access.
-- p_reason: {code, name, direction ('in' | 'out' | 'both'), acct_code, gl_key ('area/key', '' = none), active}
CREATE OR REPLACE FUNCTION erp.inventory_reason_save(p_company varchar, p_reason jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  old    erp.inventory_reason;
  v_code text := upper(nullif(btrim(p_reason->>'code'), ''));
  v_name text := nullif(btrim(p_reason->>'name'), '');
  v_dir  text := coalesce(nullif(btrim(p_reason->>'direction'), ''), 'both');
  v_acct text := nullif(btrim(p_reason->>'acct_code'), '');
  v_key  text;
  v_area text;
  v_k    text;
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
  SELECT * INTO old FROM erp.inventory_reason WHERE company_code = p_company AND code = v_code;
  IF p_reason ? 'gl_key' THEN
    v_key := nullif(btrim(p_reason->>'gl_key'), '');
    IF v_key IS NOT NULL THEN
      v_area := split_part(v_key, '/', 1);
      v_k := split_part(v_key, '/', 2);
      IF NOT EXISTS (SELECT 1 FROM erp.gl_posting_key WHERE area = v_area AND posting_key = v_k) THEN
        RAISE EXCEPTION 'Choose a G/L Account Determination key that exists for reason %.', v_code USING ERRCODE = 'P0001';
      END IF;
    END IF;
  ELSE
    v_area := old.gl_area;
    v_k := old.gl_key;
  END IF;
  INSERT INTO erp.inventory_reason (company_code, code, name, direction, acct_code, gl_area, gl_key, active, source, updated_by, updated_at)
  VALUES (p_company, v_code, v_name, v_dir, v_acct, v_area, v_k, coalesce((p_reason->>'active')::boolean, true), 'erp', u.user_id, now())
  ON CONFLICT (company_code, code) DO UPDATE SET name = EXCLUDED.name, direction = EXCLUDED.direction, acct_code = EXCLUDED.acct_code,
    gl_area = EXCLUDED.gl_area, gl_key = EXCLUDED.gl_key, active = EXCLUDED.active, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'inventory_reason_save', 'inventory_reason', v_code,
          jsonb_build_object('name', v_name, 'direction', v_dir, 'acct_code', v_acct, 'gl_key', CASE WHEN v_k IS NOT NULL THEN v_area || '/' || v_k END,
                             'before', CASE WHEN old.code IS NOT NULL THEN jsonb_build_object('acct_code', old.acct_code, 'gl_key', old.gl_area || '/' || old.gl_key,
                                                                                              'active', old.active) END));
  RETURN jsonb_build_object('code', v_code, 'name', v_name, 'direction', v_dir, 'acct_code', v_acct,
                            'gl_key', CASE WHEN v_k IS NOT NULL THEN v_area || '/' || v_k END);
END $$;

-- ============ 10. Bank statements: saved column mapping, matching rule ============
-- Save the CSV column mapping of a house bank account (Banking or Financials with full access).
-- p_mapping: {mode ('amount' | 'split'), date, amount, debit, credit, reference, description, date_format, decimal_sep ('.' | ',')}
CREATE OR REPLACE FUNCTION erp.bank_statement_format_save(p_company varchar, p_bank_code text, p_mapping jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u    erp.app_user;
  m    jsonb := coalesce(p_mapping, '{}'::jsonb);
  v_mode text := coalesce(nullif(m->>'mode', ''), 'amount');
  k    text;
  v_out jsonb;
BEGIN
  u := erp._bk_guard(p_company, true, 'save bank statement formats');
  IF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = p_bank_code AND kind = 'bank') THEN
    RAISE EXCEPTION 'Choose a bank account of company % for the format.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_mode NOT IN ('amount', 'split') THEN
    RAISE EXCEPTION 'Choose one amount column or separate debit and credit columns.' USING ERRCODE = 'P0001';
  END IF;
  FOREACH k IN ARRAY ARRAY['date', 'amount', 'debit', 'credit', 'reference', 'description'] LOOP
    IF length(coalesce(m->>k, '')) > 100 THEN
      RAISE EXCEPTION 'Column names can have at most 100 characters.' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  IF nullif(btrim(m->>'date'), '') IS NULL THEN
    RAISE EXCEPTION 'Choose the date column.' USING ERRCODE = 'P0001';
  ELSIF v_mode = 'amount' AND nullif(btrim(m->>'amount'), '') IS NULL THEN
    RAISE EXCEPTION 'Choose the amount column.' USING ERRCODE = 'P0001';
  ELSIF v_mode = 'split' AND (nullif(btrim(m->>'debit'), '') IS NULL OR nullif(btrim(m->>'credit'), '') IS NULL) THEN
    RAISE EXCEPTION 'Choose the debit and the credit columns.' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(m->>'date_format', 'DD/MM/YYYY') NOT IN ('YYYY-MM-DD', 'DD/MM/YYYY', 'MM/DD/YYYY', 'DD-MM-YYYY', 'DD.MM.YYYY') THEN
    RAISE EXCEPTION 'Choose a date format from the list.' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(m->>'decimal_sep', '.') NOT IN ('.', ',') THEN
    RAISE EXCEPTION 'The decimal separator is a dot or a comma.' USING ERRCODE = 'P0001';
  END IF;
  v_out := jsonb_build_object('mode', v_mode, 'date', btrim(m->>'date'), 'amount', nullif(btrim(m->>'amount'), ''), 'debit', nullif(btrim(m->>'debit'), ''),
                              'credit', nullif(btrim(m->>'credit'), ''), 'reference', nullif(btrim(m->>'reference'), ''),
                              'description', nullif(btrim(m->>'description'), ''), 'date_format', coalesce(m->>'date_format', 'DD/MM/YYYY'),
                              'decimal_sep', coalesce(m->>'decimal_sep', '.'));
  INSERT INTO erp.bank_statement_format (company_code, bank_code, mapping, updated_by, updated_at) VALUES (p_company, p_bank_code, v_out, u.user_id, now())
  ON CONFLICT (company_code, bank_code) DO UPDATE SET mapping = EXCLUDED.mapping, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bank_statement_format_save', 'bank_account', p_bank_code, v_out);
  RETURN v_out;
END $$;

-- A reference as compared by the matching rule: letters and digits only, upper case.
CREATE OR REPLACE FUNCTION erp._bk_norm_ref(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Every reference a journal can be recognised by on a bank statement: its references, the payment number, the transfer and
-- card references, and the cheque numbers of the payment or the deposit. Internal.
CREATE OR REPLACE FUNCTION erp._bk_jl_refs(p_company varchar, p_trans integer) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(array_agg(DISTINCT r) FILTER (WHERE r <> ''), '{}') FROM (
    SELECT erp._bk_norm_ref(unnest(ARRAY[j.ref1, j.ref2, j.ref3, j.base_ref])) AS r
      FROM erp.journal_entry j WHERE j.company_code = p_company AND j.trans_id = p_trans
    UNION ALL
    SELECT erp._bk_norm_ref(unnest(ARRAY[x.doc_no, x.transfer_ref, x.card_ref]))
      FROM erp.document_posting dp
      JOIN erp.payment_extra x ON x.company_code = dp.company_code AND x.direction = CASE dp.obj_type WHEN 24 THEN 'I' ELSE 'O' END AND x.doc_entry = dp.doc_entry
     WHERE dp.company_code = p_company AND dp.trans_id = p_trans AND dp.obj_type IN (24, 46)
    UNION ALL
    SELECT erp._bk_norm_ref(c.cheque_no)
      FROM erp.document_posting dp
      JOIN erp.payment_cheque c ON c.company_code = dp.company_code AND c.direction = CASE dp.obj_type WHEN 24 THEN 'I' ELSE 'O' END AND c.doc_entry = dp.doc_entry
     WHERE dp.company_code = p_company AND dp.trans_id = p_trans AND dp.obj_type IN (24, 46)
    UNION ALL
    SELECT erp._bk_norm_ref(unnest(ARRAY[d.doc_no] || coalesce((SELECT array_agg(c.cheque_no) FROM erp.payment_cheque c WHERE c.deposit_id = d.deposit_id), '{}')))
      FROM erp.document_posting dp JOIN erp.deposit d ON d.deposit_id = dp.doc_entry
     WHERE dp.company_code = p_company AND dp.trans_id = p_trans AND dp.obj_type = 25) s
$$;

-- Does a statement reference fit a journal's references? No statement reference = yes (the amount and date decide).
CREATE OR REPLACE FUNCTION erp._bk_ref_ok(p_stmt_ref text, p_refs text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT erp._bk_norm_ref(p_stmt_ref) = '' OR EXISTS (
    SELECT 1 FROM unnest(p_refs) r
     WHERE r = erp._bk_norm_ref(p_stmt_ref)
        OR (length(r) >= 4 AND position(r IN erp._bk_norm_ref(p_stmt_ref)) > 0)
        OR (length(erp._bk_norm_ref(p_stmt_ref)) >= 4 AND position(erp._bk_norm_ref(p_stmt_ref) IN r) > 0))
$$;

-- Auto-match (replaces 20's; decisions §3): a statement line takes the one open journal line on the bank's G/L account with
-- exactly the same amount, dated within ± banking_setting.match_days (empty = 3 days), and – when the statement line has a
-- reference or cheque number – a matching reference, payment number or cheque number. Anything else stays for manual
-- matching. Running it again adds nothing.
CREATE OR REPLACE FUNCTION erp.bank_statement_auto_match(p_company varchar, p_statement_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  s       erp.bank_statement;
  v_acct  text;
  v_days  integer;
  l       record;
  c       record;
  v_cnt   integer;
  v_t     integer;
  v_l     integer;
  v_date  date;
  v_done  integer := 0;
  v_left  integer;
BEGIN
  u := erp._bk_guard(p_company, true, 'reconcile bank statements');
  SELECT * INTO s FROM erp.bank_statement WHERE company_code = p_company AND statement_id = p_statement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank statement % was not found in company %.', p_statement_id, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT acct_code INTO v_acct FROM erp.bank_account WHERE company_code = p_company AND bank_code = s.bank_code;
  v_days := coalesce((SELECT match_days FROM erp.banking_setting WHERE company_code = p_company), 3);
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.bk_open (trans_id integer, line_id integer, ref_date date, amount numeric, refs text[]) ON COMMIT DROP;
  DELETE FROM pg_temp.bk_open;
  INSERT INTO pg_temp.bk_open SELECT j.trans_id, j.line_id, j.ref_date, j.amount, erp._bk_jl_refs(p_company, j.trans_id) FROM erp._bk_open_jl(p_company, v_acct) j;
  FOR l IN SELECT sl.* FROM erp.bank_statement_line sl
            WHERE sl.statement_id = p_statement_id AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = sl.line_id)
            ORDER BY sl.line_no LOOP
    SELECT count(*), min(o.trans_id), min(o.line_id) INTO v_cnt, v_t, v_l
      FROM pg_temp.bk_open o
     WHERE o.amount = l.amount AND o.ref_date BETWEEN l.value_date - v_days AND l.value_date + v_days AND erp._bk_ref_ok(l.reference, o.refs)
       AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.company_code = p_company AND m.trans_id = o.trans_id AND m.jl_line_id = o.line_id);
    CONTINUE WHEN v_cnt <> 1;
    SELECT * INTO c FROM pg_temp.bk_open o WHERE o.trans_id = v_t AND o.line_id = v_l;
    -- One candidate journal line, and no other unmatched line of this statement could take it either.
    IF (SELECT count(*) FROM erp.bank_statement_line x
         WHERE x.statement_id = p_statement_id AND x.amount = l.amount AND x.value_date BETWEEN c.ref_date - v_days AND c.ref_date + v_days
           AND erp._bk_ref_ok(x.reference, c.refs)
           AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = x.line_id)) = 1 THEN
      INSERT INTO erp.bank_match (company_code, match_no, statement_line_id, trans_id, jl_line_id, amount, how, matched_by)
      VALUES (p_company, nextval('erp.erp_match_no_seq'), l.line_id, v_t, v_l, l.amount, 'auto', u.user_id);
      v_done := v_done + 1;
    END IF;
  END LOOP;
  SELECT count(*) INTO v_left FROM erp.bank_statement_line sl
   WHERE sl.statement_id = p_statement_id AND NOT EXISTS (SELECT 1 FROM erp.bank_match m WHERE m.statement_line_id = sl.line_id);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bank_statement_auto_match', 'bank_statement', p_statement_id::text,
          jsonb_build_object('matched', v_done, 'unmatched', v_left, 'window_days', v_days, 'reference_rule', true));
  RETURN jsonb_build_object('matched', v_done, 'unmatched', v_left, 'window_days', v_days);
END $$;

-- Who matched, unmatched or auto-matched what on a statement (the audit rows), newest first.
CREATE OR REPLACE FUNCTION erp.bank_statement_activity(p_company varchar, p_statement_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._bk_guard(p_company, false);
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                                    ORDER BY l.at DESC, l.audit_id DESC)
                     FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                    WHERE l.company_code = p_company AND l.object = 'bank_statement' AND l.object_ref = p_statement_id::text), '[]'::jsonb);
END $$;


-- ============ 12. Numbering: warehouse default series ============
-- ---- _series_take: copied from 30_numbering_company.sql:246. B3: after the user's default comes the warehouse's default
-- series (when the document names a warehouse), then the company default.
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
  -- B3: the warehouse's default series for this document type (Inventory › Setup › Warehouses › Numbering).
  IF ns.series_id IS NULL AND v_whs IS NOT NULL THEN
    SELECT d.series_id INTO v_id FROM erp.warehouse_series_default d WHERE d.company_code = p_company AND d.whs_code = v_whs AND d.obj_type = p_obj;
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

-- ---- _health_files: copied from 31_approvals.sql:4315 + 32_gl_setup.sql (marker gl_setup).
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health'),
    ('30_numbering_company.sql', 'doc_series_save'), ('31_approvals.sql', 'approval_template_save'),
    ('32_gl_setup.sql', 'gl_setup')
  ) AS v(file_name, object)
$$;

-- ============ 13. Grants ============
REVOKE ALL ON FUNCTION erp._gl_default(varchar, text, text), erp.gl_account(varchar, text, text, boolean, integer, text),
  erp._gl_item_acct(varchar, text, text, text, text), erp._gl_acct_problem(varchar, text, boolean, boolean),
  erp._gl_set_one(erp.app_user, varchar, text, text, text, text, text, boolean), erp._item_group_method(), erp._seed_std_reasons(varchar),
  erp._company_std_reasons(), erp._bk_norm_ref(text), erp._bk_jl_refs(varchar, integer), erp._bk_ref_ok(text, text[])
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.gl_setup(varchar), erp.gl_determination_save(varchar, jsonb), erp.gl_override_save(varchar, text, text, jsonb),
  erp.warehouse_setup(varchar), erp.warehouse_save(varchar, jsonb), erp.warehouse_series_set(varchar, text, integer, bigint),
  erp.item_group_setup(varchar), erp.item_group_save(varchar, jsonb), erp.landed_cost_setup(varchar), erp.landed_cost_code_save(varchar, jsonb),
  erp.inventory_reason_save(varchar, jsonb), erp.gl_determination_set(varchar, text, text, text),
  erp.bank_statement_format_save(varchar, text, jsonb), erp.bank_statement_auto_match(varchar, integer), erp.bank_statement_activity(varchar, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.gl_setup(varchar), erp.gl_determination_save(varchar, jsonb), erp.gl_override_save(varchar, text, text, jsonb),
  erp.warehouse_setup(varchar), erp.warehouse_save(varchar, jsonb), erp.warehouse_series_set(varchar, text, integer, bigint),
  erp.item_group_setup(varchar), erp.item_group_save(varchar, jsonb), erp.landed_cost_setup(varchar), erp.landed_cost_code_save(varchar, jsonb),
  erp.inventory_reason_save(varchar, jsonb), erp.gl_determination_set(varchar, text, text, text),
  erp.bank_statement_format_save(varchar, text, jsonb), erp.bank_statement_auto_match(varchar, integer), erp.bank_statement_activity(varchar, integer)
  TO authenticated;
