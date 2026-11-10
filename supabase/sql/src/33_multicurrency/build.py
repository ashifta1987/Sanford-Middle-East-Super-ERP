#!/usr/bin/env python3
"""Assemble supabase/sql/33_multicurrency.sql from the hand-written parts and patched copies of earlier functions.

Each patch must match an exact number of times or the build stops, so a changed source is noticed at once.
  python3 supabase/sql/src/33_multicurrency/build.py           # writes supabase/sql/33_multicurrency.sql
  python3 supabase/sql/src/33_multicurrency/build.py --check   # exit 0 when the committed file is identical
"""
import sys, pathlib

ART = pathlib.Path(__file__).resolve().parent          # supabase/sql/src/33_multicurrency
SQL = ART.parent.parent                                 # supabase/sql
CHECK = '--check' in sys.argv[1:]


def extract(fname, signature_start, nth=1):
    """Text of `CREATE OR REPLACE FUNCTION <signature_start>` … `END $$;` / `$$;` (nth occurrence) in an earlier file."""
    lines = (SQL / fname).read_text().splitlines()
    hits = [i for i, l in enumerate(lines) if l.startswith('CREATE OR REPLACE FUNCTION ' + signature_start)]
    if len(hits) < nth:
        sys.exit(f'not found: {signature_start} in {fname}')
    i = hits[nth - 1]
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


# ================================================================ 6. Posting: foreign-currency amounts on journal lines
out.append("""
-- ============ 6. Posting: foreign-currency amounts on journal lines ============""")

t, ln = extract('18_posting.sql', 'erp.post_journal(')
t = patch(t, """  v_d     numeric;
  v_c     numeric;
BEGIN""", """  v_d     numeric;
  v_c     numeric;
  v_fcur  text;
  v_frate numeric;
  dd      erp.document;
BEGIN""", label='pj decl')
t = patch(t, """  v_trans := nextval('erp.erp_trans_id_seq');
""", """  -- B4: foreign currency. Explicit: source_ref.fc_currency (+ fc_rate) and line fc_debit / fc_credit. A Super ERP document
  -- in a foreign currency (object 'document') fills every line at the document's rate, the partner line at its FC total.
  v_fcur := nullif(btrim(s->>'fc_currency'), '');
  v_frate := erp._num(s->>'fc_rate');
  IF v_fcur IS NULL AND s->>'object' = 'document' AND coalesce(s->>'object_ref', '') ~ '^[0-9]+/[0-9]+$' THEN
    SELECT * INTO dd FROM erp.document
     WHERE company_code = p_company AND obj_type = split_part(s->>'object_ref', '/', 1)::integer AND doc_entry = split_part(s->>'object_ref', '/', 2)::integer;
    IF dd.currency IS NOT NULL AND dd.currency <> v_cur AND coalesce(dd.fx_rate, 0) > 0 THEN
      v_fcur := dd.currency;
      v_frate := dd.fx_rate;
    END IF;
  END IF;

  v_trans := nextval('erp.erp_trans_id_seq');
""", label='pj fc ctx')
t = patch(t, """  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, memo, ref_date, due_date, tax_code, cost_centre)
  SELECT je.company_code, je.trans_id, x.line_id, x.acct_code, x.short_name, x.debit, x.credit, coalesce(x.memo, nullif(btrim(p_memo), '')),
         je.ref_date, je.due_date, x.tax_code, x.cost_centre
    FROM je CROSS JOIN jsonb_to_recordset(e->'lines') AS x(line_id int, acct_code text, short_name text, debit numeric, credit numeric,
                                                          memo text, tax_code text, cost_centre text);""",
"""  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, memo, ref_date, due_date, tax_code, cost_centre,
                                fc_debit, fc_credit, fc_currency)
  SELECT je.company_code, je.trans_id, x.line_id, x.acct_code, x.short_name, x.debit, x.credit, coalesce(x.memo, nullif(btrim(p_memo), '')),
         je.ref_date, je.due_date, x.tax_code, x.cost_centre,
         CASE WHEN v_fcur IS NOT NULL THEN coalesce(erp._num(p.v->>'fc_debit'),
              CASE WHEN dd.card_code IS NOT NULL AND x.short_name = dd.card_code AND x.debit > 0 AND x.debit = round(dd.total, 2) THEN dd.total_fc END,
              round(x.debit / nullif(v_frate, 0), 2)) END,
         CASE WHEN v_fcur IS NOT NULL THEN coalesce(erp._num(p.v->>'fc_credit'),
              CASE WHEN dd.card_code IS NOT NULL AND x.short_name = dd.card_code AND x.credit > 0 AND x.credit = round(dd.total, 2) THEN dd.total_fc END,
              round(x.credit / nullif(v_frate, 0), 2)) END,
         v_fcur
    FROM je CROSS JOIN jsonb_to_recordset(e->'lines') AS x(line_id int, acct_code text, short_name text, debit numeric, credit numeric,
                                                          memo text, tax_code text, cost_centre text)
    LEFT JOIN LATERAL (SELECT o.value AS v FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS o(value, ord) WHERE o.ord - 1 = x.line_id) p ON true;""",
label='pj insert')
add('post_journal', '18_posting.sql', ln, t + """
-- B4: lines may carry fc_debit / fc_credit; source_ref.fc_currency / fc_rate; foreign-currency documents fill FC on every line.""")

t, ln = extract('18_posting.sql', 'erp._reverse_journal(')
t = patch(t, """'memo', l.memo, 'tax_code', l.tax_code, 'cost_centre', l.cost_centre) ORDER BY l.line_id)""",
          """'memo', l.memo, 'tax_code', l.tax_code, 'cost_centre', l.cost_centre,
                                         'fc_debit', l.fc_credit, 'fc_credit', l.fc_debit) ORDER BY l.line_id)""", label='rev lines')
t = patch(t, """                       'object', 'journal', 'object_ref', p_trans_id::text));""",
          """                       'object', 'journal', 'object_ref', p_trans_id::text,
                       'fc_currency', (SELECT max(fc_currency) FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id)));""",
          label='rev src')
add('_reverse_journal', '18_posting.sql', ln, t + "\n-- B4: the mirror keeps the foreign-currency amounts.")

# ================================================================ 7. Documents: header currency from the context
out.append("""
-- ============ 7. Sales and purchasing documents in the partner's currency ============""")

t, ln = extract('19_sales_cycle.sql', 'erp._sd_new_doc(')
t = patch(t, """DECLARE
  nb jsonb;
BEGIN
  nb := erp._sd_number(p_company, p_obj);""", """DECLARE
  nb jsonb;
  fx jsonb := erp._cur_ctx_take(p_company);
BEGIN
  nb := erp._sd_number(p_company, p_obj);""", label='sdnew decl')
t = patch(t, """p_card, p_card_name, p_ref, (SELECT currency FROM erp.company WHERE company_code = p_company), 1, 0, 0, 0, p_slp, p_branch, p_comments,""",
          """p_card, p_card_name, p_ref, fx->>'currency', (fx->>'rate')::numeric, 0, 0, 0, p_slp, p_branch, p_comments,""", label='sdnew cur')
add('_sd_new_doc', '19_sales_cycle.sql', ln, t + "\n-- B4: currency and rate from the context set by the create function (_cur_ctx_base / _cur_ctx_card).")

t, ln = extract('21_purchasing.sql', 'erp._pd_new_doc(')
t = patch(t, """DECLARE
  nb jsonb;
BEGIN
  nb := erp._pd_number(p_company, p_obj);""", """DECLARE
  nb jsonb;
  fx jsonb := erp._cur_ctx_take(p_company);
BEGIN
  nb := erp._pd_number(p_company, p_obj);""", label='pdnew decl')
t = patch(t, """p_card, p_card_name, p_ref, (SELECT currency FROM erp.company WHERE company_code = p_company), 1, 0, 0, 0, p_branch, p_comments,""",
          """p_card, p_card_name, p_ref, fx->>'currency', (fx->>'rate')::numeric, 0, 0, 0, p_branch, p_comments,""", label='pdnew cur')
add('_pd_new_doc', '21_purchasing.sql', ln, t + "\n-- B4: currency and rate from the context.")

# _sd_base_lines: amounts of the base line in the document currency
t, ln = extract('19_sales_cycle.sql', 'erp._sd_base_lines(')
t = patch(t, """'base_line_total', bl.line_total, 'base_vat', bl.vat,""",
          """'base_line_total', coalesce(bl.line_total_fc, bl.line_total), 'base_vat', coalesce(bl.vat_fc, bl.vat),""", label='sdbase')
