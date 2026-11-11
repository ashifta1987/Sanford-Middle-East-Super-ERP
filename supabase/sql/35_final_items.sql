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


-- ---- Landed cost functions with the vendor per cost line.

-- ---- _lc_eval: copied from 34_open_items.sql:665.
CREATE OR REPLACE FUNCTION erp._lc_eval(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_chg    jsonb := CASE WHEN jsonb_typeof(p_charges) = 'array' THEN p_charges ELSE '[]'::jsonb END;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  v_date   date;
  v_cur    text;
  x        jsonb;
  ln       jsonb;
  d        erp.document;
  gl       erp.document_line;
  lc       erp.landed_cost_code;
  v_out    jsonb := '[]';
  v_charges jsonb := '[]';
  v_allocs jsonb := '[]';
  v_seen   text[] := '{}';
  v_codes  text[] := '{}';
  v_no     text;
  v_w      numeric;
  v_cbm    numeric;
  i        integer := 0;
  k        integer := 0;
  v_amt    numeric;
  v_sum    numeric;
  v_last   integer;
  v_acc    numeric;
  v_a      numeric;
  v_b      numeric;
  v_alloc  numeric[];
  v_total  numeric := 0;
  v_key    text;
  v_pool   jsonb := '{}';
  v_avgm   jsonb := '{}';
  v_oh     numeric;
  v_avg    numeric;
  v_share  numeric;
  v_inv    numeric;
  v_after  numeric;
  v_ti     numeric := 0;
  v_tc     numeric := 0;
  v_res    jsonb := '[]';
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
  v_vend   text;
  v_vcur   text;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  v_date := erp._sd_doc_date(h);
  IF v_card IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card AND kind = 'supplier') THEN
    RAISE EXCEPTION 'Supplier % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one goods receipt line.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(v_chg) = 0 THEN
    RAISE EXCEPTION 'Add at least one landed cost.' USING ERRCODE = 'P0001';
  END IF;

  -- Lines
  FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = 20 AND doc_entry = erp._num(x->>'grpo_entry')::integer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Line %: goods receipt % was not found in company %.', i, coalesce(x->>'grpo_entry', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    v_no := erp._sd_no(p_company, 20, d.doc_entry);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION 'Line %: goods receipt % came from %. Landed costs work on Super ERP goods receipts only.', i, v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    ELSIF d.status = 'cancelled' THEN
      RAISE EXCEPTION 'Line %: goods receipt % is cancelled.', i, v_no USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO gl FROM erp.document_line WHERE company_code = p_company AND obj_type = 20 AND doc_entry = d.doc_entry
                                                AND line_num = erp._num(x->>'grpo_line')::integer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Line %: goods receipt % has no line %.', i, v_no, coalesce((erp._num(x->>'grpo_line') + 1)::text, '(none)') USING ERRCODE = 'P0001';
    END IF;
    IF (d.doc_entry || ':' || gl.line_num) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Line %: line % of goods receipt % is listed twice.', i, gl.line_num + 1, v_no USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || (d.doc_entry || ':' || gl.line_num);
    v_w := NULL;
    IF nullif(btrim(x->>'weight'), '') IS NOT NULL THEN
      v_w := erp._num(x->>'weight');
      IF v_w IS NULL OR v_w < 0 THEN
        RAISE EXCEPTION 'Line %: weight must be a number of 0 or more.', i USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_cbm := gl.cbm;
    IF nullif(btrim(x->>'cbm'), '') IS NOT NULL THEN
      v_cbm := erp._num(x->>'cbm');
      IF v_cbm IS NULL OR v_cbm < 0 THEN
        RAISE EXCEPTION 'Line %: volume (CBM) must be a number of 0 or more.', i USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_out := v_out || jsonb_build_object('line_num', i - 1, 'grpo_entry', d.doc_entry, 'grpo_line', gl.line_num, 'grpo_no', v_no,
      'item_code', gl.item_code, 'description', gl.description, 'whs_code', gl.whs_code, 'qty', gl.quantity,
      'value', CASE WHEN gl.line_total_fc IS NOT NULL THEN round(gl.quantity * coalesce(gl.stock_price, gl.price * coalesce(d.fx_rate, 1)), 2)
                    ELSE round(gl.quantity * gl.price, 2) END,
      'cbm', v_cbm, 'weight', v_w,
      'price', CASE WHEN gl.line_total_fc IS NOT NULL THEN coalesce(gl.stock_price, round(gl.price * coalesce(d.fx_rate, 1), 6)) ELSE gl.price END);
  END LOOP;

  -- Charges: split each one exactly.
  FOR x IN SELECT value FROM jsonb_array_elements(v_chg) LOOP
    k := k + 1;
    SELECT * INTO lc FROM erp.landed_cost_code WHERE company_code = p_company AND code = nullif(btrim(x->>'code'), '');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Landed cost %: code % is not set up for %. Ask Purchasing to add it in Purchasing › Purchasing Setup.',
        k, coalesce(nullif(btrim(x->>'code'), ''), '(none)'), p_company USING ERRCODE = 'P0001';
    ELSIF NOT lc.active THEN
      RAISE EXCEPTION 'Landed cost %: code % is inactive.', k, lc.code USING ERRCODE = 'P0001';
    ELSIF lc.code = ANY (v_codes) THEN
      RAISE EXCEPTION 'Landed cost %: code % is listed twice. Add the amounts together.', k, lc.code USING ERRCODE = 'P0001';
    END IF;
    v_codes := v_codes || lc.code::text;
    v_amt := erp._num(x->>'amount');
    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'Landed cost % (%): enter an amount above 0.', k, lc.name USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(v_amt, 2);
    -- B5: the charge's currency (rate of the landed cost date) and the broker's A/P invoice it is billed on.
    v_ccur := upper(coalesce(nullif(btrim(x->>'currency'), ''), v_cur));
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
      ELSIF v_vend IS NOT NULL AND ap.card_code <> v_vend THEN
        RAISE EXCEPTION 'Landed cost % (%): A/P invoice % is from %, not from the vendor %.', k, lc.name, v_apno, ap.card_code, v_vend USING ERRCODE = 'P0001';
      ELSIF v_vend IS NULL AND v_card IS NOT NULL AND ap.card_code <> v_card THEN
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
      v_vend := coalesce(v_vend, ap.card_code);      -- B6: the invoice's supplier is the cost line's vendor
    END IF;
    v_ctot := v_ctot + v_clear;
    v_sum := 0;
    v_last := NULL;
    FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
      ln := v_out->j;
      v_b := coalesce(CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END, 0);
      v_sum := v_sum + v_b;
      IF v_b > 0 THEN v_last := j; END IF;
    END LOOP;
    IF v_sum <= 0 THEN
      RAISE EXCEPTION 'Landed cost % (%) is split by %, but none of the lines has %. Enter it on the lines.', k, lc.name,
        CASE lc.split_method WHEN 'cbm' THEN 'volume (CBM)' WHEN 'qty' THEN 'quantity' WHEN 'value' THEN 'value' ELSE 'weight' END,
        CASE lc.split_method WHEN 'cbm' THEN 'a volume' WHEN 'qty' THEN 'a quantity' WHEN 'value' THEN 'a value' ELSE 'a weight' END USING ERRCODE = 'P0001';
    END IF;
    v_acc := 0;
    FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
      ln := v_out->j;
      v_b := coalesce(CASE lc.split_method WHEN 'cbm' THEN (ln->>'cbm')::numeric WHEN 'qty' THEN (ln->>'qty')::numeric
                                           WHEN 'value' THEN (ln->>'value')::numeric WHEN 'equal' THEN 1 ELSE (ln->>'weight')::numeric END, 0);
      IF j = v_last THEN
        v_a := v_amt - v_acc;                      -- the rounding remainder
      ELSE
        v_a := round(v_amt * v_b / v_sum, 2);
      END IF;
      v_acc := v_acc + v_a;
      v_allocs := v_allocs || jsonb_build_object('charge_no', k - 1, 'line_num', j, 'basis', v_b, 'amount', v_a);
    END LOOP;
    v_charges := v_charges || (jsonb_build_object('charge_no', k - 1, 'code', lc.code, 'name', lc.name, 'split_method', lc.split_method, 'amount', v_amt,
                                                 'acct_code', coalesce(lc.acct_code, erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing', false)))
                               || jsonb_build_object('currency', v_ccur, 'amount_fc', v_famt, 'fx_rate', v_frate, 'ap_invoice_entry', ap.doc_entry,
                                                     'ap_invoice_no', v_apno, 'clear_amount', v_clear, 'fx_diff', v_clear - v_amt)
                               || jsonb_build_object('card_code', v_vend,
                                                     'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = v_vend)));
    v_total := v_total + v_amt;
  END LOOP;

  -- Per line: allocated, the on-hand share to inventory (average cost), the rest to cost of goods sold.
  FOR j IN 0 .. jsonb_array_length(v_out) - 1 LOOP
    ln := v_out->j;
    SELECT coalesce(sum((a->>'amount')::numeric), 0) INTO v_a FROM jsonb_array_elements(v_allocs) a WHERE (a->>'line_num')::integer = j;
    v_key := (ln->>'item_code') || '|' || (ln->>'whs_code');
    SELECT sb.on_hand, sb.avg_cost INTO v_oh, v_avg FROM erp.stock_balance sb
     WHERE sb.company_code = p_company AND sb.item_code = ln->>'item_code' AND sb.whs_code = ln->>'whs_code';
    v_oh := greatest(coalesce(v_oh, 0), 0);
    IF NOT (v_pool ? v_key) THEN
      v_pool := v_pool || jsonb_build_object(v_key, v_oh);
      v_avgm := v_avgm || jsonb_build_object(v_key, coalesce(v_avg, (ln->>'price')::numeric));
    END IF;
    v_share := least((v_pool->>v_key)::numeric, (ln->>'qty')::numeric);
    v_pool := v_pool || jsonb_build_object(v_key, (v_pool->>v_key)::numeric - v_share);
    v_inv := CASE WHEN v_share >= (ln->>'qty')::numeric THEN v_a ELSE round(v_a * v_share / (ln->>'qty')::numeric, 2) END;
    v_avg := (v_avgm->>v_key)::numeric;
    v_after := CASE WHEN v_oh > 0 THEN round((v_oh * v_avg + v_inv) / v_oh, 6) ELSE v_avg END;
    v_avgm := v_avgm || jsonb_build_object(v_key, v_after);
    v_ti := v_ti + v_inv;
    v_tc := v_tc + (v_a - v_inv);
    v_res := v_res || (ln || jsonb_build_object('allocated', v_a, 'to_inventory', v_inv, 'to_cogs', v_a - v_inv, 'on_hand', v_oh,
                                                'avg_before', v_avg, 'avg_after', v_after));
  END LOOP;

  RETURN jsonb_build_object('header', jsonb_build_object('doc_date', v_date, 'card_code', v_card, 'reference', nullif(btrim(h->>'reference'), ''),
                                                         'comments', nullif(btrim(h->>'comments'), '')),
                            'lines', v_res, 'charges', v_charges, 'allocs', v_allocs,
                            'totals', jsonb_build_object('total', v_total, 'to_inventory', v_ti, 'to_cogs', v_tc, 'currency', v_cur,
                                                         'clearing', v_ctot, 'fx_diff', v_ctot - v_total));
END $$;
-- B6: + vendor per cost line (supplier, its currency or LC; a linked A/P invoice must be the vendor's, else the broker's;
-- the vendor defaults to the linked invoice's supplier).

-- ---- landed_cost_create: copied from 34_open_items.sql:908.
CREATE OR REPLACE FUNCTION erp.landed_cost_create(p_company varchar, p_header jsonb, p_lines jsonb, p_charges jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  e       jsonb;
  nb      jsonb;
  v_entry integer;
  v_lines jsonb := '[]';
  v_trans integer;
  v_inv   text;
  v_cogs  text;
  v_clr   text;
  v_ti    numeric;
  v_tc    numeric;
  v_tot   numeric;
  x       jsonb;
BEGIN
  u := erp._pd_guard(p_company, true, 'post landed costs', true);
  -- Lock the stock rows the split reads, then split.
  PERFORM 1 FROM erp.stock_balance sb
    JOIN erp.document_line gl ON gl.company_code = sb.company_code AND gl.item_code = sb.item_code AND gl.whs_code = sb.whs_code AND gl.obj_type = 20
   WHERE sb.company_code = p_company
     AND (gl.doc_entry, gl.line_num) IN (SELECT erp._num(y->>'grpo_entry')::integer, erp._num(y->>'grpo_line')::integer
                                           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END) y)
   FOR UPDATE OF sb;
  e := erp._lc_eval(p_company, p_header, p_lines, p_charges);
  v_ti := (e->'totals'->>'to_inventory')::numeric;
  v_tc := (e->'totals'->>'to_cogs')::numeric;
  v_tot := (e->'totals'->>'total')::numeric;
  -- B3: every account is checked before anything is written, in the same order as before: stock (per line), landed cost
  -- clearing (only when a type has no account of its own), price difference (per line with goods already sold).
  PERFORM erp._gl_item_acct(p_company, 'inventory', 'inventory', y->>'item_code', y->>'whs_code') FROM jsonb_array_elements(e->'lines') y;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'charges') ch WHERE ch->>'acct_code' IS NULL) THEN
    v_clr := erp.gl_account(p_company, 'purchasing', 'landed_cost_clearing');
  END IF;
  IF v_tc > 0 THEN
    PERFORM erp._gl_item_acct(p_company, 'inventory', 'price_difference', y->>'item_code', y->>'whs_code')
       FROM jsonb_array_elements(e->'lines') y WHERE (y->>'to_cogs')::numeric <> 0;
  END IF;
  -- B5: the rate difference against linked broker invoices (B4's accounts).
  IF (e->'totals'->>'fx_diff')::numeric > 0 THEN
    PERFORM erp.gl_account(p_company, 'purchasing', 'fx_loss');
  ELSIF (e->'totals'->>'fx_diff')::numeric < 0 THEN
    PERFORM erp.gl_account(p_company, 'sales', 'fx_gain');
  END IF;

  nb := erp._pd_number(p_company, 69);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.landed_cost (company_code, doc_entry, doc_no, doc_date, card_code, reference, comments, total, to_inventory, to_cogs, currency, created_by)
  VALUES (p_company, v_entry, nb->>'no', (e->'header'->>'doc_date')::date, e->'header'->>'card_code', e->'header'->>'reference',
          e->'header'->>'comments', v_tot, v_ti, v_tc, e->'totals'->>'currency', u.user_id);
  INSERT INTO erp.landed_cost_line (company_code, doc_entry, line_num, grpo_entry, grpo_line, item_code, whs_code, qty, value, cbm, weight,
                                    allocated, to_inventory, to_cogs, on_hand, avg_before, avg_after)
  SELECT p_company, v_entry, y.line_num, y.grpo_entry, y.grpo_line, y.item_code, y.whs_code, y.qty, y.value, y.cbm, y.weight,
         y.allocated, y.to_inventory, y.to_cogs, y.on_hand, y.avg_before, y.avg_after
    FROM jsonb_to_recordset(e->'lines') AS y(line_num int, grpo_entry int, grpo_line int, item_code text, whs_code text, qty numeric, value numeric,
                                             cbm numeric, weight numeric, allocated numeric, to_inventory numeric, to_cogs numeric, on_hand numeric,
                                             avg_before numeric, avg_after numeric);
  INSERT INTO erp.landed_cost_charge (company_code, doc_entry, charge_no, code, name, split_method, amount, acct_code,
                                      currency, amount_fc, fx_rate, ap_invoice_entry, clear_amount, fx_diff, card_code)
  SELECT p_company, v_entry, y.charge_no, y.code, y.name, y.split_method, y.amount, y.acct_code,
         y.currency, y.amount_fc, y.fx_rate, y.ap_invoice_entry, y.clear_amount, y.fx_diff, y.card_code
    FROM jsonb_to_recordset(e->'charges') AS y(charge_no int, code text, name text, split_method text, amount numeric, acct_code text,
                                               currency text, amount_fc numeric, fx_rate numeric, ap_invoice_entry int, clear_amount numeric, fx_diff numeric,
                                               card_code text);
  INSERT INTO erp.landed_cost_alloc (company_code, doc_entry, charge_no, line_num, basis, amount)
  SELECT p_company, v_entry, y.charge_no, y.line_num, y.basis, y.amount
    FROM jsonb_to_recordset(e->'allocs') AS y(charge_no int, line_num int, basis numeric, amount numeric);

  -- Average cost: lines are chained per item and warehouse, so the last line of each carries the final value.
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') ORDER BY (value->>'line_num')::integer LOOP
    IF (x->>'to_inventory')::numeric > 0 THEN
      UPDATE erp.stock_balance SET avg_cost = (x->>'avg_after')::numeric
       WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'whs_code';
    END IF;
  END LOOP;

  -- Stock share and sold share per line (the item's group, the receipt's warehouse); credit per landed cost type account.
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
    FROM (SELECT coalesce(ch->>'acct_code', v_clr) AS acct, sum((ch->>'clear_amount')::numeric) AS amt, min((ch->>'charge_no')::integer) AS first_charge
            FROM jsonb_array_elements(e->'charges') ch GROUP BY 1) a);
  -- B5: clearing credited at the linked invoices' LC; the difference to what was capitalised is a rate difference.
  IF (e->'totals'->>'fx_diff')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', erp.gl_account(p_company, 'purchasing', 'fx_loss'),
                                                               'debit', (e->'totals'->>'fx_diff')::numeric, 'memo', 'Exchange rate difference to the broker''s invoice'));
  ELSIF (e->'totals'->>'fx_diff')::numeric < 0 THEN
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', erp.gl_account(p_company, 'sales', 'fx_gain'),
                                                               'credit', -(e->'totals'->>'fx_diff')::numeric, 'memo', 'Exchange rate difference to the broker''s invoice'));
  END IF;
  v_trans := erp.post_journal(p_company, (e->'header'->>'doc_date')::date, format('Landed costs %s', nb->>'no'), v_lines,
    jsonb_build_object('trans_type', 69, 'base_ref', nb->>'no', 'ref1', nb->>'no', 'ref2', e->'header'->>'reference', 'allow_control', true,
                       'action', 'document_post', 'object', 'landed_cost', 'object_ref', v_entry::text));
  UPDATE erp.landed_cost SET trans_id = v_trans WHERE company_code = p_company AND doc_entry = v_entry;
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 69, v_entry, v_trans);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'landed_cost_create', 'landed_cost', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'lines', jsonb_array_length(e->'lines'),
                             'charges', e->'charges', 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_tot, 'to_inventory', v_ti, 'to_cogs', v_tc, 'trans_id', v_trans,
                            'fx_diff', (e->'totals'->>'fx_diff')::numeric);
