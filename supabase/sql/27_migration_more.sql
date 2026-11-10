-- Sanford Super ERP - A12 · SAP migration completion (docs/sap-migration-plan.md §6). Safe to run twice.
-- Run after 26_reports.sql. Extends 13_migration_console.sql; earlier files are not edited.
--
--   1. run kind 'opening_only' + erp.migration_setting (opening date, clearing account, net-pay wage codes, VAT period)
--   2. custom-field register (CUFD/OUTB or the sap schema), admin decisions, owner approval for "drop"
--   3. reconciliation checks 5.3 and 5.5-5.10 (erp.migration_more_checks), duplicate warnings, coexistence report
--   4. attachments (erp.migration_attachment, filled by the worker; check 5.10)
--   5. special prices (OSPP/SPP1) and period/volume discounts (OEDG/EDG1) + sync steps
--   6. opening-balances-only loader (erp.migration_opening_apply)
--   7. erp.migration_cross_check_all (the worker's cross-check entry point) and erp.migration_report (auditor export)
--   8. coexistence: while erp.sync = 'on', a SAP row never overwrites a Super ERP (source <> 'sap') row
--
-- Raw SAP tables are read with dynamic SQL after a to_regclass check: a table missing from the SAP copy turns a
-- check into "skipped" (info issue), never an error. Business values (dates, accounts, wage codes) live in
-- erp.migration_setting and are empty for real companies.

-- ============ 1. Run kind and settings ============
ALTER TABLE erp.migration_run DROP CONSTRAINT IF EXISTS migration_run_kind_check;
ALTER TABLE erp.migration_run ADD CONSTRAINT migration_run_kind_check CHECK (kind IN ('full', 'tables', 'structure_only', 'opening_only'));

CREATE TABLE IF NOT EXISTS erp.migration_setting (
    company_code          varchar(8) PRIMARY KEY REFERENCES sap._company ON DELETE CASCADE,
    opening_date          date,                    -- go-live (opening balance) date for an opening-balances-only run
    opening_clearing_acct varchar(30),             -- opening-balance clearing account (must exist in erp.account)
    net_pay_wage_codes    text[] NOT NULL DEFAULT '{}',   -- payroll wage codes that make up net pay (check 5.9)
    vat_period_from       date,                    -- VAT period for check 5.7 (empty: month of the last SAP posting)
    vat_period_to         date,
    updated_by            uuid,
    updated_at            timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE erp.migration_setting ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.migration_setting FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.migration_setting TO authenticated;
GRANT ALL ON erp.migration_setting TO service_role;
DROP POLICY IF EXISTS migration_setting_read ON erp.migration_setting;
CREATE POLICY migration_setting_read ON erp.migration_setting FOR SELECT TO authenticated
  USING (erp.migration_can_read(company_code) OR (erp.can_see(company_code) AND erp.migration_can_sign(NULL)));

CREATE OR REPLACE FUNCTION erp.migration_setting_save(p_company varchar, p jsonb)
RETURNS erp.migration_setting LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE old erp.migration_setting; v erp.migration_setting; v_acct text; v_codes text[];
BEGIN
  IF NOT erp.migration_can_read(p_company) THEN
    RAISE EXCEPTION 'Only admin or IT positions can change migration settings.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM sap._company WHERE company_code = p_company) THEN RAISE EXCEPTION 'Unknown company %.', p_company; END IF;
  SELECT * INTO old FROM erp.migration_setting WHERE company_code = p_company;
  v.company_code := p_company;
  v.opening_date := CASE WHEN p ? 'opening_date' THEN nullif(p->>'opening_date', '')::date ELSE old.opening_date END;
  v_acct := CASE WHEN p ? 'opening_clearing_acct' THEN nullif(btrim(p->>'opening_clearing_acct'), '') ELSE old.opening_clearing_acct END;
  IF v_acct IS DISTINCT FROM old.opening_clearing_acct AND NOT erp.can_write('finance') THEN
    RAISE EXCEPTION 'Changing the opening clearing account also needs Financials full access.' USING ERRCODE = '42501';
  END IF;
  IF v_acct IS NOT NULL AND EXISTS (SELECT 1 FROM erp.account WHERE company_code = p_company)
     AND NOT EXISTS (SELECT 1 FROM erp.account WHERE company_code = p_company AND acct_code = v_acct) THEN
    RAISE EXCEPTION 'Account % is not in the chart of accounts of %.', v_acct, p_company;
  END IF;
  v.opening_clearing_acct := v_acct;
  IF p ? 'net_pay_wage_codes' THEN
    SELECT coalesce(array_agg(DISTINCT btrim(x)) FILTER (WHERE btrim(x) <> ''), '{}') INTO v_codes
      FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'net_pay_wage_codes') = 'array' THEN p->'net_pay_wage_codes' ELSE '[]'::jsonb END) x;
    v.net_pay_wage_codes := v_codes;
  ELSE
    v.net_pay_wage_codes := coalesce(old.net_pay_wage_codes, '{}');
  END IF;
  v.vat_period_from := CASE WHEN p ? 'vat_period_from' THEN nullif(p->>'vat_period_from', '')::date ELSE old.vat_period_from END;
  v.vat_period_to := CASE WHEN p ? 'vat_period_to' THEN nullif(p->>'vat_period_to', '')::date ELSE old.vat_period_to END;
  IF (v.vat_period_from IS NULL) <> (v.vat_period_to IS NULL) THEN
    RAISE EXCEPTION 'Enter both the start and the end of the VAT period, or neither.';
  END IF;
  IF v.vat_period_from > v.vat_period_to THEN RAISE EXCEPTION 'The VAT period start must be on or before its end.'; END IF;
  INSERT INTO erp.migration_setting AS s (company_code, opening_date, opening_clearing_acct, net_pay_wage_codes, vat_period_from, vat_period_to, updated_by, updated_at)
  VALUES (p_company, v.opening_date, v.opening_clearing_acct, v.net_pay_wage_codes, v.vat_period_from, v.vat_period_to, erp.current_user_id(), now())
  ON CONFLICT (company_code) DO UPDATE SET opening_date = EXCLUDED.opening_date, opening_clearing_acct = EXCLUDED.opening_clearing_acct,
     net_pay_wage_codes = EXCLUDED.net_pay_wage_codes, vat_period_from = EXCLUDED.vat_period_from, vat_period_to = EXCLUDED.vat_period_to,
     updated_by = EXCLUDED.updated_by, updated_at = now()
  RETURNING * INTO v;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'migration_setting_save', 'migration_setting', p_company,
          jsonb_build_object('before', to_jsonb(old) - 'updated_by' - 'updated_at', 'after', to_jsonb(v) - 'updated_by' - 'updated_at'));
  RETURN v;
END $$;

-- migration_request (13) + kind opening_only, which needs the opening date and clearing account first.
CREATE OR REPLACE FUNCTION erp.migration_request(p_company varchar, p_kind text, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE v_run uuid := gen_random_uuid(); v_busy uuid; s erp.migration_setting;
BEGIN
  IF NOT erp.migration_is_admin() THEN RAISE EXCEPTION 'only admin or IT positions can start a migration' USING ERRCODE = '42501'; END IF;
  IF NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'company % is not in your company list', p_company USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM sap._company WHERE company_code = p_company) THEN RAISE EXCEPTION 'unknown company %', p_company; END IF;
  IF p_kind NOT IN ('full', 'tables', 'structure_only', 'opening_only') THEN RAISE EXCEPTION 'kind must be full, tables, structure_only or opening_only'; END IF;
  IF p_kind = 'opening_only' THEN
    SELECT * INTO s FROM erp.migration_setting WHERE company_code = p_company;
    IF s.opening_date IS NULL OR s.opening_clearing_acct IS NULL THEN
      RAISE EXCEPTION 'An opening-balances-only run needs the opening date and the clearing account of %. Enter them under Opening balances first.', p_company;
    END IF;
  END IF;
  SELECT run_id INTO v_busy FROM erp.migration_run
   WHERE company_code = p_company AND status IN ('uploading', 'queued', 'validating', 'loading', 'rebuilding', 'checking') LIMIT 1;
  IF FOUND THEN RAISE EXCEPTION 'company % already has a run in progress (%)', p_company, v_busy; END IF;
  INSERT INTO erp.migration_run (run_id, company_code, kind, status, created_by, storage_prefix, notes)
  VALUES (v_run, p_company, p_kind, 'uploading', erp.current_user_id(), p_company || '/' || v_run || '/', p_notes);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (coalesce(erp.current_user_id()::text, current_user), p_company, 'migration_request', 'migration_run', v_run::text,
          jsonb_build_object('kind', p_kind, 'notes', p_notes));
  RETURN v_run;
END $$;

-- ============ helpers (raw-table probing, check / skip writers) ============
CREATE OR REPLACE FUNCTION erp._mig_has(p_table text, VARIADIC p_cols text[] DEFAULT '{}')
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT to_regclass(format('sap.%I', p_table)) IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM unnest(p_cols) c
                      WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass(format('sap.%I', p_table))
                                           AND a.attname = c AND a.attnum > 0 AND NOT a.attisdropped))
$$;

