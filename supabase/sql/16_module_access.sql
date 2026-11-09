-- A1 · Module-level access (Full / Read / None). Safe to run twice. Does not edit 12_erp_security.sql.
--
-- Before this file, the read policies limited rows by company on every table but by module only on HR tables,
-- so a sales-only user was blocked in the UI yet could read journals and payments through the API.
-- This file adds:
--   * erp.position_module  – per position and module: 'read' or 'full'. No row (and not in module_access) = none.
--   * erp.module_level / can_read / can_write – helpers for policies, functions and the UI.
--   * RESTRICTIVE SELECT policies, AND-ed with the existing permissive company policies from 12.
--
-- Backward compatible: a module listed in erp.position.module_access with no position_module row counts as 'full'.
-- erp.set_position_module keeps module_access in step: 'full' adds the module, 'read' and none remove it,
-- so older checks built on erp.has_module (HR rows, migration console) never treat read-only as write access.

-- ============ Table ============
CREATE TABLE IF NOT EXISTS erp.position_module (
    position_code  text NOT NULL REFERENCES erp.position ON DELETE CASCADE,
    module         text NOT NULL CHECK (module IN ('admin', 'it', 'finance', 'sales', 'purchase', 'bp', 'banking', 'inventory',
                                                   'production', 'service', 'hr', 'reports', 'business')),
    level          text NOT NULL CHECK (level IN ('read', 'full')),
    PRIMARY KEY (position_code, module)
);
ALTER TABLE erp.position_module ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.position_module FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.position_module TO authenticated;
DROP POLICY IF EXISTS position_module_read ON erp.position_module;
CREATE POLICY position_module_read ON erp.position_module FOR SELECT TO authenticated USING (true);

