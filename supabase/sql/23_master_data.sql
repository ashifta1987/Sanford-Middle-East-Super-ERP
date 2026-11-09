-- A8 · Master data: business partners and items (create / edit with approval, credit limits). Safe to run twice.
-- Does not edit 10–22. Replaces (CREATE OR REPLACE): erp.bp_bank_account_save (A5, same checks and messages; adds the
-- approval step when a 'bp_bank_detail' rule applies) and erp.approval_inbox (the 9 earlier branches + 'bp_change').
--
--   erp.master_setting      – per company: extra mandatory fields, name-similarity threshold, sourcing types
--   erp.bp_contact          – contact persons of Super ERP partners
--   erp.bp_change_request   – credit limit / bank detail changes waiting for approval (history stays in audit_log)
--   erp.item.tax_code       – new column (the SAP sync never writes it)
--   number_series           – partner codes: obj_type 2001 customers (C…), 2002 suppliers (S…), 2003 leads (L…)
--   approval_rule           – rule_code gets 'bp_credit_limit' and 'bp_bank_detail' (obj_type 2 = SAP OCRD)
--   functions               – master_data_setup, bp_checks, bp_save, bp_info, bp_change_decide, bp_change_cancel,
--                             item_checks, item_save, item_info, master_setting_set, bp_bank_account_save (replaced),
--                             approval_inbox (replaced)
-- SAP rows (source 'sap') and the sample stand-ins (source 'sample') are never changed here.

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.master_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    bp_required    text[] NOT NULL DEFAULT '{}',      -- extra mandatory partner fields (name and type are always required)
    item_required  text[] NOT NULL DEFAULT '{}',      -- extra mandatory item fields (code and name are always required)
    dup_name_similarity numeric(4,3) NOT NULL DEFAULT 0.8 CHECK (dup_name_similarity BETWEEN 0.5 AND 1),
    sourcing_types text[] NOT NULL DEFAULT '{OEM,ODM}',
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.bp_contact (
    contact_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    name           text NOT NULL,
    role           text,
    phone          text,
    mobile         text,
    email          text,
    is_default     boolean NOT NULL DEFAULT false,
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS bp_contact_bp_idx ON erp.bp_contact (company_code, card_code);

CREATE TABLE IF NOT EXISTS erp.bp_change_request (
    request_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    card_code      varchar(15) NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('credit_limit', 'bank')),
    bp_bank_id     integer,                           -- bank: the account being changed (NULL = a new account)
    before         jsonb,
    after          jsonb NOT NULL,
    reason         text,
    state          text NOT NULL DEFAULT 'pending_approval' CHECK (state IN ('pending_approval', 'approved', 'rejected', 'cancelled')),
    requested_by   uuid NOT NULL,
    requested_at   timestamptz NOT NULL DEFAULT now(),
    decided_by     uuid,
    decided_at     timestamptz,
    note           text,
    FOREIGN KEY (company_code, card_code) REFERENCES erp.business_partner ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS bp_change_request_bp_idx ON erp.bp_change_request (company_code, card_code, state);

ALTER TABLE erp.item ADD COLUMN IF NOT EXISTS tax_code varchar(8);

ALTER TABLE erp.approval_rule DROP CONSTRAINT IF EXISTS approval_rule_rule_code_check;
ALTER TABLE erp.approval_rule ADD CONSTRAINT approval_rule_rule_code_check
  CHECK (rule_code IN ('discount_pct', 'credit_limit', 'below_cost', 'journal_amount', 'payment_amount', 'bank_change',
                       'po_amount', 'po_price_increase', 'stock_doc_amount', 'count_variance_pct', 'count_variance_value',
                       'bp_credit_limit', 'bp_bank_detail'));

-- ============ Read access (no write grants: writes go through the functions below) ============
ALTER TABLE erp.master_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bp_contact ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.bp_change_request ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.master_setting, erp.bp_contact, erp.bp_change_request FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.master_setting, erp.bp_contact, erp.bp_change_request TO authenticated;
DROP POLICY IF EXISTS master_setting_read ON erp.master_setting;
CREATE POLICY master_setting_read ON erp.master_setting FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS bp_contact_read ON erp.bp_contact;
CREATE POLICY bp_contact_read ON erp.bp_contact FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('bp')) OR (SELECT erp.can_read('sales')) OR (SELECT erp.can_read('purchase')) OR (SELECT erp.can_read('finance'))));
DROP POLICY IF EXISTS bp_change_request_read ON erp.bp_change_request;
CREATE POLICY bp_change_request_read ON erp.bp_change_request FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.can_read('bp')) OR (SELECT erp.can_read('sales')) OR (SELECT erp.can_read('purchase'))
                                         OR (SELECT erp.can_read('finance')) OR (SELECT erp.can_read('banking'))));

-- ============ Views ============
CREATE OR REPLACE VIEW erp.bp_change_request_list WITH (security_invoker = true) AS
SELECT r.company_code, r.request_id, r.card_code, bp.name AS card_name, bp.kind AS bp_kind, r.kind, r.bp_bank_id, r.before, r.after,
       r.reason, r.state, r.requested_at, ru.display_name AS requested_by_name, r.decided_at, du.display_name AS decided_by_name, r.note,
       bp.currency
  FROM erp.bp_change_request r
  JOIN erp.business_partner bp ON bp.company_code = r.company_code AND bp.card_code = r.card_code
  LEFT JOIN erp.app_user ru ON ru.user_id = r.requested_by
  LEFT JOIN erp.app_user du ON du.user_id = r.decided_by;
REVOKE ALL ON erp.bp_change_request_list FROM PUBLIC, anon;
GRANT SELECT ON erp.bp_change_request_list TO authenticated;

-- ============ Internal helpers (not callable from the API) ============
-- Trigram similarity, same definition as pg_trgm's similarity(): words of letters/digits, lower case, each padded with two
-- spaces in front and one behind; |shared trigrams| / |all trigrams|. Plain SQL, so no extension is needed.
CREATE OR REPLACE FUNCTION erp._md_trgms(p text) RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT coalesce(array_agg(DISTINCT substr(w, i, 3)), '{}')
    FROM (SELECT '  ' || x || ' ' AS w FROM regexp_split_to_table(lower(coalesce(p, '')), '[^[:alnum:]]+') AS x WHERE x <> '') ws
   CROSS JOIN LATERAL generate_series(1, length(w) - 2) AS i
$$;
CREATE OR REPLACE FUNCTION erp._md_trgm_sim2(ta text[], tb text[]) RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN cardinality(ta) = 0 OR cardinality(tb) = 0 THEN 0
              ELSE round(n::numeric / (cardinality(ta) + cardinality(tb) - n), 4) END
    FROM (SELECT count(*) AS n FROM unnest(ta) t WHERE t = ANY (tb)) s
