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
--   p_kept    the rate already stored on the document / draft being re-checked (submit, approval): accepted as it is.
DROP FUNCTION IF EXISTS erp._cur_pick(varchar, text, text, text, text, date, text);
CREATE OR REPLACE FUNCTION erp._cur_pick(p_company varchar, p_card text, p_bp_cur text, p_head text, p_head_rate text, p_date date, p_noun text,
                                         p_kept numeric DEFAULT NULL)
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
    ELSIF NOT erp.can_write('finance') AND v_typed IS DISTINCT FROM p_kept THEN
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

-- Open items per partner and currency (Super ERP documents), both in the document currency and in LC (same rule as
-- _bk_doc_open / _bk_doc_open_fc). Owner rights; the access rule is in WHERE: the company, and Sales (receivables) /
-- Purchasing (payables) / Banking / Financials.
DROP VIEW IF EXISTS erp.bp_balance_fc;
CREATE VIEW erp.bp_balance_fc AS
SELECT d.company_code, d.card_code, max(d.card_name) AS card_name, d.currency,
       CASE WHEN d.obj_type IN (13, 14) THEN 'receivable' ELSE 'payable' END AS side,
       count(*) AS docs,
       round(sum(CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END * (coalesce(d.total_fc, 0) - coalesce(d.paid_fc, 0) - cm.fc)), 2) AS open_fc,
       round(sum(CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END * (coalesce(d.total, 0) - coalesce(d.paid, 0) - cm.lc)), 2) AS open_lc
  FROM erp.document d
  CROSS JOIN LATERAL (
    -- credit memos based on an invoice (13 / 18), or the part of a credit memo based on invoices (14 / 19), as in _bk_doc_open
    SELECT coalesce(sum(coalesce(cl.line_total_fc, 0) + coalesce(cl.vat_fc, 0)), 0) AS fc, coalesce(sum(cl.line_total + coalesce(cl.vat, 0)), 0) AS lc
      FROM erp.document_line cl
      JOIN erp.document c ON c.company_code = cl.company_code AND c.obj_type = cl.obj_type AND c.doc_entry = cl.doc_entry
     WHERE cl.company_code = d.company_code
       AND ((d.obj_type IN (13, 18) AND cl.obj_type = d.obj_type + 1 AND cl.base_obj_type = d.obj_type AND cl.base_doc_entry = d.doc_entry
             AND c.status NOT IN ('cancelled', 'cancellation'))
         OR (d.obj_type IN (14, 19) AND cl.obj_type = d.obj_type AND cl.doc_entry = d.doc_entry AND cl.base_obj_type = d.obj_type - 1))) cm
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


-- ============ 6. Posting: foreign-currency amounts on journal lines ============

-- ---- post_journal: copied from 18_posting.sql:329.
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

  e := erp._je_lines_eval(p_company, p_lines, coalesce((s->>'allow_control')::boolean, false));
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
    RAISE EXCEPTION '%', format('Debits %s and credits %s don''t balance. Difference %s %s.', erp._money(v_d), erp._money(v_c), erp._money(abs(v_d - v_c)), v_cur)
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
  WITH je AS (
    INSERT INTO erp.journal_entry (company_code, trans_id, number, ref_date, due_date, tax_date, memo, ref1, ref2, ref3, trans_type, base_ref,
                                   total_local, total_sys, currency, reversal_of, source, created_on)
    VALUES (p_company, v_trans, v_trans, p_date, coalesce((s->>'due_date')::date, p_date), coalesce((s->>'tax_date')::date, p_date),
            nullif(btrim(p_memo), ''), s->>'ref1', s->>'ref2', s->>'ref3', coalesce((s->>'trans_type')::integer, 30), s->>'base_ref',
            v_d, v_d, v_cur, (s->>'reversal_of')::integer, 'erp', current_date)
    RETURNING company_code, trans_id, ref_date, due_date
  )
  INSERT INTO erp.journal_line (company_code, trans_id, line_id, acct_code, short_name, debit, credit, memo, ref_date, due_date, tax_code, cost_centre,
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
    LEFT JOIN LATERAL (SELECT o.value AS v FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS o(value, ord) WHERE o.ord - 1 = x.line_id) p ON true;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (coalesce(erp.current_user_id()::text, 'system:posting'), p_company, coalesce(s->>'action', 'journal_post'), 'journal', v_trans::text,
          jsonb_build_object('trans_type', coalesce((s->>'trans_type')::integer, 30), 'ref_date', p_date, 'memo', p_memo, 'total', v_d,
                             'lines', (e->>'count')::integer, 'reversal_of', s->'reversal_of', 'source_object', s->'object',
                             'source_ref', s->'object_ref'));
  RETURN v_trans;
END $$;
-- B4: lines may carry fc_debit / fc_credit; source_ref.fc_currency / fc_rate; foreign-currency documents fill FC on every line.

-- ---- _reverse_journal: copied from 18_posting.sql:393.
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
                                         'fc_debit', l.fc_credit, 'fc_credit', l.fc_debit) ORDER BY l.line_id)
       FROM erp.journal_line l WHERE l.company_code = p_company AND l.trans_id = p_trans_id),
    jsonb_build_object('trans_type', je.trans_type, 'reversal_of', p_trans_id, 'ref1', je.ref1, 'ref2', je.ref2,
                       'base_ref', p_trans_id::text, 'allow_control', true, 'action', p_action,
                       'object', 'journal', 'object_ref', p_trans_id::text,
                       'fc_currency', (SELECT max(fc_currency) FROM erp.journal_line WHERE company_code = p_company AND trans_id = p_trans_id)));
  RETURN v_new;
END $$;
-- B4: the mirror keeps the foreign-currency amounts.

-- ============ 7. Sales and purchasing documents in the partner's currency ============

-- ---- _sd_new_doc: copied from 19_sales_cycle.sql:1490.
CREATE OR REPLACE FUNCTION erp._sd_new_doc(p_company varchar, p_obj integer, p_user uuid, p_card text, p_card_name text, p_date date, p_due date,
                                           p_ref text, p_comments text, p_slp integer, p_branch integer, p_whs text, p_return boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb;
  fx jsonb := erp._cur_ctx_take(p_company);
BEGIN
  nb := erp._sd_number(p_company, p_obj);
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                            customer_ref, currency, fx_rate, total, vat_total, paid, slp_code, branch_id, comments, created_on, source)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, (nb->>'num')::integer,
          CASE p_obj WHEN 15 THEN 'delivery' WHEN 13 THEN 'ar_invoice' ELSE 'ar_credit_note' END, 'open', p_date, coalesce(p_due, p_date), p_date,
          p_card, p_card_name, p_ref, fx->>'currency', (fx->>'rate')::numeric, 0, 0, 0, p_slp, p_branch, p_comments,
          current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code, return_stock)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, nb->>'no', 'approved', p_user, p_user, now(), now(), p_whs, p_return);
  RETURN nb;
END $$;
-- B4: currency and rate from the context set by the create function (_cur_ctx_base / _cur_ctx_card).

-- ---- _pd_new_doc: copied from 21_purchasing.sql:2056.
CREATE OR REPLACE FUNCTION erp._pd_new_doc(p_company varchar, p_obj integer, p_user uuid, p_card text, p_card_name text, p_date date, p_due date,
                                           p_ref text, p_comments text, p_branch integer, p_whs text, p_office text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  nb jsonb;
  fx jsonb := erp._cur_ctx_take(p_company);
BEGIN
  nb := erp._pd_number(p_company, p_obj);
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                            customer_ref, currency, fx_rate, total, vat_total, paid, branch_id, comments, created_on, source)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, (nb->>'num')::integer, erp._pd_kind(p_obj), 'open', p_date, coalesce(p_due, p_date), p_date,
          p_card, p_card_name, p_ref, fx->>'currency', (fx->>'rate')::numeric, 0, 0, 0, p_branch, p_comments,
          current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, whs_code, china_office)
  VALUES (p_company, p_obj, (nb->>'entry')::integer, nb->>'no', 'approved', p_user, p_user, now(), now(), p_whs, p_office);
  RETURN nb;
END $$;
-- B4: currency and rate from the context.

