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
