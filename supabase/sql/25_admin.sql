-- A10 · Administration. Safe to run twice. Does not edit 10–24.
-- Replaces (CREATE OR REPLACE): erp.can_see (also requires an active app_user), erp.approval_inbox (11 earlier kinds + company_details).
--
-- Access: Administration screens are for system admin and IT positions (and the owner, who approves company details).
--   read  = module_level('admin') or module_level('it') or module_level('business') is set
--   write = erp.can_write('admin')  (Administration FULL). Exchange rates: Finance full or Administration full.
-- Lock-out guards: nobody can deactivate themselves, change their own position or remove Administration full from their own
-- position, so at least one active admin always remains (the one making the change).
--
-- Objects
--   users        user_invite, admin_users, admin_employee_options, admin_user_save, admin_invite_create, admin_invite_cancel,
--                admin_invite_link (service_role only: called by the invite-user Edge Function after the Supabase Admin API
--                created the auth user. The service key never reaches the browser.)
--   positions    admin_positions, position_save, position_delete, position_access_preview, position_access_save (on A1's set_position_module)
--   approvals    approval_template_setup, approval_rule_save, approval_rule_delete (erp.approval_rule from A2–A8).
--                Approvals are copied into erp.approval when a document is submitted, so a template change applies to new documents only.
--   numbering    number_series_setup, number_series_save (erp.number_series from A2)
--   company      admin_setting (owner position, rate currencies), company_profile (print details), company_change_request
--                (owner approval, erp.approval object 'company_details'), company_details_info / submit / decide / cancel,
--                company_print_info, admin_setting_save; storage bucket 'branding' (<company>/<file>)
--   rates        fx_rate_entry (Super ERP rates; SAP's erp.fx_rate is never written), view fx_rate_list, fx_setup, fx_rate_save, fx_rate_import
--   AI           ai_setting (no key column: the provider key is a Supabase secret read only by the ai-assistant Edge Function),
--                ai_usage, ai_setup, ai_setting_save, ai_request_check, ai_usage_record (service_role only)
--   audit        admin_audit_recent
-- No business rule is invented: owner position, currencies, limits and the AI provider are settings. Real companies start empty.

GRANT USAGE ON SCHEMA erp TO service_role;

-- ============ can_see: a deactivated user sees no company ============
CREATE OR REPLACE FUNCTION erp.can_see(p_company varchar) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp AS $$
  SELECT EXISTS (SELECT 1 FROM erp.user_company uc JOIN erp.app_user u ON u.user_id = uc.user_id
                  WHERE uc.user_id = erp.current_user_id() AND uc.company_code = p_company AND u.active)
$$;

-- ============ Tables ============
CREATE TABLE IF NOT EXISTS erp.admin_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    owner_position text REFERENCES erp.position ON DELETE SET NULL,     -- approves company detail changes
    fx_currencies  text[] NOT NULL DEFAULT '{USD,SAR,CNY,EUR}',          -- currencies in the daily rates table (A10 prompt)
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.user_invite (
    invite_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email          text NOT NULL,
    display_name   text NOT NULL,
    position_code  text NOT NULL REFERENCES erp.position,
    company_code   varchar(8) NOT NULL REFERENCES erp.company,
    companies      varchar(8)[] NOT NULL,
    emp_id         integer,
    language       text NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'ar')),
    mobile         text,
    state          text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sent', 'cancelled')),
    user_id        uuid,
    invited_by     uuid NOT NULL,
    invited_at     timestamptz NOT NULL DEFAULT now(),
    sent_at        timestamptz,
    cancelled_at   timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS user_invite_pending_uniq ON erp.user_invite (lower(email)) WHERE state = 'pending';

CREATE TABLE IF NOT EXISTS erp.company_profile (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    legal_name     text,
    trading_name   text,
    tax_id         text,
    licence_no     text,
    address        text,
    phone          text,
    email          text,
    logo_path      text,                               -- storage bucket 'branding', <company>/<file>
    fiscal_year_start smallint CHECK (fiscal_year_start BETWEEN 1 AND 12),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    requested_by   uuid,
    approved_by    uuid
);

CREATE TABLE IF NOT EXISTS erp.company_change_request (
    request_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    before         jsonb NOT NULL,
    after          jsonb NOT NULL,
    reason         text,
    state          text NOT NULL DEFAULT 'pending_approval' CHECK (state IN ('pending_approval', 'approved', 'rejected', 'cancelled')),
    requested_by   uuid NOT NULL,
    requested_at   timestamptz NOT NULL DEFAULT now(),
    decided_by     uuid,
    decided_at     timestamptz,
    note           text
);
CREATE UNIQUE INDEX IF NOT EXISTS company_change_pending_uniq ON erp.company_change_request (company_code) WHERE state = 'pending_approval';

CREATE TABLE IF NOT EXISTS erp.fx_rate_entry (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    rate_date      date NOT NULL,
    currency       varchar(3) NOT NULL,
    rate           numeric(19,6) NOT NULL CHECK (rate > 0),   -- company currency per 1 unit of the currency
    source         text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'import')),
    entered_by     uuid NOT NULL,
    entered_by_name text,
    entered_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, rate_date, currency)
);

CREATE TABLE IF NOT EXISTS erp.ai_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    enabled        boolean NOT NULL DEFAULT false,
    chat_provider  text CHECK (chat_provider IN ('google', 'openai', 'anthropic', 'azure_openai')),
    chat_model     text,
    voice_provider text CHECK (voice_provider IN ('google', 'openai', 'elevenlabs', 'azure')),
    allowed_modules text[] NOT NULL DEFAULT '{}',
    allowed_tables text[] NOT NULL DEFAULT '{}',
    monthly_limit  integer CHECK (monthly_limit BETWEEN 1 AND 1000000),   -- requests per calendar month
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.ai_usage (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    month          text NOT NULL CHECK (month ~ '^\d{4}-\d{2}$'),
    requests       integer NOT NULL DEFAULT 0,
    tokens         bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (company_code, month)
);

-- ============ Read access (no write grants) ============
ALTER TABLE erp.admin_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.user_invite ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.company_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.company_change_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.fx_rate_entry ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.ai_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.ai_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.admin_setting, erp.user_invite, erp.company_profile, erp.company_change_request, erp.fx_rate_entry,
  erp.ai_setting, erp.ai_usage FROM PUBLIC, anon, authenticated;
-- user_invite, company_change_request, ai_usage: functions only.
GRANT SELECT ON erp.admin_setting, erp.company_profile, erp.fx_rate_entry, erp.ai_setting TO authenticated;

DROP POLICY IF EXISTS admin_setting_read ON erp.admin_setting;
CREATE POLICY admin_setting_read ON erp.admin_setting FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS company_profile_read ON erp.company_profile;
CREATE POLICY company_profile_read ON erp.company_profile FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS fx_rate_entry_read ON erp.fx_rate_entry;
CREATE POLICY fx_rate_entry_read ON erp.fx_rate_entry FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.can_read('finance')));
DROP POLICY IF EXISTS ai_setting_read ON erp.ai_setting;
CREATE POLICY ai_setting_read ON erp.ai_setting FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.module_level('admin')) IS NOT NULL OR (SELECT erp.module_level('it')) IS NOT NULL));

-- Daily rates: SAP's rates (erp.fx_rate, read-only) and Super ERP's, side by side. The reader's own row rules apply.
CREATE OR REPLACE VIEW erp.fx_rate_list WITH (security_invoker = true) AS
  SELECT f.company_code, f.rate_date, f.currency::varchar(3) AS currency, f.rate, 'sap'::text AS source,
         NULL::text AS entered_by_name, NULL::timestamptz AS entered_at
    FROM erp.fx_rate f
  UNION ALL
  SELECT e.company_code, e.rate_date, e.currency, e.rate, e.source, e.entered_by_name, e.entered_at
    FROM erp.fx_rate_entry e;
REVOKE ALL ON erp.fx_rate_list FROM PUBLIC, anon;
GRANT SELECT ON erp.fx_rate_list TO authenticated;

-- Company logos: bucket 'branding', object names <company>/<file>. Admin full uploads; everyone in the company can read (print).
DO $$ BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets (id, name, public, file_size_limit) VALUES ('branding', 'branding', false, 2097152) ON CONFLICT (id) DO NOTHING;
    DROP POLICY IF EXISTS branding_insert ON storage.objects;
    CREATE POLICY branding_insert ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'branding' AND erp.can_see(((storage.foldername(name))[1])::varchar) AND erp.can_write('admin'));
    DROP POLICY IF EXISTS branding_select ON storage.objects;
    CREATE POLICY branding_select ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'branding' AND erp.can_see(((storage.foldername(name))[1])::varchar));
  END IF;
END $$;

-- ============ Helpers ============
CREATE OR REPLACE FUNCTION erp._adm_guard(p_write boolean) RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Your account has no active profile. Ask the system admin.' USING ERRCODE = '42501';
  END IF;
  IF p_write THEN
    IF NOT erp.can_write('admin') THEN
      RAISE EXCEPTION 'Only a system admin with full Administration access can change this.' USING ERRCODE = '42501';
    END IF;
  ELSIF erp.module_level('admin') IS NULL AND erp.module_level('it') IS NULL AND erp.module_level('business') IS NULL THEN
    RAISE EXCEPTION 'Only the system admin, IT and the owner can open Administration.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION erp._adm_company(p_company varchar) RETURNS erp.company
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c erp.company;
BEGIN
  SELECT * INTO c FROM erp.company WHERE company_code = p_company;
  IF NOT FOUND OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  RETURN c;
