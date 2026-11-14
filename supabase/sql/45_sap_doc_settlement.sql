-- 45 · SAP document settlement (14 Nov 2026) - REVIEW, not applied until approved.
-- SAP keeps an invoice "open" (DocStatus O, PaidToDate < DocTotal) after it was settled by an internal reconciliation or a
-- journal entry; SAP's own open item is the open part of the document's journal line on the partner (JDT1 BalDueDeb -
-- BalDueCred). erp.document rows are never changed: a separate table erp.doc_settlement holds, per SAP A/R and A/P
-- document, SAP's status and open amount; screens that list open invoices leave out settled SAP documents and show SAP's
-- open amount. A sync step in erp.sync_company fills it, so re-runs and every company (AE02-AE04) get the same.
--   open_amt: open amount in the document's own terms (like total - paid; a credit note's open credit is positive)
--   settled : SAP DocStatus = 'C', or open amount 0
BEGIN;

CREATE TABLE IF NOT EXISTS erp.doc_settlement (
    company_code varchar(8) NOT NULL,
    obj_type     integer    NOT NULL,
    doc_entry    integer    NOT NULL,
    sap_status   varchar(1),
    trans_id     integer,
    open_amt     numeric(21,6) NOT NULL DEFAULT 0,
    settled      boolean    NOT NULL,
    synced_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, obj_type, doc_entry),
    FOREIGN KEY (company_code, obj_type, doc_entry) REFERENCES erp.document ON DELETE CASCADE
);
ALTER TABLE erp.doc_settlement ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.doc_settlement FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.doc_settlement TO authenticated;
GRANT ALL ON erp.doc_settlement TO service_role;
DROP POLICY IF EXISTS doc_settlement_read ON erp.doc_settlement;
CREATE POLICY doc_settlement_read ON erp.doc_settlement FOR SELECT TO authenticated USING (erp.can_see(company_code));

-- per SAP A/R and A/P document: SAP status and SAP's open amount (side sign: customers debit - credit, suppliers credit - debit)
CREATE OR REPLACE FUNCTION erp.sync_doc_settlement(p_company varchar) RETURNS bigint
LANGUAGE plpgsql SET search_path = erp, sap, public AS $f$
DECLARE n bigint;
BEGIN
  INSERT INTO erp.doc_settlement AS t (company_code, obj_type, doc_entry, sap_status, trans_id, open_amt, settled)
  WITH j AS (SELECT "TransId" AS tid, "ShortName" AS sn, sum(coalesce("BalDueDeb", 0) - coalesce("BalDueCred", 0)) AS bd
               FROM sap."JDT1" WHERE company_code = p_company AND "ShortName" IS DISTINCT FROM "Account" GROUP BY 1, 2),
       h AS (SELECT 13 AS o,   1 AS side, "DocEntry" e, "CardCode" cc, "DocStatus" st, "TransId" tid FROM sap."OINV" WHERE company_code = p_company
             UNION ALL SELECT 14,  1, "DocEntry", "CardCode", "DocStatus", "TransId" FROM sap."ORIN" WHERE company_code = p_company
             UNION ALL SELECT 203, 1, "DocEntry", "CardCode", "DocStatus", "TransId" FROM sap."ODPI" WHERE company_code = p_company
             UNION ALL SELECT 18, -1, "DocEntry", "CardCode", "DocStatus", "TransId" FROM sap."OPCH" WHERE company_code = p_company
             UNION ALL SELECT 19, -1, "DocEntry", "CardCode", "DocStatus", "TransId" FROM sap."ORPC" WHERE company_code = p_company
             UNION ALL SELECT 204,-1, "DocEntry", "CardCode", "DocStatus", "TransId" FROM sap."ODPO" WHERE company_code = p_company)
  SELECT d.company_code, d.obj_type, d.doc_entry, h.st, h.tid,
         h.side * coalesce(d.sign, 1) * coalesce(j.bd, 0),
         coalesce(h.st, 'O') = 'C' OR round(coalesce(j.bd, 0), 2) = 0
    FROM h JOIN erp.document d ON d.company_code = p_company AND d.obj_type = h.o AND d.doc_entry = h.e AND d.source = 'sap'
    LEFT JOIN j ON j.tid = h.tid AND j.sn = h.cc
  ON CONFLICT (company_code, obj_type, doc_entry) DO UPDATE SET sap_status = EXCLUDED.sap_status, trans_id = EXCLUDED.trans_id,
       open_amt = EXCLUDED.open_amt, settled = EXCLUDED.settled, synced_at = now()
   WHERE (t.sap_status, t.trans_id, t.open_amt, t.settled) IS DISTINCT FROM (EXCLUDED.sap_status, EXCLUDED.trans_id, EXCLUDED.open_amt, EXCLUDED.settled);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;