END $$;
-- B6: + the cost line's vendor.

-- ---- landed_cost_info: copied from 34_open_items.sql:1023.
CREATE OR REPLACE FUNCTION erp.landed_cost_info(p_company varchar, p_doc_entry integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  lc erp.landed_cost;
BEGIN
  u := erp._pd_guard(p_company, false);
  SELECT * INTO lc FROM erp.landed_cost WHERE company_code = p_company AND doc_entry = p_doc_entry;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'doc_entry', lc.doc_entry, 'doc_no', lc.doc_no, 'doc_date', lc.doc_date, 'card_code', lc.card_code,
    'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = lc.card_code),
    'reference', lc.reference, 'comments', lc.comments, 'total', lc.total, 'to_inventory', lc.to_inventory, 'to_cogs', lc.to_cogs,
    'currency', lc.currency, 'trans_id', lc.trans_id, 'can_read_journal', erp.can_read('finance'),
    'created_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = lc.created_by), 'created_at', lc.created_at,
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('line_num', l.line_num, 'grpo_entry', l.grpo_entry, 'grpo_line', l.grpo_line,
                                         'grpo_no', erp._sd_no(p_company, 20, l.grpo_entry), 'item_code', l.item_code,
                                         'description', (SELECT name FROM erp.item WHERE company_code = p_company AND item_code = l.item_code),
                                         'whs_code', l.whs_code, 'qty', l.qty, 'value', l.value, 'cbm', l.cbm, 'weight', l.weight,
                                         'allocated', l.allocated, 'to_inventory', l.to_inventory, 'to_cogs', l.to_cogs, 'on_hand', l.on_hand,
                                         'avg_before', l.avg_before, 'avg_after', l.avg_after,
                                         'allocs', (SELECT jsonb_object_agg(a.charge_no::text, a.amount) FROM erp.landed_cost_alloc a
                                                     WHERE a.company_code = l.company_code AND a.doc_entry = l.doc_entry AND a.line_num = l.line_num))
                                       ORDER BY l.line_num)
                         FROM erp.landed_cost_line l WHERE l.company_code = p_company AND l.doc_entry = p_doc_entry), '[]'::jsonb),
    'charges', coalesce((SELECT jsonb_agg(jsonb_build_object('charge_no', c.charge_no, 'code', c.code, 'name', c.name, 'split_method', c.split_method,
                                           'amount', c.amount, 'currency', coalesce(c.currency, lc.currency), 'amount_fc', c.amount_fc, 'fx_rate', c.fx_rate,
                                           'ap_invoice_entry', c.ap_invoice_entry,
                                           'ap_invoice_no', CASE WHEN c.ap_invoice_entry IS NOT NULL THEN erp._sd_no(p_company, 18, c.ap_invoice_entry) END,
                                           'clear_amount', coalesce(c.clear_amount, c.amount), 'fx_diff', coalesce(c.fx_diff, 0),
                                           'card_code', c.card_code,
                                           'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = c.card_code)) ORDER BY c.charge_no)
                           FROM erp.landed_cost_charge c WHERE c.company_code = p_company AND c.doc_entry = p_doc_entry), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'actor_name', coalesce(au.display_name, l.actor)) ORDER BY l.at, l.audit_id)
                            FROM erp.audit_log l LEFT JOIN erp.app_user au ON au.user_id::text = l.actor
                           WHERE l.company_code = p_company AND l.object = 'landed_cost' AND l.object_ref = p_doc_entry::text), '[]'::jsonb));