-- ---- _sd_base_lines: copied from 19_sales_cycle.sql:1413.
CREATE OR REPLACE FUNCTION erp._sd_base_lines(p_company varchar, p_obj integer, p_base_obj integer, p_lines jsonb, p_verb text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_out   jsonb := '[]';
  l       jsonb;
  i       integer := 0;
  n       text;
  v_entry integer;
  v_line  integer;
  v_qty   numeric;
  v_sum   numeric;
  d       erp.document;
  w       erp.doc_workflow;
  bl      erp.document_line;
  v_no    text;
  v_card  text;
  v_base  text := erp._sd_name(p_base_obj);
  v_lb    text := CASE p_base_obj WHEN 13 THEN 'A/R invoice' ELSE lower(erp._sd_name(p_base_obj)) END;
BEGIN
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one line.' USING ERRCODE = 'P0001';
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_entry := erp._num(l->>'base_doc_entry')::integer;
    v_line := erp._num(l->>'base_line')::integer;
    v_qty := erp._num(l->>'qty');
    IF v_entry IS NULL OR v_line IS NULL THEN
      RAISE EXCEPTION '%', n || format('choose the %s line to copy.', v_lb) USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', n || format('%s %s was not found in company %s.', v_lb, v_entry, p_company) USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry;
    v_no := coalesce(w.doc_no, d.doc_num::text);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION '%', format('%s %s came from %s, so it can''t be %s in Super ERP.', v_base, v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END, p_verb || 'ed') USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' OR d.status <> 'open' THEN
      RAISE EXCEPTION '%', format('%s %s is not open (%s). Only approved, open documents can be %s.', v_base, v_no,
        CASE WHEN w.state IS DISTINCT FROM 'approved' THEN replace(coalesce(w.state, d.status), '_', ' ') ELSE d.status END, p_verb || 'ed')
        USING ERRCODE = 'P0001';
    END IF;
    IF v_card IS NULL THEN
      v_card := d.card_code;
    ELSIF v_card IS DISTINCT FROM d.card_code THEN
      RAISE EXCEPTION 'All lines must be for the same customer: % is for %, not %.', v_no, d.card_code, v_card USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = p_base_obj AND doc_entry = v_entry AND line_num = v_line FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', n || format('%s %s has no line %s.', v_lb, v_no, v_line + 1) USING ERRCODE = 'P0001';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '%', n || 'quantity must be more than 0.' USING ERRCODE = 'P0001';
    END IF;
    -- The same base line may appear twice: add them up.
    SELECT coalesce(sum(erp._num(x->>'qty')), 0) INTO v_sum FROM jsonb_array_elements(v_lines) x
     WHERE erp._num(x->>'base_doc_entry')::integer = v_entry AND erp._num(x->>'base_line')::integer = v_line;
    IF coalesce(bl.line_status, 'O') <> 'O' OR v_sum > coalesce(bl.open_qty, 0) THEN
      RAISE EXCEPTION '%', n || format('you are %s %s of %s but only %s %s still open on %s %s.', p_verb || 'ing', trim_scale(v_sum), bl.item_code,
        trim_scale(CASE WHEN coalesce(bl.line_status, 'O') = 'O' THEN coalesce(bl.open_qty, 0) ELSE 0 END),
        CASE WHEN coalesce(bl.open_qty, 0) = 1 THEN 'is' ELSE 'are' END, v_lb, v_no) USING ERRCODE = 'P0001';
    END IF;
    v_out := v_out || jsonb_build_object('n', i, 'base_doc_entry', v_entry, 'base_line', v_line, 'base_doc_no', v_no, 'qty', v_qty,
      'whs_code', nullif(btrim(l->>'whs_code'), ''), 'item_code', bl.item_code, 'description', bl.description, 'uom', bl.uom,
      'price', bl.price, 'discount_pct', coalesce(bl.discount_pct, 0), 'tax_code', bl.tax_code, 'base_whs', bl.whs_code,
      'cost', bl.stock_price, 'base_qty', bl.quantity, 'base_line_total', coalesce(bl.line_total_fc, bl.line_total), 'base_vat', coalesce(bl.vat_fc, bl.vat),
      'card_code', d.card_code, 'card_name', d.card_name, 'slp_code', d.slp_code, 'branch_id', d.branch_id, 'customer_ref', d.customer_ref);
  END LOOP;
  RETURN v_out;
END $$;
-- B4: base amounts in the document currency.

-- ---- sales_delivery_create: copied from 19_sales_cycle.sql:1560.
CREATE OR REPLACE FUNCTION erp.sales_delivery_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  h      jsonb := coalesce(p_header, '{}'::jsonb);
  v_date date;
  v_hwhs text := nullif(btrim(h->>'whs_code'), '');
  bl     jsonb;
  v_out  jsonb := '[]';
  x      jsonb;
  it     erp.item;
  v_whs  text;
  v_cost numeric;
  v_oh   numeric;
  v_need numeric;
  v_neg  boolean;
  v_lt   numeric;
  v_rate numeric;
  nb     jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  i      integer := 0;
BEGIN
  u := erp._sd_guard(p_company, true, 15);
  v_date := erp._sd_doc_date(h);
  bl := erp._sd_base_lines(p_company, 15, 17, p_lines, 'deliver');
  PERFORM erp._cur_ctx_base(p_company, 15, bl, v_date, h);   -- B4: the order's currency and rate

  IF v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    v_whs := coalesce(x->>'whs_code', v_hwhs, x->>'base_whs');
    IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      RAISE EXCEPTION 'Line %: warehouse % does not exist or is inactive.', x->>'n', coalesce(v_whs, '(none)') USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = x->>'item_code';
    v_cost := NULL;
    IF coalesce(it.is_stock, false) THEN
      SELECT sb.on_hand, sb.avg_cost INTO v_oh, v_cost FROM erp.stock_balance sb
       WHERE sb.company_code = p_company AND sb.item_code = it.item_code AND sb.whs_code = v_whs;
      v_oh := coalesce(v_oh, 0);
      v_cost := coalesce(v_cost, it.avg_cost);
      IF v_cost IS NULL THEN
        RAISE EXCEPTION 'Line %: % has no average cost in %, so cost of goods sold can''t be posted. Ask Finance to check the item cost.',
          x->>'n', it.item_code, v_whs USING ERRCODE = 'P0001';
      END IF;
      -- Everything this delivery takes of the item from the warehouse, against what is on hand.
      SELECT coalesce(sum((y->>'qty')::numeric), 0) INTO v_need FROM jsonb_array_elements(bl) y
       WHERE y->>'item_code' = it.item_code AND coalesce(y->>'whs_code', v_hwhs, y->>'base_whs') = v_whs;
      SELECT allow_negative INTO v_neg FROM erp.warehouse_setting WHERE company_code = p_company AND whs_code = v_whs;
      IF v_oh - v_need < 0 AND NOT coalesce(v_neg, false) THEN
        RAISE EXCEPTION 'Line %: only % of % are in stock in %. Delivering % would make stock negative, and % does not allow negative stock.',
          x->>'n', trim_scale(greatest(v_oh, 0)), it.item_code, v_whs, trim_scale(v_need), v_whs USING ERRCODE = 'P0001';
      END IF;
    END IF;
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    -- The full remaining quantity of a line carries its remaining amount exactly; part quantities are priced from the line.
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('whs', v_whs, 'cost', v_cost, 'is_stock', coalesce(it.is_stock, false),
                                              'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  nb := erp._sd_new_doc(p_company, 15, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        (bl->0->>'slp_code')::integer, (bl->0->>'branch_id')::integer, v_hwhs);
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 15, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, (SELECT currency FROM erp.company WHERE company_code = p_company), (x->>'discount_pct')::numeric,
            (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric, x->>'whs', 'O', (x->>'cost')::numeric, (x->>'cost')::numeric,
            (x->>'slp_code')::integer, 17, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    IF (x->>'is_stock')::boolean THEN
      -- Committed was added when the order opened, in the order line's warehouse.
      PERFORM erp._stock_move(p_company, x->>'item_code', x->>'whs', 0, (x->>'qty')::numeric, (x->>'cost')::numeric, 15, v_entry, i, v_date,
                              CASE WHEN x->>'whs' = x->>'base_whs' THEN (x->>'qty')::numeric ELSE 0 END);
      IF x->>'whs' IS DISTINCT FROM x->>'base_whs' THEN
        UPDATE erp.stock_balance SET committed = greatest(committed - (x->>'qty')::numeric, 0)
         WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'base_whs';
      END IF;
    END IF;
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 15, v_entry);
  PERFORM erp._sd_consume(p_company, 17, bl);
  v_trans := erp.post_document(p_company, 15, v_entry);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'delivery_create', 'delivery', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'orders', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);
END $$;
-- B4: keeps the order's currency and rate.

-- ---- _sd_inv_exec: copied from 30_numbering_company.sql:1375.
CREATE OR REPLACE FUNCTION erp._sd_inv_exec(p_company varchar, p_header jsonb, p_lines jsonb, p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_base  jsonb := '[]';
  v_svc   jsonb := '[]';
  bl      jsonb := '[]';
  v_out   jsonb := '[]';
  x       jsonb;
  v_date  date;
  v_due   date;
  v_card  text := nullif(btrim(h->>'card_code'), '');
  bp      erp.business_partner;
  it      erp.item;
  tc      erp.tax_code;
  v_cur   text;
  v_price numeric;
  v_qty   numeric;
  v_disc  numeric;
  v_tax   text;
  v_lt    numeric;
  v_rate  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_def_tax text;
  i       integer := 0;
  n       text;
BEGIN
  SELECT * INTO u FROM erp.app_user WHERE user_id = p_user;
  v_date := erp._sd_doc_date(h);
  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'Add at least one line.' USING ERRCODE = 'P0001';
  END IF;
  SELECT jsonb_agg(l) FILTER (WHERE l ? 'base_doc_entry' AND nullif(l->>'base_doc_entry', '') IS NOT NULL),
         jsonb_agg(l) FILTER (WHERE NOT (l ? 'base_doc_entry' AND nullif(l->>'base_doc_entry', '') IS NOT NULL))
    INTO v_base, v_svc FROM jsonb_array_elements(v_lines) l;
  v_base := coalesce(v_base, '[]'::jsonb);
  v_svc := coalesce(v_svc, '[]'::jsonb);
  IF jsonb_array_length(v_base) > 0 THEN
    bl := erp._sd_base_lines(p_company, 13, 15, v_base, 'invoic');
    IF v_card IS NOT NULL AND v_card IS DISTINCT FROM bl->0->>'card_code' THEN
      RAISE EXCEPTION 'The deliveries are for customer %, not %.', bl->0->>'card_code', v_card USING ERRCODE = 'P0001';
    END IF;
    v_card := bl->0->>'card_code';
  END IF;

  IF v_card IS NULL THEN
    RAISE EXCEPTION 'Choose a customer.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  IF NOT FOUND OR bp.card_code IS NULL THEN
    RAISE EXCEPTION 'Customer % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  ELSIF bp.kind <> 'customer' THEN
    RAISE EXCEPTION '% is not a customer. Choose a customer.', v_card USING ERRCODE = 'P0001';
  ELSIF NOT bp.active THEN
    RAISE EXCEPTION 'Customer % is inactive. Choose an active customer.', v_card USING ERRCODE = 'P0001';
  END IF;
  -- B4: copied deliveries keep their currency (rate of the invoice date); service-only invoices use the customer's currency.
  IF jsonb_array_length(bl) > 0 THEN
    PERFORM erp._cur_ctx_base(p_company, 13, bl, v_date, h);
  ELSE
    PERFORM erp._cur_ctx_card(p_company, v_card, v_date, h, 'Customer');
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      RAISE EXCEPTION 'The due date is not a valid date.' USING ERRCODE = 'P0001';
    ELSIF v_due < v_date THEN
      RAISE EXCEPTION 'The due date can''t be before the posting date.' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT v_date + coalesce(pt.extra_days, 0) + make_interval(months => coalesce(pt.extra_months, 0)) INTO v_due
      FROM erp.payment_terms pt WHERE pt.company_code = p_company AND pt.group_num = bp.payment_terms;
    v_due := coalesce(v_due, v_date);
  END IF;

  -- Delivery lines: price, discount and tax as delivered; cost carried for a later credit memo.
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('base_obj_type', 15, 'whs', x->>'base_whs', 'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  -- Service lines: non-stock sales items only; stock items go through a delivery first.
  SELECT default_tax_code INTO v_def_tax FROM erp.sales_setting WHERE company_code = p_company;
  FOR x IN SELECT value FROM jsonb_array_elements(v_svc) LOOP
    i := i + 1;
    n := format('Line %s: ', jsonb_array_length(bl) + i);
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = nullif(btrim(x->>'item_code'), '');
    IF nullif(btrim(x->>'item_code'), '') IS NULL THEN
      RAISE EXCEPTION '%', n || 'choose an item.' USING ERRCODE = 'P0001';
    ELSIF it.item_code IS NULL THEN
      RAISE EXCEPTION '%', n || format('item %s does not exist. Check the item code.', x->>'item_code') USING ERRCODE = 'P0001';
    ELSIF NOT it.active OR NOT coalesce(it.is_sold, false) THEN
      RAISE EXCEPTION '%', n || format('%s is not an active sales item.', it.item_code) USING ERRCODE = 'P0001';
    ELSIF coalesce(it.is_stock, false) THEN
      RAISE EXCEPTION '%', n || format('%s is a stock item. Deliver it first, then copy the delivery to an invoice.', it.item_code) USING ERRCODE = 'P0001';
    END IF;
    v_qty := erp._num(x->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '%', n || 'quantity must be more than 0.' USING ERRCODE = 'P0001';
    END IF;
    v_disc := coalesce(erp._num(nullif(btrim(x->>'discount_pct'), '')), 0);
    IF v_disc < 0 OR v_disc > 100 THEN
      RAISE EXCEPTION '%', n || 'discount must be between 0 and 100%.' USING ERRCODE = 'P0001';
    END IF;
    IF nullif(btrim(x->>'price'), '') IS NOT NULL THEN
      v_price := erp._num(x->>'price');
      IF v_price IS NULL OR v_price < 0 THEN
        RAISE EXCEPTION '%', n || 'price must be a number of 0 or more.' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      SELECT erp._cur_conv(p_company, ip.price, coalesce(ip.currency, v_cur), coalesce(nullif(current_setting('erp.fx_cur', true), ''), v_cur), v_date)
        INTO v_price FROM erp.item_price ip WHERE ip.company_code = p_company AND ip.list_num = bp.price_list AND ip.item_code = it.item_code;
      IF v_price IS NULL THEN
        RAISE EXCEPTION '%', n || format('%s has no price in the customer''s price list. Enter a price.', it.item_code) USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_tax := coalesce(nullif(btrim(x->>'tax_code'), ''), v_def_tax);
    SELECT * INTO tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
    IF v_tax IS NULL THEN
      RAISE EXCEPTION '%', n || 'choose a tax code.' USING ERRCODE = 'P0001';
    ELSIF tc.code IS NULL OR NOT tc.active OR tc.category = 'I' THEN
      RAISE EXCEPTION '%', n || format('tax code %s is not an active sales tax code.', v_tax) USING ERRCODE = 'P0001';
    END IF;
    v_lt := round(v_qty * v_price * (1 - v_disc / 100), 2);
    v_out := v_out || jsonb_build_object('item_code', it.item_code, 'description', it.name, 'uom', it.sales_uom, 'qty', v_qty, 'price', v_price,
      'discount_pct', v_disc, 'tax_code', v_tax, 'line_total', v_lt, 'vat', round(v_lt * tc.rate / 100, 2), 'whs', NULL, 'cost', NULL,
      'slp_code', bp.slp_code);
  END LOOP;

  nb := erp._sd_new_doc(p_company, 13, u.user_id, v_card, bp.name, v_date, v_due,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        coalesce((bl->0->>'slp_code')::integer, bp.slp_code), (bl->0->>'branch_id')::integer, NULL);
  v_entry := (nb->>'entry')::integer;
  i := 0;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 13, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, v_cur, (x->>'discount_pct')::numeric, (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric,
            x->>'whs', 'O', (x->>'cost')::numeric, (x->>'cost')::numeric, (x->>'slp_code')::integer,
            (x->>'base_obj_type')::integer, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 13, v_entry);
  IF jsonb_array_length(bl) > 0 THEN
    PERFORM erp._sd_consume(p_company, 15, bl);
  END IF;
  v_trans := erp.post_document(p_company, 13, v_entry);
  PERFORM erp._bp_balance_add(p_company, v_card, v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ar_invoice_create', 'ar_invoice', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', v_card, 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'deliveries', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans, 'due_date', v_due);
END $$;
-- B4: foreign-currency invoices (the invoice date's rate); price-list prices converted to the invoice currency.

-- ---- _sd_cm_exec: copied from 30_numbering_company.sql:1540.
CREATE OR REPLACE FUNCTION erp._sd_cm_exec(p_company varchar, p_header jsonb, p_lines jsonb, p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_ret   boolean := coalesce((h->>'return_stock')::boolean, false);
  v_hwhs  text := nullif(btrim(h->>'whs_code'), '');
  bl      jsonb;
  v_out   jsonb := '[]';
  x       jsonb;
  it      erp.item;
  v_date  date;
  v_whs   text;
  v_lt    numeric;
  v_rate  numeric;
  v_cost  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_cur   text;
  i       integer := 0;
BEGIN
  SELECT * INTO u FROM erp.app_user WHERE user_id = p_user;
  v_date := erp._sd_doc_date(h);
  bl := erp._sd_base_lines(p_company, 14, 13, p_lines, 'credit');
  PERFORM erp._cur_ctx_base(p_company, 14, bl, v_date, h);   -- B4: the invoice's currency and rate
  IF v_ret AND v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = x->>'item_code';
    v_whs := CASE WHEN v_ret AND coalesce(it.is_stock, false) THEN coalesce(v_hwhs, x->>'base_whs') ELSE x->>'base_whs' END;
    v_cost := (x->>'cost')::numeric;
    IF v_ret AND coalesce(it.is_stock, false) THEN
      IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
        RAISE EXCEPTION 'Line %: choose an active warehouse for the returned goods.', x->>'n' USING ERRCODE = 'P0001';
      END IF;
      IF v_cost IS NULL THEN
        v_cost := coalesce((SELECT avg_cost FROM erp.stock_balance WHERE company_code = p_company AND item_code = it.item_code AND whs_code = v_whs), it.avg_cost, 0);
      END IF;
    END IF;
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    -- Crediting the whole remaining quantity of a line returns exactly what is left of its amount.
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric * (1 - (x->>'discount_pct')::numeric / 100), 2);
    v_out := v_out || (x || jsonb_build_object('whs', v_whs, 'cost', v_cost, 'stock_back', v_ret AND coalesce(it.is_stock, false),
                                              'line_total', v_lt, 'vat', round(v_lt * coalesce(v_rate, 0) / 100, 2)));
  END LOOP;

  nb := erp._sd_new_doc(p_company, 14, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        coalesce(nullif(btrim(h->>'customer_ref'), ''), bl->0->>'customer_ref'), nullif(btrim(h->>'comments'), ''),
                        (bl->0->>'slp_code')::integer, (bl->0->>'branch_id')::integer, CASE WHEN v_ret THEN v_hwhs END, v_ret);
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(v_out) LOOP
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 14, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, 0, x->>'uom',
            (x->>'price')::numeric, v_cur, (x->>'discount_pct')::numeric, (x->>'line_total')::numeric, x->>'tax_code', (x->>'vat')::numeric,
            x->>'whs', 'C', (x->>'cost')::numeric, (x->>'cost')::numeric, (x->>'slp_code')::integer, 13, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    IF (x->>'stock_back')::boolean THEN
      PERFORM erp._stock_move(p_company, x->>'item_code', x->>'whs', (x->>'qty')::numeric, 0, (x->>'cost')::numeric, 14, v_entry, i, v_date);
    END IF;
    i := i + 1;
  END LOOP;
  v_total := erp._sd_retotal(p_company, 14, v_entry);
  PERFORM erp._sd_consume(p_company, 13, bl);
  v_trans := erp.post_document(p_company, 14, v_entry);
  PERFORM erp._bp_balance_add(p_company, bl->0->>'card_code', -v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ar_credit_memo_create', 'ar_credit_memo', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(v_out),
                             'return_stock', v_ret, 'invoices', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y),
                             'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);
END $$;
-- B4: keeps the invoice's currency and rate (so it nets against the invoice in both currencies).

-- ---- _sd_eval: copied from 31_approvals.sql:566.
CREATE OR REPLACE FUNCTION erp._sd_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_atp    jsonb := '[]';
  v_credit jsonb;
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  bp       erp.business_partner;
  v_bp_ok  boolean := false;
  v_doc_date date;
  v_due    date;
  v_pl     integer;
  v_terms  integer;
  v_slp    integer;
  v_whs    text;
  v_branch integer;
  v_def_tax text;
  v_def_whs text;
  l        jsonb;
  i        integer := 0;
  n        text;
  it       erp.item;
  v_item_ok boolean;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_disc   numeric;
  v_tax    text;
  v_tc     erp.tax_code;
  v_lwhs   text;
  v_ok     boolean;
  v_cost   numeric;
  v_avail  numeric;
  v_sb_cost numeric;
  v_gross  numeric := 0;
  v_net    numeric := 0;
  v_vat    numeric := 0;
  v_lt     numeric;
  v_lv     numeric;
  r        record;
  x        record;
  v_open   numeric;
  v_exposure numeric;
  v_bobj   integer;
  v_bentry integer;
  v_bline  integer;
  bd       erp.document;
  bw       erp.doc_workflow;
  bl       erp.document_line;
  v_bno    text;
  v_atpd   date;
  ar       erp.atp_rule;
  v_a      jsonb;
  v_used   jsonb := '{}'::jsonb;    -- item|whs → quantity already promised by earlier lines of this order
  v_key    text;
  v_prev   numeric;
  v_lcur   text;
  v_frate  numeric := 1;
  fx       jsonb;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT default_tax_code, default_whs_code INTO v_def_tax, v_def_whs FROM erp.sales_setting WHERE company_code = p_company;

  -- Customer
  IF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', 'Choose a customer.');
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s does not exist in company %s. Check the code.', v_card, p_company));
    ELSIF bp.kind <> 'customer' THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a customer. Choose a customer.', v_card));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Customer %s is inactive. Choose an active customer.', v_card));
    ELSE
      v_bp_ok := true;
      bp.balance := coalesce(bp.balance, 0) + coalesce((SELECT b.balance FROM erp.bp_balance_erp b WHERE b.company_code = p_company AND b.card_code = v_card), 0);
    END IF;
  END IF;

  -- Dates
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_doc_date := erp._date(h->>'doc_date');
    IF v_doc_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN p_obj = 23 THEN 'The valid-until date is not a valid date.' ELSE 'The delivery date is not a valid date.' END);
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN p_obj = 23 THEN 'The valid-until date can''t be before the posting date.' ELSE 'The delivery date can''t be before the posting date.' END);
    END IF;
  END IF;

  -- B4: document currency and rate (v_cur becomes the document currency; v_lcur is the company currency)
  v_lcur := v_cur;
  fx := erp._cur_pick(p_company, v_card, CASE WHEN v_bp_ok THEN bp.currency END, h->>'currency', h->>'fx_rate', v_doc_date, 'Customer',
                      (SELECT fx_rate FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry AND source = 'erp'));
  IF fx->>'error' IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', fx->>'field', 'message', fx->>'error');
  END IF;
  v_cur := fx->>'currency';
  v_frate := coalesce((fx->>'rate')::numeric, CASE WHEN v_cur = v_lcur THEN 1 END);

  -- Price list, payment terms, salesperson: the header value, else the customer's own
  v_pl := coalesce(erp._num(h->>'price_list')::integer, CASE WHEN v_bp_ok THEN bp.price_list END);
  IF v_pl IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.price_list WHERE company_code = p_company AND list_num = v_pl) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'price_list', 'message', format('Price list %s does not exist.', v_pl));
  END IF;
  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);
  IF v_terms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_terms) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'payment_terms', 'message', format('Payment terms %s do not exist.', v_terms));
  END IF;
  v_slp := coalesce(erp._num(h->>'slp_code')::integer, CASE WHEN v_bp_ok THEN bp.slp_code END);
  IF v_slp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.salesperson WHERE company_code = p_company AND slp_code = v_slp) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'slp_code', 'message', format('Salesperson %s does not exist.', v_slp));
  END IF;

  -- Header warehouse (lines use it unless they name their own)
  v_whs := coalesce(nullif(btrim(h->>'whs_code'), ''), v_def_whs);
  IF v_whs IS NOT NULL THEN
    SELECT branch_id INTO v_branch FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist in company %s.', v_whs, p_company));
    ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is inactive. Choose another warehouse.', v_whs));
    END IF;
  END IF;
  v_atpd := coalesce(v_due, v_doc_date);

  -- Lines
  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one line.');
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_ok := true;
    v_item_ok := false;
    v_code := nullif(btrim(l->>'item_code'), '');
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'choose an item.');
      v_ok := false;
    ELSE
      SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('item %s does not exist. Check the item code.', v_code));
        v_ok := false;
      ELSIF NOT it.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is inactive. Choose an active item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_sold, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a sales item.', v_code));
        v_ok := false;
      ELSE
        v_item_ok := true;
      END IF;
    END IF;

    v_qty := erp._num(l->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || 'quantity must be more than 0.');
      v_ok := false;
    END IF;

    v_disc := CASE WHEN nullif(btrim(l->>'discount_pct'), '') IS NULL THEN 0 ELSE erp._num(l->>'discount_pct') END;
    IF v_disc IS NULL OR v_disc < 0 OR v_disc > 100 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'discount_pct', 'message', n || 'discount must be between 0 and 100%.');
      v_ok := false;
    END IF;

    v_lwhs := coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs);
    IF v_lwhs IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || 'choose a warehouse.');
      v_ok := false;
    ELSIF v_lwhs IS DISTINCT FROM v_whs THEN
      IF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s does not exist in company %s.', v_lwhs, p_company));
        v_ok := false;
      ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs AND active) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s is inactive. Choose another warehouse.', v_lwhs));
        v_ok := false;
      END IF;
    END IF;

    v_tax := coalesce(nullif(btrim(l->>'tax_code'), ''), v_def_tax);
    v_tc := NULL;
    IF v_tax IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || 'choose a tax code.');
      v_ok := false;
    ELSE
      SELECT * INTO v_tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s does not exist.', v_tax));
        v_ok := false;
      ELSIF NOT v_tc.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is inactive.', v_tax));
        v_ok := false;
      ELSIF v_tc.category = 'I' THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is for purchases. Choose a sales tax code.', v_tax));
        v_ok := false;
      END IF;
    END IF;

    v_price := NULL;
    IF nullif(btrim(l->>'price'), '') IS NOT NULL THEN
      v_price := erp._num(l->>'price');
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price must be a number.');
        v_ok := false;
      ELSIF v_price < 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price can''t be negative.');
        v_ok := false;
      END IF;
    ELSIF v_item_ok AND v_pl IS NULL AND NOT v_bp_ok THEN
      v_ok := false;   -- no valid customer yet, so no price list to price from (the customer problem is already listed)
    ELSIF v_item_ok THEN
      SELECT CASE WHEN coalesce(ip.currency, v_lcur) = v_cur THEN ip.price
                  WHEN v_frate IS NULL THEN NULL
                  ELSE round(ip.price * erp._cur_rate(p_company, coalesce(ip.currency, v_lcur), v_doc_date) / v_frate, 6) END
        INTO v_price FROM erp.item_price ip WHERE ip.company_code = p_company AND ip.list_num = v_pl AND ip.item_code = v_code;
      IF v_price IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has no price in the customer''s price list. Enter a price.', v_code));
        v_ok := false;
      END IF;
    END IF;

    -- Copied from a quotation: the quotation must be a Super ERP one, open, for this customer and item, with enough left.
    v_bobj := erp._num(l->>'base_obj_type')::integer;
    v_bentry := erp._num(l->>'base_doc_entry')::integer;
    v_bline := erp._num(l->>'base_line')::integer;
    IF v_bentry IS NOT NULL OR v_bobj IS NOT NULL THEN
      IF p_obj <> 17 OR coalesce(v_bobj, 0) <> 23 OR v_bentry IS NULL OR v_bline IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'only a sales order can be copied from a quotation.');
        v_ok := false;
      ELSE
        SELECT * INTO bd FROM erp.document WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry;
        SELECT * INTO bw FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry;
        v_bno := coalesce(bw.doc_no, bd.doc_num::text);
        SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = 23 AND doc_entry = v_bentry AND line_num = v_bline;
        IF bd.doc_entry IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s was not found in company %s.', v_bentry, p_company));
          v_ok := false;
        ELSIF bd.source <> 'erp' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s came from %s. Only Super ERP quotations can be copied.',
            v_bno, CASE bd.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
          v_ok := false;
        ELSIF bw.state IS DISTINCT FROM 'approved' OR bd.status <> 'open' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('quotation %s is not open, so it can''t be copied.', v_bno));
          v_ok := false;
        ELSIF bd.card_code IS DISTINCT FROM v_card THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'card_code', 'message', n || format('quotation %s is for customer %s. Copy it to an order for the same customer.', v_bno, bd.card_code));
          v_ok := false;
        ELSIF bl.line_num IS NULL OR bl.item_code IS DISTINCT FROM v_code THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('the item does not match line %s of quotation %s.', v_bline + 1, v_bno));
          v_ok := false;
        ELSIF v_qty IS NOT NULL AND v_qty > coalesce(bl.open_qty, 0) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || format('only %s of %s are still open on quotation %s.', trim_scale(coalesce(bl.open_qty, 0)), v_code, v_bno));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    IF v_ok THEN
      SELECT sb.avg_cost, sb.on_hand - sb.committed INTO v_sb_cost, v_avail
        FROM erp.stock_balance sb WHERE sb.company_code = p_company AND sb.item_code = v_code AND sb.whs_code = v_lwhs;
      IF NOT FOUND THEN v_sb_cost := NULL; v_avail := NULL; END IF;
      v_cost := coalesce(v_sb_cost, it.avg_cost);
      v_lt := round(v_qty * v_price * (1 - v_disc / 100), 2);
      v_lv := round(v_lt * v_tc.rate / 100, 2);
      v_gross := v_gross + round(v_qty * v_price, 2);
      v_net := v_net + v_lt;
      v_vat := v_vat + v_lv;

      -- Available-to-Promise (orders, stock items, when the company has an ATP rule for the item)
      v_a := NULL;
      IF p_obj = 17 AND coalesce(it.is_stock, false) AND v_atpd IS NOT NULL THEN
        ar := erp._atp_rule(p_company, v_code);
        IF ar.rule_id IS NOT NULL THEN
          v_a := erp._atp(p_company, v_code, v_lwhs, v_atpd, ar);
          IF NOT (v_a->>'no_check')::boolean THEN
            v_key := v_code || '|' || CASE WHEN ar.whs_scope = 'all_whs' THEN '*' ELSE v_lwhs END;
            v_prev := coalesce((v_used->>v_key)::numeric, 0);
            v_used := v_used || jsonb_build_object(v_key, v_prev + v_qty);
            IF v_prev + v_qty > (v_a->>'available')::numeric THEN
              v_atp := v_atp || jsonb_build_object('line', i, 'item_code', v_code, 'whs_code', v_lwhs, 'qty', v_prev + v_qty,
                'available', (v_a->>'available')::numeric, 'date', v_atpd, 'rule_code', ar.rule_code,
                'message', format('Line %s: you are promising %s of %s but can promise only %s by %s.', i, trim_scale(v_prev + v_qty), v_code,
                                  trim_scale(greatest((v_a->>'available')::numeric, 0)), erp._day(v_atpd)));
            END IF;
          END IF;
        END IF;
      END IF;

      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.sales_uom, 'qty', v_qty, 'price', v_price,
        'discount_pct', v_disc, 'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs,
        'line_total', v_lt, 'vat', v_lv, 'cost', v_cost, 'available', v_avail, 'is_stock', coalesce(it.is_stock, false),
        'base_obj_type', CASE WHEN v_bentry IS NOT NULL THEN 23 END, 'base_doc_entry', v_bentry, 'base_line', CASE WHEN v_bentry IS NOT NULL THEN v_bline END,
        'atp', v_a);
    END IF;
  END LOOP;

  -- Credit position (orders; shown on the form even when no rule applies)
  IF v_bp_ok THEN
    SELECT coalesce(sum(total), 0) INTO v_open FROM erp.document
     WHERE company_code = p_company AND obj_type = 17 AND status = 'open' AND card_code = v_card AND (p_obj <> 17 OR doc_entry IS DISTINCT FROM p_doc_entry);
    v_credit := jsonb_build_object('limit', bp.credit_limit, 'balance', coalesce(bp.balance, 0), 'open_orders', v_open,
                                   'this_order', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'left', bp.credit_limit - coalesce(bp.balance, 0) - v_open,
                                   'currency', v_lcur);
  END IF;

  -- Rule checks (only for a document that is otherwise valid)
  IF jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 17, CASE WHEN p_obj = 17 THEN ARRAY['discount_pct', 'credit_limit', 'below_cost']
                                                              ELSE ARRAY['discount_pct', 'below_cost'] END, p_position) LOOP
      IF r.rule_code = 'discount_pct' THEN
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, discount_pct numeric, item_code text)
                  WHERE erp._apr_hit(r.conds, jsonb_build_object('discount_pct', t.discount_pct, 'doc_total', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) LOOP
          v_checks := v_checks || (r.ck || jsonb_build_object('line', x.line_num + 1, 'value', x.discount_pct, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Line %s: Discount %s%% is above your limit of %s%%. Submit it for approval or lower the discount.',
                                                   x.line_num + 1, erp._pct(x.discount_pct), erp._pct(r.limit_value))
                            ELSE erp._apr_msg(format('Line %s: Discount %s%%: ', x.line_num + 1, erp._pct(x.discount_pct)), r.template_name, r.conds) END));
        END LOOP;
      ELSIF r.rule_code = 'credit_limit' THEN
        -- NULL credit limit = not set in SAP: the rule does not apply to this customer.
        IF bp.credit_limit IS NOT NULL THEN
          v_exposure := coalesce(bp.balance, 0) + v_open + round((v_net + v_vat) * coalesce(v_frate, 1), 2);
          IF v_exposure > bp.credit_limit AND erp._apr_hit(r.conds, jsonb_build_object('credit_over', v_exposure - bp.credit_limit, 'doc_total', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) THEN
            v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', v_exposure, 'limit', bp.credit_limit,
              'message', format('Customer %s would be over the credit limit of %s %s: balance %s + open orders %s + this order %s = %s %s.',
                                v_card, erp._money(bp.credit_limit), v_lcur, erp._money(bp.balance), erp._money(v_open),
                                erp._money(round((v_net + v_vat) * coalesce(v_frate, 1), 2)), erp._money(v_exposure), v_lcur)));
          END IF;
        END IF;
      ELSIF r.rule_code = 'below_cost' THEN
        FOR x IN SELECT t0.line_num, t0.price, t0.discount_pct, round(t0.cost / coalesce(v_frate, 1), 4) AS cost, t0.item_code
                   FROM jsonb_to_recordset(v_out) AS t0(line_num int, price numeric, discount_pct numeric, cost numeric, item_code text)
                  WHERE t0.cost IS NOT NULL AND round(t0.price * (1 - t0.discount_pct / 100), 4) < round(t0.cost / coalesce(v_frate, 1), 4)
                    AND erp._apr_hit(r.conds, jsonb_build_object('below_cost_pct', CASE WHEN t0.cost > 0 THEN round((t0.cost / coalesce(v_frate, 1) - round(t0.price * (1 - t0.discount_pct / 100), 4)) / (t0.cost / coalesce(v_frate, 1)) * 100, 4) ELSE 0 END,
                                                                 'doc_total', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) LOOP
          v_checks := v_checks || (r.ck || jsonb_build_object('line', x.line_num + 1, 'value', round(x.price * (1 - x.discount_pct / 100), 4), 'limit', x.cost,
            'message', format('Line %s: net price %s for %s is below its cost of %s.',
                              x.line_num + 1, erp._money(x.price * (1 - x.discount_pct / 100)), x.item_code, erp._money(x.cost))));
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'atp', CASE WHEN jsonb_array_length(v_err) = 0 THEN v_atp ELSE '[]'::jsonb END,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date,
                                 'due_date', v_due, 'price_list', v_pl, 'payment_terms', v_terms, 'slp_code', v_slp, 'whs_code', v_whs,
                                 'branch_id', v_branch, 'customer_ref', nullif(btrim(h->>'customer_ref'), ''),
                                 'comments', nullif(btrim(h->>'comments'), ''), 'currency', v_cur, 'fx_rate', v_frate),
    'totals', jsonb_build_object('before_discount', v_gross, 'discount', v_gross - v_net, 'net', v_net, 'vat', v_vat,
                                 'total', v_net + v_vat, 'currency', v_cur, 'rate', v_frate, 'local_currency', v_lcur,
                                 'rate_overridden', coalesce((fx->>'overridden')::boolean, false),
                                 'total_lc', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'vat_lc', round(v_vat * coalesce(v_frate, 1), 2)),
    'credit', CASE WHEN p_obj = 17 THEN v_credit END);