$$;
CREATE OR REPLACE FUNCTION erp._md_trgm_sim(a text, b text) RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT erp._md_trgm_sim2(erp._md_trgms(a), erp._md_trgms(b))
$$;
CREATE OR REPLACE FUNCTION erp._md_digits(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT nullif(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'), '')
$$;

-- Who is calling; may they read business partners, and change them (p_write) for this kind of partner?
-- Read: Business Partners, Sales, Purchasing or Financials. Write: Business Partners or Financials (full) for every kind,
-- Sales (full) for customers and leads, Purchasing (full) for suppliers.
CREATE OR REPLACE FUNCTION erp._md_bp_guard(p_company varchar, p_write boolean, p_kind text DEFAULT NULL) RETURNS erp.app_user
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
  IF NOT (erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance')) THEN
    RAISE EXCEPTION 'Your position does not include Business Partners. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF NOT p_write OR erp.can_write('bp') OR erp.can_write('finance') THEN
    RETURN u;
  END IF;
  IF erp.can_write('sales') AND (p_kind IS NULL OR p_kind IN ('customer', 'lead')) THEN
    RETURN u;
  END IF;
  IF erp.can_write('purchase') AND (p_kind IS NULL OR p_kind = 'supplier') THEN
    RETURN u;
  END IF;
  IF erp.can_write('sales') THEN
    RAISE EXCEPTION 'Your position can create and change customers and leads only. Ask a Business Partners or Purchasing user to change suppliers.' USING ERRCODE = '42501';
  ELSIF erp.can_write('purchase') THEN
    RAISE EXCEPTION 'Your position can create and change suppliers only. Ask a Business Partners or Sales user to change customers and leads.' USING ERRCODE = '42501';
  END IF;
  RAISE EXCEPTION 'You have read-only access to Business Partners. Ask the system admin for full access to create or change partners.' USING ERRCODE = '42501';
END $$;

-- Items. Read: Inventory, Sales or Purchasing. Write: Inventory or Purchasing (full).
CREATE OR REPLACE FUNCTION erp._md_item_guard(p_company varchar, p_write boolean) RETURNS erp.app_user
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
  IF NOT (erp.can_read('inventory') OR erp.can_read('sales') OR erp.can_read('purchase')) THEN
    RAISE EXCEPTION 'Your position does not include Inventory. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_write AND NOT (erp.can_write('inventory') OR erp.can_write('purchase')) THEN
    RAISE EXCEPTION 'You have read-only access to items. Ask the system admin for full Inventory access to create or change items.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- The message every SAP (or sample) master record shows when someone tries to change it.
CREATE OR REPLACE FUNCTION erp._md_sap_msg(p_what text, p_company varchar) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT format('This %s comes from SAP. Change it in SAP until %s goes live on Super ERP.', p_what, p_company)
$$;

-- Approval steps a change needs: rows of approval_rule (obj_type 2) for the requester's position (or every position).
CREATE OR REPLACE FUNCTION erp._md_rules(p_company varchar, p_rule text, p_position text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('rule_code', ar.rule_code, 'step', ar.step, 'approver_position', ar.approver_position,
                                               'approver_name', p.name) ORDER BY ar.step, ar.approver_position), '[]'::jsonb)
    FROM erp.approval_rule ar JOIN erp.position p ON p.position_code = ar.approver_position
   WHERE ar.company_code = p_company AND ar.obj_type = 2 AND ar.active AND ar.rule_code = p_rule
     AND (ar.position_code IS NULL OR ar.position_code = p_position)
$$;

-- Plain label of a master-data field, for the "mandatory" messages.
CREATE OR REPLACE FUNCTION erp._md_label(p_field text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_field
    WHEN 'foreign_name' THEN 'foreign (Arabic) name' WHEN 'group_code' THEN 'group' WHEN 'currency' THEN 'currency' WHEN 'trn' THEN 'TRN'
    WHEN 'phone' THEN 'phone' WHEN 'mobile' THEN 'mobile' WHEN 'email' THEN 'e-mail' WHEN 'payment_terms' THEN 'payment terms'
    WHEN 'price_list' THEN 'price list' WHEN 'slp_code' THEN 'salesperson' WHEN 'city' THEN 'city' WHEN 'country' THEN 'country'
    WHEN 'credit_limit' THEN 'credit limit' WHEN 'contacts' THEN 'contact person' WHEN 'addresses' THEN 'address'
    WHEN 'barcode' THEN 'barcode' WHEN 'hs_code' THEN 'HS code' WHEN 'moq' THEN 'MOQ' WHEN 'sales_uom' THEN 'sales unit'
    WHEN 'purchase_uom' THEN 'purchase unit' WHEN 'inventory_uom' THEN 'inventory unit' WHEN 'sourcing_type' THEN 'sourcing type'
    WHEN 'preferred_supplier' THEN 'preferred supplier' WHEN 'tax_code' THEN 'tax code' WHEN 'supplier_part_no' THEN 'supplier part number'
    WHEN 'firm_code' THEN 'brand' ELSE replace(p_field, '_', ' ') END
$$;

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

  -- possible duplicates: same TRN, same phone / mobile, or a similar name (only when one of those is new or changed)
  v_check_dups := v_new OR v_name IS DISTINCT FROM old.name OR v_trn IS DISTINCT FROM old.trn
                  OR v_phone IS DISTINCT FROM old.phone OR v_mobile IS DISTINCT FROM old.mobile;
  IF v_check_dups AND v_name IS NOT NULL THEN
    v_ta := erp._md_trgms(v_name);
    FOR r IN
      SELECT x.card_code, x.name, x.kind, x.match, x.sim FROM (
        SELECT p.card_code, p.name, p.kind,
               CASE WHEN v_trn IS NOT NULL AND erp._md_digits(p.trn) IS NOT NULL AND coalesce(erp._md_digits(p.trn), p.trn) = coalesce(erp._md_digits(v_trn), v_trn) THEN 'trn'
                    WHEN coalesce(length(erp._md_digits(p.phone)), 0) >= 7 AND erp._md_digits(p.phone) IN (erp._md_digits(v_phone), erp._md_digits(v_mobile)) THEN 'phone'
                    WHEN coalesce(length(erp._md_digits(p.mobile)), 0) >= 7 AND erp._md_digits(p.mobile) IN (erp._md_digits(v_phone), erp._md_digits(v_mobile)) THEN 'phone'
                    WHEN erp._md_trgm_sim2(v_ta, erp._md_trgms(p.name)) > v_thr THEN 'name' END AS match,
               erp._md_trgm_sim2(v_ta, erp._md_trgms(p.name)) AS sim
          FROM erp.business_partner p
         WHERE p.company_code = p_company AND p.card_code IS DISTINCT FROM v_code) x
       WHERE x.match IS NOT NULL
       ORDER BY CASE x.match WHEN 'trn' THEN 1 WHEN 'phone' THEN 2 ELSE 3 END, x.sim DESC, x.card_code
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

-- Next free partner code from the company's series for this type (row-locked; skips codes that already exist).
CREATE OR REPLACE FUNCTION erp._md_next_code(p_company varchar, p_kind text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_obj integer := CASE p_kind WHEN 'customer' THEN 2001 WHEN 'supplier' THEN 2002 ELSE 2003 END;
  ns erp.number_series;
  v_code text;
  v_n integer;
BEGIN
  SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = v_obj AND active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Partner numbering for % is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).',
      CASE p_kind WHEN 'customer' THEN 'customers' WHEN 'supplier' THEN 'suppliers' ELSE 'leads' END, p_company USING ERRCODE = 'P0001';
  END IF;
  v_n := ns.next_num;
  LOOP
    v_code := ns.prefix || lpad(v_n::text, ns.pad, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_code);
    v_n := v_n + 1;
    IF v_n > ns.next_num + 100000 THEN
      RAISE EXCEPTION 'No free partner code found in the % series of company %.', ns.prefix, p_company USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  IF length(v_code) > 15 THEN
    RAISE EXCEPTION 'The next partner code % is longer than 15 characters. Ask the system admin to shorten the series.', v_code USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.number_series SET next_num = v_n + 1 WHERE company_code = p_company AND obj_type = v_obj;
  RETURN v_code;
END $$;

-- Open the approval steps of a change request (one row per rule step).
CREATE OR REPLACE FUNCTION erp._md_open_approvals(p_company varchar, p_request integer, p_appr jsonb, p_user uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  SELECT p_company, 'bp_change', p_request::text, (x->>'step')::smallint, x->>'approver_position', x->>'rule_code', p_user, now(),
         jsonb_build_object('checks', jsonb_build_array(x))
    FROM jsonb_array_elements(p_appr) x
$$;

-- ============ API: business partners ============
-- Check a partner form without saving: errors per field, possible duplicates, and the approvals saving would need.
CREATE OR REPLACE FUNCTION erp.bp_checks(p_company varchar, p_bp jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  e jsonb;
BEGIN
  u := erp._md_bp_guard(p_company, false);
  e := erp._bp_eval(p_company, p_bp, u);
  RETURN e - 'old';
END $$;

-- Create (no card_code) or change (card_code) a Super ERP partner. Duplicates need p_dup_reason. A credit limit change that
-- a 'bp_credit_limit' rule covers is not applied: it waits in bp_change_request (a new partner starts at 0 until approved).
-- p_bp: {card_code?, kind, name, foreign_name, group_code, currency, trn, phone, mobile, email, payment_terms, price_list, slp_code,
--        credit_limit, city, country, region, bp_category, active, contacts:[{name, role, phone, mobile, email, is_default}],
--        addresses:[{address_name, kind B|S, street, block, building, city, state, zip, country}]}
CREATE OR REPLACE FUNCTION erp.bp_save(p_company varchar, p_bp jsonb, p_dup_reason text DEFAULT NULL, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  e      jsonb;
  v      jsonb;
  old    jsonb;
  v_new  boolean;
  v_code text;
  v_appr jsonb;
  v_dups jsonb;
  v_req  integer;
  v_credit numeric;
  v_dup_reason text := nullif(btrim(p_dup_reason), '');
  v_changed jsonb := '{}'::jsonb;
  k text;
  c jsonb;
BEGIN
  u := erp._md_bp_guard(p_company, false);
  e := erp._bp_eval(p_company, p_bp, u);
  v := e->'values'; old := e->'old'; v_new := (e->>'is_new')::boolean;
  PERFORM erp._md_bp_guard(p_company, true, coalesce(v->>'kind', old->>'kind'));
  IF NOT v_new AND old->>'kind' IS DISTINCT FROM v->>'kind' THEN
    PERFORM erp._md_bp_guard(p_company, true, old->>'kind');
  END IF;
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN jsonb_array_length(e->'errors') > 1 THEN format('%s more problem(s) to fix.', jsonb_array_length(e->'errors') - 1) ELSE 'Fix it and save again.' END;
  END IF;
  v_dups := e->'duplicates';
  IF jsonb_array_length(v_dups) > 0 AND v_dup_reason IS NULL THEN
    RAISE EXCEPTION 'This partner may already exist: % · % (%). Check the list and confirm with a reason to save it anyway.',
      v_dups->0->>'card_code', v_dups->0->>'name',
      CASE v_dups->0->>'match' WHEN 'trn' THEN 'same TRN' WHEN 'phone' THEN 'same phone' ELSE 'similar name' END
      USING ERRCODE = 'P0001', HINT = format('%s possible duplicate(s) found.', jsonb_array_length(v_dups));
  END IF;
  v_appr := e->'approvals';
  v_credit := (v->>'credit_limit')::numeric;

  IF v_new THEN
    v_code := erp._md_next_code(p_company, v->>'kind');
    INSERT INTO erp.business_partner (company_code, card_code, kind, name, foreign_name, group_code, bp_category, currency, credit_limit, balance,
                                      trn, phone, mobile, email, slp_code, price_list, payment_terms, region, city, country, active, created_on, source)
    VALUES (p_company, v_code, v->>'kind', v->>'name', v->>'foreign_name', (v->>'group_code')::integer, v->>'bp_category', v->>'currency',
            CASE WHEN jsonb_array_length(v_appr) > 0 THEN 0 ELSE v_credit END, 0,
            v->>'trn', v->>'phone', v->>'mobile', v->>'email', (v->>'slp_code')::integer, (v->>'price_list')::integer, (v->>'payment_terms')::integer,
            v->>'region', v->>'city', v->>'country', (v->>'active')::boolean, current_date, 'erp');
  ELSE
    v_code := v->>'card_code';
    PERFORM 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_code FOR UPDATE;
    FOR k IN SELECT unnest(ARRAY['kind', 'name', 'foreign_name', 'group_code', 'bp_category', 'currency', 'credit_limit', 'trn', 'phone', 'mobile',
                                 'email', 'slp_code', 'price_list', 'payment_terms', 'region', 'city', 'country', 'active']) LOOP
      IF (old->k) IS DISTINCT FROM (v->k) AND NOT (k = 'credit_limit' AND (old->>k)::numeric IS NOT DISTINCT FROM (v->>k)::numeric) THEN
        v_changed := v_changed || jsonb_build_object(k, jsonb_build_object('from', old->k, 'to', v->k));
      END IF;
    END LOOP;
    UPDATE erp.business_partner
       SET kind = v->>'kind', name = v->>'name', foreign_name = v->>'foreign_name', group_code = (v->>'group_code')::integer,
           bp_category = v->>'bp_category', currency = v->>'currency',
           credit_limit = CASE WHEN jsonb_array_length(v_appr) > 0 THEN credit_limit ELSE v_credit END,
           trn = v->>'trn', phone = v->>'phone', mobile = v->>'mobile', email = v->>'email', slp_code = (v->>'slp_code')::integer,
           price_list = (v->>'price_list')::integer, payment_terms = (v->>'payment_terms')::integer, region = v->>'region',
           city = v->>'city', country = v->>'country', active = (v->>'active')::boolean
     WHERE company_code = p_company AND card_code = v_code;
  END IF;

  IF v_new OR p_bp ? 'contacts' THEN
    DELETE FROM erp.bp_contact WHERE company_code = p_company AND card_code = v_code;
    INSERT INTO erp.bp_contact (company_code, card_code, name, role, phone, mobile, email, is_default)
    SELECT p_company, v_code, btrim(x->>'name'), nullif(btrim(x->>'role'), ''), nullif(btrim(x->>'phone'), ''), nullif(btrim(x->>'mobile'), ''),
           nullif(lower(btrim(x->>'email')), ''), coalesce((x->>'is_default')::boolean, false)
      FROM jsonb_array_elements(e->'contacts') x;
  END IF;
  IF v_new OR p_bp ? 'addresses' THEN
    DELETE FROM erp.bp_address WHERE company_code = p_company AND card_code = v_code;
    INSERT INTO erp.bp_address (company_code, card_code, address_name, kind, street, block, building, city, state, zip, country)
    SELECT p_company, v_code, btrim(x->>'address_name'), x->>'kind', nullif(btrim(x->>'street'), ''), nullif(btrim(x->>'block'), ''),
           nullif(btrim(x->>'building'), ''), nullif(btrim(x->>'city'), ''), nullif(btrim(x->>'state'), ''), nullif(btrim(x->>'zip'), ''),
           nullif(upper(btrim(x->>'country')), '')
      FROM jsonb_array_elements(e->'addresses') x;
  END IF;

  IF jsonb_array_length(v_appr) > 0 THEN
    INSERT INTO erp.bp_change_request (company_code, card_code, kind, before, after, reason, requested_by)
    VALUES (p_company, v_code, 'credit_limit', jsonb_build_object('credit_limit', CASE WHEN v_new THEN NULL ELSE old->'credit_limit' END),
            jsonb_build_object('credit_limit', v_credit), nullif(btrim(p_reason), ''), u.user_id)
    RETURNING request_id INTO v_req;
    PERFORM erp._md_open_approvals(p_company, v_req, v_appr, u.user_id);
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'bp_credit_limit_request', 'business_partner', v_code,
            jsonb_build_object('request_id', v_req, 'from', CASE WHEN v_new THEN NULL ELSE old->'credit_limit' END, 'to', v_credit,
                               'reason', nullif(btrim(p_reason), ''), 'approvers', v_appr));
    v_changed := v_changed - 'credit_limit';
  END IF;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_new THEN 'bp_create' ELSE 'bp_update' END, 'business_partner', v_code,
          CASE WHEN v_new THEN jsonb_build_object('values', v || jsonb_build_object('card_code', v_code), 'contacts', jsonb_array_length(e->'contacts'),
                                                  'addresses', jsonb_array_length(e->'addresses'))
               ELSE jsonb_build_object('changed', v_changed, 'contacts_replaced', p_bp ? 'contacts', 'addresses_replaced', p_bp ? 'addresses') END);
  IF jsonb_array_length(v_dups) > 0 THEN
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'bp_duplicate_confirmed', 'business_partner', v_code, jsonb_build_object('reason', v_dup_reason, 'duplicates', v_dups));
  END IF;
  RETURN jsonb_build_object('card_code', v_code, 'created', v_new, 'changed', v_changed,
                            'credit_request', CASE WHEN v_req IS NULL THEN NULL ELSE jsonb_build_object('request_id', v_req, 'state', 'pending_approval',
                                                   'approvers', v_appr) END);
END $$;

-- Write a bank-detail change exactly as A5 did (bp_bank_account + bp_bank_change log + audit), so A5's bank-change payment
-- rule counts from the moment the details take effect. p_id NULL = new account.
CREATE OR REPLACE FUNCTION erp._bp_bank_apply(p_company varchar, p_card text, p_id integer, p_new jsonb, p_changed_by uuid, p_actor uuid,
                                              p_request integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  old    erp.bp_bank_account;
  v_id   integer := p_id;
  v_kind text;
  v_act  boolean := coalesce((p_new->>'active')::boolean, true);
BEGIN
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.bp_bank_account WHERE bp_bank_id = v_id AND company_code = p_company AND card_code = p_card FOR UPDATE;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO erp.bp_bank_account (company_code, card_code, bank_name, account_no, iban, swift, holder, active, source, updated_by)
    VALUES (p_company, p_card, p_new->>'bank_name', p_new->>'account_no', p_new->>'iban', p_new->>'swift', p_new->>'holder', v_act, 'erp', p_changed_by)
    RETURNING bp_bank_id INTO v_id;
    v_kind := 'added';
  ELSE
    UPDATE erp.bp_bank_account SET bank_name = p_new->>'bank_name', account_no = p_new->>'account_no', iban = p_new->>'iban', swift = p_new->>'swift',
                                   holder = p_new->>'holder', active = v_act, updated_by = p_changed_by, updated_at = now()
     WHERE bp_bank_id = v_id;
    v_kind := CASE WHEN old.active AND NOT v_act THEN 'deactivated' ELSE 'changed' END;
  END IF;
  INSERT INTO erp.bp_bank_change (company_code, card_code, bp_bank_id, change_kind, before, after, changed_by)
  VALUES (p_company, p_card, v_id, v_kind,
          CASE WHEN old.bp_bank_id IS NOT NULL THEN jsonb_build_object('bank_name', old.bank_name, 'account_no', old.account_no, 'iban', old.iban,
                                                                       'swift', old.swift, 'holder', old.holder, 'active', old.active) END, p_new, p_changed_by);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (p_actor::text, p_company, 'bp_bank_change', 'business_partner', p_card,
          jsonb_build_object('bp_bank_id', v_id, 'change', v_kind, 'before', CASE WHEN old.bp_bank_id IS NOT NULL THEN to_jsonb(old) - 'updated_by' END,
                             'after', p_new) || CASE WHEN p_request IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('request_id', p_request) END);
  RETURN jsonb_build_object('bp_bank_id', v_id, 'change', v_kind, 'changed_at', now());
END $$;

-- Add or change a business partner's bank details (replaces A5's version: same checks and messages). When an approval rule
-- 'bp_bank_detail' covers the caller's position, the change waits for approval (bp_change_request) and is applied by the
-- final approval; otherwise it is applied at once, as before. Bank details from SAP stay read-only.
-- p_bank: {bp_bank_id (change) | null (add), bank_name, account_no, iban, swift, holder, active, reason}
CREATE OR REPLACE FUNCTION erp.bp_bank_account_save(p_company varchar, p_card text, p_bank jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  r      jsonb := coalesce(p_bank, '{}'::jsonb);
  v_id   integer := erp._num(r->>'bp_bank_id')::integer;
  v_bank text := nullif(btrim(r->>'bank_name'), '');
  v_acc  text := nullif(btrim(r->>'account_no'), '');
  v_iban text := nullif(upper(regexp_replace(coalesce(r->>'iban', ''), '\s', '', 'g')), '');
  v_act  boolean := coalesce((r->>'active')::boolean, true);
  old    erp.bp_bank_account;
  v_new  jsonb;
  bp     erp.business_partner;
  v_rules jsonb;
  v_appr jsonb;
  v_req  integer;
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
  IF NOT (erp.can_write('bp') OR erp.can_write('banking') OR erp.can_write('finance')) THEN
    IF erp.can_read('bp') OR erp.can_read('banking') OR erp.can_read('finance') THEN
      RAISE EXCEPTION 'You have read-only access. Ask the system admin for full access to change bank details.' USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Your position does not include Business Partners, Banking or Financials. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business partner % does not exist in company %. Check the code.', coalesce(p_card, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_bank IS NULL THEN
    RAISE EXCEPTION 'Enter the bank name.' USING ERRCODE = 'P0001';
  ELSIF v_acc IS NULL AND v_iban IS NULL THEN
    RAISE EXCEPTION 'Enter the account number or the IBAN.' USING ERRCODE = 'P0001';
  ELSIF v_iban IS NOT NULL AND v_iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' THEN
    RAISE EXCEPTION 'The IBAN % is not valid. It starts with the country code and two check digits, e.g. AE07 0331 2345 6789 0123 456.', v_iban USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.bp_bank_account WHERE bp_bank_id = v_id AND company_code = p_company AND card_code = p_card FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Bank account % was not found for %.', v_id, p_card USING ERRCODE = 'P0001';
    ELSIF old.source = 'sap' THEN
      RAISE EXCEPTION 'These bank details came from SAP Business One and are read-only during the soft switch.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_new := jsonb_build_object('bank_name', v_bank, 'account_no', v_acc, 'iban', v_iban, 'swift', nullif(upper(btrim(r->>'swift')), ''),
                              'holder', nullif(btrim(r->>'holder'), ''), 'active', v_act);
  IF v_id IS NOT NULL AND v_new = jsonb_build_object('bank_name', old.bank_name, 'account_no', old.account_no, 'iban', old.iban, 'swift', old.swift,
                                                     'holder', old.holder, 'active', old.active) THEN
    RAISE EXCEPTION 'Nothing changed.' USING ERRCODE = 'P0001';
  END IF;

  -- A8: approval before the change takes effect
  v_rules := erp._md_rules(p_company, 'bp_bank_detail', u.position_code);
  IF jsonb_array_length(v_rules) = 0 THEN
    RETURN erp._bp_bank_apply(p_company, p_card, v_id, v_new, u.user_id, u.user_id);
  END IF;
  IF EXISTS (SELECT 1 FROM erp.bp_change_request WHERE company_code = p_company AND card_code = p_card AND kind = 'bank'
                                                    AND state = 'pending_approval' AND bp_bank_id IS NOT DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'A bank detail change for % is already waiting for approval. Wait for the decision or cancel it.', p_card USING ERRCODE = 'P0001';
  END IF;
  SELECT jsonb_agg(x || jsonb_build_object('message',
           format('New bank details for %s (%s) need approval from %s before they are used.', p_card, bp.name,
                  (SELECT string_agg(y->>'approver_name', ' then ' ORDER BY (y->>'step')::int) FROM jsonb_array_elements(v_rules) y))))
    INTO v_appr FROM jsonb_array_elements(v_rules) x;
  INSERT INTO erp.bp_change_request (company_code, card_code, kind, bp_bank_id, before, after, reason, requested_by)
  VALUES (p_company, p_card, 'bank', v_id,
          CASE WHEN v_id IS NOT NULL THEN jsonb_build_object('bank_name', old.bank_name, 'account_no', old.account_no, 'iban', old.iban,
                                                             'swift', old.swift, 'holder', old.holder, 'active', old.active) END,
          v_new, nullif(btrim(r->>'reason'), ''), u.user_id)
  RETURNING request_id INTO v_req;
  PERFORM erp._md_open_approvals(p_company, v_req, v_appr, u.user_id);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bp_bank_change_request', 'business_partner', p_card,
          jsonb_build_object('request_id', v_req, 'bp_bank_id', v_id, 'after', v_new, 'approvers', v_appr));
  RETURN jsonb_build_object('request_id', v_req, 'state', 'pending_approval', 'bp_bank_id', v_id,
                            'change', CASE WHEN v_id IS NULL THEN 'added' WHEN old.active AND NOT v_act THEN 'deactivated' ELSE 'changed' END,
                            'approvers', v_appr);
END $$;

-- Who may decide / see change requests: anyone in the company who reads partners or banking.
CREATE OR REPLACE FUNCTION erp._md_req_guard(p_company varchar) RETURNS erp.app_user
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
  IF NOT (erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance') OR erp.can_read('banking')) THEN
    RAISE EXCEPTION 'Your position does not include Business Partners. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

-- Approve or reject the current step of a credit limit / bank detail change. The final approval applies the change.
CREATE OR REPLACE FUNCTION erp.bp_change_decide(p_company varchar, p_request integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  q      erp.bp_change_request;
  bp     erp.business_partner;
  cur    erp.bp_bank_account;
  v_left integer;
  v_res  jsonb;
  v_state text;
BEGIN
  u := erp._md_req_guard(p_company);
  SELECT * INTO q FROM erp.bp_change_request WHERE company_code = p_company AND request_id = p_request FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % was not found in company %.', coalesce(p_request::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This change request is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  v_left := erp._inv_decide(p_company, 'bp_change', p_request::text, 'change request', q.requested_by, u, p_decision, p_note);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_left < 0 THEN 'bp_change_reject' ELSE 'bp_change_approve' END, 'bp_change', p_request::text,
          jsonb_build_object('card_code', q.card_code, 'kind', q.kind, 'note', nullif(btrim(p_note), ''), 'open_steps', greatest(v_left, 0)));
  IF v_left < 0 THEN
    UPDATE erp.bp_change_request SET state = 'rejected', decided_by = u.user_id, decided_at = now(), note = nullif(btrim(p_note), '')
     WHERE request_id = p_request;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, CASE q.kind WHEN 'credit_limit' THEN 'bp_credit_limit_rejected' ELSE 'bp_bank_change_rejected' END,
            'business_partner', q.card_code, jsonb_build_object('request_id', p_request, 'after', q.after, 'note', nullif(btrim(p_note), '')));
    RETURN jsonb_build_object('request_id', p_request, 'state', 'rejected');
  ELSIF v_left > 0 THEN
    RETURN jsonb_build_object('request_id', p_request, 'state', 'pending_approval', 'open_steps', v_left);
  END IF;

  -- fully approved: apply
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = q.card_code FOR UPDATE;
  IF q.kind = 'credit_limit' THEN
    IF bp.source <> 'erp' THEN
      RAISE EXCEPTION '%', erp._md_sap_msg('partner', p_company) USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.business_partner SET credit_limit = (q.after->>'credit_limit')::numeric WHERE company_code = p_company AND card_code = q.card_code;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'bp_credit_limit_change', 'business_partner', q.card_code,
            jsonb_build_object('request_id', p_request, 'from', bp.credit_limit, 'to', q.after->'credit_limit', 'requested_by', q.requested_by));
    v_res := jsonb_build_object('credit_limit', q.after->'credit_limit');
  ELSE
    IF q.bp_bank_id IS NOT NULL THEN
      SELECT * INTO cur FROM erp.bp_bank_account WHERE bp_bank_id = q.bp_bank_id AND company_code = p_company FOR UPDATE;
      IF NOT FOUND OR jsonb_build_object('bank_name', cur.bank_name, 'account_no', cur.account_no, 'iban', cur.iban, 'swift', cur.swift,
                                         'holder', cur.holder, 'active', cur.active) IS DISTINCT FROM q.before THEN
        RAISE EXCEPTION 'The bank details of % changed after this request was made. Reject it and ask for a new request.', q.card_code USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_res := erp._bp_bank_apply(p_company, q.card_code, q.bp_bank_id, q.after, q.requested_by, u.user_id, p_request);
    UPDATE erp.bp_change_request SET bp_bank_id = (v_res->>'bp_bank_id')::integer WHERE request_id = p_request;
  END IF;
  UPDATE erp.bp_change_request SET state = 'approved', decided_by = u.user_id, decided_at = now(), note = nullif(btrim(p_note), '')
   WHERE request_id = p_request;
  RETURN jsonb_build_object('request_id', p_request, 'state', 'approved') || v_res;
END $$;

-- Withdraw a waiting change: the requester, or a user who may change this partner.
CREATE OR REPLACE FUNCTION erp.bp_change_cancel(p_company varchar, p_request integer, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  q  erp.bp_change_request;
  v_kind text;
BEGIN
  u := erp._md_req_guard(p_company);
  SELECT * INTO q FROM erp.bp_change_request WHERE company_code = p_company AND request_id = p_request FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % was not found in company %.', coalesce(p_request::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'Only a change that is waiting for approval can be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  IF q.requested_by <> u.user_id THEN
    SELECT kind INTO v_kind FROM erp.business_partner WHERE company_code = p_company AND card_code = q.card_code;
    IF q.kind = 'bank' THEN
      IF NOT (erp.can_write('bp') OR erp.can_write('banking') OR erp.can_write('finance')) THEN
        RAISE EXCEPTION 'Only the requester or a user with full access can cancel this change.' USING ERRCODE = '42501';
      END IF;
    ELSE
      PERFORM erp._md_bp_guard(p_company, true, v_kind);
    END IF;
  END IF;
  UPDATE erp.bp_change_request SET state = 'cancelled', decided_by = u.user_id, decided_at = now(), note = nullif(btrim(p_note), '')
   WHERE request_id = p_request;
  UPDATE erp.approval SET superseded = true
   WHERE company_code = p_company AND object = 'bp_change' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'bp_change_cancel', 'bp_change', p_request::text,
          jsonb_build_object('card_code', q.card_code, 'kind', q.kind, 'note', nullif(btrim(p_note), '')));
  RETURN jsonb_build_object('request_id', p_request, 'state', 'cancelled');
END $$;

-- Everything the partner page needs: partner, contacts, addresses, bank details (Business Partners / Banking / Financials
-- readers only), change requests with their approvals, history (audit_log) and what the caller may do.
CREATE OR REPLACE FUNCTION erp.bp_info(p_company varchar, p_card text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  bp  erp.business_partner;
  v_edit text;
  v_bank boolean;
BEGIN
  u := erp._md_bp_guard(p_company, false);
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF bp.source <> 'erp' THEN
    v_edit := erp._md_sap_msg('partner', p_company);
  ELSE
    BEGIN
      PERFORM erp._md_bp_guard(p_company, true, bp.kind);
    EXCEPTION WHEN insufficient_privilege THEN
      v_edit := SQLERRM;
    END;
  END IF;
  v_bank := erp.can_read('bp') OR erp.can_read('banking') OR erp.can_read('finance');
  RETURN jsonb_build_object(
    'partner', to_jsonb(bp) || jsonb_build_object(
       'group_name', (SELECT name FROM erp.bp_group WHERE company_code = p_company AND group_code = bp.group_code),
       'payment_terms_name', (SELECT name FROM erp.payment_terms WHERE company_code = p_company AND group_num = bp.payment_terms),
       'price_list_name', (SELECT name FROM erp.price_list WHERE company_code = p_company AND list_num = bp.price_list),
       'slp_name', (SELECT name FROM erp.salesperson WHERE company_code = p_company AND slp_code = bp.slp_code)),
    'can_edit', v_edit IS NULL, 'edit_reason', v_edit,
    'can_bank', erp.can_write('bp') OR erp.can_write('banking') OR erp.can_write('finance'),
    'bank_needs_approval', jsonb_array_length(erp._md_rules(p_company, 'bp_bank_detail', u.position_code)) > 0,
    'credit_needs_approval', jsonb_array_length(erp._md_rules(p_company, 'bp_credit_limit', u.position_code)) > 0,
    'contacts', (SELECT coalesce(jsonb_agg(to_jsonb(c) - 'company_code' - 'card_code' ORDER BY c.is_default DESC, c.contact_id), '[]'::jsonb)
                   FROM erp.bp_contact c WHERE c.company_code = p_company AND c.card_code = p_card),
    'addresses', (SELECT coalesce(jsonb_agg(to_jsonb(a) - 'company_code' - 'card_code' ORDER BY a.kind, a.address_name), '[]'::jsonb)
                    FROM erp.bp_address a WHERE a.company_code = p_company AND a.card_code = p_card),
    'bank_accounts', CASE WHEN v_bank THEN (SELECT coalesce(jsonb_agg(to_jsonb(b) - 'company_code' - 'card_code' - 'updated_by' ORDER BY b.bp_bank_id), '[]'::jsonb)
                                              FROM erp.bp_bank_account b WHERE b.company_code = p_company AND b.card_code = p_card) END,
    'last_bank_change', (SELECT max(changed_at) FROM erp.bp_bank_change WHERE company_code = p_company AND card_code = p_card),
    'requests', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'request_id', q.request_id, 'kind', q.kind, 'bp_bank_id', q.bp_bank_id,
                    'before', CASE WHEN q.kind = 'bank' AND NOT v_bank THEN NULL ELSE q.before END,
                    'after', CASE WHEN q.kind = 'bank' AND NOT v_bank THEN NULL ELSE q.after END,
                    'reason', q.reason, 'state', q.state, 'requested_at', q.requested_at, 'requested_by_name', ru.display_name,
                    'requested_by_me', q.requested_by = u.user_id, 'decided_at', q.decided_at, 'decided_by_name', du.display_name, 'note', q.note,
                    'approvals', erp._inv_approvals(p_company, 'bp_change', q.request_id::text, u)) ORDER BY q.request_id DESC), '[]'::jsonb)
                   FROM erp.bp_change_request q
                   LEFT JOIN erp.app_user ru ON ru.user_id = q.requested_by
                   LEFT JOIN erp.app_user du ON du.user_id = q.decided_by
                  WHERE q.company_code = p_company AND q.card_code = p_card),
    'history', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor),
                                                             'detail', CASE WHEN l.action LIKE 'bp_bank%' AND NOT v_bank THEN NULL ELSE l.detail END)
                                          ORDER BY l.at DESC, l.audit_id DESC), '[]'::jsonb)
                  FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                 WHERE l.company_code = p_company AND l.object = 'business_partner' AND l.object_ref = p_card));
