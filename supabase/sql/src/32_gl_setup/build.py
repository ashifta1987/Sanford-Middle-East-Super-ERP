#!/usr/bin/env python3
"""Assemble supabase/sql/32_gl_setup.sql from the hand-written parts and patched copies of earlier functions."""
import re, sys, pathlib

ART = pathlib.Path(__file__).resolve().parent          # supabase/sql/src/32_gl_setup
SQL = ART.parent.parent                                 # supabase/sql
# --check: build into memory and compare with the committed file instead of writing it.
CHECK = '--check' in sys.argv[1:]


def extract(fname, signature_start, nth=1):
    """Return the text of `CREATE OR REPLACE FUNCTION <signature_start>` … `$$;` (nth occurrence) from an earlier file."""
    lines = (SQL / fname).read_text().splitlines()
    hits = [i for i, l in enumerate(lines) if l.startswith('CREATE OR REPLACE FUNCTION ' + signature_start)]
    if len(hits) < nth:
        sys.exit(f'not found: {signature_start} in {fname}')
    i = hits[nth - 1]
    j = i
    while not (lines[j].rstrip() in ('END $$;', '$$;')):
        j += 1
    return '\n'.join(lines[i:j + 1]), i + 1


def patch(text, old, new, count=1, label=''):
    n = text.count(old)
    if n != count:
        sys.exit(f'patch {label!r}: expected {count} occurrence(s), found {n}:\n{old[:200]}')
    return text.replace(old, new)


out = []
out.append((ART / 'part1.sql').read_text())

# ---------------------------------------------------------------- post_document (22)
t, ln = extract('22_inventory.sql', 'erp.post_document(')
t = patch(t, "erp._inv_whs_acct(p_company, l.whs_code)", "erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code)", count=7, label='whs acct')
t = patch(t, "erp._inv_whs_acct(p_company, l.from_whs)", "erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs)", count=3, label='from acct')
t = patch(t, """    IF NOT EXISTS (SELECT 1 FROM erp.document_line l
                     LEFT JOIN erp.warehouse_setting fs ON fs.company_code = l.company_code AND fs.whs_code = l.from_whs
                     LEFT JOIN erp.warehouse_setting ts ON ts.company_code = l.company_code AND ts.whs_code = l.whs_code
                    WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry AND fs.stock_acct IS DISTINCT FROM ts.stock_acct) THEN
      RETURN NULL;
    END IF;
""", "", label='67 shortcut')
# 15: COGS per line (item group / warehouse)
t = patch(t, """    v_cogs := erp.gl_account(p_company, 'inventory', 'cogs');
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_cogs, 'debit', v_cost));
    v_lines := v_lines || (SELECT""", """    v_lines := (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'cogs', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
             WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
    v_lines := v_lines || (SELECT""", label='15 cogs')
# 13 / 14: revenue / returns per line
t = patch(t, """    SELECT jsonb_agg(jsonb_build_object('acct_code', v_rev, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(s.net, 2)))
      FROM (SELECT sum(line_total) AS net FROM erp.document_line
             WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry HAVING sum(line_total) <> 0) s), '[]'::jsonb);""",
"""    SELECT jsonb_agg(jsonb_build_object('acct_code', s.acct, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(s.net, 2)) ORDER BY s.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'sales', CASE p_obj_type WHEN 13 THEN 'revenue' ELSE 'sales_returns' END, l.item_code, l.whs_code) AS acct,
                   sum(l.line_total) AS net FROM erp.document_line l
             WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry GROUP BY 1 HAVING sum(l.line_total) <> 0) s), '[]'::jsonb);""", label='revenue')
t = patch(t, """      v_cogs := erp.gl_account(p_company, 'inventory', 'cogs');
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_cogs, 'credit', v_cost));""",
"""      v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'cogs', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
               WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);""", label='14 cogs')
out.append(f"""
-- ============ 11. Posting with item group / warehouse accounts ============
-- ---- post_document: copied from 22_inventory.sql:{ln}. B3: stock accounts per line (item group, warehouse), COGS per line
-- (15 / 14 with returned stock), revenue / returns per line (13 / 14); transfers (67) post only lines whose accounts differ.
-- With no item group or warehouse accounts set, every journal is exactly as before.
""" + t)