END $$;
-- B4: the customer's currency (or the header's), the date's rate; prices in the document currency (price lists converted);
-- credit limit, discount and below-cost rules in LC; totals in DC with total_lc / rate.

-- ---- sales_doc_save: copied from 19_sales_cycle.sql:907.
CREATE OR REPLACE FUNCTION erp.sales_doc_save(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  e      jsonb;
  hd     jsonb;
  nb     jsonb;
  v_new  boolean := p_doc_entry IS NULL;
  v_entry integer;
  v_num  integer;
  v_no   text;
  v_nerr integer;
  v_noun text := erp._sd_noun(p_obj);
  v_obj  text := erp._sd_object(p_obj);
BEGIN
  PERFORM erp._sd_check_obj(p_obj);
  u := erp._sd_guard(p_company, true, p_obj);
  IF NOT v_new THEN
    w := erp._sd_lock(p_company, p_obj, p_doc_entry);
    IF w.state = 'pending_approval' THEN
      RAISE EXCEPTION 'This % is waiting for approval and can''t be edited. Ask the approver to reject it first.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.state = 'approved' THEN
      RAISE EXCEPTION 'This % is approved and can''t be edited.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.state = 'cancelled' THEN
      RAISE EXCEPTION 'This % is cancelled and can''t be edited.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.created_by <> u.user_id THEN
      RAISE EXCEPTION 'Only the person who created this % can change it.', v_noun USING ERRCODE = 'P0001';
    END IF;
  END IF;

  e := erp._sd_eval(p_company, p_obj, p_header, p_lines, u.position_code, p_doc_entry);
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this %s.', v_nerr - 1, v_noun) ELSE '' END;
  END IF;
  hd := e->'header';

  IF v_new THEN
    nb := erp._sd_number(p_company, p_obj);
    v_num := (nb->>'num')::integer;
    v_no := nb->>'no';
    v_entry := (nb->>'entry')::integer;
    INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                              customer_ref, currency, fx_rate, total, vat_total, paid, slp_code, branch_id, comments, created_on, source)
    VALUES (p_company, p_obj, v_entry, v_num, CASE p_obj WHEN 23 THEN 'sales_quotation' ELSE 'sales_order' END, 'draft',
            (hd->>'doc_date')::date, (hd->>'due_date')::date, (hd->>'doc_date')::date,
            hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', (e->'totals'->>'rate')::numeric, (e->'totals'->>'total_lc')::numeric,
            (e->'totals'->>'vat_lc')::numeric, 0, (hd->>'slp_code')::integer, (hd->>'branch_id')::integer, hd->>'comments', current_date, 'erp');
    INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, price_list, payment_terms, whs_code)
    VALUES (p_company, p_obj, v_entry, v_no, 'draft', u.user_id, (hd->>'price_list')::integer, (hd->>'payment_terms')::integer, hd->>'whs_code');
  ELSE
    v_entry := p_doc_entry;
    v_no := w.doc_no;
    SELECT doc_num INTO v_num FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    UPDATE erp.document
       SET status = 'draft', doc_date = (hd->>'doc_date')::date, due_date = (hd->>'due_date')::date, tax_date = (hd->>'doc_date')::date,
           card_code = hd->>'card_code', card_name = hd->>'card_name', customer_ref = hd->>'customer_ref',
           total = (e->'totals'->>'total_lc')::numeric, vat_total = (e->'totals'->>'vat_lc')::numeric, slp_code = (hd->>'slp_code')::integer,
           currency = e->'totals'->>'currency', fx_rate = (e->'totals'->>'rate')::numeric, total_fc = NULL, vat_total_fc = NULL,
           branch_id = (hd->>'branch_id')::integer, comments = hd->>'comments'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry AND source = 'erp';
    UPDATE erp.doc_workflow
       SET state = 'draft', updated_at = now(), price_list = (hd->>'price_list')::integer,
           payment_terms = (hd->>'payment_terms')::integer, whs_code = hd->>'whs_code'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    DELETE FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
  END IF;

  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                 discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, slp_code,
                                 base_obj_type, base_doc_entry, base_line)
  SELECT p_company, p_obj, v_entry, x.line_num, x.item_code, x.description, x.qty, x.qty, x.uom, x.price, e->'totals'->>'currency',
         x.discount_pct, x.line_total, x.tax_code, x.vat, x.whs_code, 'O', x.cost, x.cost, (hd->>'slp_code')::integer,
         x.base_obj_type, x.base_doc_entry, x.base_line
    FROM jsonb_to_recordset(e->'lines') AS x(line_num int, item_code text, description text, uom text, qty numeric, price numeric,
                                             discount_pct numeric, tax_code text, whs_code text, line_total numeric, vat numeric, cost numeric,
                                             base_obj_type int, base_doc_entry int, base_line int);
  PERFORM erp._sd_retotal(p_company, p_obj, v_entry);   -- B4: LC and DC totals from the lines

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN v_new THEN '_create' ELSE '_update' END, v_obj, v_entry::text,
          jsonb_build_object('doc_no', v_no, 'card_code', hd->>'card_code', 'total', e->'totals'->'total',
                             'lines', jsonb_array_length(e->'lines'), 'checks', jsonb_array_length(e->'checks'),
                             'copied_from', (SELECT jsonb_agg(DISTINCT x.base_doc_entry) FROM jsonb_to_recordset(e->'lines') AS x(base_doc_entry int)
                                              WHERE x.base_doc_entry IS NOT NULL)));

  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_num', v_num, 'doc_no', v_no, 'state', 'draft',
                            'totals', e->'totals', 'checks', e->'checks', 'atp', e->'atp', 'lines', e->'lines');
END $$;
-- B4: header currency + rate; totals from the lines (LC, and DC for foreign-currency documents).

-- ---- _sd_stored: copied from 19_sales_cycle.sql:586.
CREATE OR REPLACE FUNCTION erp._sd_stored(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('card_code', d.card_code, 'doc_date', d.doc_date, 'due_date', d.due_date, 'price_list', w.price_list,
                                 'payment_terms', w.payment_terms, 'slp_code', d.slp_code, 'whs_code', w.whs_code,
                                 'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'fx_rate', d.fx_rate),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', l.item_code, 'qty', l.quantity, 'price', l.price,
                                                          'discount_pct', l.discount_pct, 'tax_code', l.tax_code, 'whs_code', l.whs_code,
                                                          'base_obj_type', l.base_obj_type, 'base_doc_entry', l.base_doc_entry, 'base_line', l.base_line)
                                        ORDER BY l.line_num)
                         FROM erp.document_line l
                        WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry), '[]'::jsonb))
    FROM erp.document d
    JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_doc_entry
$$;
-- B4: + currency and rate (a re-check keeps them).

-- ---- _pd_stored: copied from 21_purchasing.sql:692.
CREATE OR REPLACE FUNCTION erp._pd_stored(p_company varchar, p_obj integer, p_doc_entry integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object('card_code', d.card_code, 'doc_date', d.doc_date, 'due_date', d.due_date, 'payment_terms', w.payment_terms,
                                 'whs_code', w.whs_code, 'china_office', w.china_office, 'customer_ref', d.customer_ref, 'comments', d.comments,
                                 'currency', d.currency, 'fx_rate', d.fx_rate),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item_code', l.item_code, 'qty', l.quantity, 'price', l.price, 'tax_code', l.tax_code,
                                                          'whs_code', l.whs_code, 'cbm', l.cbm, 'base_obj_type', l.base_obj_type,
                                                          'base_doc_entry', l.base_doc_entry, 'base_line', l.base_line) ORDER BY l.line_num)
                         FROM erp.document_line l
                        WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry), '[]'::jsonb))
    FROM erp.document d
    JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.obj_type = p_obj AND d.doc_entry = p_doc_entry
$$;
-- B4: + currency and rate.

-- ---- _pd_eval: copied from 31_approvals.sql:1203.
CREATE OR REPLACE FUNCTION erp._pd_eval(p_company varchar, p_obj integer, p_header jsonb, p_lines jsonb, p_position text, p_doc_entry integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_req    boolean := p_obj = 1470000113;
  v_po     boolean := p_obj = 22;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  bp       erp.business_partner;
  v_bp_ok  boolean := false;
  st       erp.purchase_setting;
  v_doc_date date;
  v_due    date;
  v_terms  integer;
  v_whs    text;
  v_branch integer;
  v_office text := nullif(btrim(h->>'china_office'), '');
  l        jsonb;
  i        integer := 0;
  n        text;
  it       erp.item;
  v_code   text;
  v_qty    numeric;
  v_price  numeric;
  v_tax    text;
  v_tc     erp.tax_code;
  v_lwhs   text;
  v_cbm    numeric;
  v_ok     boolean;
  v_lt     numeric;
  v_lv     numeric;
  v_net    numeric := 0;
  v_vat    numeric := 0;
  v_last   jsonb;
  v_bobj   integer;
  v_bentry integer;
  v_bline  integer;
  bd       erp.document;
  bw       erp.doc_workflow;
  bl       erp.document_line;
  v_bno    text;
  r        record;
  x        record;
  v_lcur   text;
  v_frate  numeric := 1;
  fx       jsonb;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.purchase_setting WHERE company_code = p_company;

  -- Supplier (quotations and orders; a request has none)
  IF v_req THEN
    v_card := NULL;
  ELSIF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', 'Choose a supplier.');
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Supplier %s does not exist in company %s. Check the code.', v_card, p_company));
    ELSIF bp.kind <> 'supplier' THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a supplier. Choose a supplier.', v_card));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Supplier %s is inactive. Choose an active supplier.', v_card));
    ELSE
      v_bp_ok := true;
    END IF;
  END IF;

  -- Dates
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_doc_date := erp._date(h->>'doc_date');
    IF v_doc_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NULL THEN
    IF v_req THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message', 'Choose the date the goods are needed by.');
    END IF;
  ELSE
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN v_req THEN 'The needed-by date is not a valid date.' WHEN v_po THEN 'The delivery date is not a valid date.' ELSE 'The valid-until date is not a valid date.' END);
    ELSIF v_doc_date IS NOT NULL AND v_due < v_doc_date THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'due_date', 'message',
        CASE WHEN v_req THEN 'The needed-by date can''t be before the posting date.' WHEN v_po THEN 'The delivery date can''t be before the posting date.'
             ELSE 'The valid-until date can''t be before the posting date.' END);
    END IF;
  END IF;

  -- B4: document currency and rate (a purchase request has no supplier: company currency)
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

  v_terms := coalesce(erp._num(h->>'payment_terms')::integer, CASE WHEN v_bp_ok THEN bp.payment_terms END);
  IF v_terms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.payment_terms WHERE company_code = p_company AND group_num = v_terms) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'payment_terms', 'message', format('Payment terms %s do not exist.', v_terms));
  END IF;

  IF v_office IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.china_office WHERE company_code = p_company AND code = v_office AND active) THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'china_office', 'message', format('China office %s is not set up for %s.', v_office, p_company));
  END IF;

  -- Header warehouse: the receiving warehouse (lines use it unless they name their own)
  v_whs := coalesce(nullif(btrim(h->>'whs_code'), ''), st.default_whs_code);
  IF v_whs IS NOT NULL THEN
    SELECT branch_id INTO v_branch FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s does not exist in company %s.', v_whs, p_company));
    ELSIF NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'whs_code', 'message', format('Warehouse %s is inactive. Choose another warehouse.', v_whs));
    END IF;
  END IF;

  -- Lines
  IF jsonb_array_length(v_lines) = 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'lines', 'message', 'Add at least one line.');
  END IF;
  FOR l IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_ok := true;
    v_code := nullif(btrim(l->>'item_code'), '');
    it := NULL;
    IF v_code IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'choose an item.');
      v_ok := false;
    ELSE
      SELECT * INTO it FROM erp.item WHERE company_code = p_company AND item_code = v_code;
      IF NOT FOUND THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('item %s does not exist. Check the item code.', v_code));
        v_ok := false;
      ELSIF NOT it.active THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is inactive. Choose an active item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_bought, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a purchase item.', v_code));
        v_ok := false;
      ELSIF NOT coalesce(it.is_stock, false) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s is not a stock item. Buying services comes in a later stage.', v_code));
        v_ok := false;
      END IF;
    END IF;

    v_qty := erp._num(l->>'qty');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || 'quantity must be more than 0.');
      v_ok := false;
    END IF;

    v_lwhs := coalesce(nullif(btrim(l->>'whs_code'), ''), v_whs);
    IF v_lwhs IS NULL THEN
      IF v_po THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || 'choose the warehouse the goods are received into.');
        v_ok := false;
      END IF;
    ELSIF v_lwhs IS DISTINCT FROM v_whs AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_lwhs AND active) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'whs_code', 'message', n || format('warehouse %s does not exist or is inactive.', v_lwhs));
      v_ok := false;
    END IF;

    v_cbm := NULL;
    IF nullif(btrim(l->>'cbm'), '') IS NOT NULL THEN
      v_cbm := erp._num(l->>'cbm');
      IF v_cbm IS NULL OR v_cbm < 0 THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'cbm', 'message', n || 'volume (CBM) must be a number of 0 or more.');
        v_ok := false;
      END IF;
    END IF;

    v_last := CASE WHEN v_code IS NOT NULL THEN erp._cur_last_dc(erp._pd_last_price(p_company, v_code, p_doc_entry), v_cur, v_frate) END;
    v_tc := NULL;
    v_tax := NULL;
    v_price := NULL;
    IF NOT v_req THEN
      v_tax := coalesce(nullif(btrim(l->>'tax_code'), ''), st.default_tax_code);
      IF v_tax IS NULL THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || 'choose a tax code.');
        v_ok := false;
      ELSE
        SELECT * INTO v_tc FROM erp.tax_code WHERE company_code = p_company AND code = v_tax;
        IF NOT FOUND THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s does not exist.', v_tax));
          v_ok := false;
        ELSIF NOT v_tc.active THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is inactive.', v_tax));
          v_ok := false;
        ELSIF v_tc.category = 'O' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'tax_code', 'message', n || format('tax code %s is for sales. Choose a purchase tax code.', v_tax));
          v_ok := false;
        END IF;
      END IF;
      IF nullif(btrim(l->>'price'), '') IS NOT NULL THEN
        v_price := erp._num(l->>'price');
        IF v_price IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price must be a number.');
          v_ok := false;
        ELSIF v_price < 0 THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || 'price can''t be negative.');
          v_ok := false;
        END IF;
      ELSIF v_code IS NOT NULL THEN
        v_price := (v_last->>'price')::numeric;
        IF v_price IS NULL AND it.item_code IS NOT NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'price', 'message', n || format('%s has never been bought, so there is no last price. Enter a price.', v_code));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    -- Copied from a request (quotation, order) or a quotation (order): Super ERP, approved and open, same item, enough left.
    v_bobj := erp._num(l->>'base_obj_type')::integer;
    v_bentry := erp._num(l->>'base_doc_entry')::integer;
    v_bline := erp._num(l->>'base_line')::integer;
    IF v_bentry IS NOT NULL OR v_bobj IS NOT NULL THEN
      IF v_req OR v_bentry IS NULL OR v_bline IS NULL OR NOT (v_bobj = 1470000113 OR (v_po AND v_bobj = 540000006)) THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || 'a quotation is copied from a request, and an order from a request or a quotation.');
        v_ok := false;
      ELSE
        SELECT * INTO bd FROM erp.document WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry;
        SELECT * INTO bw FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry;
        v_bno := coalesce(bw.doc_no, bd.doc_num::text);
        SELECT * INTO bl FROM erp.document_line WHERE company_code = p_company AND obj_type = v_bobj AND doc_entry = v_bentry AND line_num = v_bline;
        IF bd.doc_entry IS NULL THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s was not found in company %s.', lower(erp._pd_name(v_bobj)), v_bentry, p_company));
          v_ok := false;
        ELSIF bd.source <> 'erp' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s came from %s. Only Super ERP documents can be copied.',
            lower(erp._pd_name(v_bobj)), v_bno, CASE bd.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END));
          v_ok := false;
        ELSIF bw.state IS DISTINCT FROM 'approved' OR bd.status <> 'open' THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('%s %s is not open, so it can''t be copied.', lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        ELSIF v_bobj = 540000006 AND bd.card_code IS DISTINCT FROM v_card THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'card_code', 'message', n || format('quotation %s is from supplier %s. Copy it to an order for the same supplier.', v_bno, bd.card_code));
          v_ok := false;
        ELSIF bl.line_num IS NULL OR bl.item_code IS DISTINCT FROM v_code THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'item_code', 'message', n || format('the item does not match line %s of %s %s.', v_bline + 1, lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        ELSIF v_po AND v_qty IS NOT NULL AND (coalesce(bl.line_status, 'O') <> 'O' OR v_qty > coalesce(bl.open_qty, 0)) THEN
          v_err := v_err || jsonb_build_object('line', i, 'field', 'qty', 'message', n || format('only %s of %s are still open on %s %s.',
            trim_scale(CASE WHEN coalesce(bl.line_status, 'O') = 'O' THEN coalesce(bl.open_qty, 0) ELSE 0 END), v_code, lower(erp._pd_name(v_bobj)), v_bno));
          v_ok := false;
        END IF;
      END IF;
    END IF;

    IF v_ok THEN
      v_lt := CASE WHEN v_req THEN 0 ELSE round(v_qty * v_price, 2) END;
      v_lv := CASE WHEN v_req THEN 0 ELSE round(v_lt * v_tc.rate / 100, 2) END;
      v_net := v_net + v_lt;
      v_vat := v_vat + v_lv;
      v_out := v_out || jsonb_build_object(
        'line_num', i - 1, 'item_code', v_code, 'description', it.name, 'uom', it.purchase_uom, 'qty', v_qty, 'price', v_price,
        'tax_code', v_tax, 'tax_rate', v_tc.rate, 'whs_code', v_lwhs, 'cbm', v_cbm, 'line_total', v_lt, 'vat', v_lv,
        'last_price', v_last->'price', 'last_doc_no', v_last->>'doc_no', 'last_doc_date', v_last->>'doc_date',
        'base_obj_type', CASE WHEN v_bentry IS NOT NULL THEN v_bobj END, 'base_doc_entry', v_bentry,
        'base_line', CASE WHEN v_bentry IS NOT NULL THEN v_bline END);
    END IF;
  END LOOP;

  -- Purchase order rules (only for an order that is otherwise valid)
  IF v_po AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 22, ARRAY['po_amount', 'po_price_increase'], p_position) LOOP
      IF r.rule_code = 'po_amount' THEN
        IF erp._apr_hit(r.conds, jsonb_build_object('amount', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) THEN
          v_checks := v_checks || (r.ck || jsonb_build_object('line', NULL, 'value', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Purchase order total %s %s is above your limit of %s %s.', erp._money(round((v_net + v_vat) * coalesce(v_frate, 1), 2)), v_lcur, erp._money(r.limit_value), v_lcur)
                            ELSE erp._apr_msg(format('Purchase order total %s %s: ', erp._money(v_net + v_vat), v_cur), r.template_name, r.conds) END));
        END IF;
      ELSE
        FOR x IN SELECT * FROM jsonb_to_recordset(v_out) AS t(line_num int, item_code text, price numeric, last_price numeric, last_doc_no text)
                  WHERE t.last_price > 0 AND t.price > t.last_price
                    AND CASE WHEN r.std THEN t.price > round(t.last_price * (1 + r.limit_value / 100), 6)
                             ELSE erp._apr_hit(r.conds, jsonb_build_object('increase_pct', (t.price / t.last_price - 1) * 100, 'amount', round((v_net + v_vat) * coalesce(v_frate, 1), 2))) END LOOP
          v_checks := v_checks || (r.ck || jsonb_build_object('line', x.line_num + 1, 'value', round((x.price / x.last_price - 1) * 100, 2), 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('Line %s: price %s for %s is %s%% above the last purchase price of %s (%s). The limit is %s%%.',
                              x.line_num + 1, erp._money(x.price), x.item_code, erp._pct(round((x.price / x.last_price - 1) * 100, 2)),
                              erp._money(x.last_price), x.last_doc_no, erp._pct(r.limit_value))
                            ELSE erp._apr_msg(format('Line %s: price %s for %s is %s%% above the last purchase price: ', x.line_num + 1, erp._money(x.price), x.item_code,
                                                     erp._pct(round((x.price / x.last_price - 1) * 100, 2))), r.template_name, r.conds) END));
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', CASE WHEN v_bp_ok THEN bp.name END, 'doc_date', v_doc_date, 'due_date', v_due,
                                 'payment_terms', v_terms, 'whs_code', v_whs, 'branch_id', v_branch, 'china_office', v_office,
                                 'customer_ref', nullif(btrim(h->>'customer_ref'), ''), 'comments', nullif(btrim(h->>'comments'), ''),
                                 'currency', v_cur, 'fx_rate', v_frate),
    'totals', jsonb_build_object('net', v_net, 'vat', v_vat, 'total', v_net + v_vat, 'currency', v_cur, 'rate', v_frate, 'local_currency', v_lcur,
                                 'rate_overridden', coalesce((fx->>'overridden')::boolean, false),
                                 'total_lc', round((v_net + v_vat) * coalesce(v_frate, 1), 2), 'vat_lc', round(v_vat * coalesce(v_frate, 1), 2)));