END $$;

-- ============ Items ============
-- Returns {errors:[{field, message}], duplicates:[{item_code, name, match}], values, is_new, old}. Raises for unknown / SAP items.
CREATE OR REPLACE FUNCTION erp._item_eval(p_company varchar, p_item jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  b      jsonb := coalesce(p_item, '{}'::jsonb);
  v_code text := nullif(upper(btrim(b->>'item_code')), '');
  v_new  boolean := NOT coalesce((b->>'edit')::boolean, false);
  old    erp.item;
  m      jsonb;
  st     erp.master_setting;
  v_err  jsonb := '[]'::jsonb;
  v_dups jsonb := '[]'::jsonb;
  v_name text; v_group integer; v_firm integer; v_barcode text; v_hs text; v_moq numeric; v_src text; v_sup text; v_spn text; v_tax text;
  v_stock boolean; v_sold boolean; v_bought boolean; v_batch boolean; v_serial boolean; v_active boolean;
  v_pcs jsonb := '{}'::jsonb; v_uom jsonb := '{}'::jsonb;
  v_raw text; f text; v_n numeric; v_oh numeric; o record;
BEGIN
  SELECT * INTO st FROM erp.master_setting WHERE company_code = p_company;
  IF NOT v_new THEN
    SELECT * INTO old FROM erp.item WHERE company_code = p_company AND item_code = v_code;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item % does not exist in company %. Check the code.', coalesce(v_code, '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    IF old.source <> 'erp' THEN
      RAISE EXCEPTION '%', erp._md_sap_msg('item', p_company) USING ERRCODE = 'P0001',
        HINT = 'SAP items stay read-only in Super ERP during the soft switch.';
    END IF;
  END IF;
  m := CASE WHEN v_new THEN '{}'::jsonb ELSE to_jsonb(old) END
       || (b - 'item_code' - 'company_code' - 'edit' - 'source' - 'avg_cost' - 'created_on' - 'master_item_code');

  IF v_new THEN
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('field', 'item_code', 'message', 'Enter the item code.');
    ELSIF v_code !~ '^[A-Z0-9][A-Z0-9._/-]{0,49}$' THEN
      v_err := v_err || jsonb_build_object('field', 'item_code', 'message', 'The item code may use letters, digits, dot, dash, slash and underscore (50 characters at most).');
    ELSIF EXISTS (SELECT 1 FROM erp.item WHERE company_code = p_company AND item_code = v_code) THEN
      v_err := v_err || jsonb_build_object('field', 'item_code', 'message', format('Item %s already exists in company %s.', v_code, p_company));
    END IF;
  END IF;
  v_name := nullif(btrim(m->>'name'), '');
  IF v_name IS NULL THEN
    v_err := v_err || jsonb_build_object('field', 'name', 'message', 'Enter the item description.');
  ELSIF length(v_name) > 200 THEN
    v_err := v_err || jsonb_build_object('field', 'name', 'message', 'The description is too long (200 characters at most).');
  END IF;
  v_raw := nullif(btrim(m->>'group_code'), '');
  IF v_raw IS NOT NULL THEN
    v_group := erp._num(v_raw)::integer;
    IF NOT EXISTS (SELECT 1 FROM erp.item_group WHERE company_code = p_company AND group_code = v_group) THEN
      v_err := v_err || jsonb_build_object('field', 'group_code', 'message', format('Item group %s does not exist in company %s.', v_raw, p_company));
    END IF;
  END IF;
  v_raw := nullif(btrim(m->>'firm_code'), '');
  IF v_raw IS NOT NULL THEN
    v_firm := erp._num(v_raw)::integer;
    IF NOT EXISTS (SELECT 1 FROM erp.brand WHERE company_code = p_company AND firm_code = v_firm) THEN
      v_err := v_err || jsonb_build_object('field', 'firm_code', 'message', format('Brand %s does not exist in company %s.', v_raw, p_company));
    END IF;
  END IF;
  FOREACH f IN ARRAY ARRAY['sales_uom', 'purchase_uom', 'inventory_uom'] LOOP
    v_raw := nullif(upper(btrim(m->>f)), '');
    IF v_raw IS NOT NULL AND length(v_raw) > 20 THEN
      v_err := v_err || jsonb_build_object('field', f, 'message', format('The %s is too long (20 characters at most).', erp._md_label(f)));
    END IF;
    v_uom := v_uom || jsonb_build_object(f, v_raw);
  END LOOP;
  -- barcode: unique in the company
  v_barcode := nullif(btrim(m->>'barcode'), '');
  IF v_barcode IS NOT NULL THEN
    IF v_barcode !~ '^[A-Za-z0-9-]{4,50}$' THEN
      v_err := v_err || jsonb_build_object('field', 'barcode', 'message', 'The barcode may use letters, digits and dashes only (4 to 50 characters).');
    ELSE
      SELECT item_code, name INTO o FROM erp.item WHERE company_code = p_company AND barcode = v_barcode AND item_code IS DISTINCT FROM v_code LIMIT 1;
      IF FOUND THEN
        v_err := v_err || jsonb_build_object('field', 'barcode', 'message',
          format('Barcode %s is already used by item %s · %s. A barcode must be unique in the company.', v_barcode, o.item_code, o.name));
      END IF;
    END IF;
  END IF;
  v_hs := nullif(btrim(m->>'hs_code'), '');
  IF v_hs IS NOT NULL AND (v_hs !~ '^[0-9. ]+$' OR length(erp._md_digits(v_hs)) NOT BETWEEN 6 AND 12 OR length(v_hs) > 15) THEN
    v_err := v_err || jsonb_build_object('field', 'hs_code', 'message', 'The HS code must have 6 to 12 digits, e.g. 8516.61.00.');
  END IF;
  v_raw := nullif(btrim(m->>'moq'), '');
  IF v_raw IS NOT NULL THEN
    v_moq := erp._num(v_raw);
    IF v_moq IS NULL OR v_moq < 0 THEN
      v_err := v_err || jsonb_build_object('field', 'moq', 'message', 'Enter the MOQ as a number of 0 or more.');
    END IF;
  END IF;
  FOREACH f IN ARRAY ARRAY['pcs_20gp', 'pcs_40gp', 'pcs_40hq'] LOOP
    v_raw := nullif(btrim(m->>f), '');
    v_n := NULL;
    IF v_raw IS NOT NULL THEN
      v_n := erp._num(v_raw);
      IF v_n IS NULL OR v_n < 0 OR v_n <> trunc(v_n) OR v_n > 2147483647 THEN
        v_err := v_err || jsonb_build_object('field', f, 'message',
          format('Enter the %s container quantity as a whole number of 0 or more.', upper(replace(f, 'pcs_', ''))));
        v_n := NULL;
      END IF;
    END IF;
    v_pcs := v_pcs || jsonb_build_object(f, v_n);
  END LOOP;
  v_src := nullif(upper(btrim(m->>'sourcing_type')), '');
  IF v_src IS NOT NULL AND NOT v_src = ANY (coalesce(st.sourcing_types, '{OEM,ODM}')) THEN
    v_err := v_err || jsonb_build_object('field', 'sourcing_type', 'message',
      format('Sourcing type must be one of: %s.', array_to_string(coalesce(st.sourcing_types, '{OEM,ODM}'), ', ')));
  END IF;
  v_sup := nullif(upper(btrim(m->>'preferred_supplier')), '');
  IF v_sup IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_sup AND kind = 'supplier') THEN
    v_err := v_err || jsonb_build_object('field', 'preferred_supplier', 'message', format('Preferred supplier %s is not a supplier in company %s.', v_sup, p_company));
  END IF;
  v_spn := nullif(btrim(m->>'supplier_part_no'), '');
  IF v_spn IS NOT NULL AND length(v_spn) > 50 THEN
    v_err := v_err || jsonb_build_object('field', 'supplier_part_no', 'message', 'The supplier part number is too long (50 characters at most).');
  END IF;
  v_tax := nullif(upper(btrim(m->>'tax_code')), '');
  IF v_tax IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.tax_code WHERE company_code = p_company AND code = v_tax AND active) THEN
    v_err := v_err || jsonb_build_object('field', 'tax_code', 'message', format('Tax code %s does not exist or is inactive in company %s.', v_tax, p_company));
  END IF;
  v_stock := coalesce((m->>'is_stock')::boolean, true);
  v_sold := coalesce((m->>'is_sold')::boolean, true);
  v_bought := coalesce((m->>'is_bought')::boolean, true);
  v_batch := coalesce((m->>'batch_managed')::boolean, false);
  v_serial := coalesce((m->>'serial_managed')::boolean, false);
  v_active := coalesce((m->>'active')::boolean, true);
  IF v_batch AND v_serial THEN
    v_err := v_err || jsonb_build_object('field', 'serial_managed', 'message', 'An item is managed by batches or by serial numbers, not both.');
  ELSIF (v_batch OR v_serial) AND NOT v_stock THEN
    v_err := v_err || jsonb_build_object('field', 'is_stock', 'message', 'Only inventory items can be managed by batches or serial numbers.');
  END IF;
  IF NOT v_new THEN
    SELECT coalesce(sum(on_hand), 0) INTO v_oh FROM erp.stock_balance WHERE company_code = p_company AND item_code = v_code;
    IF v_oh <> 0 AND (v_batch IS DISTINCT FROM old.batch_managed OR v_serial IS DISTINCT FROM old.serial_managed) THEN
      v_err := v_err || jsonb_build_object('field', 'batch_managed', 'message',
        format('%s has stock on hand. Its batch / serial management can''t change until the stock is zero.', v_code));
    END IF;
    IF v_oh <> 0 AND coalesce(old.is_stock, true) AND NOT v_stock THEN
      v_err := v_err || jsonb_build_object('field', 'is_stock', 'message', format('%s has stock on hand. It must stay an inventory item.', v_code));
    END IF;
  END IF;
  FOREACH f IN ARRAY coalesce(st.item_required, '{}') LOOP
    IF nullif(btrim(m->>f), '') IS NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_err) e WHERE e->>'field' = f) THEN
      v_err := v_err || jsonb_build_object('field', f, 'message', format('Enter the %s. It is mandatory in company %s.', erp._md_label(f), p_company));
    END IF;
  END LOOP;
  -- possible duplicate: another item with the same supplier part number (only when it is new or changed)
  IF v_spn IS NOT NULL AND (v_new OR v_spn IS DISTINCT FROM old.supplier_part_no) THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('item_code', i.item_code, 'name', i.name, 'match', 'supplier_part_no',
                                                 'preferred_supplier', i.preferred_supplier) ORDER BY i.item_code), '[]'::jsonb)
      INTO v_dups
      FROM (SELECT * FROM erp.item WHERE company_code = p_company AND lower(btrim(supplier_part_no)) = lower(v_spn)
                                     AND item_code IS DISTINCT FROM v_code ORDER BY item_code LIMIT 10) i;
  END IF;
  RETURN jsonb_build_object('is_new', v_new, 'errors', v_err, 'duplicates', v_dups, 'old', CASE WHEN v_new THEN NULL ELSE to_jsonb(old) END,
    'values', jsonb_build_object('item_code', v_code, 'name', v_name, 'foreign_name', nullif(btrim(m->>'foreign_name'), ''), 'group_code', v_group,
                                 'firm_code', v_firm, 'barcode', v_barcode, 'hs_code', v_hs, 'moq', v_moq, 'sourcing_type', v_src,
                                 'preferred_supplier', v_sup, 'supplier_part_no', v_spn, 'tax_code', v_tax, 'is_stock', v_stock, 'is_sold', v_sold,
                                 'is_bought', v_bought, 'batch_managed', v_batch, 'serial_managed', v_serial, 'active', v_active,
                                 'category', nullif(btrim(m->>'category'), ''))
              || v_uom || v_pcs);