END $$;
-- B6: + vendor (code and name) per charge.

-- ============ 3. Journals carry system currency amounts ============
-- When a company's system currency differs from its local currency, every Super ERP journal line also carries its amount in
-- the system currency (journal_line.sys_debit / sys_credit, SAP JDT1 SYSDeb / SYSCred): the amount the caller passes, the
-- line's FC amount when the FC is the system currency, else LC / the system currency's rate of the posting date
-- (fx_rate_list; missing = refused, as SAP). Rounding per line is what creates conversion differences. A journal with
-- source_ref.sys_only = true carries system currency amounts only (LC 0) — Conversion Differences posts those. Reversals
-- mirror the system currency amounts. Companies whose system currency is the local currency post exactly as before.

-- ---- post_journal: copied from 33_multicurrency.sql:375.
CREATE OR REPLACE FUNCTION erp.post_journal(p_company varchar, p_date date, p_memo text, p_lines jsonb, p_source_ref jsonb DEFAULT '{}')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s       jsonb := coalesce(p_source_ref, '{}'::jsonb);
  e       jsonb;
  v_msg   text;
  v_cur   text;
  v_trans integer;
  v_nerr  integer;
  v_d     numeric;
  v_c     numeric;
  v_fcur  text;
  v_frate numeric;
  dd      erp.document;
  v_sc    text;
  v_srate numeric;
  v_sysonly boolean := coalesce((coalesce(p_source_ref, '{}'::jsonb)->>'sys_only')::boolean, false);
  v_lines jsonb := p_lines;
  v_rows  jsonb;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Company % does not exist.', coalesce(p_company, '(none)') USING ERRCODE = 'P0001';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Choose a posting date.' USING ERRCODE = 'P0001';
  END IF;
  v_msg := erp._period_message(p_company, p_date, true);
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION '%', v_msg USING ERRCODE = 'P0001';
  END IF;

  -- B6: system currency.
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

  e := erp._je_lines_eval(p_company, v_lines, coalesce((s->>'allow_control')::boolean, false));
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this journal.', v_nerr - 1) ELSE '' END;
  END IF;
  IF (e->>'count')::integer < 2 THEN
    RAISE EXCEPTION 'Add at least two lines.' USING ERRCODE = 'P0001';
  END IF;
  v_d := (e->>'debit')::numeric;
  v_c := (e->>'credit')::numeric;
  IF v_d <> v_c THEN
    RAISE EXCEPTION '%', format('Debits %s and credits %s don''t balance. Difference %s %s.', erp._money(v_d), erp._money(v_c), erp._money(abs(v_d - v_c)), CASE WHEN v_sysonly THEN v_sc ELSE v_cur END)
      USING ERRCODE = 'P0001';
  END IF;

  -- B4: foreign currency. Explicit: source_ref.fc_currency (+ fc_rate) and line fc_debit / fc_credit. A Super ERP document
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

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (coalesce(erp.current_user_id()::text, 'system:posting'), p_company, coalesce(s->>'action', 'journal_post'), 'journal', v_trans::text,
          jsonb_build_object('trans_type', coalesce((s->>'trans_type')::integer, 30), 'ref_date', p_date, 'memo', p_memo, 'total', v_d,
                             'lines', (e->>'count')::integer, 'reversal_of', s->'reversal_of', 'source_object', s->'object',
                             'source_ref', s->'object_ref', 'sys_currency', v_sc, 'sys_only', v_sysonly));
  RETURN v_trans;