END $$;
-- B4: the supplier's currency (or the header's), the date's rate; last prices in the document currency; amount rules in LC.

-- ---- purchase_doc_save: copied from 21_purchasing.sql:1114.
CREATE OR REPLACE FUNCTION erp.purchase_doc_save(p_company varchar, p_obj integer, p_doc_entry integer, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  w      erp.doc_workflow;
  e      jsonb;
  hd     jsonb;
  nb     jsonb;
  v_new  boolean := p_doc_entry IS NULL;
  v_entry integer;
  v_num  integer;
  v_no   text;
  v_nerr integer;
  v_noun text := erp._pd_noun(p_obj);
  v_obj  text := erp._pd_object(p_obj);
BEGIN
  PERFORM erp._pd_check_obj(p_obj);
  u := erp._pd_guard(p_company, true, CASE p_obj WHEN 22 THEN 'create purchase orders' ELSE 'create purchase quotations' END, false, p_obj = 1470000113);
  IF NOT v_new THEN
    w := erp._pd_lock(p_company, p_obj, p_doc_entry);
    IF w.state = 'pending_approval' THEN
      RAISE EXCEPTION 'This % is waiting for approval and can''t be edited. Ask the approver to reject it first.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.state = 'approved' THEN
      RAISE EXCEPTION 'This % is approved and can''t be edited.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.state = 'cancelled' THEN
      RAISE EXCEPTION 'This % is cancelled and can''t be edited.', v_noun USING ERRCODE = 'P0001';
    ELSIF w.created_by <> u.user_id THEN
      RAISE EXCEPTION 'Only the person who created this % can change it.', v_noun USING ERRCODE = 'P0001';
    END IF;
  END IF;

  e := erp._pd_eval(p_company, p_obj, p_header, p_lines, u.position_code, p_doc_entry);
  v_nerr := jsonb_array_length(e->'errors');
  IF v_nerr > 0 THEN
    RAISE EXCEPTION '%', e->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN v_nerr > 1 THEN format('%s more problem(s) on this %s.', v_nerr - 1, v_noun) ELSE '' END;
  END IF;
  hd := e->'header';

  IF v_new THEN
    nb := erp._pd_number(p_company, p_obj);
    v_num := (nb->>'num')::integer;
    v_no := nb->>'no';
    v_entry := (nb->>'entry')::integer;
    INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                              customer_ref, currency, fx_rate, total, vat_total, paid, branch_id, comments, created_on, source)
    VALUES (p_company, p_obj, v_entry, v_num, erp._pd_kind(p_obj), 'draft', (hd->>'doc_date')::date, (hd->>'due_date')::date, (hd->>'doc_date')::date,
            hd->>'card_code', hd->>'card_name', hd->>'customer_ref', e->'totals'->>'currency', (e->'totals'->>'rate')::numeric, (e->'totals'->>'total_lc')::numeric,
            (e->'totals'->>'vat_lc')::numeric, 0, (hd->>'branch_id')::integer, hd->>'comments', current_date, 'erp');
    INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, payment_terms, whs_code, china_office)
    VALUES (p_company, p_obj, v_entry, v_no, 'draft', u.user_id, (hd->>'payment_terms')::integer, hd->>'whs_code', hd->>'china_office');
  ELSE
    v_entry := p_doc_entry;
    v_no := w.doc_no;
    SELECT doc_num INTO v_num FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    UPDATE erp.document
       SET status = 'draft', doc_date = (hd->>'doc_date')::date, due_date = (hd->>'due_date')::date, tax_date = (hd->>'doc_date')::date,
           card_code = hd->>'card_code', card_name = hd->>'card_name', customer_ref = hd->>'customer_ref',
           total = (e->'totals'->>'total_lc')::numeric, vat_total = (e->'totals'->>'vat_lc')::numeric,
           currency = e->'totals'->>'currency', fx_rate = (e->'totals'->>'rate')::numeric, total_fc = NULL, vat_total_fc = NULL,
           branch_id = (hd->>'branch_id')::integer, comments = hd->>'comments'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry AND source = 'erp';
    UPDATE erp.doc_workflow
       SET state = 'draft', updated_at = now(), payment_terms = (hd->>'payment_terms')::integer, whs_code = hd->>'whs_code',
           china_office = hd->>'china_office'
     WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
    DELETE FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = v_entry;
  END IF;

  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                 discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, cbm,
                                 base_obj_type, base_doc_entry, base_line)
  SELECT p_company, p_obj, v_entry, x.line_num, x.item_code, x.description, x.qty, x.qty, x.uom, x.price, e->'totals'->>'currency',
         0, x.line_total, x.tax_code, x.vat, x.whs_code, 'O', x.price, x.price, x.cbm, x.base_obj_type, x.base_doc_entry, x.base_line
    FROM jsonb_to_recordset(e->'lines') AS x(line_num int, item_code text, description text, uom text, qty numeric, price numeric,
                                             tax_code text, whs_code text, cbm numeric, line_total numeric, vat numeric,
                                             base_obj_type int, base_doc_entry int, base_line int);
  PERFORM erp._sd_retotal(p_company, p_obj, v_entry);   -- B4: LC and DC totals from the lines

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, v_obj || CASE WHEN v_new THEN '_create' ELSE '_update' END, v_obj, v_entry::text,
          jsonb_build_object('doc_no', v_no, 'card_code', hd->>'card_code', 'total', e->'totals'->'total',
                             'lines', jsonb_array_length(e->'lines'), 'checks', jsonb_array_length(e->'checks'),
                             'copied_from', (SELECT jsonb_agg(DISTINCT x.base_doc_entry) FROM jsonb_to_recordset(e->'lines') AS x(base_doc_entry int)
                                              WHERE x.base_doc_entry IS NOT NULL)));

  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_num', v_num, 'doc_no', v_no, 'state', 'draft',
                            'totals', e->'totals', 'checks', e->'checks', 'lines', e->'lines');
END $$;
-- B4: header currency + rate; totals from the lines.

-- ---- purchase_grpo_create: copied from 21_purchasing.sql:2077.
CREATE OR REPLACE FUNCTION erp.purchase_grpo_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_date  date;
  v_hwhs  text := nullif(btrim(h->>'whs_code'), '');
  bl      jsonb;
  x       jsonb;
  s       record;
  v_whs   text;
  v_rate  numeric;
  v_lt    numeric;
  v_left  numeric;
  v_take  numeric;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  v_cur   text;
  i       integer := 0;
  v_fxr   numeric;
BEGIN
  u := erp._pd_guard(p_company, true, 'receive goods');
  v_date := erp._sd_doc_date(h);
  bl := erp._pd_base_lines(p_company, 22, p_lines, 'receiv');
  v_fxr := erp._cur_ctx_base(p_company, 20, bl, v_date, h);   -- B4: the PO's currency and rate
  IF v_hwhs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_hwhs AND active) THEN
    RAISE EXCEPTION 'Warehouse % does not exist or is inactive in company %.', v_hwhs, p_company USING ERRCODE = 'P0001';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    v_whs := coalesce(x->>'whs_code', v_hwhs, x->>'base_whs');
    IF v_whs IS NULL OR NOT EXISTS (SELECT 1 FROM erp.warehouse WHERE company_code = p_company AND whs_code = v_whs AND active) THEN
      RAISE EXCEPTION 'Line %: warehouse % does not exist or is inactive.', x->>'n', coalesce(v_whs, '(none)') USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;

  nb := erp._pd_new_doc(p_company, 20, u.user_id, bl->0->>'card_code', bl->0->>'card_name', v_date, v_date,
                        nullif(btrim(h->>'customer_ref'), ''), nullif(btrim(h->>'comments'), ''), (bl->0->>'branch_id')::integer, v_hwhs,
                        bl->0->>'china_office');
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    v_whs := coalesce(x->>'whs_code', v_hwhs, x->>'base_whs');
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric, 2);
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, cbm,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 20, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, v_cur, 0, v_lt, x->>'tax_code', round(v_lt * coalesce(v_rate, 0) / 100, 2), v_whs, 'O',
            round((x->>'price')::numeric * v_fxr, 6), round((x->>'price')::numeric * v_fxr, 6),
            CASE WHEN (x->>'cbm') IS NOT NULL AND (x->>'base_qty')::numeric > 0
                 THEN round((x->>'cbm')::numeric * (x->>'qty')::numeric / (x->>'base_qty')::numeric, 6) END,
            22, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    PERFORM erp._stock_move(p_company, x->>'item_code', v_whs, (x->>'qty')::numeric, 0, round((x->>'price')::numeric * v_fxr, 6), 20, v_entry, i, v_date);
    -- Off order in the warehouse the order expected it.
    UPDATE erp.stock_balance SET on_order = greatest(on_order - (x->>'qty')::numeric, 0)
     WHERE company_code = p_company AND item_code = x->>'item_code' AND whs_code = x->>'base_whs';
    -- Containers in transit for this order line: received, oldest ETA first.
    v_left := (x->>'qty')::numeric;
    FOR s IN SELECT sl.shipment_id, sl.po_line, sl.qty - sl.received_qty AS open_q
               FROM erp.purchase_shipment ps JOIN erp.purchase_shipment_line sl ON sl.shipment_id = ps.shipment_id
              WHERE ps.company_code = p_company AND ps.po_doc_entry = (x->>'base_doc_entry')::integer AND sl.po_line = (x->>'base_line')::integer
                AND ps.status = 'in_transit' AND sl.qty > sl.received_qty
              ORDER BY ps.eta, ps.shipment_id FOR UPDATE OF sl LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_left, s.open_q);
      UPDATE erp.purchase_shipment_line SET received_qty = received_qty + v_take WHERE shipment_id = s.shipment_id AND po_line = s.po_line;
      v_left := v_left - v_take;
    END LOOP;
    i := i + 1;
  END LOOP;
  UPDATE erp.purchase_shipment ps SET status = 'arrived', updated_at = now()
   WHERE ps.company_code = p_company AND ps.status = 'in_transit'
     AND ps.po_doc_entry IN (SELECT (y->>'base_doc_entry')::integer FROM jsonb_array_elements(bl) y)
     AND NOT EXISTS (SELECT 1 FROM erp.purchase_shipment_line sl WHERE sl.shipment_id = ps.shipment_id AND sl.received_qty < sl.qty);
  v_total := erp._sd_retotal(p_company, 20, v_entry);
  PERFORM erp._sd_consume(p_company, 22, bl);
  v_trans := erp.post_document(p_company, 20, v_entry);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'grpo_create', 'grpo', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', bl->0->>'card_code', 'total', v_total, 'lines', jsonb_array_length(bl),
                             'orders', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_total, 'trans_id', v_trans);
END $$;
-- B4: keeps the PO's currency and rate; stock comes in at the LC price (price × rate).