add('_sd_base_lines', '19_sales_cycle.sql', ln, t + "\n-- B4: base amounts in the document currency.")

# ---- delivery
t, ln = extract('19_sales_cycle.sql', 'erp.sales_delivery_create(')
t = patch(t, """  bl := erp._sd_base_lines(p_company, 15, 17, p_lines, 'deliver');
""", """  bl := erp._sd_base_lines(p_company, 15, 17, p_lines, 'deliver');
  PERFORM erp._cur_ctx_base(p_company, 15, bl, v_date, h);   -- B4: the order's currency and rate
""", label='dlv ctx')
add('sales_delivery_create', '19_sales_cycle.sql', ln, t + "\n-- B4: keeps the order's currency and rate.")

# ---- A/R invoice executor
t, ln = extract('30_numbering_company.sql', 'erp._sd_inv_exec(')
t = patch(t, """  ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
    RAISE EXCEPTION 'Customer % is billed in %. Invoices in a foreign currency come in a later stage.', v_card, bp.currency USING ERRCODE = 'P0001';
  END IF;""", """  END IF;
  -- B4: copied deliveries keep their currency (rate of the invoice date); service-only invoices use the customer's currency.
  IF jsonb_array_length(bl) > 0 THEN
    PERFORM erp._cur_ctx_base(p_company, 13, bl, v_date, h);
  ELSE
    PERFORM erp._cur_ctx_card(p_company, v_card, v_date, h, 'Customer');
  END IF;""", label='inv cur')
t = patch(t, """      SELECT price INTO v_price FROM erp.item_price WHERE company_code = p_company AND list_num = bp.price_list AND item_code = it.item_code;""",
          """      SELECT erp._cur_conv(p_company, ip.price, coalesce(ip.currency, v_cur), coalesce(nullif(current_setting('erp.fx_cur', true), ''), v_cur), v_date)
        INTO v_price FROM erp.item_price ip WHERE ip.company_code = p_company AND ip.list_num = bp.price_list AND ip.item_code = it.item_code;""",
          label='inv price')
add('_sd_inv_exec', '30_numbering_company.sql', ln, t + """
-- B4: foreign-currency invoices (the invoice date's rate); price-list prices converted to the invoice currency.""")

# ---- credit memo executor
t, ln = extract('30_numbering_company.sql', 'erp._sd_cm_exec(')
t = patch(t, """  bl := erp._sd_base_lines(p_company, 14, 13, p_lines, 'credit');
""", """  bl := erp._sd_base_lines(p_company, 14, 13, p_lines, 'credit');
  PERFORM erp._cur_ctx_base(p_company, 14, bl, v_date, h);   -- B4: the invoice's currency and rate
""", label='cm ctx')
add('_sd_cm_exec', '30_numbering_company.sql', ln, t + "\n-- B4: keeps the invoice's currency and rate (so it nets against the invoice in both currencies).")

# ---- sales evaluator
t, ln = extract('31_approvals.sql', 'erp._sd_eval(')
t = patch(t, """  v_prev   numeric;
BEGIN""", """  v_prev   numeric;
  v_lcur   text;
  v_frate  numeric := 1;
  fx       jsonb;
BEGIN""", label='sde decl')
t = patch(t, """    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s is billed in %s. Orders in a foreign currency come in a later stage.', v_card, bp.currency));
""", "", label='sde refuse')
t = patch(t, """  -- Price list, payment terms, salesperson: the header value, else the customer's own""",
          """  -- B4: document currency and rate (v_cur becomes the document currency; v_lcur is the company currency)
  v_lcur := v_cur;
  fx := erp._cur_pick(p_company, v_card, CASE WHEN v_bp_ok THEN bp.currency END, h->>'currency', h->>'fx_rate', v_doc_date, 'Customer',
                      (SELECT fx_rate FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp'));
  IF fx->>'error' IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', fx->>'field', 'message', fx->>'error');
  END IF;
  v_cur := fx->>'currency';
  v_frate := coalesce((fx->>'rate')::numeric, CASE WHEN v_cur = v_lcur THEN 1 END);

  -- Price list, payment terms, salesperson: the header value, else the customer's own""", label='sde cur')
t = patch(t, """      SELECT price INTO v_price FROM erp.item_price WHERE company_code = p_company AND list_num = v_pl AND item_code = v_code;""",
          """      SELECT CASE WHEN coalesce(ip.currency, v_lcur) = v_cur THEN ip.price
                  WHEN v_frate IS NULL THEN NULL
                  ELSE round(ip.price * erp._cur_rate(p_company, coalesce(ip.currency, v_lcur), v_doc_date) / v_frate, 6) END
        INTO v_price FROM erp.item_price ip WHERE ip.company_code = p_company AND ip.list_num = v_pl AND ip.item_code = v_code;""", label='sde price')
# credit position in LC
t = patch(t, """                                   'this_order', v_net + v_vat, 'left', bp.credit_limit - coalesce(bp.balance, 0) - v_open);""",
          """                                   'this_order', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'left', bp.credit_limit - coalesce(bp.balance, 0) - v_open,
                                   'currency', v_lcur);""", label='sde credit')
t = patch(t, """          v_exposure := coalesce(bp.balance, 0) + v_open + v_net + v_vat;""",
          """          v_exposure := coalesce(bp.balance, 0) + v_open + round((v_net + v_vat) * coalesce(v_frate, 1), 2);""", label='sde exposure')
t = patch(t, """'credit_over', v_exposure - bp.credit_limit, 'doc_total', v_net + v_vat)""",
          """'credit_over', v_exposure - bp.credit_limit, 'doc_total', round((v_net + v_vat) * coalesce(v_frate, 1), 2))""", label='sde credit fact')
t = patch(t, """                                v_card, erp._money(bp.credit_limit), v_cur, erp._money(bp.balance), erp._money(v_open),
                                erp._money(v_net + v_vat), erp._money(v_exposure), v_cur)));""",
          """                                v_card, erp._money(bp.credit_limit), v_lcur, erp._money(bp.balance), erp._money(v_open),
                                erp._money(round((v_net + v_vat) * coalesce(v_frate, 1), 2)), erp._money(v_exposure), v_lcur)));""", label='sde credit msg')
t = patch(t, """jsonb_build_object('discount_pct', t.discount_pct, 'doc_total', v_net + v_vat)""",
          """jsonb_build_object('discount_pct', t.discount_pct, 'doc_total', round((v_net + v_vat) * coalesce(v_frate, 1), 2))""", label='sde disc fact')
# below cost: cost (LC) in the document currency
t = patch(t, """        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, price numeric, discount_pct numeric, cost numeric, item_code text)""",
          """        FOR x IN SELECT t0.line_num, t0.price, t0.discount_pct, round(t0.cost / coalesce(v_frate, 1), 4) AS cost, t0.item_code
                   FROM jsonb_to_recordset(v_out) AS t0(line_num int, price numeric, discount_pct numeric, cost numeric, item_code text)""", label='sde cost1')
t = patch(t, """                  WHERE t.cost IS NOT NULL AND round(t.price * (1 - t.discount_pct / 100), 4) < t.cost
                    AND erp._apr_hit(r.conds, jsonb_build_object('below_cost_pct', CASE WHEN t.cost > 0 THEN round((t.cost - round(t.price * (1 - t.discount_pct / 100), 4)) / t.cost * 100, 4) ELSE 0 END,
                                                                 'doc_total', v_net + v_vat)) LOOP""",
          """                  WHERE t0.cost IS NOT NULL AND round(t0.price * (1 - t0.discount_pct / 100), 4) < round(t0.cost / coalesce(v_frate, 1), 4)
                    AND erp._apr_hit(r.conds, jsonb_build_object('below_cost_pct', CASE WHEN t0.cost > 0 THEN round((t0.cost / coalesce(v_frate, 1) - round(t0.price * (1 - t0.discount_pct / 100), 4)) / (t0.cost / coalesce(v_frate, 1)) * 100, 4) ELSE 0 END,
                                                                 'doc_total', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) LOOP""", label='sde cost2')
t = patch(t, """                                 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('before_discount', v_gross, 'discount', v_gross - v_net, 'net', v_net, 'vat', v_vat,
                                 'total', v_net + v_vat, 'currency', v_cur),""",
          """                                 'comments', nullif(btrim(h->>'comments'), ''), 'currency', v_cur, 'fx_rate', v_frate),
    'totals', jsonb_build_object('before_discount', v_gross, 'discount', v_gross - v_net, 'net', v_net, 'vat', v_vat,
                                 'total', v_net + v_vat, 'currency', v_cur, 'rate', v_frate, 'local_currency', v_lcur,
                                 'rate_overridden', coalesce((fx->>'overridden')::boolean, false),
                                 'total_lc', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'vat_lc', round(v_vat * coalesce(v_frate, 1), 2)),""", label='sde totals')
