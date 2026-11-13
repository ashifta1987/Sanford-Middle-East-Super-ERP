-- 39 · wide numerics (13 Nov 2026, AE05 load): every erp amount / quantity / price / total / FC total / cost / value column
-- narrower than numeric(19,6) becomes numeric(19,6), the precision SAP itself uses. document_line.discount_pct too: SAP
-- stores DiscPrcnt as numeric(19,6) and AE05 credit-note lines with quantity 0 carry values down to -1,333,415 %.
-- Kept as they are: coordinates, GPS accuracy, day counts, HR/master settings, other percentages and rates.
-- Widening never loses data; ALTER COLUMN TYPE rewrites the (nearly empty) tables.
BEGIN;
-- views that read these columns are dropped and recreated unchanged (same definition, options, grants, comments)
DROP VIEW erp.conv_diff_list;
DROP VIEW erp.deposit_list;
DROP VIEW erp.fx_revaluation_list;
DROP VIEW erp.payroll_run_list;
DROP VIEW erp.inv_count_list;
DROP VIEW erp.journal_draft_list;
DROP VIEW erp.landed_cost_list;
DROP VIEW erp.payment_draft_list;
DROP VIEW erp.prod_order_list;
ALTER TABLE erp.ap_dp_draw ALTER COLUMN amount TYPE numeric(19,6), ALTER COLUMN amount_fc TYPE numeric(19,6);
ALTER TABLE erp.approval_rule ALTER COLUMN limit_value TYPE numeric(19,6);
ALTER TABLE erp.apr_template_condition ALTER COLUMN value1 TYPE numeric(19,6), ALTER COLUMN value2 TYPE numeric(19,6);
ALTER TABLE erp.bank_match ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.bank_statement_line ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.control_setting ALTER COLUMN limit_value TYPE numeric(19,6);
ALTER TABLE erp.conv_diff_line ALTER COLUMN lc_balance TYPE numeric(19,6), ALTER COLUMN sc_balance TYPE numeric(19,6);
ALTER TABLE erp.conv_diff_run ALTER COLUMN debit TYPE numeric(19,6), ALTER COLUMN credit TYPE numeric(19,6);
ALTER TABLE erp.deposit ALTER COLUMN cheque_total TYPE numeric(19,6), ALTER COLUMN cash_amount TYPE numeric(19,6), ALTER COLUMN total TYPE numeric(19,6);
ALTER TABLE erp.document_line ALTER COLUMN discount_pct TYPE numeric(19,6);
ALTER TABLE erp.fx_revaluation ALTER COLUMN gain TYPE numeric(19,6), ALTER COLUMN loss TYPE numeric(19,6);
ALTER TABLE erp.fx_revaluation_line ALTER COLUMN open_fc TYPE numeric(19,6), ALTER COLUMN book_lc TYPE numeric(19,6), ALTER COLUMN new_lc TYPE numeric(19,6), ALTER COLUMN diff TYPE numeric(19,6), ALTER COLUMN gain TYPE numeric(19,6);
ALTER TABLE erp.hr_employee_extra ALTER COLUMN ticket_value TYPE numeric(19,6);
ALTER TABLE erp.hr_pay ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.hr_payroll_emp ALTER COLUMN gross TYPE numeric(19,6), ALTER COLUMN deductions TYPE numeric(19,6), ALTER COLUMN net TYPE numeric(19,6), ALTER COLUMN fixed_income TYPE numeric(19,6), ALTER COLUMN variable_income TYPE numeric(19,6);
ALTER TABLE erp.hr_payroll_input ALTER COLUMN value TYPE numeric(19,6);
ALTER TABLE erp.hr_payroll_line ALTER COLUMN qty TYPE numeric(19,6), ALTER COLUMN rate TYPE numeric(19,6), ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.hr_payroll_run ALTER COLUMN gross TYPE numeric(19,6), ALTER COLUMN deductions TYPE numeric(19,6), ALTER COLUMN net TYPE numeric(19,6);
ALTER TABLE erp.inv_count ALTER COLUMN gain_value TYPE numeric(19,6), ALTER COLUMN loss_value TYPE numeric(19,6);
ALTER TABLE erp.journal_draft ALTER COLUMN total TYPE numeric(19,6);
ALTER TABLE erp.journal_draft_line ALTER COLUMN debit TYPE numeric(19,6), ALTER COLUMN credit TYPE numeric(19,6);
ALTER TABLE erp.landed_cost ALTER COLUMN total TYPE numeric(19,6), ALTER COLUMN to_inventory TYPE numeric(19,6), ALTER COLUMN to_cogs TYPE numeric(19,6);
ALTER TABLE erp.landed_cost_alloc ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.landed_cost_charge ALTER COLUMN amount TYPE numeric(19,6), ALTER COLUMN amount_fc TYPE numeric(19,6), ALTER COLUMN clear_amount TYPE numeric(19,6), ALTER COLUMN fx_diff TYPE numeric(19,6);
ALTER TABLE erp.landed_cost_line ALTER COLUMN value TYPE numeric(19,6), ALTER COLUMN allocated TYPE numeric(19,6), ALTER COLUMN to_inventory TYPE numeric(19,6), ALTER COLUMN to_cogs TYPE numeric(19,6);
ALTER TABLE erp.payment_cheque ALTER COLUMN amount TYPE numeric(19,6), ALTER COLUMN amount_fc TYPE numeric(19,6);
ALTER TABLE erp.payment_draft ALTER COLUMN total TYPE numeric(19,6);
ALTER TABLE erp.position ALTER COLUMN approval_limit TYPE numeric(19,6);
ALTER TABLE erp.prod_order ALTER COLUMN issued_value TYPE numeric(19,6), ALTER COLUMN comp_received_value TYPE numeric(19,6), ALTER COLUMN resource_value TYPE numeric(19,6), ALTER COLUMN received_value TYPE numeric(19,6), ALTER COLUMN variance_value TYPE numeric(19,6);
ALTER TABLE erp.prod_order_line ALTER COLUMN issued_value TYPE numeric(19,6);
ALTER TABLE erp.prod_resource_use ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.purchase_pi ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.sales_doc_request ALTER COLUMN total TYPE numeric(19,6);
ALTER TABLE erp.trade_budget ALTER COLUMN amount TYPE numeric(19,6);
ALTER TABLE erp.trade_request ALTER COLUMN amount TYPE numeric(19,6);
CREATE VIEW erp.conv_diff_list WITH (security_invoker=true) AS
 SELECT run_id,
    company_code,
    COALESCE(doc_no, 'CVD-'::text || run_id) AS doc_no,
    run_date,
    accounts,
    partners,
    sys_currency,
    debit,
    credit,
    trans_id,
    cancel_trans_id,
    state,
    memo,
    created_at,
    ( SELECT app_user.display_name
           FROM erp.app_user
          WHERE app_user.user_id = r.created_by) AS created_by_name,
    ( SELECT count(*) AS count
           FROM erp.conv_diff_line l
          WHERE l.run_id = r.run_id) AS lines
   FROM erp.conv_diff_run r;