END $$;

CREATE OR REPLACE FUNCTION erp._adm_modules() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['admin', 'it', 'finance', 'sales', 'purchase', 'bp', 'banking', 'inventory', 'production', 'service', 'hr', 'reports', 'business']
$$;

-- Level of a module for a position: same rule as erp.module_level (a position_module row wins, else module_access = full).
CREATE OR REPLACE FUNCTION erp._adm_level(p_position text, p_module text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(pm.level, CASE WHEN p_module = ANY (p.module_access) THEN 'full' END)
    FROM erp.position p
    LEFT JOIN erp.position_module pm ON pm.position_code = p.position_code AND pm.module = p_module
   WHERE p.position_code = p_position
$$;

-- Document types that have numbering in Super ERP (SAP object types; 2001–2003 partner codes, 171 employee codes).
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
    (171, 'Employee code', 'hr', 50)) AS v(obj_type, label, module, sort)
$$;

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
    ('bp_credit_limit', ARRAY[2], false, 'none', 12), ('bp_bank_detail', ARRAY[2], false, 'none', 13)
  ) AS v(rule_code, obj_types, position_required, limit_kind, sort)
$$;

CREATE OR REPLACE FUNCTION erp._adm_name(p_user uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT display_name FROM erp.app_user WHERE user_id = p_user
$$;

-- ============ Users ============
-- Validates position, companies, home company, employee link, language and mobile for a new or existing user.
-- Companies the admin can't see are never added or removed (they are kept as they are).
CREATE OR REPLACE FUNCTION erp._adm_user_check(p jsonb, p_target uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_name  text := nullif(btrim(p->>'display_name'), '');
  v_pos   text := nullif(btrim(p->>'position_code'), '');
  v_home  varchar := nullif(btrim(p->>'company_code'), '');
  v_lang  text := coalesce(nullif(p->>'language', ''), 'en');
  v_mob   text := nullif(btrim(p->>'mobile'), '');
  v_emp   integer;
  v_list  varchar[];
  v_keep  varchar[];
  c       varchar;
BEGIN
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the person''s name.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_name) > 120 THEN
    RAISE EXCEPTION 'The name can have up to 120 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF v_pos IS NULL THEN
    RAISE EXCEPTION 'Choose a position.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_pos) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_pos USING ERRCODE = 'P0001';
  END IF;
  IF v_lang NOT IN ('en', 'ar') THEN
    RAISE EXCEPTION 'Language must be English or Arabic.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mob IS NOT NULL AND v_mob !~ '^\+?[0-9 ()-]{6,20}$' THEN
    RAISE EXCEPTION 'Enter the mobile number with digits only, for example +971 50 123 4567.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p->'companies') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'companies') = 0 THEN
    RAISE EXCEPTION 'Choose at least one company.' USING ERRCODE = 'P0001';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_list FROM jsonb_array_elements_text(p->'companies') x;
  FOREACH c IN ARRAY v_list LOOP
    IF NOT EXISTS (SELECT 1 FROM erp.company WHERE company_code = c) THEN
      RAISE EXCEPTION 'Company % does not exist.', c USING ERRCODE = 'P0001';
    END IF;
    IF NOT erp.can_see(c) THEN
      RAISE EXCEPTION 'You can only give access to companies you can see yourself. You don''t have %.', c USING ERRCODE = '42501';
    END IF;
  END LOOP;
  IF p_target IS NOT NULL THEN
    SELECT array_agg(company_code) INTO v_keep FROM erp.user_company WHERE user_id = p_target AND NOT erp.can_see(company_code);
    v_list := v_list || coalesce(v_keep, '{}');
  END IF;
  IF v_home IS NULL THEN
    RAISE EXCEPTION 'Choose the home company.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_home = ANY (v_list) THEN
    RAISE EXCEPTION 'The home company % must be one of the user''s companies.', v_home USING ERRCODE = 'P0001';
  END IF;
  IF nullif(p->>'emp_id', '') IS NOT NULL THEN
    BEGIN
      v_emp := (p->>'emp_id')::integer;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Choose the employee from the list.' USING ERRCODE = 'P0001';
    END;
    IF NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = v_home AND emp_id = v_emp) THEN
      RAISE EXCEPTION 'Employee % is not in %. Link an employee of the home company.', v_emp, v_home USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM erp.app_user WHERE company_code = v_home AND emp_id = v_emp AND user_id IS DISTINCT FROM p_target) THEN
      RAISE EXCEPTION 'Employee % is already linked to %.', v_emp,
        (SELECT display_name FROM erp.app_user WHERE company_code = v_home AND emp_id = v_emp AND user_id IS DISTINCT FROM p_target LIMIT 1)
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN jsonb_build_object('display_name', v_name, 'position_code', v_pos, 'company_code', v_home, 'language', v_lang,
                            'mobile', v_mob, 'emp_id', v_emp, 'companies', to_jsonb(v_list));
END $$;

-- Users who share a company with the admin, plus pending invitations. Last sign-in comes from auth.users when Supabase has it.
CREATE OR REPLACE FUNCTION erp.admin_users() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
BEGIN
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'me', me.user_id,
    'users', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'user_id', u.user_id, 'display_name', u.display_name, 'email', u.email, 'mobile', u.mobile,
               'position_code', u.position_code, 'position_name', p.name, 'company_code', u.company_code,
               'companies', (SELECT coalesce(jsonb_agg(uc.company_code ORDER BY uc.company_code), '[]'::jsonb) FROM erp.user_company uc WHERE uc.user_id = u.user_id),
               'emp_id', u.emp_id,
               'emp_name', (SELECT concat_ws(' ', e.first_name, e.last_name) FROM erp.employee e WHERE e.company_code = u.company_code AND e.emp_id = u.emp_id),
               'emp_code', (SELECT e.hr_code FROM erp.employee e WHERE e.company_code = u.company_code AND e.emp_id = u.emp_id),
               'language', u.language, 'active', u.active,
               'last_sign_in_at', (SELECT to_jsonb(a) ->> 'last_sign_in_at' FROM auth.users a WHERE a.id = u.user_id),
               'invited_at', (SELECT max(i.invited_at) FROM erp.user_invite i WHERE i.user_id = u.user_id))
             ORDER BY u.display_name)
        FROM erp.app_user u
        JOIN erp.position p ON p.position_code = u.position_code
       WHERE EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = u.user_id AND erp.can_see(uc.company_code))
          OR erp.can_see(u.company_code)), '[]'::jsonb),
    'invites', coalesce((
      SELECT jsonb_agg(jsonb_build_object('invite_id', i.invite_id, 'email', i.email, 'display_name', i.display_name,
               'position_code', i.position_code, 'company_code', i.company_code, 'companies', to_jsonb(i.companies),
               'invited_at', i.invited_at, 'invited_by_name', erp._adm_name(i.invited_by)) ORDER BY i.invited_at DESC)
        FROM erp.user_invite i
       WHERE i.state = 'pending' AND erp.can_see(i.company_code)), '[]'::jsonb),
    'positions', (SELECT coalesce(jsonb_agg(jsonb_build_object('position_code', position_code, 'name', name) ORDER BY name), '[]'::jsonb) FROM erp.position),
    'companies', (SELECT coalesce(jsonb_agg(jsonb_build_object('company_code', company_code, 'short_name', short_name) ORDER BY company_code), '[]'::jsonb)
                    FROM erp.company WHERE erp.can_see(company_code)));
END $$;

-- Employees of a company for the "employee link" picker: code and name only (no HR or salary data). Admin full.
CREATE OR REPLACE FUNCTION erp.admin_employee_options(p_company varchar, p_q text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s text := '%' || coalesce(btrim(p_q), '') || '%';
BEGIN
  PERFORM erp._adm_guard(true);
  PERFORM erp._adm_company(p_company);
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'name') FROM (
      SELECT jsonb_build_object('emp_id', e.emp_id, 'hr_code', e.hr_code, 'name', concat_ws(' ', e.first_name, e.last_name),
               'linked_to', (SELECT display_name FROM erp.app_user u WHERE u.company_code = e.company_code AND u.emp_id = e.emp_id LIMIT 1)) AS x
        FROM erp.employee e
       WHERE e.company_code = p_company
         AND (concat_ws(' ', e.first_name, e.last_name) ILIKE s OR coalesce(e.hr_code, '') ILIKE s OR e.emp_id::text = btrim(p_q))
       ORDER BY e.first_name LIMIT 10) q), '[]'::jsonb);
END $$;