-- ---- purchase_invoice_create: copied from 21_purchasing.sql:2168.
CREATE OR REPLACE FUNCTION erp.purchase_invoice_create(p_company varchar, p_header jsonb, p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  v_dps   jsonb := CASE WHEN jsonb_typeof(h->'down_payments') = 'array' THEN h->'down_payments' ELSE '[]'::jsonb END;
  bl      jsonb;
  x       jsonb;
  bp      erp.business_partner;
  dp      erp.document;
  v_date  date;
  v_due   date;
  v_card  text;
  v_cur   text;
  v_rate  numeric;
  v_lt    numeric;
  v_net   numeric := 0;
  v_vat   numeric := 0;
  v_gross numeric;
  v_amt   numeric;
  v_avail numeric;
  v_drawn numeric := 0;
  v_draws jsonb := '[]';
  v_seen  integer[] := '{}';
  v_dpno  text;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_total numeric;
  i       integer := 0;
  v_fxr   numeric;
  v_isfc  boolean;
  v_alc   numeric;
  v_dlc   numeric := 0;
BEGIN
  u := erp._pd_guard(p_company, true, 'post A/P invoices', true);
  v_date := erp._sd_doc_date(h);
  bl := erp._pd_base_lines(p_company, 20, p_lines, 'invoic');
  v_card := bl->0->>'card_code';
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
  IF bp.card_code IS NULL THEN
    RAISE EXCEPTION 'Supplier % does not exist in company %. Check the code.', v_card, p_company USING ERRCODE = 'P0001';
  END IF;
  -- B4: the goods receipts' currency at the invoice date's rate.
  v_fxr := erp._cur_ctx_base(p_company, 18, bl, v_date, h);
  v_isfc := nullif(current_setting('erp.fx_cur', true), '') IS DISTINCT FROM v_cur AND nullif(current_setting('erp.fx_cur', true), '') IS NOT NULL;
  IF v_isfc THEN
    v_cur := current_setting('erp.fx_cur', true);
  END IF;
  IF nullif(btrim(h->>'due_date'), '') IS NOT NULL THEN
    v_due := erp._date(h->>'due_date');
    IF v_due IS NULL THEN
      RAISE EXCEPTION 'The due date is not a valid date.' USING ERRCODE = 'P0001';
    ELSIF v_due < v_date THEN
      RAISE EXCEPTION 'The due date can''t be before the posting date.' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT v_date + coalesce(pt.extra_days, 0) + make_interval(months => coalesce(pt.extra_months, 0)) INTO v_due
      FROM erp.payment_terms pt WHERE pt.company_code = p_company AND pt.group_num = coalesce((bl->0->>'payment_terms')::integer, bp.payment_terms);
    v_due := coalesce(v_due, v_date);
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric, 2);
    v_net := v_net + v_lt;
    v_vat := v_vat + round(v_lt * coalesce(v_rate, 0) / 100, 2);
  END LOOP;
  v_gross := v_net + v_vat;

  -- Down payments drawn: Super ERP 204 of this supplier, paid, not yet drawn.
  FOR x IN SELECT value FROM jsonb_array_elements(v_dps) LOOP
    IF erp._num(x->>'doc_entry') IS NULL AND erp._num(x->>'amount') IS NULL THEN CONTINUE; END IF;
    SELECT * INTO dp FROM erp.document WHERE company_code = p_company AND obj_type = 204 AND doc_entry = erp._num(x->>'doc_entry')::integer FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Down payment invoice % was not found in company %.', coalesce(x->>'doc_entry', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    v_dpno := erp._sd_no(p_company, 204, dp.doc_entry);
    IF dp.source <> 'erp' THEN
      RAISE EXCEPTION 'Down payment invoice % came from %, so it can''t be drawn in Super ERP.', v_dpno,
        CASE dp.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    ELSIF dp.card_code IS DISTINCT FROM v_card THEN
      RAISE EXCEPTION 'Down payment invoice % belongs to %, not %.', v_dpno, dp.card_code, v_card USING ERRCODE = 'P0001';
    ELSIF dp.status = 'cancelled' THEN
      RAISE EXCEPTION 'Down payment invoice % is cancelled.', v_dpno USING ERRCODE = 'P0001';
    ELSIF dp.doc_entry = ANY (v_seen) THEN
      RAISE EXCEPTION 'Down payment invoice % is listed twice.', v_dpno USING ERRCODE = 'P0001';
    ELSIF coalesce(dp.currency, v_cur) <> v_cur AND (v_isfc OR dp.total_fc IS NOT NULL) THEN
      RAISE EXCEPTION 'Down payment invoice % is in %, but this A/P invoice is in %.', v_dpno, dp.currency, v_cur USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || dp.doc_entry;
    v_amt := round(erp._num(x->>'amount'), 2);
    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'Enter the amount to draw from down payment invoice %.', v_dpno USING ERRCODE = 'P0001';
    END IF;
    v_avail := CASE WHEN v_isfc
                    THEN round(coalesce(dp.paid_fc, 0) - coalesce((SELECT sum(amount_fc) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2)
                    ELSE round(coalesce(dp.paid, 0) - coalesce((SELECT sum(amount) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2) END;
    IF coalesce(dp.paid, 0) <= 0 THEN
      RAISE EXCEPTION 'Down payment invoice % is not paid yet. Pay it first in Banking › Outgoing Payments, then draw it.', v_dpno USING ERRCODE = 'P0001';
    ELSIF v_amt > v_avail THEN
      RAISE EXCEPTION '%', format('You are drawing %s %s from down payment invoice %s, but only %s %s of it is paid and not drawn yet.',
        erp._money(v_amt), v_cur, v_dpno, erp._money(greatest(v_avail, 0)), v_cur) USING ERRCODE = 'P0001';
    END IF;
    v_drawn := v_drawn + v_amt;
    -- B4: in a foreign currency the draw's LC is at the down payment's own rate (the whole LC rest when it is drawn in full).
    v_alc := CASE WHEN NOT v_isfc THEN v_amt
                  WHEN v_amt >= v_avail THEN round(coalesce(dp.paid, 0) - coalesce((SELECT sum(amount) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dp.doc_entry), 0), 2)
                  ELSE round(v_amt * coalesce(dp.paid, 0) / nullif(dp.paid_fc, 0), 2) END;
    v_dlc := v_dlc + v_alc;
    v_draws := v_draws || jsonb_build_object('dp_entry', dp.doc_entry, 'doc_no', v_dpno, 'amount', v_amt, 'amount_lc', v_alc);
  END LOOP;
  IF v_drawn > v_gross THEN
    RAISE EXCEPTION '%', format('Down payments drawn (%s %s) are more than the invoice total of %s %s.', erp._money(v_drawn), v_cur, erp._money(v_gross), v_cur)
      USING ERRCODE = 'P0001';
  END IF;

  nb := erp._pd_new_doc(p_company, 18, u.user_id, v_card, bp.name, v_date, v_due,
                        nullif(btrim(h->>'customer_ref'), ''), nullif(btrim(h->>'comments'), ''), (bl->0->>'branch_id')::integer, NULL,
                        bl->0->>'china_office');
  v_entry := (nb->>'entry')::integer;
  FOR x IN SELECT value FROM jsonb_array_elements(bl) LOOP
    SELECT rate INTO v_rate FROM erp.tax_code WHERE company_code = p_company AND code = x->>'tax_code';
    v_lt := round((x->>'qty')::numeric * (x->>'price')::numeric, 2);
    INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, item_code, description, quantity, open_qty, uom, price, currency,
                                   discount_pct, line_total, tax_code, vat, whs_code, line_status, gross_buy_price, stock_price, cbm,
                                   base_obj_type, base_doc_entry, base_line)
    VALUES (p_company, 18, v_entry, i, x->>'item_code', x->>'description', (x->>'qty')::numeric, (x->>'qty')::numeric, x->>'uom',
            (x->>'price')::numeric, v_cur, 0, v_lt, x->>'tax_code', round(v_lt * coalesce(v_rate, 0) / 100, 2), x->>'base_whs', 'O',
            (x->>'price')::numeric, (x->>'price')::numeric, NULL, 20, (x->>'base_doc_entry')::integer, (x->>'base_line')::integer);
    i := i + 1;
  END LOOP;
  INSERT INTO erp.ap_dp_draw (company_code, invoice_entry, dp_entry, amount, amount_fc)
  SELECT p_company, v_entry, (y->>'dp_entry')::integer, (y->>'amount_lc')::numeric, CASE WHEN v_isfc THEN (y->>'amount')::numeric END
    FROM jsonb_array_elements(v_draws) y;
  PERFORM erp._sd_retotal(p_company, 18, v_entry);
  UPDATE erp.document SET total = round(total - v_dlc, 2), total_fc = CASE WHEN v_isfc THEN round(total_fc - v_drawn, 2) ELSE total_fc END
   WHERE company_code = p_company AND obj_type = 18 AND doc_entry = v_entry AND source = 'erp'
  RETURNING total INTO v_total;
  -- Down payment invoices fully drawn are closed.
  UPDATE erp.document dd SET status = 'closed'
   WHERE dd.company_code = p_company AND dd.obj_type = 204 AND dd.source = 'erp' AND dd.status = 'open'
     AND dd.doc_entry = ANY (v_seen)
     AND (SELECT coalesce(sum(amount), 0) FROM erp.ap_dp_draw WHERE company_code = p_company AND dp_entry = dd.doc_entry) >= dd.total;
  PERFORM erp._sd_consume(p_company, 20, bl);
  v_trans := erp.post_document(p_company, 18, v_entry);
  PERFORM erp._bp_balance_add(p_company, v_card, -v_total);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ap_invoice_create', 'ap_invoice', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', v_card, 'gross', v_gross, 'drawn', v_drawn, 'total', v_total,
                             'lines', jsonb_array_length(bl), 'down_payments', v_draws,
                             'receipts', (SELECT jsonb_agg(DISTINCT y->>'base_doc_no') FROM jsonb_array_elements(bl) y), 'trans_id', v_trans));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'gross', v_gross, 'drawn', v_drawn, 'total', v_total,
                            'trans_id', v_trans, 'due_date', v_due);
END $$;
-- B4: foreign-currency A/P invoices at the invoice date's rate (the goods receipt difference is posted by post_document);
-- down payments of the same currency are drawn in that currency, their LC at the down payment's rate.

-- ---- purchase_deposit_create: copied from 21_purchasing.sql:1719.
CREATE OR REPLACE FUNCTION erp.purchase_deposit_create(p_company varchar, p_po integer, p_header jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user;
  h       jsonb := coalesce(p_header, '{}'::jsonb);
  d       erp.document;
  w       erp.doc_workflow;
  v_date  date;
  v_due   date;
  v_amt   numeric;
  v_pct   numeric;
  v_prev  numeric;
  v_pi    integer := erp._num(h->>'pi_id')::integer;
  nb      jsonb;
  v_entry integer;
  v_trans integer;
  v_cur   text;
  v_lcur  text;
  v_fxr   numeric := 1;
  v_pot   numeric;
  fx      jsonb;
BEGIN
  u := erp._pd_guard(p_company, true, 'raise deposits');
  d := erp._pd_po(p_company, p_po, 'A deposit');
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = 22 AND doc_entry = p_po;
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  v_date := erp._sd_doc_date(h);
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
    IF v_due IS NULL OR v_due < v_date THEN
      RAISE EXCEPTION 'The due date must be a valid date on or after the posting date.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF nullif(btrim(h->>'amount'), '') IS NOT NULL THEN
    v_amt := erp._num(h->>'amount');
  ELSIF nullif(btrim(h->>'pct'), '') IS NOT NULL THEN
    v_pct := erp._num(h->>'pct');
    IF v_pct IS NULL OR v_pct <= 0 OR v_pct > 100 THEN
      RAISE EXCEPTION 'The deposit percentage must be more than 0 and at most 100.' USING ERRCODE = 'P0001';
    END IF;
    v_amt := round(v_pot * v_pct / 100, 2);
  END IF;
  IF v_amt IS NULL OR v_amt <= 0 THEN
    RAISE EXCEPTION 'Enter the deposit amount (or a percentage of the order).' USING ERRCODE = 'P0001';
  END IF;
  v_amt := round(v_amt, 2);
  SELECT coalesce(sum(CASE WHEN v_cur <> v_lcur THEN dd.total_fc ELSE dd.total END), 0) INTO v_prev
    FROM erp.document dd
   WHERE dd.company_code = p_company AND dd.obj_type = 204 AND dd.source = 'erp' AND dd.status <> 'cancelled'
     AND EXISTS (SELECT 1 FROM erp.document_line l WHERE l.company_code = dd.company_code AND l.obj_type = 204 AND l.doc_entry = dd.doc_entry
                    AND l.base_obj_type = 22 AND l.base_doc_entry = p_po);
  IF v_prev + v_amt > v_pot THEN
    RAISE EXCEPTION '%', format('Deposits on %s would be %s %s, more than the order total of %s %s (%s %s already raised).',
      w.doc_no, erp._money(v_prev + v_amt), v_cur, erp._money(v_pot), v_cur, erp._money(v_prev), v_cur) USING ERRCODE = 'P0001';
  END IF;
  IF v_pi IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.purchase_pi WHERE company_code = p_company AND pi_id = v_pi AND po_doc_entry = p_po) THEN
    RAISE EXCEPTION 'Proforma invoice % does not belong to purchase order %.', v_pi, w.doc_no USING ERRCODE = 'P0001';
  END IF;

  nb := erp._pd_number(p_company, 204);
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.document (company_code, obj_type, doc_entry, doc_num, doc_kind, status, doc_date, due_date, tax_date, card_code, card_name,
                            customer_ref, currency, fx_rate, total, vat_total, paid, branch_id, comments, created_on, source)
  VALUES (p_company, 204, v_entry, (nb->>'num')::integer, 'ap_down_payment', 'open', v_date, coalesce(v_due, v_date), v_date, d.card_code, d.card_name,
          coalesce((SELECT vendor_pi_no FROM erp.purchase_pi WHERE pi_id = v_pi), d.customer_ref), v_cur, v_fxr, round(v_amt * v_fxr, 2), 0, 0, d.branch_id,
          nullif(btrim(h->>'comments'), ''), current_date, 'erp');
  INSERT INTO erp.doc_workflow (company_code, obj_type, doc_entry, doc_no, state, created_by, submitted_by, submitted_at, decided_at, china_office)
  VALUES (p_company, 204, v_entry, nb->>'no', 'approved', u.user_id, u.user_id, now(), now(), w.china_office);
  INSERT INTO erp.document_line (company_code, obj_type, doc_entry, line_num, description, quantity, open_qty, price, currency, discount_pct,
                                 line_total, vat, line_status, base_obj_type, base_doc_entry)
  VALUES (p_company, 204, v_entry, 0, format('Deposit for %s', w.doc_no), 1, 0, v_amt, v_cur, 0, v_amt, 0, 'C', 22, p_po);
  PERFORM erp._sd_retotal(p_company, 204, v_entry);
  v_trans := erp.post_document(p_company, 204, v_entry);
  PERFORM erp._bp_balance_add(p_company, d.card_code, -round(v_amt * v_fxr, 2));
  IF v_pi IS NOT NULL THEN
    UPDATE erp.purchase_pi SET deposit_doc_entry = v_entry, updated_by = u.user_id, updated_at = now() WHERE company_code = p_company AND pi_id = v_pi;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'ap_down_payment_create', 'ap_down_payment', v_entry::text,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', d.card_code, 'total', v_amt, 'po_doc_entry', p_po, 'po_doc_no', w.doc_no,
                             'pi_id', v_pi, 'trans_id', v_trans));
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'purchase_order_deposit', 'purchase_order', p_po::text,
          jsonb_build_object('doc_no', w.doc_no, 'deposit_doc_no', nb->>'no', 'total', v_amt));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'total', v_amt, 'trans_id', v_trans, 'card_code', d.card_code);
END $$;
-- B4: deposits in the order's currency at the deposit date's rate.

-- ---- post_document: copied from 32_gl_setup.sql:534.
CREATE OR REPLACE FUNCTION erp.post_document(p_company varchar, p_obj_type integer, p_doc_entry integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  d       erp.document;
  w       erp.doc_workflow;
  v_trans integer;
  v_ar    text;
  v_rev   text;
  v_vat   text;
  v_inv   text;
  v_cogs  text;
  v_ap    text;
  v_clr   text;
  v_dp    text;
  v_net   numeric;
  v_vatsum numeric;
  v_cost  numeric;
  v_drawn numeric;
  v_sign  integer;
  v_lines jsonb;
  v_name  text;
  v_ref   text;
  v_grni  numeric;
BEGIN
  SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document % was not found in company %.', p_doc_entry, p_company USING ERRCODE = 'P0001';
  END IF;
  IF d.source = 'sap' THEN
    RAISE EXCEPTION 'Document % came from SAP Business One. SAP posts its own journal entry, so nothing is posted in Super ERP.', d.doc_num
      USING ERRCODE = 'P0001';
  ELSIF d.source <> 'erp' THEN
    RAISE EXCEPTION 'Document % is sample test data. Nothing is posted.', d.doc_num USING ERRCODE = 'P0001';
  END IF;
  SELECT trans_id INTO v_trans FROM erp.document_posting WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  IF FOUND THEN
    RAISE EXCEPTION 'Document % is already posted (journal %).', d.doc_num, v_trans USING ERRCODE = 'P0001';
  END IF;
  IF p_obj_type NOT IN (13, 14, 15, 20, 204, 18, 59, 60, 67) THEN
    RAISE EXCEPTION 'Posting for this document type comes in a later phase.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  v_ref := coalesce(w.doc_no, d.doc_num::text);

  -- ---------- Inventory (A7) ----------
  IF p_obj_type IN (59, 60) THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing of value moved (zero cost): no journal
    END IF;
    SELECT jsonb_agg(x ORDER BY ord, acct) INTO v_lines FROM (
      SELECT 1 AS ord, a.acct, jsonb_build_object('acct_code', a.acct, CASE WHEN p_obj_type = 59 THEN 'debit' ELSE 'credit' END, a.amt) AS x
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a
      UNION ALL
      SELECT 2, o.acct, jsonb_build_object('acct_code', o.acct, CASE WHEN p_obj_type = 59 THEN 'credit' ELSE 'debit' END, o.amt)
        FROM (SELECT l.acct_code AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) o) s;
    v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s%s', CASE p_obj_type WHEN 59 THEN 'Goods receipt' ELSE 'Goods issue' END, v_ref,
                                                              coalesce(' · ' || (SELECT name FROM erp.inventory_reason WHERE company_code = p_company AND code = w.reason_code), '')), v_lines,
      jsonb_build_object('trans_type', p_obj_type, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
    RETURN v_trans;
  ELSIF p_obj_type = 67 THEN
    -- Same stock account on both sides (the usual case): stock moved, nothing to post.
    SELECT jsonb_agg(x ORDER BY ord, acct) INTO v_lines FROM (
      SELECT 1 AS ord, t.acct, jsonb_build_object('acct_code', t.acct, 'debit', t.amt) AS x
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry
                 AND erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) <> erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs)
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) t
      UNION ALL
      SELECT 2, f.acct, jsonb_build_object('acct_code', f.acct, 'credit', f.amt)
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 67 AND l.doc_entry = p_doc_entry
                 AND erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) <> erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.from_whs)
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) f) s;
    IF v_lines IS NULL THEN
      RETURN NULL;
    END IF;
    v_trans := erp.post_journal(p_company, d.doc_date, format('Inventory transfer %s', v_ref), v_lines,
      jsonb_build_object('trans_type', 67, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('67/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 67, p_doc_entry, v_trans);
    RETURN v_trans;
  END IF;

  -- ---------- Purchasing (A6; inventory side per warehouse stock account) ----------
  IF p_obj_type = 20 THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 20 AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing of value received (zero-price lines): no journal
    END IF;
    SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct) INTO v_lines
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l WHERE l.company_code = p_company AND l.obj_type = 20 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a;
    v_clr := erp.gl_account(p_company, 'purchasing', 'grpo_clearing');
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'credit', v_cost));
    v_trans := erp.post_journal(p_company, d.doc_date, format('Goods receipt PO %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 20, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('20/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 20, p_doc_entry, v_trans);
    RETURN v_trans;
  ELSIF p_obj_type = 204 THEN
    IF coalesce(d.total, 0) <= 0 THEN
      RAISE EXCEPTION 'Down payment invoice % has no amount to post.', v_ref USING ERRCODE = 'P0001';
    END IF;
    v_dp := erp.gl_account(p_company, 'purchasing', 'down_payments');
    v_ap := erp.gl_account(p_company, 'purchasing', 'domestic_ap');
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_dp, 'debit', round(d.total, 2)),
                                 jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'credit', round(d.total, 2)));
    v_trans := erp.post_journal(p_company, d.doc_date, format('A/P down payment invoice %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 204, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'due_date', d.due_date, 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('204/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 204, p_doc_entry, v_trans);
    RETURN v_trans;
  ELSIF p_obj_type = 18 THEN
    SELECT coalesce(sum(line_total), 0), coalesce(sum(vat), 0) INTO v_net, v_vatsum
      FROM erp.document_line WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry;
    SELECT coalesce(sum(amount), 0) INTO v_drawn FROM erp.ap_dp_draw WHERE company_code = p_company AND invoice_entry = p_doc_entry;
    IF v_net + v_vatsum <= 0 THEN
      RAISE EXCEPTION 'A/P invoice % has no amount to post.', v_ref USING ERRCODE = 'P0001';
    END IF;
    v_clr := erp.gl_account(p_company, 'purchasing', 'grpo_clearing');
    v_ap := erp.gl_account(p_company, 'purchasing', 'domestic_ap');
    IF v_vatsum <> 0 THEN
      v_vat := erp.gl_account(p_company, 'purchasing', 'input_vat');
    END IF;
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_clr, 'debit', round(v_net, 2)));
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
               WHERE company_code = p_company AND obj_type = 18 AND doc_entry = p_doc_entry GROUP BY tax_code HAVING sum(vat) <> 0) t), '[]'::jsonb);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'credit', round(v_net + v_vatsum, 2)));
    IF v_drawn > 0 THEN
      v_dp := erp.gl_account(p_company, 'purchasing', 'down_payments');
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('acct_code', v_ap, 'short_name', d.card_code, 'debit', round(v_drawn, 2), 'memo', 'Down payment drawn',
                                                                 'fc_debit', (SELECT sum(amount_fc) FROM erp.ap_dp_draw WHERE company_code = p_company AND invoice_entry = p_doc_entry)),
                                              jsonb_build_object('acct_code', v_dp, 'credit', round(v_drawn, 2), 'memo', 'Down payment drawn',
                                                                 'fc_credit', (SELECT sum(amount_fc) FROM erp.ap_dp_draw WHERE company_code = p_company AND invoice_entry = p_doc_entry)));
    END IF;
    v_trans := erp.post_journal(p_company, d.doc_date, format('A/P invoice %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 18, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'due_date', d.due_date,
                         'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('18/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 18, p_doc_entry, v_trans);
    RETURN v_trans;
  END IF;

  -- ---------- Sales (A3 / A4, unchanged) ----------
  IF p_obj_type = 15 THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
     WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry;
    IF v_cost <= 0 THEN
      RETURN NULL;   -- nothing from stock (service lines only, or zero cost): no journal
    END IF;
    v_lines := (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'cogs', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
             WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
    v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
              FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
             WHERE l.company_code = p_company AND l.obj_type = 15 AND l.doc_entry = p_doc_entry
             GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
    v_trans := erp.post_journal(p_company, d.doc_date, format('Delivery %s · %s', v_ref, coalesce(d.card_name, d.card_code)), v_lines,
      jsonb_build_object('trans_type', 15, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref, 'allow_control', true,
                         'action', 'document_post', 'object', 'document', 'object_ref', format('15/%s', p_doc_entry)));
    INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, 15, p_doc_entry, v_trans);
    RETURN v_trans;
  END IF;

  v_sign := CASE p_obj_type WHEN 13 THEN 1 ELSE -1 END;
  v_name := CASE p_obj_type WHEN 13 THEN 'A/R invoice' ELSE 'A/R credit memo' END;
  v_ar  := erp.gl_account(p_company, 'sales', 'domestic_ar');
  v_rev := erp.gl_account(p_company, 'sales', CASE p_obj_type WHEN 13 THEN 'revenue' ELSE 'sales_returns' END);
  SELECT coalesce(sum(line_total), 0), coalesce(sum(vat), 0) INTO v_net, v_vatsum
    FROM erp.document_line WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry;
  IF v_vatsum <> 0 THEN
    v_vat := erp.gl_account(p_company, 'sales', 'output_vat');
  END IF;
  IF v_net + v_vatsum <= 0 THEN
    RAISE EXCEPTION '% % has no amount to post.', v_name, d.doc_num USING ERRCODE = 'P0001';
  END IF;

  v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_ar, 'short_name', d.card_code,
               CASE WHEN v_sign = 1 THEN 'debit' ELSE 'credit' END, round(v_net + v_vatsum, 2)));
  v_lines := v_lines || coalesce((
    SELECT jsonb_agg(jsonb_build_object('acct_code', s.acct, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(s.net, 2)) ORDER BY s.acct)
      FROM (SELECT erp._gl_item_acct(p_company, 'sales', CASE p_obj_type WHEN 13 THEN 'revenue' ELSE 'sales_returns' END, l.item_code, l.whs_code) AS acct,
                   sum(l.line_total) AS net FROM erp.document_line l
             WHERE l.company_code = p_company AND l.obj_type = p_obj_type AND l.doc_entry = p_doc_entry GROUP BY 1 HAVING sum(l.line_total) <> 0) s), '[]'::jsonb);
  v_lines := v_lines || coalesce((
    SELECT jsonb_agg(jsonb_build_object('acct_code', v_vat, CASE WHEN v_sign = 1 THEN 'credit' ELSE 'debit' END, round(t.vat, 2), 'tax_code', t.tax_code)
                     ORDER BY t.tax_code)
      FROM (SELECT tax_code, sum(vat) AS vat FROM erp.document_line
             WHERE company_code = p_company AND obj_type = p_obj_type AND doc_entry = p_doc_entry GROUP BY tax_code HAVING sum(vat) <> 0) t), '[]'::jsonb);

  -- Goods back in stock on a credit memo: inventory up, cost of goods sold down, at the cost they left with.
  IF p_obj_type = 14 AND coalesce(w.return_stock, false) THEN
    SELECT coalesce(sum(round(l.quantity * l.stock_price, 2)), 0) INTO v_cost
      FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
     WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry;
    IF v_cost > 0 THEN
      v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'debit', a.amt) ORDER BY a.acct)
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'inventory', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
               WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
      v_lines := v_lines || (SELECT jsonb_agg(jsonb_build_object('acct_code', a.acct, 'credit', a.amt) ORDER BY a.acct)
        FROM (SELECT erp._gl_item_acct(p_company, 'inventory', 'cogs', l.item_code, l.whs_code) AS acct, sum(round(l.quantity * l.stock_price, 2)) AS amt
                FROM erp.document_line l JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code AND coalesce(i.is_stock, false)
               WHERE l.company_code = p_company AND l.obj_type = 14 AND l.doc_entry = p_doc_entry
               GROUP BY 1 HAVING sum(round(l.quantity * l.stock_price, 2)) <> 0) a);
    END IF;
  END IF;

  v_trans := erp.post_journal(p_company, d.doc_date, format('%s %s · %s', v_name, v_ref, coalesce(d.card_name, d.card_code)), v_lines,
    jsonb_build_object('trans_type', p_obj_type, 'base_ref', v_ref, 'ref1', v_ref, 'ref2', d.customer_ref,
                       'due_date', d.due_date, 'tax_date', coalesce(d.tax_date, d.doc_date), 'allow_control', true,
                       'action', 'document_post', 'object', 'document', 'object_ref', format('%s/%s', p_obj_type, p_doc_entry)));
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, p_obj_type, p_doc_entry, v_trans);
  RETURN v_trans;