-- column expression or NULL when the raw column does not exist
CREATE OR REPLACE FUNCTION erp._mig_col(p_table text, p_alias text, p_col text, p_type text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN erp._mig_has(p_table, p_col) THEN format('%s.%I::%s', p_alias, p_col, p_type) ELSE format('NULL::%s', p_type) END
$$;

CREATE OR REPLACE FUNCTION erp._mig_eq(a numeric, b numeric) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT abs(coalesce(a, 0) - coalesce(b, 0)) < 0.005
$$;

CREATE OR REPLACE FUNCTION erp._mig_check(p_run uuid, p_co varchar, p_area text, p_name text, p_sap numeric, p_raw numeric, p_app numeric,
                                          p_ok boolean, p_detail jsonb DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  INSERT INTO erp.migration_check (run_id, company_code, area, check_name, sap_value, raw_value, app_value, difference, ok, detail)
  VALUES (p_run, p_co, p_area, p_name, p_sap, p_raw, p_app,
          CASE WHEN p_app IS NULL AND p_raw IS NULL THEN NULL ELSE coalesce(p_app, p_raw, 0) - coalesce(p_sap, p_raw, 0) END, p_ok, p_detail)
$$;

-- a check that could not run: written as skipped (ok) with an info issue; returns the issue key
CREATE OR REPLACE FUNCTION erp._mig_skip(p_run uuid, p_co varchar, p_area text, p_name text, p_reason text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE k text := 'skip:' || p_co || ':' || p_area || ':' || p_name;
BEGIN
  PERFORM erp._mig_check(p_run, p_co, p_area, p_name, NULL, NULL, NULL, true, jsonb_build_object('skipped', true, 'reason', p_reason));
  PERFORM erp.migration_add_issue(p_run, p_co, 'info', p_area, k, format('%s: check skipped - %s', p_co, p_name), p_reason);
  RETURN k;
END $$;

CREATE OR REPLACE FUNCTION erp._mig_sweep(p_run uuid, p_co varchar, p_areas text[], p_found text[])
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  UPDATE erp.migration_issue i SET status = 'fixed', resolved_at = now(), note = 'not found by the check of ' || to_char(now(), 'YYYY-MM-DD HH24:MI')
   WHERE i.run_id = p_run AND i.company_code = p_co AND i.area = ANY (p_areas) AND i.status = 'open' AND NOT (i.issue_key = ANY (coalesce(p_found, '{}')))
$$;

-- ============ 2. Custom-field register ============
CREATE TABLE IF NOT EXISTS erp.custom_field_register (
    company_code   varchar(8) NOT NULL REFERENCES sap._company ON DELETE CASCADE,
    table_name     text NOT NULL,                 -- SAP table (OCRD, @TRADEMARK ...)
    field_name     text NOT NULL DEFAULT '',      -- U_ field; '' = the user-defined table itself
    kind           text NOT NULL CHECK (kind IN ('field', 'table')),
    description    text,
    field_type     text,
    decision       text NOT NULL CHECK (decision IN ('mapped', 'raw_only', 'drop')),
    target         text,                          -- erp.<table>.<column> (or erp.<table> for a user table)
    suggested      text,                          -- what the build suggested
    rows_used      bigint,                        -- rows of this company with a value
    total_rows     bigint,
    last_used      date,                          -- latest UpdateDate/CreateDate of a row with a value
    in_raw         boolean NOT NULL DEFAULT false,-- present in the raw sap schema
    dict_source    text,                          -- 'CUFD/OUTB' or 'sap schema'
    decided_by     uuid,                          -- NULL = automatic
    decided_at     timestamptz,
    note           text,
    drop_state     text CHECK (drop_state IN ('pending', 'approved', 'rejected')),
    drop_decided_by uuid,
    drop_decided_at timestamptz,
    drop_note      text,
    built_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, table_name, field_name)
);
CREATE INDEX IF NOT EXISTS custom_field_register_decision_idx ON erp.custom_field_register (company_code, decision, drop_state);

-- the company's owner position (Ashif) approves dropping fields
CREATE OR REPLACE FUNCTION erp._cf_is_owner(p_company varchar) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT erp.can_see(p_company) AND EXISTS (
    SELECT 1 FROM erp.admin_setting s JOIN erp.app_user u ON u.position_code = s.owner_position
     WHERE s.company_code = p_company AND u.user_id = erp.current_user_id() AND u.active)
$$;

ALTER TABLE erp.custom_field_register ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.custom_field_register FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.custom_field_register TO authenticated;
GRANT ALL ON erp.custom_field_register TO service_role;
DROP POLICY IF EXISTS custom_field_register_read ON erp.custom_field_register;
CREATE POLICY custom_field_register_read ON erp.custom_field_register FOR SELECT TO authenticated
  USING (erp.migration_can_read(company_code) OR erp._cf_is_owner(company_code));

-- Builds / refreshes the register for one company (worker or admin through custom_field_register_build).
-- Human decisions are kept; automatic rows follow the current sync mapping.
CREATE OR REPLACE FUNCTION erp._cf_build(p_company varchar)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_dict text; t record; r record; ln text; v_tgt text; v_from text; v_rx text; q text; parts text[]; flds text[];
  v_date text; i int; j int; res jsonb; n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sap._company WHERE company_code = p_company) THEN RAISE EXCEPTION 'Unknown company %.', p_company; END IF;
  CREATE TEMP TABLE IF NOT EXISTS _cf (table_name text, field_name text, kind text, description text, field_type text,
                                        in_raw boolean DEFAULT false, rows_used bigint, total_rows bigint, last_used date, target text) ON COMMIT DROP;
  TRUNCATE _cf;
  -- dictionary
  IF erp._mig_has('CUFD', 'TableID', 'AliasID') THEN
    v_dict := 'CUFD/OUTB';
    EXECUTE format('INSERT INTO _cf (table_name, field_name, kind, description, field_type)
                    SELECT DISTINCT ON (1, 2) btrim(c."TableID"), ''U_'' || btrim(c."AliasID"), ''field'', %s, %s
                      FROM sap."CUFD" c WHERE c.company_code = $1 AND coalesce(btrim(c."AliasID"), '''') <> '''' ORDER BY 1, 2',
                   erp._mig_col('CUFD', 'c', 'Descr', 'text'),
                   'concat_ws('' '', ' || erp._mig_col('CUFD', 'c', 'TypeID', 'text') || ', ''('' || ' || erp._mig_col('CUFD', 'c', 'EditSize', 'text') || ' || '')'')')
      USING p_company;
    IF erp._mig_has('OUTB', 'TableName') THEN
      EXECUTE format('INSERT INTO _cf (table_name, field_name, kind, description, field_type)
                      SELECT DISTINCT ''@'' || btrim(o."TableName"), '''', ''table'', %s, ''user table''
                        FROM sap."OUTB" o WHERE o.company_code = $1 AND coalesce(btrim(o."TableName"), '''') <> ''''',
                     erp._mig_col('OUTB', 'o', 'Descr', 'text'))
        USING p_company;
    END IF;
  ELSE
    v_dict := 'sap schema';
    INSERT INTO _cf (table_name, field_name, kind, field_type)
    SELECT c.relname, a.attname, 'field', format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relnamespace = 'sap'::regnamespace AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped AND a.attname LIKE 'U\_%';
    INSERT INTO _cf (table_name, field_name, kind, field_type)
    SELECT c.relname, '', 'table', 'user table' FROM pg_class c
     WHERE c.relnamespace = 'sap'::regnamespace AND c.relkind = 'r' AND c.relname LIKE '@%';
  END IF;
  UPDATE _cf f SET in_raw = CASE WHEN f.kind = 'table' THEN erp._mig_has(f.table_name) ELSE erp._mig_has(f.table_name, f.field_name) END;

  -- usage: one scan per raw table (fields in chunks of 200)
  FOR t IN SELECT f.table_name, array_agg(f.field_name ORDER BY f.field_name) FILTER (WHERE f.kind = 'field' AND f.in_raw) flds,
                  bool_or(f.kind = 'table' AND f.in_raw) has_table
             FROM _cf f WHERE f.in_raw AND erp._mig_has(f.table_name, 'company_code') GROUP BY 1 LOOP
    v_date := CASE WHEN erp._mig_has(t.table_name, 'UpdateDate') AND erp._mig_has(t.table_name, 'CreateDate') THEN 'coalesce("UpdateDate", "CreateDate")::date'
                   WHEN erp._mig_has(t.table_name, 'UpdateDate') THEN '"UpdateDate"::date'
                   WHEN erp._mig_has(t.table_name, 'CreateDate') THEN '"CreateDate"::date' ELSE 'NULL::date' END;
    EXECUTE format('SELECT count(*), max(%s) FROM sap.%I WHERE company_code = $1', v_date, t.table_name) INTO r USING p_company;
    UPDATE _cf f SET total_rows = r.count, rows_used = CASE WHEN f.kind = 'table' THEN r.count ELSE f.rows_used END,
                     last_used = CASE WHEN f.kind = 'table' THEN r.max ELSE f.last_used END
     WHERE f.table_name = t.table_name;
    flds := coalesce(t.flds, '{}');
    i := 1;
    WHILE i <= cardinality(flds) LOOP
      parts := '{}';
      FOR j IN i .. least(i + 199, cardinality(flds)) LOOP
        parts := parts || format('%L, jsonb_build_array(count(nullif(btrim(%I::text), '''')), max(%s) FILTER (WHERE nullif(btrim(%I::text), '''') IS NOT NULL))',
                                 flds[j], flds[j], v_date, flds[j]);
      END LOOP;
      q := format('SELECT jsonb_build_object(%s) FROM sap.%I WHERE company_code = $1', array_to_string(parts, ', '), t.table_name);
      EXECUTE q INTO res USING p_company;
      UPDATE _cf f SET rows_used = (res->f.field_name->>0)::bigint, last_used = (res->f.field_name->>1)::date
       WHERE f.table_name = t.table_name AND f.kind = 'field' AND res ? f.field_name;
      i := i + 200;
    END LOOP;
  END LOOP;

  -- mapping: read from the sync functions themselves (s."U_X" ... AS column; FROM sap."@T"; payroll unpivot)
  CREATE TEMP TABLE IF NOT EXISTS _cfmap (table_name text, field_name text, target text) ON COMMIT DROP;
  TRUNCATE _cfmap;
  FOR r IN SELECT p.proname, p.prosrc FROM pg_proc p WHERE p.pronamespace = 'erp'::regnamespace AND p.proname LIKE 'sync\_%' AND p.prokind = 'f' LOOP
    v_tgt := (regexp_match(r.prosrc, 'INSERT INTO erp\.([a-z_0-9]+)'))[1];
    v_from := (regexp_match(r.prosrc, 'FROM sap\."([^"]+)"'))[1];
    CONTINUE WHEN v_tgt IS NULL OR v_from IS NULL;
    FOR ln IN SELECT regexp_split_to_table(r.prosrc, '\n') LOOP
      IF ln ~ '\m[a-z]+\."U_[A-Za-z0-9_]+"' AND ln ~ ' AS [a-z0-9_]+,?\s*$' THEN
        INSERT INTO _cfmap VALUES (v_from, (regexp_match(ln, '\m[a-z]+\."(U_[A-Za-z0-9_]+)"'))[1],
                                   'erp.' || v_tgt || '.' || (regexp_match(ln, ' AS ([a-z0-9_]+),?\s*$'))[1]);
      END IF;
    END LOOP;
    INSERT INTO _cfmap SELECT DISTINCT m[1], '', 'erp.' || v_tgt FROM regexp_matches(r.prosrc, 'sap\."(@[^"]+)"', 'g') m;
    v_rx := (regexp_match(r.prosrc, 'kv\.key ~ ''([^'']+)'''))[1];
    IF v_rx IS NOT NULL THEN
      INSERT INTO _cfmap SELECT f.table_name, f.field_name, 'erp.' || v_tgt || ' (wage code ' || substr(f.field_name, 6) || ')'
        FROM _cf f WHERE f.table_name = v_from AND f.kind = 'field' AND f.field_name ~ v_rx;
    END IF;
  END LOOP;
  UPDATE _cf f SET target = (SELECT min(m.target) FROM _cfmap m WHERE m.table_name = f.table_name AND m.field_name = f.field_name);

  INSERT INTO erp.custom_field_register AS g (company_code, table_name, field_name, kind, description, field_type, decision, target, suggested,
                                              rows_used, total_rows, last_used, in_raw, dict_source, built_at)
  SELECT p_company, f.table_name, f.field_name, f.kind, f.description, f.field_type,
         CASE WHEN f.target IS NOT NULL THEN 'mapped' ELSE 'raw_only' END, f.target,
         CASE WHEN f.target IS NOT NULL THEN 'mapped' ELSE 'raw_only' END,
         f.rows_used, f.total_rows, f.last_used, f.in_raw, v_dict, now()
    FROM (SELECT DISTINCT ON (table_name, field_name) * FROM _cf ORDER BY table_name, field_name, in_raw DESC) f
  ON CONFLICT (company_code, table_name, field_name) DO UPDATE SET
     kind = EXCLUDED.kind, description = coalesce(EXCLUDED.description, g.description), field_type = EXCLUDED.field_type,
     rows_used = EXCLUDED.rows_used, total_rows = EXCLUDED.total_rows, last_used = EXCLUDED.last_used, in_raw = EXCLUDED.in_raw,
     dict_source = EXCLUDED.dict_source, suggested = EXCLUDED.suggested, built_at = now(),
     decision = CASE WHEN g.decided_by IS NULL THEN EXCLUDED.decision ELSE g.decision END,
     target = CASE WHEN g.decided_by IS NULL THEN EXCLUDED.target ELSE g.target END;
  GET DIAGNOSTICS n = ROW_COUNT;
  -- automatic rows no longer in the dictionary go; decided ones stay (marked not in the raw copy)
  DELETE FROM erp.custom_field_register g WHERE g.company_code = p_company AND g.decided_by IS NULL
     AND NOT EXISTS (SELECT 1 FROM _cf f WHERE f.table_name = g.table_name AND f.field_name = g.field_name);
  UPDATE erp.custom_field_register g SET in_raw = false WHERE g.company_code = p_company
     AND NOT EXISTS (SELECT 1 FROM _cf f WHERE f.table_name = g.table_name AND f.field_name = g.field_name);
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION erp.custom_field_register_build(p_company varchar)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT erp.migration_can_read(p_company) THEN
    RAISE EXCEPTION 'Only admin or IT positions can rebuild the custom-field register.' USING ERRCODE = '42501';
  END IF;
  n := erp._cf_build(p_company);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'custom_field_register_build', 'custom_field_register', p_company, jsonb_build_object('rows', n));
  RETURN n;
END $$;

-- Admin / IT decision on one or more fields: items = [{"table": "OCRD", "field": "U_SFID"}, ...]
CREATE OR REPLACE FUNCTION erp.custom_field_decide(p_company varchar, p_items jsonb, p_decision text, p_target text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE it record; g erp.custom_field_register; n int := 0; v_t text := nullif(btrim(p_target), ''); m text[];
BEGIN
  IF NOT erp.migration_can_read(p_company) THEN
    RAISE EXCEPTION 'Only admin or IT positions can change the custom-field register.' USING ERRCODE = '42501';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('mapped', 'raw_only', 'drop') THEN RAISE EXCEPTION 'Decision must be mapped, raw_only or drop.'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Pick at least one field.'; END IF;
  IF p_decision = 'mapped' THEN
    IF v_t IS NULL THEN RAISE EXCEPTION 'A mapped field needs a target column, for example erp.business_partner.salesforce_id.'; END IF;
    m := regexp_match(v_t, '^erp\.([a-z_][a-z0-9_]*)(?:\.([a-z_][a-z0-9_]*))?$');
    IF m IS NULL OR NOT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema = 'erp' AND c.table_name = m[1]
                                  AND (m[2] IS NULL OR c.column_name = m[2])) THEN
      RAISE EXCEPTION 'Target % does not exist. Use erp.<table>.<column>.', v_t;
    END IF;
  END IF;
  FOR it IN SELECT x->>'table' tbl, coalesce(x->>'field', '') fld FROM jsonb_array_elements(p_items) x LOOP
    SELECT * INTO g FROM erp.custom_field_register WHERE company_code = p_company AND table_name = it.tbl AND field_name = it.fld FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Field %.% is not on the register of %.', it.tbl, nullif(it.fld, ''), p_company; END IF;
    UPDATE erp.custom_field_register SET decision = p_decision,
           target = CASE WHEN p_decision = 'mapped' THEN v_t ELSE NULL END,
           decided_by = erp.current_user_id(), decided_at = now(), note = coalesce(nullif(btrim(p_note), ''), note),
           drop_state = CASE WHEN p_decision = 'drop' THEN 'pending' END,
           drop_decided_by = NULL, drop_decided_at = NULL, drop_note = NULL
     WHERE company_code = p_company AND table_name = it.tbl AND field_name = it.fld;
    n := n + 1;
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'custom_field_decide', 'custom_field_register', p_company,
          jsonb_build_object('decision', p_decision, 'target', v_t, 'note', p_note, 'items', p_items));
  RETURN n;
END $$;

-- Owner (admin_setting.owner_position of the company) approves or rejects proposed drops. A rejected drop goes back to raw_only.
CREATE OR REPLACE FUNCTION erp.custom_field_drop_decide(p_company varchar, p_items jsonb, p_approve boolean, p_note text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE it record; g erp.custom_field_register; n int := 0; v_owner text;
BEGIN
  IF NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'You don''t have access to this.' USING ERRCODE = '42501'; END IF;
  SELECT owner_position INTO v_owner FROM erp.admin_setting WHERE company_code = p_company;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'No owner position is set for %. Set it in Administration › Company details first.', p_company;
  END IF;
  IF NOT erp._cf_is_owner(p_company) THEN
    RAISE EXCEPTION 'Only the owner position of % can approve dropping custom fields.', p_company USING ERRCODE = '42501';
  END IF;
  IF p_approve IS NULL THEN RAISE EXCEPTION 'Say whether the drop is approved or rejected.'; END IF;
  IF NOT p_approve AND coalesce(btrim(p_note), '') = '' THEN RAISE EXCEPTION 'Say why the drop is rejected.'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Pick at least one field.'; END IF;
  FOR it IN SELECT x->>'table' tbl, coalesce(x->>'field', '') fld FROM jsonb_array_elements(p_items) x LOOP
    SELECT * INTO g FROM erp.custom_field_register WHERE company_code = p_company AND table_name = it.tbl AND field_name = it.fld FOR UPDATE;
    IF NOT FOUND OR g.decision <> 'drop' OR g.drop_state IS DISTINCT FROM 'pending' THEN
      RAISE EXCEPTION 'Field %.% is not waiting for a drop approval.', it.tbl, nullif(it.fld, '');
    END IF;
    UPDATE erp.custom_field_register SET drop_state = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
           decision = CASE WHEN p_approve THEN 'drop' ELSE 'raw_only' END,
           drop_decided_by = erp.current_user_id(), drop_decided_at = now(), drop_note = nullif(btrim(p_note), '')
     WHERE company_code = p_company AND table_name = it.tbl AND field_name = it.fld;
    n := n + 1;
  END LOOP;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, CASE WHEN p_approve THEN 'custom_field_drop_approve' ELSE 'custom_field_drop_reject' END,
          'custom_field_register', p_company, jsonb_build_object('note', p_note, 'items', p_items));
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION erp.custom_field_setup(p_company varchar)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE v_edit boolean := erp.migration_can_read(p_company); v_own boolean := erp._cf_is_owner(p_company);
BEGIN
  IF NOT (v_edit OR v_own) THEN RAISE EXCEPTION 'You don''t have access to this.' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'company', p_company, 'can_edit', v_edit, 'can_approve_drop', v_own,
    'owner_position', (SELECT owner_position FROM erp.admin_setting WHERE company_code = p_company),
    'built_at', (SELECT max(built_at) FROM erp.custom_field_register WHERE company_code = p_company),
    'dict_source', (SELECT min(dict_source) FROM erp.custom_field_register WHERE company_code = p_company),
    'summary', (SELECT jsonb_build_object('total', count(*), 'fields', count(*) FILTER (WHERE kind = 'field'), 'tables', count(*) FILTER (WHERE kind = 'table'),
                       'mapped', count(*) FILTER (WHERE decision = 'mapped'), 'raw_only', count(*) FILTER (WHERE decision = 'raw_only'),
                       'drop_pending', count(*) FILTER (WHERE decision = 'drop' AND drop_state = 'pending'),
                       'drop_approved', count(*) FILTER (WHERE decision = 'drop' AND drop_state = 'approved'),
                       'unused', count(*) FILTER (WHERE in_raw AND coalesce(rows_used, 0) = 0),
                       'decided', count(*) FILTER (WHERE decided_by IS NOT NULL))
                  FROM erp.custom_field_register WHERE company_code = p_company),
    'tables', (SELECT coalesce(jsonb_agg(DISTINCT table_name ORDER BY table_name), '[]') FROM erp.custom_field_register WHERE company_code = p_company));
END $$;