add('_sd_eval', '31_approvals.sql', ln, t + """
-- B4: the customer's currency (or the header's), the date's rate; prices in the document currency (price lists converted);
-- credit limit, discount and below-cost rules in LC; totals in DC with total_lc / rate.""")

# ---- sales_doc_save: currency, rate and LC totals on the header
t, ln = extract('19_sales_cycle.sql', 'erp.sales_doc_save(')
t = patch(t, """hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', 1, (e->'totals'->>'total')::numeric,
            (e->'totals'->>'vat')::numeric, 0,""",
          """hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', (e->'totals'->>'rate')::numeric, (e->'totals'->>'total_lc')::numeric,
            (e->'totals'->>'vat_lc')::numeric, 0,""", label='sds ins')
t = patch(t, """           total = (e->'totals'->>'total')::numeric, vat_total = (e->'totals'->>'vat')::numeric, slp_code = (hd->>'slp_code')::integer,""",
          """           total = (e->'totals'->>'total_lc')::numeric, vat_total = (e->'totals'->>'vat_lc')::numeric, slp_code = (hd->>'slp_code')::integer,
           currency = e->'totals'->>'currency', fx_rate = (e->'totals'->>'rate')::numeric, total_fc = NULL, vat_total_fc = NULL,""", label='sds upd')
t = patch(t, """                                             base_obj_type int, base_doc_entry int, base_line int);

  INSERT INTO erp.audit_log""", """                                             base_obj_type int, base_doc_entry int, base_line int);
  PERFORM erp._sd_retotal(p_company, p_obj, v_entry);   -- B4: LC and DC totals from the lines

  INSERT INTO erp.audit_log""", label='sds retotal')
add('sales_doc_save', '19_sales_cycle.sql', ln, t + "\n-- B4: header currency + rate; totals from the lines (LC, and DC for foreign-currency documents).")

# ---- stored documents re-checked at submit / approval carry their currency and rate
t, ln = extract('19_sales_cycle.sql', 'erp._sd_stored(')
t = patch(t, """                                 'customer_ref', d.customer_ref, 'comments', d.comments),""",
          """                                 'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'fx_rate', d.fx_rate),""", label='sd stored')
add('_sd_stored', '19_sales_cycle.sql', ln, t + "\n-- B4: + currency and rate (a re-check keeps them).")
t, ln = extract('21_purchasing.sql', 'erp._pd_stored(')
t = patch(t, """'whs_code', w.whs_code, 'china_office', w.china_office, 'customer_ref', d.customer_ref, 'comments', d.comments),""",
          """'whs_code', w.whs_code, 'china_office', w.china_office, 'customer_ref', d.customer_ref, 'comments', d.comments,
                                 'currency', d.currency, 'fx_rate', d.fx_rate),""", label='pd stored')
add('_pd_stored', '21_purchasing.sql', ln, t + "\n-- B4: + currency and rate.")

# ---- print sheet in the document currency (VAT also in LC)
t, ln = extract('19_sales_cycle.sql', 'erp.sales_print_data(')
t = patch(t, """  bp erp.business_partner;
BEGIN""", """  bp erp.business_partner;
  v_fc boolean;
BEGIN""", label='spd decl')
t = patch(t, """  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = d.card_code;
""", """  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = d.card_code;
  v_fc := d.total_fc IS NOT NULL AND d.total_fc <> 0 AND d.currency IS DISTINCT FROM c.currency;
""", label='spd fc')
t = patch(t, """'customer_ref', d.customer_ref, 'comments', d.comments, 'total', d.total,
                              'vat_total', d.vat_total, 'currency', d.currency,""", """'customer_ref', d.customer_ref, 'comments', d.comments,
                              'total', CASE WHEN v_fc THEN d.total_fc ELSE d.total END, 'vat_total', CASE WHEN v_fc THEN d.vat_total_fc ELSE d.vat_total END,
                              'currency', d.currency, 'fx_rate', CASE WHEN v_fc THEN d.fx_rate END, 'total_lc', d.total, 'vat_total_lc', d.vat_total,""", label='spd doc')
t = patch(t, """'discount_pct', l.discount_pct, 'line_total', l.line_total, 'tax_code', l.tax_code,
                                                          'vat', l.vat, 'whs_code', l.whs_code)""", """'discount_pct', l.discount_pct, 'line_total', CASE WHEN v_fc THEN l.line_total_fc ELSE l.line_total END, 'tax_code', l.tax_code,
                                                          'vat', CASE WHEN v_fc THEN l.vat_fc ELSE l.vat END, 'whs_code', l.whs_code)""", label='spd lines')
t = patch(t, """sum(l.line_total) AS net, sum(l.vat) AS vat""", """sum(CASE WHEN v_fc THEN l.line_total_fc ELSE l.line_total END) AS net, sum(CASE WHEN v_fc THEN l.vat_fc ELSE l.vat END) AS vat""", label='spd vat')
add('sales_print_data', '19_sales_cycle.sql', ln, t + "\n-- B4: amounts in the document currency; total_lc / vat_total_lc and the rate for foreign-currency documents.")

# ---- GRPO / deposit / A/P invoice page in the document currency
t, ln = extract('21_purchasing.sql', 'erp.purchase_view(')
t = patch(t, """    'gross', CASE WHEN p_obj = 18 THEN (SELECT coalesce(sum(line_total + coalesce(vat, 0)), 0) FROM erp.document_line""",
          """    'gross', CASE WHEN p_obj = 18 THEN (SELECT coalesce(sum(CASE WHEN d.total_fc IS NOT NULL THEN coalesce(line_total_fc, 0) + coalesce(vat_fc, 0) ELSE line_total + coalesce(vat, 0) END), 0) FROM erp.document_line""", label='pv gross')
t = patch(t, """    'open_amount', CASE WHEN p_obj IN (18, 204) AND d.source = 'erp' THEN erp._bk_doc_open(p_company, p_obj, p_doc_entry) END,""",
          """    'open_amount', CASE WHEN p_obj IN (18, 204) AND d.source = 'erp' THEN coalesce(erp._bk_doc_open_fc(p_company, p_obj, p_doc_entry), erp._bk_doc_open(p_company, p_obj, p_doc_entry)) END,
    'open_amount_lc', CASE WHEN p_obj IN (18, 204) AND d.source = 'erp' THEN erp._bk_doc_open(p_company, p_obj, p_doc_entry) END,""", label='pv open')
t = patch(t, """                                                                                      'amount', x.amount) ORDER BY x.dp_entry)""",
          """                                                                                      'amount', coalesce(x.amount_fc, x.amount), 'amount_lc', x.amount) ORDER BY x.dp_entry)""", label='pv draws')
t = patch(t, """                                                                                          'amount', x.amount) ORDER BY x.invoice_entry)""",
          """                                                                                          'amount', coalesce(x.amount_fc, x.amount), 'amount_lc', x.amount) ORDER BY x.invoice_entry)""", label='pv drawn_by')
add('purchase_view', '21_purchasing.sql', ln, t + "\n-- B4: gross, open amount and draws in the document currency (open_amount_lc / amount_lc in LC).")

# ---- purchase order page: deposits in the order's currency
t, ln = extract('31_approvals.sql', 'erp.purchase_doc_info(')
t = patch(t, """      SELECT jsonb_agg(jsonb_build_object('doc_entry', dd.doc_entry, 'doc_no', dw.doc_no, 'doc_date', dd.doc_date, 'total', dd.total, 'paid', coalesce(dd.paid, 0),
               'drawn', (SELECT coalesce(sum(x.amount), 0) FROM erp.ap_dp_draw x WHERE x.company_code = dd.company_code AND x.dp_entry = dd.doc_entry),""",
          """      SELECT jsonb_agg(jsonb_build_object('doc_entry', dd.doc_entry, 'doc_no', dw.doc_no, 'doc_date', dd.doc_date,
               'total', CASE WHEN dd.total_fc IS NOT NULL THEN dd.total_fc ELSE dd.total END,
               'paid', CASE WHEN dd.total_fc IS NOT NULL THEN coalesce(dd.paid_fc, 0) ELSE coalesce(dd.paid, 0) END, 'currency', dd.currency, 'fx_rate', dd.fx_rate,
               'drawn', (SELECT coalesce(sum(CASE WHEN dd.total_fc IS NOT NULL THEN x.amount_fc ELSE x.amount END), 0) FROM erp.ap_dp_draw x WHERE x.company_code = dd.company_code AND x.dp_entry = dd.doc_entry),""", label='pdi deposits')
