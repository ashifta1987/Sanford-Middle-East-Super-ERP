#!/usr/bin/env python3
"""Assemble supabase/sql/34_open_items.sql from the hand-written parts and patched copies of earlier functions.

Each patch must match an exact number of times or the build stops, so a changed source is noticed at once.
  python3 supabase/sql/src/34_open_items/build.py           # writes supabase/sql/34_open_items.sql
  python3 supabase/sql/src/34_open_items/build.py --check   # exit 0 when the committed file is identical
"""
import sys, pathlib

ART = pathlib.Path(__file__).resolve().parent          # supabase/sql/src/34_open_items
SQL = ART.parent.parent                                 # supabase/sql
CHECK = '--check' in sys.argv[1:]


def extract(fname, signature_start, nth=-1):
    """Text of `CREATE OR REPLACE FUNCTION <signature_start>` … `END $$;` / `$$;` in an earlier file (default: the last one)."""
    lines = (SQL / fname).read_text().splitlines()
    hits = [i for i, l in enumerate(lines) if l.startswith('CREATE OR REPLACE FUNCTION ' + signature_start)]
    if not hits:
        sys.exit(f'not found: {signature_start} in {fname}')
    i = hits[nth]
    j = i
    while lines[j].rstrip() not in ('END $$;', '$$;'):
        j += 1
    return '\n'.join(lines[i:j + 1]), i + 1


def patch(text, old, new, count=1, label=''):
    n = text.count(old)
    if n != count:
        sys.exit(f'patch {label!r}: expected {count} occurrence(s), found {n}:\n{old[:300]}')
    return text.replace(old, new)


out = [(ART / 'part1.sql').read_text()]


def add(title, fname, ln, text):
    out.append(f"\n-- ---- {title}: copied from {fname}:{ln}.\n" + text)


# ================================================================ 2. Approval engine: substitutes
out.append("""
-- ============ 2. Approval engine: a substitute decides in the authorizer's place ============""")

t, ln = extract('31_approvals.sql', 'erp._apr_is_mine(')
t = patch(t, """                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) END
           AND NOT EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND v.user_id = u.user_id)""",
          """                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) OR erp._apr_sub_principal(a.approval_id, u.user_id) IS NOT NULL END
           AND NOT EXISTS (SELECT 1 FROM erp.approval_vote v WHERE v.approval_id = a.approval_id AND (v.user_id = u.user_id OR v.on_behalf_of = u.user_id))""",
          label='is_mine')
add('_apr_is_mine', '31_approvals.sql', ln, t + """
-- B5: an active substitute of a stage authorizer may decide too; a person whose substitute already voted on the row can't
-- vote again (and the other way round).""")

t, ln = extract('31_approvals.sql', 'erp._apr_can_act(')
t = patch(t, """                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) END""",
          """                ELSE erp._apr_authorizer(a.stage_id, u.user_id, u.position_code) OR erp._apr_sub_of_stage(a.stage_id, u.user_id) END""", label='can_act')
add('_apr_can_act', '31_approvals.sql', ln, t + "\n-- B5: + active substitutes of the stage's authorizers.")

t, ln = extract('31_approvals.sql', 'erp._apr_votes(')
t = patch(t, """jsonb_build_object('user_name', u.display_name, 'decision', v.decision, 'note', v.note, 'at', v.voted_at)""",
          """jsonb_build_object('user_name', u.display_name, 'decision', v.decision, 'note', v.note, 'at', v.voted_at,
                                       'on_behalf_of_name', (SELECT ob.display_name FROM erp.app_user ob WHERE ob.user_id = v.on_behalf_of))""", label='votes')
add('_apr_votes', '31_approvals.sql', ln, t + "\n-- B5: + on_behalf_of_name (a substitute's vote).")

t, ln = extract('31_approvals.sql', 'erp._apr_trail(')
t = patch(t, """           'decided_by_name', du.display_name, 'note', a.note,""",
          """           'decided_by_name', du.display_name, 'note', a.note,
           'decided_on_behalf_of_name', (SELECT ob.display_name FROM erp.app_user ob WHERE ob.user_id = a.on_behalf_of),""", label='trail')
add('_apr_trail', '31_approvals.sql', ln, t + "\n-- B5: + decided_on_behalf_of_name.")