END $$;

CREATE OR REPLACE FUNCTION erp.item_checks(p_company varchar, p_item jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._md_item_guard(p_company, false);
  RETURN erp._item_eval(p_company, p_item) - 'old';
END $$;

-- Create (edit = false) or change (edit = true) a Super ERP item. A duplicate supplier part number needs p_dup_reason.
-- p_item: {item_code, edit, name, foreign_name, group_code, firm_code, barcode, hs_code, moq, pcs_20gp, pcs_40gp, pcs_40hq, sourcing_type,
--          preferred_supplier, supplier_part_no, tax_code, sales_uom, purchase_uom, inventory_uom, is_stock, is_sold, is_bought,
--          batch_managed, serial_managed, active, category}
CREATE OR REPLACE FUNCTION erp.item_save(p_company varchar, p_item jsonb, p_dup_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  e     jsonb;
  v     jsonb;
  old   jsonb;
  v_new boolean;
  v_code text;
  v_changed jsonb := '{}'::jsonb;
  v_reason text := nullif(btrim(p_dup_reason), '');
  k text;
BEGIN
  u := erp._md_item_guard(p_company, true);
  e := erp._item_eval(p_company, p_item);
  v := e->'values'; old := e->'old'; v_new := (e->>'is_new')::boolean; v_code := v->>'item_code';
  IF jsonb_array_length(e->'errors') > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN jsonb_array_length(e->'errors') > 1 THEN format('%s more problem(s) to fix.', jsonb_array_length(e->'errors') - 1) ELSE 'Fix it and save again.' END;
  END IF;
  IF jsonb_array_length(e->'duplicates') > 0 AND v_reason IS NULL THEN
    RAISE EXCEPTION 'Supplier part number % is already used by item % · %. Check it and confirm with a reason to save anyway.',
      v->>'supplier_part_no', e->'duplicates'->0->>'item_code', e->'duplicates'->0->>'name' USING ERRCODE = 'P0001';
  END IF;
  IF v_new THEN
    INSERT INTO erp.item (company_code, item_code, name, foreign_name, group_code, firm_code, category, sourcing_type, hs_code, moq, barcode,
                          sales_uom, purchase_uom, inventory_uom, is_stock, is_sold, is_bought, batch_managed, serial_managed,
                          pcs_20gp, pcs_40gp, pcs_40hq, preferred_supplier, supplier_part_no, tax_code, active, created_on, source)
    VALUES (p_company, v_code, v->>'name', v->>'foreign_name', (v->>'group_code')::integer, (v->>'firm_code')::integer,
            coalesce(v->>'category', (SELECT name FROM erp.item_group WHERE company_code = p_company AND group_code = (v->>'group_code')::integer)),
            v->>'sourcing_type', v->>'hs_code', (v->>'moq')::numeric, v->>'barcode', v->>'sales_uom', v->>'purchase_uom', v->>'inventory_uom',
            (v->>'is_stock')::boolean, (v->>'is_sold')::boolean, (v->>'is_bought')::boolean, (v->>'batch_managed')::boolean, (v->>'serial_managed')::boolean,
            (v->>'pcs_20gp')::integer, (v->>'pcs_40gp')::integer, (v->>'pcs_40hq')::integer, v->>'preferred_supplier', v->>'supplier_part_no',
            v->>'tax_code', (v->>'active')::boolean, current_date, 'erp');
  ELSE
    PERFORM 1 FROM erp.item WHERE company_code = p_company AND item_code = v_code FOR UPDATE;
    FOR k IN SELECT jsonb_object_keys(v) LOOP
      IF k <> 'item_code' AND (old->k) IS DISTINCT FROM (v->k)
         AND NOT (jsonb_typeof(old->k) = 'number' AND jsonb_typeof(v->k) = 'number' AND (old->>k)::numeric = (v->>k)::numeric) THEN
        v_changed := v_changed || jsonb_build_object(k, jsonb_build_object('from', old->k, 'to', v->k));
      END IF;
    END LOOP;
    UPDATE erp.item
       SET name = v->>'name', foreign_name = v->>'foreign_name', group_code = (v->>'group_code')::integer, firm_code = (v->>'firm_code')::integer,
           category = v->>'category', sourcing_type = v->>'sourcing_type', hs_code = v->>'hs_code', moq = (v->>'moq')::numeric, barcode = v->>'barcode',
           sales_uom = v->>'sales_uom', purchase_uom = v->>'purchase_uom', inventory_uom = v->>'inventory_uom',
           is_stock = (v->>'is_stock')::boolean, is_sold = (v->>'is_sold')::boolean, is_bought = (v->>'is_bought')::boolean,
           batch_managed = (v->>'batch_managed')::boolean, serial_managed = (v->>'serial_managed')::boolean,
           pcs_20gp = (v->>'pcs_20gp')::integer, pcs_40gp = (v->>'pcs_40gp')::integer, pcs_40hq = (v->>'pcs_40hq')::integer,
           preferred_supplier = v->>'preferred_supplier', supplier_part_no = v->>'supplier_part_no', tax_code = v->>'tax_code',
           active = (v->>'active')::boolean
     WHERE company_code = p_company AND item_code = v_code;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN v_new THEN 'item_create' ELSE 'item_update' END, 'item', v_code,
          CASE WHEN v_new THEN jsonb_build_object('values', v) ELSE jsonb_build_object('changed', v_changed) END);
  IF jsonb_array_length(e->'duplicates') > 0 THEN
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'item_duplicate_confirmed', 'item', v_code, jsonb_build_object('reason', v_reason, 'duplicates', e->'duplicates'));
  END IF;
  RETURN jsonb_build_object('item_code', v_code, 'created', v_new, 'changed', v_changed);
