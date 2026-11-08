-- Test users for the access tests (run as the database owner after 12/13 and the first sync).
INSERT INTO erp.position (position_code, name, module_access) VALUES
  ('FIN', 'Finance controller', '{finance}'), ('HRA', 'HR admin', '{hr}'), ('MER', 'Merchandiser', '{field}'),
  ('ADM', 'System admin', '{admin,it}'), ('BUS', 'Business owner', '{business}'), ('ITM', 'IT manager', '{it}'), ('SAL', 'Salesman', '{sales,field}')
ON CONFLICT DO NOTHING;
INSERT INTO erp.app_user (user_id, company_code, emp_id, display_name, position_code) VALUES
  ('00000000-0000-0000-0000-000000000001', 'AE01', NULL, 'Fatima Finance', 'FIN'),
  ('00000000-0000-0000-0000-000000000002', 'AE01', NULL, 'Hana HR', 'HRA'),
  ('00000000-0000-0000-0000-000000000003', 'AE01', 7, 'Driver Seven (merchandiser)', 'MER'),
  ('00000000-0000-0000-0000-000000000004', 'AE01', NULL, 'Adam Admin', 'ADM'),
  ('00000000-0000-0000-0000-000000000005', 'AE01', NULL, 'Bilal Business', 'BUS'),
  ('00000000-0000-0000-0000-000000000006', 'AE01', NULL, 'Ivan IT', 'ITM'),
  ('00000000-0000-0000-0000-000000000007', 'AE01', NULL, 'Amal Admin (AE01 only)', 'ADM')
ON CONFLICT DO NOTHING;
INSERT INTO erp.user_company (user_id, company_code)
SELECT u, c FROM unnest(ARRAY['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003',
                              '00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000006']::uuid[]) u,
              unnest(ARRAY['AE01', 'SA01']) c
UNION ALL SELECT '00000000-0000-0000-0000-000000000007', 'AE01'
ON CONFLICT DO NOTHING;