END $$;
-- B6: system currency amounts on every line when the company's system currency is not its local currency (missing rate =
-- refused); source_ref.sys_only for journals in the system currency only; header total_sys in the system currency.

-- ---- _reverse_journal: copied from 33_multicurrency.sql:465.
CREATE OR REPLACE FUNCTION erp._reverse_journal(p_company varchar, p_trans_id integer, p_date date, p_memo text, p_action text DEFAULT 'journal_reverse')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  je    erp.journal_entry;
  v_new integer;
BEGIN
  SELECT * INTO je FROM erp.journal_entry WHERE company_code = p_company AND trans_id = p_trans_id;
  v_new := erp.post_journal(p_company, p_date, p_memo,
    (SELECT jsonb_agg(jsonb_build_object('acct_code', l.acct_code, 'short_name', l.short_name, 'debit', l.credit, 'credit', l.debit,
                                         'memo', l.memo, 'tax_code', l.tax_code, 'cost_centre', l.cost_centre,
                                         'fc_debit', l.fc_credit, 'fc_credit', l.fc_debit,
                                         'sys_debit', l.sys_credit, 'sys_credit', l.sys_debit) ORDER BY l.line_id)
       FROM erp.journal_line l WHERE l.company_code = p_company AND l.trans_id = p_trans_id),
    jsonb_build_object('trans_type', je.trans_type, 'reversal_of', p_trans_id, 'ref1', je.ref1, 'ref2', je.ref2,
                       'base_ref', p_trans_id::text, 'allow_control', true, 'action', p_action,
                       'object', 'journal', 'object_ref', p_trans_id::text,
                       'fc_currency', (SELECT max(fc_currency) FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id),
                       'sys_only', NOT EXISTS (SELECT 1 FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id AND (debit <> 0 OR credit <> 0))));
  RETURN v_new;