END $$;

-- Item page extras: whether the caller may edit (and why not), names of the codes, change history.
CREATE OR REPLACE FUNCTION erp.item_info(p_company varchar, p_item text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  it erp.item;
  v_edit text;
BEGIN
  PERFORM erp._md_item_guard(p_company, false);
  SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = p_item;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF it.source <> 'erp' THEN
    v_edit := erp._md_sap_msg('item', p_company);
  ELSIF NOT (erp.can_write('inventory') OR erp.can_write('purchase')) THEN
    v_edit := 'You have read-only access to items. Ask the system admin for full Inventory access to create or change items.';
  END IF;
  RETURN jsonb_build_object(
    'item', to_jsonb(it) || jsonb_build_object(
       'group_name', (SELECT name FROM erp.item_group WHERE company_code = p_company AND group_code = it.group_code),
       'brand_name', (SELECT name FROM erp.brand WHERE company_code = p_company AND firm_code = it.firm_code),
       'supplier_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = it.preferred_supplier),
       'tax_name', (SELECT name FROM erp.tax_code WHERE company_code = p_company AND code = it.tax_code),
       'on_hand', (SELECT coalesce(sum(on_hand), 0) FROM erp.stock_balance WHERE company_code = p_company AND item_code = p_item)),
    'can_edit', v_edit IS NULL, 'edit_reason', v_edit,
    'history', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor), 'detail', l.detail)
                                          ORDER BY l.at DESC, l.audit_id DESC), '[]'::jsonb)
                  FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                 WHERE l.company_code = p_company AND l.object = 'item' AND l.object_ref = p_item));