t, ln = extract('31_approvals.sql', 'erp.approval_inbox(')
t = patch(t, """                     OR EXISTS (SELECT 1 FROM erp.admin_setting s WHERE s.owner_position = u.position_code AND erp.can_see(s.company_code)),""",
          """                     OR EXISTS (SELECT 1 FROM erp.admin_setting s WHERE s.owner_position = u.position_code AND erp.can_see(s.company_code))
                     OR EXISTS (SELECT 1 FROM erp.apr_substitute ss WHERE ss.substitute_id = u.user_id AND ss.active
                                   AND current_date BETWEEN ss.from_date AND ss.to_date AND erp.can_see(ss.company_code)),""", label='inbox approver')
t = patch(t, """      'waiting', coalesce((SELECT jsonb_agg(j ORDER BY requested_at) FROM r""",
          """      'waiting', coalesce((SELECT jsonb_agg(j || jsonb_build_object('on_behalf_of_name',
                                    CASE WHEN stage_id IS NOT NULL AND NOT erp._apr_authorizer(stage_id, u.user_id, u.position_code)
                                         THEN (SELECT ob.display_name FROM erp.app_user ob WHERE ob.user_id = erp._apr_sub_principal(approval_id, u.user_id)) END)
                                  ORDER BY requested_at) FROM r""", label='inbox waiting')
add('approval_inbox', '31_approvals.sql', ln, t + """
-- B5: substitutes count as approvers while their substitution is active; waiting rows they decide for someone else name that
-- person (on_behalf_of_name).""")

# ================================================================ 3. Credit memos across rates
out.append("""
-- ============ 3. Credit memos copying invoices with other rates ============
-- SAP Business One: a credit memo copied from an A/R invoice reverses it at the invoice's rate, so the reversal is exact in
-- LC. B4 refused a typed rate and invoices with different rates on one credit memo; now each copied line keeps the rate of
-- its own invoice (trigger cur_line_fc), a typed rate is not used for copied lines, and the header shows the invoice's rate
-- (several invoices with different rates: the average of the copied lines, LC total / FC total).""")

t, ln = extract('33_multicurrency.sql', 'erp._cur_ctx_base(')
t = patch(t, """  IF p_obj IN (15, 14, 20) THEN
    -- Keeps the rate of the document it is copied from.""",
          """  IF p_obj = 14 THEN
    -- B5: each copied line keeps its own invoice's rate (cur_line_fc); the header starts with the first one.
    v_rate := v_rates[1];
  ELSIF p_obj IN (15, 20) THEN
    -- Keeps the rate of the document it is copied from.""", label='ctx 14')
add('_cur_ctx_base', '33_multicurrency.sql', ln, t + "\n-- B5: credit memos accept invoices with different rates and ignore a typed rate (lines keep their invoice's rate).")

t, ln = extract('33_multicurrency.sql', 'erp._cur_line_fc(')
t = patch(t, """DECLARE
  d record;
BEGIN""", """DECLARE
  d      record;
  v_rate numeric;
  v_base numeric;
BEGIN""", label='linefc decl')
t = patch(t, """    NEW.currency := d.currency;""", """    v_rate := d.fx_rate;
    -- B5: a credit memo line copied from an A/R invoice keeps that invoice's rate (exact reversal in LC).
    IF NEW.obj_type = 14 AND NEW.base_obj_type = 13 AND NEW.base_doc_entry IS NOT NULL THEN
      SELECT b.fx_rate INTO v_base FROM erp.document b
       WHERE b.company_code = NEW.company_code AND b.obj_type = 13 AND b.doc_entry = NEW.base_doc_entry AND b.currency = d.currency;
      v_rate := coalesce(nullif(v_base, 0), v_rate);
    END IF;
    NEW.currency := d.currency;""", label='linefc base')
t = patch(t, "round(NEW.line_total_fc * d.fx_rate, 2)", "round(NEW.line_total_fc * v_rate, 2)", label='linefc lt')
t = patch(t, "round(NEW.vat_fc * d.fx_rate, 2)", "round(NEW.vat_fc * v_rate, 2)", label='linefc vat')
add('_cur_line_fc', '33_multicurrency.sql', ln, t + "\n-- B5: credit memo lines copied from an invoice use the invoice's rate.")