END $$;
-- B6: the mirror keeps the system currency amounts (and reverses journals in the system currency only).

-- ---- _health_files: copied from 34_open_items.sql:1061.
CREATE OR REPLACE FUNCTION erp._health_files() RETURNS TABLE (file_name text, object text) LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    ('14_console_views.sql', 'company_go_live'), ('14_signoff_inbox.sql', 'migration_inbox'),
    ('15_stage1_overview.sql', 'home_kpis'), ('16_module_access.sql', 'module_level'), ('17_sales_order.sql', 'sales_order_save'),
    ('18_posting.sql', 'journal_submit'), ('19_sales_cycle.sql', 'sales_delivery_create'), ('20_banking.sql', 'bank_statement_import'),
    ('21_purchasing.sql', 'landed_cost_create'), ('22_inventory.sql', 'inv_count_create'), ('23_master_data.sql', 'bp_save'),
    ('24_hr.sql', 'leave_checks'), ('25_admin.sql', 'admin_users'), ('26_reports.sql', 'control_findings'),
    ('27_migration_more.sql', 'custom_field_setup'), ('28_production_service.sql', 'prod_order_create'), ('29_go_live.sql', 'system_health'),
    ('30_numbering_company.sql', 'doc_series_save'), ('31_approvals.sql', 'approval_template_save'),
    ('32_gl_setup.sql', 'gl_setup'),
    ('33_multicurrency.sql', 'currency_rate'),
    ('34_open_items.sql', 'fx_revaluation_post'),
    ('35_final_items.sql', 'conversion_diff_post')
  ) AS v(file_name, object)
$$;
-- B6: + 35_final_items.sql (marker conversion_diff_post).

