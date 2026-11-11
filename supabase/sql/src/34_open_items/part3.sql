
-- ============ 5. Foreign-currency totals on lists ============
-- New views next to the earlier ones (sales_order_list / sales_doc_list 19, purchase_doc_list 21, payment_list 20), built
-- from the base tables so that re-running 19–21 never meets a dependent view. Same columns as the earlier views, then:
-- local_currency, fx_rate, total_fc / paid_fc (only for documents in another currency than the company's).
CREATE OR REPLACE VIEW erp.sales_doc_list_fc WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status, w.state,
       d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total, d.vat_total, d.paid, d.source, d.created_on,
       c.currency AS local_currency,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.fx_rate END AS fx_rate,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.total_fc END AS total_fc,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.paid_fc END AS paid_fc
  FROM erp.document d
  LEFT JOIN erp.company c ON c.company_code = d.company_code
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (23, 17, 15, 13, 14);

CREATE OR REPLACE VIEW erp.purchase_doc_list_fc WITH (security_invoker = true) AS
SELECT d.company_code, d.obj_type, d.doc_entry, d.doc_num, coalesce(w.doc_no, d.doc_num::text) AS doc_no, d.doc_kind, d.status, w.state, w.china_office,
       d.doc_date, d.due_date, d.card_code, d.card_name, d.customer_ref, d.comments, d.currency, d.total, d.vat_total, d.paid, d.container_no, d.source,
       d.created_on,
       c.currency AS local_currency,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.fx_rate END AS fx_rate,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.total_fc END AS total_fc,
       CASE WHEN d.currency IS NOT NULL AND d.currency <> c.currency THEN d.paid_fc END AS paid_fc
  FROM erp.document d
  LEFT JOIN erp.company c ON c.company_code = d.company_code
  LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
 WHERE d.obj_type IN (1470000113, 540000006, 22, 20, 21, 204, 18, 19);

CREATE OR REPLACE VIEW erp.payment_list_fc WITH (security_invoker = true) AS
SELECT p.company_code, p.direction, p.doc_entry, p.doc_num, coalesce(x.doc_no, p.doc_num::text) AS doc_no, p.doc_type, p.doc_date, p.card_code,
       p.card_name, p.currency, p.total, p.cash, p.transfer, p.cheque, p.card, p.on_account, p.cancelled, p.trans_id, p.memo, p.source,
       c.currency AS local_currency,
       CASE WHEN p.currency IS NOT NULL AND p.currency <> c.currency THEN p.fx_rate END AS fx_rate,
       CASE WHEN p.currency IS NOT NULL AND p.currency <> c.currency THEN p.total_fc END AS total_fc,
       p.fx_diff
  FROM erp.payment p
  LEFT JOIN erp.company c ON c.company_code = p.company_code
  LEFT JOIN erp.payment_extra x ON x.company_code = p.company_code AND x.direction = p.direction AND x.doc_entry = p.doc_entry;

REVOKE ALL ON erp.sales_doc_list_fc, erp.purchase_doc_list_fc, erp.payment_list_fc FROM PUBLIC, anon;
GRANT SELECT ON erp.sales_doc_list_fc, erp.purchase_doc_list_fc, erp.payment_list_fc TO authenticated;

-- ============ 6. Period-end exchange rate revaluation (Financials › Exchange Rate Differences) ============
-- Open A/R and A/P items of Super ERP documents in a foreign currency, as of the revaluation date (payments and credit memos
-- dated on or before it), are revalued per partner and currency at the date's rate (fx_rate_list; Financials may type another
-- one). The book value includes earlier revaluations that are still in force on that date. One journal through post_journal:
-- each partner's control account (A/R: sales / domestic_ar, A/P: purchasing / domestic_ap, with the partner as short name)
-- against general / fx_reval_gain or general / fx_reval_loss. Optional automatic reversal on the first day of the next
-- posting period (SAP default). One revaluation per date (cancel it to run it again); a later revaluation blocks earlier
-- dates. The posting periods decide whether the dates are open (post_journal). No approval; Financials full.
-- SAP Business One documents are never revalued here (SAP posts its own).
INSERT INTO erp.gl_posting_key (area, posting_key, label, sort, tab, ctx, store, control_ok, used_in) VALUES
  ('general', 'fx_reval_gain', 'Exchange rate differences – gain (revaluation)', 82, 'general', false, NULL, false,
     'Financials › Exchange Rate Differences: period-end revaluation of open foreign-currency items'),
  ('general', 'fx_reval_loss', 'Exchange rate differences – loss (revaluation)', 83, 'general', false, NULL, false,
     'Financials › Exchange Rate Differences: period-end revaluation of open foreign-currency items')
