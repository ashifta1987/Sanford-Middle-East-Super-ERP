-- 50 · SANA search speed (S4, go by Ashif 16 Nov 2026).
-- Measured on live (qa.sales / qa.finance, AE05): sana_find('SMP-1010') and sana_find('C0001') were cancelled at the 8 s API limit
-- (ILIKE '%…%' over 651k documents, the access check running row by row); sana_stock('SMP-1010') took 2.1 s. Those two lookups
-- made q4 / q6 of the timing set take 13–15 s.
-- Rules (agreed):
--   (a) sana_find tries EXACT matches first — card code, item code / barcode, document number / doc_entry / Southfield number,
--       partner name prefix — each with an index and limited to the caller's companies before any per-row access check. Only when
--       nothing matches does it fall back to text search: pg_trgm indexes, at most 50 candidate rows per list.
--   (b) sana_stock: stock_balance (company_code, item_code) is already indexed by its primary key (company_code, item_code,
--       whs_code), so no new index is needed there; the slow part was finding the item, so sana_stock gets the same exact-first
--       rule and a pg_trgm index on item names.
--   (c) A time budget: Postgres cannot shorten the timeout of a statement that is already running (a function's
--       `SET statement_timeout` does not apply to the call itself — tested), so sana_find checks the clock between phases and
--       skips the text search once 2.5 s have passed, returning "no match"; the sana Edge Function also stops waiting for a
--       lookup after 3 s and treats it as no match (core.ts).
-- Why a helper: under row-level security Postgres may only use an index for a condition whose operator is "leakproof". `=` is,
-- ILIKE / LIKE are not, so a text search on an RLS table always reads every row and runs the access check per row (seen on live:
-- 2 s on 24k items, >15 s on 650k documents, even with the pg_trgm index). So the text and prefix searches run in a SECURITY
-- DEFINER helper that returns only KEYS, only from the caller's own companies (re-checked inside), at most 50; the caller then
-- reads those rows by key under its normal RLS and role rules. Exact matches (=) need no helper.
-- Output shape and role rules are unchanged from 36_sana.sql. Safe to run twice. Builds GIN indexes on erp.document (about 650k rows):
-- writes to erp.document wait while they build.

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE INDEX IF NOT EXISTS document_doc_num_idx        ON erp.document (company_code, doc_num);
CREATE INDEX IF NOT EXISTS document_card_name_trgm     ON erp.document USING gin (card_name extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS document_customer_ref_trgm  ON erp.document USING gin (customer_ref extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS business_partner_name_prefix ON erp.business_partner (company_code, lower(name) text_pattern_ops);
CREATE INDEX IF NOT EXISTS business_partner_name_trgm  ON erp.business_partner USING gin (name extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS business_partner_fname_trgm ON erp.business_partner USING gin (foreign_name extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS item_barcode_idx            ON erp.item (company_code, barcode);
CREATE INDEX IF NOT EXISTS item_name_trgm              ON erp.item USING gin (name extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS doc_workflow_doc_no_upper   ON erp.doc_workflow (company_code, upper(doc_no));

-- The companies a search may look in: the one asked for (if the caller may see it), else all of the caller's companies.
CREATE OR REPLACE FUNCTION erp._sana_search_companies(p_company varchar) RETURNS varchar[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN p_company IS NOT NULL THEN CASE WHEN erp.can_see(p_company) THEN ARRAY[p_company]::varchar[] ELSE '{}'::varchar[] END
              ELSE coalesce((SELECT array_agg(uc.company_code) FROM erp.user_company uc WHERE uc.user_id = erp.current_user_id()), '{}') END
$$;

-- Keys only (company, code / obj_type, doc_entry), only in the caller's companies, at most 50. p_what: item | partner | partner_prefix | document.
CREATE OR REPLACE FUNCTION erp._sana_text_keys(p_what text, p_cos varchar[], p_text text, p_kinds text[] DEFAULT NULL)
RETURNS TABLE (company_code varchar, code text, obj_type integer, doc_entry integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, extensions, pg_temp AS $$
DECLARE cos varchar[] := ARRAY(SELECT unnest(p_cos) INTERSECT SELECT uc.company_code FROM erp.user_company uc WHERE uc.user_id = erp.current_user_id());
        q text := '%' || replace(replace(replace(left(btrim(coalesce(p_text, '')), 80), '\', ''), '%', ''), '_', '\_') || '%';
        prefix text := replace(replace(replace(lower(left(btrim(coalesce(p_text, '')), 80)), '\', ''), '%', ''), '_', '\_') || '%';
BEGIN
  IF cardinality(cos) = 0 OR length(btrim(coalesce(p_text, ''))) < 2 THEN RETURN; END IF;
  IF p_what = 'item' THEN
    RETURN QUERY SELECT i.company_code, i.item_code::text, NULL::integer, NULL::integer FROM erp.item i WHERE i.company_code = ANY (cos) AND i.name ILIKE q LIMIT 50;
  ELSIF p_what = 'partner' THEN
    RETURN QUERY SELECT b.company_code, b.card_code::text, NULL::integer, NULL::integer FROM erp.business_partner b
                  WHERE b.company_code = ANY (cos) AND (b.name ILIKE q OR b.foreign_name ILIKE q) LIMIT 50;
  ELSIF p_what = 'partner_prefix' THEN
    RETURN QUERY SELECT b.company_code, b.card_code::text, NULL::integer, NULL::integer FROM erp.business_partner b
                  WHERE b.company_code = ANY (cos) AND lower(b.name) LIKE prefix LIMIT 50;
  ELSIF p_what = 'document' THEN
    RETURN QUERY SELECT d.company_code, NULL::text, d.obj_type, d.doc_entry FROM erp.document d
                  WHERE d.company_code = ANY (cos) AND d.doc_kind = ANY (coalesce(p_kinds, '{}')) AND (d.card_name ILIKE q OR d.customer_ref ILIKE q) LIMIT 50;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION erp._sana_find_out(p_see_p boolean, p_see_i boolean, p_partners jsonb, p_items jsonb, p_docs jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT CASE WHEN p_see_p THEN jsonb_build_object('partners', p_partners) ELSE '{}'::jsonb END
      || CASE WHEN p_see_i THEN jsonb_build_object('items', p_items) ELSE '{}'::jsonb END
      || jsonb_build_object('documents', p_docs)
$$;

CREATE OR REPLACE FUNCTION erp.sana_find(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, extensions, pg_temp AS $$
DECLARE t text := btrim(left(coalesce(p_query, ''), 80));
        q text := '%' || replace(replace(replace(left(btrim(coalesce(p_query, '')), 80), '\', ''), '%', ''), '_', '\_') || '%';
        prefix text := replace(replace(replace(lower(btrim(left(coalesce(p_query, ''), 80))), '\', ''), '%', ''), '_', '\_') || '%';
        num integer := CASE WHEN btrim(coalesce(p_query, '')) ~ '^[0-9]{1,9}$' THEN btrim(p_query)::integer END;
        cos varchar[] := erp._sana_search_companies(p_company);
        started timestamptz := clock_timestamp();
        see_p boolean := erp.sana_has('sales', 'purchase', 'finance', 'bp');
        see_i boolean := erp.sana_has('inventory', 'sales', 'purchase');
        -- role rules worked out ONCE (not per row): which partner kinds and document kinds this caller may see
        see_c boolean := erp.sana_has('sales', 'finance', 'bp');
        see_s boolean := erp.sana_has('purchase', 'finance', 'bp');
        kinds text[] := (SELECT coalesce(array_agg(k), '{}') FROM unnest(ARRAY['sales_quotation','sales_order','delivery','sales_return','ar_down_payment','ar_invoice',
                           'ar_credit_note','purchase_request','purchase_quotation','purchase_order','goods_receipt_po','goods_return','ap_down_payment','ap_invoice',
                           'ap_credit_note','transfer_request','inventory_transfer','goods_receipt','goods_issue']) k WHERE erp.sana_doc_allowed(k));
        partners jsonb := '[]'; items jsonb := '[]'; docs jsonb := '[]';
BEGIN
  -- same shape as 36: 'partners' / 'items' only for roles that may see them, 'documents' always
  IF length(t) < 2 THEN RETURN jsonb_build_object('error', 'Search text is too short'); END IF;
  IF cardinality(cos) = 0 THEN RETURN erp._sana_find_out(see_p, see_i, partners, items, docs); END IF;

  -- 1. exact: codes, barcodes, document numbers, partner name prefix (all indexed)
  IF see_p THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO partners FROM (
      SELECT b.company_code AS company, b.card_code AS code, b.name, b.kind, '/bp/' || b.company_code || '/' || b.card_code AS link
        FROM erp.business_partner b
       WHERE b.company_code = ANY (cos)
         AND (b.card_code IN (t, upper(t))
              OR (b.company_code, b.card_code) IN (SELECT k.company_code, k.code FROM erp._sana_text_keys('partner_prefix', cos, t) k))
         AND (b.kind <> 'customer' OR see_c) AND (b.kind <> 'supplier' OR see_s)
       ORDER BY (b.card_code IN (t, upper(t))) DESC, b.name LIMIT 8) x;
  END IF;
  IF see_i THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO items FROM (
      SELECT i.company_code AS company, i.item_code AS code, i.name, '/items/' || i.company_code || '/' || i.item_code AS link
        FROM erp.item i WHERE i.company_code = ANY (cos) AND (i.item_code IN (t, upper(t)) OR i.barcode = t)
       ORDER BY i.item_code LIMIT 8) x;
  END IF;
  -- documents: SAP number (company_code, doc_num index) or Southfield number (doc_workflow (company_code, upper(doc_no)) index)
  SELECT coalesce(jsonb_agg(x), '[]') INTO docs FROM (
    WITH c AS MATERIALIZED (
      SELECT d.* FROM erp.document d WHERE num IS NOT NULL AND d.company_code = ANY (cos) AND d.doc_num = num
      UNION
      SELECT d.* FROM erp.doc_workflow w JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE w.company_code = ANY (cos) AND upper(w.doc_no) = upper(t)
      LIMIT 50)
    SELECT c.company_code AS company, c.doc_kind AS kind, erp._sana_doc_no(c.company_code, c.obj_type, c.doc_entry, c.doc_num) AS number,
           c.card_name AS partner, c.doc_date AS date, c.status, c.total, c.currency, erp._doc_link(c.company_code, c.obj_type, c.doc_entry) AS link
      FROM c WHERE c.doc_kind = ANY (kinds)
     ORDER BY c.doc_date DESC LIMIT 8) x;
  IF jsonb_array_length(partners) + jsonb_array_length(items) + jsonb_array_length(docs) > 0 THEN
    RETURN erp._sana_find_out(see_p, see_i, partners, items, docs);
  END IF;

  -- 2. text search (pg_trgm), at most 50 candidates per list, only within the time budget and for 3+ characters
  IF length(t) < 3 OR clock_timestamp() - started > interval '2.5 seconds' THEN
    RETURN erp._sana_find_out(see_p, see_i, partners, items, docs);
  END IF;
  IF see_p THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO partners FROM (
      WITH c AS MATERIALIZED (SELECT b.* FROM erp.business_partner b
                               WHERE (b.company_code, b.card_code) IN (SELECT k.company_code, k.code FROM erp._sana_text_keys('partner', cos, t) k))
      SELECT c.company_code AS company, c.card_code AS code, c.name, c.kind, '/bp/' || c.company_code || '/' || c.card_code AS link FROM c
       WHERE (c.kind <> 'customer' OR see_c) AND (c.kind <> 'supplier' OR see_s)
       ORDER BY c.name LIMIT 8) x;
  END IF;
  IF see_i AND clock_timestamp() - started <= interval '2.5 seconds' THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO items FROM (
      WITH c AS MATERIALIZED (SELECT i.* FROM erp.item i WHERE (i.company_code, i.item_code) IN (SELECT k.company_code, k.code FROM erp._sana_text_keys('item', cos, t) k))
      SELECT c.company_code AS company, c.item_code AS code, c.name, '/items/' || c.company_code || '/' || c.item_code AS link FROM c ORDER BY c.item_code LIMIT 8) x;
  END IF;
  IF clock_timestamp() - started <= interval '2.5 seconds' THEN
    SELECT coalesce(jsonb_agg(x), '[]') INTO docs FROM (
      WITH c AS MATERIALIZED (SELECT d.* FROM erp.document d
                               WHERE (d.company_code, d.obj_type, d.doc_entry) IN (SELECT k.company_code, k.obj_type, k.doc_entry FROM erp._sana_text_keys('document', cos, t, kinds) k))
      SELECT c.company_code AS company, c.doc_kind AS kind, erp._sana_doc_no(c.company_code, c.obj_type, c.doc_entry, c.doc_num) AS number,
             c.card_name AS partner, c.doc_date AS date, c.status, c.total, c.currency, erp._doc_link(c.company_code, c.obj_type, c.doc_entry) AS link
        FROM c ORDER BY c.doc_date DESC LIMIT 8) x;
  END IF;
  RETURN erp._sana_find_out(see_p, see_i, partners, items, docs);
END $$;

-- Stock: exact item code / barcode first, then item name (pg_trgm, at most 50 candidates). Cost only for finance, purchasing,
-- inventory and the owner (unchanged rule from 36).
CREATE OR REPLACE FUNCTION erp.sana_stock(p_query text, p_company varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = erp, extensions, pg_temp AS $$
DECLARE cost boolean := erp.sana_has('finance', 'purchase', 'inventory'); t text := btrim(left(coalesce(p_query, ''), 80));
        q text := '%' || replace(replace(replace(left(btrim(coalesce(p_query, '')), 80), '\', ''), '%', ''), '_', '\_') || '%';
        cos varchar[] := erp._sana_search_companies(p_company); comps varchar[]; codes text[];
BEGIN
  IF NOT erp.sana_has('inventory', 'sales', 'purchase') THEN RETURN erp.sana_denied('inventory'); END IF;
  IF length(t) < 2 OR cardinality(cos) = 0 THEN RETURN jsonb_build_object('items', '[]'::jsonb, 'cost_visible', cost); END IF;
  SELECT array_agg(i.company_code), array_agg(i.item_code::text) INTO comps, codes FROM (
    SELECT company_code, item_code FROM erp.item WHERE company_code = ANY (cos) AND (item_code IN (t, upper(t)) OR barcode = t) LIMIT 5) i;
  IF codes IS NULL AND length(t) >= 3 THEN
    SELECT array_agg(i.company_code), array_agg(i.item_code::text) INTO comps, codes FROM (
      SELECT k.company_code, k.code AS item_code FROM erp._sana_text_keys('item', cos, t) k ORDER BY k.code LIMIT 5) i;
  END IF;
  IF codes IS NULL THEN RETURN jsonb_build_object('items', '[]'::jsonb, 'cost_visible', cost); END IF;
  RETURN jsonb_build_object('items', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
    SELECT i.company_code AS company, i.item_code AS code, i.name, i.inventory_uom AS unit, '/items/' || i.company_code || '/' || i.item_code AS link,
           (SELECT coalesce(jsonb_agg(jsonb_build_object('warehouse', s.whs_code, 'on_hand', s.on_hand, 'committed', s.committed, 'ordered', s.on_order,
                    'available', s.on_hand - s.committed, 'below_minimum', s.min_stock > 0 AND s.on_hand < s.min_stock) ORDER BY s.whs_code), '[]')
              FROM erp.stock_balance s WHERE s.company_code = i.company_code AND s.item_code = i.item_code) AS warehouses,
           CASE WHEN cost THEN i.avg_cost END AS average_cost
      FROM erp.item i
     WHERE (i.company_code, i.item_code) IN (SELECT u.c, u.i FROM unnest(comps, codes) AS u(c, i))
     ORDER BY i.item_code LIMIT 5) x), 'cost_visible', cost);
END $$;

REVOKE ALL ON FUNCTION erp._sana_search_companies(varchar), erp._sana_find_out(boolean, boolean, jsonb, jsonb, jsonb), erp._sana_text_keys(text, varchar[], text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp._sana_search_companies(varchar), erp._sana_find_out(boolean, boolean, jsonb, jsonb, jsonb), erp._sana_text_keys(text, varchar[], text, text[]) TO authenticated;
REVOKE ALL ON FUNCTION erp.sana_find(text, varchar), erp.sana_stock(text, varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.sana_find(text, varchar), erp.sana_stock(text, varchar) TO authenticated;

NOTIFY pgrst, 'reload schema';
