-- A9 · HR and Staff Portal tests. LOCAL STACK ONLY (sample company ZZ99 + scripts/local-stack/test-users.sql).
-- Run on a FRESH rebuild (base.txt incl. 24_hr.sql). Everything happens inside one transaction that is rolled back.
-- Prints one row per check: PASS/FAIL · name · detail, then a TOTAL row.
BEGIN;

CREATE TEMP TABLE a9_result (n serial, ok boolean, name text, detail text);
GRANT ALL ON a9_result TO authenticated;

CREATE FUNCTION pg_temp.call(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', p_role)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN coalesce(v, 'null'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
END $$;
CREATE FUNCTION pg_temp.check(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  INSERT INTO a9_result (ok, name, detail) VALUES (coalesce(p_ok, false), p_name, p_detail)
$$;
CREATE FUNCTION pg_temp.expect(p_res jsonb, p_msg text, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'message' = p_msg, p_name, coalesce(p_res->>'error', 'no error') || ': ' || coalesce(p_res->>'message', left(p_res::text, 300)))
$$;
CREATE FUNCTION pg_temp.ok(p_res jsonb, p_name text) RETURNS void LANGUAGE sql AS $$
  SELECT pg_temp.check(p_res->>'error' IS NULL, p_name, left(p_res::text, 300))
$$;
CREATE FUNCTION pg_temp.n(p_user uuid, p_sql text) RETURNS integer LANGUAGE sql AS $$
  SELECT (pg_temp.call(p_user, 'SELECT to_jsonb(count(*)) FROM (' || p_sql || ') x') #>> '{}')::integer
$$;
CREATE FUNCTION pg_temp.err(p_res jsonb, p_field text) RETURNS text LANGUAGE sql AS $$
  SELECT e->>'message' FROM jsonb_array_elements(coalesce(p_res->'errors', '[]'::jsonb)) e WHERE e->>'field' IS NOT DISTINCT FROM p_field LIMIT 1
$$;
CREATE FUNCTION pg_temp.leave(p_user uuid, p_leave jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.leave_submit(%L, %L::jsonb)', 'ZZ99', p_leave))
$$;
CREATE FUNCTION pg_temp.lchk(p_user uuid, p_leave jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.leave_checks(%L, %L::jsonb)', 'ZZ99', p_leave))
$$;
CREATE FUNCTION pg_temp.decide(p_user uuid, p_req integer, p_dec text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.leave_decide(%L, %s, %L, %L)', 'ZZ99', p_req, p_dec, p_note))
$$;
CREATE FUNCTION pg_temp.inp(p_user uuid, p_input jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.call(p_user, format('SELECT erp.payroll_input_save(%L, %L::jsonb)', 'ZZ99', p_input))
$$;

DO $$
DECLARE
  admin  uuid := '00000000-0000-4000-8000-000000000001';
  sales  uuid := '00000000-0000-4000-8000-000000000002';
  nobody uuid := '00000000-0000-4000-8000-000000000003';
  fin    uuid := '00000000-0000-4000-8000-000000000004';
  owner  uuid := '00000000-0000-4000-8000-000000000005';
  hr     uuid := '00000000-0000-4000-8000-000000000018';
  hrread uuid := '00000000-0000-4000-8000-000000000019';
  emp    uuid := '00000000-0000-4000-8000-000000000020';
  lead   uuid := '00000000-0000-4000-8000-000000000021';
  emp2   uuid := '00000000-0000-4000-8000-000000000022';
  r jsonb; r2 jsonb; v_n integer; v_new integer; v_a integer; v_b integer; q1 integer; q2 integer; q3 integer; q4 integer;
  v_run integer; v_run2 integer; v_txt text; v_line text; v_trans integer; v_audit integer;
  extra_ok jsonb := '{"iban":"AE100330000001000079190","bank_routing":"403520101","mol_person_id":"10000000000077","wps_bank":"SMPBANK","site_code":"DWC"}';
BEGIN
  -- ---------- Access ----------
  r := pg_temp.call(nobody, $q$SELECT erp.hr_setup('ZZ99')$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'user without a profile refused', r::text);
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_setup('AE01')$q$), 'You don''t have access to company AE01.', 'other company refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.hr_setup('ZZ99')$q$),
    'Your position does not include Human Resources. Ask the system admin if you need it.', 'sales user can''t open HR setup');
  PERFORM pg_temp.expect(pg_temp.call(hrread, $q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"A","last_name":"B","joined_on":"2026-01-01"}')$q$),
    'You have read-only access to Human Resources. Ask the system admin for full access.', 'HR read-only can''t create an employee');
  PERFORM pg_temp.expect(pg_temp.call(hrread, $q$SELECT erp.payroll_calculate('ZZ99', '2026-10')$q$),
    'Salary and payroll are for HR positions with full access only.', 'HR read-only can''t run payroll');
  PERFORM pg_temp.expect(pg_temp.call(hrread, $q$SELECT erp.hr_pay_set('ZZ99', 1, 'BASIC', 1, '2027-01-01')$q$),
    'Salary and payroll are for HR positions with full access only.', 'HR read-only can''t change pay');

  -- ---------- Who sees employees ----------
  SELECT count(*) INTO v_n FROM erp.employee WHERE company_code = 'ZZ99';
  PERFORM pg_temp.check(pg_temp.n(emp, 'SELECT 1 FROM erp.employee') = 1, 'an employee sees only their own record', pg_temp.n(emp, 'SELECT 1 FROM erp.employee')::text);
  PERFORM pg_temp.check(pg_temp.n(emp, 'SELECT 1 FROM erp.employee WHERE emp_id = 6') = 1, '… and it is their own (E0006)');
  PERFORM pg_temp.check(pg_temp.n(hrread, 'SELECT 1 FROM erp.employee') = v_n, 'HR read-only sees all employees (module_level)', pg_temp.n(hrread, 'SELECT 1 FROM erp.employee')::text);
  PERFORM pg_temp.check(pg_temp.n(hr, 'SELECT 1 FROM erp.employee') = v_n, 'HR full sees all employees');
  PERFORM pg_temp.check(pg_temp.n(owner, 'SELECT 1 FROM erp.employee') = 0, 'owner without HR still sees 0 employees (A1 unchanged)');
  PERFORM pg_temp.check(pg_temp.n(sales, 'SELECT 1 FROM erp.employee') = 0, 'sales user sees 0 employees');
  PERFORM pg_temp.check(pg_temp.n(lead, 'SELECT 1 FROM erp.employee') = 1, 'a manager sees only their own employee record');

  -- ---------- Salary privacy ----------
  r := pg_temp.call(hr, 'SELECT to_jsonb(count(*)) FROM erp.employee_pay');
  PERFORM pg_temp.check((r #>> '{}')::int = 0 OR r->>'error' IS NOT NULL, 'migrated salary table closed to direct reads (even HR)', r::text);
  r := pg_temp.call(hr, 'SELECT to_jsonb(count(*)) FROM erp.hr_pay');
  PERFORM pg_temp.check(r->>'error' = '42501', 'hr_pay has no direct read grant', r::text);
  r := pg_temp.call(hr, 'SELECT to_jsonb(count(*)) FROM erp.hr_payroll_line');
  PERFORM pg_temp.check(r->>'error' = '42501', 'payroll lines have no direct read grant', r::text);
  r := pg_temp.call(hr, 'SELECT to_jsonb(count(*)) FROM erp.hr_employee_extra');
  PERFORM pg_temp.check(r->>'error' = '42501', 'bank / WPS details have no direct read grant', r::text);
  SELECT count(*) INTO v_audit FROM erp.audit_log WHERE action = 'salary_view';
  r := pg_temp.call(hrread, $q$SELECT erp.hr_employee_info('ZZ99', 1)$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND NOT (r ? 'pay') AND NOT (r ? 'bank') AND NOT (r ? 'gratuity') AND (r->>'salary_visible')::boolean = false,
                        'HR read-only gets the profile without any salary field', left(r::text, 200));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE action = 'salary_view') = v_audit, 'no salary view logged for HR read-only');
  r := pg_temp.call(hr, $q$SELECT erp.hr_employee_info('ZZ99', 1)$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'pay') = 3 AND r->'bank'->>'iban' = 'AE410330000001000007919', 'HR full sees pay and bank details', left(r::text, 200));
  PERFORM pg_temp.check((SELECT count(*) FROM erp.audit_log WHERE action = 'salary_view' AND object_ref = '1' AND actor = hr::text) = 1,
                        'every view of a salary is audited (salary_view)');
  r := pg_temp.call(emp, $q$SELECT erp.hr_employee_info('ZZ99', 6)$q$);
  PERFORM pg_temp.check(jsonb_array_length(r->'pay') = 3, 'an employee sees their own pay', left(r::text, 200));
  PERFORM pg_temp.expect(pg_temp.call(emp, $q$SELECT erp.hr_employee_info('ZZ99', 1)$q$),
    'Your position does not include Human Resources. Ask the system admin if you need it.', 'an employee can''t open another employee');
  PERFORM pg_temp.check(pg_temp.n(sales, 'SELECT 1 FROM erp.hr_doc_expiry') = 0, 'sales user sees no document expiry rows');

  -- ---------- Employee master ----------
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"Nadia","joined_on":"2026-10-16"}')$q$),
    'Enter the last name.', 'last name required');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"Nadia","last_name":"Aziz","joined_on":"2026-10-16","gov_id":"123"}')$q$),
    'The Emirates ID must be 15 digits starting with 784.', 'Emirates ID format checked');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"Nadia","last_name":"Aziz","joined_on":"2026-10-16","left_on":"2026-01-01"}')$q$),
    'The leaving date can''t be before the joining date.', 'leaving before joining refused');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"Nadia","last_name":"Aziz","joined_on":"2026-10-16","manager_emp_id":4242}')$q$),
    'The manager (employee 4242) was not found in company ZZ99.', 'unknown manager refused');
  r := pg_temp.call(hr, format($q$SELECT erp.hr_employee_save('ZZ99', %L::jsonb)$q$,
         jsonb_build_object('first_name', 'Nadia', 'last_name', 'Aziz', 'joined_on', '2026-10-16', 'division', 'Warehouse', 'manager_emp_id', 7,
                            'gov_id', '784-1990-1234567-1', 'email', 'nadia@sample.test', 'extra', extra_ok)));
  v_new := (r->>'emp_id')::integer;
  PERFORM pg_temp.check(r->>'hr_code' = 'EMP-0001' AND v_new >= 900000, 'HR creates an employee (EMP-0001, Super ERP id range)', r::text);
  PERFORM pg_temp.check((SELECT source FROM erp.employee WHERE company_code = 'ZZ99' AND emp_id = v_new) = 'erp'
                        AND (SELECT iban FROM erp.hr_employee_extra WHERE company_code = 'ZZ99' AND emp_id = v_new) = 'AE100330000001000079190',
                        'new employee is source erp with HR details');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_save('ZZ99', '{"emp_id":1,"job_title":"Changed"}')$q$),
    'This employee comes from SAP. Change it in SAP until ZZ99 goes live on Super ERP. HR details (shift, site, WPS, tickets) can still be changed here.',
    'sample/SAP employee master is read-only');
  PERFORM pg_temp.check((SELECT job_title FROM erp.employee WHERE company_code = 'ZZ99' AND emp_id = 1) = 'Accountant', 'sample employee unchanged');
  r := pg_temp.call(hr, $q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"Tariq","last_name":"Noor","joined_on":"2025-01-01"}')$q$);
  v_a := (r->>'emp_id')::integer;
  r := pg_temp.call(hr, format($q$SELECT erp.hr_employee_save('ZZ99', '{"first_name":"Hana","last_name":"Faris","joined_on":"2025-01-01","manager_emp_id":%s}')$q$, v_a));
  v_b := (r->>'emp_id')::integer;
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.hr_employee_save('ZZ99', '{"emp_id":%s,"manager_emp_id":%s}')$q$, v_a, v_b)),
    'An employee can''t report to themself or to someone who reports to them.', 'reporting loop refused');
  r := pg_temp.call(hr, format($q$SELECT erp.hr_employee_save('ZZ99', '{"emp_id":%s,"job_title":"Driver","mobile":"+971 50 111 2222"}')$q$, v_a));
  PERFORM pg_temp.check(r->>'error' IS NULL AND (SELECT job_title FROM erp.employee WHERE company_code = 'ZZ99' AND emp_id = v_a) = 'Driver',
                        'HR edits a Super ERP employee', r::text);
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_extra_save('ZZ99', 10, '{"iban":"AE100330000001000079191"}')$q$),
    'The IBAN AE100330000001000079191 is not valid. Check the letters and digits.', 'IBAN check digits verified');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_employee_extra_save('ZZ99', 10, '{"bank_routing":"1234"}')$q$),
    'The bank routing code must be 9 digits.', 'routing code length from settings');
  PERFORM pg_temp.ok(pg_temp.call(hr, $q$SELECT erp.hr_employee_extra_save('ZZ99', 10, '{"home_city":"Sample city","shift_code":"DAY"}')$q$),
    'HR details can be set on a sample (SAP) employee');

  -- ---------- Pay ----------
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.hr_pay_set('ZZ99', %s, 'OT', 100, '2026-10-16')$q$, v_new)),
    'Only fixed earnings (basic, allowances) are set per employee. Overtime is entered per payroll month.', 'overtime is not a fixed pay element');
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.hr_pay_set('ZZ99', %s, 'BASIC', -1, '2026-10-16')$q$, v_new)),
    'Enter an amount of 0 or more.', 'negative pay refused');
  PERFORM pg_temp.ok(pg_temp.call(hr, format($q$SELECT erp.hr_pay_set('ZZ99', %s, 'BASIC', 6000, '2026-10-16', 'Offer letter')$q$, v_new)), 'HR sets basic pay');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'salary_change' AND object_ref = v_new::text AND (detail->>'to')::numeric = 6000),
                        'pay change audited (salary_change)');

  -- ---------- Documents and expiry alerts ----------
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.hr_document_save('ZZ99', '{"emp_id":%s,"doc_type":"visa","doc_no":"V1"}')$q$, v_new)),
    'Enter the expiry date. Expiry alerts depend on it.', 'visa needs an expiry date');
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.hr_document_save('ZZ99', '{"emp_id":%s,"doc_type":"visa","expires_on":"2028-01-01","storage_path":"ZZ99/1/visa.pdf"}')$q$, v_new)),
    format('The file must be stored under ZZ99/%s/ in the hr-docs bucket.', v_new), 'file path must be under the employee''s folder');
  r := pg_temp.call(hr, format($q$SELECT erp.hr_document_save('ZZ99', '{"emp_id":%s,"doc_type":"passport","doc_no":"P123","issued_on":"2024-01-01","expires_on":"%s","storage_path":"ZZ99/%s/passport.pdf","file_name":"passport.pdf"}')$q$,
                               v_new, current_date + 20, v_new));
  PERFORM pg_temp.ok(r, 'HR adds a passport with a file');
  PERFORM pg_temp.expect(pg_temp.call(hrread, format($q$SELECT erp.hr_document_save('ZZ99', '{"emp_id":%s,"doc_type":"other"}')$q$, v_new)),
    'You have read-only access to Human Resources. Ask the system admin for full access.', 'HR read-only can''t add documents');
  PERFORM pg_temp.check(pg_temp.n(hr, $q$SELECT 1 FROM erp.hr_doc_expiry WHERE company_code = 'ZZ99'$q$) = 5, 'expiry alerts list 5 documents within 60 days',
                        pg_temp.n(hr, $q$SELECT 1 FROM erp.hr_doc_expiry WHERE company_code = 'ZZ99'$q$)::text);
  r := pg_temp.call(hr, $q$SELECT jsonb_object_agg(emp_id, band) FROM erp.hr_doc_expiry WHERE company_code = 'ZZ99' AND source = 'erp' AND emp_id < 100$q$);
  PERFORM pg_temp.check(r->>'2' = 'd60' AND r->>'6' = 'd30' AND r->>'4' = 'd7' AND r->>'9' = 'expired' AND NOT r ? '1', 'alert bands 60 / 30 / 7 / expired', r::text);
  PERFORM pg_temp.check(pg_temp.n(emp, 'SELECT 1 FROM erp.hr_doc_expiry') = 1, 'an employee sees only their own expiring documents');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'hr_docs_select')
                        AND (SELECT public FROM storage.buckets WHERE id = 'hr-docs') = false, 'private hr-docs bucket with read policy');

  -- ---------- Attendance ----------
  r := pg_temp.call(emp, $q$SELECT erp.attendance_check('ZZ99', 'in', 24.8962, 55.1612, 12)$q$);
  PERFORM pg_temp.check(r->>'error' IS NULL AND NOT (r->'flags' ? 'outside_site') AND (r->>'distance_m')::int < 300 AND r->>'site_code' = 'DWC',
                        'check-in inside the site area is not flagged', r::text);
  r := pg_temp.call(emp, $q$SELECT erp.attendance_check('ZZ99', 'in', 24.8962, 55.1612, 12)$q$);
  PERFORM pg_temp.check(r->>'message' LIKE 'You already checked in today at %', 'second check-in refused', r::text);
  PERFORM pg_temp.ok(pg_temp.call(emp, $q$SELECT erp.attendance_check('ZZ99', 'out', 24.8962, 55.1612, 12)$q$), 'check-out');
  PERFORM pg_temp.check(pg_temp.call(emp, $q$SELECT erp.attendance_check('ZZ99', 'out', 24.8962, 55.1612, 12)$q$)->>'message' LIKE 'You already checked out today at %',
                        'second check-out refused');
  UPDATE erp.hr_shift SET start_time = '00:00', grace_min = 0 WHERE company_code = 'ZZ99' AND shift_code = 'WH';
  r := pg_temp.call(lead, $q$SELECT erp.attendance_check('ZZ99', 'in', 25.0500, 55.3000, 20)$q$);
  PERFORM pg_temp.check(r->'flags' ? 'outside_site' AND r->>'message' LIKE '%Outside the site area%rule "Check-in outside site area"%',
                        'check-in outside the area is flagged with the rule name', r::text);
  PERFORM pg_temp.check(r->'flags' ? 'late' OR to_char(now() AT TIME ZONE 'Asia/Dubai', 'HH24:MI') = '00:00', 'check-in after shift start is flagged late', r::text);
  r := pg_temp.call(emp2, $q$SELECT erp.attendance_check('ZZ99', 'in')$q$);
  PERFORM pg_temp.check(r->'flags' ? 'no_location', 'check-in without location is flagged', r::text);
  PERFORM pg_temp.expect(pg_temp.call(emp2, $q$SELECT erp.attendance_check('ZZ99', 'out', 95, 10)$q$),
    'The location sent by the phone is not valid. Try again.', 'invalid coordinates refused');
  PERFORM pg_temp.expect(pg_temp.call(sales, $q$SELECT erp.attendance_check('ZZ99', 'in', 24.9, 55.2)$q$),
    'Your sign-in is not linked to an employee record in ZZ99. Ask HR to link it.', 'unlinked sign-in can''t check in');
  PERFORM pg_temp.check(pg_temp.n(hrread, $q$SELECT 1 FROM erp.attendance_list WHERE company_code = 'ZZ99'$q$) = 3, 'HR sees today''s 3 check-ins');
  PERFORM pg_temp.check(pg_temp.n(hrread, $q$SELECT 1 FROM erp.attendance_list WHERE outside_site$q$) = 1, 'HR filters the outside-site check-ins');
  PERFORM pg_temp.check(pg_temp.n(emp, 'SELECT 1 FROM erp.attendance_list') = 1, 'an employee sees only their own attendance');
  r := pg_temp.call(emp, $q$WITH x AS (INSERT INTO erp.hr_attendance (company_code, emp_id, work_date, check_in_at) VALUES ('ZZ99', 6, '2020-01-01', now()) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct attendance writes', r::text);

  -- ---------- Leave: checks ----------
  r := pg_temp.lchk(emp, '{}');
  PERFORM pg_temp.check(pg_temp.err(r, 'leave_code') = 'Choose a leave type.' AND pg_temp.err(r, 'from_date') = 'Choose the first day of leave.', 'leave type and dates required', r::text);
  r := pg_temp.lchk(emp, '{"leave_code":"AL","from_date":"2026-11-20","to_date":"2026-11-18"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'to_date') = 'The last day can''t be before the first day.', 'last day before first refused', r::text);
  r := pg_temp.lchk(emp, '{"leave_code":"AL","from_date":"2026-11-21","to_date":"2026-11-22"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'to_date') = 'These dates fall on weekends or public holidays only. There is nothing to request.', 'weekend-only request refused', r::text);
  r := pg_temp.lchk(emp, '{"leave_code":"AL","from_date":"2026-12-01","to_date":"2026-12-04"}');
  PERFORM pg_temp.check((r->>'days')::numeric = 2, 'working days skip the National Day holidays (4 dates → 2 days)', r::text);
  r := pg_temp.lchk(emp, '{"leave_code":"AL","from_date":"2026-02-02","to_date":"2026-03-31"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'to_date') LIKE 'Not enough annual leave: 2.5 days left, this request needs 42 days.', 'balance checked (1 month accrued = 2.5 days)', r::text);
  r := pg_temp.lchk(emp, '{"leave_code":"UL","from_date":"2026-06-01","to_date":"2026-07-15"}');
  PERFORM pg_temp.check(pg_temp.err(r, 'to_date') = 'A single Unpaid leave request can be at most 30 days. This one is 45 days.', 'leave type maximum checked', r::text);
  r := pg_temp.call(hr, format($q$SELECT erp.leave_checks('ZZ99', '{"emp_id":%s,"leave_code":"SL","from_date":"2026-10-01","to_date":"2026-10-02"}')$q$, v_new));
  PERFORM pg_temp.check(pg_temp.err(r, 'from_date') = 'Leave can''t start before the joining date (16 Oct 2026).', 'no leave before joining', r::text);
  PERFORM pg_temp.expect(pg_temp.lchk(emp, format('{"emp_id":%s,"leave_code":"AL","from_date":"2026-11-16","to_date":"2026-11-16"}', 1)::jsonb),
    'Only HR with full access can request leave for another employee.', 'staff can''t request for someone else');
  r := pg_temp.lchk(emp, '{"leave_code":"AL","from_date":"2026-11-16","to_date":"2026-11-19"}');
  PERFORM pg_temp.check((r->>'days')::numeric = 4 AND (r->'balance'->>'available')::numeric = 25 AND jsonb_array_length(r->'steps') = 2
                        AND r->'steps'->0->>'rule_code' = 'leave_manager' AND r->'steps'->0->>'approver_name' = 'Ravi Menon',
                        'balance 25 days (10 months × 2.5), steps manager then HR', r::text);

  -- ---------- Leave: submit and approve ----------
  r := pg_temp.leave(emp, '{"leave_code":"AL","from_date":"2026-11-16","to_date":"2026-11-19","reason":"Family visit"}');
  q1 := (r->>'request_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'pending_approval', 'employee submits annual leave', r::text);
  PERFORM pg_temp.expect(pg_temp.leave(emp, '{"leave_code":"SL","from_date":"2026-11-18","to_date":"2026-11-18"}'),
    'You already have leave from 16 Nov 2026 to 19 Nov 2026 that overlaps these dates.', 'overlapping leave refused');
  r := pg_temp.leave(emp2, '{"leave_code":"SL","from_date":"2026-11-23","to_date":"2026-11-24","reason":"Clinic"}');
  q2 := (r->>'request_id')::integer;
  PERFORM pg_temp.check(jsonb_array_length(r->'steps') = 1 AND r->'steps'->0->>'rule_code' = 'leave_hr',
                        'manager without a sign-in: straight to HR', r::text);
  -- who sees which leave
  PERFORM pg_temp.check(pg_temp.n(lead, 'SELECT 1 FROM erp.leave_request_list') = 1 AND pg_temp.n(lead, format('SELECT 1 FROM erp.leave_request_list WHERE request_id = %s', q1)) = 1,
                        'a manager sees their team''s leave only (list)');
  PERFORM pg_temp.check(pg_temp.n(lead, 'SELECT 1 FROM erp.leave_request') = 1, 'a manager sees their team''s leave only (table)');
  PERFORM pg_temp.check(pg_temp.n(emp, 'SELECT 1 FROM erp.leave_request_list') = 1 AND pg_temp.n(emp2, 'SELECT 1 FROM erp.leave_request_list') = 1,
                        'staff see only their own leave');
  PERFORM pg_temp.check(pg_temp.n(hrread, 'SELECT 1 FROM erp.leave_request_list') = 2, 'HR sees all leave');
  PERFORM pg_temp.check(pg_temp.n(sales, 'SELECT 1 FROM erp.leave_request_list') = 0, 'other users see no leave');
  PERFORM pg_temp.expect(pg_temp.call(sales, format($q$SELECT erp.leave_info('ZZ99', %s)$q$, q1)), format('Leave request %s was not found in company ZZ99.', q1),
                         'other users can''t open a leave request');
  -- inbox
  r := pg_temp.call(lead, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') x WHERE x->>'kind' = 'leave' AND (x->>'doc_entry')::int = q1)
                        AND (r->>'is_approver')::boolean, 'manager has the leave in Waiting for me', left(r::text, 300));
  r := pg_temp.call(hr, 'SELECT erp.approval_inbox()');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') x WHERE (x->>'doc_entry')::int = q1)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'waiting') x WHERE x->>'kind' = 'leave' AND (x->>'doc_entry')::int = q2),
                        'HR waits until the manager decides; sees the direct one', left(r::text, 300));
  PERFORM pg_temp.expect(pg_temp.decide(hr, q1, 'approved'), 'This leave request is waiting for approval from Ravi Menon. You can''t decide it.', 'HR can''t skip the manager');
  PERFORM pg_temp.expect(pg_temp.decide(emp, q1, 'approved'), 'You can''t decide your own leave request.', 'employee can''t approve own leave');
  PERFORM pg_temp.expect(pg_temp.decide(emp2, q1, 'approved'), 'This leave request is waiting for approval from Ravi Menon. You can''t decide it.', 'another staff member can''t decide');
  PERFORM pg_temp.expect(pg_temp.decide(lead, q1, 'rejected'), 'Add a note saying why you are rejecting this leave request.', 'rejection needs a note');
  r := pg_temp.decide(lead, q1, 'approved', 'Covered by Joseph');
  PERFORM pg_temp.check(r->>'state' = 'pending_approval' AND (r->>'open_steps')::int = 1, 'manager approves → waits for HR', r::text);
  r := pg_temp.decide(hr, q1, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'approved', 'HR approves → approved', r::text);
  r := pg_temp.call(emp, format($q$SELECT erp.leave_info('ZZ99', %s)$q$, q1));
  PERFORM pg_temp.check((r->'balance'->>'taken')::numeric = 4 AND (r->'balance'->>'available')::numeric = 21, 'balance after approval: 25 − 4 = 21', r->>'balance');
  -- long leave → owner
  r := pg_temp.leave(emp2, '{"leave_code":"AL","from_date":"2026-12-07","to_date":"2026-12-28"}');
  q3 := (r->>'request_id')::integer;
  PERFORM pg_temp.check((r->>'days')::numeric = 16 AND jsonb_array_length(r->'steps') = 2 AND r->'steps'->1->>'rule_code' = 'leave_long',
                        'leave above 14 days also needs the owner', r::text);
  PERFORM pg_temp.check(pg_temp.decide(hr, q3, 'approved')->>'state' = 'pending_approval', 'HR approves long leave → waits for owner');
  r := pg_temp.decide(owner, q3, 'approved');
  PERFORM pg_temp.check(r->>'state' = 'approved', 'owner approves long leave', r::text);
  -- reject and cancel
  r := pg_temp.leave(emp, '{"leave_code":"SL","from_date":"2026-12-14","to_date":"2026-12-14"}');
  q4 := (r->>'request_id')::integer;
  PERFORM pg_temp.check(pg_temp.decide(lead, q4, 'rejected', 'Stock count that day')->>'state' = 'rejected', 'manager rejects with a note');
  PERFORM pg_temp.expect(pg_temp.call(emp, format($q$SELECT erp.leave_cancel('ZZ99', %s)$q$, q2)), 'Only the employee or HR with full access can cancel this leave.',
                         'staff can''t cancel someone else''s leave');
  PERFORM pg_temp.expect(pg_temp.call(sales, format($q$SELECT erp.leave_cancel('ZZ99', %s)$q$, q2)), 'Only the employee or HR with full access can cancel this leave.',
                         'a sign-in without an employee record can''t cancel leave');
  PERFORM pg_temp.check(pg_temp.call(emp2, format($q$SELECT erp.leave_cancel('ZZ99', %s, 'Feeling better')$q$, q2))->>'state' = 'cancelled', 'employee cancels waiting leave');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.approval WHERE object = 'leave' AND object_ref = q2::text AND decision IS NULL AND NOT superseded),
                        'cancelled leave leaves nothing waiting');
  r := pg_temp.call(emp, $q$WITH x AS (INSERT INTO erp.leave_request (company_code, emp_id, leave_code, from_date, to_date, days, requested_by) VALUES ('ZZ99', 6, 'AL', '2027-01-04', '2027-01-04', 1, gen_random_uuid()) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'no direct leave writes', r::text);

  -- ---------- Payroll ----------
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.payroll_calculate('ZZ99', '2026-13')$q$), 'Enter the payroll month as YYYY-MM, e.g. 2026-11.', 'period format checked');
  PERFORM pg_temp.expect(pg_temp.inp(hr, '{"period":"2026-10","emp_id":1,"kind":"overtime_hours","value":800}'), 'Overtime can''t be more than 744 hours in a month.', 'overtime hours capped');
  PERFORM pg_temp.expect(pg_temp.inp(hr, '{"period":"2026-10","emp_id":1,"kind":"deduction","wage_code":"BONUS","value":10}'),
    'One-off bonus is not a monthly deduction wage type.', 'deduction needs a deduction wage type');
  PERFORM pg_temp.ok(pg_temp.inp(hr, '{"period":"2026-10","emp_id":1,"kind":"overtime_hours","value":10,"note":"Stock count"}'), 'overtime input');
  PERFORM pg_temp.ok(pg_temp.inp(hr, '{"period":"2026-10","emp_id":1,"kind":"unpaid_days","value":2}'), 'unpaid days input');
  PERFORM pg_temp.ok(pg_temp.inp(hr, '{"period":"2026-10","emp_id":1,"kind":"deduction","wage_code":"ADVANCE","value":500}'), 'advance recovery input');
  r := pg_temp.call(hr, $q$SELECT erp.payroll_calculate('ZZ99', '2026-10')$q$);
  v_run := (r->>'run_id')::integer;
  PERFORM pg_temp.check(r->>'error' IS NULL AND (r->>'headcount')::int = 11 AND jsonb_array_length(r->'skipped') = 2 AND (r->>'errors')::int = 0,
                        'payroll 2026-10: 10 sample + 1 new joiner; 2 without pay skipped', r::text);
  SELECT jsonb_build_object('gross', gross, 'ded', deductions, 'net', net, 'fixed', fixed_income, 'var', variable_income) INTO r2
    FROM erp.hr_payroll_emp WHERE run_id = v_run AND emp_id = 1;
  -- E0001: 9,000 + 3,500 + 1,000 = 13,500; OT 10 h × 9,000/30/8 × 1.25 = 468.75; unpaid 2 × 13,500/30 = 900; advance 500
  PERFORM pg_temp.check((r2->>'gross')::numeric = 13968.75 AND (r2->>'ded')::numeric = 1400 AND (r2->>'net')::numeric = 12568.75
                        AND (r2->>'var')::numeric = 468.75 AND (r2->>'fixed')::numeric = 12100, 'payroll maths: E0001 net 12,568.75', r2::text);
  PERFORM pg_temp.check((SELECT amount FROM erp.hr_payroll_line WHERE run_id = v_run AND emp_id = v_new AND wage_code = 'BASIC') = 3200.00
                        AND (SELECT days_paid FROM erp.hr_payroll_emp WHERE run_id = v_run AND emp_id = v_new) = 16,
                        'payroll maths: joiner on 16 Oct paid 16/30 of 6,000 = 3,200');
  PERFORM pg_temp.check((SELECT net FROM erp.hr_payroll_emp WHERE run_id = v_run AND emp_id = 6) = 4700, 'payroll maths: E0006 full month 4,700');
  PERFORM pg_temp.check((SELECT net FROM erp.hr_payroll_run WHERE run_id = v_run) = (SELECT sum(net) FROM erp.hr_payroll_emp WHERE run_id = v_run), 'run total = sum of employees');
  PERFORM pg_temp.ok(pg_temp.inp(hr, '{"period":"2026-10","emp_id":2,"kind":"earning","wage_code":"BONUS","value":1000}'), 'bonus input after calculation');
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.payroll_step('ZZ99', %s, 'review')$q$, v_run)),
    'Inputs changed after the last calculation. Calculate payroll 2026-10 again before review.', 'review refused while inputs changed');
  r := pg_temp.call(hr, $q$SELECT erp.payroll_calculate('ZZ99', '2026-10')$q$);
  PERFORM pg_temp.check((SELECT gross FROM erp.hr_payroll_emp WHERE run_id = v_run AND emp_id = 2) = 21500, 'recalculated with the bonus (20,500 + 1,000)');
  PERFORM pg_temp.check(pg_temp.call(hr, format($q$SELECT erp.payroll_step('ZZ99', %s, 'review')$q$, v_run))->>'state' = 'reviewed', 'payroll reviewed');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.payroll_calculate('ZZ99', '2026-10')$q$), 'Payroll 2026-10 is reviewed. Reopen it before calculating again.',
                         'reviewed payroll can''t be recalculated');
  PERFORM pg_temp.check(pg_temp.call(hr, format($q$SELECT erp.payroll_step('ZZ99', %s, 'reopen')$q$, v_run))->>'state' = 'draft', 'payroll reopened');
  PERFORM pg_temp.check(pg_temp.call(hr, format($q$SELECT erp.payroll_step('ZZ99', %s, 'review')$q$, v_run))->>'state' = 'reviewed', 'reviewed again');
  -- WPS before lock
  r := pg_temp.call(hr, format($q$SELECT erp.wps_check('ZZ99', %s, 'SMPBANK')$q$, v_run));
  PERFORM pg_temp.check(r->'errors'->0->>'message' = 'Lock payroll 2026-10 before making the WPS file.', 'WPS needs a locked payroll', r::text);
  PERFORM pg_temp.expect(pg_temp.call(emp, format($q$SELECT erp.portal_payslip('ZZ99', %s)$q$, v_run)), 'This payslip is not available.', 'no payslip before lock');
  PERFORM pg_temp.check(pg_temp.call(hr, format($q$SELECT erp.payroll_step('ZZ99', %s, 'lock')$q$, v_run))->>'state' = 'locked', 'payroll locked');
  PERFORM pg_temp.expect(pg_temp.inp(hr, '{"period":"2026-10","emp_id":1,"kind":"overtime_hours","value":1}'), 'Payroll 2026-10 is locked. Its inputs can''t change.', 'locked payroll inputs frozen');
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.payroll_step('ZZ99', %s, 'reopen')$q$, v_run)),
    'Only a reviewed payroll can be reopened. Locked payroll can''t be reopened.', 'locked payroll can''t be reopened');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_pay_set('ZZ99', 1, 'BASIC', 9500, '2026-10-20')$q$),
    'Payroll is locked up to 31 Oct 2026. A pay change must start after that.', 'pay change inside a locked month refused');
  -- payslips
  r := pg_temp.call(emp, format($q$SELECT erp.portal_payslip('ZZ99', %s)$q$, v_run));
  PERFORM pg_temp.check((r->'employee'->>'net')::numeric = 4700 AND jsonb_array_length(r->'lines') = 3, 'employee opens own payslip', left(r::text, 200));
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'salary_view' AND object = 'payslip' AND actor = emp::text), 'payslip view audited');
  PERFORM pg_temp.expect(pg_temp.call(emp, format($q$SELECT erp.portal_payslip('ZZ99', %s, 1)$q$, v_run)), 'Salary and payroll are for HR positions with full access only.',
                         'employee can''t open someone else''s payslip');
  PERFORM pg_temp.expect(pg_temp.call(sales, format($q$SELECT erp.portal_payslip('ZZ99', %s, 6)$q$, v_run)), 'Salary and payroll are for HR positions with full access only.',
                         'a sign-in without an employee record can''t open payslips');
  PERFORM pg_temp.check((pg_temp.call(hr, format($q$SELECT erp.portal_payslip('ZZ99', %s, 6)$q$, v_run))->'employee'->>'net')::numeric = 4700, 'HR full opens any payslip');
  r := pg_temp.call(emp, $q$SELECT erp.portal_me('ZZ99')$q$);
  PERFORM pg_temp.check((r->>'linked')::boolean AND jsonb_array_length(r->'payslips') = 1 AND r->'shift'->>'shift_code' = 'WH' AND jsonb_array_length(r->'duties') = 3
                        AND r->'attendance_today'->>'check_out_at' IS NOT NULL, 'Staff Portal: payslip, shift, duties, today''s attendance', left(r::text, 300));
  PERFORM pg_temp.check((pg_temp.call(lead, $q$SELECT erp.portal_me('ZZ99')$q$)->>'is_manager')::boolean, 'portal knows the team lead is a manager');
  PERFORM pg_temp.check((pg_temp.call(sales, $q$SELECT erp.portal_me('ZZ99')$q$)->>'linked')::boolean = false, 'unlinked sign-in gets linked=false');
  -- WPS file
  r := pg_temp.call(hr, format($q$SELECT erp.wps_check('ZZ99', %s, 'SMPBANK')$q$, v_run));
  PERFORM pg_temp.check(jsonb_array_length(r->'errors') = 0 AND (r->>'count')::int = 11, 'WPS check passes for 11 employees', r::text);
  r := pg_temp.call(hr, format($q$SELECT erp.wps_file('ZZ99', %s, 'SMPBANK')$q$, v_run));
  v_txt := r->>'content';
  PERFORM pg_temp.check(r->>'file_name' ~ '^1000000000099[0-9]{12}\.SIF$', 'SIF file name: employer ID + YYMMDDHHMMSS', r->>'file_name');
  PERFORM pg_temp.check((SELECT bool_and(l ~ '^EDR,[0-9]{14},[0-9]{9},AE[0-9]{21},2026-10-01,2026-10-31,[0-9]+(\.[0-9]+)?,[0-9]+\.[0-9]{2},[0-9]+\.[0-9]{2},[0-9]+(\.[0-9]+)?$')
                           FROM unnest(string_to_array(rtrim(v_txt, E'\r\n'), E'\r\n')) l WHERE l LIKE 'EDR%')
                        AND (SELECT count(*) FROM unnest(string_to_array(rtrim(v_txt, E'\r\n'), E'\r\n')) l WHERE l LIKE 'EDR%') = 11,
                        'WPS EDR rows pass format validation', left(v_txt, 200));
  v_line := (SELECT l FROM unnest(string_to_array(rtrim(v_txt, E'\r\n'), E'\r\n')) l WHERE l LIKE 'SCR%');
  PERFORM pg_temp.check(v_line ~ '^SCR,1000000000099,403520101,[0-9]{4}-[0-9]{2}-[0-9]{2},[0-9]{4},102026,11,[0-9]+\.[0-9]{2},AED,ZZ99-SAMPLE$'
                        AND split_part(v_line, ',', 8)::numeric = (SELECT sum(net) FROM erp.hr_payroll_emp WHERE run_id = v_run),
                        'WPS SCR row: count, total = payroll net, currency', v_line);
  PERFORM pg_temp.check((SELECT count(*) FROM unnest(string_to_array(rtrim(v_txt, E'\r\n'), E'\r\n')) l) = 12 AND v_txt LIKE '%' || E'\r\n', 'SIF: 11 EDR + 1 SCR, CRLF lines');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'wps_export' AND object_ref = v_run::text), 'WPS export audited');
  UPDATE erp.hr_employee_extra SET mol_person_id = '123456789012' WHERE company_code = 'ZZ99' AND emp_id = 10;   -- simulate a bad migrated value
  r := pg_temp.call(hr, format($q$SELECT erp.wps_check('ZZ99', %s, 'SMPBANK')$q$, v_run));
  PERFORM pg_temp.check(r->'errors'->0->>'message' = 'E0010 Mariam Saleh: the MOHRE personal number must be 14 digits.', 'WPS check names the bad employee', r::text);
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.wps_file('ZZ99', %s, 'SMPBANK')$q$, v_run)),
    'E0010 Mariam Saleh: the MOHRE personal number must be 14 digits.', 'WPS file refused until valid');
  UPDATE erp.hr_employee_extra SET iban = 'AE100330000001000079191', mol_person_id = '10000000000010' WHERE company_code = 'ZZ99' AND emp_id = 10;
  r := pg_temp.call(hr, format($q$SELECT erp.wps_check('ZZ99', %s, 'SMPBANK')$q$, v_run));
  PERFORM pg_temp.check(r->'errors'->0->>'message' = 'E0010 Mariam Saleh: the IBAN is missing or not a valid UAE IBAN.', 'WPS check catches a bad IBAN', r::text);
  UPDATE erp.hr_employee_extra SET iban = 'AE100330000001000079190' WHERE company_code = 'ZZ99' AND emp_id = 10;
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.wps_file('ZZ99', %s, 'NOBANK')$q$, v_run)), 'WPS bank NOBANK is not set up for ZZ99.', 'unknown WPS bank refused');
  -- posting through A3
  PERFORM pg_temp.expect(pg_temp.call(hrread, format($q$SELECT erp.payroll_post('ZZ99', %s)$q$, v_run)), 'Salary and payroll are for HR positions with full access only.',
                         'HR read-only can''t post payroll');
  r := pg_temp.call(hr, format($q$SELECT erp.payroll_post('ZZ99', %s)$q$, v_run));
  v_trans := (r->>'trans_id')::integer;
  PERFORM pg_temp.check(r->>'state' = 'posted' AND v_trans >= 900000000, 'payroll posted through post_journal', r::text);
  PERFORM pg_temp.check((SELECT sum(debit) = sum(credit) FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = v_trans)
                        AND (SELECT credit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = v_trans AND acct_code = '2300') = (SELECT net FROM erp.hr_payroll_run WHERE run_id = v_run)
                        AND (SELECT credit FROM erp.journal_line WHERE company_code = 'ZZ99' AND trans_id = v_trans AND acct_code = '1250') = 500,
                        'payroll journal: Dr salaries, Cr advances 500, Cr payable = net, balanced');
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.payroll_post('ZZ99', %s)$q$, v_run)), format('Payroll 2026-10 is already posted (journal %s).', v_trans), 'no double posting');
  r := pg_temp.call(hr, $q$SELECT erp.payroll_calculate('ZZ99', '2026-09')$q$);
  v_run2 := (r->>'run_id')::integer;
  PERFORM pg_temp.expect(pg_temp.call(hr, format($q$SELECT erp.payroll_post('ZZ99', %s)$q$, v_run2)), 'Lock payroll 2026-09 before posting it.', 'draft payroll can''t be posted');
  PERFORM pg_temp.check(pg_temp.n(hrread, 'SELECT 1 FROM erp.payroll_run_list') = 0 AND pg_temp.n(hr, 'SELECT 1 FROM erp.payroll_run_list') = 2,
                        'payroll run list: HR full only');

  -- ---------- Gratuity and air ticket (calculated, not posted) ----------
  r := erp._hr_gratuity('ZZ99', 1, DATE '2018-07-09' + 1094);
  PERFORM pg_temp.check((r->>'amount')::numeric = 18900 AND (r->>'years')::numeric = 3 AND (r->>'posted')::boolean = false,
                        'gratuity 3 years: 21 days × 3 × 300 = 18,900', r::text);
  r := erp._hr_gratuity('ZZ99', 1, DATE '2018-07-09' + 2554);
  PERFORM pg_temp.check((r->>'amount')::numeric = 49500, 'gratuity 7 years: (21 × 5 + 30 × 2) × 300 = 49,500', r::text);
  r := erp._hr_gratuity('ZZ99', 1, DATE '2018-07-09' + 199);
  PERFORM pg_temp.check((r->>'amount')::numeric = 0, 'no gratuity under the minimum service', r::text);
  r := erp._hr_ticket('ZZ99', 3, DATE '2021-03-25');
  PERFORM pg_temp.check((r->>'amount')::numeric = 1800 AND (r->>'months')::int = 24, 'air ticket accrual: 24 of 24 months = 1,800', r::text);
  r := pg_temp.call(hr, $q$SELECT erp.hr_employee_info('ZZ99', 3)$q$);
  PERFORM pg_temp.check((r->'gratuity'->>'set')::boolean AND (r->'ticket'->>'set')::boolean, 'employee page shows gratuity and ticket to HR full', left(r::text, 100));
  UPDATE erp.hr_setting SET gratuity_days_first = NULL WHERE company_code = 'ZZ99';
  PERFORM pg_temp.check(erp._hr_gratuity('ZZ99', 1, current_date)->>'message' = 'The gratuity policy is not set for ZZ99. Ask HR to set it in HR setup.', 'gratuity policy missing → message');
  UPDATE erp.hr_setting SET gratuity_days_first = 21 WHERE company_code = 'ZZ99';
  r := pg_temp.call(hr, $q$SELECT to_jsonb(erp._hr_gratuity('ZZ99', 1, current_date))$q$);
  PERFORM pg_temp.check(r->>'error' = '42501', 'gratuity helper is internal', r::text);

  -- ---------- Setup ----------
  PERFORM pg_temp.expect(pg_temp.call(hrread, $q$SELECT erp.hr_setup_save('ZZ99', 'site', '{}')$q$),
    'You have read-only access to Human Resources. Ask the system admin for full access.', 'HR read-only can''t change setup');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'site', '{"site_code":"X","name":"X","lat":25,"lng":55,"radius_m":5}')$q$),
    'The site radius must be between 10 and 100,000 metres.', 'site radius checked');
  PERFORM pg_temp.ok(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'site', '{"site_code":"jafza","name":"Sample yard","lat":25.0,"lng":55.06,"radius_m":500}')$q$), 'HR adds a site');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'setting', '{"payable_acct":"2100"}')$q$),
    'Only Finance with full access can change the salaries payable account.', 'payable account needs Finance');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'setting', '{"month_days_basis":"31"}')$q$),
    'One of the HR settings is out of range. Check the bases (30 or calendar, basic or gross) and that numbers are above 0.', 'setting values checked');
  PERFORM pg_temp.ok(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'setting', '{"long_leave_days":20,"weekend":[5,6]}')$q$), 'HR changes leave settings');
  PERFORM pg_temp.check((SELECT weekend FROM erp.hr_setting WHERE company_code = 'ZZ99') = '{5,6}', 'weekend saved');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'policy', '{"leave_code":"AL","accrual":"weekly"}')$q$),
    'Choose how the leave builds up: monthly, yearly or not tracked.', 'leave policy accrual checked');
  PERFORM pg_temp.expect(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'leave_adjust', '{"emp_id":6,"leave_code":"AL","days":5}')$q$),
    'Add a note saying why the balance changes (e.g. carried forward from last year).', 'balance adjustment needs a note');
  PERFORM pg_temp.ok(pg_temp.call(hr, $q$SELECT erp.hr_setup_save('ZZ99', 'leave_adjust', '{"emp_id":6,"leave_code":"AL","days":5,"leave_year":2026,"note":"Carried forward"}')$q$), 'balance adjustment');
  PERFORM pg_temp.check((erp._hr_leave_balance('ZZ99', 6, 'AL', '2026-11-16')->>'available')::numeric = 26, 'adjustment counts: 25 + 5 − 4 = 26');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM erp.audit_log WHERE action = 'hr_setup_site' AND object_ref = 'JAFZA'), 'setup changes audited');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM erp.hr_setting s JOIN erp.company c USING (company_code) WHERE c.company_code <> 'ZZ99'),
                        'no HR settings invented for real companies');
END $$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM a9_result ORDER BY n;
SELECT 'TOTAL' AS result, count(*) FILTER (WHERE ok) || ' passed, ' || count(*) FILTER (WHERE NOT ok) || ' failed' AS name, '' AS detail FROM a9_result;
ROLLBACK;
