-- 40 · SAP field sizes (13 Nov 2026, AE05 load): every erp column the sync fills straight from a SAP field is at least
-- as wide as that field in the sap schema (HANA DECIMAL(21,6) -> numeric(21,6); NVARCHAR(n) -> varchar(n)), so a value
-- SAP accepts can always be synced. Generated from the erp.sync_* functions; widening only, no data changes.
-- Views reading these columns are dropped and recreated unchanged (same definition, options, grants, comments).
BEGIN;
DROP VIEW erp.payment_list;
DROP VIEW erp.purchase_doc_list;
DROP VIEW erp.sales_doc_list_fc;
DROP VIEW erp.purchase_doc_list_fc;
DROP VIEW erp.stock_balance_parts;
DROP VIEW erp.inventory_doc_list;
DROP VIEW erp.bp_balance_fc;
DROP VIEW erp.sales_doc_list;
DROP VIEW erp.fx_rate_list;
DROP VIEW erp.sales_order_list;
DROP VIEW erp.payment_list_fc;
DROP VIEW erp.item_movement_list;
-- the HR policy compares hr_code, so it is dropped and recreated unchanged around the type change
DROP POLICY air_ticket_accrual_hr_or_self ON erp.air_ticket_accrual;
ALTER TABLE erp.account ALTER COLUMN balance_local TYPE numeric(21,6);
ALTER TABLE erp.air_ticket_accrual ALTER COLUMN closing TYPE numeric(21,6), ALTER COLUMN hr_code TYPE character varying(254), ALTER COLUMN opening TYPE numeric(21,6);
ALTER TABLE erp.artwork_request ALTER COLUMN po_amount TYPE numeric(21,6);
ALTER TABLE erp.business_partner ALTER COLUMN balance TYPE numeric(21,6), ALTER COLUMN credit_limit TYPE numeric(21,6), ALTER COLUMN inflow_target TYPE numeric(21,6), ALTER COLUMN outflow_target TYPE numeric(21,6), ALTER COLUMN tpl_handling_fee TYPE numeric(21,6), ALTER COLUMN tpl_storage_rate TYPE numeric(21,6);
ALTER TABLE erp.document ALTER COLUMN fx_rate TYPE numeric(21,6), ALTER COLUMN paid TYPE numeric(21,6), ALTER COLUMN total TYPE numeric(21,6), ALTER COLUMN total_fc TYPE numeric(21,6), ALTER COLUMN vat_total TYPE numeric(21,6);
ALTER TABLE erp.document_line ALTER COLUMN cbm TYPE numeric(21,6), ALTER COLUMN discount_pct TYPE numeric(21,6), ALTER COLUMN gross_buy_price TYPE numeric(21,6), ALTER COLUMN line_total TYPE numeric(21,6), ALTER COLUMN line_total_fc TYPE numeric(21,6), ALTER COLUMN open_qty TYPE numeric(21,6), ALTER COLUMN price TYPE numeric(21,6), ALTER COLUMN quantity TYPE numeric(21,6), ALTER COLUMN stock_price TYPE numeric(21,6), ALTER COLUMN vat TYPE numeric(21,6);
ALTER TABLE erp.fx_rate ALTER COLUMN rate TYPE numeric(21,6);
ALTER TABLE erp.ic_account_map ALTER COLUMN acct_code TYPE character varying(100), ALTER COLUMN group_acct_code TYPE character varying(100);
ALTER TABLE erp.item ALTER COLUMN avg_cost TYPE numeric(21,6), ALTER COLUMN moq TYPE numeric(21,6);
ALTER TABLE erp.item_price ALTER COLUMN price TYPE numeric(21,6);
ALTER TABLE erp.journal_entry ALTER COLUMN total_local TYPE numeric(21,6), ALTER COLUMN total_sys TYPE numeric(21,6);
ALTER TABLE erp.journal_line ALTER COLUMN credit TYPE numeric(21,6), ALTER COLUMN debit TYPE numeric(21,6), ALTER COLUMN fc_credit TYPE numeric(21,6), ALTER COLUMN fc_debit TYPE numeric(21,6), ALTER COLUMN sys_credit TYPE numeric(21,6), ALTER COLUMN sys_debit TYPE numeric(21,6);
ALTER TABLE erp.payment ALTER COLUMN card TYPE numeric(21,6), ALTER COLUMN cash TYPE numeric(21,6), ALTER COLUMN cheque TYPE numeric(21,6), ALTER COLUMN fx_rate TYPE numeric(21,6), ALTER COLUMN on_account TYPE numeric(21,6), ALTER COLUMN total TYPE numeric(21,6), ALTER COLUMN transfer TYPE numeric(21,6);
ALTER TABLE erp.payment_allocation ALTER COLUMN applied TYPE numeric(21,6), ALTER COLUMN applied_fc TYPE numeric(21,6);
ALTER TABLE erp.price_list ALTER COLUMN factor TYPE numeric(21,6);
ALTER TABLE erp.salesperson ALTER COLUMN commission_pct TYPE numeric(21,6);
ALTER TABLE erp.stock_balance ALTER COLUMN avg_cost TYPE numeric(21,6), ALTER COLUMN committed TYPE numeric(21,6), ALTER COLUMN max_stock TYPE numeric(21,6), ALTER COLUMN min_stock TYPE numeric(21,6), ALTER COLUMN on_hand TYPE numeric(21,6), ALTER COLUMN on_order TYPE numeric(21,6);
ALTER TABLE erp.stock_movement ALTER COLUMN price TYPE numeric(21,6), ALTER COLUMN qty_in TYPE numeric(21,6), ALTER COLUMN qty_out TYPE numeric(21,6);
ALTER TABLE erp.supplier_pi ALTER COLUMN pi_qty TYPE numeric(21,6), ALTER COLUMN qty TYPE numeric(21,6);
ALTER TABLE erp.tax_code ALTER COLUMN rate TYPE numeric(21,6);
ALTER TABLE erp.tpl_contract ALTER COLUMN min_handling_fee TYPE numeric(21,6), ALTER COLUMN min_storage_fee TYPE numeric(21,6), ALTER COLUMN storage_fee TYPE numeric(21,6);
CREATE VIEW erp.item_movement_list WITH (security_invoker=true) AS
 SELECT m.company_code,
    m.item_code,
    m.trans_seq,
    m.trans_type,
    m.doc_entry,
    m.doc_line,
    m.doc_date,
    m.whs_code,
    m.qty_in,
    m.qty_out,
    m.price,
    m.currency,
    COALESCE(w.doc_no, c.doc_no, d.doc_num::text, m.doc_entry::text) AS doc_no,
    d.doc_kind,
        CASE
            WHEN m.trans_seq >= 900000000 THEN 'erp'::text
            ELSE COALESCE(d.source, 'sap'::text)
        END AS source
   FROM erp.stock_movement m
     LEFT JOIN erp.document d ON d.company_code::text = m.company_code::text AND d.obj_type = m.trans_type AND d.doc_entry = m.doc_entry
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = m.company_code::text AND w.obj_type = m.trans_type AND w.doc_entry = m.doc_entry
     LEFT JOIN erp.inv_count c ON m.trans_type = 1470000065 AND c.company_code::text = m.company_code::text AND c.count_id = m.doc_entry;