ON CONFLICT (area, posting_key) DO UPDATE SET label = EXCLUDED.label, sort = EXCLUDED.sort, tab = EXCLUDED.tab, ctx = EXCLUDED.ctx,
  store = EXCLUDED.store, control_ok = EXCLUDED.control_ok, used_in = EXCLUDED.used_in;

-- SAMPLE accounts for the test company ZZ99 only (real companies enter theirs in G/L Account Determination › General).
INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
SELECT 'ZZ99', v.acct, v.acct, v.name, v.parent, 2, true, 'other', 7, 'AED', false, false, 0, 'sample'
  FROM (VALUES ('7110', 'Unrealised exchange gains (SAMPLE)', '4000'), ('7210', 'Unrealised exchange losses (SAMPLE)', '6000')) AS v(acct, name, parent)
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99')
ON CONFLICT DO NOTHING;
INSERT INTO erp.gl_determination (company_code, area, posting_key, acct_code, source)
SELECT 'ZZ99', 'general', v.k, v.acct, 'sample'
  FROM (VALUES ('fx_reval_gain', '7110'), ('fx_reval_loss', '7210')) AS v(k, acct)
 WHERE EXISTS (SELECT 1 FROM erp.account a WHERE a.company_code = 'ZZ99' AND a.acct_code = v.acct)