t, ln = extract('33_multicurrency.sql', 'erp._sd_cm_exec(')
t = patch(t, """  v_total := erp._sd_retotal(p_company, 14, v_entry);
""", """  v_total := erp._sd_retotal(p_company, 14, v_entry);
  -- B5: invoices with different rates: the header shows the average rate of the copied lines (LC total / FC total).
  UPDATE erp.document d SET fx_rate = round(d.total / d.total_fc, 6)
   WHERE d.company_code = p_company AND d.obj_type = 14 AND d.doc_entry = v_entry AND coalesce(d.total_fc, 0) <> 0
     AND (SELECT count(DISTINCT b.fx_rate) FROM erp.document_line l
            JOIN erp.document b ON b.company_code = l.company_code AND b.obj_type = 13 AND b.doc_entry = l.base_doc_entry
           WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = v_entry AND l.base_obj_type = 13) > 1;
""", label='cm avg')
t = patch(t, """  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);""",
          """  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans,
                            'fx_rate', (SELECT fx_rate FROM erp.document WHERE company_code = p_company AND obj_type = 14 AND doc_entry = v_entry));""",
          label='cm ret')
add('_sd_cm_exec', '33_multicurrency.sql', ln, t + "\n-- B5: average header rate for invoices with different rates; + fx_rate in the result.")

# ================================================================ 4. Landed costs in a foreign currency
out.append((ART / 'part2.sql').read_text())

t, ln = extract('32_gl_setup.sql', 'erp._lc_eval(')
t = patch(t, """  v_res    jsonb := '[]';
  j        integer;
BEGIN""", """  v_res    jsonb := '[]';
  j        integer;
  v_ccur   text;
  v_famt   numeric;
  v_frate  numeric;
  v_clear  numeric;
  v_irate  numeric;
  v_linked numeric;
  v_aptot  numeric;
  v_apno   text;
  v_apmap  jsonb := '{}';
  fx       jsonb;
  ap       erp.document;
  v_ctot   numeric := 0;
BEGIN""", label='lc decl')
t = patch(t, """      'value', round(gl.quantity * gl.price, 2), 'cbm', v_cbm, 'weight', v_w, 'price', gl.price);""",
          """      'value', CASE WHEN gl.line_total_fc IS NOT NULL THEN round(gl.quantity * coalesce(gl.stock_price, gl.price * coalesce(d.fx_rate, 1)), 2)
                    ELSE round(gl.quantity * gl.price, 2) END,
      'cbm', v_cbm, 'weight', v_w,
      'price', CASE WHEN gl.line_total_fc IS NOT NULL THEN coalesce(gl.stock_price, round(gl.price * coalesce(d.fx_rate, 1), 6)) ELSE gl.price END);""",
          label='lc value')
