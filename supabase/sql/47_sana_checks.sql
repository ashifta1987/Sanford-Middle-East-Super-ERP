-- 47 · SANA agent, phase 1 (S3): deterministic checks. They run BEFORE the model and are handed to it as facts, so a slow or
-- failed model never blocks a law warning. All SECURITY INVOKER: they read with the caller's rights (RLS + module checks) and
-- return only what the caller may see. Country rules come from erp.sana_rule (46); a switched-off rule returns no rows.
--
-- Every check returns rows (code, severity law|risk|info, message, evidence, score). evidence = [{table, id, label, link}];
-- score is set only where it is computed (duplicate bill, 0–100).
-- Record ids: document 'obj_type:doc_entry', payment 'I:doc_entry' / 'O:doc_entry', partner card_code, item item_code.
--
-- Not in our schema today (so these checks return nothing even when the rule is on; listed in docs/sana-agent.md):
--   GST by HSN and the MRP cap (no HSN / MRP columns), MSME 45-day terms (no MSME flag on the partner).
-- Import cost / supplier: SANA shows cost and supplier for EVERY item only to purchase, finance, inventory (QC) and the owner
-- (business): erp.sana_can_see_cost(). sana_has() already counts the business module, so sana_document / sana_stock (36)
-- already show cost to the owner and need no change. No check here returns cost or supplier fields.
-- Safe to run twice. Not applied to live until Ashif says go (branch first).

CREATE OR REPLACE FUNCTION erp.sana_can_see_cost() RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$ SELECT erp.sana_has('finance', 'purchase', 'inventory') $$;

CREATE OR REPLACE FUNCTION erp._sana_ev(p_table text, p_id text, p_label text, p_link text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('table', p_table, 'id', p_id, 'label', p_label, 'link', p_link))
$$;
CREATE OR REPLACE FUNCTION erp._sana_doc_ev(d erp.document) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = erp, pg_temp AS $$
  SELECT erp._sana_ev('document', d.obj_type || ':' || d.doc_entry, d.doc_kind || ' ' || d.doc_num, erp.sana_doc_link(d.doc_kind, d.company_code, d.doc_entry))
$$;
CREATE OR REPLACE FUNCTION erp._sana_partner_allowed(p_kind text) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT CASE p_kind WHEN 'supplier' THEN erp.sana_has('purchase', 'finance') ELSE erp.sana_has('sales', 'finance') END
$$;