add('purchase_doc_info', '31_approvals.sql', ln, t + "\n-- B4: deposits in the order's currency.")

# ---- purchasing evaluator
t, ln = extract('31_approvals.sql', 'erp._pd_eval(')
t = patch(t, """  r        record;
  x        record;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;""", """  r        record;
  x        record;
  v_lcur   text;
  v_frate  numeric := 1;
  fx       jsonb;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;""", label='pde decl')
t = patch(t, """    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message',
        format('Supplier %s is billed in %s. Purchasing in a foreign currency comes in a later stage.', v_card, bp.currency));
""", "", label='pde refuse')
t = patch(t, """  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);""",
          """  -- B4: document currency and rate (a purchase request has no supplier: company currency)
  v_lcur := v_cur;
  IF NOT v_req THEN
    fx := erp._cur_pick(p_company, v_card, CASE WHEN v_bp_ok THEN bp.currency END, h->>'currency', h->>'fx_rate', v_doc_date, 'Supplier',
                        (SELECT fx_rate FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp'));
    IF fx->>'error' IS NOT NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', fx->>'field', 'message', fx->>'error');
    END IF;
    v_cur := fx->>'currency';
    v_frate := coalesce((fx->>'rate')::numeric, CASE WHEN v_cur = v_lcur THEN 1 END);
  END IF;

  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);""", label='pde cur')
t = patch(t, """    v_last := CASE WHEN v_code IS NOT NULL THEN erp._pd_last_price(p_company, v_code, p_doc_entry) END;""",
          """    v_last := CASE WHEN v_code IS NOT NULL THEN erp._cur_last_dc(erp._pd_last_price(p_company, v_code, p_doc_entry), v_cur, v_frate) END;""", label='pde last')
t = patch(t, """        IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_net + v_vat)) THEN
          v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', v_net + v_vat, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Purchase order total %s %s is above your limit of %s %s.', erp._money(v_net + v_vat), v_cur, erp._money(r.limit_value), v_cur)""",
          """        IF erp._apr_hit(r.conds, jsonb_build_object('amount', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) THEN
          v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Purchase order total %s %s is above your limit of %s %s.', erp._money(round((v_net + v_vat) * coalesce(v_frate, 1), 2)), v_lcur, erp._money(r.limit_value), v_lcur)""",
          label='pde amount')
t = patch(t, """'increase_pct', (t.price / t.last_price - 1) * 100, 'amount', v_net + v_vat)""",
          """'increase_pct', (t.price / t.last_price - 1) * 100, 'amount', round((v_net + v_vat) * coalesce(v_frate, 1), 2))""", label='pde inc fact')
t = patch(t, """                                 'customer_ref', nullif(btrim(h->>'customer_ref'), ''), 'comments', nullif(btrim(h->>'comments'), '')),
    'totals', jsonb_build_object('net', v_net, 'vat', v_vat, 'total', v_net + v_vat, 'currency', v_cur));""",
          """                                 'customer_ref', nullif(btrim(h->>'customer_ref'), ''), 'comments', nullif(btrim(h->>'comments'), ''),
                                 'currency', v_cur, 'fx_rate', v_frate),
    'totals', jsonb_build_object('net', v_net, 'vat', v_vat, 'total', v_net + v_vat, 'currency', v_cur, 'rate', v_frate, 'local_currency', v_lcur,
                                 'rate_overridden', coalesce((fx->>'overridden')::boolean, false),
                                 'total_lc', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'vat_lc', round(v_vat * coalesce(v_frate, 1), 2)));""", label='pde totals')
add('_pd_eval', '31_approvals.sql', ln, t + """
-- B4: the supplier's currency (or the header's), the date's rate; last prices in the document currency; amount rules in LC.""")

# ---- purchase_doc_save
t, ln = extract('21_purchasing.sql', 'erp.purchase_doc_save(')
t = patch(t, """hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', 1, (e->'totals'->>'total')::numeric,
            (e->'totals'->>'vat')::numeric, 0,""",
          """hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', (e->'totals'->>'rate')::numeric, (e->'totals'->>'total_lc')::numeric,
            (e->'totals'->>'vat_lc')::numeric, 0,""", label='pds ins')
t = patch(t, """           total = (e->'totals'->>'total')::numeric, vat_total = (e->'totals'->>'vat')::numeric,
           branch_id""", """           total = (e->'totals'->>'total_lc')::numeric, vat_total = (e->'totals'->>'vat_lc')::numeric,
           currency = e->'totals'->>'currency', fx_rate = (e->'totals'->>'rate')::numeric, total_fc = NULL, vat_total_fc = NULL,
           branch_id""", label='pds upd')
t = patch(t, """                                             base_obj_type int, base_doc_entry int, base_line int);

  INSERT INTO erp.audit_log""", """                                             base_obj_type int, base_doc_entry int, base_line int);
  PERFORM erp._sd_retotal(p_company, p_obj, v_entry);   -- B4: LC and DC totals from the lines

  INSERT INTO erp.audit_log""", label='pds retotal')
add('purchase_doc_save', '21_purchasing.sql', ln, t + "\n-- B4: header currency + rate; totals from the lines.")

# ---- GRPO: the PO's currency and rate; stock at LC
t, ln = extract('21_purchasing.sql', 'erp.purchase_grpo_create(')
t = patch(t, """  v_cur   text;
  i       integer := 0;
BEGIN
  u := erp._pd_guard(p_company, true, 'receive goods');""", """  v_cur   text;
  i       integer := 0;
  v_fxr   numeric;
BEGIN
  u := erp._pd_guard(p_company, true, 'receive goods');""", label='grpo decl')
t = patch(t, """  bl := erp._pd_base_lines(p_company, 22, p_lines, 'receiv');
""", """  bl := erp._pd_base_lines(p_company, 22, p_lines, 'receiv');
  v_fxr := erp._cur_ctx_base(p_company, 20, bl, v_date, h);   -- B4: the PO's currency and rate
""", label='grpo ctx')
t = patch(t, """            (x->>'price')::numeric, (x->>'price')::numeric,
            CASE WHEN (x->>'cbm') IS NOT NULL""", """            round((x->>'price')::numeric * v_fxr, 6), round((x->>'price')::numeric * v_fxr, 6),
            CASE WHEN (x->>'cbm') IS NOT NULL""", label='grpo cost')
t = patch(t, """    PERFORM erp._stock_move(p_company, x->>'item_code', v_whs, (x->>'qty')::numeric, 0, (x->>'price')::numeric, 20, v_entry, i, v_date);""",
          """    PERFORM erp._stock_move(p_company, x->>'item_code', v_whs, (x->>'qty')::numeric, 0, round((x->>'price')::numeric * v_fxr, 6), 20, v_entry, i, v_date);""",
          label='grpo move')
add('purchase_grpo_create', '21_purchasing.sql', ln, t + "\n-- B4: keeps the PO's currency and rate; stock comes in at the LC price (price × rate).")

# ---- A/P invoice: own date's rate; down payments drawn in the document currency
t, ln = extract('21_purchasing.sql', 'erp.purchase_invoice_create(')
t = patch(t, """  v_total numeric;
  i       integer := 0;
BEGIN
  u := erp._pd_guard(p_company, true, 'post A/P invoices', true);""", """  v_total numeric;
  i       integer := 0;
  v_fxr   numeric;
  v_isfc  boolean;
  v_alc   numeric;
  v_dlc   numeric := 0;
BEGIN
  u := erp._pd_guard(p_company, true, 'post A/P invoices', true);""", label='api decl')
t = patch(t, """  ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
    RAISE EXCEPTION 'Supplier % is billed in %. Purchasing in a foreign currency comes in a later stage.', v_card, bp.currency USING ERRCODE = 'P0001';
  END IF;""", """  END IF;
  -- B4: the goods receipts' currency at the invoice date's rate.
  v_fxr := erp._cur_ctx_base(p_company, 18, bl, v_date, h);
  v_isfc := nullif(current_setting('erp.fx_cur', true), '') IS DISTINCT FROM v_cur AND nullif(current_setting('erp.fx_cur', true), '') IS NOT NULL;
  IF v_isfc THEN
    v_cur := current_setting('erp.fx_cur', true);
  END IF;""", label='api cur')