t = patch(t, """    v_amt := round(v_amt, 2);
""", """    v_amt := round(v_amt, 2);
    -- B5: the charge's currency (rate of the landed cost date) and the broker's A/P invoice it is billed on.
    v_ccur := upper(coalesce(nullif(btrim(x->>'currency'), ''), v_cur));
    v_famt := NULL;
    v_frate := NULL;
    IF v_ccur <> v_cur THEN
      fx := erp._cur_pick(p_company, NULL, NULL, v_ccur, x->>'fx_rate', v_date, '');
      IF fx->>'error' IS NOT NULL THEN
        RAISE EXCEPTION 'Landed cost % (%): %', k, lc.name, fx->>'error' USING ERRCODE = 'P0001';
      END IF;
      v_frate := (fx->>'rate')::numeric;
      v_famt := v_amt;
      v_amt := round(v_famt * v_frate, 2);
    END IF;
    v_clear := v_amt;
    v_apno := NULL;
    ap := NULL;
    IF nullif(btrim(x->>'ap_invoice_entry'), '') IS NOT NULL THEN
      SELECT * INTO ap FROM erp.document WHERE company_code = p_company AND obj_type = 18 AND doc_entry = erp._num(x->>'ap_invoice_entry')::integer;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % was not found in %.', k, lc.name, x->>'ap_invoice_entry', p_company USING ERRCODE = 'P0001';
      END IF;
      v_apno := erp._sd_no(p_company, 18, ap.doc_entry);
      IF ap.status IN ('cancelled', 'cancellation') THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is cancelled.', k, lc.name, v_apno USING ERRCODE = 'P0001';
      ELSIF v_card IS NOT NULL AND ap.card_code <> v_card THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is from %, not from the broker %.', k, lc.name, v_apno, ap.card_code, v_card USING ERRCODE = 'P0001';
      ELSIF coalesce(ap.currency, v_cur) <> v_ccur THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is in %, but this charge is in %. Enter the charge in the invoice''s currency.',
          k, lc.name, v_apno, coalesce(ap.currency, v_cur), v_ccur USING ERRCODE = 'P0001';
      END IF;
      -- Net of VAT, in the invoice's currency; what other landed costs (and earlier lines of this one) already took.
      v_aptot := CASE WHEN v_ccur <> v_cur THEN coalesce(ap.total_fc, 0) - coalesce(ap.vat_total_fc, 0) ELSE ap.total - coalesce(ap.vat_total, 0) END;
      v_linked := coalesce((SELECT sum(coalesce(c.amount_fc, c.amount)) FROM erp.landed_cost_charge c WHERE c.company_code = p_company AND c.ap_invoice_entry = ap.doc_entry), 0)
                  + coalesce((v_apmap->>ap.doc_entry::text)::numeric, 0);
      IF v_linked + coalesce(v_famt, v_amt) > v_aptot THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % has % % left to link (net of VAT), less than % %.', k, lc.name, v_apno,
          erp._money(greatest(v_aptot - v_linked, 0)), v_ccur, erp._money(coalesce(v_famt, v_amt)), v_ccur USING ERRCODE = 'P0001';
      END IF;
      v_apmap := v_apmap || jsonb_build_object(ap.doc_entry::text, coalesce((v_apmap->>ap.doc_entry::text)::numeric, 0) + coalesce(v_famt, v_amt));
      v_irate := CASE WHEN v_ccur <> v_cur THEN coalesce(nullif(ap.fx_rate, 0), v_frate) ELSE 1 END;
      v_clear := round(coalesce(v_famt, v_amt) * v_irate, 2);
    END IF;
    v_ctot := v_ctot + v_clear;
""", label='lc charge')
t = patch(t, """    v_charges := v_charges || jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt,
                                                 'acct_code', coalesce(lc.acct_code, erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false)));""",
          """    v_charges := v_charges || (jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt,
                                                 'acct_code', coalesce(lc.acct_code, erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false)))
                               || jsonb_build_object('currency', v_ccur, 'amount_fc', v_famt, 'fx_rate', v_frate, 'ap_invoice_entry', ap.doc_entry,
                                                     'ap_invoice_no', v_apno, 'clear_amount', v_clear, 'fx_diff', v_clear - v_amt));""", label='lc charges')
t = patch(t, """                            'totals', jsonb_build_object('total', v_total, 'to_inventory', v_ti, 'to_cogs', v_tc, 'currency', v_cur));""",
          """                            'totals', jsonb_build_object('total', v_total, 'to_inventory', v_ti, 'to_cogs', v_tc, 'currency', v_cur,
                                                         'clearing', v_ctot, 'fx_diff', v_ctot - v_total));""", label='lc totals')
add('_lc_eval', '32_gl_setup.sql', ln, t + """
-- B5: charges in a foreign currency (rate of the landed cost date) and the linked broker A/P invoice (clearing at its LC);
-- the value split of a foreign-currency receipt uses its LC value.""")

t, ln = extract('32_gl_setup.sql', 'erp.landed_cost_create(')
t = patch(t, """  IF v_tc > 0 THEN
    PERFORM erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code')
       FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0;
  END IF;
""", """  IF v_tc > 0 THEN
    PERFORM erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code')
       FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0;
  END IF;
  -- B5: the rate difference against linked broker invoices (B4's accounts).
  IF (e->'totals'->>'fx_diff')::numeric > 0 THEN
    PERFORM erp.gl_account(p_company, 'purchasing', 'fx_loss');
  ELSIF (e->'totals'->>'fx_diff')::numeric < 0 THEN
    PERFORM erp.gl_account(p_company, 'sales', 'fx_gain');
  END IF;
""", label='lcc accts')
t = patch(t, """  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount, acct_code)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount, y.acct_code
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric, acct_code text);""",
          """  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount, acct_code,
                                      currency, amount_fc, fx_rate, ap_invoice_entry, clear_amount, fx_diff)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount, y.acct_code,
         y.currency, y.amount_fc, y.fx_rate, y.ap_invoice_entry, y.clear_amount, y.fx_diff
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric, acct_code text,
                                               currency text, amount_fc numeric, fx_rate numeric, ap_invoice_entry int, clear_amount numeric, fx_diff numeric);""",
          label='lcc insert')