# ---------------------------------------------------------------- _count_post (22)
t, ln = extract('22_inventory.sql', 'erp._count_post(')
t = patch(t, """  IF v_gain > 0 OR v_loss > 0 THEN
    v_stock := erp._inv_whs_acct(p_company, c.whs_code);
    v_vacct := erp.gl_account(p_company, 'inventory', 'count_variance');
    IF v_gain > 0 THEN
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_stock, 'debit', v_gain, 'memo', 'Count gains'),
                                              jsonb_build_object('acct_code', v_vacct, 'credit', v_gain, 'memo', 'Count gains'));
    END IF;
    IF v_loss > 0 THEN
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_vacct, 'debit', v_loss, 'memo', 'Count losses'),
                                              jsonb_build_object('acct_code', v_stock, 'credit', v_loss, 'memo', 'Count losses'));
    END IF;""", """  IF v_gain > 0 OR v_loss > 0 THEN
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
    END IF;""", label='count post')
out.append(f"""
-- ---- _count_post: copied from 22_inventory.sql:{ln}. B3: stock and count variance accounts per line (item group, warehouse).
""" + t)

# ---------------------------------------------------------------- _inv_eval (31)
t, ln = extract('31_approvals.sql', 'erp._inv_eval(')
t = patch(t, "      v_acct := coalesce(v_acct, rs.acct_code);",
          "      -- B3: a reason without an account uses its G/L determination key (warehouse → company default).\n"
          "      v_acct := coalesce(v_acct, rs.acct_code, CASE WHEN rs.gl_key IS NOT NULL THEN erp.gl_account(p_company, rs.gl_area, rs.gl_key, false, NULL::integer, v_whs) END);",
          label='reason acct')
t = patch(t, "format('Reason %s has no account. Choose the account, or ask Finance to set one in Inventory Setup.', rs.name)",
          "CASE WHEN rs.gl_key IS NOT NULL THEN format('Reason %s has no account, and G/L account for ''%s'' is not set for %s. Choose the account, or ask Finance to set it in Setup › Financials › G/L Account Determination.', rs.name, (SELECT label FROM erp.gl_posting_key WHERE area = rs.gl_area AND posting_key = rs.gl_key), p_company)\n"
          "             ELSE format('Reason %s has no account. Choose the account, or ask Finance to set one in Inventory Setup.', rs.name) END",
          label='reason msg')
out.append(f"""
-- ---- _inv_eval: copied from 31_approvals.sql:{ln}. B3: a reason with no account uses its G/L determination key.
""" + t)

# ---------------------------------------------------------------- _lc_eval (21)
t, ln = extract('21_purchasing.sql', 'erp._lc_eval(')
old_case = """CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric ELSE (ln->>'weight')::numeric END"""
new_case = """CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END"""
t = patch(t, old_case, new_case, count=2, label='lc case')
t = patch(t, "v_charges := v_charges || jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt);",
          "v_charges := v_charges || jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt,\n"
          "                                                 'acct_code', coalesce(lc.acct_code, erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false)));",
          label='lc charges')
out.append(f"""
-- ---- _lc_eval: copied from 21_purchasing.sql:{ln}. B3: split method 'equal' (the same share for every line); each charge
-- carries the account it is credited to (its type's account, else landed cost clearing).
""" + t)

# ---------------------------------------------------------------- landed_cost_create (30)
t, ln = extract('30_numbering_company.sql', 'erp.landed_cost_create(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb')
t = patch(t, """  v_inv := erp.gl_account(p_company, 'inventory', 'inventory');
  v_clr := erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing');
  IF v_tc > 0 THEN
    v_cogs := erp.gl_account(p_company, 'inventory', 'price_difference');
  END IF;
""", """  -- B3: every account is checked before anything is written, in the same order as before: stock (per line), landed cost
  -- clearing (only when a type has no account of its own), price difference (per line with goods already sold).
  PERFORM erp._gl_item_acct(p_company, 'inventory', 'inventory', y->>'item_code', y->>'whs_code') FROM jsonb_array_elements(e->'lines') y;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'charges') ch WHERE ch->>'acct_code' IS NULL) THEN
    v_clr := erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing');
  END IF;
  IF v_tc > 0 THEN
    PERFORM erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code')
       FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0;
  END IF;
""", label='lc accounts')
t = patch(t, """  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric);""",
"""  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount, acct_code)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount, y.acct_code
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric, acct_code text);""", label='lc charge insert')
t = patch(t, """  IF v_ti > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_inv, 'debit', v_ti, 'memo', 'Landed costs on stock');
  END IF;
  IF v_tc > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_cogs, 'debit', v_tc, 'memo', 'Landed costs on goods already sold (price difference)');
  END IF;
  v_lines := v_lines || jsonb_build_object('acct_code', v_clr, 'credit', v_tot);""",
"""  -- Stock share and sold share per line (the item's group, the receipt's warehouse); credit per landed cost type account.
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
            FROM jsonb_array_elements(e->'charges') ch GROUP BY 1) a);""", label='lc posting')