-- Tax codes are reference data, but erp.tax_code is readable by the finance module only (A1 policy). The checks need the rate
-- for purchase and sales users too: this returns code, rate and active for one company the caller may see, nothing else.
CREATE OR REPLACE FUNCTION erp._sana_tax_codes(p_company varchar) RETURNS TABLE (code varchar, rate numeric, active boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT t.code, t.rate, coalesce(t.active, true) FROM erp.tax_code t WHERE t.company_code = p_company AND erp.can_see(p_company)
$$;

-- ---------- Tax: VAT by tax code (AE) / GST by HSN (IN, no HSN data yet) ----------
-- Lines from the document, or from a draft {doc_kind, lines: [{line_num, line_total, tax_code, vat}]} while the form is open.
CREATE OR REPLACE FUNCTION erp.sana_check_tax(p_company varchar, p_obj_type integer, p_doc_entry integer, p_draft jsonb DEFAULT NULL)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE vat jsonb := erp.sana_rule_params(p_company, 'vat_rate'); d erp.document; kind text; ev jsonb; std numeric;
BEGIN
  IF vat IS NULL THEN RETURN; END IF;                               -- IN: gst_rate needs HSN, not in the schema yet
  IF p_draft IS NULL THEN
    SELECT * INTO d FROM erp.document x WHERE x.company_code = p_company AND x.obj_type = p_obj_type AND x.doc_entry = p_doc_entry;
    IF NOT FOUND THEN RETURN; END IF;
    kind := d.doc_kind; ev := erp._sana_doc_ev(d);
  ELSE
    kind := p_draft ->> 'doc_kind'; ev := erp._sana_ev('draft', coalesce(p_draft ->> 'id', 'new'), 'draft', NULL);
  END IF;
  IF kind IS NULL OR NOT erp.sana_doc_allowed(kind) THEN RETURN; END IF;
  std := coalesce((vat ->> 'rate')::numeric, 5);
  RETURN QUERY
  WITH l AS (
    SELECT dl.line_num, dl.line_total, dl.tax_code, dl.vat FROM erp.document_line dl
     WHERE p_draft IS NULL AND dl.company_code = p_company AND dl.obj_type = p_obj_type AND dl.doc_entry = p_doc_entry
    UNION ALL
    SELECT x.line_num, x.line_total, x.tax_code, x.vat FROM jsonb_to_recordset(coalesce(p_draft -> 'lines', '[]')) AS x(line_num integer, line_total numeric, tax_code text, vat numeric)
     WHERE p_draft IS NOT NULL)
  SELECT 'tax.unknown_code', 'risk', format('Line %s uses tax code %s, which is not an active tax code for %s.', l.line_num, coalesce(l.tax_code, '(none)'), p_company),
         jsonb_build_array(ev), NULL::integer
    FROM l LEFT JOIN erp._sana_tax_codes(p_company) t ON t.code = l.tax_code
   WHERE coalesce(l.line_total, 0) <> 0 AND (t.code IS NULL OR NOT t.active)
  UNION ALL
  SELECT 'tax.vat_mismatch', 'risk', format('Line %s: VAT is %s but %s %% of %s is %s.', l.line_num, round(coalesce(l.vat, 0), 2), t.rate, round(l.line_total, 2), round(l.line_total * t.rate / 100, 2)),
         jsonb_build_array(ev, erp._sana_ev('tax_code', t.code, t.code || ' ' || t.rate || ' %', NULL)), NULL
    FROM l JOIN erp._sana_tax_codes(p_company) t ON t.code = l.tax_code
   WHERE l.line_total IS NOT NULL AND abs(coalesce(l.vat, 0) - l.line_total * t.rate / 100) > 0.05
  UNION ALL
  SELECT 'tax.rate_unusual', 'info', format('Line %s: tax code %s is %s %%; the standard VAT rate is %s %%.', l.line_num, t.code, t.rate, std),
         jsonb_build_array(ev, erp._sana_ev('tax_code', t.code, t.code || ' ' || t.rate || ' %', NULL)), NULL
    FROM l JOIN erp._sana_tax_codes(p_company) t ON t.code = l.tax_code
   WHERE coalesce(l.line_total, 0) <> 0 AND t.rate NOT IN (0, std);
END $$;

-- ---------- Cash limits (IN: receipt 2,00,000 refused, payment above 10,000 needs a reason; AE: none) ----------
-- Payment by key ('I'/'O', doc_entry) or a draft {direction: 'I'|'O', cash: 12345, card_code}.
CREATE OR REPLACE FUNCTION erp.sana_check_cash_limits(p_company varchar, p_direction text DEFAULT NULL, p_doc_entry integer DEFAULT NULL, p_draft jsonb DEFAULT NULL)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE dir text; cash numeric; ev jsonb; r jsonb; cur text := coalesce((erp.sana_rule_params(p_company, 'number_format') ->> 'currency'), '');
BEGIN
  IF NOT erp.sana_has('finance', 'banking') THEN RETURN; END IF;
  IF p_draft IS NOT NULL THEN
    dir := p_draft ->> 'direction'; cash := (p_draft ->> 'cash')::numeric; ev := erp._sana_ev('draft', 'new', 'draft payment', NULL);
  ELSE
    SELECT p.direction, p.cash, erp._sana_ev('payment', p.direction || ':' || p.doc_entry, CASE p.direction WHEN 'I' THEN 'Receipt ' ELSE 'Payment ' END || p.doc_num,
                                             '/banking/' || CASE p.direction WHEN 'I' THEN 'incoming' ELSE 'outgoing' END || '/' || p.company_code || '/' || p.doc_entry)
      INTO dir, cash, ev FROM erp.payment p WHERE p.company_code = p_company AND p.direction = p_direction AND p.doc_entry = p_doc_entry;
  END IF;
  IF dir IS NULL OR coalesce(cash, 0) <= 0 THEN RETURN; END IF;
  IF dir = 'I' THEN
    r := erp.sana_rule_params(p_company, 'cash_receipt_limit');
    IF r IS NOT NULL AND cash >= (r ->> 'amount')::numeric THEN
      RETURN QUERY SELECT 'cash.receipt_limit', 'law', format('Cash received %s %s is at or above the legal limit of %s %s. Take it by bank instead.', cash, cur, r ->> 'amount', cur),
                          jsonb_build_array(ev), NULL::integer;
    END IF;
  ELSE
    r := erp.sana_rule_params(p_company, 'cash_payment_limit');
    IF r IS NOT NULL AND cash > (r ->> 'amount')::numeric THEN
      RETURN QUERY SELECT 'cash.payment_limit', 'law', format('Cash paid %s %s is above %s %s. Enter the reason, or pay by bank.', cash, cur, r ->> 'amount', cur),
                          jsonb_build_array(ev), NULL::integer;
    END IF;
  END IF;
END $$;

-- ---------- MRP cap (IN). No MRP column in our schema yet: returns nothing (documented). ----------
CREATE OR REPLACE FUNCTION erp.sana_check_mrp(p_company varchar, p_obj_type integer, p_doc_entry integer, p_line integer DEFAULT NULL, p_draft jsonb DEFAULT NULL)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF erp.sana_rule_params(p_company, 'mrp_cap') IS NULL THEN RETURN; END IF;
  RETURN;   -- TODO: item.mrp does not exist yet; add the comparison when the Indian item master carries MRP.
END $$;

-- ---------- Credit (customer): over the limit, or near it (warn_pct) ----------
CREATE OR REPLACE FUNCTION erp.sana_check_credit(p_company varchar, p_card_code varchar, p_amount numeric DEFAULT 0)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE r jsonb := erp.sana_rule_params(p_company, 'credit_limit'); bp erp.business_partner; expo numeric; ev jsonb;
BEGIN
  IF r IS NULL THEN RETURN; END IF;
  SELECT * INTO bp FROM erp.business_partner b WHERE b.company_code = p_company AND b.card_code = p_card_code;
  IF NOT FOUND OR bp.kind <> 'customer' OR NOT erp._sana_partner_allowed(bp.kind) OR coalesce(bp.credit_limit, 0) <= 0 THEN RETURN; END IF;
  expo := coalesce(bp.balance, 0) + coalesce(p_amount, 0);
  ev := erp._sana_ev('partner', bp.card_code, bp.name, '/partners/' || bp.company_code || '/' || bp.card_code);
  IF expo > bp.credit_limit THEN
    RETURN QUERY SELECT 'credit.over_limit', 'risk', format('%s would owe %s against a credit limit of %s.', bp.name, round(expo, 2), round(bp.credit_limit, 2)), jsonb_build_array(ev), NULL::integer;
  ELSIF expo >= bp.credit_limit * coalesce((r ->> 'warn_pct')::numeric, 90) / 100 THEN
    RETURN QUERY SELECT 'credit.near_limit', 'info', format('%s is at %s %% of the credit limit.', bp.name, round(expo * 100 / bp.credit_limit)), jsonb_build_array(ev), NULL::integer;
  END IF;
END $$;

-- ---------- Duplicate supplier bill: same partner within window_days; score from reference, amount and date ----------
CREATE OR REPLACE FUNCTION erp.sana_check_duplicate_bill(p_company varchar, p_doc_entry integer DEFAULT NULL, p_draft jsonb DEFAULT NULL)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE r jsonb := erp.sana_rule_params(p_company, 'duplicate_bill'); card text; ref text; amt numeric; dt date; me_entry integer; ev jsonb;
BEGIN
  IF r IS NULL OR NOT erp.sana_doc_allowed('ap_invoice') THEN RETURN; END IF;
  IF p_draft IS NULL THEN
    SELECT d.card_code, d.customer_ref, d.total, d.doc_date, d.doc_entry, erp._sana_doc_ev(d) INTO card, ref, amt, dt, me_entry, ev
      FROM erp.document d WHERE d.company_code = p_company AND d.obj_type = 18 AND d.doc_entry = p_doc_entry;
  ELSE
    card := p_draft ->> 'card_code'; ref := p_draft ->> 'customer_ref'; amt := (p_draft ->> 'total')::numeric; dt := coalesce((p_draft ->> 'doc_date')::date, current_date);
    ev := erp._sana_ev('draft', 'new', 'draft bill', NULL);
  END IF;
  IF card IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT 'duplicate.bill', 'risk',
         format('Possible duplicate of %s %s (%s, %s).', o.doc_kind, o.doc_num, o.doc_date, round(o.total, 2)),
         jsonb_build_array(ev, erp._sana_doc_ev(o)), s.sc
    FROM erp.document o
   CROSS JOIN LATERAL (SELECT (CASE WHEN nullif(regexp_replace(upper(coalesce(ref, '')), '[^A-Z0-9]', '', 'g'), '') = regexp_replace(upper(coalesce(o.customer_ref, '')), '[^A-Z0-9]', '', 'g') THEN 60 ELSE 0 END
                             + CASE WHEN abs(coalesce(o.total, 0) - coalesce(amt, -1)) < 0.01 THEN 30 ELSE 0 END
                             + CASE WHEN abs(o.doc_date - dt) <= 7 THEN 10 ELSE 0 END)::integer AS sc) s
   WHERE o.company_code = p_company AND o.obj_type = 18 AND o.card_code = card AND o.status NOT IN ('cancelled', 'cancellation', 'draft')
     AND o.doc_entry IS DISTINCT FROM me_entry AND abs(o.doc_date - dt) <= coalesce((r ->> 'window_days')::integer, 90)
     AND s.sc >= coalesce((r ->> 'min_score')::integer, 70)
   ORDER BY s.sc DESC, o.doc_date DESC LIMIT 3;
END $$;

-- ---------- Licences / certificates expiring (item_certificate.expires_on) ----------
CREATE OR REPLACE FUNCTION erp.sana_check_licence_expiry(p_company varchar, p_days integer DEFAULT NULL)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE r jsonb := erp.sana_rule_params(p_company, 'licence_expiry'); n integer;
BEGIN
  IF r IS NULL OR NOT erp.sana_has('inventory', 'purchase') THEN RETURN; END IF;
  n := coalesce(p_days, (r ->> 'days')::integer, 30);
  RETURN QUERY
  SELECT CASE WHEN c.expires_on < current_date THEN 'licence.expired' ELSE 'licence.expiring' END,
         CASE WHEN c.expires_on < current_date THEN 'risk' ELSE 'info' END,
         format('%s certificate %s for %s %s on %s.', c.scheme, coalesce(c.certificate_no, ''), c.item_code,
                CASE WHEN c.expires_on < current_date THEN 'expired' ELSE 'expires' END, c.expires_on),
         jsonb_build_array(erp._sana_ev('item', c.item_code, c.item_code, '/items/' || c.company_code || '/' || c.item_code)), NULL::integer
    FROM erp.item_certificate c
   WHERE c.company_code = p_company AND c.expires_on IS NOT NULL AND c.expires_on <= current_date + n
     AND c.expires_on >= current_date - 30 AND coalesce(lower(c.status), '') NOT IN ('rejected', 'cancelled', 'renewed')
   ORDER BY c.expires_on LIMIT 20;
END $$;

-- ---------- Payment terms (IN: MSME 45 days). No MSME flag in our schema yet: returns nothing (documented). ----------
CREATE OR REPLACE FUNCTION erp.sana_check_terms(p_company varchar, p_card_code varchar)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
BEGIN
  IF erp.sana_rule_params(p_company, 'msme_terms') IS NULL THEN RETURN; END IF;
  RETURN;   -- TODO: business_partner has no MSME flag yet; compare payment_terms days with params.days when it does.
END $$;

-- ---------- TRN (AE): 15 digits ----------
CREATE OR REPLACE FUNCTION erp.sana_check_trn(p_company varchar, p_card_code varchar)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE r jsonb := erp.sana_rule_params(p_company, 'trn_format'); bp erp.business_partner; digits text;
BEGIN
  IF r IS NULL THEN RETURN; END IF;
  SELECT * INTO bp FROM erp.business_partner b WHERE b.company_code = p_company AND b.card_code = p_card_code;
  IF NOT FOUND OR NOT erp._sana_partner_allowed(bp.kind) OR nullif(btrim(bp.trn), '') IS NULL THEN RETURN; END IF;
  digits := regexp_replace(bp.trn, '\s', '', 'g');
  IF digits !~ ('^[0-9]{' || coalesce((r ->> 'digits')::integer, 15) || '}$') THEN
    RETURN QUERY SELECT 'trn.format', 'risk', format('The TRN of %s is not %s digits.', bp.name, coalesce((r ->> 'digits')::integer, 15)),
                        jsonb_build_array(erp._sana_ev('partner', bp.card_code, bp.name, '/partners/' || bp.company_code || '/' || bp.card_code)), NULL::integer;
  END IF;
END $$;

-- ---------- Dispatcher: the checks that apply to one record, in one round trip (keeps `now` under 3 s) ----------
CREATE OR REPLACE FUNCTION erp.sana_checks(p_company varchar, p_record_type text, p_record_id text, p_draft jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE out jsonb := '[]'; d erp.document; o integer; e integer; ran text[] := '{}'; rec jsonb; bp erp.business_partner;
BEGIN
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN RETURN jsonb_build_object('findings', '[]'::jsonb, 'checked', '[]'::jsonb); END IF;
  IF p_record_type = 'document' THEN
    o := nullif(split_part(p_record_id, ':', 1), '')::integer; e := nullif(split_part(p_record_id, ':', 2), '')::integer;
    SELECT * INTO d FROM erp.document x WHERE x.company_code = p_company AND x.obj_type = o AND x.doc_entry = e;
    IF FOUND AND erp.sana_doc_allowed(d.doc_kind) THEN
      -- a short summary for the model's facts (no cost, no supplier terms; masked again in the Edge Function)
      rec := jsonb_build_object('kind', d.doc_kind, 'number', d.doc_num, 'date', d.doc_date, 'due', d.due_date, 'status', d.status, 'partner', d.card_name,
                                'currency', d.currency, 'total', d.total, 'vat', d.vat_total, 'paid', d.paid,
                                'lines', (SELECT count(*) FROM erp.document_line l WHERE l.company_code = d.company_code AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry));
      out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_tax(p_company, o, e, p_draft) c); ran := ran || 'tax'::text;
      IF d.obj_type IN (13, 17, 15, 23) AND d.card_code IS NOT NULL THEN
        out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_credit(p_company, d.card_code, 0) c); ran := ran || 'credit'::text;
      END IF;
      IF d.obj_type = 18 THEN out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_duplicate_bill(p_company, e, p_draft) c); ran := ran || 'duplicate_bill'::text; END IF;
      IF d.card_code IS NOT NULL THEN out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_trn(p_company, d.card_code) c); ran := ran || 'trn'::text; END IF;
      out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_mrp(p_company, o, e, NULL, p_draft) c);
    END IF;
  ELSIF p_record_type = 'payment' THEN
    out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_cash_limits(p_company, split_part(p_record_id, ':', 1), nullif(split_part(p_record_id, ':', 2), '')::integer, p_draft) c);
    ran := ran || 'cash_limits'::text;
  ELSIF p_record_type = 'partner' THEN
    SELECT * INTO bp FROM erp.business_partner b WHERE b.company_code = p_company AND b.card_code = p_record_id;
    IF FOUND AND erp._sana_partner_allowed(bp.kind) THEN
      rec := jsonb_build_object('kind', bp.kind, 'name', bp.name, 'currency', bp.currency, 'balance', bp.balance, 'credit_limit', bp.credit_limit, 'active', bp.active);
    END IF;
    out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_credit(p_company, p_record_id, 0) c)
               || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_terms(p_company, p_record_id) c)
               || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_trn(p_company, p_record_id) c);
    ran := ran || ARRAY['credit', 'terms', 'trn'];
  ELSIF p_record_type = 'home' THEN
    out := out || (SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]') FROM erp.sana_check_licence_expiry(p_company, NULL) c); ran := ran || 'licence_expiry'::text;
  END IF;
  RETURN jsonb_build_object('findings', out, 'checked', to_jsonb(ran), 'record', rec);