END $$;

-- ============ API: setup lists for the partner and item forms ============
CREATE OR REPLACE FUNCTION erp.master_data_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  co erp.company;
  st erp.master_setting;
  v_bp boolean; v_it boolean;
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
  v_bp := erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance');
  v_it := erp.can_read('inventory') OR erp.can_read('sales') OR erp.can_read('purchase');
  IF NOT (v_bp OR v_it) THEN
    RAISE EXCEPTION 'Your position does not include Business Partners or Inventory. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO co FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.master_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'company_currency', co.currency, 'company_country', co.country,
    'currencies', (SELECT coalesce(jsonb_agg(c ORDER BY c <> co.currency, c), '[]'::jsonb) FROM (
                     SELECT co.currency AS c UNION SELECT currency FROM erp.fx_rate WHERE company_code = p_company
                     UNION SELECT currency FROM erp.business_partner WHERE company_code = p_company AND currency IS NOT NULL) x),
    'bp_groups', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', group_code, 'name', name, 'kind', kind) ORDER BY group_code), '[]'::jsonb)
                    FROM erp.bp_group WHERE company_code = p_company),
    'payment_terms', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', group_num, 'name', name) ORDER BY group_num), '[]'::jsonb)
                        FROM erp.payment_terms WHERE company_code = p_company),
    'price_lists', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', list_num, 'name', name) ORDER BY list_num), '[]'::jsonb)
                      FROM erp.price_list WHERE company_code = p_company),
    'salespeople', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', slp_code, 'name', name) ORDER BY slp_code), '[]'::jsonb)
                      FROM erp.salesperson WHERE company_code = p_company AND active),
    'item_groups', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', group_code, 'name', name) ORDER BY group_code), '[]'::jsonb)
                      FROM erp.item_group WHERE company_code = p_company),
    'brands', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', firm_code, 'name', name) ORDER BY name), '[]'::jsonb)
                 FROM erp.brand WHERE company_code = p_company),
    'tax_codes', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'rate', rate) ORDER BY code), '[]'::jsonb)
                    FROM erp.tax_code WHERE company_code = p_company AND active),
    'uoms', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM (
               SELECT sales_uom AS x FROM erp.item WHERE company_code = p_company AND sales_uom IS NOT NULL
               UNION SELECT purchase_uom FROM erp.item WHERE company_code = p_company AND purchase_uom IS NOT NULL
               UNION SELECT inventory_uom FROM erp.item WHERE company_code = p_company AND inventory_uom IS NOT NULL) s),
    'sourcing_types', to_jsonb(coalesce(st.sourcing_types, '{OEM,ODM}')),
    'bp_required', to_jsonb(coalesce(st.bp_required, '{}')), 'item_required', to_jsonb(coalesce(st.item_required, '{}')),
    'dup_name_similarity', coalesce(st.dup_name_similarity, 0.8),
    'numbering', (SELECT jsonb_object_agg(CASE obj_type WHEN 2001 THEN 'customer' WHEN 2002 THEN 'supplier' ELSE 'lead' END,
                                          prefix || lpad(next_num::text, pad, '0'))
                    FROM erp.number_series WHERE company_code = p_company AND obj_type IN (2001, 2002, 2003) AND active),
    'credit_approvers', erp._md_rules(p_company, 'bp_credit_limit', u.position_code),
    'bank_approvers', erp._md_rules(p_company, 'bp_bank_detail', u.position_code),
    'can_read_bp', v_bp, 'can_read_items', v_it,
    'can_write_bp', jsonb_build_object(
       'customer', v_bp AND (erp.can_write('bp') OR erp.can_write('finance') OR erp.can_write('sales')),
       'lead', v_bp AND (erp.can_write('bp') OR erp.can_write('finance') OR erp.can_write('sales')),
       'supplier', v_bp AND (erp.can_write('bp') OR erp.can_write('finance') OR erp.can_write('purchase'))),
    'can_write_items', v_it AND (erp.can_write('inventory') OR erp.can_write('purchase')));