ON CONFLICT (company_code, area, posting_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS erp.fx_revaluation (
    reval_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    doc_no         text,
    reval_date     date NOT NULL,
    currencies     text[] NOT NULL,
    rates          jsonb NOT NULL,                                -- {"USD": {"rate": 3.7, "list_rate": 3.7, "overridden": false}}
    auto_reverse   boolean NOT NULL DEFAULT true,
    reverse_date   date,
    trans_id       integer,
    reverse_trans_id integer,
    gain           numeric(19,2) NOT NULL DEFAULT 0,              -- LC, company's view
    loss           numeric(19,2) NOT NULL DEFAULT 0,
    memo           text,
    state          text NOT NULL DEFAULT 'posted' CHECK (state IN ('posted', 'cancelled')),
    cancel_trans_ids integer[],
    cancel_reason  text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_by   uuid,
    cancelled_at   timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS fx_revaluation_once ON erp.fx_revaluation (company_code, reval_date) WHERE state = 'posted';

CREATE TABLE IF NOT EXISTS erp.fx_revaluation_line (
    reval_id       bigint NOT NULL REFERENCES erp.fx_revaluation ON DELETE CASCADE,
    line_no        integer NOT NULL,
    card_code      varchar(15) NOT NULL,
    card_name      text,
    side           text NOT NULL CHECK (side IN ('receivable', 'payable')),
    currency       varchar(3) NOT NULL,
    docs           integer NOT NULL,
    open_fc        numeric(19,2) NOT NULL,
    book_lc        numeric(19,2) NOT NULL,
    rate           numeric(19,6) NOT NULL,
    new_lc         numeric(19,2) NOT NULL,
    diff           numeric(19,2) NOT NULL,                        -- new_lc − book_lc (the balance's change in LC)
    gain           numeric(19,2) NOT NULL,                        -- company's gain (+) / loss (−)
    acct_code      varchar(15),
    PRIMARY KEY (reval_id, line_no)
);

ALTER TABLE erp.fx_revaluation ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.fx_revaluation_line ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.fx_revaluation, erp.fx_revaluation_line FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.fx_revaluation, erp.fx_revaluation_line TO authenticated;
DROP POLICY IF EXISTS fx_revaluation_read ON erp.fx_revaluation;
CREATE POLICY fx_revaluation_read ON erp.fx_revaluation FOR SELECT TO authenticated USING (erp.can_see(company_code) AND erp.can_read('finance'));
DROP POLICY IF EXISTS fx_revaluation_line_read ON erp.fx_revaluation_line;
CREATE POLICY fx_revaluation_line_read ON erp.fx_revaluation_line FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.fx_revaluation r WHERE r.reval_id = fx_revaluation_line.reval_id AND erp.can_see(r.company_code) AND erp.can_read('finance')));

CREATE OR REPLACE VIEW erp.fx_revaluation_list WITH (security_invoker = true) AS
SELECT r.reval_id, r.company_code, coalesce(r.doc_no, 'FXR-' || r.reval_id) AS doc_no, r.reval_date, r.currencies, r.auto_reverse, r.reverse_date, r.trans_id,
       r.reverse_trans_id, r.gain, r.loss, r.gain - r.loss AS net, r.state, r.memo, r.created_at,
       (SELECT display_name FROM erp.app_user WHERE user_id = r.created_by) AS created_by_name,
       (SELECT count(*) FROM erp.fx_revaluation_line l WHERE l.reval_id = r.reval_id) AS lines
  FROM erp.fx_revaluation r;
REVOKE ALL ON erp.fx_revaluation_list FROM PUBLIC, anon;
GRANT SELECT ON erp.fx_revaluation_list TO authenticated;

-- Open foreign-currency items per partner, side and currency as of a date (Super ERP documents; the same netting as
-- bp_balance_fc / _bk_doc_open, limited to payments and credit memos dated on or before the date).
CREATE OR REPLACE FUNCTION erp._fxr_open(p_company varchar, p_date date, p_curs text[])
RETURNS TABLE (card_code varchar, card_name text, side text, currency varchar, docs bigint, open_fc numeric, open_lc numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH d AS (
    SELECT d.*, CASE WHEN d.obj_type IN (14, 19) THEN -1 ELSE 1 END AS sg
      FROM erp.document d JOIN erp.company c ON c.company_code = d.company_code
     WHERE d.company_code = p_company AND d.source = 'erp' AND d.obj_type IN (13, 14, 18, 19, 204)
       AND d.status NOT IN ('cancelled', 'cancellation', 'draft') AND d.doc_date <= p_date
       AND d.total_fc IS NOT NULL AND d.currency IS NOT NULL AND d.currency <> c.currency
       AND (p_curs IS NULL OR cardinality(p_curs) = 0 OR d.currency = ANY (p_curs))
  ), x AS (
    SELECT d.card_code, d.card_name, CASE WHEN d.obj_type IN (13, 14) THEN 'receivable' ELSE 'payable' END AS side, d.currency, d.sg,
           coalesce(d.total_fc, 0) - pay.fc - cm.fc AS ofc,
           coalesce(d.total, 0) - pay.lc - cm.lc AS olc
      FROM d
      CROSS JOIN LATERAL (
        SELECT coalesce(sum(coalesce(pa.applied_fc, 0)), 0) AS fc, coalesce(sum(pa.applied), 0) AS lc
          FROM erp.payment_allocation pa
          JOIN erp.payment p ON p.company_code = pa.company_code AND p.direction = pa.direction AND p.doc_entry = pa.doc_entry
         WHERE pa.company_code = d.company_code AND pa.target_obj_type = d.obj_type AND pa.target_doc_entry = d.doc_entry
           AND NOT coalesce(p.cancelled, false) AND p.doc_date <= p_date) pay
      CROSS JOIN LATERAL (
        SELECT coalesce(sum(coalesce(cl.line_total_fc, 0) + coalesce(cl.vat_fc, 0)), 0) AS fc, coalesce(sum(cl.line_total + coalesce(cl.vat, 0)), 0) AS lc
          FROM erp.document_line cl
          JOIN erp.document c ON c.company_code = cl.company_code AND c.obj_type = cl.obj_type AND c.doc_entry = cl.doc_entry
         WHERE cl.company_code = d.company_code
           AND ((d.obj_type IN (13, 18) AND cl.obj_type = d.obj_type + 1 AND cl.base_obj_type = d.obj_type AND cl.base_doc_entry = d.doc_entry
                 AND c.status NOT IN ('cancelled', 'cancellation') AND c.doc_date <= p_date)
             OR (d.obj_type IN (14, 19) AND cl.obj_type = d.obj_type AND cl.doc_entry = d.doc_entry AND cl.base_obj_type = d.obj_type - 1))) cm
  )
  SELECT x.card_code, max(x.card_name), x.side, x.currency, count(*) FILTER (WHERE x.ofc <> 0 OR x.olc <> 0), round(sum(x.sg * x.ofc), 2), round(sum(x.sg * x.olc), 2)
    FROM x GROUP BY x.card_code, x.side, x.currency
$$;

-- Validate a revaluation request and compute its lines. Never writes. p_in: {date, currencies: [..] (empty = every foreign
-- currency with open items), rates: {USD: 3.7} (empty = fx_rate_list)}. Raises the first problem.
CREATE OR REPLACE FUNCTION erp._fxr_eval(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  v_in    jsonb := coalesce(p_in, '{}'::jsonb);
  v_lc    text := (SELECT currency FROM erp.company WHERE company_code = p_company);
  v_date  date;
  v_curs  text[];
  v_all   boolean;
  c       text;
  v_rate  numeric;
  v_list  numeric;
  v_typed numeric;
  v_rates jsonb := '{}';
  v_rows  jsonb;
  v_rev   date;
  pp      erp.posting_period;
BEGIN
  BEGIN
    v_date := nullif(btrim(v_in->>'date'), '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Enter the date as YYYY-MM-DD.' USING ERRCODE = 'P0001';
  END;
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'Choose the revaluation date.' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(v_in->'currencies') = 'array' THEN
    SELECT coalesce(array_agg(DISTINCT upper(btrim(x)) ORDER BY upper(btrim(x))) FILTER (WHERE nullif(btrim(x), '') IS NOT NULL), '{}')
      INTO v_curs FROM jsonb_array_elements_text(v_in->'currencies') x;
  ELSE
    v_curs := '{}';
  END IF;
  v_all := cardinality(v_curs) = 0;
  IF v_lc = ANY (v_curs) THEN
    RAISE EXCEPTION '% is the company currency of %. Choose foreign currencies only.', v_lc, p_company USING ERRCODE = 'P0001';
  END IF;
  IF v_all THEN
    SELECT coalesce(array_agg(DISTINCT o.currency::text ORDER BY o.currency::text), '{}') INTO v_curs FROM erp._fxr_open(p_company, v_date, NULL) o WHERE o.open_fc <> 0;
  END IF;
  IF cardinality(v_curs) = 0 THEN
    RAISE EXCEPTION 'There are no open foreign-currency items in % on %.', p_company, erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  FOREACH c IN ARRAY v_curs LOOP
    v_list := erp._cur_rate(p_company, c, v_date);
    BEGIN
      v_typed := nullif(btrim(v_in->'rates'->>c), '')::numeric;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Enter the exchange rate for % as a number.', c USING ERRCODE = 'P0001';
    END;
    IF v_typed IS NOT NULL AND v_typed <= 0 THEN
      RAISE EXCEPTION 'The exchange rate for % must be more than 0.', c USING ERRCODE = 'P0001';
    END IF;
    v_rate := coalesce(v_typed, v_list);
    IF v_rate IS NULL THEN
      RAISE EXCEPTION '%', erp._cur_no_rate(c, v_date) USING ERRCODE = 'P0001';
    END IF;
    v_rates := v_rates || jsonb_build_object(c, jsonb_build_object('rate', v_rate, 'list_rate', v_list, 'overridden', v_typed IS NOT NULL AND v_typed IS DISTINCT FROM v_list));
  END LOOP;

  WITH o AS (SELECT * FROM erp._fxr_open(p_company, v_date, v_curs)),
  prior AS (
    SELECT l.card_code, l.side, l.currency, sum(l.diff) AS adj
      FROM erp.fx_revaluation_line l JOIN erp.fx_revaluation r ON r.reval_id = l.reval_id
     WHERE r.company_code = p_company AND r.state = 'posted' AND r.reval_date < v_date AND (r.reverse_date IS NULL OR r.reverse_date > v_date)
     GROUP BY 1, 2, 3),
  y AS (
    SELECT o.card_code, o.card_name, o.side, o.currency, o.docs, o.open_fc, o.open_lc + coalesce(p.adj, 0) AS book_lc,
           (v_rates->o.currency->>'rate')::numeric AS rate
      FROM o LEFT JOIN prior p ON p.card_code = o.card_code AND p.side = o.side AND p.currency = o.currency
     WHERE o.open_fc <> 0 OR o.open_lc + coalesce(p.adj, 0) <> 0),
  z AS (SELECT y.*, round(y.open_fc * y.rate, 2) AS new_lc FROM y)
  SELECT coalesce(jsonb_agg(jsonb_build_object('card_code', z.card_code, 'card_name', z.card_name, 'side', z.side, 'currency', z.currency, 'docs', z.docs,
                                               'open_fc', z.open_fc, 'book_lc', z.book_lc, 'rate', z.rate, 'new_lc', z.new_lc, 'diff', z.new_lc - z.book_lc,
                                               'gain', CASE WHEN z.side = 'receivable' THEN z.new_lc - z.book_lc ELSE z.book_lc - z.new_lc END)
                            ORDER BY z.side DESC, z.currency, z.card_code), '[]'::jsonb)
    INTO v_rows FROM z;

  SELECT * INTO pp FROM erp.posting_period WHERE company_code = p_company AND v_date BETWEEN from_date AND to_date ORDER BY from_date LIMIT 1;
  v_rev := coalesce(pp.to_date + 1, (date_trunc('month', v_date) + interval '1 month')::date);

  RETURN jsonb_build_object(
    'date', v_date, 'currencies', to_jsonb(v_curs), 'rates', v_rates, 'local_currency', v_lc, 'reverse_date', v_rev, 'rows', v_rows,
    'totals', jsonb_build_object(
      'gain', coalesce((SELECT sum((r->>'gain')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'gain')::numeric > 0), 0),
      'loss', coalesce((SELECT -sum((r->>'gain')::numeric) FROM jsonb_array_elements(v_rows) r WHERE (r->>'gain')::numeric < 0), 0),
      'net', coalesce((SELECT sum((r->>'gain')::numeric) FROM jsonb_array_elements(v_rows) r), 0),
      'partners', jsonb_array_length(v_rows)),
    'already', (SELECT jsonb_build_object('reval_id', r.reval_id, 'doc_no', r.doc_no, 'date', r.reval_date) FROM erp.fx_revaluation r
                 WHERE r.company_code = p_company AND r.state = 'posted' AND r.reval_date = v_date),
    'later', (SELECT jsonb_build_object('reval_id', r.reval_id, 'doc_no', r.doc_no, 'date', r.reval_date) FROM erp.fx_revaluation r
               WHERE r.company_code = p_company AND r.state = 'posted' AND r.reval_date > v_date ORDER BY r.reval_date DESC LIMIT 1));
END $$;

-- Setup for the screen: currencies with open items today, the two accounts, the rates list, history.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'revalue foreign-currency balances');
BEGIN
  RETURN jsonb_build_object(
    'company_code', p_company,
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'can_write', erp.can_write('finance'),
    'currencies', to_jsonb(erp._cur_list(p_company)),
    'open_currencies', coalesce((SELECT jsonb_agg(DISTINCT o.currency ORDER BY o.currency) FROM erp._fxr_open(p_company, current_date, NULL) o WHERE o.open_fc <> 0), '[]'::jsonb),
    'gain_acct', erp.gl_account(p_company, 'general', 'fx_reval_gain', false),
    'loss_acct', erp.gl_account(p_company, 'general', 'fx_reval_loss', false),
    'history', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.reval_date DESC, l.reval_id DESC) FROM erp.fx_revaluation_list l WHERE l.company_code = p_company), '[]'::jsonb));