END $$;

-- ---------- Evidence: keep only the ids the caller can open (a finding whose evidence does not resolve is dropped) ----------
CREATE OR REPLACE FUNCTION erp.sana_evidence_resolve(p_company varchar, p_evidence jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(e ORDER BY n), '[]') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_evidence) = 'array' THEN p_evidence ELSE '[]' END) WITH ORDINALITY AS x(e, n)
   WHERE erp.can_see(p_company) AND CASE e ->> 'table'
     WHEN 'document' THEN EXISTS (SELECT 1 FROM erp.document d WHERE d.company_code = p_company AND e ->> 'id' ~ '^[0-9]+:[0-9]+$'
                                    AND d.obj_type = split_part(e ->> 'id', ':', 1)::integer AND d.doc_entry = split_part(e ->> 'id', ':', 2)::integer AND erp.sana_doc_allowed(d.doc_kind))
     WHEN 'payment' THEN erp.sana_has('finance', 'banking') AND EXISTS (SELECT 1 FROM erp.payment p WHERE p.company_code = p_company AND e ->> 'id' ~ '^[IO]:[0-9]+$'
                                    AND p.direction = split_part(e ->> 'id', ':', 1) AND p.doc_entry = split_part(e ->> 'id', ':', 2)::integer)
     WHEN 'partner' THEN EXISTS (SELECT 1 FROM erp.business_partner b WHERE b.company_code = p_company AND b.card_code = e ->> 'id' AND erp._sana_partner_allowed(b.kind))
     WHEN 'item' THEN erp.sana_has('inventory', 'sales', 'purchase') AND EXISTS (SELECT 1 FROM erp.item i WHERE i.company_code = p_company AND i.item_code = e ->> 'id')
     WHEN 'tax_code' THEN EXISTS (SELECT 1 FROM erp._sana_tax_codes(p_company) t WHERE t.code = e ->> 'id')
     WHEN 'draft' THEN true            -- the form the user has open
     ELSE false END