END $$;
-- B4: unchanged for local-currency documents; a foreign-currency A/P invoice clears GRNI at the goods receipt value and posts
-- the rate difference (purchasing / fx_loss, sales / fx_gain). post_journal fills the FC amounts of every line.

-- ---- sales_copy_source: copied from 30_numbering_company.sql:1624.
CREATE OR REPLACE FUNCTION erp.sales_copy_source(p_company varchar, p_obj integer, p_doc_entry integer, p_card_code text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u    erp.app_user;
  d    erp.document;
  w    erp.doc_workflow;
  v_no text;
BEGIN
  u := erp._so_guard(p_company, false);
  IF p_obj IS NULL OR p_obj NOT IN (23, 17, 15, 13) THEN
    RAISE EXCEPTION 'Copy to works from quotations, orders, deliveries and invoices only.' USING ERRCODE = 'P0001';
  END IF;
  IF p_doc_entry IS NOT NULL THEN
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% % was not found in company %.', erp._sd_name(p_obj), p_doc_entry, p_company USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    v_no := coalesce(w.doc_no, d.doc_num::text);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION '% % came from %. Copy to works on Super ERP documents only.', erp._sd_name(p_obj), v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION '% % is not approved yet, so it can''t be copied.', erp._sd_name(p_obj), v_no USING ERRCODE = 'P0001';
    END IF;
    IF d.status <> 'open' THEN
      RAISE EXCEPTION '% % is %, so nothing is left to copy.', erp._sd_name(p_obj), v_no, d.status USING ERRCODE = 'P0001';
    END IF;
    IF p_obj = 23 AND d.due_date < current_date THEN
      RAISE EXCEPTION '%', erp._sd_quote_expired_msg(v_no, d.due_date) USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN jsonb_build_object(
    'obj_type', p_obj,
    'header', CASE WHEN p_doc_entry IS NOT NULL THEN jsonb_build_object(
                'doc_entry', d.doc_entry, 'doc_no', v_no, 'card_code', d.card_code, 'card_name', d.card_name, 'doc_date', d.doc_date,
                'due_date', d.due_date, 'price_list', w.price_list, 'payment_terms', w.payment_terms, 'slp_code', d.slp_code,
                'whs_code', w.whs_code, 'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'fx_rate', d.fx_rate) END,
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'base_obj_type', l.obj_type, 'base_doc_entry', l.doc_entry, 'base_line', l.line_num, 'base_doc_no', coalesce(lw.doc_no, ld.doc_num::text),
               'base_doc_date', ld.doc_date, 'card_code', ld.card_code, 'item_code', l.item_code, 'description', l.description, 'uom', l.uom,
               'quantity', l.quantity, 'open_qty', l.open_qty, 'price', l.price, 'discount_pct', l.discount_pct, 'tax_code', l.tax_code,
               'tax_rate', (SELECT t.rate FROM erp.tax_code t WHERE t.company_code = l.company_code AND t.code = l.tax_code),
               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cost', l.stock_price,
               'currency', ld.currency, 'fx_rate', ld.fx_rate, 'line_total_fc', l.line_total_fc, 'vat_fc', l.vat_fc,
               'is_stock', coalesce(i.is_stock, false),
               'on_hand', (SELECT sb.on_hand FROM erp.stock_balance sb WHERE sb.company_code = l.company_code AND sb.item_code = l.item_code AND sb.whs_code = l.whs_code))
             ORDER BY ld.doc_date, l.doc_entry, l.line_num)
        FROM erp.document_line l
        JOIN erp.document ld ON ld.company_code = l.company_code AND ld.obj_type = l.obj_type AND ld.doc_entry = l.doc_entry
        JOIN erp.doc_workflow lw ON lw.company_code = l.company_code AND lw.obj_type = l.obj_type AND lw.doc_entry = l.doc_entry AND lw.state = 'approved'
        LEFT JOIN erp.item i ON i.company_code = l.company_code AND i.item_code = l.item_code
       WHERE l.company_code = p_company AND l.obj_type = p_obj AND ld.source = 'erp' AND ld.status = 'open'
         AND coalesce(l.line_status, 'O') = 'O' AND l.open_qty > 0
         AND NOT (p_obj = 23 AND coalesce(ld.due_date < current_date, false))   -- expired quotations are not offered (no valid-until = never expires)
         AND (CASE WHEN p_doc_entry IS NOT NULL THEN l.doc_entry = p_doc_entry ELSE ld.card_code = p_card_code END)), '[]'::jsonb));
END $$;
-- B4: + currency and rate of the base (header and lines).

-- ---- purchase_copy_source: copied from 21_purchasing.sql:1511.
CREATE OR REPLACE FUNCTION erp.purchase_copy_source(p_company varchar, p_obj integer, p_doc_entry integer, p_card_code text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u    erp.app_user;
  d    erp.document;
  w    erp.doc_workflow;
  v_no text;
BEGIN
  u := erp._pd_guard(p_company, false);
  IF p_obj IS NULL OR p_obj NOT IN (1470000113, 540000006, 22, 20) THEN
    RAISE EXCEPTION 'Copy to works from purchase requests, quotations, orders and goods receipts only.' USING ERRCODE = 'P0001';
  END IF;
  IF p_doc_entry IS NOT NULL THEN
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% % was not found in company %.', erp._pd_name(p_obj), p_doc_entry, p_company USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO w FROM erp.doc_workflow WHERE company_code = p_company AND obj_type = p_obj AND doc_entry = p_doc_entry;
    v_no := coalesce(w.doc_no, d.doc_num::text);
    IF d.source <> 'erp' THEN
      RAISE EXCEPTION '% % came from %. Copy to works on Super ERP documents only.', erp._pd_name(p_obj), v_no,
        CASE d.source WHEN 'sap' THEN 'SAP Business One' ELSE 'the sample test data' END USING ERRCODE = 'P0001';
    END IF;
    IF w.state IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION '% % is not approved yet, so it can''t be copied.', erp._pd_name(p_obj), v_no USING ERRCODE = 'P0001';
    END IF;
    IF d.status <> 'open' THEN
      RAISE EXCEPTION '% % is %, so nothing is left to copy.', erp._pd_name(p_obj), v_no, d.status USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN jsonb_build_object(
    'obj_type', p_obj,
    'header', CASE WHEN p_doc_entry IS NOT NULL THEN jsonb_build_object(
                'doc_entry', d.doc_entry, 'doc_no', v_no, 'card_code', d.card_code, 'card_name', d.card_name, 'doc_date', d.doc_date,
                'due_date', d.due_date, 'payment_terms', w.payment_terms, 'whs_code', w.whs_code, 'china_office', w.china_office,
                'customer_ref', d.customer_ref, 'comments', d.comments, 'currency', d.currency, 'total', d.total, 'fx_rate', d.fx_rate,
                'total_fc', d.total_fc) END,
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'base_obj_type', l.obj_type, 'base_doc_entry', l.doc_entry, 'base_line', l.line_num, 'base_doc_no', coalesce(lw.doc_no, ld.doc_num::text),
               'base_doc_date', ld.doc_date, 'card_code', ld.card_code, 'item_code', l.item_code, 'description', l.description, 'uom', l.uom,
               'quantity', l.quantity, 'open_qty', l.open_qty, 'price', l.price, 'discount_pct', 0, 'tax_code', l.tax_code,
               'tax_rate', (SELECT t.rate FROM erp.tax_code t WHERE t.company_code = l.company_code AND t.code = l.tax_code),
               'whs_code', l.whs_code, 'line_total', l.line_total, 'vat', l.vat, 'cbm', l.cbm, 'cost', l.stock_price, 'is_stock', true,
               'currency', ld.currency, 'fx_rate', ld.fx_rate, 'line_total_fc', l.line_total_fc, 'vat_fc', l.vat_fc,
               'on_hand', (SELECT sb.on_hand FROM erp.stock_balance sb WHERE sb.company_code = l.company_code AND sb.item_code = l.item_code AND sb.whs_code = l.whs_code),
               'in_transit', CASE WHEN l.obj_type = 22 THEN (SELECT coalesce(sum(sl.qty - sl.received_qty), 0) FROM erp.purchase_shipment s
                                                              JOIN erp.purchase_shipment_line sl ON sl.shipment_id = s.shipment_id
                                                             WHERE s.company_code = l.company_code AND s.po_doc_entry = l.doc_entry
                                                               AND sl.po_line = l.line_num AND s.status = 'in_transit') END)
             ORDER BY ld.doc_date, l.doc_entry, l.line_num)
        FROM erp.document_line l
        JOIN erp.document ld ON ld.company_code = l.company_code AND ld.obj_type = l.obj_type AND ld.doc_entry = l.doc_entry
        JOIN erp.doc_workflow lw ON lw.company_code = l.company_code AND lw.obj_type = l.obj_type AND lw.doc_entry = l.doc_entry AND lw.state = 'approved'
       WHERE l.company_code = p_company AND l.obj_type = p_obj AND ld.source = 'erp' AND ld.status = 'open'
         AND coalesce(l.line_status, 'O') = 'O' AND l.open_qty > 0
         AND (CASE WHEN p_doc_entry IS NOT NULL THEN l.doc_entry = p_doc_entry ELSE ld.card_code = p_card_code END)), '[]'::jsonb));
END $$;
-- B4: + currency and rate of the base.

-- ============ 7b. Reports: aging with the document currency ============
-- New functions next to 26's (26 is left as it is, so re-running 26 keeps working): the same LC buckets and total, plus the
-- partner's document currency (several = comma-separated) and the open amount in that currency when it is one foreign
-- currency. The Reports screen calls these; erp.rpt_ar_aging / rpt_ap_aging stay for the AI tools.
CREATE OR REPLACE FUNCTION erp._rpt_aging_fc(p_company varchar, p_as_of date, p_objs integer[])
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric, currency text, total_fc numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  WITH o AS (
    SELECT d.card_code AS cc, d.card_name AS cn, round(d.sign * (coalesce(d.total, 0) - coalesce(d.paid, 0)), 2) AS amt,
           p_as_of - coalesce(d.due_date, d.doc_date) AS late,
           coalesce(d.currency, c.currency) AS cur, c.currency AS lc,
           CASE WHEN d.total_fc IS NOT NULL AND d.currency <> c.currency THEN round(d.sign * (coalesce(d.total_fc, 0) - coalesce(d.paid_fc, 0)), 2) END AS amt_fc
      FROM erp.document d JOIN erp.company c ON c.company_code = d.company_code
     WHERE d.company_code = p_company AND d.obj_type = ANY (p_objs) AND d.status = 'open' AND d.doc_date <= p_as_of
       AND coalesce(d.total, 0) - coalesce(d.paid, 0) <> 0)
  SELECT o.cc, max(o.cn), count(*),
         coalesce(sum(o.amt) FILTER (WHERE o.late <= 0), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 1 AND 30), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 31 AND 60), 0), coalesce(sum(o.amt) FILTER (WHERE o.late BETWEEN 61 AND 90), 0),
         coalesce(sum(o.amt) FILTER (WHERE o.late > 90), 0), sum(o.amt),
         string_agg(DISTINCT o.cur, ', '),
         CASE WHEN count(DISTINCT o.cur) = 1 AND max(o.cur) <> max(o.lc) THEN sum(o.amt_fc) END
    FROM o GROUP BY o.cc ORDER BY sum(o.amt) DESC, o.cc
$$;

CREATE OR REPLACE FUNCTION erp.rpt_ar_aging_fc(p_company varchar, p_as_of date)
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric, currency text, total_fc numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['sales', 'finance'], 'Sales or Financials');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'Choose the aging date.' USING ERRCODE = 'P0001'; END IF;
  RETURN QUERY SELECT * FROM erp._rpt_aging_fc(p_company, p_as_of, ARRAY[13, 14]);
END $$;

CREATE OR REPLACE FUNCTION erp.rpt_ap_aging_fc(p_company varchar, p_as_of date)
RETURNS TABLE (card_code varchar, card_name text, docs bigint, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total numeric, currency text, total_fc numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['purchase', 'finance'], 'Purchasing or Financials');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'Choose the aging date.' USING ERRCODE = 'P0001'; END IF;
  RETURN QUERY SELECT * FROM erp._rpt_aging_fc(p_company, p_as_of, ARRAY[18, 19]);