END $$;

-- Preview (Financials full): the lines and totals that posting would create.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_preview(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, true, 'revalue foreign-currency balances');
BEGIN
  RETURN erp._fxr_eval(p_company, p_in);
END $$;

-- Post the revaluation journal (and its automatic reversal when asked). p_in: preview input + {auto_reverse (default true), memo}.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_post(p_company varchar, p_in jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u       erp.app_user := erp._je_guard(p_company, true, 'revalue foreign-currency balances');
  v_in    jsonb := coalesce(p_in, '{}'::jsonb);
  e       jsonb;
  r       jsonb;
  v_date  date;
  v_auto  boolean := coalesce((v_in->>'auto_reverse')::boolean, true);
  v_memo  text := nullif(btrim(v_in->>'memo'), '');
  v_id    bigint;
  v_no    text;
  v_ar    text;
  v_ap    text;
  v_gacct text;
  v_lacct text;
  v_lines jsonb := '[]';
  v_gain  numeric;
  v_loss  numeric;
  v_trans integer;
  v_rtrans integer;
  v_rev   date;
  x       record;
  i       integer := 0;
BEGIN
  -- One revaluation at a time per company (the date checks below must see each other's rows).
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  e := erp._fxr_eval(p_company, v_in);
  v_date := (e->>'date')::date;
  IF e->'already' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Open items on % are already revalued (%). Cancel that revaluation first if you need to run it again.', erp._day(v_date), e->'already'->>'doc_no'
      USING ERRCODE = 'P0001';
  END IF;
  IF e->'later' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'A later revaluation (% on %) is already posted. Cancel it first, or choose a date after %.', e->'later'->>'doc_no',
      erp._day((e->'later'->>'date')::date), erp._day((e->'later'->>'date')::date) USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(e->'rows') = 0 THEN
    RAISE EXCEPTION 'There are no open foreign-currency items in % on %.', p_company, erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(e->'rows') y WHERE (y->>'diff')::numeric <> 0) THEN
    RAISE EXCEPTION 'The open items are already at these rates on %. Nothing to post.', erp._day(v_date) USING ERRCODE = 'P0001';
  END IF;
  v_gain := (e->'totals'->>'gain')::numeric;
  v_loss := (e->'totals'->>'loss')::numeric;
  -- Accounts first (the A3 "not set" messages), only those this run needs.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'rows') y WHERE y->>'side' = 'receivable' AND (y->>'diff')::numeric <> 0) THEN
    v_ar := erp.gl_account(p_company, 'sales', 'domestic_ar');
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(e->'rows') y WHERE y->>'side' = 'payable' AND (y->>'diff')::numeric <> 0) THEN
    v_ap := erp.gl_account(p_company, 'purchasing', 'domestic_ap');
  END IF;
  IF v_gain > 0 THEN v_gacct := erp.gl_account(p_company, 'general', 'fx_reval_gain'); END IF;
  IF v_loss > 0 THEN v_lacct := erp.gl_account(p_company, 'general', 'fx_reval_loss'); END IF;

  INSERT INTO erp.fx_revaluation (company_code, reval_date, currencies, rates, auto_reverse, gain, loss, memo, created_by)
  SELECT p_company, v_date, ARRAY(SELECT jsonb_array_elements_text(e->'currencies')), e->'rates', v_auto, v_gain, v_loss, v_memo, u.user_id
  RETURNING reval_id INTO v_id;
  v_no := 'FXR-' || v_id;
  UPDATE erp.fx_revaluation SET doc_no = v_no WHERE reval_id = v_id;

  FOR x IN SELECT * FROM jsonb_to_recordset(e->'rows') AS y(card_code text, card_name text, side text, currency text, docs integer, open_fc numeric,
                                                           book_lc numeric, rate numeric, new_lc numeric, diff numeric, gain numeric) LOOP
    i := i + 1;
    INSERT INTO erp.fx_revaluation_line (reval_id, line_no, card_code, card_name, side, currency, docs, open_fc, book_lc, rate, new_lc, diff, gain, acct_code)
    VALUES (v_id, i, x.card_code, x.card_name, x.side, x.currency, x.docs, x.open_fc, x.book_lc, x.rate, x.new_lc, x.diff, x.gain,
            CASE WHEN x.side = 'receivable' THEN v_ar ELSE v_ap END);
    CONTINUE WHEN x.diff = 0;
    -- A receivable that grew is debited; a payable that grew is credited.
    v_lines := v_lines || jsonb_build_object('acct_code', CASE WHEN x.side = 'receivable' THEN v_ar ELSE v_ap END, 'short_name', x.card_code,
      CASE WHEN (x.side = 'receivable') = (x.diff > 0) THEN 'debit' ELSE 'credit' END, abs(x.diff),
      'memo', format('Revaluation %s %s %s at %s', x.card_code, erp._money(x.open_fc), x.currency, trim_scale(x.rate)));
  END LOOP;
  IF v_gain > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_gacct, 'credit', v_gain, 'memo', 'Exchange rate differences – gain');
  END IF;
  IF v_loss > 0 THEN
    v_lines := v_lines || jsonb_build_object('acct_code', v_lacct, 'debit', v_loss, 'memo', 'Exchange rate differences – loss');
  END IF;
  v_trans := erp.post_journal(p_company, v_date, coalesce(v_memo, format('Exchange rate differences %s · %s', erp._day(v_date), array_to_string(ARRAY(SELECT jsonb_array_elements_text(e->'currencies')), ', '))),
    v_lines, jsonb_build_object('trans_type', 30, 'ref1', v_no, 'ref2', 'FX revaluation', 'base_ref', v_no, 'allow_control', true,
                                'action', 'fx_revaluation_journal', 'object', 'fx_revaluation', 'object_ref', v_id::text));
  IF v_auto THEN
    v_rev := (e->>'reverse_date')::date;
    v_rtrans := erp._reverse_journal(p_company, v_trans, v_rev, format('Reversal of %s (exchange rate differences %s)', v_no, erp._day(v_date)), 'fx_revaluation_reverse');
  END IF;
  UPDATE erp.fx_revaluation SET trans_id = v_trans, reverse_date = v_rev, reverse_trans_id = v_rtrans WHERE reval_id = v_id;

  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'fx_revaluation_post', 'fx_revaluation', v_id::text,
          jsonb_build_object('doc_no', v_no, 'date', v_date, 'currencies', e->'currencies', 'rates', e->'rates', 'gain', v_gain, 'loss', v_loss,
                             'partners', jsonb_array_length(e->'rows'), 'trans_id', v_trans, 'auto_reverse', v_auto, 'reverse_date', v_rev, 'reverse_trans_id', v_rtrans));
  RETURN jsonb_build_object('reval_id', v_id, 'doc_no', v_no, 'date', v_date, 'trans_id', v_trans, 'reverse_date', v_rev, 'reverse_trans_id', v_rtrans,
                            'gain', v_gain, 'loss', v_loss, 'net', v_gain - v_loss, 'lines', i);