GRANT SELECT ON erp.item_movement_list TO "authenticated";
CREATE VIEW erp.payment_list_fc WITH (security_invoker=true) AS
 SELECT p.company_code,
    p.direction,
    p.doc_entry,
    p.doc_num,
    COALESCE(x.doc_no, p.doc_num::text) AS doc_no,
    p.doc_type,
    p.doc_date,
    p.card_code,
    p.card_name,
    p.currency,
    p.total,
    p.cash,
    p.transfer,
    p.cheque,
    p.card,
    p.on_account,
    p.cancelled,
    p.trans_id,
    p.memo,
    p.source,
    c.currency AS local_currency,
        CASE
            WHEN p.currency IS NOT NULL AND p.currency::bpchar <> c.currency THEN p.fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN p.currency IS NOT NULL AND p.currency::bpchar <> c.currency THEN p.total_fc
            ELSE NULL::numeric
        END AS total_fc,
    p.fx_diff
   FROM erp.payment p
     LEFT JOIN erp.company c ON c.company_code::text = p.company_code::text
     LEFT JOIN erp.payment_extra x ON x.company_code::text = p.company_code::text AND x.direction = p.direction AND x.doc_entry = p.doc_entry;
GRANT SELECT ON erp.payment_list_fc TO "authenticated";
CREATE VIEW erp.sales_order_list WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.obj_type,
    d.doc_entry,
    d.doc_num,
    COALESCE(w.doc_no, d.doc_num::text) AS doc_no,
    d.doc_kind,
    d.status,
    w.state,
    d.doc_date,
    d.due_date,
    d.card_code,
    d.card_name,
    d.customer_ref,
    d.comments,
    d.currency,
    d.total,
    d.vat_total,
    d.source,
    d.created_on
   FROM erp.document d
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = d.company_code::text AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
  WHERE d.obj_type = 17;