END $$;

-- Mandatory fields, similarity threshold and sourcing types per company (system admin with full Administration access).
CREATE OR REPLACE FUNCTION erp.master_setting_set(p_company varchar, p_setting jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s jsonb := coalesce(p_setting, '{}'::jsonb);
  v_bp text[]; v_it text[]; v_sim numeric; v_src text[];
  v_old jsonb;
  bad text;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF NOT erp.can_write('admin') THEN
    RAISE EXCEPTION 'Only a system admin with full Administration access can change master data settings.' USING ERRCODE = '42501';
  END IF;
  SELECT to_jsonb(m) - 'updated_by' - 'updated_at' INTO v_old FROM erp.master_setting m WHERE company_code = p_company;
  IF s ? 'bp_required' THEN
    SELECT array_agg(x) INTO v_bp FROM jsonb_array_elements_text(s->'bp_required') x;
    SELECT x INTO bad FROM unnest(coalesce(v_bp, '{}')) x WHERE x NOT IN ('foreign_name', 'group_code', 'currency', 'trn', 'phone', 'mobile', 'email',
           'payment_terms', 'price_list', 'slp_code', 'city', 'country', 'credit_limit', 'contacts', 'addresses') LIMIT 1;
    IF bad IS NOT NULL THEN
      RAISE EXCEPTION 'Partner field % can''t be made mandatory.', bad USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF s ? 'item_required' THEN
    SELECT array_agg(x) INTO v_it FROM jsonb_array_elements_text(s->'item_required') x;
    SELECT x INTO bad FROM unnest(coalesce(v_it, '{}')) x WHERE x NOT IN ('foreign_name', 'group_code', 'firm_code', 'barcode', 'hs_code', 'moq',
           'sales_uom', 'purchase_uom', 'inventory_uom', 'sourcing_type', 'preferred_supplier', 'tax_code', 'supplier_part_no') LIMIT 1;
    IF bad IS NOT NULL THEN
      RAISE EXCEPTION 'Item field % can''t be made mandatory.', bad USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF s ? 'dup_name_similarity' THEN
    v_sim := erp._num(s->>'dup_name_similarity');
    IF v_sim IS NULL OR v_sim NOT BETWEEN 0.5 AND 1 THEN
      RAISE EXCEPTION 'The name similarity for duplicate warnings must be between 0.5 and 1.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF s ? 'sourcing_types' THEN
    SELECT array_agg(DISTINCT upper(btrim(x))) INTO v_src FROM jsonb_array_elements_text(s->'sourcing_types') x WHERE btrim(x) <> '';
  END IF;
  INSERT INTO erp.master_setting (company_code, bp_required, item_required, dup_name_similarity, sourcing_types, updated_by, updated_at)
  VALUES (p_company, coalesce(v_bp, '{}'), coalesce(v_it, '{}'), coalesce(v_sim, 0.8), coalesce(v_src, '{OEM,ODM}'), erp.current_user_id(), now())
  ON CONFLICT (company_code) DO UPDATE
    SET bp_required = CASE WHEN s ? 'bp_required' THEN coalesce(v_bp, '{}') ELSE master_setting.bp_required END,
        item_required = CASE WHEN s ? 'item_required' THEN coalesce(v_it, '{}') ELSE master_setting.item_required END,
        dup_name_similarity = coalesce(v_sim, master_setting.dup_name_similarity),
        sourcing_types = coalesce(v_src, master_setting.sourcing_types),
        updated_by = erp.current_user_id(), updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'master_setting_set', 'master_setting', p_company,
          jsonb_build_object('before', v_old, 'after', (SELECT to_jsonb(m) - 'updated_by' - 'updated_at' FROM erp.master_setting m WHERE company_code = p_company)));
  RETURN (SELECT to_jsonb(m) FROM erp.master_setting m WHERE company_code = p_company);
