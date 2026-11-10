
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
