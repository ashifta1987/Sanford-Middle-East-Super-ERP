#!/usr/bin/env python3
"""Assemble supabase/sql/35_final_items.sql from the hand-written parts and patched copies of earlier functions.

Each patch must match an exact number of times or the build stops, so a changed source is noticed at once.
  python3 supabase/sql/src/35_final_items/build.py           # writes supabase/sql/35_final_items.sql
  python3 supabase/sql/src/35_final_items/build.py --check   # exit 0 when the committed file is identical
"""
import sys, pathlib

ART = pathlib.Path(__file__).resolve().parent          # supabase/sql/src/35_final_items
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


# ================================================================ 1. Landed cost vendor per cost line (+ broker on the header)
out.append("""
-- ---- Landed cost functions with the vendor per cost line.""")

t, ln = extract('34_open_items.sql', 'erp._lc_eval(')
t = patch(t, """  ap       erp.document;
  v_ctot   numeric := 0;
BEGIN""", """  ap       erp.document;
  v_ctot   numeric := 0;
  v_vend   text;
  v_vcur   text;
BEGIN""", label='lc decl')
t = patch(t, """    v_ccur := upper(coalesce(nullif(btrim(x->>'currency'), ''), v_cur));
    v_famt := NULL;
""", """    v_ccur := upper(coalesce(nullif(btrim(x->>'currency'), ''), v_cur));
    -- B6: the vendor of the cost line (SAP B1: Vendor on the Costs tab; the header's card_code is the Broker).
    v_vend := nullif(btrim(x->>'card_code'), '');
    IF v_vend IS NOT NULL THEN
      SELECT currency INTO v_vcur FROM erp.business_partner WHERE company_code = p_company AND card_code = v_vend AND kind = 'supplier';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Landed cost % (%): supplier % does not exist in company %. Check the code.', k, lc.name, v_vend, p_company USING ERRCODE = 'P0001';
      END IF;
      v_vcur := nullif(nullif(btrim(v_vcur), ''), '##');
      IF v_vcur IS NOT NULL AND v_ccur NOT IN (v_vcur, v_cur) THEN
        RAISE EXCEPTION 'Landed cost % (%): supplier % trades in %. Enter the charge in %.', k, lc.name, v_vend, v_vcur,
          CASE WHEN v_vcur = v_cur THEN v_cur ELSE v_vcur || ' or ' || v_cur END USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_famt := NULL;
""", label='lc vendor')
t = patch(t, """      ELSIF v_card IS NOT NULL AND ap.card_code <> v_card THEN""",
          """      ELSIF v_vend IS NOT NULL AND ap.card_code <> v_vend THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is from %, not from the vendor %.', k, lc.name, v_apno, ap.card_code, v_vend USING ERRCODE = 'P0001';
      ELSIF v_vend IS NULL AND v_card IS NOT NULL AND ap.card_code <> v_card THEN""", label='lc ap vendor')
t = patch(t, """      v_clear := round(coalesce(v_famt, v_amt) * v_irate, 2);
    END IF;""", """      v_clear := round(coalesce(v_famt, v_amt) * v_irate, 2);
      v_vend := coalesce(v_vend, ap.card_code);      -- B6: the invoice's supplier is the cost line's vendor
    END IF;""", label='lc vend default')
t = patch(t, """'ap_invoice_no', v_apno, 'clear_amount', v_clear, 'fx_diff', v_clear - v_amt));""",
          """'ap_invoice_no', v_apno, 'clear_amount', v_clear, 'fx_diff', v_clear - v_amt)
                               || jsonb_build_object('card_code', v_vend,
                                                     'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = v_vend)));""",
          label='lc charge json')
add('_lc_eval', '34_open_items.sql', ln, t + """
-- B6: + vendor per cost line (supplier, its currency or LC; a linked A/P invoice must be the vendor's, else the broker's;
-- the vendor defaults to the linked invoice's supplier).""")