-- Change an existing user: position, companies, home company, employee link, language, mobile, active.
CREATE OR REPLACE FUNCTION erp.admin_user_save(p_user_id uuid, p_user jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  old    erp.app_user;
  v      jsonb;
  v_act  boolean;
  v_old_c jsonb;
BEGIN
  SELECT * INTO old FROM erp.app_user WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR NOT (erp.can_see(old.company_code) OR EXISTS (SELECT 1 FROM erp.user_company uc WHERE uc.user_id = p_user_id AND erp.can_see(uc.company_code))) THEN
    RAISE EXCEPTION 'User not found. Invite new people with Invite user.' USING ERRCODE = 'P0001';
  END IF;
  v := erp._adm_user_check(p_user, p_user_id);
  v_act := coalesce((p_user->>'active')::boolean, old.active);
  IF p_user_id = me.user_id THEN
    IF v->>'position_code' <> old.position_code THEN
      RAISE EXCEPTION 'You can''t change your own position. Ask another system admin.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_act THEN
      RAISE EXCEPTION 'You can''t deactivate your own account. Ask another system admin.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  SELECT coalesce(jsonb_agg(company_code ORDER BY company_code), '[]'::jsonb) INTO v_old_c FROM erp.user_company WHERE user_id = p_user_id;

  UPDATE erp.app_user
     SET display_name = v->>'display_name', position_code = v->>'position_code', company_code = v->>'company_code',
         language = v->>'language', mobile = v->>'mobile', emp_id = (v->>'emp_id')::integer, active = v_act
   WHERE user_id = p_user_id;
  DELETE FROM erp.user_company WHERE user_id = p_user_id
     AND company_code NOT IN (SELECT jsonb_array_elements_text(v->'companies'));
  INSERT INTO erp.user_company (user_id, company_code)
  SELECT p_user_id, x FROM jsonb_array_elements_text(v->'companies') x
  ON CONFLICT DO NOTHING;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, v->>'company_code', CASE WHEN old.active AND NOT v_act THEN 'user_deactivate'
                                                     WHEN NOT old.active AND v_act THEN 'user_activate' ELSE 'user_save' END,
          'app_user', p_user_id::text,
          jsonb_build_object('before', jsonb_build_object('display_name', old.display_name, 'position_code', old.position_code,
                               'company_code', old.company_code, 'language', old.language, 'mobile', old.mobile, 'emp_id', old.emp_id,
                               'active', old.active, 'companies', v_old_c),
                             'after', v || jsonb_build_object('active', v_act)));
  RETURN jsonb_build_object('user_id', p_user_id, 'active', v_act);
END $$;

-- Step 1 of an invitation (called by the invite-user Edge Function with the admin's own session): check and record it.
CREATE OR REPLACE FUNCTION erp.admin_invite_create(p_invite jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me    erp.app_user := erp._adm_guard(true);
  v     jsonb;
  v_mail text := lower(nullif(btrim(p_invite->>'email'), ''));
  v_id  bigint;
BEGIN
  IF v_mail IS NULL THEN
    RAISE EXCEPTION 'Enter the email address.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Enter a valid email address, for example name@company.com.' USING ERRCODE = 'P0001';
  END IF;
  v := erp._adm_user_check(p_invite, NULL);
  IF EXISTS (SELECT 1 FROM erp.app_user WHERE lower(email) = v_mail) THEN
    RAISE EXCEPTION 'A user with % already exists. Change that user instead.', v_mail USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.user_invite WHERE lower(email) = v_mail AND state = 'pending') THEN
    RAISE EXCEPTION 'An invitation to % is already waiting. Cancel it first to send a new one.', v_mail USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.user_invite (email, display_name, position_code, company_code, companies, emp_id, language, mobile, invited_by)
  VALUES (v_mail, v->>'display_name', v->>'position_code', v->>'company_code',
          ARRAY(SELECT jsonb_array_elements_text(v->'companies'))::varchar[], (v->>'emp_id')::integer, v->>'language', v->>'mobile', me.user_id)
  RETURNING invite_id INTO v_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, v->>'company_code', 'user_invite', 'user_invite', v_id::text, v || jsonb_build_object('email', v_mail));
  RETURN jsonb_build_object('invite_id', v_id, 'email', v_mail, 'state', 'pending');
END $$;

-- Step 2 (service_role only): the Edge Function created the auth user with the Supabase Admin API; create the profile.
CREATE OR REPLACE FUNCTION erp.admin_invite_link(p_invite_id bigint, p_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  i erp.user_invite;
BEGIN
  IF coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'Only the invite-user server function can link an invitation.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO i FROM erp.user_invite WHERE invite_id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR i.state <> 'pending' THEN
    RAISE EXCEPTION 'Invitation % is not waiting to be sent.', p_invite_id USING ERRCODE = 'P0001';
  END IF;
  IF p_user_id IS NULL OR EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION 'This sign-in already has a Super ERP profile.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.app_user (user_id, company_code, emp_id, display_name, email, mobile, position_code, language, active)
  VALUES (p_user_id, i.company_code, i.emp_id, i.display_name, i.email, i.mobile, i.position_code, i.language, true);
  INSERT INTO erp.user_company (user_id, company_code) SELECT p_user_id, unnest(i.companies) ON CONFLICT DO NOTHING;
  UPDATE erp.user_invite SET state = 'sent', user_id = p_user_id, sent_at = now() WHERE invite_id = p_invite_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES ('system:invite-user', i.company_code, 'user_invite_sent', 'app_user', p_user_id::text,
          jsonb_build_object('invite_id', p_invite_id, 'email', i.email, 'invited_by', i.invited_by));
  RETURN jsonb_build_object('invite_id', p_invite_id, 'user_id', p_user_id, 'state', 'sent');
END $$;

CREATE OR REPLACE FUNCTION erp.admin_invite_cancel(p_invite_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(true);
  i  erp.user_invite;
BEGIN
  SELECT * INTO i FROM erp.user_invite WHERE invite_id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR NOT erp.can_see(i.company_code) THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0001';
  END IF;
  IF i.state <> 'pending' THEN
    RAISE EXCEPTION 'Only a waiting invitation can be cancelled. This one is %.', i.state USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.user_invite SET state = 'cancelled', cancelled_at = now() WHERE invite_id = p_invite_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, i.company_code, 'user_invite_cancel', 'user_invite', p_invite_id::text, jsonb_build_object('email', i.email));
  RETURN jsonb_build_object('invite_id', p_invite_id, 'state', 'cancelled');
END $$;

-- ============ Positions and the Authorizations matrix ============
CREATE OR REPLACE FUNCTION erp.admin_positions() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
BEGIN
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'), 'my_position', me.position_code, 'modules', to_jsonb(erp._adm_modules()),
    'positions', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'position_code', p.position_code, 'name', p.name,
               'levels', (SELECT coalesce(jsonb_object_agg(m, erp._adm_level(p.position_code, m)) FILTER (WHERE erp._adm_level(p.position_code, m) IS NOT NULL), '{}'::jsonb)
                            FROM unnest(erp._adm_modules()) m),
               'users', (SELECT count(*) FROM erp.app_user u WHERE u.position_code = p.position_code AND u.active),
               'rules', (SELECT count(*) FROM erp.approval_rule r WHERE p.position_code IN (r.position_code, r.approver_position)))
             ORDER BY p.name)
        FROM erp.position p), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION erp.position_save(p_code text, p_name text, p_new boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_name text := nullif(btrim(p_name), '');
  v_old  text;
BEGIN
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Enter the position name.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_name) > 80 THEN
    RAISE EXCEPTION 'The position name can have up to 80 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF p_new THEN
    IF v_code !~ '^[A-Z0-9_]{2,30}$' THEN
      RAISE EXCEPTION 'Use 2 to 30 capital letters, digits or _ for the position code, for example SALES_MGR.' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_code) THEN
      RAISE EXCEPTION 'Position % already exists.', v_code USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.position (position_code, name, module_access) VALUES (v_code, v_name, '{}');
  ELSE
    SELECT name INTO v_old FROM erp.position WHERE position_code = v_code;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_code USING ERRCODE = 'P0001';
    END IF;
    UPDATE erp.position SET name = v_name WHERE position_code = v_code;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, NULL, CASE WHEN p_new THEN 'position_create' ELSE 'position_rename' END, 'position', v_code,
          jsonb_build_object('from', v_old, 'to', v_name));
  RETURN jsonb_build_object('position_code', v_code, 'name', v_name);
END $$;

CREATE OR REPLACE FUNCTION erp.position_delete(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  n   integer;
  v_name text;
BEGIN
  SELECT name INTO v_name FROM erp.position WHERE position_code = p_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', p_code USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO n FROM erp.app_user WHERE position_code = p_code;
  IF n > 0 THEN
    RAISE EXCEPTION 'Position % still has % user(s). Move them to another position first.', p_code, n USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO n FROM erp.approval_rule WHERE p_code IN (position_code, approver_position);
  IF n > 0 THEN
    RAISE EXCEPTION 'Position % is used in % approval rule(s). Change those rules first.', p_code, n USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    DELETE FROM erp.position WHERE position_code = p_code;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'Position % is still used elsewhere (approvals, user invitations or settings), so it can''t be deleted.', p_code USING ERRCODE = 'P0001';
  END;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, NULL, 'position_delete', 'position', p_code, jsonb_build_object('name', v_name));
  RETURN jsonb_build_object('position_code', p_code, 'deleted', true);
END $$;

-- Which modules would change for a position, and which users that affects. p_levels = {"sales": "full" | "read" | "none", …}.
CREATE OR REPLACE FUNCTION erp._adm_access_diff(p_position text, p_levels jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  k text;
  v_to text;
  v_from text;
  ch jsonb := '[]'::jsonb;
  rank jsonb := '{"none": 0, "read": 1, "full": 2}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = p_position) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', coalesce(p_position, '(none)') USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_levels) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the access levels per module.' USING ERRCODE = 'P0001';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_levels) LOOP
    IF NOT k = ANY (erp._adm_modules()) THEN
      RAISE EXCEPTION 'Module % is not a known module.', k USING ERRCODE = 'P0001';
    END IF;
    v_to := coalesce(p_levels->>k, 'none');
    IF v_to NOT IN ('full', 'read', 'none') THEN
      RAISE EXCEPTION 'Access level must be Full, Read or None.' USING ERRCODE = 'P0001';
    END IF;
    v_from := coalesce(erp._adm_level(p_position, k), 'none');
    IF v_from <> v_to THEN
      ch := ch || jsonb_build_object('module', k, 'from', v_from, 'to', v_to,
                                     'gain', (rank->>v_to)::int > (rank->>v_from)::int);
    END IF;
  END LOOP;
  RETURN ch;