GRANT SELECT ON erp.sales_order_list TO "authenticated";
CREATE VIEW erp.fx_rate_list WITH (security_invoker=true) AS
 SELECT f.company_code,
    f.rate_date,
    f.currency,
    f.rate,
    'sap'::text AS source,
    NULL::text AS entered_by_name,
    NULL::timestamp with time zone AS entered_at
   FROM erp.fx_rate f
UNION ALL
 SELECT e.company_code,
    e.rate_date,
    e.currency,
    e.rate,
    e.source,
    e.entered_by_name,
    e.entered_at
   FROM erp.fx_rate_entry e;
GRANT SELECT ON erp.fx_rate_list TO "authenticated";
CREATE VIEW erp.sales_doc_list WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.obj_type,
    d.doc_entry,
    d.doc_num,
    COALESCE(w.doc_no, d.doc_num::text) AS doc_no,
    d.doc_kind,
    d.status,
    w.state,
    d.doc_date,
    d.due_date,
    d.card_code,
    d.card_name,
    d.customer_ref,
    d.comments,
    d.currency,
    d.total,
    d.vat_total,
    d.paid,
    d.source,
    d.created_on
   FROM erp.document d
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = d.company_code::text AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
  WHERE d.obj_type = ANY (ARRAY[23, 17, 15, 13, 14]);
