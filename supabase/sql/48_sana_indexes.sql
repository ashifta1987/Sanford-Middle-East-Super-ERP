-- 48 · SANA agent: speed for the duplicate-bill check (S3 follow-up, go by Ashif 16 Nov 2026).
-- Measured on live (qa.finance, AE05 bill 18:22499): the check took ~0.57 s. The date filter `abs(doc_date - d) <= 90` could not use
-- an index, so all ~9,900 bills of a big supplier were read and passed through RLS one by one.
-- Fix: (1) a small partial index on A/P invoices only (13k rows on live), (2) the same check with a range the index can use
-- (doc_date BETWEEN d - window AND d + window). Same results, same rights (SECURITY INVOKER); replaces the 47 version.
-- Safe to run twice.

CREATE INDEX IF NOT EXISTS document_ap_invoice_card_date_idx ON erp.document (company_code, card_code, doc_date) WHERE obj_type = 18;

CREATE OR REPLACE FUNCTION erp.sana_check_duplicate_bill(p_company varchar, p_doc_entry integer DEFAULT NULL, p_draft jsonb DEFAULT NULL)
RETURNS TABLE (code text, severity text, message text, evidence jsonb, score integer)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, pg_temp AS $$
DECLARE r jsonb := erp.sana_rule_params(p_company, 'duplicate_bill'); card text; ref text; amt numeric; dt date; me_entry integer; ev jsonb; win integer;
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
  win := coalesce((r ->> 'window_days')::integer, 90);
  RETURN QUERY
  SELECT 'duplicate.bill', 'risk',
         format('Possible duplicate of %s %s (%s, %s).', o.doc_kind, o.doc_num, o.doc_date, round(o.total, 2)),
         jsonb_build_array(ev, erp._sana_doc_ev(o)), s.sc
    FROM erp.document o
   CROSS JOIN LATERAL (SELECT (CASE WHEN nullif(regexp_replace(upper(coalesce(ref, '')), '[^A-Z0-9]', '', 'g'), '') = regexp_replace(upper(coalesce(o.customer_ref, '')), '[^A-Z0-9]', '', 'g') THEN 60 ELSE 0 END
                             + CASE WHEN abs(coalesce(o.total, 0) - coalesce(amt, -1)) < 0.01 THEN 30 ELSE 0 END
                             + CASE WHEN abs(o.doc_date - dt) <= 7 THEN 10 ELSE 0 END)::integer AS sc) s
   WHERE o.company_code = p_company AND o.obj_type = 18 AND o.card_code = card
     AND o.doc_date BETWEEN dt - win AND dt + win
     AND o.status NOT IN ('cancelled', 'cancellation', 'draft') AND o.doc_entry IS DISTINCT FROM me_entry
     AND s.sc >= coalesce((r ->> 'min_score')::integer, 70)
   ORDER BY s.sc DESC, o.doc_date DESC LIMIT 3;
END $$;

REVOKE ALL ON FUNCTION erp.sana_check_duplicate_bill(varchar, integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_check_duplicate_bill(varchar, integer, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