END $$;

CREATE OR REPLACE FUNCTION erp.position_access_preview(p_position text, p_levels jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  ch jsonb;
BEGIN
  PERFORM erp._adm_guard(false);
  ch := erp._adm_access_diff(p_position, p_levels);
  RETURN jsonb_build_object(
    'position_code', p_position, 'changes', ch,
    'gain', (SELECT coalesce(jsonb_agg(c), '[]'::jsonb) FROM jsonb_array_elements(ch) c WHERE (c->>'gain')::boolean),
    'lose', (SELECT coalesce(jsonb_agg(c), '[]'::jsonb) FROM jsonb_array_elements(ch) c WHERE NOT (c->>'gain')::boolean),
    'users', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', u.user_id, 'display_name', u.display_name, 'email', u.email) ORDER BY u.display_name)
                         FROM erp.app_user u WHERE u.position_code = p_position AND u.active), '[]'::jsonb));
END $$;

-- Saves the matrix row through A1's set_position_module (which audits each module). Takes effect on the users' next request.
CREATE OR REPLACE FUNCTION erp.position_access_save(p_position text, p_levels jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(true);
  ch jsonb;
  c  jsonb;
BEGIN
  ch := erp._adm_access_diff(p_position, p_levels);
  IF jsonb_array_length(ch) = 0 THEN
    RAISE EXCEPTION 'Nothing changed.' USING ERRCODE = 'P0001';
  END IF;
  IF p_position = me.position_code AND EXISTS (SELECT 1 FROM jsonb_array_elements(ch) x WHERE x->>'module' = 'admin' AND x->>'to' <> 'full') THEN
    RAISE EXCEPTION 'You can''t remove your own Administration access. Ask another system admin.' USING ERRCODE = 'P0001';
  END IF;
  FOR c IN SELECT * FROM jsonb_array_elements(ch) LOOP
    PERFORM erp.set_position_module(p_position, c->>'module', nullif(c->>'to', 'none'));
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, NULL, 'position_access_save', 'position', p_position,
          jsonb_build_object('changes', ch, 'users', (SELECT count(*) FROM erp.app_user WHERE position_code = p_position AND active)));
  RETURN jsonb_build_object('position_code', p_position, 'changes', ch);
END $$;

-- ============ Approval templates (erp.approval_rule) ============
CREATE OR REPLACE FUNCTION erp.approval_template_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'catalogue', (SELECT jsonb_agg(jsonb_build_object('rule_code', s.rule_code, 'obj_types', to_jsonb(s.obj_types),
                    'position_required', s.position_required, 'limit_kind', s.limit_kind) ORDER BY s.sort) FROM erp._adm_rule_spec() s),
    'positions', (SELECT coalesce(jsonb_agg(jsonb_build_object('position_code', position_code, 'name', name) ORDER BY name), '[]'::jsonb) FROM erp.position),
    'rules', coalesce((
      SELECT jsonb_agg(jsonb_build_object('rule_id', r.rule_id, 'obj_type', r.obj_type, 'rule_code', r.rule_code,
               'position_code', r.position_code, 'position_name', p.name, 'limit_value', r.limit_value,
               'approver_position', r.approver_position, 'approver_name', a.name, 'step', r.step, 'active', r.active, 'note', r.note)
             ORDER BY s.sort, r.obj_type, r.position_code NULLS FIRST, r.step)
        FROM erp.approval_rule r
        JOIN erp._adm_rule_spec() s ON s.rule_code = r.rule_code
        LEFT JOIN erp.position p ON p.position_code = r.position_code
        JOIN erp.position a ON a.position_code = r.approver_position
       WHERE r.company_code = p_company), '[]'::jsonb),
    'pending', (SELECT count(*) FROM erp.approval ap WHERE ap.company_code = p_company AND ap.decision IS NULL AND NOT ap.superseded),
    'leave', (SELECT jsonb_build_object('long_leave_days', hs.long_leave_days, 'hr_approver_position', hs.hr_approver_position, 'owner_position', hs.owner_position)
                FROM erp.hr_setting hs WHERE hs.company_code = p_company));
END $$;

-- Create (no rule_id) or change a rule. Documents already waiting keep the approvers they were sent to.
CREATE OR REPLACE FUNCTION erp.approval_rule_save(p_company varchar, p_rule jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  s      record;
  old    erp.approval_rule;
  v_id   bigint := nullif(p_rule->>'rule_id', '')::bigint;
  v_code text := nullif(p_rule->>'rule_code', '');
  v_obj  integer;
  v_pos  text := nullif(btrim(p_rule->>'position_code'), '');
  v_appr text := nullif(btrim(p_rule->>'approver_position'), '');
  v_lim  numeric;
  v_step integer := coalesce(nullif(p_rule->>'step', '')::integer, 1);
  v_act  boolean := coalesce((p_rule->>'active')::boolean, true);
  v_note text := nullif(btrim(p_rule->>'note'), '');
BEGIN
  PERFORM erp._adm_company(p_company);
  IF v_id IS NOT NULL THEN
    SELECT * INTO old FROM erp.approval_rule WHERE rule_id = v_id AND company_code = p_company FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Approval rule % not found in %.', v_id, p_company USING ERRCODE = 'P0001';
    END IF;
    v_code := coalesce(v_code, old.rule_code);
  END IF;
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Choose the approval rule.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM erp._adm_rule_spec() x WHERE x.rule_code = v_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rule % is not a known approval rule.', v_code USING ERRCODE = 'P0001';
  END IF;
  v_obj := coalesce(nullif(p_rule->>'obj_type', '')::integer, old.obj_type, s.obj_types[1]);
  IF NOT v_obj = ANY (s.obj_types) THEN
    RAISE EXCEPTION 'This rule applies to document type % only.', array_to_string(s.obj_types, ' or ') USING ERRCODE = 'P0001';
  END IF;
  IF s.position_required AND v_pos IS NULL THEN
    RAISE EXCEPTION 'This limit is set per position. Choose the requester''s position.' USING ERRCODE = 'P0001';
  END IF;
  IF v_pos IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_pos) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_pos USING ERRCODE = 'P0001';
  END IF;
  IF v_appr IS NULL THEN
    RAISE EXCEPTION 'Choose who approves.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_appr) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_appr USING ERRCODE = 'P0001';
  END IF;
  IF v_step NOT BETWEEN 1 AND 9 THEN
    RAISE EXCEPTION 'The step must be between 1 and 9.' USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_lim := nullif(p_rule->>'limit_value', '')::numeric;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the limit as a number.' USING ERRCODE = 'P0001';
  END;
  IF s.limit_kind = 'none' THEN
    v_lim := NULL;
  ELSIF v_lim IS NULL THEN
    RAISE EXCEPTION 'Enter the limit for this rule.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'pct' AND v_lim NOT BETWEEN 0 AND 100 THEN
    RAISE EXCEPTION 'Enter a percentage between 0 and 100.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'pct_any' AND (v_lim <= 0 OR v_lim > 1000) THEN
    RAISE EXCEPTION 'Enter a percentage above 0 and up to 1000.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'amount' AND v_lim < 0 THEN
    RAISE EXCEPTION 'The amount can''t be negative.' USING ERRCODE = 'P0001';
  ELSIF s.limit_kind = 'days' AND (v_lim <> trunc(v_lim) OR v_lim NOT BETWEEN 1 AND 365) THEN
    RAISE EXCEPTION 'Enter whole days between 1 and 365.' USING ERRCODE = 'P0001';
  END IF;

  BEGIN
    IF v_id IS NULL THEN
      INSERT INTO erp.approval_rule (company_code, obj_type, rule_code, position_code, limit_value, approver_position, step, active, note)
      VALUES (p_company, v_obj, v_code, v_pos, v_lim, v_appr, v_step, v_act, v_note)
      RETURNING rule_id INTO v_id;
    ELSE
      UPDATE erp.approval_rule
         SET obj_type = v_obj, rule_code = v_code, position_code = v_pos, limit_value = v_lim, approver_position = v_appr,
             step = v_step, active = v_act, note = v_note
       WHERE rule_id = v_id;
    END IF;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'This rule already exists for that position and step. Change the existing rule instead.' USING ERRCODE = 'P0001';
  END;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, CASE WHEN old.rule_id IS NULL THEN 'approval_rule_create' ELSE 'approval_rule_change' END,
          'approval_rule', v_id::text,
          jsonb_build_object('before', CASE WHEN old.rule_id IS NULL THEN NULL ELSE to_jsonb(old) END,
                             'after', (SELECT to_jsonb(r) FROM erp.approval_rule r WHERE r.rule_id = v_id)));
  RETURN jsonb_build_object('rule_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION erp.approval_rule_delete(p_company varchar, p_rule_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me  erp.app_user := erp._adm_guard(true);
  old erp.approval_rule;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO old FROM erp.approval_rule WHERE rule_id = p_rule_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval rule % not found in %.', p_rule_id, p_company USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM erp.approval_rule WHERE rule_id = p_rule_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'approval_rule_delete', 'approval_rule', p_rule_id::text, jsonb_build_object('before', to_jsonb(old)));
  RETURN jsonb_build_object('rule_id', p_rule_id, 'deleted', true);
END $$;

-- ============ Document numbering (erp.number_series) ============
CREATE OR REPLACE FUNCTION erp.number_series_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'series', (SELECT jsonb_agg(jsonb_build_object('obj_type', d.obj_type, 'label', d.label, 'module', d.module,
                 'prefix', n.prefix, 'next_num', n.next_num, 'pad', n.pad, 'active', n.active,
                 'example', CASE WHEN n.prefix IS NOT NULL THEN n.prefix || lpad(n.next_num::text, n.pad, '0') END) ORDER BY d.sort)
                 FROM erp._adm_doc_types() d
                 LEFT JOIN erp.number_series n ON n.company_code = p_company AND n.obj_type = d.obj_type));