$$;

REVOKE ALL ON FUNCTION erp._sana_tax_codes(varchar), erp.sana_can_see_cost(), erp._sana_ev(text, text, text, text), erp._sana_doc_ev(erp.document), erp._sana_partner_allowed(text),
  erp.sana_check_tax(varchar, integer, integer, jsonb), erp.sana_check_cash_limits(varchar, text, integer, jsonb),
  erp.sana_check_mrp(varchar, integer, integer, integer, jsonb), erp.sana_check_credit(varchar, varchar, numeric),
  erp.sana_check_duplicate_bill(varchar, integer, jsonb), erp.sana_check_licence_expiry(varchar, integer), erp.sana_check_terms(varchar, varchar),
  erp.sana_check_trn(varchar, varchar), erp.sana_checks(varchar, text, text, jsonb), erp.sana_evidence_resolve(varchar, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._sana_tax_codes(varchar), erp.sana_can_see_cost(), erp._sana_ev(text, text, text, text), erp._sana_doc_ev(erp.document), erp._sana_partner_allowed(text),
  erp.sana_check_tax(varchar, integer, integer, jsonb), erp.sana_check_cash_limits(varchar, text, integer, jsonb),
  erp.sana_check_mrp(varchar, integer, integer, integer, jsonb), erp.sana_check_credit(varchar, varchar, numeric),
  erp.sana_check_duplicate_bill(varchar, integer, jsonb), erp.sana_check_licence_expiry(varchar, integer), erp.sana_check_terms(varchar, varchar),
  erp.sana_check_trn(varchar, varchar), erp.sana_checks(varchar, text, text, jsonb), erp.sana_evidence_resolve(varchar, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