-- settled SAP document? (false for documents created in Super ERP and for documents without a settlement row)
CREATE OR REPLACE FUNCTION erp._doc_settled(p_company varchar, p_obj integer, p_entry integer) RETURNS boolean
LANGUAGE sql STABLE SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT s.settled FROM erp.doc_settlement s WHERE s.company_code = p_company AND s.obj_type = p_obj AND s.doc_entry = p_entry), false)
$$;
-- open amount: SAP's for SAP documents with a settlement row, else total - paid
CREATE OR REPLACE FUNCTION erp._doc_open_amt(p_company varchar, p_obj integer, p_entry integer, p_total numeric, p_paid numeric) RETURNS numeric
LANGUAGE sql STABLE SET search_path = erp, pg_temp AS $$
  SELECT coalesce((SELECT s.open_amt FROM erp.doc_settlement s WHERE s.company_code = p_company AND s.obj_type = p_obj AND s.doc_entry = p_entry),
                  coalesce(p_total, 0) - coalesce(p_paid, 0))
$$;
GRANT EXECUTE ON FUNCTION erp._doc_settled(varchar, integer, integer), erp._doc_open_amt(varchar, integer, integer, numeric, numeric) TO authenticated;

CREATE OR REPLACE PROCEDURE erp.sync_company(IN p_company character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE n bigint; t timestamptz;
BEGIN
  PERFORM set_config('erp.sync', 'on', false);
  INSERT INTO erp.company (company_code, legal_name, short_name, country, currency, licence_type, sap_schema)
  SELECT c.company_code, c.legal_name, c.legal_name, c.country, c.currency, c.licence_type, c.sap_schema FROM sap._company c WHERE c.company_code = p_company
  ON CONFLICT (company_code) DO UPDATE SET legal_name = EXCLUDED.legal_name, country = EXCLUDED.country, currency = EXCLUDED.currency,
       licence_type = EXCLUDED.licence_type, sap_schema = EXCLUDED.sap_schema;
  COMMIT;
  t := clock_timestamp(); n := erp.sync_branches(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_branches', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_accounts(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_accounts', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_cost_centres(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_cost_centres', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_tax_codes(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_tax_codes', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_fx_rates(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_fx_rates', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_salespeople(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_salespeople', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_terms(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_terms', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_business_partners(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_business_partners', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_addresses(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_addresses', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_bp_merchandisers(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_bp_merchandisers', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_brands(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_brands', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_group_items(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_group_items', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_items(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_items', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_certificates(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_certificates', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_market_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_market_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_tags(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_tags', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_price_lists(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_price_lists', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_item_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_item_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_special_prices(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_special_prices', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_special_price_periods(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_special_price_periods', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_discount_groups(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_discount_groups', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_discount_group_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_discount_group_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_warehouses(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_warehouses', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_stock_balances(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_stock_balances', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_batches(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_batches', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_serials(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_serials', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_stock_movements(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_stock_movements', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_quotation(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_quotation', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_quotation_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_quotation_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_order(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_order', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_order_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_order_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_delivery(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_delivery', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_delivery_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_delivery_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_return(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_return', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_sales_return_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_sales_return_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_invoice(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_invoice', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_invoice_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_invoice_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_credit_note(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_credit_note', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_credit_note_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_credit_note_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_down_payment(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_down_payment', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ar_down_payment_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ar_down_payment_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_request(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_request', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_request_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_request_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_quotation(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_quotation', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_quotation_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_quotation_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_order(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_order', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_purchase_order_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_purchase_order_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_po(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_po', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_po_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_po_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_return(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_return', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_return_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_return_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_invoice(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_invoice', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_invoice_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_invoice_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_credit_note(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_credit_note', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_credit_note_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_credit_note_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_down_payment(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_down_payment', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_ap_down_payment_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_ap_down_payment_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_transfer_request(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_transfer_request', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_transfer_request_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_transfer_request_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_inventory_transfer(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_inventory_transfer', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_inventory_transfer_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_inventory_transfer_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_receipt_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_receipt_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_issue(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_issue', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_docs_goods_issue_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_docs_goods_issue_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_journals(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_journals', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_journal_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_journal_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payments_incoming(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payments_incoming', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_allocations_incoming(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_allocations_incoming', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payments_outgoing(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payments_outgoing', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payment_allocations_outgoing(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payment_allocations_outgoing', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_ic_account_map(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_ic_account_map', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_hr_org(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_hr_org', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employees(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employees', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employee_documents(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employee_documents', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_wage_types(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_wage_types', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_employee_pay(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_employee_pay', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_leave_types(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_leave_types', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_payroll_results(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_payroll_results', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_air_tickets(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_air_tickets', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_tpl_contracts(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_tpl_contracts', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_artwork(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_artwork', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_artwork_lines(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_artwork_lines', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_supplier_pi(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_supplier_pi', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_trademarks(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_trademarks', n, t); COMMIT;
  t := clock_timestamp(); n := erp.sync_doc_settlement(p_company); INSERT INTO erp.sync_log (company_code, step, rows_written, started_at) VALUES (p_company, 'sync_doc_settlement', n, t); COMMIT;
  PERFORM set_config('erp.sync', 'off', false);
END $procedure$;

CREATE OR REPLACE FUNCTION erp.rpt_open_items(p_company character varying, p_kind text DEFAULT NULL::text)
 RETURNS TABLE(doc_kind text, obj_type integer, doc_entry integer, doc_no text, doc_date date, due_date date, card_code character varying, card_name text, currency character varying, total numeric, open_amount numeric, days_open integer, link text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'erp', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  PERFORM erp._rpt_need(p_company, ARRAY['sales', 'purchase', 'finance', 'inventory'], 'Sales, Purchasing, Inventory or Financials');
  IF nullif(p_kind, '') IS NOT NULL AND p_kind NOT IN ('sales_quotation', 'sales_order', 'delivery', 'ar_down_payment', 'ar_invoice',
       'ar_credit_note', 'purchase_request', 'purchase_quotation', 'purchase_order', 'goods_receipt_po', 'ap_down_payment', 'ap_invoice',
       'ap_credit_note', 'transfer_request') THEN
    RAISE EXCEPTION 'Document kind % has no open items list.', p_kind USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  SELECT d.doc_kind, d.obj_type, d.doc_entry, coalesce(w.doc_no, d.doc_num::text), d.doc_date, d.due_date, d.card_code, d.card_name,
         d.currency, round(coalesce(d.total, 0), 2),
         round(CASE WHEN d.obj_type IN (13, 14, 203, 18, 19, 204) THEN erp._doc_open_amt(d.company_code, d.obj_type, d.doc_entry, d.total, d.paid)
                    ELSE coalesce((SELECT sum(CASE WHEN coalesce(dl.quantity, 0) = 0 THEN 0
                                                   ELSE coalesce(dl.open_qty, dl.quantity) / dl.quantity * coalesce(dl.line_total, 0) END)
                                     FROM erp.document_line dl
                                    WHERE dl.company_code = d.company_code AND dl.obj_type = d.obj_type AND dl.doc_entry = d.doc_entry),
                                  coalesce(d.total, 0)) END, 2),
         (current_date - d.doc_date)::integer,
         erp._doc_link(d.company_code, d.obj_type, d.doc_entry)
    FROM erp.document d
    LEFT JOIN erp.doc_workflow w ON w.company_code = d.company_code AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
   WHERE d.company_code = p_company AND d.status = 'open' AND NOT erp._doc_settled(d.company_code, d.obj_type, d.doc_entry)
     AND d.obj_type IN (23, 17, 15, 203, 13, 14, 1470000113, 540000006, 22, 20, 204, 18, 19, 1250000001)
     AND (nullif(p_kind, '') IS NULL OR d.doc_kind = p_kind)
   ORDER BY d.doc_date, d.obj_type, d.doc_entry;
END $function$;

CREATE OR REPLACE FUNCTION erp.payment_open_docs(p_company character varying, p_dir text, p_card text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'erp', 'pg_temp'
AS $function$
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
                     AND d.source <> 'erp' AND d.status = 'open' AND NOT erp._doc_settled(d.company_code, d.obj_type, d.doc_entry)));
END $function$;

CREATE OR REPLACE FUNCTION erp.sana_receivables(p_company character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'erp', 'pg_temp'
AS $function$
BEGIN
  IF NOT erp.sana_has('sales','finance') THEN RETURN erp.sana_denied('receivables'); END IF;
  RETURN (WITH o AS (
      SELECT d.*, erp._doc_open_amt(d.company_code, d.obj_type, d.doc_entry, d.total, d.paid) AS open_amt, current_date - due_date AS days FROM erp.document d
       WHERE d.doc_kind = 'ar_invoice' AND d.status = 'open' AND total > coalesce(paid, 0) AND NOT erp._doc_settled(d.company_code, d.obj_type, d.doc_entry) AND (p_company IS NULL OR d.company_code = p_company))
    SELECT jsonb_build_object(
      'open_total', (SELECT coalesce(sum(open_amt), 0) FROM o),
      'not_due', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days <= 0),
      'd1_30', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN 1 AND 30),
      'd31_60', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN 31 AND 60),
      'd61_90', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN 61 AND 90),
      'over_90', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days > 90),
      'top_overdue', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT card_code AS code, card_name AS customer, sum(open_amt) AS overdue, max(days) AS oldest_days
                        FROM o WHERE days > 0 GROUP BY card_code, card_name ORDER BY 3 DESC LIMIT 8) x),
      'list_link', '/docs/ar_invoice?f_status=open'));
END $function$;

CREATE OR REPLACE FUNCTION erp.sana_payables(p_company character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'erp', 'pg_temp'
AS $function$
BEGIN
  IF NOT erp.sana_has('purchase','finance') THEN RETURN erp.sana_denied('payables'); END IF;
  RETURN (WITH o AS (
      SELECT d.*, erp._doc_open_amt(d.company_code, d.obj_type, d.doc_entry, d.total, d.paid) AS open_amt, current_date - due_date AS days FROM erp.document d
       WHERE d.doc_kind = 'ap_invoice' AND d.status = 'open' AND total > coalesce(paid, 0) AND NOT erp._doc_settled(d.company_code, d.obj_type, d.doc_entry) AND (p_company IS NULL OR d.company_code = p_company))
    SELECT jsonb_build_object(
      'open_total', (SELECT coalesce(sum(open_amt), 0) FROM o),
      'due_7_days', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days BETWEEN -7 AND 0),
      'overdue', (SELECT coalesce(sum(open_amt), 0) FROM o WHERE days > 0),
      'top_suppliers', (SELECT coalesce(jsonb_agg(x), '[]') FROM (SELECT card_code AS code, card_name AS supplier, sum(open_amt) AS open, max(days) AS oldest_days
                        FROM o GROUP BY card_code, card_name ORDER BY 3 DESC LIMIT 8) x),
      'list_link', '/docs/ap_invoice?f_status=open'));
END $function$;

CREATE OR REPLACE FUNCTION erp.sana_finance_summary(p_company character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'erp', 'pg_temp'
AS $function$
BEGIN
  IF NOT erp.sana_has('finance') THEN RETURN erp.sana_denied('finance'); END IF;
  RETURN jsonb_build_object(
    'by_drawer', (SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM (
       SELECT CASE a.group_mask WHEN 1 THEN 'assets' WHEN 2 THEN 'liabilities' WHEN 3 THEN 'equity' WHEN 4 THEN 'revenue'
                                WHEN 5 THEN 'cost_of_sales' WHEN 6 THEN 'expenses' ELSE 'other' END AS k,
              sum(coalesce(a.balance_local, 0) + coalesce((SELECT sum(jl.debit - jl.credit) FROM erp.journal_line jl
                    JOIN erp.journal_entry je ON je.company_code = jl.company_code AND je.trans_id = jl.trans_id
                   WHERE jl.company_code = a.company_code AND jl.acct_code = a.acct_code AND je.source <> 'sap'), 0)) AS v
         FROM erp.account a WHERE a.postable AND (p_company IS NULL OR a.company_code = p_company) GROUP BY 1) a),
    'payables_due_7_days', (SELECT jsonb_build_object('count', count(*), 'amount', coalesce(sum(erp._doc_open_amt(company_code, obj_type, doc_entry, total, paid)), 0)) FROM erp.document
       WHERE doc_kind = 'ap_invoice' AND status = 'open' AND due_date <= current_date + 7 AND NOT erp._doc_settled(company_code, obj_type, doc_entry) AND (p_company IS NULL OR company_code = p_company)),
    'journals_last_30_days', (SELECT count(*) FROM erp.journal_entry WHERE ref_date >= current_date - 30 AND (p_company IS NULL OR company_code = p_company)),
    'links', jsonb_build_array(jsonb_build_object('label', 'Chart of accounts', 'link', '/financials/accounts'),
                               jsonb_build_object('label', 'Journal entries', 'link', '/financials/journals')));
END $function$;

COMMIT;
-- first fill (after review): SELECT erp.sync_doc_settlement(company_code) FROM erp.company;
