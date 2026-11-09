-- LOCAL STACK ONLY. Test positions and users for the sample company ZZ99. Never run on Supabase.
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_ALL', 'QA · all modules', '{admin,it,finance,sales,purchase,inventory,banking,production,service,hr,reports,business}'),
  ('QA_SALES', 'QA · sales only', '{sales}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000001', 'ZZ99', 'QA Admin', 'qa.admin@sample.test', 'QA_ALL', 'en', true),
  ('00000000-0000-4000-8000-000000000002', 'ZZ99', 'QA Sales', 'qa.sales@sample.test', 'QA_SALES', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES
  ('00000000-0000-4000-8000-000000000001', 'ZZ99'), ('00000000-0000-4000-8000-000000000002', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A1 · module-level access test positions and users (local stack only).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_FINANCE', 'QA · finance', '{finance}'),
  ('QA_OWNER', 'QA · owner (business)', '{business}'),
  ('QA_SALES_READ', 'QA · sales read-only', '{}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
DO $$ BEGIN
  IF to_regclass('erp.position_module') IS NOT NULL THEN
    INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_SALES_READ', 'sales', 'read')
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;
END $$;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000004', 'ZZ99', 'QA Finance', 'qa.finance@sample.test', 'QA_FINANCE', 'en', true),
  ('00000000-0000-4000-8000-000000000005', 'ZZ99', 'QA Owner', 'qa.owner@sample.test', 'QA_OWNER', 'en', true),
  ('00000000-0000-4000-8000-000000000006', 'ZZ99', 'QA Sales read-only', 'qa.salesread@sample.test', 'QA_SALES_READ', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES
  ('00000000-0000-4000-8000-000000000004', 'ZZ99'), ('00000000-0000-4000-8000-000000000005', 'ZZ99'),
  ('00000000-0000-4000-8000-000000000006', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A2 · sales manager (approver for discount and credit-limit rules on ZZ99; see 17_sales_order.sql sample rules).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_SALES_MGR', 'QA · sales manager', '{sales}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000007', 'ZZ99', 'QA Sales Manager', 'qa.salesmgr@sample.test', 'QA_SALES_MGR', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES ('00000000-0000-4000-8000-000000000007', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A3 · finance manager (approver for manual journals above the ZZ99 sample limit; see 18_posting.sql sample rule).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_FIN_MGR', 'QA · finance manager', '{finance}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000008', 'ZZ99', 'QA Finance Manager', 'qa.finmgr@sample.test', 'QA_FIN_MGR', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES ('00000000-0000-4000-8000-000000000008', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A5 · banking read-only (sees payments, deposits and statements; can't record or match anything).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_BANK_READ', 'QA · banking read-only', '{}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
DO $$ BEGIN
  IF to_regclass('erp.position_module') IS NOT NULL THEN
    INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_BANK_READ', 'banking', 'read')
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;
END $$;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000009', 'ZZ99', 'QA Banking read-only', 'qa.bankread@sample.test', 'QA_BANK_READ', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES ('00000000-0000-4000-8000-000000000009', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A6 · purchasing (full), purchasing manager (approver for the ZZ99 sample PO rules in 21_purchasing.sql), and a staff member with
-- read-only Purchasing access (raises purchase requests, nothing else).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_PURCHASE', 'QA · purchasing', '{purchase}'),
  ('QA_PURCH_MGR', 'QA · purchasing manager', '{purchase}'),
  ('QA_PURCH_READ', 'QA · staff (purchasing read-only)', '{}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
DO $$ BEGIN
  IF to_regclass('erp.position_module') IS NOT NULL THEN
    INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_PURCH_READ', 'purchase', 'read')
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;
END $$;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000010', 'ZZ99', 'QA Purchasing', 'qa.purchase@sample.test', 'QA_PURCHASE', 'en', true),
  ('00000000-0000-4000-8000-000000000011', 'ZZ99', 'QA Purchasing Manager', 'qa.purchmgr@sample.test', 'QA_PURCH_MGR', 'en', true),
  ('00000000-0000-4000-8000-000000000012', 'ZZ99', 'QA Staff', 'qa.staff@sample.test', 'QA_PURCH_READ', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES
  ('00000000-0000-4000-8000-000000000010', 'ZZ99'), ('00000000-0000-4000-8000-000000000011', 'ZZ99'),
  ('00000000-0000-4000-8000-000000000012', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A7 · inventory (full), stock manager (approver for the ZZ99 sample goods receipt / issue and count rules in 22_inventory.sql), and a
-- storekeeper with read-only Inventory access.
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_STOCK', 'QA · inventory', '{inventory}'),
  ('QA_STOCK_MGR', 'QA · stock manager', '{inventory}'),
  ('QA_STOCK_READ', 'QA · inventory read-only', '{}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
DO $$ BEGIN
  IF to_regclass('erp.position_module') IS NOT NULL THEN
    INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_STOCK_READ', 'inventory', 'read')
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;
END $$;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000013', 'ZZ99', 'QA Inventory', 'qa.stock@sample.test', 'QA_STOCK', 'en', true),
  ('00000000-0000-4000-8000-000000000014', 'ZZ99', 'QA Stock Manager', 'qa.stockmgr@sample.test', 'QA_STOCK_MGR', 'en', true),
  ('00000000-0000-4000-8000-000000000015', 'ZZ99', 'QA Inventory read-only', 'qa.stockread@sample.test', 'QA_STOCK_READ', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES
  ('00000000-0000-4000-8000-000000000013', 'ZZ99'), ('00000000-0000-4000-8000-000000000014', 'ZZ99'),
  ('00000000-0000-4000-8000-000000000015', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A8 · business partners clerk (full Business Partners access; bank detail changes need QA · finance manager on ZZ99, see
-- 23_master_data.sql sample rules) and a read-only Business Partners user.
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_BP', 'QA · business partners', '{bp}'),
  ('QA_BP_READ', 'QA · business partners read-only', '{}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
DO $$ BEGIN
  IF to_regclass('erp.position_module') IS NOT NULL THEN
    INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_BP_READ', 'bp', 'read')
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;
END $$;
INSERT INTO erp.app_user (user_id, company_code, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000016', 'ZZ99', 'QA Business Partners', 'qa.bp@sample.test', 'QA_BP', 'en', true),
  ('00000000-0000-4000-8000-000000000017', 'ZZ99', 'QA Business Partners read-only', 'qa.bpread@sample.test', 'QA_BP_READ', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES
  ('00000000-0000-4000-8000-000000000016', 'ZZ99'), ('00000000-0000-4000-8000-000000000017', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A9 · HR: HR officer with full access (linked to sample employee E0008), HR read-only, and three staff members with no module
-- access who use the Staff Portal: qa.emp (E0006, manager E0007), qa.teamlead (E0007, manages E0006 and E0009) and qa.emp2
-- (E0003, manager E0002 who has no sign-in). Leave approvals on ZZ99: manager → QA · HR → QA · owner above 14 days (24_hr.sql).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_HR', 'QA · HR officer', '{hr}'),
  ('QA_HR_READ', 'QA · HR read-only', '{}'),
  ('QA_STAFF', 'QA · staff (portal only)', '{}'),
  ('QA_TEAM_LEAD', 'QA · team lead (portal only)', '{}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
DO $$ BEGIN
  IF to_regclass('erp.position_module') IS NOT NULL THEN
    INSERT INTO erp.position_module (position_code, module, level) VALUES ('QA_HR_READ', 'hr', 'read')
    ON CONFLICT (position_code, module) DO UPDATE SET level = EXCLUDED.level;
  END IF;
END $$;
INSERT INTO erp.app_user (user_id, company_code, emp_id, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000018', 'ZZ99', 8, 'QA HR', 'qa.hr@sample.test', 'QA_HR', 'en', true),
  ('00000000-0000-4000-8000-000000000019', 'ZZ99', NULL, 'QA HR read-only', 'qa.hrread@sample.test', 'QA_HR_READ', 'en', true),
  ('00000000-0000-4000-8000-000000000020', 'ZZ99', 6, 'QA Staff (Faisal)', 'qa.emp@sample.test', 'QA_STAFF', 'en', true),
  ('00000000-0000-4000-8000-000000000021', 'ZZ99', 7, 'QA Team lead (Ravi)', 'qa.teamlead@sample.test', 'QA_TEAM_LEAD', 'en', true),
  ('00000000-0000-4000-8000-000000000022', 'ZZ99', 3, 'QA Staff (Priya)', 'qa.emp2@sample.test', 'QA_STAFF', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES
  ('00000000-0000-4000-8000-000000000018', 'ZZ99'), ('00000000-0000-4000-8000-000000000019', 'ZZ99'),
  ('00000000-0000-4000-8000-000000000020', 'ZZ99'), ('00000000-0000-4000-8000-000000000021', 'ZZ99'),
  ('00000000-0000-4000-8000-000000000022', 'ZZ99')
ON CONFLICT DO NOTHING;

-- A10 · IT (Administration screens read-only: IT can look, only Administration full can change).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('QA_IT', 'QA · IT support', '{it}')
ON CONFLICT (position_code) DO UPDATE SET module_access = EXCLUDED.module_access, name = EXCLUDED.name;
INSERT INTO erp.app_user (user_id, company_code, emp_id, display_name, email, position_code, language, active) VALUES
  ('00000000-0000-4000-8000-000000000023', 'ZZ99', NULL, 'QA IT support', 'qa.it@sample.test', 'QA_IT', 'en', true)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code) VALUES ('00000000-0000-4000-8000-000000000023', 'ZZ99')
ON CONFLICT DO NOTHING;