-- ============ 4. Conversion Differences (Financials › Exchange Rates and Revaluation › Conversion Differences) ============
-- Super ERP journal lines carry their system currency amount rounded per line, so an account or a partner can end with a
-- local currency balance of 0 and a small system currency balance. This window finds them (as of a date: lines dated on or
-- before it that carry system currency amounts) and posts one correcting journal in the system currency only (no LC
-- effect): each row is cleared against general / conversion_diff. SAP Business One journals are not touched (SAP keeps its
-- own). Period lock through post_journal; Financials full; audited; reports stay in LC.
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort, tab, ctx, store, control_ok, used_in) VALUES
  ('general', 'conversion_diff', 'Conversion differences (system currency)', 84, 'general', false, NULL, false,
     'Financials › Conversion Differences: rounding differences in the system currency')
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, tab = EXCLUDED.tab, ctx = EXCLUDED.ctx,
  store = EXCLUDED.store, control_ok = EXCLUDED.control_ok, used_in = EXCLUDED.used_in;

-- SAMPLE account for the test company ZZ99 only (real companies enter theirs in G/L Account Determination › General).
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', '7120', '7120', 'Conversion differences (SAMPLE)', '4000', 2, true, 'other', 7, 'AED', false, false, 0, 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT DO NOTHING;
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', 'general', 'conversion_diff', '7120', 'sample'
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = '7120')
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS erp.conv_diff_run (
    run_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    doc_no         text,
    run_date       date NOT NULL,
    accounts       boolean NOT NULL,
    partners       boolean NOT NULL,
    sys_currency   varchar(3) NOT NULL,
    debit          numeric(19,2) NOT NULL DEFAULT 0,              -- system currency
    credit         numeric(19,2) NOT NULL DEFAULT 0,
    acct_code      varchar(15),                                   -- the conversion difference account (when a net is posted)
    trans_id       integer,
    memo           text,
    state          text NOT NULL DEFAULT 'posted' CHECK (state IN ('posted', 'cancelled')),
    cancel_trans_id integer,
    cancel_reason  text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_by   uuid,
    cancelled_at   timestamptz
);

CREATE TABLE IF NOT EXISTS erp.conv_diff_line (
    run_id         bigint NOT NULL REFERENCES erp.conv_diff_run ON DELETE CASCADE,
    line_no        integer NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('account', 'partner')),
    acct_code      varchar(15) NOT NULL,
    card_code      varchar(15),
    lc_balance     numeric(19,2) NOT NULL,
    sc_balance     numeric(19,2) NOT NULL,                        -- what the correction clears (system currency)
    journals       integer NOT NULL,
    PRIMARY KEY (run_id, line_no)
);

ALTER TABLE erp.conv_diff_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.conv_diff_line ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.conv_diff_run, erp.conv_diff_line FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.conv_diff_run, erp.conv_diff_line TO authenticated;
DROP POLICY IF EXISTS conv_diff_run_read ON erp.conv_diff_run;
CREATE POLICY conv_diff_run_read ON erp.conv_diff_run FOR SELECT TO authenticated USING (erp.can_see(company_code) AND erp.can_read('finance'));
DROP POLICY IF EXISTS conv_diff_line_read ON erp.conv_diff_line;
CREATE POLICY conv_diff_line_read ON erp.conv_diff_line FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.conv_diff_run r WHERE r.run_id = conv_diff_line.run_id AND erp.can_see(r.company_code) AND erp.can_read('finance')));

CREATE OR REPLACE VIEW erp.conv_diff_list WITH (security_invoker = true) AS
SELECT r.run_id, r.company_code, coalesce(r.doc_no, 'CVD-' || r.run_id) AS doc_no, r.run_date, r.accounts, r.partners, r.sys_currency,
       r.debit, r.credit, r.trans_id, r.cancel_trans_id, r.state, r.memo, r.created_at,
       (SELECT display_name FROM erp.app_user WHERE user_id = r.created_by) AS created_by_name,
       (SELECT count(*) FROM erp.conv_diff_line l WHERE l.run_id = r.run_id) AS lines
  FROM erp.conv_diff_run r;
REVOKE ALL ON erp.conv_diff_list FROM PUBLIC, anon;
GRANT SELECT ON erp.conv_diff_list TO authenticated;