t, ln = extract('34_open_items.sql', 'erp.landed_cost_create(')
t = patch(t, """                                      currency, amount_fc, fx_rate, ap_invoice_entry, clear_amount, fx_diff)""",
          """                                      currency, amount_fc, fx_rate, ap_invoice_entry, clear_amount, fx_diff, card_code)""", label='lcc cols')
t = patch(t, """         y.currency, y.amount_fc, y.fx_rate, y.ap_invoice_entry, y.clear_amount, y.fx_diff""",
          """         y.currency, y.amount_fc, y.fx_rate, y.ap_invoice_entry, y.clear_amount, y.fx_diff, y.card_code""", label='lcc vals')
t = patch(t, """currency text, amount_fc numeric, fx_rate numeric, ap_invoice_entry int, clear_amount numeric, fx_diff numeric);""",
          """currency text, amount_fc numeric, fx_rate numeric, ap_invoice_entry int, clear_amount numeric, fx_diff numeric,
                                               card_code text);""", label='lcc rec')
add('landed_cost_create', '34_open_items.sql', ln, t + "\n-- B6: + the cost line's vendor.")

t, ln = extract('34_open_items.sql', 'erp.landed_cost_info(')
t = patch(t, """                                           'clear_amount', coalesce(c.clear_amount, c.amount), 'fx_diff', coalesce(c.fx_diff, 0)) ORDER BY c.charge_no)""",
          """                                           'clear_amount', coalesce(c.clear_amount, c.amount), 'fx_diff', coalesce(c.fx_diff, 0),
                                           'card_code', c.card_code,
                                           'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = c.card_code)) ORDER BY c.charge_no)""",
          label='lci vendor')
add('landed_cost_info', '34_open_items.sql', ln, t + "\n-- B6: + vendor (code and name) per charge.")

# ================================================================ 2. Posting in the system currency
out.append("""
-- ============ 3. Journals carry system currency amounts ============
-- When a company's system currency differs from its local currency, every Super ERP journal line also carries its amount in
-- the system currency (journal_line.sys_debit / sys_credit, SAP JDT1 SYSDeb / SYSCred): the amount the caller passes, the
-- line's FC amount when the FC is the system currency, else LC / the system currency's rate of the posting date
-- (fx_rate_list; missing = refused, as SAP). Rounding per line is what creates conversion differences. A journal with
-- source_ref.sys_only = true carries system currency amounts only (LC 0) — Conversion Differences posts those. Reversals
-- mirror the system currency amounts. Companies whose system currency is the local currency post exactly as before.""")

t, ln = extract('33_multicurrency.sql', 'erp.post_journal(')
t = patch(t, """  v_frate numeric;
  dd      erp.document;
BEGIN""", """  v_frate numeric;
  dd      erp.document;
  v_sc    text;
  v_srate numeric;
  v_sysonly boolean := coalesce((coalesce(p_source_ref, '{}'::jsonb)->>'sys_only')::boolean, false);
  v_lines jsonb := p_lines;
  v_rows  jsonb;
BEGIN""", label='pj decl')
t = patch(t, """  e := erp._je_lines_eval(p_company, p_lines, coalesce((s->>'allow_control')::boolean, false));""",
          """  -- B6: system currency.
  v_sc := erp._sys_cur(p_company);
  IF v_sysonly THEN
    IF v_sc IS NULL THEN
      RAISE EXCEPTION 'The system currency of % is its local currency %, so there is nothing to post in the system currency only.', p_company, v_cur
        USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_lines) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) x
                                                    WHERE coalesce(erp._num(x->>'debit'), 0) <> 0 OR coalesce(erp._num(x->>'credit'), 0) <> 0) THEN
      RAISE EXCEPTION 'A journal in the system currency only has no % amounts. Enter the amounts in %.', v_cur, v_sc USING ERRCODE = 'P0001';
    END IF;
    -- The same account and amount checks, on the system currency amounts.
    SELECT jsonb_agg((x.value - 'debit' - 'credit') || jsonb_build_object('debit', x.value->'sys_debit', 'credit', x.value->'sys_credit') ORDER BY x.ord)
      INTO v_lines FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) WITH ORDINALITY AS x(value, ord);
  ELSIF v_sc IS NOT NULL THEN
    v_srate := erp._cur_rate(p_company, v_sc, p_date);
    IF coalesce(v_srate, 0) <= 0 THEN
      RAISE EXCEPTION '%', format('There is no exchange rate for %s (the system currency) on %s. Enter it in Administration › Exchange Rates, then try again.',
                                  v_sc, erp._day(p_date)) USING ERRCODE = 'P0001';
    END IF;
  END IF;

  e := erp._je_lines_eval(p_company, v_lines, coalesce((s->>'allow_control')::boolean, false));""", label='pj sc')