-- ============ 4. Attachments (filled by the worker) ============
CREATE TABLE IF NOT EXISTS erp.migration_attachment (
    run_id        uuid NOT NULL REFERENCES erp.migration_run ON DELETE CASCADE,
    company_code  varchar(8) NOT NULL,
    abs_entry     integer NOT NULL,
    line          integer NOT NULL,
    obj_type      text,
    doc_key       text,
    file_name     text,
    source_path   text,
    storage_path  text,
    bytes         bigint,
    sha256        text,
    status        text NOT NULL CHECK (status IN ('copied', 'found', 'missing', 'error')),
    message       text,
    checked_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, abs_entry, line)
);
ALTER TABLE erp.migration_attachment ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.migration_attachment FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.migration_attachment TO authenticated;
GRANT ALL ON erp.migration_attachment TO service_role;
DROP POLICY IF EXISTS migration_attachment_admin ON erp.migration_attachment;
CREATE POLICY migration_attachment_admin ON erp.migration_attachment FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.migration_run r WHERE r.run_id = migration_attachment.run_id AND erp.migration_can_read(r.company_code)));

-- ATC1 rows of a company with the document they belong to (any raw table with an AtcEntry column).
CREATE OR REPLACE FUNCTION erp.migration_attachment_list(p_company varchar)
RETURNS TABLE (abs_entry integer, line integer, src_path text, trgt_path text, file_name text, file_ext text, obj_type text, doc_key text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE t record; parts text[] := '{}'; links text;
BEGIN
  IF NOT erp._mig_has('ATC1', 'AbsEntry', 'Line', 'FileName') THEN RETURN; END IF;
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid
            WHERE c.relnamespace = 'sap'::regnamespace AND c.relkind = 'r' AND a.attname = 'AtcEntry' AND NOT a.attisdropped ORDER BY 1 LOOP
    IF erp._mig_has(t.relname, 'DocEntry', 'ObjType') THEN
      parts := parts || format('SELECT "AtcEntry"::int a, "ObjType"::text o, "DocEntry"::text k FROM sap.%I WHERE company_code = $1 AND "AtcEntry" IS NOT NULL', t.relname);
    ELSIF t.relname = 'OCRD' THEN
      parts := parts || text 'SELECT "AtcEntry"::int, ''2'', "CardCode"::text FROM sap."OCRD" WHERE company_code = $1 AND "AtcEntry" IS NOT NULL';
    ELSIF t.relname = 'OITM' THEN
      parts := parts || text 'SELECT "AtcEntry"::int, ''4'', "ItemCode"::text FROM sap."OITM" WHERE company_code = $1 AND "AtcEntry" IS NOT NULL';
    ELSIF t.relname = 'OHEM' AND erp._mig_has('OHEM', 'empID') THEN
      parts := parts || text 'SELECT "AtcEntry"::int, ''171'', "empID"::text FROM sap."OHEM" WHERE company_code = $1 AND "AtcEntry" IS NOT NULL';
    END IF;
  END LOOP;
  links := CASE WHEN cardinality(parts) = 0 THEN 'SELECT NULL::int a, NULL::text o, NULL::text k WHERE false' ELSE array_to_string(parts, ' UNION ALL ') END;
  RETURN QUERY EXECUTE format(
    'WITH l AS (SELECT DISTINCT ON (a) a, o, k FROM (%s) x(a, o, k) ORDER BY a, o, k)
     SELECT t."AbsEntry"::int, t."Line"::int, %s, %s, t."FileName"::text, %s, coalesce(l.o, ''unlinked''), coalesce(l.k, t."AbsEntry"::text)
       FROM sap."ATC1" t LEFT JOIN l ON l.a = t."AbsEntry" WHERE t.company_code = $1 ORDER BY 1, 2',
    links, erp._mig_col('ATC1', 't', 'srcPath', 'text'), erp._mig_col('ATC1', 't', 'trgtPath', 'text'), erp._mig_col('ATC1', 't', 'FileExt', 'text'))
    USING p_company;
END $$;

-- Check 5.10 for the run's company: writes area 'attachments' (checks + issues), keeps its own issue sweep.
CREATE OR REPLACE FUNCTION erp.migration_attachment_check(p_run uuid, p_company varchar DEFAULT NULL)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE co varchar; f text[] := '{}'; v_listed bigint; s record; k text; v_list text;
BEGIN
  SELECT coalesce(p_company, company_code) INTO co FROM erp.migration_run WHERE run_id = p_run;
  IF co IS NULL THEN RAISE EXCEPTION 'run % not found', p_run; END IF;
  DELETE FROM erp.migration_check WHERE run_id = p_run AND company_code = co AND area = 'attachments';
  IF NOT erp._mig_has('ATC1', 'AbsEntry', 'Line', 'FileName') THEN
    f := f || erp._mig_skip(p_run, co, 'attachments', 'attachment files (ATC1 -> Storage)', 'ATC1 is not in the SAP copy');
    PERFORM erp._mig_sweep(p_run, co, ARRAY['attachments'], f);
    RETURN f;
  END IF;
  EXECUTE 'SELECT count(*) FROM sap."ATC1" WHERE company_code = $1' INTO v_listed USING co;
  SELECT count(*) n, count(*) FILTER (WHERE status IN ('copied', 'found')) found, count(*) FILTER (WHERE status = 'copied') copied,
         count(*) FILTER (WHERE status = 'missing') missing, count(*) FILTER (WHERE status = 'error') errors,
         coalesce(sum(bytes) FILTER (WHERE status IN ('copied', 'found')), 0) b_found, coalesce(sum(bytes) FILTER (WHERE status = 'copied'), 0) b_copied,
         count(*) FILTER (WHERE status = 'copied' AND sha256 IS NOT NULL) hashed
    INTO s FROM erp.migration_attachment WHERE run_id = p_run AND company_code = co;
  IF v_listed > 0 AND s.n = 0 THEN
    PERFORM erp._mig_check(p_run, co, 'attachments', 'attachment files (ATC1 -> Storage)', v_listed, NULL, NULL, false,
                           jsonb_build_object('job', 'not run'));
    k := 'att_notrun:' || co; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'warning', 'attachments', k, format('%s: the attachment copy has not run (%s files listed in ATC1)', co, v_listed),
            'Run the worker with --attachments-root (the SAP attachments folder, read only) to copy them to Storage.', 'ATC1');
  ELSE
    PERFORM erp._mig_check(p_run, co, 'attachments', 'attachment files (ATC1 -> Storage)', v_listed, s.found, s.copied,
                           s.missing = 0 AND s.errors = 0 AND s.copied = v_listed,
                           jsonb_build_object('listed', v_listed, 'found', s.found, 'copied', s.copied, 'missing', s.missing, 'errors', s.errors));
    PERFORM erp._mig_check(p_run, co, 'attachments', 'attachment bytes copied', NULL, s.b_found, s.b_copied, s.b_found = s.b_copied,
                           jsonb_build_object('hashed', s.hashed));
    PERFORM erp._mig_check(p_run, co, 'attachments', 'attachment SHA-256 recorded', s.copied, s.hashed, s.hashed, s.hashed = s.copied, NULL);
    IF s.missing > 0 THEN
      SELECT string_agg(coalesce(source_path, file_name), '; ' ORDER BY abs_entry, line) INTO v_list
        FROM (SELECT * FROM erp.migration_attachment WHERE run_id = p_run AND company_code = co AND status = 'missing' ORDER BY abs_entry, line LIMIT 30) x;
      k := 'att_missing:' || co; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'attachments', k, format('%s: %s attachment file(s) missing from the SAP folder', co, s.missing),
              v_list || CASE WHEN s.missing > 30 THEN ' ...' ELSE '' END, 'ATC1');
    END IF;
    IF s.errors > 0 THEN
      SELECT string_agg(coalesce(source_path, file_name) || ': ' || coalesce(message, ''), '; ') INTO v_list
        FROM (SELECT * FROM erp.migration_attachment WHERE run_id = p_run AND company_code = co AND status = 'error' ORDER BY abs_entry, line LIMIT 20) x;
      k := 'att_error:' || co; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'attachments', k, format('%s: %s attachment file(s) could not be copied', co, s.errors), v_list, 'ATC1');
    END IF;
  END IF;
  PERFORM erp._mig_sweep(p_run, co, ARRAY['attachments'], f);
  RETURN f;
END $$;

-- ============ 8. Coexistence: the SAP sync never overwrites Super ERP rows ============
CREATE TABLE IF NOT EXISTS erp.sync_conflict (
    company_code  varchar(8) NOT NULL,
    table_name    text NOT NULL,
    row_key       text NOT NULL,          -- key of the Super ERP row the SAP row would have overwritten
    owner_source  text,
    first_seen    timestamptz NOT NULL DEFAULT now(),
    last_seen     timestamptz NOT NULL DEFAULT now(),
    times         integer NOT NULL DEFAULT 1,
    PRIMARY KEY (company_code, table_name, row_key)
);
ALTER TABLE erp.sync_conflict ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.sync_conflict FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.sync_conflict TO authenticated;
GRANT ALL ON erp.sync_conflict TO service_role;
DROP POLICY IF EXISTS sync_conflict_admin ON erp.sync_conflict;
CREATE POLICY sync_conflict_admin ON erp.sync_conflict FOR SELECT TO authenticated USING (erp.migration_can_read(company_code));

