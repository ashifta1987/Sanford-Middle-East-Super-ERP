-- LOCAL STACK ONLY. B1 (30_numbering_company.sql): the pilot company AE05 is visible to qa.it (IT, Administration read-only)
-- only, so the go-live checklist and the Companies screen show it. Real AE05 users come later. Never run on Supabase.
INSERT INTO erp.user_company (user_id, company_code)
SELECT '00000000-0000-4000-8000-000000000023', 'AE05'
 WHERE EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'AE05')
   AND EXISTS (SELECT 1 FROM erp.app_user WHERE user_id = '00000000-0000-4000-8000-000000000023')
ON CONFLICT DO NOTHING;