END $$;

-- ============ Approvals inbox (replaces 22's): the 9 earlier branches exactly as before, plus partner change requests ============
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
REVOKE ALL ON FUNCTION erp._md_trgms(text), erp._md_trgm_sim2(text[], text[]), erp._md_trgm_sim(text, text), erp._md_digits(text),
  erp._md_bp_guard(varchar, boolean, text), erp._md_item_guard(varchar, boolean), erp._md_sap_msg(text, varchar), erp._md_rules(varchar, text, text),
  erp._md_label(text), erp._bp_eval(varchar, jsonb, erp.app_user), erp._md_next_code(varchar, text), erp._md_open_approvals(varchar, integer, jsonb, uuid),
  erp._bp_bank_apply(varchar, text, integer, jsonb, uuid, uuid, integer), erp._md_req_guard(varchar), erp._item_eval(varchar, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.bp_checks(varchar, jsonb), erp.bp_save(varchar, jsonb, text, text), erp.bp_bank_account_save(varchar, text, jsonb),
  erp.bp_change_decide(varchar, integer, text, text), erp.bp_change_cancel(varchar, integer, text), erp.bp_info(varchar, text),
  erp.item_checks(varchar, jsonb), erp.item_save(varchar, jsonb, text), erp.item_info(varchar, text), erp.master_data_setup(varchar),
  erp.master_setting_set(varchar, jsonb), erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.bp_checks(varchar, jsonb), erp.bp_save(varchar, jsonb, text, text), erp.bp_bank_account_save(varchar, text, jsonb),
  erp.bp_change_decide(varchar, integer, text, text), erp.bp_change_cancel(varchar, integer, text), erp.bp_info(varchar, text),
  erp.item_checks(varchar, jsonb), erp.item_save(varchar, jsonb, text), erp.item_info(varchar, text), erp.master_data_setup(varchar),
  erp.master_setting_set(varchar, jsonb), erp.approval_inbox()
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Partner codes C00001 / S00001 / L00001 (the sample SAP stand-ins use 4 digits, so they never collide).
INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad)
SELECT 'ZZ99', v.obj, v.prefix, 1, 5
  FROM (VALUES (2001, 'C'), (2002, 'S'), (2003, 'L')) AS v(obj, prefix)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, obj_type) DO NOTHING;

INSERT INTO erp.master_setting (company_code, bp_required, item_required, note)
SELECT 'ZZ99', '{group_code,payment_terms}', '{group_code,inventory_uom}', 'SAMPLE setting for test company ZZ99 only'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code) DO NOTHING;

-- Credit limit changes by anyone → QA · finance manager. Bank detail changes made by QA · business partners → QA · finance
-- manager (A5's tests change bank details as QA · finance and expect them to apply at once, with A5's 30-day payment block).
INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, note)
SELECT 'ZZ99', 2, v.rule, v.pos, NULL, v.appr, 1, 'SAMPLE rule for test company ZZ99 only'
  FROM (VALUES ('bp_credit_limit', NULL, 'QA_FIN_MGR'), ('bp_bank_detail', 'QA_BP', 'QA_FIN_MGR')) AS v(rule, pos, appr)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
   AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.appr)
   AND (v.pos IS NULL OR EXISTS (SELECT 1 FROM erp.position WHERE position_code = v.pos))
ON CONFLICT (company_code, obj_type, rule_code, (coalesce(position_code, '')), step) DO NOTHING;

-- Trademark Master (SAP user-defined table @TRADEMARK) stays as migrated; two sample rows so the read-only screen has data.
INSERT INTO erp.trademark (company_code, code, trademark_no, description, class, country, valid_from, valid_to)
SELECT 'ZZ99', v.code, v.no, v.descr, v.cls, v.country, v.vf::date, v.vt::date
  FROM (VALUES ('TM-SMP-01', 'SMP-000001', 'SAMPLE brand · kitchen appliances (test data)', 11, 'AE', '2020-01-01', '2030-01-01'),
               ('TM-SMP-02', 'SMP-000002', 'SAMPLE brand · personal care (test data)', 8, 'SA', '2021-06-01', '2031-06-01')) AS v(code, no, descr, cls, country, vf, vt)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT (company_code, code) DO NOTHING;
