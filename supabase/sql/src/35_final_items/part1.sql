-- B6 · Last open items: the landed cost vendor per cost line (broker on the header), the system currency and Conversion
-- Differences. Safe to run twice. Does not edit 10–34: earlier behaviour is changed here with CREATE OR REPLACE, keeping
-- the earlier tests passing.
--
-- GENERATED from supabase/sql/src/35_final_items (part1/2.sql + asserted patches of earlier functions in build.py).
-- Edit the sources and run `python3 supabase/sql/src/35_final_items/build.py`; `--check` verifies the committed file.
--
-- Sections
--   1. Landed costs: vendor per cost line (SAP B1: Broker on the header, Vendor on each cost line)
--   2. System currency per company (Administration › Company Details; default = local currency = inactive)
--   3. Journals carry system currency amounts (post_journal, _reverse_journal)
--   4. Conversion Differences (Financials › Exchange Rates and Revaluation › Conversion Differences)
--   5. Grants
--
-- Nothing company-specific is seeded for AE01–AE05: their system currency stays the local currency (inactive) until Sanford
-- decides. ZZ99 gets a SAMPLE conversion difference account (7120) only; its system currency also stays inactive on the
-- shared database (the tests switch on the SAMPLE USD system currency themselves, because every posting date then needs a
-- USD rate).

-- ============ 1. Landed costs: vendor per cost line ============
-- landed_cost.card_code stays the broker (header). Each cost line may name its vendor (a supplier); a vendor with a fixed
-- currency takes charges in that currency or LC. A linked A/P invoice must be the vendor's (else the broker's, B5), and an
-- unnamed vendor becomes the linked invoice's supplier. The rate difference between the landed cost and that invoice is
-- posted as B4/B5 do (purchasing / fx_loss, sales / fx_gain).
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS card_code varchar(15);

-- ============ 2. System currency per company ============
-- SAP Business One keeps a system currency next to the local currency. Here it is optional: no row (or the local currency)
-- means inactive, and journals carry no system currency amounts. An active system currency is fixed once Super ERP journal
-- lines carry amounts in it (SAP B1 does the same). Read = Administration (admin / IT / owner); write = Administration full;
-- audited.
CREATE TABLE IF NOT EXISTS erp.system_currency_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    currency       varchar(3) NOT NULL,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE erp.system_currency_setting ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.system_currency_setting FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.system_currency_setting TO authenticated;
DROP POLICY IF EXISTS system_currency_setting_read ON erp.system_currency_setting;
CREATE POLICY system_currency_setting_read ON erp.system_currency_setting FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- The active system currency of a company, or NULL (= the local currency, inactive).
CREATE OR REPLACE FUNCTION erp._sys_cur(p_company varchar) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT s.currency::text FROM erp.system_currency_setting s JOIN erp.company c ON c.company_code = s.company_code
   WHERE s.company_code = p_company AND s.currency <> c.currency
$$;

-- Super ERP journal lines that carry system currency amounts (they fix the system currency).
CREATE OR REPLACE FUNCTION erp._sys_cur_used(p_company varchar) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT count(DISTINCT l.trans_id) FROM erp.journal_line l JOIN erp.journal_entry j ON j.company_code = l.company_code AND j.trans_id = l.trans_id
   WHERE l.company_code = p_company AND j.source = 'erp' AND (l.sys_debit IS NOT NULL OR l.sys_credit IS NOT NULL)
$$;

CREATE OR REPLACE FUNCTION erp.system_currency_info(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
  c  erp.company := erp._adm_company(p_company);
  s  erp.system_currency_setting;
  v_sc text := erp._sys_cur(p_company);
  v_used bigint := erp._sys_cur_used(p_company);
BEGIN
  SELECT * INTO s FROM erp.system_currency_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'company_code', p_company, 'local_currency', c.currency, 'system_currency', coalesce(v_sc, c.currency), 'active', v_sc IS NOT NULL,
    'currencies', to_jsonb(erp._cur_list(p_company)), 'can_write', erp.can_write('admin'), 'locked', v_sc IS NOT NULL AND v_used > 0, 'journals', v_used,
    'rate_today', CASE WHEN v_sc IS NOT NULL THEN erp._cur_rate(p_company, v_sc, current_date) END,
    'updated_by_name', erp._adm_name(s.updated_by), 'updated_at', s.updated_at);
END $$;

-- Set the system currency (the local currency = switch it off). p_currency: 3 letters.
CREATE OR REPLACE FUNCTION erp.system_currency_save(p_company varchar, p_currency text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  c      erp.company := erp._adm_company(p_company);
  v_new  text := upper(nullif(btrim(p_currency), ''));
  v_old  text := coalesce(erp._sys_cur(p_company), c.currency);
  v_used bigint;
BEGIN
  IF v_new IS NULL THEN
    RAISE EXCEPTION 'Choose the system currency.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new <> c.currency AND NOT v_new = ANY (erp._cur_list(p_company)) THEN
    RAISE EXCEPTION 'Currency % is not in the rates list of % (%).', v_new, p_company, array_to_string(erp._cur_list(p_company), ', ') USING ERRCODE = 'P0001';
  END IF;
  IF v_new = v_old THEN
    RETURN jsonb_build_object('company_code', p_company, 'system_currency', v_new, 'active', v_new <> c.currency, 'changed', false);
  END IF;
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  v_used := erp._sys_cur_used(p_company);
  IF v_old <> c.currency AND v_used > 0 THEN
    RAISE EXCEPTION 'The system currency of % can''t be changed: % journal entries already carry amounts in %.', p_company, v_used, v_old USING ERRCODE = 'P0001';
  END IF;
  IF v_new = c.currency THEN
    DELETE FROM erp.system_currency_setting WHERE company_code = p_company;
  ELSE
    INSERT INTO erp.system_currency_setting (company_code, currency, updated_by, updated_at) VALUES (p_company, v_new, me.user_id, now())
    ON CONFLICT (company_code) DO UPDATE SET currency = EXCLUDED.currency, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'system_currency_set', 'company', p_company, jsonb_build_object('before', v_old, 'after', v_new));
  RETURN jsonb_build_object('company_code', p_company, 'system_currency', v_new, 'active', v_new <> c.currency, 'changed', true);
END $$;