GRANT SELECT ON erp.conv_diff_list TO "authenticated";
CREATE VIEW erp.deposit_list WITH (security_invoker=true) AS
 SELECT d.company_code,
    d.deposit_id,
    d.doc_no,
    d.deposit_date,
    d.bank_code,
    b.name AS bank_name,
    d.cheques,
    d.cheque_total,
    d.cash_amount,
    d.total,
    d.memo,
    d.trans_id,
    d.created_at
   FROM erp.deposit d
     LEFT JOIN erp.bank_account b ON b.company_code::text = d.company_code::text AND b.bank_code = d.bank_code;
GRANT SELECT ON erp.deposit_list TO "authenticated";
CREATE VIEW erp.fx_revaluation_list WITH (security_invoker=true) AS
 SELECT reval_id,
    company_code,
    COALESCE(doc_no, 'FXR-'::text || reval_id) AS doc_no,
    reval_date,
    currencies,
    auto_reverse,
    reverse_date,
    trans_id,
    reverse_trans_id,
    gain,
    loss,
    gain - loss AS net,
    state,
    memo,
    created_at,
    ( SELECT app_user.display_name
           FROM erp.app_user
          WHERE app_user.user_id = r.created_by) AS created_by_name,
    ( SELECT count(*) AS count
           FROM erp.fx_revaluation_line l
          WHERE l.reval_id = r.reval_id) AS lines
   FROM erp.fx_revaluation r;