GRANT SELECT ON erp.sales_doc_list TO "authenticated";
CREATE VIEW erp.bp_balance_fc AS
 SELECT d.company_code,
    d.card_code,
    max(d.card_name) AS card_name,
    d.currency,
        CASE
            WHEN d.obj_type = ANY (ARRAY[13, 14]) THEN 'receivable'::text
            ELSE 'payable'::text
        END AS side,
    count(*) AS docs,
    round(sum(
        CASE
            WHEN d.obj_type = ANY (ARRAY[14, 19]) THEN '-1'::integer
            ELSE 1
        END::numeric * (COALESCE(d.total_fc, 0::numeric) - COALESCE(d.paid_fc, 0::numeric) - cm.fc)), 2) AS open_fc,
    round(sum(
        CASE
            WHEN d.obj_type = ANY (ARRAY[14, 19]) THEN '-1'::integer
            ELSE 1
        END::numeric * (COALESCE(d.total, 0::numeric) - COALESCE(d.paid, 0::numeric) - cm.lc)), 2) AS open_lc
   FROM erp.document d
     CROSS JOIN LATERAL ( SELECT COALESCE(sum(COALESCE(cl.line_total_fc, 0::numeric) + COALESCE(cl.vat_fc, 0::numeric)), 0::numeric) AS fc,
            COALESCE(sum(cl.line_total + COALESCE(cl.vat, 0::numeric)), 0::numeric) AS lc
           FROM erp.document_line cl
             JOIN erp.document c ON c.company_code::text = cl.company_code::text AND c.obj_type = cl.obj_type AND c.doc_entry = cl.doc_entry
          WHERE cl.company_code::text = d.company_code::text AND ((d.obj_type = ANY (ARRAY[13, 18])) AND cl.obj_type = (d.obj_type + 1) AND cl.base_obj_type = d.obj_type AND cl.base_doc_entry = d.doc_entry AND (c.status <> ALL (ARRAY['cancelled'::text, 'cancellation'::text])) OR (d.obj_type = ANY (ARRAY[14, 19])) AND cl.obj_type = d.obj_type AND cl.doc_entry = d.doc_entry AND cl.base_obj_type = (d.obj_type - 1))) cm
  WHERE d.source = 'erp'::text AND (d.obj_type = ANY (ARRAY[13, 14, 18, 19, 204])) AND (d.status <> ALL (ARRAY['cancelled'::text, 'cancellation'::text, 'draft'::text])) AND d.total_fc IS NOT NULL AND erp.can_see(d.company_code) AND (erp.can_read('finance'::text) OR erp.can_read('banking'::text) OR (d.obj_type = ANY (ARRAY[13, 14])) AND erp.can_read('sales'::text) OR (d.obj_type = ANY (ARRAY[18, 19, 204])) AND erp.can_read('purchase'::text))
  GROUP BY d.company_code, d.card_code, d.currency, (
        CASE
            WHEN d.obj_type = ANY (ARRAY[13, 14]) THEN 'receivable'::text
            ELSE 'payable'::text
        END);
GRANT SELECT ON erp.bp_balance_fc TO "authenticated";
CREATE VIEW erp.inventory_doc_list WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.obj_type,
    d.doc_entry,
    d.doc_num,
    COALESCE(w.doc_no, d.doc_num::text) AS doc_no,
    d.doc_kind,
    d.status,
    w.state,
    w.reason_code,
    COALESCE(d.from_whs, (( SELECT min(l.from_whs::text) AS min
           FROM erp.document_line l
          WHERE l.company_code::text = d.company_code::text AND l.obj_type = d.obj_type AND l.doc_entry = d.doc_entry))::character varying) AS from_whs,
    COALESCE(d.to_whs, w.whs_code) AS to_whs,
    d.doc_date,
    d.due_date,
    d.card_code,
    d.card_name,
    d.customer_ref,
    d.comments,
    d.currency,
    d.total,
    d.vat_total,
    d.paid,
    d.source,
    d.created_on
   FROM erp.document d
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = d.company_code::text AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
  WHERE d.obj_type = ANY (ARRAY[1250000001, 67, 59, 60]);
GRANT SELECT ON erp.inventory_doc_list TO "authenticated";
CREATE VIEW erp.stock_balance_parts WITH (security_invoker=true) AS
 SELECT company_code,
    item_code,
    whs_code,
    on_hand,
    COALESCE(sap_on_hand, on_hand - erp_on_hand) AS sap_on_hand,
    erp_on_hand,
    committed,
    erp_committed,
    on_order,
    erp_on_order
   FROM erp.stock_balance;
GRANT SELECT ON erp.stock_balance_parts TO "authenticated";
CREATE VIEW erp.purchase_doc_list_fc WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.obj_type,
    d.doc_entry,
    d.doc_num,
    COALESCE(w.doc_no, d.doc_num::text) AS doc_no,
    d.doc_kind,
    d.status,
    w.state,
    w.china_office,
    d.doc_date,
    d.due_date,
    d.card_code,
    d.card_name,
    d.customer_ref,
    d.comments,
    d.currency,
    d.total,
    d.vat_total,
    d.paid,
    d.container_no,
    d.source,
    d.created_on,
    c.currency AS local_currency,
        CASE
            WHEN d.currency IS NOT NULL AND d.currency::bpchar <> c.currency THEN d.fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN d.currency IS NOT NULL AND d.currency::bpchar <> c.currency THEN d.total_fc
            ELSE NULL::numeric
        END AS total_fc,
        CASE
            WHEN d.currency IS NOT NULL AND d.currency::bpchar <> c.currency THEN d.paid_fc
            ELSE NULL::numeric
        END AS paid_fc
   FROM erp.document d
     LEFT JOIN erp.company c ON c.company_code::text = d.company_code::text
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = d.company_code::text AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
  WHERE d.obj_type = ANY (ARRAY[1470000113, 540000006, 22, 20, 21, 204, 18, 19]);