t = patch(t, """    FROM (SELECT coalesce(ch->>'acct_code', v_clr) AS acct, sum((ch->>'amount')::numeric) AS amt, min((ch->>'charge_no')::integer) AS first_charge
            FROM jsonb_array_elements(e->'charges') ch GROUP BY 1) a);""",
          """    FROM (SELECT coalesce(ch->>'acct_code', v_clr) AS acct, sum((ch->>'clear_amount')::numeric) AS amt, min((ch->>'charge_no')::integer) AS first_charge
            FROM jsonb_array_elements(e->'charges') ch GROUP BY 1) a);
  -- B5: clearing credited at the linked invoices' LC; the difference to what was capitalised is a rate difference.
  IF (e->'totals'->>'fx_diff')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', erp.gl_account(p_company, 'purchasing', 'fx_loss'),
                                                               'debit', (e->'totals'->>'fx_diff')::numeric, 'memo', 'Exchange rate difference to the broker''s invoice'));
  ELSIF (e->'totals'->>'fx_diff')::numeric < 0 THEN
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', erp.gl_account(p_company, 'sales', 'fx_gain'),
                                                               'credit', -(e->'totals'->>'fx_diff')::numeric, 'memo', 'Exchange rate difference to the broker''s invoice'));
  END IF;""", label='lcc credit')
t = patch(t, """  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'trans_id', v_trans);""",
          """  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'trans_id', v_trans,
                            'fx_diff', (e->'totals'->>'fx_diff')::numeric);""", label='lcc ret')
add('landed_cost_create', '32_gl_setup.sql', ln, t + """
-- B5: charges keep currency / FC amount / rate / linked invoice; clearing at the linked invoice's LC, difference to
-- purchasing / fx_loss or sales / fx_gain.""")

t, ln = extract('21_purchasing.sql', 'erp.landed_cost_info(')
t = patch(t, """    'charges', coalesce((SELECT jsonb_agg(jsonb_build_object('charge_no', c.charge_no, 'code', c.code, 'name', c.name, 'split_method', c.split_method,
                                           'amount', c.amount) ORDER BY c.charge_no)""",
          """    'charges', coalesce((SELECT jsonb_agg(jsonb_build_object('charge_no', c.charge_no, 'code', c.code, 'name', c.name, 'split_method', c.split_method,
                                           'amount', c.amount, 'currency', coalesce(c.currency, lc.currency), 'amount_fc', c.amount_fc, 'fx_rate', c.fx_rate,
                                           'ap_invoice_entry', c.ap_invoice_entry,
                                           'ap_invoice_no', CASE WHEN c.ap_invoice_entry IS NOT NULL THEN erp._sd_no(p_company, 18, c.ap_invoice_entry) END,
                                           'clear_amount', coalesce(c.clear_amount, c.amount), 'fx_diff', coalesce(c.fx_diff, 0)) ORDER BY c.charge_no)""",
          label='lci charges')
add('landed_cost_info', '21_purchasing.sql', ln, t + "\n-- B5: charges with currency, FC amount, rate, linked A/P invoice, clearing amount and rate difference.")

# ================================================================ health
t, ln = extract('33_multicurrency.sql', 'erp._health_files(')
t = patch(t, "('33_multicurrency.sql', 'currency_rate')", "('33_multicurrency.sql', 'currency_rate'),\n    ('34_open_items.sql', 'fx_revaluation_post')", label='health')
add('_health_files', '33_multicurrency.sql', ln, t + "\n-- B5: + 34_open_items.sql (marker fx_revaluation_post).")

out.append((ART / 'part3.sql').read_text())

target = SQL / '34_open_items.sql'
text = '\n'.join(out).rstrip() + '\n'
if CHECK:
    same = target.exists() and target.read_text() == text
    print('identical' if same else 'DIFFERENT', target)
    sys.exit(0 if same else 1)
target.write_text(text)
print('wrote', target, sum(1 for _ in target.open()))