t = patch(t, """    ELSIF dp.doc_entry = ANY (v_seen) THEN
      RAISE EXCEPTION 'Down payment invoice % is listed twice.', v_dpno USING ERRCODE = 'P0001';
    END IF;""", """    ELSIF dp.doc_entry = ANY (v_seen) THEN
      RAISE EXCEPTION 'Down payment invoice % is listed twice.', v_dpno USING ERRCODE = 'P0001';
    ELSIF coalesce(dp.currency, v_cur) <> v_cur AND (v_isfc OR dp.total_fc IS NOT NULL) THEN
      RAISE EXCEPTION 'Down payment invoice % is in %, but this A/P invoice is in %.', v_dpno, dp.currency, v_cur USING ERRCODE = 'P0001';
    END IF;""", label='api dp cur')
t = patch(t, """    v_avail := round(coalesce(dp.paid, 0) - coalesce((SELECT sum(amount) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2);""",
          """    v_avail := CASE WHEN v_isfc
                    THEN round(coalesce(dp.paid_fc, 0) - coalesce((SELECT sum(amount_fc) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2)
                    ELSE round(coalesce(dp.paid, 0) - coalesce((SELECT sum(amount) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2) END;""",
          label='api avail')
t = patch(t, """    v_drawn := v_drawn + v_amt;
    v_draws := v_draws || jsonb_build_object('dp_entry', dp.doc_entry, 'doc_no', v_dpno, 'amount', v_amt);""",
          """    v_drawn := v_drawn + v_amt;
    -- B4: in a foreign currency the draw's LC is at the down payment's own rate (the whole LC rest when it is drawn in full).
    v_alc := CASE WHEN NOT v_isfc THEN v_amt
                  WHEN v_amt >= v_avail THEN round(coalesce(dp.paid, 0) - coalesce((SELECT sum(amount) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2)
                  ELSE round(v_amt * coalesce(dp.paid, 0) / nullif(dp.paid_fc, 0), 2) END;
    v_dlc := v_dlc + v_alc;
    v_draws := v_draws || jsonb_build_object('dp_entry', dp.doc_entry, 'doc_no', v_dpno, 'amount', v_amt, 'amount_lc', v_alc);""", label='api draw')
t = patch(t, """  INSERT INTO erp.ap_dp_draw (company_code, invoice_entry, dp_entry, amount)
  SELECT p_company, v_entry, (y->>'dp_entry')::integer, (y->>'amount')::numeric FROM jsonb_array_elements(v_draws) y;""",
          """  INSERT INTO erp.ap_dp_draw (company_code, invoice_entry, dp_entry, amount, amount_fc)
  SELECT p_company, v_entry, (y->>'dp_entry')::integer, (y->>'amount_lc')::numeric, CASE WHEN v_isfc THEN (y->>'amount')::numeric END
    FROM jsonb_array_elements(v_draws) y;""", label='api draw ins')
t = patch(t, """  UPDATE erp.document SET total = round(total - v_drawn, 2)""",
          """  UPDATE erp.document SET total = round(total - v_dlc, 2), total_fc = CASE WHEN v_isfc THEN round(total_fc - v_drawn, 2) ELSE total_fc END""", label='api total')
add('purchase_invoice_create', '21_purchasing.sql', ln, t + """
-- B4: foreign-currency A/P invoices at the invoice date's rate (the goods receipt difference is posted by post_document);
-- down payments of the same currency are drawn in that currency, their LC at the down payment's rate.""")

# ---- deposit (204): the PO's currency, the deposit date's rate
t, ln = extract('21_purchasing.sql', 'erp.purchase_deposit_create(')
t = patch(t, """  v_cur   text;
BEGIN
  u := erp._pd_guard(p_company, true, 'raise deposits');""", """  v_cur   text;
  v_lcur  text;
  v_fxr   numeric := 1;
  v_pot   numeric;
  fx      jsonb;
BEGIN
  u := erp._pd_guard(p_company, true, 'raise deposits');""", label='dep decl')
t = patch(t, """  v_date := erp._sd_doc_date(h);
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL OR v_due < v_date THEN""", """  v_date := erp._sd_doc_date(h);
  -- B4: amounts in the order's currency; the deposit takes its own date's rate.
  v_lcur := v_cur;
  v_cur := coalesce(d.currency, v_lcur);
  v_pot := CASE WHEN v_cur <> v_lcur THEN d.total_fc ELSE d.total END;
  IF v_cur <> v_lcur THEN
    fx := erp._cur_pick(p_company, d.card_code, NULL, v_cur, h->>'fx_rate', v_date, 'Supplier');
    IF fx->>'error' IS NOT NULL THEN
      RAISE EXCEPTION '%', fx->>'error' USING ERRCODE = 'P0001';
    END IF;
    v_fxr := (fx->>'rate')::numeric;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL OR v_due < v_date THEN""", label='dep cur')
t = patch(t, """    v_amt := round(d.total * v_pct / 100, 2);""", """    v_amt := round(v_pot * v_pct / 100, 2);""", label='dep pct')
t = patch(t, """  SELECT coalesce(sum(dd.total), 0) INTO v_prev""", """  SELECT coalesce(sum(CASE WHEN v_cur <> v_lcur THEN dd.total_fc ELSE dd.total END), 0) INTO v_prev""", label='dep prev')
t = patch(t, """  IF v_prev + v_amt > d.total THEN
    RAISE EXCEPTION '%', format('Deposits on %s would be %s %s, more than the order total of %s %s (%s %s already raised).',
      w.doc_no, erp._money(v_prev + v_amt), v_cur, erp._money(d.total), v_cur, erp._money(v_prev), v_cur) USING ERRCODE = 'P0001';""",
          """  IF v_prev + v_amt > v_pot THEN
    RAISE EXCEPTION '%', format('Deposits on %s would be %s %s, more than the order total of %s %s (%s %s already raised).',
      w.doc_no, erp._money(v_prev + v_amt), v_cur, erp._money(v_pot), v_cur, erp._money(v_prev), v_cur) USING ERRCODE = 'P0001';""", label='dep max')
t = patch(t, """coalesce((SELECT vendor_pi_no FROM erp.purchase_pi WHERE pi_id = v_pi), d.customer_ref), v_cur, 1, v_amt, 0, 0, d.branch_id,""",
          """coalesce((SELECT vendor_pi_no FROM erp.purchase_pi WHERE pi_id = v_pi), d.customer_ref), v_cur, v_fxr, round(v_amt * v_fxr, 2), 0, 0, d.branch_id,""", label='dep ins')
t = patch(t, """  VALUES (p_company, 204, v_entry, 0, format('Deposit for %s', w.doc_no), 1, 0, v_amt, v_cur, 0, v_amt, 0, 'C', 22, p_po);
  v_trans := erp.post_document(p_company, 204, v_entry);
  PERFORM erp._bp_balance_add(p_company, d.card_code, -v_amt);""",
          """  VALUES (p_company, 204, v_entry, 0, format('Deposit for %s', w.doc_no), 1, 0, v_amt, v_cur, 0, v_amt, 0, 'C', 22, p_po);
  PERFORM erp._sd_retotal(p_company, 204, v_entry);
  v_trans := erp.post_document(p_company, 204, v_entry);
  PERFORM erp._bp_balance_add(p_company, d.card_code, -round(v_amt * v_fxr, 2));""", label='dep line')
add('purchase_deposit_create', '21_purchasing.sql', ln, t + "\n-- B4: deposits in the order's currency at the deposit date's rate.")

