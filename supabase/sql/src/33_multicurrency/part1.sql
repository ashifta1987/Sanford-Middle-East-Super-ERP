-- B4 · Multi-currency (sales, purchasing, payments) and soft-switch stock. Safe to run twice. Does not edit 10–32: earlier
-- behaviour is changed here with CREATE OR REPLACE, keeping the earlier tests passing.
--
-- GENERATED from supabase/sql/src/33_multicurrency (part1/2/3.sql + asserted patches of earlier functions in build.py).
-- Edit the sources and run `python3 supabase/sql/src/33_multicurrency/build.py`; `--check` verifies the committed file.
--
-- Decisions of 10 Nov 2026 (docs/decisions-2026-11-10.md): §2 C9 (multi-currency) and §3 (soft-switch stock).
--
-- Conventions (as SAP Business One):
--   document.total / vat_total / paid, document_line.line_total / vat, payment.total ......... local currency (LC)
--   document.total_fc / vat_total_fc / paid_fc, document_line.line_total_fc / vat_fc,
--   document_line.price, payment.total_fc, payment_allocation.applied_fc ...................... document currency (DC)
--   rate = LC per 1 unit of the currency (A10 fx_rate_entry). LC documents keep every *_fc column NULL, so AED documents and
--   their journals are exactly as before.
--
-- Rules:
--   * Currency: the header currency; empty = the partner's currency; a partner with '##' (all currencies) or none may use any
--     currency of the company's rates list (Administration › Exchange Rates) or LC; a partner with a fixed currency uses it or LC.
--   * Rate: fx_rate_list for the posting date (exact date, as SAP). Missing → "There is no exchange rate for USD on 10 Nov 2026…".
--   * A different rate on the form: only Financials (full) and only on documents that take the date's rate (quotations, orders,
--     purchase quotations / orders, A/R and A/P invoices, deposits, payments). Copies that keep the base rate (delivery ← order,
--     GRPO ← purchase order, credit memo ← invoice) can't change it; copying bases with different rates is refused.
--   * Copy-to keeps the currency. The A/R invoice and the A/P invoice take their own date's rate. A delivery posts cost only, so
--     no difference arises; an A/P invoice clears goods received / not invoiced at the GRPO's value and posts the rate
--     difference to purchasing / fx_loss or sales / fx_gain.
--   * Payments are in the documents' currency; money in LC at the payment date's rate; each document is cleared at its own LC
--     (proportionally, the rest on the final payment); the difference is the realised FX gain / loss.
--
-- Soft switch: stock_balance.on_hand = SAP on-hand of the latest sync + net Super ERP movements (see section 9).

-- ============ 1. Columns ============
ALTER TABLE erp.document ADD COLUMN IF NOT EXISTS vat_total_fc numeric(19,6);
ALTER TABLE erp.document ADD COLUMN IF NOT EXISTS paid_fc numeric(19,6);
ALTER TABLE erp.document_line ADD COLUMN IF NOT EXISTS vat_fc numeric(19,6);
ALTER TABLE erp.payment ADD COLUMN IF NOT EXISTS total_fc numeric(19,6);
ALTER TABLE erp.payment ADD COLUMN IF NOT EXISTS on_account_fc numeric(19,6);
ALTER TABLE erp.payment ADD COLUMN IF NOT EXISTS fx_diff numeric(19,6);          -- LC: + gain / − loss for the company
ALTER TABLE erp.payment_cheque ADD COLUMN IF NOT EXISTS amount_fc numeric(19,2);
ALTER TABLE erp.ap_dp_draw ADD COLUMN IF NOT EXISTS amount_fc numeric(19,2);

-- ============ 2. Rates ============
-- Rate (LC per 1 unit) for an exact date: SAP's rate first, else the Super ERP rate. 1 for the company currency, NULL when none.
CREATE OR REPLACE FUNCTION erp._cur_rate(p_company varchar, p_cur text, p_date date) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN upper(btrim(p_cur)) = (SELECT currency FROM erp.company WHERE company_code = p_company) THEN 1::numeric
              ELSE coalesce((SELECT rate FROM erp.fx_rate WHERE company_code = p_company AND rate_date = p_date AND currency = upper(btrim(p_cur))),
                            (SELECT rate FROM erp.fx_rate_entry WHERE company_code = p_company AND rate_date = p_date AND currency = upper(btrim(p_cur)))) END