END $$;
REVOKE ALL ON FUNCTION erp._rpt_aging_fc(varchar, date, integer[]), erp.rpt_ar_aging_fc(varchar, date), erp.rpt_ap_aging_fc(varchar, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._rpt_aging_fc(varchar, date, integer[]), erp.rpt_ar_aging_fc(varchar, date), erp.rpt_ap_aging_fc(varchar, date) TO authenticated;


-- ============ 8. Payments in the documents' currency, realised FX gain / loss ============

-- ---- _pay_eval: copied from 31_approvals.sql:930.
CREATE OR REPLACE FUNCTION erp._pay_eval(p_company varchar, p_dir text, p_header jsonb, p_lines jsonb, p_position text, p_draft_id integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h        jsonb := coalesce(p_header, '{}'::jsonb);
  v_lines  jsonb := CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END;
  v_chqin  jsonb := CASE WHEN jsonb_typeof(p_header->'cheques') = 'array' THEN p_header->'cheques' ELSE '[]'::jsonb END;
  v_in     boolean := p_dir = 'I';
  v_party  text := CASE WHEN p_dir = 'I' THEN 'customer' ELSE 'supplier' END;
  v_partyc  text := CASE WHEN p_dir = 'I' THEN 'Customer' ELSE 'Supplier' END;
  v_err    jsonb := '[]';
  v_checks jsonb := '[]';
  v_out    jsonb := '[]';
  v_chq    jsonb := '[]';
  v_cur    text;
  v_card   text := nullif(btrim(h->>'card_code'), '');
  v_tbank  text := nullif(btrim(h->>'transfer_bank'), '');
  v_cbank  text := nullif(btrim(h->>'cheque_bank'), '');
  bp       erp.business_partner;
  st       erp.banking_setting;
  v_date   date;
  v_cash   numeric;
  v_tr     numeric;
  v_cd     numeric;
  v_ct     numeric := 0;
  v_total  numeric := 0;
  v_applied numeric := 0;
  v_amt_ok boolean := true;
  x        jsonb;
  i        integer := 0;
  n        text;
  d        erp.document;
  v_obj    integer;
  v_entry  integer;
  v_amt    numeric;
  v_open   numeric;
  v_res    numeric;
  v_no     text;
  v_noun   text;
  v_nounc   text;
  v_seen   text[] := '{}';
  v_msg    text;
  v_names  text;
  v_changed timestamptz;
  v_cno    text;
  v_cdue   date;
  v_camt   numeric;
  r        record;
  k        integer := 0;
  v_lc     text;
  v_rate   numeric := 1;
  fx       jsonb;
BEGIN
  SELECT currency INTO v_cur FROM erp.company WHERE company_code = p_company;
  SELECT * INTO st FROM erp.banking_setting WHERE company_code = p_company;

  -- Business partner
  IF v_card IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('Choose a %s.', v_party));
  ELSE
    SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = v_card;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s %s does not exist in company %s. Check the code.', v_partyc, v_card, p_company));
    ELSIF bp.kind <> v_party THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s is not a %s. Choose a %s.', v_card, v_party, v_party));
    ELSIF NOT bp.active THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card_code', 'message', format('%s %s is inactive. Choose an active %s.', v_partyc, v_card, v_party));
    END IF;
  END IF;

  -- Posting date
  IF nullif(btrim(h->>'doc_date'), '') IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'Choose a posting date.');
  ELSE
    v_date := erp._date(h->>'doc_date');
    IF v_date IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'doc_date', 'message', 'The posting date is not a valid date.');
    END IF;
  END IF;

  -- B4: payment currency (the partner's, or the header's) and the payment date's rate. v_cur becomes the payment currency.
  v_lc := v_cur;
  fx := erp._cur_pick(p_company, v_card, bp.currency, h->>'currency', h->>'fx_rate', v_date, v_partyc,
                      CASE WHEN p_draft_id IS NOT NULL THEN erp._num(h->>'fx_rate') END);   -- a waiting draft keeps the rate it was checked with
  IF fx->>'error' IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', fx->>'field', 'message', fx->>'error');
  END IF;
  v_cur := fx->>'currency';
  v_rate := coalesce((fx->>'rate')::numeric, CASE WHEN v_cur = v_lc THEN 1 END);

  -- Means of payment
  v_cash := CASE WHEN nullif(btrim(h->>'cash'), '') IS NULL THEN 0 ELSE erp._num(h->>'cash') END;
  v_tr   := CASE WHEN nullif(btrim(h->>'transfer'), '') IS NULL THEN 0 ELSE erp._num(h->>'transfer') END;
  v_cd   := CASE WHEN nullif(btrim(h->>'card'), '') IS NULL THEN 0 ELSE erp._num(h->>'card') END;
  IF v_cash IS NULL OR v_cash < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cash', 'message', 'Cash must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  IF v_tr IS NULL OR v_tr < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer', 'message', 'The transfer amount must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  IF v_cd IS NULL OR v_cd < 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card', 'message', 'The card amount must be a number of 0 or more.'); v_amt_ok := false;
  END IF;
  v_cash := round(coalesce(v_cash, 0), 2); v_tr := round(coalesce(v_tr, 0), 2); v_cd := round(coalesce(v_cd, 0), 2);

  IF v_tr > 0 THEN
    IF v_tbank IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer_bank', 'message',
        CASE WHEN v_in THEN 'Choose the bank account the transfer was paid into.' ELSE 'Choose the bank account the transfer is paid from.' END);
    ELSIF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_tbank AND active AND kind = 'bank') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'transfer_bank', 'message', format('Bank account %s does not exist or is inactive in company %s.', v_tbank, p_company));
    END IF;
  END IF;

  FOR x IN SELECT value FROM jsonb_array_elements(v_chqin) LOOP
    k := k + 1;
    v_cno := nullif(btrim(x->>'cheque_no'), '');
    v_camt := erp._num(x->>'amount');
    v_cdue := erp._date(x->>'due_date');
    IF v_cno IS NULL AND v_camt IS NULL AND nullif(btrim(x->>'due_date'), '') IS NULL THEN CONTINUE; END IF;   -- empty row
    IF v_cno IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter the cheque number.', k));
    ELSIF v_camt IS NULL OR v_camt <= 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter an amount above 0.', k)); v_amt_ok := false;
    ELSIF v_cdue IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheques', 'message', format('Cheque %s: enter a valid due date.', k));
    ELSE
      v_ct := v_ct + round(v_camt, 2);
      v_chq := v_chq || jsonb_build_object('cheque_no', v_cno, 'bank_name', nullif(btrim(x->>'bank_name'), ''), 'due_date', v_cdue,
                                           'amount', round(v_camt, 2), 'post_dated', v_date IS NOT NULL AND v_cdue > v_date);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_chq) > 0 AND NOT v_in THEN
    IF v_cbank IS NULL THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheque_bank', 'message', 'Choose the bank account the cheques are drawn on.');
    ELSIF NOT EXISTS (SELECT 1 FROM erp.bank_account WHERE company_code = p_company AND bank_code = v_cbank AND active AND kind = 'bank') THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'cheque_bank', 'message', format('Bank account %s does not exist or is inactive in company %s.', v_cbank, p_company));
    END IF;
  END IF;
  IF v_cd > 0 AND NOT v_in THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'card', 'message', 'Outgoing payments by card are not supported. Pay by transfer, cheque or cash.');
  END IF;

  v_total := round(v_cash + v_tr + v_ct + v_cd, 2);
  IF v_amt_ok AND v_total <= 0 THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'total', 'message',
      CASE WHEN v_in THEN 'Enter the amount received: cash, transfer, cheque or card.' ELSE 'Enter the amount paid: cash, transfer or cheque.' END);
  END IF;

  -- Accounts the posting needs
  IF v_cash > 0 AND st.cash_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The cash account is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF v_ct > 0 AND v_in AND st.cheque_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The account for cheques received is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF v_cd > 0 AND v_in AND st.card_acct IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message', format('The account for card receipts is not set for %s. Ask Finance to set it in Banking › Banking Setup.', p_company));
  END IF;
  IF erp.gl_account(p_company, CASE WHEN v_in THEN 'sales' ELSE 'purchasing' END, CASE WHEN v_in THEN 'domestic_ar' ELSE 'domestic_ap' END, false) IS NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'setup', 'message',
      format('G/L account for ''%s'' is not set for %s. Ask Finance to set it in Setup › Financials › G/L Account Determination.',
             CASE WHEN v_in THEN 'Domestic accounts receivable' ELSE 'Domestic accounts payable' END, p_company));
  END IF;
  v_msg := erp._period_message(p_company, v_date, true);
  IF v_msg IS NOT NULL THEN
    v_err := v_err || jsonb_build_object('line', NULL, 'field', 'period', 'message', v_msg);
  END IF;

  -- Allocations
  FOR x IN SELECT value FROM jsonb_array_elements(v_lines) LOOP
    i := i + 1;
    n := format('Line %s: ', i);
    v_obj := erp._num(x->>'obj_type')::integer;
    v_entry := erp._num(x->>'doc_entry')::integer;
    v_amt := erp._num(x->>'amount');
    IF v_obj IS NULL OR v_entry IS NULL THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'choose a document.');
      CONTINUE;
    END IF;
    IF v_in AND v_obj NOT IN (13, 14) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'an incoming payment pays A/R invoices and uses A/R credit memos only.');
      CONTINUE;
    ELSIF NOT v_in AND v_obj NOT IN (18, 19, 204) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || 'an outgoing payment pays A/P invoices and down payments and uses A/P credit memos only.');
      CONTINUE;
    END IF;
    v_noun := CASE v_obj WHEN 13 THEN 'invoice' WHEN 14 THEN 'credit memo' WHEN 18 THEN 'A/P invoice' WHEN 19 THEN 'A/P credit memo' ELSE 'down payment' END;
    v_nounc := CASE v_obj WHEN 13 THEN 'Invoice' WHEN 14 THEN 'Credit memo' WHEN 18 THEN 'A/P invoice' WHEN 19 THEN 'A/P credit memo' ELSE 'Down payment' END;
    SELECT * INTO d FROM erp.document WHERE company_code = p_company AND obj_type = v_obj AND doc_entry = v_entry;
    IF NOT FOUND THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s was not found in company %s.', v_noun, v_entry, p_company));
      CONTINUE;
    END IF;
    v_no := erp._sd_no(p_company, v_obj, v_entry);
    IF d.source = 'sap' THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s came from SAP Business One. Record its payment in SAP during the soft switch.', v_noun, v_no));
    ELSIF d.source <> 'erp' THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is sample test data and can''t be paid.', v_noun, v_no));
    ELSIF d.card_code IS DISTINCT FROM v_card THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s belongs to %s, not %s.', v_noun, v_no, d.card_code, coalesce(v_card, '(none)')));
    ELSIF d.status IN ('cancelled', 'cancellation') THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is cancelled.', v_noun, v_no));
    ELSIF (v_obj || ':' || v_entry) = ANY (v_seen) THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is listed twice.', v_noun, v_no));
    ELSIF coalesce(d.currency, v_lc) <> v_cur THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'doc', 'message', n || format('%s %s is in %s, but this payment is in %s. Pay each currency''s documents in their own currency.',
        v_noun, v_no, coalesce(d.currency, v_lc), v_cur));
    ELSIF v_amt IS NULL OR v_amt <= 0 THEN
      v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n || 'enter an amount above 0.');
    ELSE
      v_amt := round(v_amt, 2);
      v_open := CASE WHEN v_cur = v_lc THEN erp._bk_doc_open(p_company, v_obj, v_entry) ELSE erp._bk_doc_open_fc(p_company, v_obj, v_entry) END;
      v_res := erp._bk_reserved(p_company, v_obj, v_entry, p_draft_id);
      IF v_amt > v_open - v_res THEN
        v_err := v_err || jsonb_build_object('line', i, 'field', 'amount', 'message', n ||
          CASE WHEN v_res > 0
               THEN format('%s %s is more than the %s %s still open on %s %s (%s %s is waiting in other payment drafts).',
                           erp._money(v_amt), v_cur, erp._money(greatest(v_open - v_res, 0)), v_cur, v_noun, v_no, erp._money(v_res), v_cur)
               ELSE format('%s %s is more than the %s %s still open on %s %s.', erp._money(v_amt), v_cur, erp._money(greatest(v_open, 0)), v_cur, v_noun, v_no) END);
      ELSE
        v_applied := v_applied + CASE WHEN v_obj IN (14, 19) THEN -v_amt ELSE v_amt END;
        v_out := v_out || jsonb_build_object('line_no', jsonb_array_length(v_out), 'obj_type', v_obj, 'doc_entry', v_entry, 'doc_no', v_no,
                                             'amount', v_amt, 'sign', CASE WHEN v_obj IN (14, 19) THEN -1 ELSE 1 END, 'open', v_open,
                                             'doc_date', d.doc_date, 'due_date', d.due_date, 'total', CASE WHEN v_cur = v_lc THEN d.total ELSE d.total_fc END,
                                             'fx_rate', d.fx_rate);
      END IF;
    END IF;
    v_seen := v_seen || (v_obj || ':' || v_entry);
  END LOOP;
  v_applied := round(v_applied, 2);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_err) e WHERE e->>'field' IN ('amount', 'doc', 'cash', 'transfer', 'card', 'cheques')) THEN
    IF v_applied > v_total AND v_total > 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'applied', 'message',
        format('You applied %s %s but the payment is %s %s. Lower the applied amounts or raise the payment.', erp._money(v_applied), v_cur, erp._money(v_total), v_cur));
    ELSIF v_applied < 0 THEN
      v_err := v_err || jsonb_build_object('line', NULL, 'field', 'applied', 'message', 'The credit memos are more than the invoices you applied. Apply more invoices or less credit.');
    END IF;
  END IF;

  -- Approval rules: outgoing payments (amount, recent bank change); B2: incoming payments (template incoming_payment).
  IF v_in AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 24, ARRAY['incoming_payment'], p_position) LOOP
      IF erp._apr_hit(r.conds, jsonb_build_object('amount', round(v_total * coalesce(v_rate, 1), 2))) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', round(v_total * coalesce(v_rate, 1), 2), 'limit', r.limit_value,
          'message', erp._apr_msg(format('Incoming payment %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds)));
      END IF;
    END LOOP;
  END IF;
  IF NOT v_in AND jsonb_array_length(v_err) = 0 THEN
    FOR r IN SELECT * FROM erp._apr_rules(p_company, 46, ARRAY['payment_amount'], p_position) LOOP
      IF erp._apr_hit(r.conds, jsonb_build_object('amount', round(v_total * coalesce(v_rate, 1), 2))) THEN
        v_checks := v_checks || (r.ck || jsonb_build_object('value', round(v_total * coalesce(v_rate, 1), 2), 'limit', r.limit_value,
          'message', CASE WHEN r.std THEN format('Payment %s %s is above your payment limit of %s %s.', erp._money(round(v_total * coalesce(v_rate, 1), 2)), v_lc, erp._money(r.limit_value), v_lc)
                          ELSE erp._apr_msg(format('Payment %s %s: ', erp._money(v_total), v_cur), r.template_name, r.conds) END));
      END IF;
    END LOOP;
    SELECT max(changed_at) INTO v_changed FROM erp.bp_bank_change WHERE company_code = p_company AND card_code = v_card;
    IF v_changed IS NOT NULL THEN
      FOR r IN SELECT * FROM erp._apr_rules(p_company, 46, ARRAY['bank_change'], p_position) LOOP
        IF erp._apr_hit(r.conds, jsonb_build_object('days_since_change', extract(epoch FROM now() - v_changed) / 86400, 'amount', round(v_total * coalesce(v_rate, 1), 2))) THEN
          SELECT string_agg(x.approver_name, ' and ' ORDER BY x.step) INTO v_names
            FROM erp._apr_rules(p_company, 46, ARRAY['bank_change'], p_position) x WHERE x.template_id = r.template_id;
          v_checks := v_checks || (r.ck || jsonb_build_object('value', v_changed::date, 'limit', r.limit_value,
            'message', CASE WHEN r.std THEN format('%s''s bank details changed on %s, within the last %s days. %s must both approve this payment.',
                                                   bp.name, erp._day(v_changed::date), trim_scale(r.limit_value), v_names)
                            ELSE erp._apr_msg(format('%s''s bank details changed on %s: ', bp.name, erp._day(v_changed::date)), r.template_name, r.conds) END));
        END IF;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'errors', v_err,
    'checks', v_checks,
    'lines', v_out,
    'header', jsonb_build_object('card_code', v_card, 'card_name', bp.name, 'doc_date', v_date, 'memo', nullif(btrim(h->>'memo'), ''),
                                 'cash', v_cash, 'transfer', v_tr, 'transfer_bank', CASE WHEN v_tr > 0 THEN v_tbank END,
                                 'transfer_ref', nullif(btrim(h->>'transfer_ref'), ''), 'cheques', v_chq, 'cheque_total', v_ct,
                                 'cheque_bank', CASE WHEN v_ct > 0 AND NOT v_in THEN v_cbank END, 'card', v_cd, 'card_ref', nullif(btrim(h->>'card_ref'), ''),
                                 'currency', v_cur, 'fx_rate', v_rate),
    'totals', jsonb_build_object('total', v_total, 'applied', v_applied, 'on_account', round(v_total - v_applied, 2), 'currency', v_cur,
                                 'rate', v_rate, 'local_currency', v_lc, 'rate_overridden', coalesce((fx->>'overridden')::boolean, false),
                                 'total_lc', round(v_total * coalesce(v_rate, 1), 2)));
END $$;
-- B4: payments in the partner's currency (all documents of that currency) at the payment date's rate; open amounts and
-- allocations in that currency; approval amounts in LC.

-- ---- _pay_post: copied from 30_numbering_company.sql:1284.
CREATE OR REPLACE FUNCTION erp._pay_post(p_company varchar, p_dir text, e jsonb, p_user uuid, p_draft_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  h       jsonb := e->'header';
  v_in    boolean := p_dir = 'I';
  v_obj   integer := CASE WHEN p_dir = 'I' THEN 24 ELSE 46 END;
  nb      jsonb;
  v_entry integer;
  v_total numeric := (e->'totals'->>'total')::numeric;
  v_cur   text := e->'totals'->>'currency';
  st      erp.banking_setting;
  v_ctl   text;
  v_side  text := CASE WHEN p_dir = 'I' THEN 'debit' ELSE 'credit' END;
  v_oside text := CASE WHEN p_dir = 'I' THEN 'credit' ELSE 'debit' END;
  v_lines jsonb := '[]';
  v_trans integer;
  v_memo  text;
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
  END IF;
  IF p_draft_id IS NOT NULL THEN
    PERFORM set_config('erp.series', coalesce((SELECT series_id::text FROM erp.payment_draft WHERE draft_id = p_draft_id), ''), true);
    PERFORM set_config('erp.series_user', coalesce(p_user::text, ''), true);
    PERFORM set_config('erp.series_date', coalesce(h->>'doc_date', ''), true);
  END IF;
  nb := erp._bk_number(p_company, v_obj);
  IF p_draft_id IS NOT NULL THEN
    PERFORM erp._series_clear();
  END IF;
  v_entry := (nb->>'entry')::integer;
  INSERT INTO erp.payment (company_code, direction, doc_entry, doc_num, doc_type, doc_date, card_code, card_name, currency, fx_rate, total,
                           cash, transfer, cheque, card, on_account, cancelled, memo, source)
  VALUES (p_company, p_dir, v_entry, (nb->>'num')::integer, CASE WHEN v_in THEN 'C' ELSE 'S' END, (h->>'doc_date')::date, h->>'card_code',
          h->>'card_name', v_cur, v_rate, v_total, (h->>'cash')::numeric, (h->>'transfer')::numeric, (h->>'cheque_total')::numeric, (h->>'card')::numeric,
          (e->'totals'->>'on_account')::numeric, false, h->>'memo', 'erp');
  IF v_isfc THEN
    UPDATE erp.payment SET total_fc = (efc->'totals'->>'total')::numeric, on_account_fc = (efc->'totals'->>'on_account')::numeric,
                           fx_diff = CASE WHEN v_in THEN v_fxd ELSE -v_fxd END
     WHERE company_code = p_company AND direction = p_dir AND doc_entry = v_entry;
  END IF;
  INSERT INTO erp.payment_extra (company_code, direction, doc_entry, doc_no, transfer_bank, transfer_ref, cheque_bank, card_ref, draft_id, created_by)
  VALUES (p_company, p_dir, v_entry, nb->>'no', h->>'transfer_bank', h->>'transfer_ref', h->>'cheque_bank', h->>'card_ref', p_draft_id, p_user);
  INSERT INTO erp.payment_cheque (company_code, direction, doc_entry, line_no, cheque_no, bank_name, due_date, amount, amount_fc)
  SELECT p_company, p_dir, v_entry, (c.ord - 1)::smallint, c.v->>'cheque_no', c.v->>'bank_name', (c.v->>'due_date')::date, (c.v->>'amount')::numeric,
         (c.v->>'amount_fc')::numeric
    FROM jsonb_array_elements(h->'cheques') WITH ORDINALITY AS c(v, ord);
  INSERT INTO erp.payment_allocation (company_code, direction, doc_entry, line_no, target_obj_type, target_doc_entry, applied, applied_fc)
  SELECT p_company, p_dir, v_entry, (l->>'line_no')::integer, (l->>'obj_type')::integer, (l->>'doc_entry')::integer, (l->>'amount')::numeric,
         (l->>'amount_fc')::numeric
    FROM jsonb_array_elements(e->'lines') l;
  FOR x IN SELECT value FROM jsonb_array_elements(e->'lines') LOOP
    UPDATE erp.document SET paid = round(coalesce(paid, 0) + (x->>'amount')::numeric, 6),
                            paid_fc = CASE WHEN x ? 'amount_fc' THEN round(coalesce(paid_fc, 0) + (x->>'amount_fc')::numeric, 6) ELSE paid_fc END
     WHERE company_code = p_company AND obj_type = (x->>'obj_type')::integer AND doc_entry = (x->>'doc_entry')::integer AND source = 'erp';
  END LOOP;

  -- Journal: money side (cash / bank / cheques / card) against the customer's receivable or the supplier's payable.
  v_ctl := erp.gl_account(p_company, CASE WHEN v_in THEN 'sales' ELSE 'purchasing' END, CASE WHEN v_in THEN 'domestic_ar' ELSE 'domestic_ap' END);
  IF (h->>'cash')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', st.cash_acct, v_side, (h->>'cash')::numeric, 'memo', 'Cash');
  END IF;
  IF (h->>'transfer')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', (SELECT acct_code FROM erp.bank_account WHERE company_code = p_company AND bank_code = h->>'transfer_bank'),
                                             v_side, (h->>'transfer')::numeric, 'memo', coalesce('Transfer ' || (h->>'transfer_ref'), 'Transfer'));
  END IF;
  IF (h->>'cheque_total')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', CASE WHEN v_in THEN st.cheque_acct
                                                               ELSE (SELECT acct_code FROM erp.bank_account WHERE company_code = p_company AND bank_code = h->>'cheque_bank') END,
                                             v_side, (h->>'cheque_total')::numeric,
                                             'memo', 'Cheques ' || (SELECT string_agg(c->>'cheque_no', ', ') FROM jsonb_array_elements(h->'cheques') c));
  END IF;
  IF (h->>'card')::numeric > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', st.card_acct, v_side, (h->>'card')::numeric, 'memo', coalesce('Card ' || (h->>'card_ref'), 'Card'));
  END IF;
  IF v_in THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_ctl, 'short_name', h->>'card_code', v_oside, v_ctl_amt);
  ELSE
    v_lines := jsonb_build_array(jsonb_build_object('acct_code', v_ctl, 'short_name', h->>'card_code', v_oside, v_ctl_amt)) || v_lines;
  END IF;
  IF v_isfc THEN
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
                       'fc_currency', CASE WHEN v_isfc THEN v_cur END, 'fc_rate', CASE WHEN v_isfc THEN v_rate END));
  UPDATE erp.payment SET trans_id = v_trans WHERE company_code = p_company AND direction = p_dir AND doc_entry = v_entry;
  INSERT INTO erp.document_posting (company_code, obj_type, doc_entry, trans_id) VALUES (p_company, v_obj, v_entry, v_trans);
  PERFORM erp._bp_balance_add(p_company, h->>'card_code', CASE WHEN v_in THEN -v_ctl_amt ELSE v_ctl_amt END);

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (coalesce(p_user::text, 'system:banking'), p_company, 'payment_post', 'payment', p_dir || '/' || v_entry,
          jsonb_build_object('doc_no', nb->>'no', 'card_code', h->>'card_code', 'total', v_total, 'on_account', e->'totals'->'on_account',
                             'allocations', jsonb_array_length(e->'lines'), 'trans_id', v_trans, 'draft_id', p_draft_id,
                             'currency', v_cur, 'rate', CASE WHEN v_isfc THEN v_rate END, 'total_fc', CASE WHEN v_isfc THEN efc->'totals'->'total' END,
                             'fx_diff', CASE WHEN v_isfc THEN v_fxd END));
  RETURN jsonb_build_object('doc_entry', v_entry, 'doc_no', nb->>'no', 'trans_id', v_trans, 'total', v_total, 'on_account', e->'totals'->'on_account',
                            'currency', v_cur, 'total_fc', CASE WHEN v_isfc THEN efc->'totals'->'total' END, 'fx_diff', CASE WHEN v_isfc THEN v_fxd END);