# ---- post_document: A/P invoice from goods receipts in a foreign currency
t, ln = extract('32_gl_setup.sql', 'erp.post_document(')
t = patch(t, """  v_name  text;
  v_ref   text;
BEGIN""", """  v_name  text;
  v_ref   text;
  v_grni  numeric;
BEGIN""", label='pd decl')
t = patch(t, """    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'debit', round(v_net, 2)));
    v_lines := v_lines || coalesce((
      SELECT jsonb_agg(jsonb_build_object('acct_code', v_vat, 'debit', round(t.vat, 2), 'tax_code', t.tax_code) ORDER BY t.tax_code)
        FROM (SELECT tax_code, sum(vat) AS vat FROM erp.document_line
               WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry GROUP BY tax_code HAVING sum(vat) <> 0) t), '[]'::jsonb);""",
          """    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'debit', round(v_net, 2)));
    -- B4: a foreign-currency invoice clears goods received / not invoiced at the goods receipts' LC value; the rate difference
    -- goes to exchange rate losses (more LC than received) or gains (less).
    IF d.total_fc IS NOT NULL THEN
      SELECT coalesce(sum(round(l.quantity * g.stock_price, 2)), 0) INTO v_grni
        FROM erp.document_line l
        JOIN erp.document_line g ON g.company_code = l.company_code AND g.obj_type = 20 AND g.doc_entry = l.base_doc_entry AND g.line_num = l.base_line
       WHERE l.company_code = p_company AND l.obj_type = 18 AND l.doc_entry = p_doc_entry AND l.base_obj_type = 20;
      IF v_grni > 0 AND v_grni <> round(v_net, 2) THEN
        v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'debit', v_grni,
                                       'fc_debit', (SELECT sum(line_total_fc) FROM erp.document_line WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry)),
          CASE WHEN round(v_net, 2) > v_grni
               THEN jsonb_build_object('acct_code', erp.gl_account(p_company, 'purchasing', 'fx_loss'), 'debit', round(v_net, 2) - v_grni, 'fc_debit', 0, 'fc_credit', 0, 'memo', 'Exchange rate difference to the goods receipt')
               ELSE jsonb_build_object('acct_code', erp.gl_account(p_company, 'sales', 'fx_gain'), 'credit', v_grni - round(v_net, 2), 'fc_debit', 0, 'fc_credit', 0, 'memo', 'Exchange rate difference to the goods receipt') END);
      END IF;
    END IF;
    v_lines := v_lines || coalesce((
      SELECT jsonb_agg(jsonb_build_object('acct_code', v_vat, 'debit', round(t.vat, 2), 'tax_code', t.tax_code) ORDER BY t.tax_code)
        FROM (SELECT tax_code, sum(vat) AS vat FROM erp.document_line
               WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry GROUP BY tax_code HAVING sum(vat) <> 0) t), '[]'::jsonb);""",
          label='pd 18 grni')
t = patch(t, """      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'debit', round(v_drawn, 2), 'memo', 'Down payment drawn'),
                                              jsonb_build_object('acct_code', v_dp, 'credit', round(v_drawn, 2), 'memo', 'Down payment drawn'));""",
          """      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'debit', round(v_drawn, 2), 'memo', 'Down payment drawn',
                                                                 'fc_debit', (SELECT sum(amount_fc) FROM erp.ap_dp_draw WHERE company_code = p_company AND invoice_entry = p_doc_entry)),
                                              jsonb_build_object('acct_code', v_dp, 'credit', round(v_drawn, 2), 'memo', 'Down payment drawn',
                                                                 'fc_credit', (SELECT sum(amount_fc) FROM erp.ap_dp_draw WHERE company_code = p_company AND invoice_entry = p_doc_entry)));""", label='pd 18 draw')
add('post_document', '32_gl_setup.sql', ln, t + """
-- B4: unchanged for local-currency documents; a foreign-currency A/P invoice clears GRNI at the goods receipt value and posts
-- the rate difference (purchasing / fx_loss, sales / fx_gain). post_journal fills the FC amounts of every line.""")

# ---- copy sources: currency and rate of the base
t, ln = extract('30_numbering_company.sql', 'erp.sales_copy_source(')
t = patch(t, """'whs_code', w.whs_code, 'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency) END,""",
          """'whs_code', w.whs_code, 'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'fx_rate', d.fx_rate) END,""", label='scs head')
t = patch(t, """               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cost', l.stock_price,""",
          """               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cost', l.stock_price,
               'currency', ld.currency, 'fx_rate', ld.fx_rate, 'line_total_fc', l.line_total_fc, 'vat_fc', l.vat_fc,""", label='scs line')
add('sales_copy_source', '30_numbering_company.sql', ln, t + "\n-- B4: + currency and rate of the base (header and lines).")

t, ln = extract('21_purchasing.sql', 'erp.purchase_copy_source(')
t = patch(t, """'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'total', d.total) END,""",
          """'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'total', d.total, 'fx_rate', d.fx_rate,
                'total_fc', d.total_fc) END,""", label='pcs head')
t = patch(t, """               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cbm', l.cbm, 'cost', l.stock_price, 'is_stock', true,""",
          """               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cbm', l.cbm, 'cost', l.stock_price, 'is_stock', true,
               'currency', ld.currency, 'fx_rate', ld.fx_rate, 'line_total_fc', l.line_total_fc, 'vat_fc', l.vat_fc,""", label='pcs line')
add('purchase_copy_source', '21_purchasing.sql', ln, t + "\n-- B4: + currency and rate of the base.")

out.append((ART / 'part2.sql').read_text())

# ================================================================ 8. Payments
out.append("""
-- ============ 8. Payments in the documents' currency, realised FX gain / loss ============""")

t, ln = extract('31_approvals.sql', 'erp._pay_eval(')
t = patch(t, """  r        record;
  k        integer := 0;
BEGIN""", """  r        record;
  k        integer := 0;
  v_lc     text;
  v_rate   numeric := 1;
  fx       jsonb;
BEGIN""", label='pe decl')
t = patch(t, """    ELSIF bp.currency IS NOT NULL AND bp.currency NOT IN (v_cur, '##') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message',
        format('%s %s is billed in %s. Payments in a foreign currency come in a later stage.', v_partyc, v_card, bp.currency));
""", "", label='pe refuse')
t = patch(t, """  -- Means of payment
  v_cash :=""", """  -- B4: payment currency (the partner's, or the header's) and the payment date's rate. v_cur becomes the payment currency.
  v_lc := v_cur;
  fx := erp._cur_pick(p_company, v_card, bp.currency, h->>'currency', h->>'fx_rate', v_date, v_partyc,
                      CASE WHEN p_draft_id IS NOT NULL THEN erp._num(h->>'fx_rate') END);   -- a waiting draft keeps the rate it was checked with
  IF fx->>'error' IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', fx->>'field', 'message', fx->>'error');
  END IF;
  v_cur := fx->>'currency';
  v_rate := coalesce((fx->>'rate')::numeric, CASE WHEN v_cur = v_lc THEN 1 END);

  -- Means of payment
  v_cash :=""", label='pe cur')
t = patch(t, """    ELSIF (v_obj || ':' || v_entry) = ANY (v_seen) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is listed twice.', v_noun, v_no));""",
          """    ELSIF (v_obj || ':' || v_entry) = ANY (v_seen) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is listed twice.', v_noun, v_no));
    ELSIF coalesce(d.currency, v_lc) <> v_cur THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is in %s, but this payment is in %s. Pay each currency''s documents in their own currency.',
        v_noun, v_no, coalesce(d.currency, v_lc), v_cur));""", label='pe doc cur')
t = patch(t, """      v_open := erp._bk_doc_open(p_company, v_obj, v_entry);""",
          """      v_open := CASE WHEN v_cur = v_lc THEN erp._bk_doc_open(p_company, v_obj, v_entry) ELSE erp._bk_doc_open_fc(p_company, v_obj, v_entry) END;""", label='pe open')
t = patch(t, """'doc_date', d.doc_date, 'due_date', d.due_date, 'total', d.total);""",
          """'doc_date', d.doc_date, 'due_date', d.due_date, 'total', CASE WHEN v_cur = v_lc THEN d.total ELSE d.total_fc END,
                                             'fx_rate', d.fx_rate);""", label='pe line')
t = patch(t, """      IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_total)) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', v_total, 'limit', r.limit_value,
          'message', erp._apr_msg(format('Incoming payment %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds)));""",
          """      IF erp._apr_hit(r.conds, jsonb_build_object('amount', round(v_total * coalesce(v_rate, 1), 2))) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', round(v_total * coalesce(v_rate, 1), 2), 'limit', r.limit_value,
          'message', erp._apr_msg(format('Incoming payment %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds)));""", label='pe in rule')
t = patch(t, """      IF erp._apr_hit(r.conds, jsonb_build_object('amount', v_total)) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', v_total, 'limit', r.limit_value,
          'message', CASE WHEN r.std THEN format('Payment %s %s is above your payment limit of %s %s.', erp._money(v_total), v_cur, erp._money(r.limit_value), v_cur)""",
          """      IF erp._apr_hit(r.conds, jsonb_build_object('amount', round(v_total * coalesce(v_rate, 1), 2))) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', round(v_total * coalesce(v_rate, 1), 2), 'limit', r.limit_value,
          'message', CASE WHEN r.std THEN format('Payment %s %s is above your payment limit of %s %s.', erp._money(round(v_total * coalesce(v_rate, 1), 2)), v_lc, erp._money(r.limit_value), v_lc)""",
          label='pe out rule')