CREATE OR REPLACE FUNCTION erp._sync_note(p_co varchar, p_table text, p_key text, p_src text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  INSERT INTO erp.sync_conflict AS c (company_code, table_name, row_key, owner_source) VALUES (p_co, p_table, p_key, p_src)
  ON CONFLICT (company_code, table_name, row_key) DO UPDATE SET last_seen = now(), times = c.times + 1, owner_source = EXCLUDED.owner_source
$$;

-- main tables (own source column): fired only for protected rows during the sync (see WHEN on the trigger)
CREATE OR REPLACE FUNCTION erp._sync_keep_own() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE v_key text;
BEGIN
  SELECT string_agg(to_jsonb(OLD)->>a, '/') INTO v_key FROM unnest(TG_ARGV) a;
  PERFORM erp._sync_note(OLD.company_code, TG_TABLE_NAME, v_key, OLD.source);
  RETURN NULL;
END $$;

-- child tables: skipped when their parent belongs to Super ERP
CREATE OR REPLACE FUNCTION erp._sync_keep_child() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE v_src text; v_key text;
BEGIN
  CASE TG_ARGV[0]
    WHEN 'document' THEN
      SELECT p.source INTO v_src FROM erp.document p WHERE p.company_code = NEW.company_code AND p.obj_type = NEW.obj_type AND p.doc_entry = NEW.doc_entry;
      v_key := NEW.obj_type || '/' || NEW.doc_entry;
    WHEN 'journal' THEN
      SELECT p.source INTO v_src FROM erp.journal_entry p WHERE p.company_code = NEW.company_code AND p.trans_id = NEW.trans_id;
      v_key := NEW.trans_id::text;
    WHEN 'payment' THEN
      SELECT p.source INTO v_src FROM erp.payment p WHERE p.company_code = NEW.company_code AND p.direction = NEW.direction AND p.doc_entry = NEW.doc_entry;
      v_key := NEW.direction || '/' || NEW.doc_entry;
    WHEN 'bp' THEN
      SELECT p.source INTO v_src FROM erp.business_partner p WHERE p.company_code = NEW.company_code AND p.card_code = NEW.card_code;
      v_key := NEW.card_code;
    WHEN 'item' THEN
      SELECT p.source INTO v_src FROM erp.item p WHERE p.company_code = NEW.company_code AND p.item_code = NEW.item_code;
      v_key := NEW.item_code;
    ELSE RETURN NEW;
  END CASE;
  IF v_src IS NOT NULL AND v_src <> 'sap' THEN
    PERFORM erp._sync_note(NEW.company_code, TG_TABLE_NAME, v_key, v_src);
    RETURN NULL;
  END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT * FROM (VALUES ('business_partner', 'card_code'), ('item', 'item_code'), ('document', 'obj_type, doc_entry'),
                                 ('journal_entry', 'trans_id'), ('payment', 'direction, doc_entry'), ('employee', 'emp_id'),
                                 ('account', 'acct_code')) x(tbl, keys) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS sync_keep_erp ON erp.%I', t.tbl);
    EXECUTE format('CREATE TRIGGER sync_keep_erp BEFORE UPDATE ON erp.%I FOR EACH ROW
                    WHEN (current_setting(''erp.sync'', true) = ''on'' AND OLD.source IS DISTINCT FROM ''sap'')
                    EXECUTE FUNCTION erp._sync_keep_own(%s)', t.tbl,
                   (SELECT string_agg(quote_literal(btrim(k)), ', ') FROM unnest(string_to_array(t.keys, ',')) k));
  END LOOP;
  FOR t IN SELECT * FROM (VALUES ('document_line', 'document'), ('journal_line', 'journal'), ('payment_allocation', 'payment'),
                                 ('bp_address', 'bp'), ('bp_merchandiser', 'bp'), ('item_price', 'item'), ('stock_balance', 'item'),
                                 ('item_certificate', 'item'), ('item_market_price', 'item')) x(tbl, parent) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS sync_keep_erp ON erp.%I', t.tbl);
    EXECUTE format('CREATE TRIGGER sync_keep_erp BEFORE INSERT OR UPDATE ON erp.%I FOR EACH ROW
                    WHEN (current_setting(''erp.sync'', true) = ''on'')
                    EXECUTE FUNCTION erp._sync_keep_child(%L)', t.tbl, t.parent);
  END LOOP;
END $$;

-- ============ 3a. Duplicate detection (warnings only, never merges) ============
CREATE OR REPLACE FUNCTION erp._mig_norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(regexp_replace(
           regexp_replace(regexp_replace(lower(coalesce(p, '')), '[^[:alnum:]]+', ' ', 'g'),
                          '\m(l l c|llc|fze|fzco|fz|ltd|limited|inc|co|est|plc)\M', ' ', 'g'),
           '\s+', '', 'g'), '')
$$;
CREATE OR REPLACE FUNCTION erp._mig_norm_phone(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 7 THEN right(regexp_replace(p, '\D', '', 'g'), 9) END
$$;

-- Partners (customers, suppliers, leads separately) by TRN, phone and normalised name; items by barcode and by
-- supplier part number + supplier. Scans every row of the company (SAP, Super ERP and sample).
CREATE OR REPLACE FUNCTION erp.migration_duplicates(p_company varchar, p_run uuid)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; r record; k text; n_trn int := 0; n_ph int := 0; n_nm int := 0; n_bc int := 0; n_spn int := 0;
BEGIN
  DELETE FROM erp.migration_check WHERE run_id = p_run AND company_code = p_company AND area = 'duplicates';
  FOR r IN
    WITH keys AS (
      SELECT b.kind, 'TRN' rule, regexp_replace(b.trn, '\D', '', 'g') v, b.card_code, b.name FROM erp.business_partner b
       WHERE b.company_code = p_company AND length(regexp_replace(coalesce(b.trn, ''), '\D', '', 'g')) >= 5
      UNION
      SELECT b.kind, 'phone', erp._mig_norm_phone(x.ph), b.card_code, b.name FROM erp.business_partner b CROSS JOIN LATERAL (VALUES (b.phone), (b.mobile)) x(ph)
       WHERE b.company_code = p_company AND erp._mig_norm_phone(x.ph) IS NOT NULL
      UNION
      SELECT b.kind, 'name', erp._mig_norm_name(b.name), b.card_code, b.name FROM erp.business_partner b
       WHERE b.company_code = p_company AND length(coalesce(erp._mig_norm_name(b.name), '')) >= 3)
    SELECT kind, rule, v, array_agg(DISTINCT card_code ORDER BY card_code) codes, string_agg(DISTINCT name, ' | ') names
      FROM keys GROUP BY 1, 2, 3 HAVING count(DISTINCT card_code) > 1 ORDER BY 1, 2, 3 LOOP
    k := 'dup:' || p_company || ':bp:' || r.rule || ':' || r.kind || ':' || r.v; f := f || k;
    IF r.rule = 'TRN' THEN n_trn := n_trn + 1; ELSIF r.rule = 'phone' THEN n_ph := n_ph + 1; ELSE n_nm := n_nm + 1; END IF;
    PERFORM erp.migration_add_issue(p_run, p_company, 'warning', 'duplicates', k,
            format('%s: %s %ss share the same %s: %s', p_company, cardinality(r.codes), r.kind, r.rule, array_to_string(r.codes, ', ')),
            format('%s %s. Names: %s. Not merged: Finance decides, any merge is done in SAP before the final run.', r.rule, r.v, r.names),
            'OCRD');
  END LOOP;
  FOR r IN SELECT 'barcode' rule, NULL::text sup, btrim(i.barcode) v, array_agg(i.item_code ORDER BY i.item_code) codes, string_agg(i.name, ' | ') names
             FROM erp.item i WHERE i.company_code = p_company AND coalesce(btrim(i.barcode), '') <> '' GROUP BY 3 HAVING count(*) > 1
           UNION ALL
           SELECT 'supplier part number', i.preferred_supplier, btrim(i.supplier_part_no), array_agg(i.item_code ORDER BY i.item_code), string_agg(i.name, ' | ')
             FROM erp.item i WHERE i.company_code = p_company AND coalesce(btrim(i.supplier_part_no), '') <> '' AND coalesce(btrim(i.preferred_supplier), '') <> ''
            GROUP BY 2, 3 HAVING count(*) > 1
           ORDER BY 1, 2, 3 LOOP
    k := 'dup:' || p_company || ':item:' || r.rule || ':' || coalesce(r.sup || ':', '') || r.v; f := f || k;
    IF r.rule = 'barcode' THEN n_bc := n_bc + 1; ELSE n_spn := n_spn + 1; END IF;
    PERFORM erp.migration_add_issue(p_run, p_company, 'warning', 'duplicates', k,
            format('%s: %s items share the same %s: %s', p_company, cardinality(r.codes), r.rule, array_to_string(r.codes, ', ')),
            format('%s %s%s. Names: %s. Not merged: decide which code stays before the final run.', r.rule, r.v,
                   coalesce(' from supplier ' || r.sup, ''), r.names), 'OITM');
  END LOOP;
  PERFORM erp._mig_check(p_run, p_company, 'duplicates', 'partners sharing a TRN', NULL, NULL, n_trn, true, jsonb_build_object('groups', n_trn));
  PERFORM erp._mig_check(p_run, p_company, 'duplicates', 'partners sharing a phone number', NULL, NULL, n_ph, true, jsonb_build_object('groups', n_ph));
  PERFORM erp._mig_check(p_run, p_company, 'duplicates', 'partners sharing a normalised name', NULL, NULL, n_nm, true, jsonb_build_object('groups', n_nm));
  PERFORM erp._mig_check(p_run, p_company, 'duplicates', 'items sharing a barcode', NULL, NULL, n_bc, true, jsonb_build_object('groups', n_bc));
  PERFORM erp._mig_check(p_run, p_company, 'duplicates', 'items sharing a supplier part number', NULL, NULL, n_spn, true, jsonb_build_object('groups', n_spn));
  RETURN f;
END $$;

-- ============ 3b. Reconciliation checks 5.3, 5.5-5.9 ============
-- 5.3 inventory value = inventory G/L accounts (per inventory account of the warehouses, OWHS.BalInvntAc)
CREATE OR REPLACE FUNCTION erp._mc_inventory_gl(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; r record; k text; ok boolean; t_gr numeric := 0; t_rv numeric := 0; t_av numeric := 0; t_ga numeric := 0; bad int := 0;
BEGIN
  IF NOT erp._mig_has('OITW', 'WhsCode', 'OnHand', 'AvgPrice') OR NOT erp._mig_has('OWHS', 'WhsCode', 'BalInvntAc') OR NOT erp._mig_has('JDT1', 'Account', 'Debit', 'Credit') THEN
    RETURN ARRAY[erp._mig_skip(p_run, co, 'inventory_gl', 'inventory value = inventory G/L accounts', 'needs OITW, OWHS.BalInvntAc and JDT1 in the SAP copy')];
  END IF;
  FOR r IN EXECUTE $q$
    WITH whs AS (SELECT "WhsCode" w, nullif(btrim("BalInvntAc"), '') acct FROM sap."OWHS" WHERE company_code = $1),
         rs AS (SELECT "WhsCode" w, sum(coalesce("OnHand", 0) * coalesce("AvgPrice", 0)) v FROM sap."OITW" WHERE company_code = $1 GROUP BY 1),
         aps AS (SELECT whs_code w, sum(on_hand * coalesce(avg_cost, 0)) v FROM erp.stock_balance WHERE company_code = $1 GROUP BY 1),
         per AS (SELECT coalesce(rs.w, aps.w) w, rs.v rv, aps.v av FROM rs FULL JOIN aps ON aps.w = rs.w),
         acc AS (SELECT whs.acct, array_agg(per.w ORDER BY per.w) whs, sum(per.rv) rv, sum(per.av) av FROM per LEFT JOIN whs ON whs.w = per.w GROUP BY 1)
    SELECT acc.acct, acc.whs, coalesce(acc.rv, 0) rv, coalesce(acc.av, 0) av,
           (SELECT coalesce(sum(coalesce(j."Debit", 0) - coalesce(j."Credit", 0)), 0) FROM sap."JDT1" j WHERE j.company_code = $1 AND j."Account" = acc.acct) gr,
           (SELECT coalesce(sum(l.debit - l.credit), 0) FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
             WHERE l.company_code = $1 AND l.acct_code = acc.acct AND e.source = 'sap') ga
      FROM acc ORDER BY 1 NULLS FIRST $q$ USING co LOOP
    IF r.acct IS NULL THEN
      ok := erp._mig_eq(r.rv, 0) AND erp._mig_eq(r.av, 0);
      PERFORM erp._mig_check(p_run, co, 'inventory_gl', 'inventory value, warehouses without an inventory account', NULL, r.rv, r.av, ok,
                             jsonb_build_object('warehouses', to_jsonb(r.whs)));
      k := 'invgl_noacct:' || co; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, CASE WHEN ok THEN 'warning' ELSE 'critical' END, 'inventory_gl', k,
              format('%s: warehouses without an inventory account: %s', co, array_to_string(r.whs, ', ')),
              format('OWHS.BalInvntAc is empty. Stock value in SAP %s, in the app %s. Set the account in SAP (or confirm item-group accounts are used).', r.rv, r.av), 'OWHS');
      CONTINUE;
    END IF;
    ok := erp._mig_eq(r.gr, r.rv) AND erp._mig_eq(r.rv, r.av) AND erp._mig_eq(r.ga, r.gr);
    t_gr := t_gr + r.gr; t_rv := t_rv + r.rv; t_av := t_av + r.av; t_ga := t_ga + r.ga;
    PERFORM erp._mig_check(p_run, co, 'inventory_gl', 'inventory value = G/L ' || r.acct, r.gr, r.rv, r.av, ok,
                           jsonb_build_object('account', r.acct, 'warehouses', to_jsonb(r.whs), 'gl_app', r.ga,
                                              'sap', 'JDT1 balance', 'raw', 'OITW OnHand x AvgPrice', 'app', 'stock_balance value'));
    IF NOT ok THEN
      bad := bad + 1;
      k := 'invgl:' || co || ':' || r.acct; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'inventory_gl', k, format('%s: inventory value differs from G/L account %s', co, r.acct),
              format('G/L in SAP %s, stock value in SAP %s, stock value in the app %s, G/L in the app %s. Warehouses: %s',
                     r.gr, r.rv, r.av, r.ga, array_to_string(r.whs, ', ')), 'OITW');
    END IF;
  END LOOP;
  PERFORM erp._mig_check(p_run, co, 'inventory_gl', 'inventory value = inventory G/L accounts (total)', t_gr, t_rv, t_av,
                         bad = 0 AND erp._mig_eq(t_gr, t_rv) AND erp._mig_eq(t_rv, t_av), jsonb_build_object('accounts_differing', bad, 'gl_app', t_ga));
  RETURN f;
END $$;

-- 5.5 A/R and A/P per partner: OCRD.Balance (SAP) = open items in the SAP copy = open items in the app.
-- Amounts are debit - credit: invoices + down payments - credit notes for customers, the negative for suppliers,
-- minus / plus payments on account (ORCT / OVPM OpenBal, from SAP on both sides).
CREATE OR REPLACE FUNCTION erp._mc_partners(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; d record; parts text[] := '{}'; pays text[] := '{}'; r record; k text; v_ok boolean; q text;
        n_bad int := 0; n_issues int := 0; s record; v_ctl numeric; v_ctl_app numeric; v_accts text[];
BEGIN
  IF NOT erp._mig_has('OCRD', 'CardCode', 'CardType', 'Balance') OR NOT erp._mig_has('JDT1', 'Account', 'ShortName', 'Debit', 'Credit') THEN
    RETURN ARRAY[erp._mig_skip(p_run, co, 'partners', 'partner balances = open items', 'needs OCRD (CardCode, CardType, Balance) and JDT1 in the SAP copy')];
  END IF;
  FOR d IN SELECT * FROM (VALUES ('OINV', 1), ('ODPI', 1), ('ORIN', -1), ('OPCH', -1), ('ODPO', -1), ('ORPC', 1)) x(t, m) LOOP
    IF erp._mig_has(d.t, 'CardCode', 'DocTotal', 'PaidToDate', 'CANCELED', 'DocStatus') THEN
      parts := parts || format('SELECT "CardCode" c, %s * ("DocTotal" - coalesce("PaidToDate", 0)) v FROM sap.%I WHERE company_code = $1 '
                               'AND coalesce("CANCELED", ''N'') NOT IN (''Y'', ''C'') AND coalesce("DocStatus", ''O'') <> ''C''', d.m, d.t);
    END IF;
  END LOOP;
  IF erp._mig_has('ORCT', 'CardCode', 'OpenBal', 'Canceled') THEN
    pays := pays || text 'SELECT "CardCode" c, -coalesce("OpenBal", 0) v FROM sap."ORCT" WHERE company_code = $1 AND coalesce("Canceled", ''N'') <> ''Y''';
  END IF;
  IF erp._mig_has('OVPM', 'CardCode', 'OpenBal', 'Canceled') THEN
    pays := pays || text 'SELECT "CardCode" c, coalesce("OpenBal", 0) v FROM sap."OVPM" WHERE company_code = $1 AND coalesce("Canceled", ''N'') <> ''Y''';
  END IF;
  q := format($q$
    WITH bp AS (SELECT "CardCode" c, "CardType" k, coalesce("Balance", 0) b FROM sap."OCRD" WHERE company_code = $1 AND "CardType" IN ('C', 'S')),
         ro AS (SELECT c, sum(v) v FROM (%s) x GROUP BY 1),
         pay AS (SELECT c, sum(v) v FROM (%s) x GROUP BY 1),
         jr AS (SELECT "ShortName" c, sum(coalesce("Debit", 0) - coalesce("Credit", 0)) v FROM sap."JDT1"
                 WHERE company_code = $1 AND "ShortName" IS DISTINCT FROM "Account" GROUP BY 1),
         ao AS (SELECT card_code c, sum(CASE WHEN obj_type IN (13, 203, 14) THEN 1 ELSE -1 END * coalesce(sign, 1) * (coalesce(total, 0) - coalesce(paid, 0))) v
                  FROM erp.document WHERE company_code = $1 AND source = 'sap' AND status = 'open' AND obj_type IN (13, 203, 14, 18, 204, 19) GROUP BY 1)
    SELECT bp.c, bp.k, bp.b, coalesce(ro.v, 0) + coalesce(pay.v, 0) rv, coalesce(ao.v, 0) + coalesce(pay.v, 0) av, coalesce(jr.v, 0) jrv, coalesce(pay.v, 0) pv
      FROM bp LEFT JOIN ro ON ro.c = bp.c LEFT JOIN pay ON pay.c = bp.c LEFT JOIN jr ON jr.c = bp.c LEFT JOIN ao ON ao.c = bp.c ORDER BY bp.k, bp.c $q$,
    CASE WHEN cardinality(parts) = 0 THEN 'SELECT NULL::text c, 0::numeric v WHERE false' ELSE array_to_string(parts, ' UNION ALL ') END,
    CASE WHEN cardinality(pays) = 0 THEN 'SELECT NULL::text c, 0::numeric v WHERE false' ELSE array_to_string(pays, ' UNION ALL ') END);
  CREATE TEMP TABLE IF NOT EXISTS _mc_bp (c text, kind text, b numeric, rv numeric, av numeric, jrv numeric, pv numeric, ok boolean) ON COMMIT DROP;
  TRUNCATE _mc_bp;
  FOR r IN EXECUTE q USING co LOOP
    v_ok := erp._mig_eq(r.b, r.rv) AND erp._mig_eq(r.rv, r.av) AND erp._mig_eq(r.jrv, r.b);
    INSERT INTO _mc_bp VALUES (r.c, r.k, r.b, r.rv, r.av, r.jrv, r.pv, v_ok);
    IF NOT v_ok THEN
      n_bad := n_bad + 1;
      IF n_bad <= 500 THEN
        PERFORM erp._mig_check(p_run, co, 'partners', 'partner balance ' || r.c, r.b, r.rv, r.av, false,
                               jsonb_build_object('card_code', r.c, 'kind', r.k, 'journal_balance', r.jrv, 'payments_on_account', r.pv));
      END IF;
      IF n_bad <= 100 THEN
        k := 'bp:' || co || ':' || r.c; f := f || k;
        PERFORM erp.migration_add_issue(p_run, co, 'critical', 'partners', k, format('%s: balance of %s does not match its open items', co, r.c),
                format('SAP balance (OCRD) %s, SAP journal lines %s, open items in SAP %s, open items in the app %s (payments on account %s)',
                       r.b, r.jrv, r.rv, r.av, r.pv), 'OCRD');
      END IF;
    END IF;
  END LOOP;
  IF n_bad > 100 THEN
    k := 'bp_more:' || co; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'critical', 'partners', k, format('%s: %s more partners do not match their open items', co, n_bad - 100),
            'Only the first 100 are listed one by one. Export the check list for all of them.', 'OCRD');
  END IF;
  -- per kind totals and the control accounts
  FOR s IN SELECT x.k, x.label, x.ctl FROM (VALUES ('C', 'customer balances = open items', 'A/R control accounts = open customer items'),
                                                ('S', 'supplier balances = open items', 'A/P control accounts = open supplier items')) x(k, label, ctl) LOOP
    SELECT count(*) n, count(*) FILTER (WHERE NOT _mc_bp.ok) bad, coalesce(sum(b), 0) b, coalesce(sum(rv), 0) rv, coalesce(sum(av), 0) av INTO r FROM _mc_bp WHERE _mc_bp.kind = s.k;
    PERFORM erp._mig_check(p_run, co, 'partners', s.label, r.b, r.rv, r.av, r.bad = 0, jsonb_build_object('partners', r.n, 'differing', r.bad));
    EXECUTE 'SELECT array_agg(DISTINCT j."Account") FROM sap."JDT1" j JOIN sap."OCRD" b ON b.company_code = j.company_code AND b."CardCode" = j."ShortName"
              WHERE j.company_code = $1 AND j."ShortName" <> j."Account" AND b."CardType" = $2' INTO v_accts USING co, s.k;
    EXECUTE 'SELECT coalesce(sum(coalesce("Debit", 0) - coalesce("Credit", 0)), 0) FROM sap."JDT1" WHERE company_code = $1 AND "Account" = ANY ($2)'
      INTO v_ctl USING co, coalesce(v_accts, '{}');
    SELECT coalesce(sum(l.debit - l.credit), 0) INTO v_ctl_app FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
     WHERE l.company_code = co AND e.source = 'sap' AND l.acct_code = ANY (coalesce(v_accts, '{}'));
    v_ok := erp._mig_eq(v_ctl, r.rv) AND erp._mig_eq(v_ctl_app, v_ctl);
    PERFORM erp._mig_check(p_run, co, 'partners', s.ctl, v_ctl, r.rv, v_ctl_app, v_ok,
                           jsonb_build_object('accounts', to_jsonb(coalesce(v_accts, '{}')), 'sap', 'control account balance (JDT1)',
                                              'raw', 'open items in SAP', 'app', 'control account balance (app journals)'));
    IF NOT v_ok THEN
      k := 'ctl:' || co || ':' || s.k; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'partners', k, format('%s: %s do not match', co, s.ctl),
              format('control accounts %s: SAP %s, app %s; open items in SAP %s', array_to_string(coalesce(v_accts, '{}'), ', '), v_ctl, v_ctl_app, r.rv));
    END IF;
  END LOOP;
  RETURN f;
END $$;

-- 5.6 open sales and purchase orders: count, open quantity, open value
CREATE OR REPLACE FUNCTION erp._mc_open_orders(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; d record; k text; rc numeric; rq numeric; rv numeric; rs numeric; ac numeric; aq numeric; av numeric; v_disc text; v_hdr text;
BEGIN
  FOR d IN SELECT * FROM (VALUES ('ORDR', 'RDR1', 17, 'open sales orders'), ('OPOR', 'POR1', 22, 'open purchase orders')) x(h, l, obj, name) LOOP
    IF NOT erp._mig_has(d.h, 'DocEntry', 'DocStatus', 'CANCELED') OR NOT erp._mig_has(d.l, 'DocEntry', 'OpenQty', 'Price', 'LineStatus') THEN
      f := f || erp._mig_skip(p_run, co, 'open_orders', d.name, format('needs %s and %s in the SAP copy', d.h, d.l));
      CONTINUE;
    END IF;
    v_hdr := 'coalesce(h."CANCELED", ''N'') NOT IN (''Y'', ''C'') AND coalesce(h."DocStatus", ''O'') = ''O''';
    v_disc := CASE WHEN erp._mig_has(d.l, 'DiscPrcnt') THEN '(1 - coalesce(l."DiscPrcnt", 0) / 100)' ELSE '1' END;
    EXECUTE format('SELECT count(*) FROM sap.%I h WHERE h.company_code = $1 AND %s', d.h, v_hdr) INTO rc USING co;
    EXECUTE format('SELECT coalesce(sum(l."OpenQty"), 0), coalesce(sum(l."OpenQty" * coalesce(l."Price", 0) * %s), 0), %s
                      FROM sap.%I l JOIN sap.%I h ON h.company_code = l.company_code AND h."DocEntry" = l."DocEntry"
                     WHERE l.company_code = $1 AND %s AND coalesce(l."LineStatus", ''O'') = ''O''',
                   v_disc, CASE WHEN erp._mig_has(d.l, 'OpenSum') THEN 'sum(l."OpenSum")' ELSE 'NULL::numeric' END, d.l, d.h, v_hdr)
      INTO rq, rv, rs USING co;
    SELECT count(*) INTO ac FROM erp.document WHERE company_code = co AND obj_type = d.obj AND source = 'sap' AND status = 'open';
    SELECT coalesce(sum(l.open_qty), 0), coalesce(sum(l.open_qty * coalesce(l.price, 0) * (1 - coalesce(l.discount_pct, 0) / 100)), 0) INTO aq, av
      FROM erp.document_line l JOIN erp.document h USING (company_code, obj_type, doc_entry)
     WHERE l.company_code = co AND l.obj_type = d.obj AND h.source = 'sap' AND h.status = 'open' AND coalesce(l.line_status, 'O') = 'O';
    PERFORM erp._mig_check(p_run, co, 'open_orders', d.name || ': count', NULL, rc, ac, rc = ac, jsonb_build_object('obj_type', d.obj));
    PERFORM erp._mig_check(p_run, co, 'open_orders', d.name || ': open quantity', NULL, rq, aq, round(rq, 3) = round(aq, 3), jsonb_build_object('obj_type', d.obj));
    PERFORM erp._mig_check(p_run, co, 'open_orders', d.name || ': open value', rs, rv, av, erp._mig_eq(rv, av),
                           jsonb_build_object('obj_type', d.obj, 'sap', 'OpenSum (SAP, local currency)', 'value', 'open qty x price x (1 - discount)'));
    IF rc <> ac OR round(rq, 3) <> round(aq, 3) OR NOT erp._mig_eq(rv, av) THEN
      k := 'oo:' || co || ':' || d.obj; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'open_orders', k, format('%s: %s differ between SAP and the app', co, d.name),
              format('count %s / %s, open quantity %s / %s, open value %s / %s (SAP copy / app)', rc, ac, rq, aq, rv, av), d.h);
    END IF;
  END LOOP;
  RETURN f;
END $$;

-- 5.7 VAT payable (output, OVTG.Category O) and recoverable (input, I) for the last open period
CREATE OR REPLACE FUNCTION erp._mc_vat(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; s erp.migration_setting; v_from date; v_to date; c record; a record; k text; t_raw numeric; t_app numeric; n int; v_label text; m int;
-- note: tax codes whose account appears in both categories are counted in each
BEGIN
  IF NOT erp._mig_has('OVTG', 'Code', 'Account', 'Category') OR NOT erp._mig_has('JDT1', 'Account', 'Debit', 'Credit', 'RefDate') THEN
    RETURN ARRAY[erp._mig_skip(p_run, co, 'vat', 'VAT accounts, last open period', 'needs OVTG (Account, Category) and JDT1 in the SAP copy')];
  END IF;
  SELECT * INTO s FROM erp.migration_setting WHERE company_code = co;
  IF s.vat_period_from IS NOT NULL THEN
    v_from := s.vat_period_from; v_to := s.vat_period_to;
  ELSE
    EXECUTE 'SELECT date_trunc(''month'', max("RefDate"))::date FROM sap."JDT1" WHERE company_code = $1' INTO v_from USING co;
    IF v_from IS NULL THEN RETURN ARRAY[erp._mig_skip(p_run, co, 'vat', 'VAT accounts, last open period', 'no journal lines in the SAP copy')]; END IF;
    v_to := (v_from + interval '1 month - 1 day')::date;
  END IF;
  v_label := to_char(v_from, 'YYYY-MM-DD') || '..' || to_char(v_to, 'YYYY-MM-DD');
  FOR c IN SELECT * FROM (VALUES ('O', 'VAT payable', -1), ('I', 'VAT recoverable', 1)) x(cat, label, sgn) LOOP
    t_raw := 0; t_app := 0; n := 0; m := 0;
    FOR a IN EXECUTE $q$
      WITH acc AS (SELECT DISTINCT btrim("Account") acct FROM sap."OVTG" WHERE company_code = $1 AND "Category" = $2 AND coalesce(btrim("Account"), '') <> '')
      SELECT acc.acct,
             (SELECT $3 * coalesce(sum(coalesce(j."Debit", 0) - coalesce(j."Credit", 0)), 0) FROM sap."JDT1" j
               WHERE j.company_code = $1 AND j."Account" = acc.acct AND j."RefDate"::date BETWEEN $4 AND $5) rv,
             (SELECT $3 * coalesce(sum(l.debit - l.credit), 0) FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
               WHERE l.company_code = $1 AND l.acct_code = acc.acct AND e.source = 'sap' AND coalesce(l.ref_date, e.ref_date) BETWEEN $4 AND $5) av
        FROM acc ORDER BY 1 $q$ USING co, c.cat, c.sgn, v_from, v_to LOOP
      n := n + 1; t_raw := t_raw + a.rv; t_app := t_app + a.av;
      PERFORM erp._mig_check(p_run, co, 'vat', c.label || ' ' || a.acct || ' ' || v_label, NULL, a.rv, a.av, erp._mig_eq(a.rv, a.av),
                             jsonb_build_object('account', a.acct, 'from', v_from, 'to', v_to, 'category', c.cat));
      IF NOT erp._mig_eq(a.rv, a.av) THEN
        m := m + 1;
        k := 'vat:' || co || ':' || c.cat || ':' || a.acct; f := f || k;
        PERFORM erp.migration_add_issue(p_run, co, 'critical', 'vat', k, format('%s: %s on account %s differs for %s', co, c.label, a.acct, v_label),
                format('SAP copy %s, app %s', a.rv, a.av), 'JDT1');
      END IF;
    END LOOP;
    IF n = 0 THEN
      f := f || erp._mig_skip(p_run, co, 'vat', c.label || ', last open period', format('no OVTG tax code of category %s has an account', c.cat));
    ELSE
      PERFORM erp._mig_check(p_run, co, 'vat', c.label || ', last open period', NULL, t_raw, t_app, m = 0,
                             jsonb_build_object('accounts', n, 'from', v_from, 'to', v_to, 'period_from_setting', s.vat_period_from IS NOT NULL));
    END IF;
  END LOOP;
  RETURN f;
END $$;

-- 5.8 intercompany balances net to zero (pairs of companies, journal BP lines on intercompany partners)
CREATE OR REPLACE FUNCTION erp._mc_intercompany(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; b record; k text; v_cur text; r1 numeric; r2 numeric; a1 numeric; a2 numeric; n int := 0; v_loaded boolean; ok boolean; v_name text;
  q_raw constant text := 'SELECT coalesce(sum(coalesce(j."Debit", 0) - coalesce(j."Credit", 0)), 0) FROM sap."JDT1" j
                           JOIN sap."OCRD" p ON p.company_code = j.company_code AND p."CardCode" = j."ShortName"
                          WHERE j.company_code = $1 AND j."ShortName" <> j."Account" AND left(btrim(p."U_CTX_ICPC"), 8) = $2';
BEGIN
  IF NOT erp._mig_has('OCRD', 'CardCode', 'U_CTX_ICPC') OR NOT erp._mig_has('JDT1', 'Account', 'ShortName', 'Debit', 'Credit') THEN
    RETURN ARRAY[erp._mig_skip(p_run, co, 'intercompany', 'intercompany balances net to zero', 'needs OCRD.U_CTX_ICPC and JDT1 in the SAP copy')];
  END IF;
  SELECT currency INTO v_cur FROM sap._company WHERE company_code = co;
  FOR b IN SELECT c.company_code, c.currency FROM sap._company c WHERE c.company_code <> co ORDER BY 1 LOOP
    EXECUTE q_raw INTO r1 USING co, b.company_code;
    EXECUTE q_raw INTO r2 USING b.company_code, co;
    SELECT coalesce(sum(l.debit - l.credit), 0) INTO a1 FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
      JOIN erp.business_partner p ON p.company_code = l.company_code AND p.card_code = l.short_name
     WHERE l.company_code = co AND e.source = 'sap' AND l.short_name <> l.acct_code AND p.ic_partner_company = b.company_code;
    SELECT coalesce(sum(l.debit - l.credit), 0) INTO a2 FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
      JOIN erp.business_partner p ON p.company_code = l.company_code AND p.card_code = l.short_name
     WHERE l.company_code = b.company_code AND e.source = 'sap' AND l.short_name <> l.acct_code AND p.ic_partner_company = co;
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM sap."OCRD" WHERE company_code = $1 AND left(btrim("U_CTX_ICPC"), 8) = $2)
                 OR EXISTS (SELECT 1 FROM sap."OCRD" WHERE company_code = $2 AND left(btrim("U_CTX_ICPC"), 8) = $1)' INTO v_loaded USING co, b.company_code;
    CONTINUE WHEN NOT v_loaded AND r1 = 0 AND r2 = 0 AND a1 = 0 AND a2 = 0;
    n := n + 1;
    v_name := 'intercompany ' || least(co, b.company_code) || ' / ' || greatest(co, b.company_code);
    IF b.currency IS DISTINCT FROM v_cur THEN
      f := f || erp._mig_skip(p_run, co, 'intercompany', v_name, format('different currencies (%s / %s): compare in SAP with the rates used there', v_cur, b.currency));
      CONTINUE;
    END IF;
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM sap."JDT1" WHERE company_code = $1)' INTO v_loaded USING b.company_code;
    IF NOT v_loaded THEN
      f := f || erp._mig_skip(p_run, co, 'intercompany', v_name, format('%s is not loaded yet', b.company_code));
      CONTINUE;
    END IF;
    ok := erp._mig_eq(r1 + r2, 0) AND erp._mig_eq(a1 + a2, 0);
    PERFORM erp._mig_check(p_run, co, 'intercompany', v_name, 0, r1 + r2, a1 + a2, ok,
                           jsonb_build_object(co || '->' || b.company_code, jsonb_build_object('raw', r1, 'app', a1),
                                              b.company_code || '->' || co, jsonb_build_object('raw', r2, 'app', a2)));
    IF NOT ok THEN
      k := 'ic:' || co || ':' || b.company_code; f := f || k;
      PERFORM erp.migration_add_issue(p_run, co, 'critical', 'intercompany', k, format('%s: intercompany balances with %s do not net to zero', co, b.company_code),
              format('%s with %s: SAP %s app %s; %s with %s: SAP %s app %s', co, b.company_code, r1, a1, b.company_code, co, r2, a2), 'JDT1');
    END IF;
  END LOOP;
  IF n = 0 THEN
    PERFORM erp._mig_check(p_run, co, 'intercompany', 'intercompany partners', NULL, 0, 0, true, jsonb_build_object('note', 'no intercompany partners (OCRD.U_CTX_ICPC)'));
  END IF;
  RETURN f;
END $$;

-- 5.9 payroll: employees paid and net pay of the last period (@ALT_HR_PRRT, as unpivoted by erp.sync_payroll_results)
CREATE OR REPLACE FUNCTION erp._mc_payroll(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; v_p text; v_codes text[]; re int; ae int; rn numeric; an numeric; k text; v_name text;
  rx constant text := '^U_ALT(I?[0-9]{3,4}|L[PB][0-9]{2}|IN[0-9]{2})$';
BEGIN
  IF NOT erp._mig_has('@ALT_HR_PRRT', 'U_ALTINPRD', 'U_ALTEMPID') THEN
    RETURN ARRAY[erp._mig_skip(p_run, co, 'payroll', 'payroll, last period', 'needs @ALT_HR_PRRT in the SAP copy')];
  END IF;
  EXECUTE 'SELECT max("U_ALTINPRD") FROM sap."@ALT_HR_PRRT" WHERE company_code = $1 AND "U_ALTEMPID" IS NOT NULL' INTO v_p USING co;
  IF v_p IS NULL THEN RETURN ARRAY[erp._mig_skip(p_run, co, 'payroll', 'payroll, last period', 'no payroll results in the SAP copy')]; END IF;
  SELECT coalesce(net_pay_wage_codes, '{}') INTO v_codes FROM erp.migration_setting WHERE company_code = co;
  v_codes := coalesce(v_codes, '{}');
  EXECUTE 'SELECT count(DISTINCT "U_ALTEMPID") FROM sap."@ALT_HR_PRRT" WHERE company_code = $1 AND "U_ALTINPRD" = $2 AND "U_ALTEMPID" IS NOT NULL'
    INTO re USING co, v_p;
  EXECUTE 'SELECT coalesce(sum(kv.value::numeric), 0) FROM sap."@ALT_HR_PRRT" r CROSS JOIN LATERAL jsonb_each_text(to_jsonb(r)) kv
            WHERE r.company_code = $1 AND r."U_ALTINPRD" = $2 AND r."U_ALTEMPID" IS NOT NULL AND kv.key ~ $3 AND kv.value ~ ''^-?[0-9.]+$''
              AND (cardinality($4::text[]) = 0 OR substr(kv.key, 6) = ANY ($4::text[]))' INTO rn USING co, v_p, rx, v_codes;
  SELECT count(DISTINCT hr_code), coalesce(sum(amount) FILTER (WHERE cardinality(v_codes) = 0 OR wage_code = ANY (v_codes)), 0) INTO ae, an
    FROM erp.payroll_result WHERE company_code = co AND period = v_p;
  PERFORM erp._mig_check(p_run, co, 'payroll', 'employees paid ' || v_p, NULL, re, ae, re = ae, jsonb_build_object('period', v_p));
  v_name := CASE WHEN cardinality(v_codes) = 0 THEN 'payroll total ' || v_p || ' (all wage codes)' ELSE 'net pay ' || v_p END;
  PERFORM erp._mig_check(p_run, co, 'payroll', v_name, NULL, rn, an, erp._mig_eq(rn, an), jsonb_build_object('period', v_p, 'wage_codes', to_jsonb(v_codes)));
  IF cardinality(v_codes) = 0 THEN
    k := 'payroll_codes:' || co; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'info', 'payroll', k, format('%s: net-pay wage codes are not set', co),
            'The check compares the total of all wage codes. Enter the net-pay wage codes under Opening balances and settings.');
  END IF;
  IF re <> ae OR NOT erp._mig_eq(rn, an) THEN
    k := 'payroll:' || co || ':' || v_p; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'critical', 'payroll', k, format('%s: payroll for %s differs between SAP and the app', co, v_p),
            format('employees %s / %s, %s %s / %s (SAP copy / app)', re, ae, v_name, rn, an), '@ALT_HR_PRRT');
  END IF;
  RETURN f;
END $$;

-- SAP rows the sync did not apply because a Super ERP record owns the key
CREATE OR REPLACE FUNCTION erp._mc_coexistence(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE f text[] := '{}'; r record; k text; n int := 0;
BEGIN
  FOR r IN SELECT table_name, count(*) n, sum(times) times, string_agg(row_key, ', ' ORDER BY row_key) FILTER (WHERE true) keys
             FROM erp.sync_conflict WHERE company_code = co GROUP BY 1 ORDER BY 1 LOOP
    n := n + 1;
    PERFORM erp._mig_check(p_run, co, 'coexistence', 'SAP rows not applied (Super ERP owns the key): ' || r.table_name, 0, r.n, 0, false,
                           jsonb_build_object('keys', left(r.keys, 2000), 'times', r.times));
    k := 'coexist:' || co || ':' || r.table_name; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'warning', 'coexistence', k,
            format('%s: %s SAP %s row(s) were not applied because a Super ERP record uses the same key', co, r.n, r.table_name),
            format('Keys: %s. The sync never overwrites Super ERP records. Renumber in SAP or decide which record stays before go-live.', left(r.keys, 500)),
            r.table_name);
  END LOOP;
  IF n = 0 THEN
    PERFORM erp._mig_check(p_run, co, 'coexistence', 'SAP rows not applied (Super ERP owns the key)', 0, 0, 0, true, NULL);
  END IF;
  RETURN f;
END $$;

-- custom-field register state: proposed drops waiting for the owner
CREATE OR REPLACE FUNCTION erp._mc_custom_fields(p_run uuid, co varchar)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE s record; k text; f text[] := '{}';
BEGIN
  SELECT count(*) n, count(*) FILTER (WHERE decision = 'drop' AND drop_state = 'pending') pend,
         count(*) FILTER (WHERE decision = 'mapped') mapped, count(*) FILTER (WHERE decision = 'drop' AND drop_state = 'approved') dropped
    INTO s FROM erp.custom_field_register WHERE company_code = co;
  PERFORM erp._mig_check(p_run, co, 'custom_fields', 'custom fields on the register', NULL, s.n, s.mapped, true,
                         jsonb_build_object('mapped', s.mapped, 'drop_approved', s.dropped, 'drop_pending', s.pend));
  PERFORM erp._mig_check(p_run, co, 'custom_fields', 'proposed drops waiting for the owner', 0, s.pend, s.pend, s.pend = 0, NULL);
  IF s.pend > 0 THEN
    k := 'cf_pending:' || co; f := f || k;
    PERFORM erp.migration_add_issue(p_run, co, 'warning', 'custom_fields', k, format('%s: %s custom field(s) proposed for dropping wait for the owner''s approval', co, s.pend),
            'Open Custom fields on this run. Only the owner position can approve a drop.');
  END IF;
  RETURN f;
END $$;

-- All checks added by A12 for one company (or every in-scope company): 5.3, 5.5-5.10, duplicates, register, coexistence.
CREATE OR REPLACE FUNCTION erp.migration_more_checks(p_company varchar, p_run uuid)
RETURNS TABLE (companies integer, checks bigint, failed bigint, critical_open bigint, warning_open bigint, info_open bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE co varchar; v_cos varchar[]; f text[];
  areas constant text[] := ARRAY['inventory_gl', 'partners', 'open_orders', 'vat', 'intercompany', 'payroll', 'duplicates', 'coexistence', 'custom_fields'];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM erp.migration_run m WHERE m.run_id = p_run) THEN RAISE EXCEPTION 'run % not found', p_run; END IF;
  SELECT array_agg(c.company_code ORDER BY c.company_code) INTO v_cos FROM sap._company c
   WHERE (p_company IS NULL AND c.in_scope) OR c.company_code = p_company;
  IF v_cos IS NULL THEN RAISE EXCEPTION 'unknown company %', p_company; END IF;
  FOREACH co IN ARRAY v_cos LOOP
    DELETE FROM erp.migration_check c WHERE c.run_id = p_run AND c.company_code = co AND c.area = ANY (areas);
    f := erp._mc_inventory_gl(p_run, co) || erp._mc_partners(p_run, co) || erp._mc_open_orders(p_run, co) || erp._mc_vat(p_run, co)
      || erp._mc_intercompany(p_run, co) || erp._mc_payroll(p_run, co) || erp.migration_duplicates(co, p_run)
      || erp._mc_coexistence(p_run, co) || erp._mc_custom_fields(p_run, co);
    PERFORM erp._mig_sweep(p_run, co, areas, f);
    PERFORM erp.migration_attachment_check(p_run, co);
  END LOOP;
  RETURN QUERY SELECT cardinality(v_cos),
    (SELECT count(*) FROM erp.migration_check c WHERE c.run_id = p_run),
    (SELECT count(*) FROM erp.migration_check c WHERE c.run_id = p_run AND NOT c.ok),
    (SELECT count(*) FROM erp.migration_issue i WHERE i.run_id = p_run AND i.status = 'open' AND i.severity = 'critical'),
    (SELECT count(*) FROM erp.migration_issue i WHERE i.run_id = p_run AND i.status = 'open' AND i.severity = 'warning'),
    (SELECT count(*) FROM erp.migration_issue i WHERE i.run_id = p_run AND i.status = 'open' AND i.severity = 'info');
END $$;

-- ============ 6. Opening-balances-only loader (plan §2 option 2) ============
-- Runs inside the worker's transaction right after the app sync of an 'opening_only' run. Keeps master data and open
-- documents, removes closed SAP documents, SAP payments and SAP journals of the company, and posts ONE opening
-- journal (trans_id 0) at migration_setting.opening_date:
--   non-control accounts at their SAP trial balance; open A/R and A/P documents and payments on account to the
--   partner's control account (short_name = partner); inventory accounts at the app stock value; the remainder to the
--   clearing account. A remainder means sub-ledgers and control accounts disagree in SAP: critical issue.
CREATE OR REPLACE FUNCTION erp.migration_opening_apply(p_company varchar, p_run uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s erp.migration_setting; r erp.migration_run; v_d date; v_clr text; v_ctrl text[]; v_inv text[] := '{}'; v_prev text;
  n_closed int; n_pay int; n_jrn int; n_open int; v_plug numeric; v_dr numeric; v_cr numeric; f text[] := '{}'; k text; x record; n_bad int := 0;
  v_noacct text;
BEGIN
  SELECT * INTO r FROM erp.migration_run WHERE run_id = p_run;
  IF NOT FOUND THEN RAISE EXCEPTION 'run % not found', p_run; END IF;
  SELECT * INTO s FROM erp.migration_setting WHERE company_code = p_company;
  v_d := s.opening_date; v_clr := s.opening_clearing_acct;
  IF v_d IS NULL OR v_clr IS NULL THEN
    RAISE EXCEPTION 'An opening-balances-only run needs the opening date and the clearing account of %. Enter them under Opening balances first.', p_company;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.account WHERE company_code = p_company AND acct_code = v_clr) THEN
    RAISE EXCEPTION 'Clearing account % is not in the chart of accounts of %.', v_clr, p_company;
  END IF;
  IF NOT erp._mig_has('JDT1', 'Account', 'ShortName', 'Debit', 'Credit', 'RefDate') OR NOT erp._mig_has('OCRD', 'CardCode', 'CardType') THEN
    RAISE EXCEPTION 'An opening-balances-only run needs JDT1 and OCRD in the SAP copy of %.', p_company;
  END IF;
  v_prev := current_setting('erp.sync', true);
  PERFORM set_config('erp.sync', 'on', true);

  -- control and inventory accounts, partner control account
  EXECUTE 'SELECT coalesce(array_agg(DISTINCT j."Account"), ''{}'') FROM sap."JDT1" j JOIN sap."OCRD" b ON b.company_code = j.company_code AND b."CardCode" = j."ShortName"
            WHERE j.company_code = $1 AND j."ShortName" <> j."Account"' INTO v_ctrl USING p_company;
  IF erp._mig_has('OWHS', 'WhsCode', 'BalInvntAc') THEN
    EXECUTE 'SELECT coalesce(array_agg(DISTINCT btrim("BalInvntAc")) FILTER (WHERE coalesce(btrim("BalInvntAc"), '''') <> ''''), ''{}'') FROM sap."OWHS" WHERE company_code = $1'
      INTO v_inv USING p_company;
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS _op_bp (c text PRIMARY KEY, acct text) ON COMMIT DROP;
  TRUNCATE _op_bp;
  EXECUTE format($q$INSERT INTO _op_bp SELECT b."CardCode", coalesce(%s,
            (SELECT j."Account" FROM sap."JDT1" j WHERE j.company_code = b.company_code AND j."ShortName" = b."CardCode" AND j."ShortName" <> j."Account"
              GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1)) FROM sap."OCRD" b WHERE b.company_code = $1$q$,
          CASE WHEN erp._mig_has('OCRD', 'DebPayAcct') THEN 'nullif(btrim(b."DebPayAcct"), '''')' ELSE 'NULL::text' END) USING p_company;

  -- prune history (SAP rows of this company only)
  DELETE FROM erp.document_line l USING erp.document d
   WHERE d.company_code = p_company AND d.source = 'sap' AND d.status <> 'open'
     AND l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry;
  DELETE FROM erp.document WHERE company_code = p_company AND source = 'sap' AND status <> 'open';
  GET DIAGNOSTICS n_closed = ROW_COUNT;
  DELETE FROM erp.payment WHERE company_code = p_company AND source = 'sap';
  GET DIAGNOSTICS n_pay = ROW_COUNT;
  DELETE FROM erp.journal_line l USING erp.journal_entry e WHERE e.company_code = p_company AND e.source = 'sap'
     AND l.company_code = e.company_code AND l.trans_id = e.trans_id;
  DELETE FROM erp.journal_entry WHERE company_code = p_company AND source = 'sap';
  GET DIAGNOSTICS n_jrn = ROW_COUNT;

  -- opening lines
  CREATE TEMP TABLE IF NOT EXISTS _op_line (acct text, short_name text, amt numeric, memo text) ON COMMIT DROP;
  TRUNCATE _op_line;
  EXECUTE 'INSERT INTO _op_line SELECT "Account", NULL, sum(coalesce("Debit", 0) - coalesce("Credit", 0)), ''balance at '' || $2::text
             FROM sap."JDT1" WHERE company_code = $1 AND "RefDate"::date <= $2 AND NOT ("Account" = ANY ($3))
            GROUP BY 1 HAVING round(sum(coalesce("Debit", 0) - coalesce("Credit", 0)), 2) <> 0'
    USING p_company, v_d, v_ctrl || v_inv;
  INSERT INTO _op_line
  SELECT bp.acct, d.card_code, CASE WHEN d.obj_type IN (13, 203, 14) THEN 1 ELSE -1 END * coalesce(d.sign, 1) * (coalesce(d.total, 0) - coalesce(d.paid, 0)),
         format('open %s %s', d.obj_type, coalesce(d.doc_num, d.doc_entry))
    FROM erp.document d LEFT JOIN _op_bp bp ON bp.c = d.card_code
   WHERE d.company_code = p_company AND d.source = 'sap' AND d.status = 'open' AND d.obj_type IN (13, 203, 14, 18, 204, 19)
     AND round(coalesce(d.total, 0) - coalesce(d.paid, 0), 2) <> 0;
  SELECT count(*) INTO n_open FROM erp.document WHERE company_code = p_company AND source = 'sap' AND status = 'open';
  IF erp._mig_has('ORCT', 'CardCode', 'OpenBal', 'Canceled') THEN
    EXECUTE 'INSERT INTO _op_line SELECT bp.acct, p."CardCode", -sum(p."OpenBal"), ''payments on account''
               FROM sap."ORCT" p LEFT JOIN _op_bp bp ON bp.c = p."CardCode"
              WHERE p.company_code = $1 AND coalesce(p."Canceled", ''N'') <> ''Y'' AND coalesce(p."OpenBal", 0) <> 0 GROUP BY 1, 2' USING p_company;
  END IF;
  IF erp._mig_has('OVPM', 'CardCode', 'OpenBal', 'Canceled') THEN
    EXECUTE 'INSERT INTO _op_line SELECT bp.acct, p."CardCode", sum(p."OpenBal"), ''payments on account''
               FROM sap."OVPM" p LEFT JOIN _op_bp bp ON bp.c = p."CardCode"
              WHERE p.company_code = $1 AND coalesce(p."Canceled", ''N'') <> ''Y'' AND coalesce(p."OpenBal", 0) <> 0 GROUP BY 1, 2' USING p_company;
  END IF;
  IF cardinality(v_inv) > 0 THEN
    EXECUTE 'INSERT INTO _op_line SELECT btrim(w."BalInvntAc"), NULL, sum(b.on_hand * coalesce(b.avg_cost, 0)), ''stock value''
               FROM erp.stock_balance b JOIN sap."OWHS" w ON w.company_code = b.company_code AND w."WhsCode" = b.whs_code
              WHERE b.company_code = $1 AND coalesce(btrim(w."BalInvntAc"), '''') <> '''' GROUP BY 1 HAVING round(sum(b.on_hand * coalesce(b.avg_cost, 0)), 2) <> 0'
      USING p_company;
  END IF;
  SELECT string_agg(DISTINCT short_name, ', ') INTO v_noacct FROM _op_line WHERE acct IS NULL;
  DELETE FROM _op_line WHERE acct IS NULL;
  SELECT -coalesce(sum(amt), 0) INTO v_plug FROM _op_line;
  IF v_plug <> 0 THEN INSERT INTO _op_line VALUES (v_clr, NULL, v_plug, 'opening balance clearing'); END IF;

  INSERT INTO erp.journal_entry (company_code, trans_id, number, ref_date, due_date, tax_date, memo, ref1, ref2, trans_type, total_local, source, created_on)
  SELECT p_company, 0, 0, v_d, v_d, v_d, format('Opening balance at %s (opening-balances-only run %s)', v_d, left(p_run::text, 8)), 'OPENING', p_run::text, 0,
         (SELECT coalesce(sum(greatest(amt, 0)), 0) FROM _op_line), 'sap', current_date;
  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, memo, ref_date, due_date)
  SELECT p_company, 0, (row_number() OVER (ORDER BY o.short_name IS NOT NULL, o.acct, o.short_name, o.memo)) - 1, o.acct, coalesce(o.short_name, o.acct),
         greatest(o.amt, 0), greatest(-o.amt, 0), o.memo, v_d, v_d
    FROM _op_line o WHERE o.amt <> 0;
  SELECT coalesce(sum(debit), 0), coalesce(sum(credit), 0) INTO v_dr, v_cr FROM erp.journal_line WHERE company_code = p_company AND trans_id = 0;

  -- opening checks (area 'opening')
  DELETE FROM erp.migration_check WHERE run_id = p_run AND company_code = p_company AND area = 'opening';
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening journal: debit = credit', 0, v_dr, v_cr, erp._mig_eq(v_dr, v_cr),
                         jsonb_build_object('opening_date', v_d, 'lines', (SELECT count(*) FROM _op_line)));
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening clearing account remainder', 0, 0, v_plug, erp._mig_eq(v_plug, 0),
                         jsonb_build_object('account', v_clr));
  IF NOT erp._mig_eq(v_plug, 0) THEN
    k := 'opening:clear:' || p_company; f := f || k;
    PERFORM erp.migration_add_issue(p_run, p_company, 'critical', 'opening', k,
            format('%s: the opening clearing account %s is not zero (%s)', p_company, v_clr, v_plug),
            'Open documents, payments on account and stock do not add up to the control and inventory account balances in SAP. See checks 5.3 and 5.5.');
  END IF;
  IF v_noacct IS NOT NULL THEN
    k := 'opening:noacct:' || p_company; f := f || k;
    PERFORM erp.migration_add_issue(p_run, p_company, 'critical', 'opening', k, format('%s: partners without a control account', p_company),
            'Their open items went to the clearing account: ' || left(v_noacct, 500), 'OCRD');
  END IF;
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening: open documents brought in', NULL, NULL, n_open, true, NULL);
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening: closed documents removed', NULL, NULL, n_closed, true, NULL);
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening: SAP payments removed', NULL, NULL, n_pay, true, NULL);
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening: SAP journals replaced by one opening journal', NULL, NULL, n_jrn, true, NULL);
  FOR x IN EXECUTE $q$
    WITH raw AS (SELECT "Account" a, sum(coalesce("Debit", 0) - coalesce("Credit", 0)) b FROM sap."JDT1" WHERE company_code = $1 AND "RefDate"::date <= $2 GROUP BY 1),
         app AS (SELECT l.acct_code a, sum(l.debit - l.credit) b FROM erp.journal_line l JOIN erp.journal_entry e USING (company_code, trans_id)
                  WHERE l.company_code = $1 AND e.source = 'sap' GROUP BY 1)
    SELECT coalesce(raw.a, app.a) a, coalesce(raw.b, 0) rb, coalesce(app.b, 0) ab FROM raw FULL JOIN app ON app.a = raw.a
     WHERE round(coalesce(raw.b, 0) - coalesce(app.b, 0), 2) <> 0 ORDER BY 1 $q$ USING p_company, v_d LOOP
    n_bad := n_bad + 1;
    PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening balance ' || x.a, NULL, x.rb, x.ab, false, jsonb_build_object('account', x.a, 'date', v_d));
    k := 'opening:tb:' || p_company || ':' || x.a; f := f || k;
    PERFORM erp.migration_add_issue(p_run, p_company, 'critical', 'opening', k, format('%s: opening balance of account %s differs from SAP at %s', p_company, x.a, v_d),
            format('SAP trial balance %s, opening journal %s', x.rb, x.ab), 'JDT1');
  END LOOP;
  PERFORM erp._mig_check(p_run, p_company, 'opening', 'opening balances at ' || v_d || ': accounts that differ', 0, NULL, n_bad, n_bad = 0, NULL);
  PERFORM erp._mig_sweep(p_run, p_company, ARRAY['opening'], f);
  PERFORM set_config('erp.sync', coalesce(v_prev, 'off'), true);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES ('migration_worker', p_company, 'migration_opening_apply', 'migration_run', p_run::text,
          jsonb_build_object('opening_date', v_d, 'clearing', v_clr, 'remainder', v_plug, 'open_documents', n_open, 'closed_removed', n_closed,
                             'payments_removed', n_pay, 'journals_replaced', n_jrn));
  RETURN jsonb_build_object('opening_date', v_d, 'debit', v_dr, 'credit', v_cr, 'remainder', v_plug, 'open_documents', n_open,
                            'closed_removed', n_closed, 'payments_removed', n_pay, 'journals_replaced', n_jrn, 'accounts_differing', n_bad);