$$;

CREATE OR REPLACE FUNCTION erp._cur_no_rate(p_cur text, p_date date) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT format('There is no exchange rate for %s on %s. Enter it in Administration › Exchange Rates, then try again.', p_cur, erp._day(p_date))
$$;

CREATE OR REPLACE FUNCTION erp._cur_list(p_company varchar) RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT fx_currencies FROM erp.admin_setting WHERE company_code = p_company), '{USD,SAR,CNY,EUR}'::text[])
$$;

-- Amount in another currency through LC at the date's rates. NULL when a rate is missing.
CREATE OR REPLACE FUNCTION erp._cur_conv(p_company varchar, p_amount numeric, p_from text, p_to text, p_date date) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN p_amount IS NULL THEN NULL
              WHEN coalesce(upper(p_from), '') = coalesce(upper(p_to), '') THEN p_amount
              ELSE round(p_amount * erp._cur_rate(p_company, coalesce(p_from, (SELECT currency FROM erp.company WHERE company_code = p_company)), p_date)
                         / nullif(erp._cur_rate(p_company, p_to, p_date), 0), 6) END
$$;

-- The document currency and rate for a form. Never raises: returns {currency, rate, local, overridden, error, field}.
--   p_bp_cur  the partner's currency (NULL or '##' = any currency)    p_head / p_head_rate  what the form sent (may be empty)
--   p_noun    'Customer' / 'Supplier'                                 p_date  posting date (NULL: no rate yet)
CREATE OR REPLACE FUNCTION erp._cur_pick(p_company varchar, p_card text, p_bp_cur text, p_head text, p_head_rate text, p_date date, p_noun text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_lc    text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_bp    text := upper(nullif(btrim(p_bp_cur), ''));
  v_cur   text;
  v_rate  numeric;
  v_typed numeric := erp._num(nullif(btrim(p_head_rate), ''));
  v_res   jsonb;
BEGIN
  v_cur := upper(coalesce(nullif(btrim(p_head), ''), CASE WHEN v_bp IS NOT NULL AND v_bp <> '##' THEN v_bp END, v_lc));
  v_res := jsonb_build_object('currency', v_cur, 'local', v_lc, 'rate', NULL, 'overridden', false);
  IF v_cur <> v_lc THEN
    IF v_bp IS NOT NULL AND v_bp <> '##' AND v_cur <> v_bp THEN
      RETURN v_res || jsonb_build_object('field', 'currency', 'error',
        format('%s %s trades in %s. Choose %s or %s.', p_noun, p_card, v_bp, v_bp, v_lc));
    ELSIF (v_bp IS NULL OR v_bp = '##') AND NOT v_cur = ANY (erp._cur_list(p_company)) THEN
      RETURN v_res || jsonb_build_object('field', 'currency', 'error',
        format('Currency %s is not in the rates list of %s (%s).', v_cur, p_company, array_to_string(erp._cur_list(p_company), ', ')));
    END IF;
  END IF;
  IF v_cur = v_lc THEN
    RETURN v_res || jsonb_build_object('rate', 1);
  END IF;
  IF p_date IS NULL THEN
    RETURN v_res;
  END IF;
  v_rate := erp._cur_rate(p_company, v_cur, p_date);
  IF v_typed IS NOT NULL AND v_typed IS DISTINCT FROM v_rate THEN
    IF v_typed <= 0 THEN
      RETURN v_res || jsonb_build_object('field', 'fx_rate', 'error', 'The exchange rate must be more than 0.');
    ELSIF NOT erp.can_write('finance') THEN
      RETURN v_res || jsonb_build_object('rate', v_rate, 'field', 'fx_rate', 'error',
        CASE WHEN v_rate IS NULL THEN erp._cur_no_rate(v_cur, p_date)
             ELSE format('Only Financials can change the exchange rate. The rate for %s on %s is %s.', v_cur, erp._day(p_date), trim_scale(v_rate)) END);
    END IF;
    RETURN v_res || jsonb_build_object('rate', v_typed, 'overridden', true, 'list_rate', v_rate);
  ELSIF v_rate IS NULL THEN
    RETURN v_res || jsonb_build_object('field', 'fx_rate', 'error', erp._cur_no_rate(v_cur, p_date));
  END IF;
  RETURN v_res || jsonb_build_object('rate', v_rate);
END $$;

-- Rate for a form (any signed-in user of the company): {currency, local, rate, can_override, message}.
CREATE OR REPLACE FUNCTION erp.currency_rate(p_company varchar, p_currency text, p_date date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_lc   text;
  v_cur  text := upper(nullif(btrim(p_currency), ''));
  v_rate numeric;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  SELECT currency INTO v_lc FROM erp.company WHERE company_code = p_company;
  v_cur := coalesce(v_cur, v_lc);
  v_rate := CASE WHEN p_date IS NULL THEN NULL ELSE erp._cur_rate(p_company, v_cur, p_date) END;
  RETURN jsonb_build_object('currency', v_cur, 'local', v_lc, 'rate', v_rate, 'date', p_date,
    'currencies', to_jsonb(erp._cur_list(p_company)), 'can_override', erp.can_write('finance'),
    'message', CASE WHEN p_date IS NOT NULL AND v_rate IS NULL THEN erp._cur_no_rate(v_cur, p_date) END);
END $$;

-- ============ 3. Document context: currency + rate for the next Super ERP document header ============
-- Set by the create functions before _sd_new_doc / _pd_new_doc, which take it and clear it (transaction-local settings).
CREATE OR REPLACE FUNCTION erp._cur_ctx_set(p_cur text, p_rate numeric) RETURNS void
LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM set_config('erp.fx_cur', coalesce(p_cur, ''), true);
  PERFORM set_config('erp.fx_rate', coalesce(p_rate::text, ''), true);
END $$;

-- Take the context (and clear it). Returns {currency, rate}; LC and 1 when none is set.
CREATE OR REPLACE FUNCTION erp._cur_ctx_take(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql SET search_path = erp, pg_temp AS $$
DECLARE
  v_cur  text := nullif(current_setting('erp.fx_cur', true), '');
  v_rate numeric := nullif(current_setting('erp.fx_rate', true), '')::numeric;
BEGIN
  PERFORM erp._cur_ctx_set(NULL, NULL);
  RETURN jsonb_build_object('currency', coalesce(v_cur, (SELECT currency FROM erp.company WHERE company_code = p_company)),
                            'rate', CASE WHEN v_cur IS NULL THEN 1 ELSE coalesce(v_rate, 1) END);
END $$;

CREATE OR REPLACE FUNCTION erp._cur_noun(p_obj integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE p_obj WHEN 15 THEN 'delivery' WHEN 13 THEN 'A/R invoice' WHEN 14 THEN 'credit memo' WHEN 20 THEN 'goods receipt'
                    WHEN 18 THEN 'A/P invoice' WHEN 204 THEN 'down payment invoice' ELSE 'document' END
$$;

-- Currency and rate of a copy (delivery 15 ← order, A/R invoice 13 ← delivery, credit memo 14 ← invoice, GRPO 20 ← PO,
-- A/P invoice 18 ← GRPO) from its base lines; sets the context and returns the rate. Raises the first problem.
CREATE OR REPLACE FUNCTION erp._cur_ctx_base(p_company varchar, p_obj integer, p_bl jsonb, p_date date, p_header jsonb) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_base  integer := CASE p_obj WHEN 15 THEN 17 WHEN 13 THEN 15 WHEN 14 THEN 13 WHEN 20 THEN 22 WHEN 18 THEN 20 END;
  v_lc    text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_curs  text[];
  v_rates numeric[];
  v_cur   text;
  v_rate  numeric;
  v_head  text := upper(nullif(btrim(p_header->>'currency'), ''));
  v_typed numeric := erp._num(nullif(btrim(p_header->>'fx_rate'), ''));
  v_noun  text := erp._cur_noun(p_obj);
  e       jsonb;
BEGIN
  SELECT array_agg(DISTINCT coalesce(d.currency, v_lc) ORDER BY coalesce(d.currency, v_lc)),
         array_agg(DISTINCT coalesce(d.fx_rate, 1) ORDER BY coalesce(d.fx_rate, 1))
    INTO v_curs, v_rates
    FROM erp.document d
   WHERE d.company_code = p_company AND d.obj_type = v_base
     AND d.doc_entry IN (SELECT (x->>'base_doc_entry')::integer FROM jsonb_array_elements(coalesce(p_bl, '[]'::jsonb)) x);
  IF coalesce(array_length(v_curs, 1), 0) = 0 THEN
    PERFORM erp._cur_ctx_set(NULL, NULL);
    RETURN 1;
  END IF;
  IF array_length(v_curs, 1) > 1 THEN
    RAISE EXCEPTION 'The lines you copy are in more than one currency (%). Copy the documents of one currency at a time.', array_to_string(v_curs, ', ')
      USING ERRCODE = 'P0001';
  END IF;
  v_cur := v_curs[1];
  IF v_head IS NOT NULL AND v_head <> v_cur THEN
    RAISE EXCEPTION 'The lines you copy are in %, so this % is in % too. The currency can''t be changed on a copy.', v_cur, v_noun, v_cur
      USING ERRCODE = 'P0001';
  END IF;
  IF v_cur = v_lc THEN
    PERFORM erp._cur_ctx_set(v_lc, 1);
    RETURN 1;
  END IF;
  IF p_obj IN (15, 14, 20) THEN
    -- Keeps the rate of the document it is copied from.
    IF array_length(v_rates, 1) > 1 THEN
      RAISE EXCEPTION 'The lines you copy have different exchange rates (%). Copy the documents of one rate at a time.',
        (SELECT string_agg(trim_scale(r)::text, ', ') FROM unnest(v_rates) r) USING ERRCODE = 'P0001';
    END IF;
    v_rate := v_rates[1];
    IF v_typed IS NOT NULL AND v_typed <> v_rate THEN
      RAISE EXCEPTION 'This % keeps the exchange rate of the document it is copied from (%).', v_noun, trim_scale(v_rate) USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- Own posting date's rate (A/R invoice, A/P invoice).
    e := erp._cur_pick(p_company, NULL, NULL, v_cur, p_header->>'fx_rate', p_date, '');
    IF e->>'error' IS NOT NULL THEN
      RAISE EXCEPTION '%', e->>'error' USING ERRCODE = 'P0001';
    END IF;
    v_rate := (e->>'rate')::numeric;
  END IF;
  PERFORM erp._cur_ctx_set(v_cur, v_rate);
  RETURN v_rate;
END $$;

-- Currency and rate of a document without a base (direct service invoice): from the header / the partner. Sets the context.
CREATE OR REPLACE FUNCTION erp._cur_ctx_card(p_company varchar, p_card text, p_date date, p_header jsonb, p_noun text) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  e jsonb;
BEGIN
  e := erp._cur_pick(p_company, p_card, (SELECT currency FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card),
                     p_header->>'currency', p_header->>'fx_rate', p_date, p_noun);
  IF e->>'error' IS NOT NULL THEN
    RAISE EXCEPTION '%', e->>'error' USING ERRCODE = 'P0001';
  END IF;
  PERFORM erp._cur_ctx_set(e->>'currency', (e->>'rate')::numeric);
  RETURN (e->>'rate')::numeric;
END $$;

-- ============ 4. Lines of foreign-currency documents: DC → LC ============
-- Every create function computes line amounts in the document currency. For a Super ERP document whose currency is not the
-- company currency, this moves them to the *_fc columns and stores LC = round(DC × rate, 2). LC documents are untouched.
CREATE OR REPLACE FUNCTION erp._cur_line_fc() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d record;
BEGIN
  SELECT doc.currency, doc.fx_rate, doc.source, c.currency AS lc INTO d
    FROM erp.document doc JOIN erp.company c ON c.company_code = doc.company_code
   WHERE doc.company_code = NEW.company_code AND doc.obj_type = NEW.obj_type AND doc.doc_entry = NEW.doc_entry;
  IF d.source = 'erp' AND d.currency IS NOT NULL AND d.currency <> d.lc AND coalesce(d.fx_rate, 0) > 0 AND NEW.line_total_fc IS NULL THEN
    NEW.currency := d.currency;
    NEW.line_total_fc := NEW.line_total;
    NEW.vat_fc := NEW.vat;
    NEW.line_total := round(NEW.line_total_fc * d.fx_rate, 2);
    NEW.vat := CASE WHEN NEW.vat_fc IS NULL THEN NULL ELSE round(NEW.vat_fc * d.fx_rate, 2) END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS cur_line_fc ON erp.document_line;
CREATE TRIGGER cur_line_fc BEFORE INSERT ON erp.document_line FOR EACH ROW
  WHEN (current_setting('erp.sync', true) IS DISTINCT FROM 'on') EXECUTE FUNCTION erp._cur_line_fc();

-- Totals of a Super ERP document from its lines (replaces 19): LC always, DC for foreign-currency documents. Returns the LC total.
CREATE OR REPLACE FUNCTION erp._sd_retotal(p_company varchar, p_obj integer, p_entry integer) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_total numeric;
BEGIN
  UPDATE erp.document d SET total = s.net + s.vat, vat_total = s.vat,
                            total_fc = CASE WHEN s.fc THEN s.net_fc + s.vat_fc ELSE d.total_fc END,
                            vat_total_fc = CASE WHEN s.fc THEN s.vat_fc ELSE d.vat_total_fc END
    FROM (SELECT coalesce(sum(line_total), 0) AS net, coalesce(sum(vat), 0) AS vat,
                 coalesce(sum(line_total_fc), 0) AS net_fc, coalesce(sum(vat_fc), 0) AS vat_fc, coalesce(bool_or(line_total_fc IS NOT NULL), false) AS fc
            FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry) s
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_entry AND d.source = 'erp'
  RETURNING d.total INTO v_total;
  RETURN v_total;
END $$;

-- ============ 5. Open amounts in the document currency ============
-- What is still open on a foreign-currency document, in its own currency (NULL for LC documents). Same rule as _bk_doc_open.
CREATE OR REPLACE FUNCTION erp._bk_doc_open_fc(p_company varchar, p_obj integer, p_entry integer) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d   erp.document;
  v_c numeric := 0;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry;
  IF NOT FOUND OR d.total_fc IS NULL OR d.currency = (SELECT currency FROM erp.company WHERE company_code = p_company) THEN RETURN NULL; END IF;
  IF p_obj IN (13, 18) THEN
    SELECT coalesce(sum(coalesce(cl.line_total_fc, 0) + coalesce(cl.vat_fc, 0)), 0) INTO v_c
      FROM erp.document_line cl
      JOIN erp.document c ON c.company_code = cl.company_code AND c.obj_type = cl.obj_type AND c.doc_entry = cl.doc_entry
     WHERE cl.company_code = p_company AND cl.obj_type = p_obj + 1 AND cl.base_obj_type = p_obj AND cl.base_doc_entry = p_entry
       AND c.status NOT IN ('cancelled', 'cancellation');
  ELSIF p_obj IN (14, 19) THEN
    SELECT coalesce(sum(coalesce(line_total_fc, 0) + coalesce(vat_fc, 0)), 0) INTO v_c
      FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry AND base_obj_type = p_obj - 1;
  END IF;
  RETURN round(coalesce(d.total_fc, 0) - coalesce(d.paid_fc, 0) - v_c, 2);
END $$;

-- LC cleared when p_amount_fc of a foreign-currency document is paid: in proportion to what is open, the whole LC rest on the
-- payment that clears the FC in full (so a fully paid document is fully paid in both currencies).
CREATE OR REPLACE FUNCTION erp._cur_clear_lc(p_company varchar, p_obj integer, p_entry integer, p_amount_fc numeric) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_ofc numeric := erp._bk_doc_open_fc(p_company, p_obj, p_entry);
  v_olc numeric := erp._bk_doc_open(p_company, p_obj, p_entry);
BEGIN
  IF v_ofc IS NULL OR v_ofc <= 0 THEN
    RETURN round(p_amount_fc * coalesce((SELECT fx_rate FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_entry), 1), 2);
  ELSIF p_amount_fc >= v_ofc THEN
    RETURN v_olc;
  END IF;
  RETURN round(p_amount_fc * v_olc / v_ofc, 2);
END $$;

-- Open items per partner and currency (Super ERP documents), both in the document currency and in LC. Owner rights (the
-- open-amount helpers are internal); the access rule is in WHERE: the company, and Sales (receivables) / Purchasing
-- (payables) / Banking / Financials.
DROP VIEW IF EXISTS erp.bp_balance_fc;
CREATE VIEW erp.bp_balance_fc AS
SELECT d.company_code, d.card_code, max(d.card_name) AS card_name, d.currency,
       CASE WHEN d.obj_type IN (13, 14) THEN 'receivable' ELSE 'payable' END AS side,
       count(*) AS docs,
       round(sum(CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END * erp._bk_doc_open_fc(d.company_code, d.obj_type, d.doc_entry)), 2) AS open_fc,
       round(sum(CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END * erp._bk_doc_open(d.company_code, d.obj_type, d.doc_entry)), 2) AS open_lc
  FROM erp.document d
 WHERE d.source = 'erp' AND d.obj_type IN (13, 14, 18, 19, 204) AND d.status NOT IN ('cancelled', 'cancellation', 'draft') AND d.total_fc IS NOT NULL
   AND erp.can_see(d.company_code)
   AND (erp.can_read('finance') OR erp.can_read('banking') OR (d.obj_type IN (13, 14) AND erp.can_read('sales')) OR (d.obj_type IN (18, 19, 204) AND erp.can_read('purchase')))
 GROUP BY d.company_code, d.card_code, d.currency, CASE WHEN d.obj_type IN (13, 14) THEN 'receivable' ELSE 'payable' END;
REVOKE ALL ON erp.bp_balance_fc FROM PUBLIC, anon;
GRANT SELECT ON erp.bp_balance_fc TO authenticated;

-- Last purchase price (replaces 21): + the document's currency and the price in LC, so a form can compare in its own currency.
CREATE OR REPLACE FUNCTION erp._pd_last_price(p_company varchar, p_item text, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object('price', l.price, 'doc_no', coalesce(w.doc_no, d.doc_num::text), 'doc_date', d.doc_date, 'obj_type', d.obj_type,
                            'card_code', d.card_code, 'currency', coalesce(d.currency, c.currency),
                            'price_lc', CASE WHEN coalesce(d.currency, c.currency) = c.currency THEN l.price ELSE round(l.price * coalesce(d.fx_rate, 1), 6) END)
    FROM erp.document_line l
    JOIN erp.document d ON d.company_code = l.company_code AND d.obj_type = l.obj_type AND d.doc_entry = l.doc_entry
    JOIN erp.company c ON c.company_code = d.company_code
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE l.company_code = p_company AND l.item_code = p_item AND l.obj_type IN (22, 20, 18) AND l.price > 0
     AND d.status NOT IN ('draft', 'cancelled', 'cancellation') AND NOT (d.obj_type = 22 AND d.doc_entry IS NOT DISTINCT FROM p_doc_entry)
   ORDER BY d.doc_date DESC, d.doc_entry DESC, l.line_num
   LIMIT 1
$$;

-- The last price in the form's currency: the same currency as it was bought in, else through LC at the form's rate.
CREATE OR REPLACE FUNCTION erp._cur_last_dc(p_last jsonb, p_cur text, p_rate numeric) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN p_last IS NULL OR p_last->>'currency' IS NULL OR p_last->>'currency' = p_cur THEN p_last
              WHEN coalesce(p_rate, 0) <= 0 THEN p_last || jsonb_build_object('price', NULL)
              ELSE p_last || jsonb_build_object('price', round((p_last->>'price_lc')::numeric / p_rate, 6), 'bought_in', p_last->>'currency') END
$$;