t = patch(t, """'days_since_change', extract(epoch FROM now() - v_changed) / 86400, 'amount', v_total))""",
          """'days_since_change', extract(epoch FROM now() - v_changed) / 86400, 'amount', round(v_total * coalesce(v_rate, 1), 2)))""", label='pe bank rule')
t = patch(t, """                                 'cheque_bank', CASE WHEN v_ct > 0 AND NOT v_in THEN v_cbank END, 'card', v_cd, 'card_ref', nullif(btrim(h->>'card_ref'), '')),
    'totals', jsonb_build_object('total', v_total, 'applied', v_applied, 'on_account', round(v_total - v_applied, 2), 'currency', v_cur));""",
          """                                 'cheque_bank', CASE WHEN v_ct > 0 AND NOT v_in THEN v_cbank END, 'card', v_cd, 'card_ref', nullif(btrim(h->>'card_ref'), ''),
                                 'currency', v_cur, 'fx_rate', v_rate),
    'totals', jsonb_build_object('total', v_total, 'applied', v_applied, 'on_account', round(v_total - v_applied, 2), 'currency', v_cur,
                                 'rate', v_rate, 'local_currency', v_lc, 'rate_overridden', coalesce((fx->>'overridden')::boolean, false),
                                 'total_lc', round(v_total * coalesce(v_rate, 1), 2)));""", label='pe totals')
add('_pay_eval', '31_approvals.sql', ln, t + """
-- B4: payments in the partner's currency (all documents of that currency) at the payment date's rate; open amounts and
-- allocations in that currency; approval amounts in LC.""")

t, ln = extract('30_numbering_company.sql', 'erp._pay_post(')
t = patch(t, """  v_memo  text;
  x       jsonb;
BEGIN
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;""", """  v_memo  text;
  x       jsonb;
  v_lc    text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_rate  numeric := coalesce((e->'totals'->>'rate')::numeric, 1);
  v_isfc  boolean;
  hfc     jsonb := e->'header';
  efc     jsonb := e;
  v_ctl_amt numeric;
  v_fxd   numeric := 0;
  v_onlc  numeric;
BEGIN
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;
  -- B4: a foreign-currency payment is posted in LC: the money at the payment rate (each means / cheque rounded), each
  -- document cleared at its own LC (_cur_clear_lc), on account at the payment rate; the difference is the FX gain / loss.
  v_isfc := v_cur IS DISTINCT FROM v_lc;
  v_ctl_amt := v_total;
  IF v_isfc THEN
    h := h || jsonb_build_object('cash', round((h->>'cash')::numeric * v_rate, 2), 'transfer', round((h->>'transfer')::numeric * v_rate, 2),
                                 'card', round((h->>'card')::numeric * v_rate, 2),
                                 'cheques', coalesce((SELECT jsonb_agg(c.v || jsonb_build_object('amount', round((c.v->>'amount')::numeric * v_rate, 2), 'amount_fc', c.v->'amount') ORDER BY c.ord)
                                                        FROM jsonb_array_elements(h->'cheques') WITH ORDINALITY AS c(v, ord)), '[]'::jsonb));
    h := h || jsonb_build_object('cheque_total', (SELECT coalesce(sum((c->>'amount')::numeric), 0) FROM jsonb_array_elements(h->'cheques') c));
    v_total := round((h->>'cash')::numeric + (h->>'transfer')::numeric + (h->>'cheque_total')::numeric + (h->>'card')::numeric, 2);
    e := jsonb_set(e, '{lines}', coalesce((SELECT jsonb_agg(l || jsonb_build_object('amount_fc', l->'amount',
                                                 'amount', erp._cur_clear_lc(p_company, (l->>'obj_type')::integer, (l->>'doc_entry')::integer, (l->>'amount')::numeric))
                                                 ORDER BY (l->>'line_no')::integer)
                                             FROM jsonb_array_elements(e->'lines') l), '[]'::jsonb));
    v_onlc := round((efc->'totals'->>'on_account')::numeric * v_rate, 2);
    e := jsonb_set(e, '{totals,on_account}', to_jsonb(v_onlc));
    v_ctl_amt := round(coalesce((SELECT sum((l->>'amount')::numeric * (l->>'sign')::integer) FROM jsonb_array_elements(e->'lines') l), 0) + v_onlc, 2);
    v_fxd := round(v_total - v_ctl_amt, 2);   -- incoming: + gain; outgoing: + loss
  END IF;""", label='pp fc')
t = patch(t, """          h->>'card_name', v_cur, 1, v_total,""", """          h->>'card_name', v_cur, v_rate, v_total,""", label='pp rate')
t = patch(t, """  INSERT INTO erp.payment_extra (company_code, direction, doc_entry, doc_no, transfer_bank, transfer_ref, cheque_bank, card_ref, draft_id, created_by)""",
          """  IF v_isfc THEN
    UPDATE erp.payment SET total_fc = (efc->'totals'->>'total')::numeric, on_account_fc = (efc->'totals'->>'on_account')::numeric,
                           fx_diff = CASE WHEN v_in THEN v_fxd ELSE -v_fxd END
     WHERE company_code = p_company AND direction = p_dir AND doc_entry = v_entry;
  END IF;
  INSERT INTO erp.payment_extra (company_code, direction, doc_entry, doc_no, transfer_bank, transfer_ref, cheque_bank, card_ref, draft_id, created_by)""", label='pp fc row')
t = patch(t, """  INSERT INTO erp.payment_cheque (company_code, direction, doc_entry, line_no, cheque_no, bank_name, due_date, amount)
  SELECT p_company, p_dir, v_entry, (c.ord - 1)::smallint, c.v->>'cheque_no', c.v->>'bank_name', (c.v->>'due_date')::date, (c.v->>'amount')::numeric""",
          """  INSERT INTO erp.payment_cheque (company_code, direction, doc_entry, line_no, cheque_no, bank_name, due_date, amount, amount_fc)
  SELECT p_company, p_dir, v_entry, (c.ord - 1)::smallint, c.v->>'cheque_no', c.v->>'bank_name', (c.v->>'due_date')::date, (c.v->>'amount')::numeric,
         (c.v->>'amount_fc')::numeric""", label='pp cheque')
t = patch(t, """  INSERT INTO erp.payment_allocation (company_code, direction, doc_entry, line_no, target_obj_type, target_doc_entry, applied)
  SELECT p_company, p_dir, v_entry, (l->>'line_no')::integer, (l->>'obj_type')::integer, (l->>'doc_entry')::integer, (l->>'amount')::numeric""",
          """  INSERT INTO erp.payment_allocation (company_code, direction, doc_entry, line_no, target_obj_type, target_doc_entry, applied, applied_fc)
  SELECT p_company, p_dir, v_entry, (l->>'line_no')::integer, (l->>'obj_type')::integer, (l->>'doc_entry')::integer, (l->>'amount')::numeric,
         (l->>'amount_fc')::numeric""", label='pp alloc')
t = patch(t, """    UPDATE erp.document SET paid = round(coalesce(paid, 0) + (x->>'amount')::numeric, 6)""",
          """    UPDATE erp.document SET paid = round(coalesce(paid, 0) + (x->>'amount')::numeric, 6),
                            paid_fc = CASE WHEN x ? 'amount_fc' THEN round(coalesce(paid_fc, 0) + (x->>'amount_fc')::numeric, 6) ELSE paid_fc END""", label='pp paid')