END $$;

-- A mirror journal of p_trans on p_date (debits and credits swapped), used to cancel a revaluation.
CREATE OR REPLACE FUNCTION erp._fxr_mirror(p_company varchar, p_trans integer, p_date date, p_memo text, p_ref text, p_id bigint) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  RETURN erp.post_journal(p_company, p_date, p_memo,
    (SELECT jsonb_agg(jsonb_build_object('acct_code', l.acct_code, 'short_name', l.short_name, 'debit', l.credit, 'credit', l.debit, 'memo', l.memo) ORDER BY l.line_id)
       FROM erp.journal_line l WHERE l.company_code = p_company AND l.trans_id = p_trans),
    jsonb_build_object('trans_type', 30, 'ref1', p_ref, 'ref2', 'FX revaluation cancelled', 'base_ref', p_trans::text, 'allow_control', true,
                       'action', 'fx_revaluation_cancel', 'object', 'fx_revaluation', 'object_ref', p_id::text));
END $$;

-- Cancel a revaluation: mirrors its journal (on its date) and the automatic reversal (on that date). The posting periods of
-- both dates must be open. The latest revaluation goes first.
CREATE OR REPLACE FUNCTION erp.fx_revaluation_cancel(p_company varchar, p_reval_id bigint, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user := erp._je_guard(p_company, true, 'revalue foreign-currency balances');
  r      erp.fx_revaluation;
  l      erp.fx_revaluation;
  v_note text := nullif(btrim(p_reason), '');
  v_t1   integer;
  v_t2   integer;
BEGIN
  PERFORM 1 FROM erp.company WHERE company_code = p_company FOR UPDATE;
  SELECT * INTO r FROM erp.fx_revaluation WHERE reval_id = p_reval_id AND company_code = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Revaluation % was not found in %.', coalesce(p_reval_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF r.state = 'cancelled' THEN
    RAISE EXCEPTION 'Revaluation % is already cancelled.', r.doc_no USING ERRCODE = 'P0001';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'Add a reason for cancelling the revaluation.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO l FROM erp.fx_revaluation WHERE company_code = p_company AND state = 'posted' AND reval_date > r.reval_date ORDER BY reval_date DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Cancel the later revaluation % (%) first.', l.doc_no, erp._day(l.reval_date) USING ERRCODE = 'P0001';
  END IF;
  -- Mirror journals (the automatic reversal already is the reversal of record of the revaluation journal).
  v_t1 := erp._fxr_mirror(p_company, r.trans_id, r.reval_date, format('Cancellation of %s: %s', r.doc_no, v_note), r.doc_no, r.reval_id);
  IF r.reverse_trans_id IS NOT NULL THEN
    v_t2 := erp._fxr_mirror(p_company, r.reverse_trans_id, r.reverse_date, format('Cancellation of %s (its reversal): %s', r.doc_no, v_note), r.doc_no, r.reval_id);
  END IF;
  UPDATE erp.fx_revaluation SET state = 'cancelled', cancel_trans_ids = array_remove(ARRAY[v_t1, v_t2], NULL), cancel_reason = v_note,
                                cancelled_by = u.user_id, cancelled_at = now()
   WHERE reval_id = p_reval_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'fx_revaluation_cancel', 'fx_revaluation', p_reval_id::text,
          jsonb_build_object('doc_no', r.doc_no, 'date', r.reval_date, 'reason', v_note, 'trans_ids', to_jsonb(array_remove(ARRAY[v_t1, v_t2], NULL))));
  RETURN jsonb_build_object('reval_id', p_reval_id, 'doc_no', r.doc_no, 'state', 'cancelled', 'trans_ids', to_jsonb(array_remove(ARRAY[v_t1, v_t2], NULL)));
