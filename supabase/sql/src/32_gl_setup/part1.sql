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