END $$;

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
  SELECT d.label INTO v_other FROM erp.number_series n JOIN erp._adm_doc_types() d ON d.obj_type = n.obj_type
   WHERE n.company_code = p_company AND n.obj_type <> p_obj AND upper(n.prefix) = upper(v_pre) LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'Prefix % is already used by %. Choose a different prefix.', v_pre, v_other USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO old FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj FOR UPDATE;
  IF FOUND AND old.prefix = v_pre AND p_next < old.next_num THEN
    RAISE EXCEPTION 'Numbers only move forward: % has already reached %. Use a higher number or a new prefix.',
      v_lab, old.prefix || lpad(old.next_num::text, old.pad, '0') USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_no = v_pre || lpad(p_next::text, v_pad, '0')) THEN
    RAISE EXCEPTION 'Number % is already used. Choose a higher next number.', v_pre || lpad(p_next::text, v_pad, '0') USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad, active)
  VALUES (p_company, p_obj, v_pre, p_next, v_pad, coalesce(p_active, true))
  ON CONFLICT (company_code, obj_type) DO UPDATE SET prefix = EXCLUDED.prefix, next_num = EXCLUDED.next_num, pad = EXCLUDED.pad, active = EXCLUDED.active;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'number_series_save', 'number_series', p_obj::text,
          jsonb_build_object('before', CASE WHEN old.obj_type IS NULL THEN NULL ELSE to_jsonb(old) END,
                             'after', jsonb_build_object('prefix', v_pre, 'next_num', p_next, 'pad', v_pad, 'active', coalesce(p_active, true))));
  RETURN jsonb_build_object('obj_type', p_obj, 'example', v_pre || lpad(p_next::text, v_pad, '0'));
END $$;

-- ============ Company details (print) with owner approval ============
CREATE OR REPLACE FUNCTION erp._adm_profile(p_company varchar) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'legal_name', coalesce(cp.legal_name, c.legal_name), 'trading_name', coalesce(cp.trading_name, c.short_name),
    'tax_id', coalesce(cp.tax_id, c.tax_id), 'licence_no', cp.licence_no, 'address', cp.address, 'phone', cp.phone,
    'email', cp.email, 'logo_path', cp.logo_path, 'fiscal_year_start', cp.fiscal_year_start)
    FROM erp.company c LEFT JOIN erp.company_profile cp ON cp.company_code = c.company_code
   WHERE c.company_code = p_company
$$;

-- What a printed document shows for the company (every user of the company may read it).
CREATE OR REPLACE FUNCTION erp.company_print_info(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  PERFORM erp._adm_company(p_company);
  RETURN erp._adm_profile(p_company) || jsonb_build_object('company_code', p_company,
           'currency', (SELECT currency FROM erp.company WHERE company_code = p_company));
END $$;

CREATE OR REPLACE FUNCTION erp.company_details_info(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(false);
  c  erp.company := erp._adm_company(p_company);
  s  erp.admin_setting;
  q  erp.company_change_request;
BEGIN
  SELECT * INTO s FROM erp.admin_setting WHERE company_code = p_company;
  SELECT * INTO q FROM erp.company_change_request WHERE company_code = p_company AND state = 'pending_approval';
  RETURN jsonb_build_object(
    'company', jsonb_build_object('company_code', c.company_code, 'legal_name', c.legal_name, 'short_name', c.short_name,
                 'country', c.country, 'currency', c.currency, 'licence_type', c.licence_type, 'licence_authority', c.licence_authority),
    'profile', erp._adm_profile(p_company),
    'setting', jsonb_build_object('owner_position', s.owner_position,
                 'owner_position_name', (SELECT name FROM erp.position WHERE position_code = s.owner_position),
                 'fx_currencies', to_jsonb(coalesce(s.fx_currencies, '{USD,SAR,CNY,EUR}'::text[]))),
    'can_write', erp.can_write('admin'),
    'pending', CASE WHEN q.request_id IS NULL THEN NULL ELSE jsonb_build_object(
                 'request_id', q.request_id, 'before', q.before, 'after', q.after, 'reason', q.reason,
                 'requested_by_name', erp._adm_name(q.requested_by), 'requested_at', q.requested_at,
                 'is_requester', q.requested_by = me.user_id,
                 'approver_position', (SELECT a.approver_position FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'company_details'
                                         AND a.object_ref = q.request_id::text AND a.decision IS NULL AND NOT a.superseded LIMIT 1),
                 'can_decide', EXISTS (SELECT 1 FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'company_details'
                                         AND a.object_ref = q.request_id::text AND a.decision IS NULL AND NOT a.superseded
                                         AND a.approver_position = me.position_code)
                               AND q.requested_by <> me.user_id) END,
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object('request_id', h.request_id, 'state', h.state, 'after', h.after, 'reason', h.reason,
                 'requested_by_name', erp._adm_name(h.requested_by), 'requested_at', h.requested_at,
                 'decided_by_name', erp._adm_name(h.decided_by), 'decided_at', h.decided_at, 'note', h.note) ORDER BY h.requested_at DESC)
                 FROM (SELECT * FROM erp.company_change_request WHERE company_code = p_company AND state <> 'pending_approval'
                        ORDER BY requested_at DESC LIMIT 10) h), '[]'::jsonb));
END $$;

-- Owner position and rate currencies per company (Administration full).
CREATE OR REPLACE FUNCTION erp.admin_setting_save(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me    erp.app_user := erp._adm_guard(true);
  c     erp.company := erp._adm_company(p_company);
  old   erp.admin_setting;
  v_own text;
  v_cur text[];
  x     text;
BEGIN
  SELECT * INTO old FROM erp.admin_setting WHERE company_code = p_company;
  v_own := CASE WHEN p ? 'owner_position' THEN nullif(btrim(p->>'owner_position'), '') ELSE old.owner_position END;
  IF v_own IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = v_own) THEN
      RAISE EXCEPTION 'Position % does not exist. Check the position code.', v_own USING ERRCODE = 'P0001';
    END IF;
    IF erp._adm_level(v_own, 'business') IS NULL THEN
      RAISE EXCEPTION 'Position % has no Owner (Business) access, so it can''t approve company changes.', v_own USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p ? 'fx_currencies' THEN
    IF jsonb_typeof(p->'fx_currencies') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Send the currencies as a list.' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT upper(btrim(e))) INTO v_cur FROM jsonb_array_elements_text(p->'fx_currencies') e;
    FOREACH x IN ARRAY coalesce(v_cur, '{}') LOOP
      IF x !~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'Currency % is not a 3-letter code such as USD.', x USING ERRCODE = 'P0001';
      END IF;
      IF x = c.currency THEN
        RAISE EXCEPTION '% is the company currency. The rates table lists the other currencies.', x USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
  ELSE
    v_cur := coalesce(old.fx_currencies, '{USD,SAR,CNY,EUR}');
  END IF;
  INSERT INTO erp.admin_setting (company_code, owner_position, fx_currencies, updated_by, updated_at)
  VALUES (p_company, v_own, coalesce(v_cur, '{}'), me.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET owner_position = EXCLUDED.owner_position, fx_currencies = EXCLUDED.fx_currencies,
                                          updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'admin_setting_save', 'admin_setting', p_company,
          jsonb_build_object('before', jsonb_build_object('owner_position', old.owner_position, 'fx_currencies', old.fx_currencies),
                             'after', jsonb_build_object('owner_position', v_own, 'fx_currencies', v_cur)));
  RETURN jsonb_build_object('owner_position', v_own, 'fx_currencies', to_jsonb(v_cur));
END $$;