END $$;

-- One revaluation with its lines, journals and activity (Financials read).
CREATE OR REPLACE FUNCTION erp.fx_revaluation_info(p_company varchar, p_reval_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user := erp._je_guard(p_company, false, 'revalue foreign-currency balances');
  r erp.fx_revaluation;
BEGIN
  SELECT * INTO r FROM erp.fx_revaluation WHERE reval_id = p_reval_id AND company_code = p_company;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN to_jsonb(r) || jsonb_build_object(
    'local_currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
    'net', r.gain - r.loss,
    'created_by_name', erp._adm_name(r.created_by), 'cancelled_by_name', erp._adm_name(r.cancelled_by),
    'can_cancel', r.state = 'posted' AND erp.can_write('finance')
                  AND NOT EXISTS (SELECT 1 FROM erp.fx_revaluation l WHERE l.company_code = p_company AND l.state = 'posted' AND l.reval_date > r.reval_date),
    'lines', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no) FROM erp.fx_revaluation_line l WHERE l.reval_id = r.reval_id), '[]'::jsonb),
    'journals', coalesce((SELECT jsonb_agg(jsonb_build_object('trans_id', j.trans_id, 'ref_date', j.ref_date, 'memo', j.memo, 'total', j.total_local,
                                                              'lines', (SELECT jsonb_agg(jsonb_build_object('acct_code', jl.acct_code, 'short_name', jl.short_name,
                                                                                                             'debit', jl.debit, 'credit', jl.credit, 'memo', jl.memo) ORDER BY jl.line_id)
                                                                          FROM erp.journal_line jl WHERE jl.company_code = j.company_code AND jl.trans_id = j.trans_id))
                                           ORDER BY j.ref_date, j.trans_id)
                            FROM erp.journal_entry j
                           WHERE j.company_code = p_company AND j.trans_id = ANY (array_remove(ARRAY[r.trans_id, r.reverse_trans_id] || coalesce(r.cancel_trans_ids, '{}'), NULL))), '[]'::jsonb),
    'activity', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'actor_name', coalesce(au.display_name, a.actor)) ORDER BY a.at, a.audit_id)
                            FROM erp.audit_log a LEFT JOIN erp.app_user au ON au.user_id::text = a.actor
                           WHERE a.company_code = p_company AND a.object = 'fx_revaluation' AND a.object_ref = r.reval_id::text), '[]'::jsonb));