t = patch(t, """erp._money(abs(v_d - v_c)), v_cur)""", """erp._money(abs(v_d - v_c)), CASE WHEN v_sysonly THEN v_sc ELSE v_cur END)""", label='pj msg')

old_insert = t[t.index("  v_trans := nextval('erp.erp_trans_id_seq');"):t.index("  INSERT INTO erp.audit_log")]
assert old_insert.rstrip().endswith('ON true;'), old_insert[-200:]
t = patch(t, old_insert, """  v_trans := nextval('erp.erp_trans_id_seq');
  -- B6: every line's amounts first (LC, FC, system currency): posted lines can't be updated, and the header carries the
  -- system currency total.
  SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.line_id), '[]'::jsonb) INTO v_rows FROM (
    SELECT y.line_id, y.acct_code, y.short_name, y.debit, y.credit, y.memo, y.tax_code, y.cost_centre, y.fc_debit, y.fc_credit,
           CASE WHEN v_sysonly THEN y.sd
                WHEN v_sc IS NULL THEN round(erp._num(y.v->>'sys_debit'), 2)
                ELSE coalesce(round(erp._num(y.v->>'sys_debit'), 2), CASE WHEN v_fcur = v_sc THEN y.fc_debit END, round(y.debit / v_srate, 2)) END AS sys_debit,
           CASE WHEN v_sysonly THEN y.scr
                WHEN v_sc IS NULL THEN round(erp._num(y.v->>'sys_credit'), 2)
                ELSE coalesce(round(erp._num(y.v->>'sys_credit'), 2), CASE WHEN v_fcur = v_sc THEN y.fc_credit END, round(y.credit / v_srate, 2)) END AS sys_credit
      FROM (
        SELECT x.line_id, x.acct_code, x.short_name, x.memo, x.tax_code, x.cost_centre, p.v,
               CASE WHEN v_sysonly THEN 0 ELSE x.debit END AS debit, CASE WHEN v_sysonly THEN 0 ELSE x.credit END AS credit,
               x.debit AS sd, x.credit AS scr,
               CASE WHEN v_fcur IS NOT NULL AND NOT v_sysonly THEN coalesce(erp._num(p.v->>'fc_debit'),
                    CASE WHEN dd.card_code IS NOT NULL AND x.short_name = dd.card_code AND x.debit > 0 AND x.debit = round(dd.total, 2) THEN dd.total_fc END,
                    round(x.debit / nullif(v_frate, 0), 2)) END AS fc_debit,
               CASE WHEN v_fcur IS NOT NULL AND NOT v_sysonly THEN coalesce(erp._num(p.v->>'fc_credit'),
                    CASE WHEN dd.card_code IS NOT NULL AND x.short_name = dd.card_code AND x.credit > 0 AND x.credit = round(dd.total, 2) THEN dd.total_fc END,
                    round(x.credit / nullif(v_frate, 0), 2)) END AS fc_credit
          FROM jsonb_to_recordset(e->'lines') AS x(line_id int, acct_code text, short_name text, debit numeric, credit numeric,
                                                   memo text, tax_code text, cost_centre text)
          LEFT JOIN LATERAL (SELECT o.value AS v FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS o(value, ord) WHERE o.ord - 1 = x.line_id) p ON true) y) z;

  INSERT INTO erp.journal_entry (company_code, trans_id, number, ref_date, due_date, tax_date, memo, ref1, ref2, ref3, trans_type, base_ref,
                                 total_local, total_sys, currency, reversal_of, source, created_on)
  VALUES (p_company, v_trans, v_trans, p_date, coalesce((s->>'due_date')::date, p_date), coalesce((s->>'tax_date')::date, p_date),
          nullif(btrim(p_memo), ''), s->>'ref1', s->>'ref2', s->>'ref3', coalesce((s->>'trans_type')::integer, 30), s->>'base_ref',
          CASE WHEN v_sysonly THEN 0 ELSE v_d END,
          CASE WHEN v_sc IS NULL AND NOT v_sysonly THEN v_d ELSE (SELECT coalesce(sum((r->>'sys_debit')::numeric), 0) FROM jsonb_array_elements(v_rows) r) END,
          v_cur, (s->>'reversal_of')::integer, 'erp', current_date);
  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, memo, ref_date, due_date, tax_code, cost_centre,
                                fc_debit, fc_credit, fc_currency, sys_debit, sys_credit)
  SELECT p_company, v_trans, x.line_id, x.acct_code, x.short_name, x.debit, x.credit, coalesce(x.memo, nullif(btrim(p_memo), '')),
         p_date, coalesce((s->>'due_date')::date, p_date), x.tax_code, x.cost_centre,
         x.fc_debit, x.fc_credit, CASE WHEN v_sysonly THEN NULL ELSE v_fcur END, x.sys_debit, x.sys_credit
    FROM jsonb_to_recordset(v_rows) AS x(line_id int, acct_code text, short_name text, debit numeric, credit numeric, memo text, tax_code text,
                                         cost_centre text, fc_debit numeric, fc_credit numeric, sys_debit numeric, sys_credit numeric);

""", label='pj insert')
t = patch(t, """                             'source_ref', s->'object_ref'));""",
          """                             'source_ref', s->'object_ref', 'sys_currency', v_sc, 'sys_only', v_sysonly));""", label='pj audit')