t = patch(t, """'short_name', h->>'card_code', v_oside, v_total)""", """'short_name', h->>'card_code', v_oside, v_ctl_amt)""", count=2, label='pp ctl')
t = patch(t, """  v_memo := format('%s %s · %s', erp._bk_name(v_obj), nb->>'no', coalesce(h->>'card_name', h->>'card_code'));
  v_trans := erp.post_journal(p_company, (h->>'doc_date')::date, v_memo, v_lines,
    jsonb_build_object('trans_type', v_obj, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'ref2', h->>'transfer_ref', 'allow_control', true,
                       'action', 'payment_post', 'object', 'payment', 'object_ref', p_dir || '/' || v_entry));""",
          """  IF v_isfc THEN
    -- FC amounts of the lines: each means of payment as entered, the partner line = what it cleared in the documents' currency.
    v_lines := (SELECT jsonb_agg(CASE WHEN l->>'short_name' = h->>'card_code'
                                      THEN l || jsonb_build_object('fc_' || v_oside, round(coalesce((SELECT sum((a->>'amount_fc')::numeric * (a->>'sign')::integer) FROM jsonb_array_elements(e->'lines') a), 0)
                                                                                    + coalesce((efc->'totals'->>'on_account')::numeric, 0), 2), 'fc_' || v_side, 0)
                                      ELSE l || jsonb_build_object('fc_' || v_side,
                                             CASE WHEN l->>'memo' = 'Cash' THEN (hfc->>'cash')::numeric WHEN l->>'memo' LIKE 'Transfer%' THEN (hfc->>'transfer')::numeric
                                                  WHEN l->>'memo' LIKE 'Cheques%' THEN (hfc->>'cheque_total')::numeric WHEN l->>'memo' LIKE 'Card%' THEN (hfc->>'card')::numeric END,
                                             'fc_' || v_oside, 0) END ORDER BY x.ord)
                   FROM jsonb_array_elements(v_lines) WITH ORDINALITY AS x(l, ord));
  END IF;
  IF v_isfc AND v_fxd <> 0 THEN
    -- Realised exchange rate difference: incoming more LC than the invoices carried = gain; outgoing more LC = loss.
    v_lines := v_lines || CASE WHEN (v_in AND v_fxd > 0) OR (NOT v_in AND v_fxd < 0)
      THEN jsonb_build_object('acct_code', erp.gl_account(p_company, 'sales', 'fx_gain'), 'credit', abs(v_fxd), 'fc_debit', 0, 'fc_credit', 0, 'memo', 'Exchange rate gain')
      ELSE jsonb_build_object('acct_code', erp.gl_account(p_company, 'purchasing', 'fx_loss'), 'debit', abs(v_fxd), 'fc_debit', 0, 'fc_credit', 0, 'memo', 'Exchange rate loss') END;
  END IF;
  v_memo := format('%s %s · %s', erp._bk_name(v_obj), nb->>'no', coalesce(h->>'card_name', h->>'card_code'));
  v_trans := erp.post_journal(p_company, (h->>'doc_date')::date, v_memo, v_lines,
    jsonb_build_object('trans_type', v_obj, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'ref2', h->>'transfer_ref', 'allow_control', true,
                       'action', 'payment_post', 'object', 'payment', 'object_ref', p_dir || '/' || v_entry,
                       'fc_currency', CASE WHEN v_isfc THEN v_cur END, 'fc_rate', CASE WHEN v_isfc THEN v_rate END));""", label='pp fx line')
t = patch(t, """  PERFORM erp._bp_balance_add(p_company, h->>'card_code', CASE WHEN v_in THEN -v_total ELSE v_total END);""",
          """  PERFORM erp._bp_balance_add(p_company, h->>'card_code', CASE WHEN v_in THEN -v_ctl_amt ELSE v_ctl_amt END);""", label='pp bp')
t = patch(t, """'allocations', jsonb_array_length(e->'lines'), 'trans_id', v_trans, 'draft_id', p_draft_id));""",
          """'allocations', jsonb_array_length(e->'lines'), 'trans_id', v_trans, 'draft_id', p_draft_id,
                             'currency', v_cur, 'rate', CASE WHEN v_isfc THEN v_rate END, 'total_fc', CASE WHEN v_isfc THEN efc->'totals'->'total' END,
                             'fx_diff', CASE WHEN v_isfc THEN v_fxd END));""", label='pp audit')
t = patch(t, """  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'trans_id', v_trans, 'total', v_total, 'on_account', e->'totals'->'on_account');""",
          """  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'trans_id', v_trans, 'total', v_total, 'on_account', e->'totals'->'on_account',
                            'currency', v_cur, 'total_fc', CASE WHEN v_isfc THEN efc->'totals'->'total' END, 'fx_diff', CASE WHEN v_isfc THEN v_fxd END);""", label='pp ret')
add('_pay_post', '30_numbering_company.sql', ln, t + """
-- B4: foreign-currency payments: LC journal with FC amounts, documents cleared at their own LC, realised FX gain / loss
-- (sales / fx_gain, purchasing / fx_loss), paid_fc / applied_fc / total_fc / fx_diff kept.""")

t, ln = extract('20_banking.sql', 'erp.payment_cancel(')
t = patch(t, """    UPDATE erp.document SET paid = round(greatest(coalesce(paid, 0) - a.applied, 0), 6)""",
          """    UPDATE erp.document SET paid = round(greatest(coalesce(paid, 0) - a.applied, 0), 6),
                            paid_fc = CASE WHEN a.applied_fc IS NOT NULL THEN round(greatest(coalesce(paid_fc, 0) - a.applied_fc, 0), 6) ELSE paid_fc END""", label='pc paid')
t = patch(t, """  PERFORM erp._bp_balance_add(p_company, p.card_code, CASE WHEN p_dir = 'I' THEN p.total ELSE -p.total END);""",
          """  PERFORM erp._bp_balance_add(p_company, p.card_code, CASE WHEN p_dir = 'I' THEN p.total - coalesce(p.fx_diff, 0) ELSE -(p.total + coalesce(p.fx_diff, 0)) END);""",
          label='pc bp')
add('payment_cancel', '20_banking.sql', ln, t + "\n-- B4: foreign-currency amounts given back too; the partner balance moves by what the payment cleared.")

t, ln = extract('20_banking.sql', 'erp.payment_open_docs(')
t = patch(t, """    'card_code', bp.card_code, 'card_name', bp.name, 'currency', bp.currency,""",
          """    'card_code', bp.card_code, 'card_name', bp.name, 'currency', bp.currency,
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),""", label='pod head')
t = patch(t, """                                  'doc_date', d.doc_date, 'due_date', coalesce(d.due_date, d.doc_date), 'total', d.total,
                                  'open', erp._bk_doc_open(p_company, d.obj_type, d.doc_entry),""",
          """                                  'doc_date', d.doc_date, 'due_date', coalesce(d.due_date, d.doc_date),
                                  'total', CASE WHEN d.total_fc IS NOT NULL THEN d.total_fc ELSE d.total END, 'total_lc', d.total,
                                  'currency', coalesce(d.currency, (SELECT currency FROM erp.company WHERE company_code = p_company)), 'fx_rate', d.fx_rate,
                                  'open', coalesce(erp._bk_doc_open_fc(p_company, d.obj_type, d.doc_entry), erp._bk_doc_open(p_company, d.obj_type, d.doc_entry)),
                                  'open_lc', erp._bk_doc_open(p_company, d.obj_type, d.doc_entry),""", label='pod docs')
add('payment_open_docs', '20_banking.sql', ln, t + "\n-- B4: each document's currency; total and open in that currency (open_lc / total_lc in LC).")

t, ln = extract('20_banking.sql', 'erp.payment_info(')
t = patch(t, """'doc_no', erp._sd_no(p_company, a.target_obj_type, a.target_doc_entry), 'applied', a.applied,""",
          """'doc_no', erp._sd_no(p_company, a.target_obj_type, a.target_doc_entry), 'applied', a.applied, 'applied_fc', a.applied_fc,""", label='pi alloc')
add('payment_info', '20_banking.sql', ln, t + "\n-- B4: + applied_fc.")

# ---- item form: each item group's batch / serial method (B3 follow-up: the form prefills it)
t, ln = extract('23_master_data.sql', 'erp.master_data_setup(')
t = patch(t, """    'item_groups', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', group_code, 'name', name) ORDER BY group_code), '[]'::jsonb)""",
          """    'item_groups', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', group_code, 'name', name,
                                     'manage_method', (SELECT s.manage_method FROM erp.item_group_setting s
                                                        WHERE s.company_code = item_group.company_code AND s.group_code = item_group.group_code)) ORDER BY group_code), '[]'::jsonb)""", label='mds groups')
add('master_data_setup', '23_master_data.sql', ln, t + "\n-- B4: item groups carry their management method (none / batch / serial) for the item form.")

# ================================================================ health
t, ln = extract('32_gl_setup.sql', 'erp._health_files(')
t = patch(t, "('32_gl_setup.sql', 'gl_setup')", "('32_gl_setup.sql', 'gl_setup'),\n    ('33_multicurrency.sql', 'currency_rate')", label='health')
add('_health_files', '32_gl_setup.sql', ln, t + "\n-- B4: + 33_multicurrency.sql (marker currency_rate).")

out.append((ART / 'part3.sql').read_text())

target = SQL / '33_multicurrency.sql'
text = '\n'.join(out).rstrip() + '\n'
if CHECK:
    same = target.exists() and target.read_text() == text
    print('identical' if same else 'DIFFERENT', target)
    sys.exit(0 if same else 1)
target.write_text(text)
print('wrote', target, sum(1 for _ in target.open()))
