-- Access rules for the app layer (Supabase API). Principles:
--   * Data that comes from SAP is read-only to app users. Changes (orders, postings, approvals) go through
--     SECURITY DEFINER functions that check the user's position and limits - never direct table writes.
--   * A user sees only the companies listed for them in erp.user_company, and cannot change that list.
--   * Salary, payroll and ID documents: HR positions, or the employee's own record only.
--   * App-made records (shop visits, trade requests, delivery stops) are written by their owner.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA erp FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL ROUTINES IN SCHEMA erp FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA erp TO authenticated;

-- Helpers used by the policies (run with the owner's rights, read only).
CREATE OR REPLACE FUNCTION erp.has_module(p_module text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp AS $$
  SELECT EXISTS (SELECT 1 FROM erp.app_user u JOIN erp.position p USING (position_code)
                  WHERE u.user_id = erp.current_user_id() AND u.active AND p_module = ANY (p.module_access))
$$;
CREATE OR REPLACE FUNCTION erp.my_emp(p_company varchar) RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp AS $$
  SELECT u.emp_id FROM erp.app_user u WHERE u.user_id = erp.current_user_id() AND u.company_code = p_company AND u.active
$$;
CREATE OR REPLACE FUNCTION erp.my_hr_code(p_company varchar) RETURNS varchar LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp AS $$
  SELECT e.hr_code FROM erp.app_user u JOIN erp.employee e ON e.company_code = u.company_code AND e.emp_id = u.emp_id
   WHERE u.user_id = erp.current_user_id() AND u.company_code = p_company AND u.active
$$;
GRANT EXECUTE ON FUNCTION erp.current_user_id(), erp.can_see(varchar), erp.has_module(text), erp.my_emp(varchar), erp.my_hr_code(varchar) TO authenticated;

ALTER TABLE erp.company ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.branch ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.branch TO authenticated;
CREATE POLICY branch_read ON erp.branch FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.position ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.user_company ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.account ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.account TO authenticated;
CREATE POLICY account_read ON erp.account FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.cost_centre ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.cost_centre TO authenticated;
CREATE POLICY cost_centre_read ON erp.cost_centre FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.tax_code ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.tax_code TO authenticated;
CREATE POLICY tax_code_read ON erp.tax_code FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.fx_rate ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.fx_rate TO authenticated;
CREATE POLICY fx_rate_read ON erp.fx_rate FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.salesperson ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.salesperson TO authenticated;
CREATE POLICY salesperson_read ON erp.salesperson FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.payment_terms ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.payment_terms TO authenticated;
CREATE POLICY payment_terms_read ON erp.payment_terms FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.bp_group ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.bp_group TO authenticated;
CREATE POLICY bp_group_read ON erp.bp_group FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.business_partner ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.business_partner TO authenticated;
CREATE POLICY business_partner_read ON erp.business_partner FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.bp_address ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.bp_address TO authenticated;
CREATE POLICY bp_address_read ON erp.bp_address FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.bp_merchandiser ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.bp_merchandiser TO authenticated;
CREATE POLICY bp_merchandiser_read ON erp.bp_merchandiser FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.item_group ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.item_group TO authenticated;
CREATE POLICY item_group_read ON erp.item_group FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.brand ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.brand TO authenticated;
CREATE POLICY brand_read ON erp.brand FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.group_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.item ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.item TO authenticated;
CREATE POLICY item_read ON erp.item FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.item_certificate ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.item_certificate TO authenticated;
CREATE POLICY item_certificate_read ON erp.item_certificate FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.item_market_price ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.item_market_price TO authenticated;
CREATE POLICY item_market_price_read ON erp.item_market_price FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.item_tag ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.item_tag TO authenticated;
CREATE POLICY item_tag_read ON erp.item_tag FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.price_list ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.price_list TO authenticated;
CREATE POLICY price_list_read ON erp.price_list FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.item_price ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.item_price TO authenticated;
CREATE POLICY item_price_read ON erp.item_price FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.warehouse ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.warehouse TO authenticated;
CREATE POLICY warehouse_read ON erp.warehouse FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.stock_balance ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.stock_balance TO authenticated;
CREATE POLICY stock_balance_read ON erp.stock_balance FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.batch ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.batch TO authenticated;
CREATE POLICY batch_read ON erp.batch FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.stock_movement ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.stock_movement TO authenticated;
CREATE POLICY stock_movement_read ON erp.stock_movement FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.document ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.document TO authenticated;
CREATE POLICY document_read ON erp.document FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.document_line ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.document_line TO authenticated;
CREATE POLICY document_line_read ON erp.document_line FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.journal_entry ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.journal_entry TO authenticated;
CREATE POLICY journal_entry_read ON erp.journal_entry FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.journal_line ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.journal_line TO authenticated;
CREATE POLICY journal_line_read ON erp.journal_line FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.payment ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.payment TO authenticated;
CREATE POLICY payment_read ON erp.payment FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.payment_allocation ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.payment_allocation TO authenticated;
CREATE POLICY payment_allocation_read ON erp.payment_allocation FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.ic_account_map ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.ic_account_map TO authenticated;
CREATE POLICY ic_account_map_read ON erp.ic_account_map FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.ic_transaction ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.hr_org_unit ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.hr_org_unit TO authenticated;
CREATE POLICY hr_org_unit_read ON erp.hr_org_unit FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.employee ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.employee TO authenticated;
CREATE POLICY employee_hr_or_self ON erp.employee FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (erp.has_module('hr') OR emp_id = erp.my_emp(company_code)));
ALTER TABLE erp.employee_document ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.employee_document TO authenticated;
CREATE POLICY employee_document_hr_or_self ON erp.employee_document FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (erp.has_module('hr') OR hr_code = erp.my_hr_code(company_code)));
ALTER TABLE erp.wage_type ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.wage_type TO authenticated;
CREATE POLICY wage_type_read ON erp.wage_type FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.employee_pay ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.employee_pay TO authenticated;
CREATE POLICY employee_pay_hr_or_self ON erp.employee_pay FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (erp.has_module('hr') OR hr_code = erp.my_hr_code(company_code)));
ALTER TABLE erp.leave_type ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.leave_type TO authenticated;
CREATE POLICY leave_type_read ON erp.leave_type FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.payroll_result ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.payroll_result TO authenticated;
CREATE POLICY payroll_result_hr_or_self ON erp.payroll_result FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (erp.has_module('hr') OR hr_code = erp.my_hr_code(company_code)));
ALTER TABLE erp.air_ticket_accrual ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.air_ticket_accrual TO authenticated;
CREATE POLICY air_ticket_accrual_hr_or_self ON erp.air_ticket_accrual FOR SELECT TO authenticated USING (erp.can_see(company_code) AND (erp.has_module('hr') OR hr_code = erp.my_hr_code(company_code)));
ALTER TABLE erp.tpl_contract ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.tpl_contract TO authenticated;
CREATE POLICY tpl_contract_read ON erp.tpl_contract FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.artwork_request ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.artwork_request TO authenticated;
CREATE POLICY artwork_request_read ON erp.artwork_request FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.artwork_line ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.artwork_line TO authenticated;
CREATE POLICY artwork_line_read ON erp.artwork_line FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.supplier_pi ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.supplier_pi TO authenticated;
CREATE POLICY supplier_pi_read ON erp.supplier_pi FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.trademark ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.trademark TO authenticated;
CREATE POLICY trademark_read ON erp.trademark FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.shop_visit ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.shop_visit_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.trade_budget ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.trade_budget TO authenticated;
CREATE POLICY trade_budget_read ON erp.trade_budget FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.trade_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.vehicle ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.vehicle TO authenticated;
CREATE POLICY vehicle_read ON erp.vehicle FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.trip ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.trip_stop ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.approval ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON erp.approval TO authenticated;
CREATE POLICY approval_read ON erp.approval FOR SELECT TO authenticated USING (erp.can_see(company_code));
ALTER TABLE erp.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp.sync_log ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON erp.company, erp.position, erp.group_item, erp.app_user, erp.user_company, erp.ic_transaction, erp.audit_log TO authenticated;
CREATE POLICY company_read ON erp.company FOR SELECT TO authenticated USING (erp.can_see(company_code));
CREATE POLICY position_read ON erp.position FOR SELECT TO authenticated USING (true);
CREATE POLICY group_item_read ON erp.group_item FOR SELECT TO authenticated USING (true);
CREATE POLICY app_user_self ON erp.app_user FOR SELECT TO authenticated
  USING (user_id = erp.current_user_id() OR (erp.has_module('hr') AND erp.can_see(company_code)));