out.append(f"""
-- ---- landed_cost_create: copied from 30_numbering_company.sql:{ln}. B3: inventory and price difference per line (item group,
-- warehouse); the credit goes to each landed cost type's account (empty = landed cost clearing).
""" + t)

# ---------------------------------------------------------------- prod_order_receipt (28)
t, ln = extract('28_production_service.sql', 'erp.prod_order_receipt(')
t = patch(t, """  FOR r IN SELECT l.line_num, l.comp_code, l.base_qty, pr.unit, pr.unit_cost, pr.acct_code, pr.name""",
          """  FOR r IN SELECT l.line_num, l.comp_code, l.base_qty, pr.unit, pr.unit_cost,
                  coalesce(pr.acct_code, erp.gl_account(p_company, 'resources', 'resource_cost', false)) AS acct_code, pr.name""", label='res acct')
t = patch(t, "'Resource % has a cost but no account. Ask Finance to set it under Moulds and resources.'",
          "'Resource % has a cost but no account, and the resource absorption account is not set. Ask Finance to set it in G/L Account Determination (Production).'",
          label='res msg')
out.append(f"""
-- ---- prod_order_receipt: copied from 28_production_service.sql:{ln}. B3: a resource without its own account is credited to
-- the resource absorption key (G/L Account Determination › Production).
""" + t)

# ---------------------------------------------------------------- prod_resource_save (30)
t, ln = extract('30_numbering_company.sql', 'erp.prod_resource_save(')
t = patch(t, "  IF v_cost > 0 AND v_acct IS NULL THEN",
          "  IF v_cost > 0 AND v_acct IS NULL AND erp.gl_account(p_company, 'resources', 'resource_cost', false) IS NULL THEN", label='res save')
out.append(f"""
-- ---- prod_resource_save: copied from 30_numbering_company.sql:{ln}. B3: a resource with a cost may leave its account empty
-- when the resource absorption key is set (its cost is credited there).
""" + t)

out.append((ART / 'part2.sql').read_text())

# ---------------------------------------------------------------- _series_take (30)
t, ln = extract('30_numbering_company.sql', 'erp._series_take(')
t = patch(t, """  IF ns.series_id IS NULL THEN
    SELECT series_id INTO v_id FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active;""",
"""  -- B3: the warehouse's default series for this document type (Inventory › Setup › Warehouses › Numbering).
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
    SELECT series_id INTO v_id FROM erp.number_series WHERE company_code = p_company AND obj_type = p_obj AND active;""", label='series')
out.append(f"""
-- ============ 12. Numbering: warehouse default series ============
-- ---- _series_take: copied from 30_numbering_company.sql:{ln}. B3: after the user's default comes the warehouse's default
-- series (when the document names a warehouse), then the company default.
""" + t)

# ---------------------------------------------------------------- _health_files (31)
t, ln = extract('31_approvals.sql', 'erp._health_files(')
t = patch(t, "('31_approvals.sql', 'approval_template_save')", "('31_approvals.sql', 'approval_template_save'),\n    ('32_gl_setup.sql', 'gl_setup')", label='health')
out.append(f"""
-- ---- _health_files: copied from 31_approvals.sql:{ln} + 32_gl_setup.sql (marker gl_setup).
""" + t)

out.append((ART / 'part3.sql').read_text())

target = SQL / '32_gl_setup.sql'
text = '\n'.join(out).rstrip() + '\n'
if CHECK:
    same = target.read_text() == text
    print('identical' if same else 'DIFFERENT', target)
    sys.exit(0 if same else 1)
target.write_text(text)
print('wrote', target, sum(1 for _ in target.open()))