GRANT SELECT ON erp.purchase_doc_list_fc TO "authenticated";
CREATE VIEW erp.sales_doc_list_fc WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.obj_type,
    d.doc_entry,
    d.doc_num,
    COALESCE(w.doc_no, d.doc_num::text) AS doc_no,
    d.doc_kind,
    d.status,
    w.state,
    d.doc_date,
    d.due_date,
    d.card_code,
    d.card_name,
    d.customer_ref,
    d.comments,
    d.currency,
    d.total,
    d.vat_total,
    d.paid,
    d.source,
    d.created_on,
    c.currency AS local_currency,
        CASE
            WHEN d.currency IS NOT NULL AND d.currency::bpchar <> c.currency THEN d.fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN d.currency IS NOT NULL AND d.currency::bpchar <> c.currency THEN d.total_fc
            ELSE NULL::numeric
        END AS total_fc,
        CASE
            WHEN d.currency IS NOT NULL AND d.currency::bpchar <> c.currency THEN d.paid_fc
            ELSE NULL::numeric
        END AS paid_fc
   FROM erp.document d
     LEFT JOIN erp.company c ON c.company_code::text = d.company_code::text
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = d.company_code::text AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
  WHERE d.obj_type = ANY (ARRAY[23, 17, 15, 13, 14]);
GRANT SELECT ON erp.sales_doc_list_fc TO "authenticated";
CREATE VIEW erp.purchase_doc_list WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.obj_type,
    d.doc_entry,
    d.doc_num,
    COALESCE(w.doc_no, d.doc_num::text) AS doc_no,
    d.doc_kind,
    d.status,
    w.state,
    w.china_office,
    d.doc_date,
    d.due_date,
    d.card_code,
    d.card_name,
    d.customer_ref,
    d.comments,
    d.currency,
    d.total,
    d.vat_total,
    d.paid,
    d.container_no,
    d.source,
    d.created_on
   FROM erp.document d
     LEFT JOIN erp.doc_workflow w ON w.company_code::text = d.company_code::text AND w.obj_type = d.obj_type AND w.doc_entry = d.doc_entry
  WHERE d.obj_type = ANY (ARRAY[1470000113, 540000006, 22, 20, 21, 204, 18, 19]);
GRANT SELECT ON erp.purchase_doc_list TO "authenticated";
CREATE VIEW erp.payment_list WITH (security_invoker=true) AS
 SELECT p.company_code,
    p.direction,
    p.doc_entry,
    p.doc_num,
    COALESCE(x.doc_no, p.doc_num::text) AS doc_no,
    p.doc_type,
    p.doc_date,
    p.card_code,
    p.card_name,
    p.currency,
    p.total,
    p.cash,
    p.transfer,
    p.cheque,
    p.card,
    p.on_account,
    p.cancelled,
    p.trans_id,
    p.memo,
    p.source
   FROM erp.payment p
     LEFT JOIN erp.payment_extra x ON x.company_code::text = p.company_code::text AND x.direction = p.direction AND x.doc_entry = p.doc_entry;
GRANT SELECT ON erp.payment_list TO "authenticated";
CREATE POLICY air_ticket_accrual_hr_or_self ON erp.air_ticket_accrual AS PERMISSIVE FOR SELECT TO authenticated
  USING ((erp.can_see(company_code) AND (erp.has_module('hr'::text) OR ((hr_code)::text = (erp.my_hr_code(company_code))::text))));
COMMIT;