-- Accounts (non-control lines, or control lines without a partner) and partners (control account + short name) whose
-- Super ERP lines up to p_date carrying system currency amounts net to 0 in LC but not in the system currency.
CREATE OR REPLACE FUNCTION erp._cvd_rows(p_company varchar, p_date date, p_accounts boolean, p_partners boolean, p_skip text)
RETURNS TABLE (kind text, acct_code varchar, acct_name text, card_code varchar, card_name text, lc_balance numeric, sc_balance numeric, journals bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH l AS (
    SELECT CASE WHEN a.is_control AND l.short_name IS NOT NULL AND l.short_name <> l.acct_code THEN 'partner' ELSE 'account' END AS kind,
           l.acct_code, CASE WHEN a.is_control AND l.short_name IS NOT NULL AND l.short_name <> l.acct_code THEN l.short_name END AS card_code,
           l.debit - l.credit AS lc, coalesce(l.sys_debit, 0) - coalesce(l.sys_credit, 0) AS sc, l.trans_id
      FROM erp.journal_line l
      JOIN erp.journal_entry j ON j.company_code = l.company_code AND j.trans_id = l.trans_id
      JOIN erp.account a ON a.company_code = l.company_code AND a.acct_code = l.acct_code
     WHERE l.company_code = p_company AND j.source = 'erp' AND j.ref_date <= p_date
       AND (l.sys_debit IS NOT NULL OR l.sys_credit IS NOT NULL)
       AND l.acct_code IS DISTINCT FROM p_skip
  )
  SELECT l.kind, l.acct_code, (SELECT name FROM erp.account WHERE company_code = p_company AND acct_code = l.acct_code),
         l.card_code, (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = l.card_code),
         round(sum(l.lc), 2), round(sum(l.sc), 2), count(DISTINCT l.trans_id)
    FROM l
   WHERE (l.kind = 'account' AND p_accounts) OR (l.kind = 'partner' AND p_partners)
   GROUP BY l.kind, l.acct_code, l.card_code
  HAVING round(sum(l.lc), 2) = 0 AND round(sum(l.sc), 2) <> 0
   ORDER BY l.kind, l.acct_code, l.card_code
$$;

-- Validate a request and compute the rows. Never writes. p_in: {date, accounts (default true), partners (default true)}.
CREATE OR REPLACE FUNCTION erp._cvd_eval(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_in   jsonb := coalesce(p_in, '{}'::jsonb);
  v_lc   text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_sc   text := erp._sys_cur(p_company);
  v_date date;
  v_acc  boolean := coalesce((v_in->>'accounts')::boolean, true);
  v_bp   boolean := coalesce((v_in->>'partners')::boolean, true);
  v_acct text := erp.gl_account(p_company, 'general', 'conversion_diff', false);
  v_rows jsonb;
BEGIN
  IF v_sc IS NULL THEN
    RAISE EXCEPTION 'Conversion differences need a system currency. % uses its local currency % as the system currency, so there is nothing to convert. Set one in Administration › Company Details.',
      p_company, v_lc USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_date := nullif(btrim(v_in->>'date'), '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the date as YYYY-MM-DD.' USING ERRCODE = 'P0001';
  END;
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Choose the posting date.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_acc AND NOT v_bp THEN
    RAISE EXCEPTION 'Choose G/L accounts, business partners or both.' USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_rows FROM erp._cvd_rows(p_company, v_date, v_acc, v_bp, v_acct) r;
  RETURN jsonb_build_object(
    'date', v_date, 'accounts', v_acc, 'partners', v_bp, 'local_currency', v_lc, 'sys_currency', v_sc, 'acct_code', v_acct, 'rows', v_rows,
    'totals', jsonb_build_object(
      'rows', jsonb_array_length(v_rows),
      -- the correction: a positive balance is credited, a negative one debited
      'debit', coalesce((SELECT -sum((r->>'sc_balance')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'sc_balance')::numeric < 0), 0),
      'credit', coalesce((SELECT sum((r->>'sc_balance')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'sc_balance')::numeric > 0), 0),
      'net', coalesce((SELECT sum((r->>'sc_balance')::numeric) FROM jsonb_array_elements(v_rows) r), 0)));
END $$;

-- Setup for the screen (Financials read): currencies, the account, history.
CREATE OR REPLACE FUNCTION erp.conversion_diff_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'post conversion differences');
BEGIN
  RETURN jsonb_build_object(
    'company_code', p_company,
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'sys_currency', coalesce(erp._sys_cur(p_company), (SELECT currency FROM erp.company WHERE company_code = p_company)),
    'active', erp._sys_cur(p_company) IS NOT NULL,
    'can_write', erp.can_write('finance'),
    'acct_code', erp.gl_account(p_company, 'general', 'conversion_diff', false),
    'history', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.run_date DESC, l.run_id DESC) FROM erp.conv_diff_list l WHERE l.company_code = p_company), '[]'::jsonb));
END $$;

-- Preview (Financials full).
CREATE OR REPLACE FUNCTION erp.conversion_diff_preview(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, true, 'post conversion differences');
BEGIN
  RETURN erp._cvd_eval(p_company, p_in);
END $$;

-- Post the correcting journal in the system currency only. p_in: preview input + {memo}.
CREATE OR REPLACE FUNCTION erp.conversion_diff_post(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user := erp._je_guard(p_company, true, 'post conversion differences');
  v_in    jsonb := coalesce(p_in, '{}'::jsonb);
  e       jsonb;
  v_date  date;
  v_memo  text := nullif(btrim(v_in->>'memo'), '');
  v_net   numeric;
  v_acct  text;
  v_lines jsonb := '[]';
  v_id    bigint;
  v_no    text;
  v_trans integer;
  x       record;
  i       integer := 0;
BEGIN
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  e := erp._cvd_eval(p_company, v_in);
  v_date := (e->>'date')::date;
  IF jsonb_array_length(e->'rows') = 0 THEN
    RAISE EXCEPTION 'There are no conversion differences in % up to %.', p_company, erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  v_net := (e->'totals'->>'net')::numeric;
  IF v_net <> 0 THEN
    v_acct := erp.gl_account(p_company, 'general', 'conversion_diff');
  END IF;

  INSERT INTO erp.conv_diff_run (company_code, run_date, accounts, partners, sys_currency, debit, credit, acct_code, memo, created_by)
  VALUES (p_company, v_date, (e->>'accounts')::boolean, (e->>'partners')::boolean, e->>'sys_currency',
          (e->'totals'->>'debit')::numeric, (e->'totals'->>'credit')::numeric, v_acct, v_memo, u.user_id)
  RETURNING run_id INTO v_id;
  v_no := 'CVD-' || v_id;
  UPDATE erp.conv_diff_run SET doc_no = v_no WHERE run_id = v_id;

  FOR x IN SELECT * FROM jsonb_to_recordset(e->'rows') AS y(kind text, acct_code text, card_code text, lc_balance numeric, sc_balance numeric, journals integer) LOOP
    i := i + 1;
    INSERT INTO erp.conv_diff_line (run_id, line_no, kind, acct_code, card_code, lc_balance, sc_balance, journals)
    VALUES (v_id, i, x.kind, x.acct_code, x.card_code, x.lc_balance, x.sc_balance, x.journals);
    v_lines := v_lines || jsonb_build_object('acct_code', x.acct_code, 'short_name', x.card_code,
      CASE WHEN x.sc_balance > 0 THEN 'sys_credit' ELSE 'sys_debit' END, abs(x.sc_balance),
      'memo', format('Conversion difference %s %s', coalesce(x.card_code, x.acct_code), erp._money(x.sc_balance)));
  END LOOP;
  IF v_net > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_acct, 'sys_debit', v_net, 'memo', 'Conversion differences');
  ELSIF v_net < 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_acct, 'sys_credit', -v_net, 'memo', 'Conversion differences');
  END IF;
  v_trans := erp.post_journal(p_company, v_date, coalesce(v_memo, format('Conversion differences %s · %s', erp._day(v_date), e->>'sys_currency')), v_lines,
    jsonb_build_object('trans_type', 30, 'ref1', v_no, 'ref2', 'Conversion differences', 'base_ref', v_no, 'allow_control', true, 'sys_only', true,
                       'action', 'conversion_diff_journal', 'object', 'conversion_diff', 'object_ref', v_id::text));
  UPDATE erp.conv_diff_run SET trans_id = v_trans WHERE run_id = v_id;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'conversion_diff_post', 'conversion_diff', v_id::text,
          jsonb_build_object('doc_no', v_no, 'date', v_date, 'sys_currency', e->>'sys_currency', 'rows', i, 'debit', e->'totals'->'debit',
                             'credit', e->'totals'->'credit', 'net', v_net, 'trans_id', v_trans));
  RETURN jsonb_build_object('run_id', v_id, 'doc_no', v_no, 'date', v_date, 'trans_id', v_trans, 'rows', i, 'net', v_net,
                            'sys_currency', e->>'sys_currency');