END $$;

-- ============ 7. Grants ============
REVOKE ALL ON FUNCTION
  erp._apr_sub_principal(bigint, uuid), erp._apr_sub_of_stage(bigint, uuid), erp._apr_user_stages(varchar, uuid), erp._apr_vote_behalf(),
  erp._apr_vote_behalf_audit(), erp._apr_decided_behalf(), erp._sub_guard(varchar), erp._sub_status(erp.apr_substitute),
  erp._fxr_open(varchar, date, text[]), erp._fxr_eval(varchar, jsonb), erp._fxr_mirror(varchar, integer, date, text, text, bigint)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  erp.approval_substitute_list(varchar), erp.approval_substitute_save(varchar, jsonb), erp.approval_substitute_end(varchar, bigint),
  erp.fx_revaluation_setup(varchar), erp.fx_revaluation_preview(varchar, jsonb), erp.fx_revaluation_post(varchar, jsonb),
  erp.fx_revaluation_cancel(varchar, bigint, text), erp.fx_revaluation_info(varchar, bigint)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  erp.approval_substitute_list(varchar), erp.approval_substitute_save(varchar, jsonb), erp.approval_substitute_end(varchar, bigint),
  erp.fx_revaluation_setup(varchar), erp.fx_revaluation_preview(varchar, jsonb), erp.fx_revaluation_post(varchar, jsonb),
  erp.fx_revaluation_cancel(varchar, bigint, text), erp.fx_revaluation_info(varchar, bigint)
TO authenticated;