END $$;

-- ============ 7a. Worker entry point for the cross-check ============
-- 13's cross-check, then (opening_only runs) the history comparisons are replaced by the opening checks, then A12's checks.
CREATE OR REPLACE FUNCTION erp.migration_cross_check_all(p_company varchar, p_run uuid)
RETURNS TABLE (companies integer, checks bigint, failed bigint, critical_open bigint, warning_open bigint, info_open bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE r erp.migration_run; co varchar;
BEGIN
  SELECT * INTO r FROM erp.migration_run m WHERE m.run_id = p_run;
  IF NOT FOUND THEN RAISE EXCEPTION 'run % not found', p_run; END IF;
  PERFORM erp.migration_cross_check(p_company, p_run);
  IF r.kind = 'opening_only' THEN
    co := r.company_code;
    DELETE FROM erp.migration_check c WHERE c.run_id = p_run AND c.company_code = co
       AND ((c.area = 'finance' AND (c.check_name LIKE 'trial balance%' OR c.check_name LIKE 'account group %'
                                     OR c.check_name IN ('customer balance (journal BP lines)', 'supplier balance (journal BP lines)')))
            OR (c.area = 'app_tables' AND c.check_name IN ('A/R invoices', 'A/R invoice total', 'journal lines', 'debits', 'credits')));
    UPDATE erp.migration_issue i SET status = 'fixed', resolved_at = now(), note = 'not used for an opening-balances-only run: see the opening checks'
     WHERE i.run_id = p_run AND i.company_code = co AND i.status = 'open'
       AND (i.issue_key LIKE 'tb:' || co || ':%' OR i.issue_key LIKE 'group:' || co || ':%' OR i.issue_key = 'group_other:' || co
            OR i.issue_key LIKE 'bpbal:' || co || ':%'
            OR i.issue_key IN ('sync:' || co || ':A/R invoices', 'sync:' || co || ':A/R invoice total', 'sync:' || co || ':journal lines',
                               'sync:' || co || ':debits', 'sync:' || co || ':credits'));
    PERFORM erp.migration_compare_report(p_run, co);
  END IF;
  RETURN QUERY SELECT * FROM erp.migration_more_checks(p_company, p_run);
END $$;

-- ============ 5. Special prices and period / volume discounts ============
CREATE TABLE IF NOT EXISTS erp.special_price (            -- OSPP: price per partner and item
    company_code  varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    card_code     varchar(15) NOT NULL,                     -- '*<list>' = period discount of a price list (SAP convention)
    item_code     varchar(50) NOT NULL,
    price         numeric,
    currency      varchar(3),
    discount_pct  numeric,
    list_num      integer,
    valid         boolean,
    valid_from    date,
    valid_to      date,
    auto_update   boolean,
    source        text NOT NULL DEFAULT 'sap',
    PRIMARY KEY (company_code, card_code, item_code)
);
CREATE TABLE IF NOT EXISTS erp.special_price_period (     -- SPP1: date ranges of a special price
    company_code  varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    card_code     varchar(15) NOT NULL,
    item_code     varchar(50) NOT NULL,
    line_num      integer NOT NULL,
    from_date     date,
    to_date       date,
    price         numeric,
    currency      varchar(3),
    discount_pct  numeric,
    list_num      integer,
    PRIMARY KEY (company_code, card_code, item_code, line_num)
);
CREATE TABLE IF NOT EXISTS erp.discount_group (           -- OEDG: period and volume discount groups
    company_code  varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    abs_entry     integer NOT NULL,
    kind          text,                                     -- OEDG.Type (A all partners, C customer group, S supplier group, V one partner)
    obj_type      text,
    obj_code      text,
    disc_rel      text,                                     -- how several discounts combine (SAP code)
    valid         boolean,
    valid_from    date,
    valid_to      date,
    PRIMARY KEY (company_code, abs_entry)
);
CREATE TABLE IF NOT EXISTS erp.discount_group_line (      -- EDG1
    company_code  varchar(8) NOT NULL,
    abs_entry     integer NOT NULL,
    line_num      integer NOT NULL,
    obj_type      integer,                                  -- 4 item, 52 item group, 43 manufacturer
    obj_key       text,
    disc_type     text,
    discount_pct  numeric,
    pay_for       numeric,
    for_free      numeric,
    up_to         numeric,
    PRIMARY KEY (company_code, abs_entry, line_num),
    FOREIGN KEY (company_code, abs_entry) REFERENCES erp.discount_group ON DELETE CASCADE
);
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['special_price', 'special_price_period', 'discount_group', 'discount_group_line'] LOOP
    EXECUTE format('ALTER TABLE erp.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON erp.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON erp.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON erp.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (erp.can_read(''sales'') OR erp.can_read(''inventory'') OR erp.can_read(''purchase'') OR erp.can_read(''bp'')))', t || '_read', t);
  END LOOP;
END $$;

CREATE OR REPLACE VIEW erp.special_price_list WITH (security_invoker = true) AS
SELECT s.company_code, s.card_code, b.name AS card_name, s.item_code, i.name AS item_name, s.price, s.currency, s.discount_pct, s.list_num,
       s.valid, s.valid_from, s.valid_to, s.auto_update, s.source,
       (SELECT count(*) FROM erp.special_price_period p WHERE p.company_code = s.company_code AND p.card_code = s.card_code AND p.item_code = s.item_code) AS periods
  FROM erp.special_price s
  LEFT JOIN erp.business_partner b ON b.company_code = s.company_code AND b.card_code = s.card_code
  LEFT JOIN erp.item i ON i.company_code = s.company_code AND i.item_code = s.item_code;
GRANT SELECT ON erp.special_price_list TO authenticated;

-- Sync steps (dynamic: a table missing from the SAP copy writes 0 rows)
CREATE OR REPLACE FUNCTION erp.sync_special_prices(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  IF NOT erp._mig_has('OSPP', 'CardCode', 'ItemCode', 'Price') THEN RETURN 0; END IF;
  EXECUTE format($q$
    INSERT INTO erp.special_price AS t (company_code, card_code, item_code, price, currency, discount_pct, list_num, valid, valid_from, valid_to, auto_update, source)
    SELECT s.company_code, s."CardCode", s."ItemCode", s."Price", %s, %s, %s, %s = 'Y', %s, %s, %s = 'Y', 'sap'
      FROM sap."OSPP" s WHERE s.company_code = $1 AND s."CardCode" IS NOT NULL AND s."ItemCode" IS NOT NULL
    ON CONFLICT (company_code, card_code, item_code) DO UPDATE SET price = EXCLUDED.price, currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct,
       list_num = EXCLUDED.list_num, valid = EXCLUDED.valid, valid_from = EXCLUDED.valid_from, valid_to = EXCLUDED.valid_to, auto_update = EXCLUDED.auto_update
     WHERE t.source = 'sap' AND (t.price, t.currency, t.discount_pct, t.list_num, t.valid, t.valid_from, t.valid_to, t.auto_update)
           IS DISTINCT FROM (EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.list_num, EXCLUDED.valid, EXCLUDED.valid_from, EXCLUDED.valid_to, EXCLUDED.auto_update)$q$,
    erp._mig_col('OSPP', 's', 'Currency', 'varchar(3)'), erp._mig_col('OSPP', 's', 'Discount', 'numeric'), erp._mig_col('OSPP', 's', 'ListNum', 'integer'),
    erp._mig_col('OSPP', 's', 'Valid', 'text'), erp._mig_col('OSPP', 's', 'ValidFrom', 'date'), erp._mig_col('OSPP', 's', 'ValidTo', 'date'),
    erp._mig_col('OSPP', 's', 'AutoUpdt', 'text')) USING p_company;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_special_price_periods(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  IF NOT erp._mig_has('SPP1', 'CardCode', 'ItemCode', 'LINENUM') THEN RETURN 0; END IF;
  EXECUTE format($q$
    INSERT INTO erp.special_price_period AS t (company_code, card_code, item_code, line_num, from_date, to_date, price, currency, discount_pct, list_num)
    SELECT s.company_code, s."CardCode", s."ItemCode", s."LINENUM", %s, %s, %s, %s, %s, %s
      FROM sap."SPP1" s WHERE s.company_code = $1 AND s."CardCode" IS NOT NULL AND s."ItemCode" IS NOT NULL
    ON CONFLICT (company_code, card_code, item_code, line_num) DO UPDATE SET from_date = EXCLUDED.from_date, to_date = EXCLUDED.to_date, price = EXCLUDED.price,
       currency = EXCLUDED.currency, discount_pct = EXCLUDED.discount_pct, list_num = EXCLUDED.list_num
     WHERE (t.from_date, t.to_date, t.price, t.currency, t.discount_pct, t.list_num)
           IS DISTINCT FROM (EXCLUDED.from_date, EXCLUDED.to_date, EXCLUDED.price, EXCLUDED.currency, EXCLUDED.discount_pct, EXCLUDED.list_num)$q$,
    erp._mig_col('SPP1', 's', 'FromDate', 'date'), erp._mig_col('SPP1', 's', 'ToDate', 'date'), erp._mig_col('SPP1', 's', 'Price', 'numeric'),
    erp._mig_col('SPP1', 's', 'Currency', 'varchar(3)'), erp._mig_col('SPP1', 's', 'Discount', 'numeric'), erp._mig_col('SPP1', 's', 'ListNum', 'integer'))
    USING p_company;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_discount_groups(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  IF NOT erp._mig_has('OEDG', 'AbsEntry') THEN RETURN 0; END IF;
  EXECUTE format($q$
    INSERT INTO erp.discount_group AS t (company_code, abs_entry, kind, obj_type, obj_code, disc_rel, valid, valid_from, valid_to)
    SELECT s.company_code, s."AbsEntry", %s, %s, %s, %s, %s = 'Y', %s, %s FROM sap."OEDG" s WHERE s.company_code = $1
    ON CONFLICT (company_code, abs_entry) DO UPDATE SET kind = EXCLUDED.kind, obj_type = EXCLUDED.obj_type, obj_code = EXCLUDED.obj_code,
       disc_rel = EXCLUDED.disc_rel, valid = EXCLUDED.valid, valid_from = EXCLUDED.valid_from, valid_to = EXCLUDED.valid_to
     WHERE (t.kind, t.obj_type, t.obj_code, t.disc_rel, t.valid, t.valid_from, t.valid_to)
           IS DISTINCT FROM (EXCLUDED.kind, EXCLUDED.obj_type, EXCLUDED.obj_code, EXCLUDED.disc_rel, EXCLUDED.valid, EXCLUDED.valid_from, EXCLUDED.valid_to)$q$,
    erp._mig_col('OEDG', 's', 'Type', 'text'), erp._mig_col('OEDG', 's', 'ObjType', 'text'), erp._mig_col('OEDG', 's', 'ObjCode', 'text'),
    erp._mig_col('OEDG', 's', 'DiscRel', 'text'), erp._mig_col('OEDG', 's', 'ValidFor', 'text'), erp._mig_col('OEDG', 's', 'ValidFrom', 'date'),
    erp._mig_col('OEDG', 's', 'ValidTo', 'date')) USING p_company;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

CREATE OR REPLACE FUNCTION erp.sync_discount_group_lines(p_company varchar) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE n bigint;
BEGIN
  IF NOT erp._mig_has('EDG1', 'AbsEntry', 'LineNum') THEN RETURN 0; END IF;
  EXECUTE format($q$
    INSERT INTO erp.discount_group_line AS t (company_code, abs_entry, line_num, obj_type, obj_key, disc_type, discount_pct, pay_for, for_free, up_to)
    SELECT s.company_code, s."AbsEntry", s."LineNum", %s, %s, %s, %s, %s, %s, %s
      FROM sap."EDG1" s WHERE s.company_code = $1
       AND EXISTS (SELECT 1 FROM erp.discount_group g WHERE g.company_code = s.company_code AND g.abs_entry = s."AbsEntry")
    ON CONFLICT (company_code, abs_entry, line_num) DO UPDATE SET obj_type = EXCLUDED.obj_type, obj_key = EXCLUDED.obj_key, disc_type = EXCLUDED.disc_type,
       discount_pct = EXCLUDED.discount_pct, pay_for = EXCLUDED.pay_for, for_free = EXCLUDED.for_free, up_to = EXCLUDED.up_to
     WHERE (t.obj_type, t.obj_key, t.disc_type, t.discount_pct, t.pay_for, t.for_free, t.up_to)
           IS DISTINCT FROM (EXCLUDED.obj_type, EXCLUDED.obj_key, EXCLUDED.disc_type, EXCLUDED.discount_pct, EXCLUDED.pay_for, EXCLUDED.for_free, EXCLUDED.up_to)$q$,
    erp._mig_col('EDG1', 's', 'ObjType', 'integer'), erp._mig_col('EDG1', 's', 'ObjKey', 'text'), erp._mig_col('EDG1', 's', 'DiscType', 'text'),
    erp._mig_col('EDG1', 's', 'Discount', 'numeric'), erp._mig_col('EDG1', 's', 'PayFor', 'numeric'), erp._mig_col('EDG1', 's', 'ForFree', 'numeric'),
    erp._mig_col('EDG1', 's', 'UpTo', 'numeric')) USING p_company;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

-- erp.sync_company (11) re-created with the four new steps after sync_item_prices; erp.migration_sync_company
-- reads its step list from this procedure, so the worker runs them too.
CREATE OR REPLACE PROCEDURE erp.sync_company(p_company varchar) LANGUAGE plpgsql AS $f$
DECLARE n bigint; t timestamptz;
BEGIN
  PERFORM set_config('erp.sync', 'on', false);
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema)
  SELECT c.company_code, c.legal_name, c.legal_name, c.country, c.currency, c.licence_type, c.sap_schema FROM sap._company c WHERE c.company_code = p_company
  ON CONFLICT (company_code) DO UPDATE SET legal_name = EXCLUDED.legal_name, country = EXCLUDED.country, currency = EXCLUDED.currency,
       licence_type = EXCLUDED.licence_type, sap_schema = EXCLUDED.sap_schema;
  COMMIT;
  t := clock_timestamp(); n := erp.sync_branches(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_branches', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_accounts(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_accounts', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_cost_centres(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_cost_centres', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_tax_codes(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_tax_codes', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_fx_rates(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_fx_rates', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_salespeople(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_salespeople', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_terms(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_terms', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_business_partners(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_business_partners', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_addresses(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_addresses', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_merchandisers(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_merchandisers', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_brands(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_brands', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_group_items(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_group_items', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_items(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_items', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_certificates(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_certificates', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_market_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_market_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_tags(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_tags', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_price_lists(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_price_lists', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_special_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_special_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_special_price_periods(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_special_price_periods', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_discount_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_discount_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_discount_group_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_discount_group_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_warehouses(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_warehouses', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_stock_balances(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_stock_balances', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_batches(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_batches', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_serials(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_serials', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_stock_movements(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_stock_movements', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_quotation(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_quotation', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_quotation_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_quotation_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_order(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_order', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_order_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_order_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_delivery(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_delivery', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_delivery_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_delivery_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_return(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_return', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_return_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_return_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_invoice(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_invoice', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_invoice_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_invoice_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_credit_note(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_credit_note', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_credit_note_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_credit_note_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_down_payment(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_down_payment', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_down_payment_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_down_payment_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_request(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_request', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_request_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_request_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_quotation(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_quotation', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_quotation_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_quotation_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_order(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_order', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_order_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_order_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_po(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_po', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_po_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_po_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_return(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_return', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_return_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_return_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_invoice(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_invoice', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_invoice_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_invoice_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_credit_note(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_credit_note', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_credit_note_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_credit_note_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_down_payment(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_down_payment', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_down_payment_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_down_payment_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_transfer_request(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_transfer_request', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_transfer_request_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_transfer_request_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_inventory_transfer(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_inventory_transfer', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_inventory_transfer_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_inventory_transfer_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_issue(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_issue', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_issue_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_issue_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_journals(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_journals', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_journal_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_journal_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payments_incoming(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payments_incoming', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_allocations_incoming(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_allocations_incoming', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payments_outgoing(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payments_outgoing', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_allocations_outgoing(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_allocations_outgoing', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_ic_account_map(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_ic_account_map', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_hr_org(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_hr_org', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employees(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employees', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employee_documents(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employee_documents', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_wage_types(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_wage_types', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employee_pay(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employee_pay', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_leave_types(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_leave_types', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payroll_results(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payroll_results', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_air_tickets(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_air_tickets', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_tpl_contracts(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_tpl_contracts', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_artwork(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_artwork', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_artwork_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_artwork_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_supplier_pi(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_supplier_pi', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_trademarks(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_trademarks', n, t); COMMIT;
  PERFORM set_config('erp.sync', 'off', false);
END $f$;

-- ============ 7b. Run report for the auditors (one JSON: run, steps, files, checks, issues, sign-offs, register, attachments) ============
CREATE OR REPLACE FUNCTION erp.migration_report(p_run uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE r erp.migration_run; v jsonb;
BEGIN
  SELECT * INTO r FROM erp.migration_run m WHERE m.run_id = p_run;
  IF NOT FOUND OR NOT (erp.migration_can_read(r.company_code)
                       OR (erp.can_see(r.company_code) AND erp.migration_can_sign(NULL) AND r.status IN ('needs_review', 'signed_off'))) THEN
    RAISE EXCEPTION 'run not found' USING ERRCODE = '42501';
  END IF;
  v := jsonb_build_object(
    'generated_at', now(),
    'generated_by', (SELECT display_name FROM erp.app_user WHERE user_id = erp.current_user_id()),
    'run', jsonb_build_object('run_id', r.run_id, 'company_code', r.company_code, 'kind', r.kind, 'status', r.status, 'created_at', r.created_at,
                              'started_at', r.started_at, 'finished_at', r.finished_at, 'notes', r.notes, 'worker', r.worker,
                              'created_by', (SELECT display_name FROM erp.app_user WHERE user_id = r.created_by)),
    'company', (SELECT jsonb_build_object('code', c.company_code, 'name', c.legal_name, 'currency', c.currency, 'sap_schema', c.sap_schema)
                  FROM sap._company c WHERE c.company_code = r.company_code),
    'steps', (SELECT coalesce(jsonb_agg(jsonb_build_object('step_no', s.step_no, 'code', s.code, 'status', s.status, 'rows', s.rows,
                                                           'started_at', s.started_at, 'finished_at', s.finished_at, 'message', s.message) ORDER BY s.step_no), '[]')
                FROM erp.migration_step s WHERE s.run_id = p_run),
    'files', (SELECT jsonb_build_object('total', count(*), 'data_files', count(*) FILTER (WHERE kind = 'data_csv'), 'bytes', coalesce(sum(bytes), 0),
                                        'skipped', count(*) FILTER (WHERE status = 'skipped'), 'errors', count(*) FILTER (WHERE status = 'error'))
                FROM erp.migration_file WHERE run_id = p_run),
    'checks', (SELECT coalesce(jsonb_agg(to_jsonb(x) - 'item' - 'severity' - 'status'), '[]') FROM erp.migration_review(p_run) x WHERE x.item = 'check'),
    'issues', (SELECT coalesce(jsonb_agg(to_jsonb(x) - 'item' - 'sap_value' - 'raw_value' - 'app_value' - 'difference' - 'report_value'
                                         - 'report_source' - 'report_ok' - 'report_required'), '[]') FROM erp.migration_review(p_run) x WHERE x.item = 'issue'),
    'signoffs', (SELECT coalesce(jsonb_agg(jsonb_build_object('role', o.role, 'decision', o.decision, 'signed_by', o.signed_by,
                                                              'signed_by_name', u.display_name, 'signed_at', o.signed_at, 'comment', o.comment) ORDER BY o.role), '[]')
                   FROM erp.migration_signoff o LEFT JOIN erp.app_user u ON u.user_id = o.signed_by WHERE o.run_id = p_run),
    'custom_fields', (SELECT jsonb_build_object('total', count(*), 'mapped', count(*) FILTER (WHERE decision = 'mapped'),
                                                'raw_only', count(*) FILTER (WHERE decision = 'raw_only'),
                                                'drop_pending', count(*) FILTER (WHERE decision = 'drop' AND drop_state = 'pending'),
                                                'drop_approved', count(*) FILTER (WHERE decision = 'drop' AND drop_state = 'approved'))
                        FROM erp.custom_field_register WHERE company_code = r.company_code),
    'attachments', (SELECT jsonb_build_object('total', count(*), 'copied', count(*) FILTER (WHERE status = 'copied'),
                                              'missing', count(*) FILTER (WHERE status = 'missing'), 'errors', count(*) FILTER (WHERE status = 'error'),
                                              'bytes', coalesce(sum(bytes) FILTER (WHERE status = 'copied'), 0))
                      FROM erp.migration_attachment WHERE run_id = p_run),
    'settings', (SELECT to_jsonb(s) - 'updated_by' FROM erp.migration_setting s WHERE s.company_code = r.company_code));
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, r.company_code, 'migration_report', 'migration_run', p_run::text,
          jsonb_build_object('checks', jsonb_array_length(v->'checks'), 'issues', jsonb_array_length(v->'issues')));
  RETURN v;
END $$;

-- ============ Who can call what ============
REVOKE ALL ON FUNCTION erp.migration_setting_save(varchar, jsonb), erp._mig_has(text, text[]), erp._mig_col(text, text, text, text),
  erp._mig_check(uuid, varchar, text, text, numeric, numeric, numeric, boolean, jsonb), erp._mig_skip(uuid, varchar, text, text, text),
  erp._mig_sweep(uuid, varchar, text[], text[]), erp._cf_is_owner(varchar), erp._cf_build(varchar), erp.custom_field_register_build(varchar),
  erp.custom_field_decide(varchar, jsonb, text, text, text), erp.custom_field_drop_decide(varchar, jsonb, boolean, text), erp.custom_field_setup(varchar),
  erp.migration_attachment_list(varchar), erp.migration_attachment_check(uuid, varchar), erp._sync_note(varchar, text, text, text),
  erp.migration_duplicates(varchar, uuid), erp._mc_inventory_gl(uuid, varchar), erp._mc_partners(uuid, varchar), erp._mc_open_orders(uuid, varchar),
  erp._mc_vat(uuid, varchar), erp._mc_intercompany(uuid, varchar), erp._mc_payroll(uuid, varchar), erp._mc_coexistence(uuid, varchar),
  erp._mc_custom_fields(uuid, varchar), erp.migration_more_checks(varchar, uuid), erp.migration_opening_apply(varchar, uuid),
  erp.migration_cross_check_all(varchar, uuid), erp.migration_report(uuid),
  erp.sync_special_prices(varchar), erp.sync_special_price_periods(varchar), erp.sync_discount_groups(varchar), erp.sync_discount_group_lines(varchar)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp.migration_setting_save(varchar, jsonb), erp.custom_field_register_build(varchar),
  erp.custom_field_decide(varchar, jsonb, text, text, text), erp.custom_field_drop_decide(varchar, jsonb, boolean, text), erp.custom_field_setup(varchar),
  erp.migration_report(uuid), erp._cf_is_owner(varchar) TO authenticated;
GRANT EXECUTE ON FUNCTION erp._mig_has(text, text[]), erp._mig_col(text, text, text, text),
  erp._mig_check(uuid, varchar, text, text, numeric, numeric, numeric, boolean, jsonb), erp._mig_skip(uuid, varchar, text, text, text),
  erp._mig_sweep(uuid, varchar, text[], text[]), erp._cf_build(varchar), erp.migration_attachment_list(varchar), erp.migration_attachment_check(uuid, varchar),
  erp.migration_duplicates(varchar, uuid), erp.migration_more_checks(varchar, uuid), erp.migration_opening_apply(varchar, uuid),
  erp.migration_cross_check_all(varchar, uuid), erp.sync_special_prices(varchar), erp.sync_special_price_periods(varchar),
  erp.sync_discount_groups(varchar), erp.sync_discount_group_lines(varchar) TO service_role;
GRANT EXECUTE ON FUNCTION erp.migration_request(varchar, text, text) TO authenticated;