CREATE POLICY user_company_self ON erp.user_company FOR SELECT TO authenticated USING (user_id = erp.current_user_id());
CREATE POLICY ic_transaction_read ON erp.ic_transaction FOR SELECT TO authenticated USING (erp.can_see(seller_company) OR erp.can_see(buyer_company));
CREATE POLICY audit_log_admin ON erp.audit_log FOR SELECT TO authenticated USING (erp.has_module('admin') AND erp.can_see(company_code));
-- sync_log: no policy and no grant, service role only.

-- Field staff: own visits only, in their own company.
GRANT SELECT, INSERT, UPDATE ON erp.shop_visit, erp.shop_visit_item TO authenticated;
CREATE POLICY shop_visit_read ON erp.shop_visit FOR SELECT TO authenticated USING (erp.can_see(company_code));
CREATE POLICY shop_visit_own_insert ON erp.shop_visit FOR INSERT TO authenticated WITH CHECK (erp.can_see(company_code) AND emp_id = erp.my_emp(company_code));
CREATE POLICY shop_visit_own_update ON erp.shop_visit FOR UPDATE TO authenticated
  USING (emp_id = erp.my_emp(company_code) AND status = 'open') WITH CHECK (emp_id = erp.my_emp(company_code) AND status IN ('open', 'sent'));
