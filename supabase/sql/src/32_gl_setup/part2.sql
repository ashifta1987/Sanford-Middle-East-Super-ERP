
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