add('post_journal', '33_multicurrency.sql', ln, t + """
-- B6: system currency amounts on every line when the company's system currency is not its local currency (missing rate =
-- refused); source_ref.sys_only for journals in the system currency only; header total_sys in the system currency.""")

t, ln = extract('33_multicurrency.sql', 'erp._reverse_journal(')
t = patch(t, """                                         'fc_debit', l.fc_credit, 'fc_credit', l.fc_debit) ORDER BY l.line_id)""",
          """                                         'fc_debit', l.fc_credit, 'fc_credit', l.fc_debit,
                                         'sys_debit', l.sys_credit, 'sys_credit', l.sys_debit) ORDER BY l.line_id)""", label='rev lines')
t = patch(t, """                       'fc_currency', (SELECT max(fc_currency) FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id)));""",
          """                       'fc_currency', (SELECT max(fc_currency) FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id),
                       'sys_only', NOT EXISTS (SELECT 1 FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id AND (debit <> 0 OR credit <> 0))));""",
          label='rev sysonly')
add('_reverse_journal', '33_multicurrency.sql', ln, t + "\n-- B6: the mirror keeps the system currency amounts (and reverses journals in the system currency only).")

# ================================================================ health
t, ln = extract('34_open_items.sql', 'erp._health_files(')
t = patch(t, "('34_open_items.sql', 'fx_revaluation_post')", "('34_open_items.sql', 'fx_revaluation_post'),\n    ('35_final_items.sql', 'conversion_diff_post')", label='health')
add('_health_files', '34_open_items.sql', ln, t + "\n-- B6: + 35_final_items.sql (marker conversion_diff_post).")

out.append((ART / 'part2.sql').read_text())

target = SQL / '35_final_items.sql'
text = '\n'.join(out).rstrip() + '\n'
if CHECK:
    same = target.exists() and target.read_text() == text
    print('identical' if same else 'DIFFERENT', target)
    sys.exit(0 if same else 1)
target.write_text(text)
print('wrote', target, sum(1 for _ in target.open()))