CREATE POLICY shop_visit_item_read ON erp.shop_visit_item FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.shop_visit v WHERE v.visit_id = shop_visit_item.visit_id AND erp.can_see(v.company_code)));
CREATE POLICY shop_visit_item_own ON erp.shop_visit_item FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM erp.shop_visit v WHERE v.visit_id = shop_visit_item.visit_id AND v.status = 'open' AND v.emp_id = erp.my_emp(v.company_code)));
CREATE POLICY shop_visit_item_own_update ON erp.shop_visit_item FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.shop_visit v WHERE v.visit_id = shop_visit_item.visit_id AND v.status = 'open' AND v.emp_id = erp.my_emp(v.company_code)));

-- Trade spend: a salesman files a request in his name; approvals change status through a function.
GRANT SELECT, INSERT ON erp.trade_request TO authenticated;
CREATE POLICY trade_request_read ON erp.trade_request FOR SELECT TO authenticated USING (erp.can_see(company_code));
CREATE POLICY trade_request_own_insert ON erp.trade_request FOR INSERT TO authenticated
  WITH CHECK (erp.can_see(company_code) AND requested_by = erp.current_user_id() AND status IN ('draft', 'submitted') AND ap_doc_entry IS NULL);

-- Drivers: read trips of their company, update only the stops of their own trips.
GRANT SELECT ON erp.trip TO authenticated;
GRANT SELECT, UPDATE ON erp.trip_stop TO authenticated;
CREATE POLICY trip_read ON erp.trip FOR SELECT TO authenticated USING (erp.can_see(company_code));
CREATE POLICY trip_stop_read ON erp.trip_stop FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.trip x WHERE x.trip_id = trip_stop.trip_id AND erp.can_see(x.company_code)));
CREATE POLICY trip_stop_driver ON erp.trip_stop FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM erp.trip x WHERE x.trip_id = trip_stop.trip_id AND x.driver_emp_id = erp.my_emp(x.company_code)));