END $$;
-- B4: foreign-currency payments: LC journal with FC amounts, documents cleared at their own LC, realised FX gain / loss
-- (sales / fx_gain, purchasing / fx_loss), paid_fc / applied_fc / total_fc / fx_diff kept.

-- ---- payment_cancel: copied from 20_banking.sql:1064.
CREATE OR REPLACE FUNCTION erp.payment_cancel(p_company varchar, p_dir text, p_doc_entry integer, p_date date, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u        erp.app_user;
  p        erp.payment;
  x        erp.payment_extra;
  v_block  text;
  v_reason text := nullif(btrim(p_reason), '');
  v_date   date;
  v_new    integer;
  a        record;
BEGIN
  u := erp._bk_guard(p_company, true, 'cancel payments');
  SELECT * INTO p FROM erp.payment WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry FOR UPDATE;
  v_block := erp._pay_cancel_block(p_company, p_dir, p_doc_entry);
  IF v_block IS NOT NULL THEN
    RAISE EXCEPTION '%', v_block USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO x FROM erp.payment_extra WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Add a reason for the cancellation.' USING ERRCODE = 'P0001';
  END IF;
  v_date := coalesce(p_date, current_date);
  IF v_date < p.doc_date THEN
    RAISE EXCEPTION 'The cancellation date can''t be before the payment date (%).', erp._day(p.doc_date) USING ERRCODE = 'P0001';
  END IF;
  v_new := erp._reverse_journal(p_company, p.trans_id, v_date, format('Cancellation of %s %s: %s', lower(erp._bk_name(CASE WHEN p_dir = 'I' THEN 24 ELSE 46 END)), x.doc_no, v_reason),
                                'payment_cancel_journal');
  UPDATE erp.payment SET cancelled = true WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry AND source = 'erp';
  UPDATE erp.payment_extra SET cancelled_by = u.user_id, cancelled_at = now(), cancel_note = v_reason, cancel_trans_id = v_new
   WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry;
  FOR a IN SELECT * FROM erp.payment_allocation WHERE company_code = p_company AND direction = p_dir AND doc_entry = p_doc_entry LOOP
    UPDATE erp.document SET paid = round(greatest(coalesce(paid, 0) - a.applied, 0), 6),
                            paid_fc = CASE WHEN a.applied_fc IS NOT NULL THEN round(greatest(coalesce(paid_fc, 0) - a.applied_fc, 0), 6) ELSE paid_fc END
     WHERE company_code = p_company AND obj_type = a.target_obj_type AND doc_entry = a.target_doc_entry AND source = 'erp';
  END LOOP;
  PERFORM erp._bp_balance_add(p_company, p.card_code, CASE WHEN p_dir = 'I' THEN p.total - coalesce(p.fx_diff, 0) ELSE -(p.total + coalesce(p.fx_diff, 0)) END);
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payment_cancel', 'payment', p_dir || '/' || p_doc_entry,
          jsonb_build_object('doc_no', x.doc_no, 'reversed_by', v_new, 'date', v_date, 'reason', v_reason, 'total', p.total));
  RETURN jsonb_build_object('doc_entry', p_doc_entry, 'cancelled', true, 'trans_id', v_new);
END $$;
-- B4: foreign-currency amounts given back too; the partner balance moves by what the payment cleared.

-- ---- payment_open_docs: copied from 20_banking.sql:752.
CREATE OR REPLACE FUNCTION erp.payment_open_docs(p_company varchar, p_dir text, p_card text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  v_objs integer[] := CASE WHEN p_dir = 'I' THEN ARRAY[13, 14] ELSE ARRAY[18, 19, 204] END;
  bp     erp.business_partner;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO bp FROM erp.business_partner WHERE company_code = p_company AND card_code = p_card;
  RETURN jsonb_build_object(
    'card_code', bp.card_code, 'card_name', bp.name, 'currency', bp.currency,
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'balance', coalesce(bp.balance, 0) + coalesce((SELECT balance FROM erp.bp_balance_erp WHERE company_code = p_company AND card_code = p_card), 0),
    'bank_changed_at', (SELECT max(changed_at) FROM erp.bp_bank_change WHERE company_code = p_company AND card_code = p_card),
    'docs', coalesce((
      SELECT jsonb_agg(x ORDER BY x->>'due_date', x->>'doc_no') FROM (
        SELECT jsonb_build_object('obj_type', d.obj_type, 'doc_entry', d.doc_entry, 'doc_no', erp._sd_no(p_company, d.obj_type, d.doc_entry),
                                  'doc_date', d.doc_date, 'due_date', coalesce(d.due_date, d.doc_date),
                                  'total', CASE WHEN d.total_fc IS NOT NULL THEN d.total_fc ELSE d.total END, 'total_lc', d.total,
                                  'currency', coalesce(d.currency, (SELECT currency FROM erp.company WHERE company_code = p_company)), 'fx_rate', d.fx_rate,
                                  'open', coalesce(erp._bk_doc_open_fc(p_company, d.obj_type, d.doc_entry), erp._bk_doc_open(p_company, d.obj_type, d.doc_entry)),
                                  'open_lc', erp._bk_doc_open(p_company, d.obj_type, d.doc_entry),
                                  'reserved', erp._bk_reserved(p_company, d.obj_type, d.doc_entry, NULL),
                                  'sign', CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END) AS x
          FROM erp.document d
         WHERE d.company_code = p_company AND d.card_code = p_card AND d.obj_type = ANY (v_objs) AND d.source = 'erp'
           AND d.status NOT IN ('cancelled', 'cancellation')) s
       WHERE (x->>'open')::numeric > 0), '[]'::jsonb),
    'other_open', (SELECT count(*) FROM erp.document d WHERE d.company_code = p_company AND d.card_code = p_card AND d.obj_type = ANY (v_objs)
                     AND d.source <> 'erp' AND d.status = 'open'));
END $$;
-- B4: each document's currency; total and open in that currency (open_lc / total_lc in LC).

-- ---- _health_files: copied from 32_gl_setup.sql:2237.
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
    ('33_multicurrency.sql', 'currency_rate')
  ) AS v(file_name, object)
$$;
-- B4: + 33_multicurrency.sql (marker currency_rate).

-- ============ 9. Soft switch: Super ERP stock = SAP on-hand (latest sync) + net Super ERP movements ============
-- Documents created in Super ERP never go back to SAP, so SAP's OITW figures never include them. stock_balance keeps both
-- parts and the visible figure is their sum, so ATP, stock lists, valuation and the no-negative-stock checks (which all read
-- on_hand / committed / on_order) use the combined figure unchanged:
--   on_hand   = sap_on_hand   + erp_on_hand
--   committed = sap_committed + erp_committed      (open Super ERP sales orders)
--   on_order  = sap_on_order  + erp_on_order       (open Super ERP purchase orders)
-- Trigger stock_soft_switch:
--   * during the sync (erp.sync = 'on': erp.sync_company, migration_sync_company) the incoming SAP figure becomes the SAP part
--     and the Super ERP part is added on top — a sync never wipes Super ERP movements, and a changed SAP figure shows at once;
--   * any other change (Super ERP documents, order commitments) moves the Super ERP part by the same amount.
-- The sync functions themselves are unchanged (11 / 27).
ALTER TABLE erp.stock_balance ADD COLUMN IF NOT EXISTS sap_on_hand numeric(19,6);
ALTER TABLE erp.stock_balance ADD COLUMN IF NOT EXISTS erp_on_hand numeric(19,6) NOT NULL DEFAULT 0;
ALTER TABLE erp.stock_balance ADD COLUMN IF NOT EXISTS sap_committed numeric(19,6);
ALTER TABLE erp.stock_balance ADD COLUMN IF NOT EXISTS erp_committed numeric(19,6) NOT NULL DEFAULT 0;
ALTER TABLE erp.stock_balance ADD COLUMN IF NOT EXISTS sap_on_order numeric(19,6);
ALTER TABLE erp.stock_balance ADD COLUMN IF NOT EXISTS erp_on_order numeric(19,6) NOT NULL DEFAULT 0;

-- First run only (sap_on_hand still NULL): the Super ERP part from Super ERP stock movements (trans_seq from 900000000) and
-- open Super ERP orders; the rest is the SAP (or sample) baseline.
DROP TRIGGER IF EXISTS stock_soft_switch ON erp.stock_balance;
WITH mv AS (SELECT company_code, item_code, whs_code, sum(qty_in - qty_out) AS q FROM erp.stock_movement WHERE trans_seq >= 900000000 GROUP BY 1, 2, 3),
     so AS (SELECT l.company_code, l.item_code, l.whs_code, sum(l.open_qty) AS q
              FROM erp.document_line l JOIN erp.document d ON d.company_code = l.company_code AND d.obj_type = l.obj_type AND d.doc_entry = l.doc_entry
             WHERE d.obj_type = 17 AND d.source = 'erp' AND d.status = 'open' AND coalesce(l.line_status, 'O') = 'O' GROUP BY 1, 2, 3),
     po AS (SELECT l.company_code, l.item_code, l.whs_code, sum(l.open_qty) AS q
              FROM erp.document_line l JOIN erp.document d ON d.company_code = l.company_code AND d.obj_type = l.obj_type AND d.doc_entry = l.doc_entry
             WHERE d.obj_type = 22 AND d.source = 'erp' AND d.status = 'open' AND coalesce(l.line_status, 'O') = 'O' GROUP BY 1, 2, 3)
UPDATE erp.stock_balance sb
   SET erp_on_hand = coalesce(mv.q, 0), sap_on_hand = sb.on_hand - coalesce(mv.q, 0),
       erp_committed = least(coalesce(so.q, 0), sb.committed), sap_committed = sb.committed - least(coalesce(so.q, 0), sb.committed),
       erp_on_order = least(coalesce(po.q, 0), sb.on_order), sap_on_order = sb.on_order - least(coalesce(po.q, 0), sb.on_order)
  FROM erp.stock_balance s0
  LEFT JOIN mv ON mv.company_code = s0.company_code AND mv.item_code = s0.item_code AND mv.whs_code = s0.whs_code
  LEFT JOIN so ON so.company_code = s0.company_code AND so.item_code = s0.item_code AND so.whs_code = s0.whs_code
  LEFT JOIN po ON po.company_code = s0.company_code AND po.item_code = s0.item_code AND po.whs_code = s0.whs_code
 WHERE s0.company_code = sb.company_code AND s0.item_code = sb.item_code AND s0.whs_code = sb.whs_code AND sb.sap_on_hand IS NULL;

CREATE OR REPLACE FUNCTION erp._stock_soft_switch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF current_setting('erp.sync', true) = 'on' THEN
    -- A SAP figure from the sync.
    IF TG_OP = 'INSERT' THEN
      NEW.sap_on_hand := NEW.on_hand;     NEW.erp_on_hand := 0;
      NEW.sap_committed := NEW.committed; NEW.erp_committed := 0;
      NEW.sap_on_order := NEW.on_order;   NEW.erp_on_order := 0;
    ELSE
      NEW.erp_on_hand := OLD.erp_on_hand;     NEW.sap_on_hand := NEW.on_hand;     NEW.on_hand := NEW.on_hand + OLD.erp_on_hand;
      NEW.erp_committed := OLD.erp_committed; NEW.sap_committed := NEW.committed; NEW.committed := NEW.committed + OLD.erp_committed;
      NEW.erp_on_order := OLD.erp_on_order;   NEW.sap_on_order := NEW.on_order;   NEW.on_order := NEW.on_order + OLD.erp_on_order;
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    -- Created by Super ERP (a first movement or commitment in this warehouse).
    NEW.sap_on_hand := coalesce(NEW.sap_on_hand, 0);     NEW.erp_on_hand := NEW.on_hand - NEW.sap_on_hand;
    NEW.sap_committed := coalesce(NEW.sap_committed, 0); NEW.erp_committed := NEW.committed - NEW.sap_committed;
    NEW.sap_on_order := coalesce(NEW.sap_on_order, 0);   NEW.erp_on_order := NEW.on_order - NEW.sap_on_order;
  ELSE
    -- A Super ERP change: the Super ERP part moves by the same amount (unless the caller set the parts itself).
    IF NEW.erp_on_hand IS NOT DISTINCT FROM OLD.erp_on_hand AND NEW.sap_on_hand IS NOT DISTINCT FROM OLD.sap_on_hand THEN
      NEW.erp_on_hand := OLD.erp_on_hand + (NEW.on_hand - OLD.on_hand);
    END IF;
    IF NEW.erp_committed IS NOT DISTINCT FROM OLD.erp_committed AND NEW.sap_committed IS NOT DISTINCT FROM OLD.sap_committed THEN
      NEW.erp_committed := OLD.erp_committed + (NEW.committed - OLD.committed);
    END IF;
    IF NEW.erp_on_order IS NOT DISTINCT FROM OLD.erp_on_order AND NEW.sap_on_order IS NOT DISTINCT FROM OLD.sap_on_order THEN
      NEW.erp_on_order := OLD.erp_on_order + (NEW.on_order - OLD.on_order);
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER stock_soft_switch BEFORE INSERT OR UPDATE ON erp.stock_balance FOR EACH ROW EXECUTE FUNCTION erp._stock_soft_switch();

-- Super ERP warehouse-journal rows (trans_seq from 900000000) are never overwritten by the SAP sync (logged in sync_conflict).
CREATE OR REPLACE FUNCTION erp._stock_move_keep() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  PERFORM erp._sync_note(OLD.company_code, 'stock_movement', OLD.trans_seq::text, 'erp');
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS sync_keep_erp ON erp.stock_movement;
CREATE TRIGGER sync_keep_erp BEFORE UPDATE ON erp.stock_movement FOR EACH ROW
  WHEN (current_setting('erp.sync', true) = 'on' AND OLD.trans_seq >= 900000000) EXECUTE FUNCTION erp._stock_move_keep();

-- Stock of an item per warehouse with both parts (item pages, inventory users).
CREATE OR REPLACE VIEW erp.stock_balance_parts WITH (security_invoker = true) AS
SELECT company_code, item_code, whs_code, on_hand, coalesce(sap_on_hand, on_hand - erp_on_hand) AS sap_on_hand, erp_on_hand,
       committed, erp_committed, on_order, erp_on_order
  FROM erp.stock_balance;
REVOKE ALL ON erp.stock_balance_parts FROM PUBLIC, anon;
GRANT SELECT ON erp.stock_balance_parts TO authenticated;

-- ============ 10. Manual bank matching: candidates ranked by the reference (B3 follow-up) ============
-- Replaces 20: the same equal-amount candidates, but those whose journal references fit the statement line's reference
-- (B3 _bk_ref_ok: payment number, transfer / card reference, cheque numbers…) come first and carry ref_match = true.
CREATE OR REPLACE FUNCTION erp.bank_statement_candidates(p_company varchar, p_line_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  l      erp.bank_statement_line;
  v_acct text;
BEGIN
  u := erp._bk_guard(p_company, false);
  SELECT * INTO l FROM erp.bank_statement_line WHERE company_code = p_company AND line_id = p_line_id;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  SELECT acct_code INTO v_acct FROM erp.bank_account WHERE company_code = p_company AND bank_code = l.bank_code;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('trans_id', j.trans_id, 'line_id', j.line_id, 'ref_date', j.ref_date, 'amount', j.amount, 'memo', j.memo,
                                        'ref1', j.ref1, 'days', abs(j.ref_date - l.value_date), 'source', erp._bk_jl_source(p_company, j.trans_id),
                                        'ref_match', j.ref_match)
                     ORDER BY j.ref_match DESC, abs(j.ref_date - l.value_date), j.trans_id)
      FROM (SELECT * FROM (
              SELECT c.*, nullif(btrim(l.reference), '') IS NOT NULL AND erp._bk_ref_ok(l.reference, erp._bk_jl_refs(p_company, c.trans_id)) AS ref_match
                FROM (SELECT * FROM erp._bk_open_jl(p_company, v_acct) o WHERE o.amount = l.amount ORDER BY abs(o.ref_date - l.value_date), o.trans_id LIMIT 200) c) r
             ORDER BY r.ref_match DESC, abs(r.ref_date - l.value_date), r.trans_id
             LIMIT 20) j), '[]'::jsonb);
END $$;

-- ============ 11. Period-end revaluation: design preview only ============
-- Not built in B4. Open foreign-currency items (erp.bp_balance_fc) would be revalued at the period-end rate with an
-- automatic reversal on the first day of the next period (SAP "Exchange Rate Differences" / "Conversion Differences").
-- Realised differences are posted at payment (section 7).

-- ============ 12. Grants ============
REVOKE ALL ON FUNCTION
  erp._cur_rate(varchar, text, date), erp._cur_no_rate(text, date), erp._cur_list(varchar), erp._cur_conv(varchar, numeric, text, text, date),
  erp._cur_pick(varchar, text, text, text, text, date, text, numeric), erp._cur_ctx_set(text, numeric), erp._cur_ctx_take(varchar), erp._cur_noun(integer),
  erp._cur_ctx_base(varchar, integer, jsonb, date, jsonb), erp._cur_ctx_card(varchar, text, date, jsonb, text), erp._cur_line_fc(),
  erp._bk_doc_open_fc(varchar, integer, integer), erp._cur_clear_lc(varchar, integer, integer, numeric), erp._cur_last_dc(jsonb, text, numeric),
  erp._stock_soft_switch(), erp._stock_move_keep()
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.currency_rate(varchar, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.currency_rate(varchar, text, date) TO authenticated;