GRANT SELECT ON erp.fx_revaluation_list TO "authenticated";
CREATE VIEW erp.payroll_run_list AS
 SELECT r.run_id,
    r.company_code,
    r.period,
    r.from_date,
    r.to_date,
    r.state,
    r.stale,
    r.headcount,
    r.gross,
    r.deductions,
    r.net,
    c.currency,
    r.calculated_at,
    r.locked_at,
    r.posted_at,
    r.trans_id
   FROM erp.hr_payroll_run r
     JOIN erp.company c ON c.company_code::text = r.company_code::text
  WHERE erp.can_see(r.company_code) AND COALESCE(erp.can_write('hr'::text), false);
GRANT SELECT ON erp.payroll_run_list TO "authenticated";
CREATE VIEW erp.inv_count_list WITH (security_invoker=true) AS
 SELECT c.company_code,
    c.count_id,
    c.doc_no,
    c.whs_code,
    wh.name AS whs_name,
    c.item_group,
    g.name AS item_group_name,
    c.count_date,
    c.state,
    c.n_lines,
    c.n_counted,
    c.gain_value,
    c.loss_value,
    c.trans_id,
    c.comments,
    c.created_at,
    c.submitted_at,
    c.posted_at,
    u.display_name AS created_by_name
   FROM erp.inv_count c
     LEFT JOIN erp.warehouse wh ON wh.company_code::text = c.company_code::text AND wh.whs_code::text = c.whs_code::text
     LEFT JOIN erp.item_group g ON g.company_code::text = c.company_code::text AND g.group_code = c.item_group
     LEFT JOIN erp.app_user u ON u.user_id = c.created_by;
GRANT SELECT ON erp.inv_count_list TO "authenticated";
CREATE VIEW erp.journal_draft_list WITH (security_invoker=true) AS
 SELECT company_code,
    draft_id,
    ref_date,
    memo,
    ref1,
    state,
    total,
    currency,
    created_at,
    submitted_at,
    trans_id
   FROM erp.journal_draft;
GRANT SELECT ON erp.journal_draft_list TO "authenticated";
CREATE VIEW erp.landed_cost_list WITH (security_invoker=true) AS
 SELECT l.company_code,
    l.doc_entry,
    l.doc_no,
    l.doc_date,
    l.card_code,
    bp.name AS card_name,
    l.reference,
    l.total,
    l.to_inventory,
    l.to_cogs,
    l.currency,
    l.trans_id,
    l.created_at,
    ( SELECT string_agg(DISTINCT COALESCE(w.doc_no, ll.grpo_entry::text), ', '::text) AS string_agg
           FROM erp.landed_cost_line ll
             LEFT JOIN erp.doc_workflow w ON w.company_code::text = ll.company_code::text AND w.obj_type = 20 AND w.doc_entry = ll.grpo_entry
          WHERE ll.company_code::text = l.company_code::text AND ll.doc_entry = l.doc_entry) AS grpos
   FROM erp.landed_cost l
     LEFT JOIN erp.business_partner bp ON bp.company_code::text = l.company_code::text AND bp.card_code::text = l.card_code::text;
GRANT SELECT ON erp.landed_cost_list TO "authenticated";
CREATE VIEW erp.payment_draft_list WITH (security_invoker=true) AS
 SELECT company_code,
    draft_id,
    direction,
    doc_date,
    card_code,
    card_name,
    total,
    currency,
    state,
    reason,
    created_at,
    doc_entry
   FROM erp.payment_draft;
GRANT SELECT ON erp.payment_draft_list TO "authenticated";
CREATE VIEW erp.prod_order_list WITH (security_invoker=false) AS
 SELECT o.company_code,
    o.order_id,
    o.doc_no,
    o.item_code,
    i.name AS item_name,
    o.planned_qty,
    o.completed_qty,
    o.whs_code,
    o.post_date,
    o.due_date,
    o.state,
    (o.state = ANY (ARRAY['planned'::text, 'released'::text])) AND o.due_date < CURRENT_DATE AS late,
    o.issued_value,
    o.resource_value,
    o.received_value,
    o.variance_value,
    o.comments,
    o.created_at
   FROM erp.prod_order o
     LEFT JOIN erp.item i ON i.company_code::text = o.company_code::text AND i.item_code::text = o.item_code::text
  WHERE erp.can_see(o.company_code) AND (( SELECT erp.can_read('production'::text) AS can_read) OR ( SELECT erp.can_read('inventory'::text) AS can_read));
GRANT SELECT ON erp.prod_order_list TO "authenticated";
COMMIT;