-- ============ Helpers ============
-- 'full' / 'read' / NULL for the signed-in user. An explicit row wins; otherwise module_access means 'full'.
CREATE OR REPLACE FUNCTION erp.module_level(p_module text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(pm.level, CASE WHEN p_module = ANY (p.module_access) THEN 'full' END)
    FROM erp.app_user u
    JOIN erp.position p ON p.position_code = u.position_code
    LEFT JOIN erp.position_module pm ON pm.position_code = p.position_code AND pm.module = p_module
   WHERE u.user_id = erp.current_user_id() AND u.active
$$;

-- Read or full on the module, or the user is owner ('business') or system admin ('admin').
CREATE OR REPLACE FUNCTION erp.can_read(p_module text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
      FROM erp.app_user u
      JOIN erp.position p ON p.position_code = u.position_code
     CROSS JOIN LATERAL (SELECT m FROM unnest(p.module_access) AS m
                         UNION ALL
                         SELECT pm.module FROM erp.position_module pm WHERE pm.position_code = p.position_code) x
     WHERE u.user_id = erp.current_user_id() AND u.active
       AND x.m IN (p_module, 'business', 'admin'))
$$;

-- Full on the module only. Admin and owner do not get write automatically (e.g. in finance).
CREATE OR REPLACE FUNCTION erp.can_write(p_module text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(erp.module_level(p_module) = 'full', false)
$$;

REVOKE ALL ON FUNCTION erp.module_level(text), erp.can_read(text), erp.can_write(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.module_level(text), erp.can_read(text), erp.can_write(text) TO authenticated;

-- ============ Admin write function (A10 builds the Authorizations screen on top of it) ============
-- p_level: 'full', 'read', or NULL for none.
CREATE OR REPLACE FUNCTION erp.set_position_module(p_position text, p_module text, p_level text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_old text;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF NOT erp.can_write('admin') THEN
    RAISE EXCEPTION 'Only a system admin with full Administration access can change module access.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = p_position) THEN
    RAISE EXCEPTION 'Position % does not exist. Check the position code.', p_position USING ERRCODE = 'P0001';
  END IF;
  IF p_module IS NULL OR p_module NOT IN ('admin', 'it', 'finance', 'sales', 'purchase', 'bp', 'banking', 'inventory',
                                          'production', 'service', 'hr', 'reports', 'business') THEN
    RAISE EXCEPTION 'Module % is not a known module.', coalesce(p_module, '(empty)') USING ERRCODE = 'P0001',
      HINT = 'Use one of: admin, it, finance, sales, purchase, bp, banking, inventory, production, service, hr, reports, business.';
  END IF;
  IF p_level IS NOT NULL AND p_level NOT IN ('read', 'full') THEN
    RAISE EXCEPTION 'Access level must be Full, Read or None.' USING ERRCODE = 'P0001';
  END IF;

  SELECT coalesce(pm.level, CASE WHEN p_module = ANY (p.module_access) THEN 'full' END) INTO v_old
    FROM erp.position p
    LEFT JOIN erp.position_module pm ON pm.position_code = p.position_code AND pm.module = p_module
   WHERE p.position_code = p_position;

  IF p_level IS NULL THEN
    DELETE FROM erp.position_module WHERE position_code = p_position AND module = p_module;
  ELSE
    INSERT INTO erp.position_module (position_code, module, level) VALUES (p_position, p_module, p_level)
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;

  -- Keep the older module list in step, so has_module() means 'full'.
  UPDATE erp.position
     SET module_access = CASE WHEN p_level = 'full'
                              THEN (SELECT array_agg(DISTINCT m ORDER BY m) FROM unnest(module_access || p_module) AS m)
                              ELSE array_remove(module_access, p_module) END
   WHERE position_code = p_position;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, NULL, 'set_position_module', 'position', p_position,
          jsonb_build_object('module', p_module, 'from', coalesce(v_old, 'none'), 'to', coalesce(p_level, 'none')));
END $$;
REVOKE ALL ON FUNCTION erp.set_position_module(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.set_position_module(text, text, text) TO authenticated;

-- ============ RESTRICTIVE read policies ============
-- Each helper is wrapped in (SELECT …) so Postgres runs it once per query (an InitPlan), not once per row.
DO $$
DECLARE
  t text;
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      -- Financials
      ('account',            '(SELECT erp.can_read(''finance''))'),
      ('journal_entry',      '(SELECT erp.can_read(''finance''))'),
      ('journal_line',       '(SELECT erp.can_read(''finance''))'),
      ('cost_centre',        '(SELECT erp.can_read(''finance''))'),
      ('fx_rate',            '(SELECT erp.can_read(''finance''))'),
      ('tax_code',           '(SELECT erp.can_read(''finance''))'),
      -- Banking
      ('payment',            '(SELECT erp.can_read(''banking'')) OR (SELECT erp.can_read(''finance''))'),
      ('payment_allocation', '(SELECT erp.can_read(''banking'')) OR (SELECT erp.can_read(''finance''))'),
      -- Business partners
      ('business_partner',   '(SELECT erp.can_read(''bp'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase'')) OR (SELECT erp.can_read(''finance''))'),
      ('bp_address',         '(SELECT erp.can_read(''bp'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase'')) OR (SELECT erp.can_read(''finance''))'),
      ('bp_group',           '(SELECT erp.can_read(''bp'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase'')) OR (SELECT erp.can_read(''finance''))'),
      -- Items and stock
      ('item',               '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('item_group',         '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('item_price',         '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('price_list',         '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('stock_balance',      '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('warehouse',          '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('batch',              '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      ('stock_movement',     '(SELECT erp.can_read(''inventory'')) OR (SELECT erp.can_read(''sales'')) OR (SELECT erp.can_read(''purchase''))'),
      -- Marketing documents, by kind (obj_type map = src/features/erp/modules.ts › DOC_KINDS).
      -- Sales kinds: sales or finance. Purchase kinds: purchase or finance. Inventory kinds: inventory.
      -- Any other obj_type: finance only (owner and admin pass through can_read).
      ('document', $p$
        (obj_type IN (23, 17, 15, 16, 203, 13, 14) AND ((SELECT erp.can_read('sales')) OR (SELECT erp.can_read('finance'))))
     OR (obj_type IN (1470000113, 540000006, 22, 20, 21, 204, 18, 19) AND ((SELECT erp.can_read('purchase')) OR (SELECT erp.can_read('finance'))))
     OR (obj_type IN (1250000001, 67, 59, 60) AND (SELECT erp.can_read('inventory')))
     OR (obj_type NOT IN (23, 17, 15, 16, 203, 13, 14, 1470000113, 540000006, 22, 20, 21, 204, 18, 19, 1250000001, 67, 59, 60)
         AND (SELECT erp.can_read('finance')))$p$),
      ('document_line', $p$
        (obj_type IN (23, 17, 15, 16, 203, 13, 14) AND ((SELECT erp.can_read('sales')) OR (SELECT erp.can_read('finance'))))
     OR (obj_type IN (1470000113, 540000006, 22, 20, 21, 204, 18, 19) AND ((SELECT erp.can_read('purchase')) OR (SELECT erp.can_read('finance'))))
     OR (obj_type IN (1250000001, 67, 59, 60) AND (SELECT erp.can_read('inventory')))
     OR (obj_type NOT IN (23, 17, 15, 16, 203, 13, 14, 1470000113, 540000006, 22, 20, 21, 204, 18, 19, 1250000001, 67, 59, 60)
         AND (SELECT erp.can_read('finance')))$p$)
    ) AS v(tbl, expr)
  LOOP
    t := r.tbl;
    EXECUTE format('DROP POLICY IF EXISTS %I ON erp.%I', 'a1_' || t || '_module', t);
    EXECUTE format('CREATE POLICY %I ON erp.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (%s)', 'a1_' || t || '_module', t, r.expr);
  END LOOP;
END $$;