-- Ask for a change to the printed company details. The owner position approves it before it applies.
CREATE OR REPLACE FUNCTION erp.company_details_submit(p_company varchar, p_changes jsonb, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me     erp.app_user := erp._adm_guard(true);
  c      erp.company := erp._adm_company(p_company);
  v_own  text;
  v_cur  jsonb := erp._adm_profile(p_company);
  v_new  jsonb;
  k      text;
  v_id   bigint;
  v_fy   text;
BEGIN
  IF jsonb_typeof(p_changes) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the changed fields.' USING ERRCODE = 'P0001';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_changes) LOOP
    IF k NOT IN ('legal_name', 'trading_name', 'tax_id', 'licence_no', 'address', 'phone', 'email', 'logo_path', 'fiscal_year_start') THEN
      RAISE EXCEPTION 'Field % can''t be changed here.', k USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  -- Normalise: trimmed text, empty = NULL.
  SELECT jsonb_object_agg(key, CASE WHEN jsonb_typeof(value) = 'string' THEN to_jsonb(nullif(btrim(value #>> '{}'), '')) ELSE value END)
    INTO v_new FROM jsonb_each(p_changes);
  v_new := v_cur || coalesce(v_new, '{}'::jsonb);
  IF v_new->>'legal_name' IS NULL THEN
    RAISE EXCEPTION 'Enter the legal name.' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_new->>'legal_name') > 200 THEN
    RAISE EXCEPTION 'The legal name can have up to 200 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF c.country = 'AE' AND v_new->>'tax_id' IS NOT NULL AND v_new->>'tax_id' !~ '^\d{15}$' THEN
    RAISE EXCEPTION 'A UAE TRN has 15 digits. Check the number on the VAT certificate.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new->>'email' IS NOT NULL AND v_new->>'email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Enter a valid email address, for example accounts@company.com.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new->>'phone' IS NOT NULL AND v_new->>'phone' !~ '^\+?[0-9 ()-]{6,20}$' THEN
    RAISE EXCEPTION 'Enter the phone number with digits only, for example +971 4 123 4567.' USING ERRCODE = 'P0001';
  END IF;
  IF v_new->>'logo_path' IS NOT NULL AND v_new->>'logo_path' NOT LIKE p_company || '/%' THEN
    RAISE EXCEPTION 'The logo must be stored under %/ in the branding bucket.', p_company USING ERRCODE = 'P0001';
  END IF;
  v_fy := v_new->>'fiscal_year_start';
  IF v_fy IS NOT NULL AND (v_fy !~ '^\d{1,2}$' OR v_fy::int NOT BETWEEN 1 AND 12) THEN
    RAISE EXCEPTION 'Choose the month the fiscal year starts (1 to 12).' USING ERRCODE = 'P0001';
  END IF;
  IF v_fy IS NOT NULL THEN
    v_new := jsonb_set(v_new, '{fiscal_year_start}', to_jsonb(v_fy::int));
  END IF;
  IF v_new = v_cur THEN
    RAISE EXCEPTION 'Nothing changed.' USING ERRCODE = 'P0001';
  END IF;
  SELECT owner_position INTO v_own FROM erp.admin_setting WHERE company_code = p_company;
  IF v_own IS NULL THEN
    RAISE EXCEPTION 'Set the owner position for % first. The owner approves changes to company details.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.company_change_request WHERE company_code = p_company AND state = 'pending_approval') THEN
    RAISE EXCEPTION 'A change to % is already waiting for the owner''s approval. Wait for it or withdraw it first.', p_company USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.company_change_request (company_code, before, after, reason, requested_by)
  VALUES (p_company, v_cur, v_new, nullif(btrim(p_reason), ''), me.user_id)
  RETURNING request_id INTO v_id;
  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  VALUES (p_company, 'company_details', v_id::text, 1, v_own, 'company_details', me.user_id, now(),
          jsonb_build_object('checks', jsonb_build_array(jsonb_build_object('message', 'Company details change needs the owner''s approval.'))));
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'company_details_submit', 'company_details', v_id::text,
          jsonb_build_object('before', v_cur, 'after', v_new, 'reason', p_reason));
  RETURN jsonb_build_object('request_id', v_id, 'state', 'pending_approval', 'approver_position', v_own);
END $$;

CREATE OR REPLACE FUNCTION erp.company_details_decide(p_company varchar, p_request_id bigint, p_decision text, p_note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user;
  q  erp.company_change_request;
  a  erp.approval;
  n  jsonb;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO me FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  PERFORM erp._adm_company(p_company);
  SELECT * INTO q FROM erp.company_change_request WHERE request_id = p_request_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % not found in %.', p_request_id, p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This change is no longer waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO a FROM erp.approval WHERE company_code = p_company AND object = 'company_details' AND object_ref = p_request_id::text
     AND decision IS NULL AND NOT superseded ORDER BY step LIMIT 1 FOR UPDATE;
  IF me.user_id IS NULL OR a.approver_position IS DISTINCT FROM me.position_code THEN
    RAISE EXCEPTION 'Only the owner position (%) can approve company detail changes.', coalesce(a.approver_position, '?') USING ERRCODE = '42501';
  END IF;
  IF q.requested_by = me.user_id THEN
    RAISE EXCEPTION 'You can''t approve your own change.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose Approve or Reject.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND nullif(btrim(p_note), '') IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you reject the change.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET decision = p_decision, approver_user = me.user_id, decided_at = now(), note = nullif(btrim(p_note), '')
   WHERE approval_id = a.approval_id;
  UPDATE erp.company_change_request SET state = p_decision, decided_by = me.user_id, decided_at = now(), note = nullif(btrim(p_note), '')
   WHERE request_id = p_request_id;
  IF p_decision = 'approved' THEN
    n := q.after;
    INSERT INTO erp.company_profile (company_code, legal_name, trading_name, tax_id, licence_no, address, phone, email, logo_path,
                                     fiscal_year_start, updated_at, requested_by, approved_by)
    VALUES (p_company, n->>'legal_name', n->>'trading_name', n->>'tax_id', n->>'licence_no', n->>'address', n->>'phone', n->>'email',
            n->>'logo_path', (n->>'fiscal_year_start')::smallint, now(), q.requested_by, me.user_id)
    ON CONFLICT (company_code) DO UPDATE SET legal_name = EXCLUDED.legal_name, trading_name = EXCLUDED.trading_name, tax_id = EXCLUDED.tax_id,
      licence_no = EXCLUDED.licence_no, address = EXCLUDED.address, phone = EXCLUDED.phone, email = EXCLUDED.email, logo_path = EXCLUDED.logo_path,
      fiscal_year_start = EXCLUDED.fiscal_year_start, updated_at = now(), requested_by = EXCLUDED.requested_by, approved_by = EXCLUDED.approved_by;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'company_details_' || p_decision, 'company_details', p_request_id::text,
          jsonb_build_object('note', p_note, 'after', q.after));
  RETURN jsonb_build_object('request_id', p_request_id, 'state', p_decision);
END $$;

-- Withdraw a waiting change (the requester or any Administration-full user).
CREATE OR REPLACE FUNCTION erp.company_details_cancel(p_company varchar, p_request_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me erp.app_user := erp._adm_guard(true);
  q  erp.company_change_request;
BEGIN
  PERFORM erp._adm_company(p_company);
  SELECT * INTO q FROM erp.company_change_request WHERE request_id = p_request_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND OR q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This change is no longer waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.company_change_request SET state = 'cancelled', decided_by = me.user_id, decided_at = now() WHERE request_id = p_request_id;
  UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = 'company_details' AND object_ref = p_request_id::text AND decision IS NULL;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'company_details_cancel', 'company_details', p_request_id::text, NULL);
  RETURN jsonb_build_object('request_id', p_request_id, 'state', 'cancelled');
END $$;

-- ============ Exchange rates ============
CREATE OR REPLACE FUNCTION erp._fx_guard(p_company varchar) RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  PERFORM erp._adm_company(p_company);
  IF u.user_id IS NULL OR NOT (erp.can_write('finance') OR erp.can_write('admin')) THEN
    RAISE EXCEPTION 'Only Finance or a system admin with full access can enter exchange rates.' USING ERRCODE = '42501';
  END IF;
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION erp.fx_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c erp.company;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  c := erp._adm_company(p_company);
  IF NOT erp.can_read('finance') THEN
    RAISE EXCEPTION 'Your position does not include Financials.' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object('currency', c.currency,
    'currencies', to_jsonb(coalesce((SELECT fx_currencies FROM erp.admin_setting WHERE company_code = p_company), '{USD,SAR,CNY,EUR}'::text[])),
    'can_write', erp.can_write('finance') OR erp.can_write('admin'));
END $$;

CREATE OR REPLACE FUNCTION erp._fx_check(p_company varchar, p_date date, p_cur text, p_rate numeric) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  c erp.company;
  v_list text[];
  v_cur text := upper(btrim(coalesce(p_cur, '')));
BEGIN
  SELECT * INTO c FROM erp.company WHERE company_code = p_company;
  v_list := coalesce((SELECT fx_currencies FROM erp.admin_setting WHERE company_code = p_company), '{USD,SAR,CNY,EUR}'::text[]);
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Enter the rate date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_cur = c.currency THEN
    RAISE EXCEPTION '% is the company currency; it needs no rate.', v_cur USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_cur = ANY (v_list) THEN
    RAISE EXCEPTION 'Currency % is not in the rates list for % (%).', v_cur, p_company, array_to_string(v_list, ', ') USING ERRCODE = 'P0001';
  END IF;
  IF p_rate IS NULL OR p_rate <= 0 OR p_rate >= 100000 THEN
    RAISE EXCEPTION 'Enter a rate above 0 (% per 1 %).', c.currency, v_cur USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM erp.fx_rate WHERE company_code = p_company AND rate_date = p_date AND currency = v_cur) THEN
    RAISE EXCEPTION 'SAP already has a % rate for %. Change it in SAP until % goes live on Super ERP.', v_cur, to_char(p_date, 'DD Mon YYYY'), p_company
      USING ERRCODE = 'P0001';
  END IF;
  RETURN v_cur;
END $$;

CREATE OR REPLACE FUNCTION erp.fx_rate_save(p_company varchar, p_date date, p_currency text, p_rate numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me   erp.app_user := erp._fx_guard(p_company);
  v_cur text := erp._fx_check(p_company, p_date, p_currency, p_rate);
  v_old numeric;
BEGIN
  SELECT rate INTO v_old FROM erp.fx_rate_entry WHERE company_code = p_company AND rate_date = p_date AND currency = v_cur FOR UPDATE;
  INSERT INTO erp.fx_rate_entry (company_code, rate_date, currency, rate, source, entered_by, entered_by_name)
  VALUES (p_company, p_date, v_cur, p_rate, 'manual', me.user_id, me.display_name)
  ON CONFLICT (company_code, rate_date, currency) DO UPDATE SET rate = EXCLUDED.rate, source = 'manual', entered_by = EXCLUDED.entered_by,
    entered_by_name = EXCLUDED.entered_by_name, entered_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'fx_rate_save', 'fx_rate', p_date || '/' || v_cur, jsonb_build_object('from', v_old, 'to', p_rate));
  RETURN jsonb_build_object('rate_date', p_date, 'currency', v_cur, 'rate', p_rate, 'replaced', v_old);
END $$;

-- Import rows already parsed in the browser: [{date, currency, rate}]. All or nothing; problems come back per row.
CREATE OR REPLACE FUNCTION erp.fx_rate_import(p_company varchar, p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me   erp.app_user := erp._fx_guard(p_company);
  r    jsonb;
  i    integer := 0;
  errs jsonb := '[]'::jsonb;
  ok   jsonb := '[]'::jsonb;
  v_d  date;
  v_r  numeric;
  v_c  text;
BEGIN
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'The file has no rate rows.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN
    RAISE EXCEPTION 'Import up to 5,000 rows at a time.' USING ERRCODE = 'P0001';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    BEGIN
      BEGIN
        v_d := (r->>'date')::date;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'Date % is not a date (use YYYY-MM-DD).', coalesce(r->>'date', '(empty)') USING ERRCODE = 'P0001';
      END;
      BEGIN
        v_r := (r->>'rate')::numeric;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'Rate % is not a number.', coalesce(r->>'rate', '(empty)') USING ERRCODE = 'P0001';
      END;
      v_c := erp._fx_check(p_company, v_d, r->>'currency', v_r);
      IF ok @> jsonb_build_array(jsonb_build_object('d', v_d, 'c', v_c)) THEN
        RAISE EXCEPTION 'The file has % for % twice.', v_c, v_d USING ERRCODE = 'P0001';
      END IF;
      ok := ok || jsonb_build_object('d', v_d, 'c', v_c, 'r', v_r);
    EXCEPTION WHEN raise_exception THEN
      errs := errs || jsonb_build_object('row', i, 'message', SQLERRM);
    END;
  END LOOP;
  IF jsonb_array_length(errs) > 0 THEN
    RETURN jsonb_build_object('saved', 0, 'errors', errs);
  END IF;
  INSERT INTO erp.fx_rate_entry (company_code, rate_date, currency, rate, source, entered_by, entered_by_name)
  SELECT p_company, (x->>'d')::date, x->>'c', (x->>'r')::numeric, 'import', me.user_id, me.display_name FROM jsonb_array_elements(ok) x
  ON CONFLICT (company_code, rate_date, currency) DO UPDATE SET rate = EXCLUDED.rate, source = 'import', entered_by = EXCLUDED.entered_by,
    entered_by_name = EXCLUDED.entered_by_name, entered_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'fx_rate_import', 'fx_rate', NULL, jsonb_build_object('rows', jsonb_array_length(ok)));
  RETURN jsonb_build_object('saved', jsonb_array_length(ok), 'errors', '[]'::jsonb);
END $$;

-- ============ Add-Ons › AI Assistant ============
-- Tables the assistant may be allowed to read: erp tables and views the app can read, never schema sap, never salary,
-- never security or admin tables. The provider key is NOT stored here (Supabase secret AI_API_KEY).
CREATE OR REPLACE FUNCTION erp._ai_tables() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}')
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'erp' AND c.relkind IN ('r', 'v', 'p')
     AND has_table_privilege('authenticated', c.oid, 'SELECT')
     AND c.relname NOT LIKE ALL (ARRAY['hr_pay%', 'hr_payroll%', 'payroll%', 'employee_pay%', 'air_ticket%', 'hr_employee_extra%',
                                       'audit_log', 'user_invite', 'ai\_%', 'sync_log', 'app_user', 'user_company', 'admin_setting',
                                       'position_module', 'migration%', 'company_change_request'])
$$;

CREATE OR REPLACE FUNCTION erp._ai_modules() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['finance', 'sales', 'purchase', 'bp', 'banking', 'inventory', 'production', 'service', 'hr', 'reports']
$$;

CREATE OR REPLACE FUNCTION erp.ai_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s erp.ai_setting;
BEGIN
  PERFORM erp._adm_guard(false);
  PERFORM erp._adm_company(p_company);
  SELECT * INTO s FROM erp.ai_setting WHERE company_code = p_company;
  RETURN jsonb_build_object(
    'can_write', erp.can_write('admin'),
    'setting', jsonb_build_object('enabled', coalesce(s.enabled, false), 'chat_provider', s.chat_provider, 'chat_model', s.chat_model,
                 'voice_provider', s.voice_provider, 'allowed_modules', to_jsonb(coalesce(s.allowed_modules, '{}')),
                 'allowed_tables', to_jsonb(coalesce(s.allowed_tables, '{}')), 'monthly_limit', s.monthly_limit,
                 'updated_at', s.updated_at, 'updated_by_name', erp._adm_name(s.updated_by)),
    'chat_providers', '["google", "openai", "anthropic", "azure_openai"]'::jsonb,
    'voice_providers', '["google", "openai", "elevenlabs", "azure"]'::jsonb,
    'modules', to_jsonb(erp._ai_modules()),
    'tables', to_jsonb(erp._ai_tables()),
    'usage', (SELECT jsonb_build_object('month', u.month, 'requests', u.requests, 'tokens', u.tokens) FROM erp.ai_usage u
               WHERE u.company_code = p_company AND u.month = to_char(now(), 'YYYY-MM')),
    'key_secret_name', 'AI_API_KEY');
END $$;

CREATE OR REPLACE FUNCTION erp.ai_setting_save(p_company varchar, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  me    erp.app_user := erp._adm_guard(true);
  old   erp.ai_setting;
  k     text;
  x     text;
  v_on  boolean;
  v_cp  text;
  v_vp  text;
  v_mdl text;
  v_mods text[];
  v_tabs text[];
  v_lim integer;
BEGIN
  PERFORM erp._adm_company(p_company);
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the settings.' USING ERRCODE = 'P0001';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k ~* '(key|secret|token|password|credential)' THEN
      RAISE EXCEPTION 'API keys are never stored in the database. Add the key as the Supabase secret AI_API_KEY; only the AI Assistant server function reads it.'
        USING ERRCODE = 'P0001';
    END IF;
    IF k NOT IN ('enabled', 'chat_provider', 'chat_model', 'voice_provider', 'allowed_modules', 'allowed_tables', 'monthly_limit') THEN
      RAISE EXCEPTION 'Unknown AI setting %.', k USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  SELECT * INTO old FROM erp.ai_setting WHERE company_code = p_company FOR UPDATE;
  v_on  := CASE WHEN p ? 'enabled' THEN coalesce((p->>'enabled')::boolean, false) ELSE coalesce(old.enabled, false) END;
  v_cp  := CASE WHEN p ? 'chat_provider' THEN nullif(p->>'chat_provider', '') ELSE old.chat_provider END;
  v_vp  := CASE WHEN p ? 'voice_provider' THEN nullif(p->>'voice_provider', '') ELSE old.voice_provider END;
  v_mdl := CASE WHEN p ? 'chat_model' THEN nullif(btrim(p->>'chat_model'), '') ELSE old.chat_model END;
  IF v_cp IS NOT NULL AND v_cp NOT IN ('google', 'openai', 'anthropic', 'azure_openai') THEN
    RAISE EXCEPTION 'Chat provider % is not supported.', v_cp USING ERRCODE = 'P0001';
  END IF;
  IF v_vp IS NOT NULL AND v_vp NOT IN ('google', 'openai', 'elevenlabs', 'azure') THEN
    RAISE EXCEPTION 'Voice provider % is not supported.', v_vp USING ERRCODE = 'P0001';
  END IF;
  IF v_mdl IS NOT NULL AND v_mdl !~ '^[A-Za-z0-9._:/-]{1,80}$' THEN
    RAISE EXCEPTION 'Enter the model name as the provider writes it, for example gemini-2.5-flash.' USING ERRCODE = 'P0001';
  END IF;
  IF p ? 'allowed_modules' THEN
    SELECT array_agg(DISTINCT e ORDER BY e) INTO v_mods FROM jsonb_array_elements_text(coalesce(p->'allowed_modules', '[]')) e;
  ELSE
    v_mods := old.allowed_modules;
  END IF;
  FOREACH x IN ARRAY coalesce(v_mods, '{}') LOOP
    IF NOT x = ANY (erp._ai_modules()) THEN
      RAISE EXCEPTION 'Module % can''t be opened to the AI Assistant.', x USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  IF p ? 'allowed_tables' THEN
    SELECT array_agg(DISTINCT e ORDER BY e) INTO v_tabs FROM jsonb_array_elements_text(coalesce(p->'allowed_tables', '[]')) e;
  ELSE
    v_tabs := old.allowed_tables;
  END IF;
  FOREACH x IN ARRAY coalesce(v_tabs, '{}') LOOP
    IF x ILIKE 'sap.%' OR x ILIKE 'sap\_%' THEN
      RAISE EXCEPTION 'The AI Assistant never reads the raw SAP copy (schema sap).' USING ERRCODE = 'P0001';
    END IF;
    IF x ~* '(pay|payroll|salary|air_ticket|hr_employee_extra)' THEN
      RAISE EXCEPTION 'Salary data is never available to the AI Assistant (%).', x USING ERRCODE = 'P0001';
    END IF;
    IF NOT regexp_replace(x, '^erp\.', '') = ANY (erp._ai_tables()) THEN
      RAISE EXCEPTION 'Table % can''t be read by the AI Assistant.', x USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  v_tabs := ARRAY(SELECT regexp_replace(t, '^erp\.', '') FROM unnest(coalesce(v_tabs, '{}')) t);
  BEGIN
    v_lim := CASE WHEN p ? 'monthly_limit' THEN nullif(p->>'monthly_limit', '')::integer ELSE old.monthly_limit END;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the monthly limit as a whole number of requests.' USING ERRCODE = 'P0001';
  END;
  IF v_lim IS NOT NULL AND v_lim NOT BETWEEN 1 AND 1000000 THEN
    RAISE EXCEPTION 'The monthly limit must be between 1 and 1,000,000 requests.' USING ERRCODE = 'P0001';
  END IF;
  IF v_on AND (v_cp IS NULL OR v_lim IS NULL) THEN
    RAISE EXCEPTION 'Choose a chat provider and a monthly limit before switching the assistant on.' USING ERRCODE = 'P0001';
  END IF;
  IF v_on AND coalesce(array_length(v_tabs, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Choose at least one table the assistant may read before switching it on.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.ai_setting (company_code, enabled, chat_provider, chat_model, voice_provider, allowed_modules, allowed_tables, monthly_limit, updated_by, updated_at)
  VALUES (p_company, v_on, v_cp, v_mdl, v_vp, coalesce(v_mods, '{}'), v_tabs, v_lim, me.user_id, now())
  ON CONFLICT (company_code) DO UPDATE SET enabled = EXCLUDED.enabled, chat_provider = EXCLUDED.chat_provider, chat_model = EXCLUDED.chat_model,
    voice_provider = EXCLUDED.voice_provider, allowed_modules = EXCLUDED.allowed_modules, allowed_tables = EXCLUDED.allowed_tables,
    monthly_limit = EXCLUDED.monthly_limit, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (me.user_id::text, p_company, 'ai_setting_save', 'ai_setting', p_company,
          jsonb_build_object('before', CASE WHEN old.company_code IS NULL THEN NULL ELSE to_jsonb(old) - 'updated_by' - 'updated_at' END,
                             'after', jsonb_build_object('enabled', v_on, 'chat_provider', v_cp, 'chat_model', v_mdl, 'voice_provider', v_vp,
                                                         'allowed_modules', v_mods, 'allowed_tables', v_tabs, 'monthly_limit', v_lim)));
  RETURN jsonb_build_object('enabled', v_on);
END $$;

-- Called by the ai-assistant Edge Function with the user's session before each request.
CREATE OR REPLACE FUNCTION erp.ai_request_check(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s erp.ai_setting;
  v_used integer;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  PERFORM erp._adm_company(p_company);
  SELECT * INTO s FROM erp.ai_setting WHERE company_code = p_company;
  IF NOT coalesce(s.enabled, false) THEN
    RAISE EXCEPTION 'The AI Assistant is off for %.', p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT requests INTO v_used FROM erp.ai_usage WHERE company_code = p_company AND month = to_char(now(), 'YYYY-MM');
  IF coalesce(v_used, 0) >= s.monthly_limit THEN
    RAISE EXCEPTION 'This month''s AI Assistant limit for % is used up (% requests).', p_company, s.monthly_limit USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('chat_provider', s.chat_provider, 'chat_model', s.chat_model, 'voice_provider', s.voice_provider,
    -- only modules the user can read themselves
    'modules', to_jsonb(ARRAY(SELECT m FROM unnest(s.allowed_modules) m WHERE erp.can_read(m))),
    'tables', to_jsonb(s.allowed_tables), 'remaining', s.monthly_limit - coalesce(v_used, 0));
END $$;

-- service_role only (the Edge Function records usage after the provider answered).
CREATE OR REPLACE FUNCTION erp.ai_usage_record(p_company varchar, p_requests integer, p_tokens bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'Only the AI Assistant server function can record usage.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO erp.ai_usage (company_code, month, requests, tokens)
  VALUES (p_company, to_char(now(), 'YYYY-MM'), greatest(coalesce(p_requests, 0), 0), greatest(coalesce(p_tokens, 0), 0))
  ON CONFLICT (company_code, month) DO UPDATE SET requests = erp.ai_usage.requests + EXCLUDED.requests, tokens = erp.ai_usage.tokens + EXCLUDED.tokens;
END $$;

-- ============ Recent administration changes (audit_log rows with company NULL are not visible through RLS) ============
CREATE OR REPLACE FUNCTION erp.admin_audit_recent(p_objects text[], p_limit integer DEFAULT 20) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._adm_guard(false);
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('at', a.at, 'actor_name', coalesce(CASE WHEN a.actor ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN erp._adm_name(a.actor::uuid) END, a.actor),
             'company_code', a.company_code, 'action', a.action, 'object', a.object, 'object_ref', a.object_ref, 'detail', a.detail) ORDER BY a.at DESC)
      FROM (SELECT * FROM erp.audit_log
             WHERE object = ANY (p_objects) AND (company_code IS NULL OR erp.can_see(company_code))
             ORDER BY at DESC LIMIT least(greatest(coalesce(p_limit, 20), 1), 100)) a), '[]'::jsonb);
END $$;

-- ============ Approvals inbox (replaces A9's: the 11 earlier kinds + company_details) ============
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

-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._adm_guard(boolean), erp._adm_company(varchar), erp._adm_level(text, text), erp._adm_name(uuid),
  erp._adm_user_check(jsonb, uuid), erp._adm_access_diff(text, jsonb), erp._adm_profile(varchar), erp._fx_guard(varchar),
  erp._fx_check(varchar, date, text, numeric), erp._ai_tables(), erp._adm_modules(), erp._adm_doc_types(), erp._adm_rule_spec(), erp._ai_modules()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.admin_users(), erp.admin_employee_options(varchar, text), erp.admin_user_save(uuid, jsonb),
  erp.admin_invite_create(jsonb), erp.admin_invite_cancel(bigint), erp.admin_positions(), erp.position_save(text, text, boolean),
  erp.position_delete(text), erp.position_access_preview(text, jsonb), erp.position_access_save(text, jsonb),
  erp.approval_template_setup(varchar), erp.approval_rule_save(varchar, jsonb), erp.approval_rule_delete(varchar, bigint),
  erp.number_series_setup(varchar), erp.number_series_save(varchar, integer, text, integer, integer, boolean),
  erp.company_print_info(varchar), erp.company_details_info(varchar), erp.admin_setting_save(varchar, jsonb),
  erp.company_details_submit(varchar, jsonb, text), erp.company_details_decide(varchar, bigint, text, text), erp.company_details_cancel(varchar, bigint),
  erp.fx_setup(varchar), erp.fx_rate_save(varchar, date, text, numeric), erp.fx_rate_import(varchar, jsonb),
  erp.ai_setup(varchar), erp.ai_setting_save(varchar, jsonb), erp.ai_request_check(varchar), erp.admin_audit_recent(text[], integer),
  erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.admin_users(), erp.admin_employee_options(varchar, text), erp.admin_user_save(uuid, jsonb),
  erp.admin_invite_create(jsonb), erp.admin_invite_cancel(bigint), erp.admin_positions(), erp.position_save(text, text, boolean),
  erp.position_delete(text), erp.position_access_preview(text, jsonb), erp.position_access_save(text, jsonb),
  erp.approval_template_setup(varchar), erp.approval_rule_save(varchar, jsonb), erp.approval_rule_delete(varchar, bigint),
  erp.number_series_setup(varchar), erp.number_series_save(varchar, integer, text, integer, integer, boolean),
  erp.company_print_info(varchar), erp.company_details_info(varchar), erp.admin_setting_save(varchar, jsonb),
  erp.company_details_submit(varchar, jsonb, text), erp.company_details_decide(varchar, bigint, text, text), erp.company_details_cancel(varchar, bigint),
  erp.fx_setup(varchar), erp.fx_rate_save(varchar, date, text, numeric), erp.fx_rate_import(varchar, jsonb),
  erp.ai_setup(varchar), erp.ai_setting_save(varchar, jsonb), erp.ai_request_check(varchar), erp.admin_audit_recent(text[], integer),
  erp.approval_inbox()
  TO authenticated;
-- Server-only steps: the browser (anon / authenticated) can't call these. The Edge Functions use the service role.
REVOKE ALL ON FUNCTION erp.admin_invite_link(bigint, uuid), erp.ai_usage_record(varchar, integer, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp.admin_invite_link(bigint, uuid), erp.ai_usage_record(varchar, integer, bigint) TO service_role;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Owner position for company detail approvals (the same sample owner A9 uses for long leave). Real companies: Needs from Ashif.
INSERT INTO erp.admin_setting (company_code, owner_position)
SELECT 'ZZ99', 'QA_OWNER'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99') AND EXISTS (SELECT 1 FROM erp.position WHERE position_code = 'QA_OWNER')
ON CONFLICT (company_code) DO NOTHING;