END $$;

-- Cancel a run: reverses its journal on the run date (system currency only). The period must be open.
CREATE OR REPLACE FUNCTION erp.conversion_diff_cancel(p_company varchar, p_run_id bigint, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user := erp._je_guard(p_company, true, 'post conversion differences');
  r      erp.conv_diff_run;
  v_note text := nullif(btrim(p_reason), '');
  v_t    integer;
BEGIN
  SELECT * INTO r FROM erp.conv_diff_run WHERE run_id = p_run_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversion difference run % was not found in %.', coalesce(p_run_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF r.state = 'cancelled' THEN
    RAISE EXCEPTION 'Conversion difference run % is already cancelled.', r.doc_no USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a reason for cancelling the run.' USING ERRCODE = 'P0001';
  END IF;
  v_t := erp._reverse_journal(p_company, r.trans_id, r.run_date, format('Cancellation of %s: %s', r.doc_no, v_note), 'conversion_diff_cancel');
  UPDATE erp.conv_diff_run SET state = 'cancelled', cancel_trans_id = v_t, cancel_reason = v_note, cancelled_by = u.user_id, cancelled_at = now()
   WHERE run_id = p_run_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'conversion_diff_cancel', 'conversion_diff', p_run_id::text,
          jsonb_build_object('doc_no', r.doc_no, 'date', r.run_date, 'reason', v_note, 'trans_id', v_t));
  RETURN jsonb_build_object('run_id', p_run_id, 'doc_no', r.doc_no, 'state', 'cancelled', 'trans_id', v_t);
END $$;

-- One run with its lines, journals (LC and system currency amounts) and activity (Financials read).
CREATE OR REPLACE FUNCTION erp.conversion_diff_info(p_company varchar, p_run_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'post conversion differences');
  r erp.conv_diff_run;
BEGIN
  SELECT * INTO r FROM erp.conv_diff_run WHERE run_id = p_run_id AND company_code = p_company;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN to_jsonb(r) || jsonb_build_object(
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'created_by_name', erp._adm_name(r.created_by), 'cancelled_by_name', erp._adm_name(r.cancelled_by),
    'can_cancel', r.state = 'posted' AND erp.can_write('finance'),
    'lines', coalesce((SELECT jsonb_agg(to_jsonb(l) || jsonb_build_object(
                         'acct_name', (SELECT name FROM erp.account WHERE company_code = p_company AND acct_code = l.acct_code),
                         'card_name', (SELECT name FROM erp.business_partner WHERE company_code = p_company AND card_code = l.card_code)) ORDER BY l.line_no)
                         FROM erp.conv_diff_line l WHERE l.run_id = r.run_id), '[]'::jsonb),
    'journals', coalesce((SELECT jsonb_agg(jsonb_build_object('trans_id', j.trans_id, 'ref_date', j.ref_date, 'memo', j.memo, 'total', j.total_local, 'total_sys', j.total_sys,
                                                              'lines', (SELECT jsonb_agg(jsonb_build_object('acct_code', jl.acct_code, 'short_name', jl.short_name,
                                                                                                             'debit', jl.debit, 'credit', jl.credit, 'sys_debit', jl.sys_debit,
                                                                                                             'sys_credit', jl.sys_credit, 'memo', jl.memo) ORDER BY jl.line_id)
                                                                          FROM erp.journal_line jl WHERE jl.company_code = j.company_code AND jl.trans_id = j.trans_id))
                                           ORDER BY j.ref_date, j.trans_id)
                            FROM erp.journal_entry j
                           WHERE j.company_code = p_company AND j.trans_id = ANY (array_remove(ARRAY[r.trans_id, r.cancel_trans_id], NULL))), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', coalesce(au.display_name, a.actor)) ORDER BY a.at, a.audit_id)
                            FROM erp.audit_log a LEFT JOIN erp.app_user au ON au.user_id::text = a.actor
                           WHERE a.company_code = p_company AND a.object = 'conversion_diff' AND a.object_ref = r.run_id::text), '[]'::jsonb));
END $$;

-- ============ 5. Grants ============
REVOKE ALL ON FUNCTION
  erp._sys_cur(varchar), erp._sys_cur_used(varchar), erp._cvd_rows(varchar, date, boolean, boolean, text), erp._cvd_eval(varchar, jsonb)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  erp.system_currency_info(varchar), erp.system_currency_save(varchar, text),
  erp.conversion_diff_setup(varchar), erp.conversion_diff_preview(varchar, jsonb), erp.conversion_diff_post(varchar, jsonb),
  erp.conversion_diff_cancel(varchar, bigint, text), erp.conversion_diff_info(varchar, bigint)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  erp.system_currency_info(varchar), erp.system_currency_save(varchar, text),
  erp.conversion_diff_setup(varchar), erp.conversion_diff_preview(varchar, jsonb), erp.conversion_diff_post(varchar, jsonb),
  erp.conversion_diff_cancel(varchar, bigint, text), erp.conversion_diff_info(varchar, bigint)
TO authenticated;
