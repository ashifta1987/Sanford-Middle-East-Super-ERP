-- A9 · Human Resources and Staff Portal. Safe to run twice. Does not edit 10–23.
-- Replaces (CREATE OR REPLACE): erp.approval_inbox (the 10 earlier branches + 'leave', and rows meant for one user only).
--
-- Access (decided here, see the A9 walkthrough):
--   * Employee master and ID documents: HR read or full (erp.module_level('hr') IS NOT NULL), or the employee's own record.
--     Not erp.can_read('hr'): that also admits owner/admin, and A1 keeps "owner without HR sees 0 employees".
--   * Salary (pay, payroll, payslips, bank / WPS details, gratuity, air tickets): HR FULL only, or the employee's own record,
--     and only through the functions below, which write audit_log action 'salary_view' on every read.
--     The migrated salary tables (employee_pay, payroll_result, air_ticket_accrual) are closed to direct API reads.
--   * Leave requests: the requester, their manager (employee.manager_emp_id), or HR read/full.
--   * Attendance: the employee, or HR read/full.
--
--   settings   hr_setting, hr_site, hr_shift, hr_duty, hr_holiday, hr_leave_policy, hr_leave_adjust, hr_wps_bank
--   data       hr_employee_extra, hr_pay, hr_document, leave_request, hr_attendance,
--              hr_payroll_run, hr_payroll_input, hr_payroll_emp, hr_payroll_line
--   storage    bucket hr-docs (private), object names <company>/<emp_id>/<file>
-- No business rule is invented: every limit, rate and code is a setting. Real companies start empty; ZZ99 gets SAMPLE values.

-- ============ Settings tables ============
CREATE TABLE IF NOT EXISTS erp.hr_setting (
    company_code   varchar(8) PRIMARY KEY REFERENCES erp.company ON DELETE CASCADE,
    timezone       text NOT NULL DEFAULT 'Asia/Dubai',
    weekend        smallint[] NOT NULL DEFAULT '{}',      -- ISO weekdays (1 = Monday … 7 = Sunday) that are not working days
    leave_year_start smallint NOT NULL DEFAULT 1 CHECK (leave_year_start BETWEEN 1 AND 12),
    long_leave_days numeric(9,2),                         -- leave longer than this also needs the owner position (NULL = never)
    hr_approver_position text REFERENCES erp.position ON DELETE SET NULL,
    owner_position text REFERENCES erp.position ON DELETE SET NULL,
    allow_negative_leave boolean NOT NULL DEFAULT false,
    month_days_basis text CHECK (month_days_basis IN ('30', 'calendar')),
    hours_per_day  numeric(5,2) CHECK (hours_per_day > 0),
    ot_multiplier  numeric(6,3) CHECK (ot_multiplier > 0),
    ot_rate_basis  text CHECK (ot_rate_basis IN ('basic', 'gross')),
    ot_wage_code   varchar(50),
    unpaid_wage_code varchar(50),
    unpaid_basis   text CHECK (unpaid_basis IN ('basic', 'gross')),
    payable_acct   varchar(15),
    gratuity_min_years numeric(6,2),
    gratuity_years_first numeric(6,2),
    gratuity_days_first numeric(6,2),
    gratuity_days_after numeric(6,2),
    gratuity_cap_years numeric(6,2),
    gratuity_day_basis text CHECK (gratuity_day_basis IN ('30', '365')),
    employer_mol_id text,
    wps_employer_id_len smallint,
    wps_person_id_len smallint,
    wps_routing_len smallint,
    expiry_alert_days integer[] NOT NULL DEFAULT '{60,30,7}',
    note           text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erp.hr_site (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    site_code      varchar(20) NOT NULL,
    name           text NOT NULL,
    lat            numeric(9,6) NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng            numeric(9,6) NOT NULL CHECK (lng BETWEEN -180 AND 180),
    radius_m       integer NOT NULL CHECK (radius_m BETWEEN 10 AND 100000),
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, site_code)
);

CREATE TABLE IF NOT EXISTS erp.hr_shift (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    shift_code     varchar(20) NOT NULL,
    name           text NOT NULL,
    start_time     time NOT NULL,
    end_time       time NOT NULL,
    grace_min      integer NOT NULL DEFAULT 0 CHECK (grace_min BETWEEN 0 AND 240),
    departments    text[] NOT NULL DEFAULT '{}',          -- default shift for these departments (employee.division)
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, shift_code)
);

CREATE TABLE IF NOT EXISTS erp.hr_duty (
    duty_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    department     text NOT NULL,
    title          text NOT NULL,
    detail         text,
    shift_code     varchar(20),
    sort           smallint NOT NULL DEFAULT 0,
    active         boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS hr_duty_dept_idx ON erp.hr_duty (company_code, department);

CREATE TABLE IF NOT EXISTS erp.hr_holiday (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    day            date NOT NULL,
    name           text NOT NULL,
    PRIMARY KEY (company_code, day)
);

CREATE TABLE IF NOT EXISTS erp.hr_leave_policy (
    company_code   varchar(8) NOT NULL,
    leave_code     varchar(50) NOT NULL,
    annual_days    numeric(9,2) CHECK (annual_days >= 0),
    accrual        text NOT NULL CHECK (accrual IN ('monthly', 'yearly', 'none')),
    basis          text NOT NULL DEFAULT 'working' CHECK (basis IN ('working', 'calendar')),
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, leave_code),
    FOREIGN KEY (company_code, leave_code) REFERENCES erp.leave_type ON DELETE CASCADE,
    CHECK (accrual = 'none' OR annual_days IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS erp.hr_leave_adjust (
    adjust_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    emp_id         integer NOT NULL,
    leave_code     varchar(50) NOT NULL,
    leave_year     integer NOT NULL,
    days           numeric(9,2) NOT NULL,
    note           text NOT NULL,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.hr_wps_bank (
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    bank_code      varchar(20) NOT NULL,
    name           text NOT NULL,
    employer_routing text,                                 -- the employer's bank routing (agent) code
    employer_ref   text,
    active         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (company_code, bank_code)
);

-- ============ Data tables ============
CREATE TABLE IF NOT EXISTS erp.hr_employee_extra (
    company_code   varchar(8) NOT NULL,
    emp_id         integer NOT NULL,
    shift_code     varchar(20),
    site_code      varchar(20),
    iban           text,
    bank_routing   text,                                  -- the employee's bank routing (agent) code for WPS
    mol_person_id  text,                                  -- MOHRE personal number (WPS "employee unique ID")
    labour_card_no text,
    wps_bank       varchar(20),                           -- employer bank that pays this employee
    ticket_value   numeric(19,2) CHECK (ticket_value >= 0),
    ticket_every_months smallint CHECK (ticket_every_months > 0),
    ticket_last_date date,
    home_city      text,
    updated_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, emp_id),
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.hr_pay (
    company_code   varchar(8) NOT NULL,
    emp_id         integer NOT NULL,
    wage_code      varchar(50) NOT NULL,
    amount         numeric(19,2) NOT NULL CHECK (amount >= 0),
    valid_from     date NOT NULL,
    note           text,
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_code, emp_id, wage_code, valid_from),
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.hr_document (
    doc_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    emp_id         integer NOT NULL,
    doc_type       text NOT NULL CHECK (doc_type IN ('passport', 'visa', 'emirates_id', 'labour_card', 'other')),
    doc_no         text,
    issued_on      date,
    expires_on     date,
    storage_path   text,
    file_name      text,
    active         boolean NOT NULL DEFAULT true,
    uploaded_by    uuid,
    uploaded_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS hr_document_emp_idx ON erp.hr_document (company_code, emp_id);

CREATE TABLE IF NOT EXISTS erp.leave_request (
    request_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    emp_id         integer NOT NULL,
    leave_code     varchar(50) NOT NULL,
    from_date      date NOT NULL,
    to_date        date NOT NULL,
    days           numeric(9,2) NOT NULL,
    reason         text,
    state          text NOT NULL DEFAULT 'pending_approval' CHECK (state IN ('pending_approval', 'approved', 'rejected', 'cancelled')),
    requested_by   uuid NOT NULL,
    requested_at   timestamptz NOT NULL DEFAULT now(),
    decided_at     timestamptz,
    cancelled_by   uuid,
    cancel_note    text,
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE,
    CHECK (to_date >= from_date)
);
CREATE INDEX IF NOT EXISTS leave_request_emp_idx ON erp.leave_request (company_code, emp_id, from_date);

CREATE TABLE IF NOT EXISTS erp.hr_attendance (
    att_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    emp_id         integer NOT NULL,
    work_date      date NOT NULL,
    shift_code     varchar(20),
    check_in_at    timestamptz NOT NULL,
    in_lat numeric(9,6), in_lng numeric(9,6), in_accuracy numeric(9,1),
    in_site        varchar(20),
    in_distance_m  integer,
    in_flags       text[] NOT NULL DEFAULT '{}',
    late_min       integer NOT NULL DEFAULT 0,
    check_out_at   timestamptz,
    out_lat numeric(9,6), out_lng numeric(9,6), out_accuracy numeric(9,1),
    out_site       varchar(20),
    out_distance_m integer,
    out_flags      text[] NOT NULL DEFAULT '{}',
    UNIQUE (company_code, emp_id, work_date),
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS erp.hr_payroll_run (
    run_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL REFERENCES erp.company ON DELETE CASCADE,
    period         varchar(7) NOT NULL,
    from_date      date NOT NULL,
    to_date        date NOT NULL,
    state          text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'reviewed', 'locked', 'posted')),
    stale          boolean NOT NULL DEFAULT false,      -- inputs changed after the last calculation
    headcount      integer NOT NULL DEFAULT 0,
    gross          numeric(19,2) NOT NULL DEFAULT 0,
    deductions     numeric(19,2) NOT NULL DEFAULT 0,
    net            numeric(19,2) NOT NULL DEFAULT 0,
    skipped        jsonb NOT NULL DEFAULT '[]',
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    calculated_by  uuid, calculated_at timestamptz,
    reviewed_by    uuid, reviewed_at   timestamptz,
    locked_by      uuid, locked_at     timestamptz,
    posted_by      uuid, posted_at     timestamptz,
    trans_id       integer,
    UNIQUE (company_code, period)
);

CREATE TABLE IF NOT EXISTS erp.hr_payroll_input (
    input_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_code   varchar(8) NOT NULL,
    period         varchar(7) NOT NULL,
    emp_id         integer NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('overtime_hours', 'unpaid_days', 'deduction', 'earning')),
    wage_code      varchar(50),
    value          numeric(19,2) NOT NULL CHECK (value > 0),
    note           text,
    created_by     uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (company_code, emp_id) REFERENCES erp.employee ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS hr_payroll_input_idx ON erp.hr_payroll_input (company_code, period);

CREATE TABLE IF NOT EXISTS erp.hr_payroll_emp (
    run_id         integer NOT NULL REFERENCES erp.hr_payroll_run ON DELETE CASCADE,
    emp_id         integer NOT NULL,
    hr_code        varchar(50),
    name           text,
    department     text,
    wps_bank       varchar(20),
    days_in_period numeric(5,2) NOT NULL,
    days_paid      numeric(5,2) NOT NULL,
    leave_days     numeric(5,2) NOT NULL DEFAULT 0,
    unpaid_days    numeric(5,2) NOT NULL DEFAULT 0,
    gross          numeric(19,2) NOT NULL DEFAULT 0,
    deductions     numeric(19,2) NOT NULL DEFAULT 0,
    net            numeric(19,2) NOT NULL DEFAULT 0,
    fixed_income   numeric(19,2) NOT NULL DEFAULT 0,
    variable_income numeric(19,2) NOT NULL DEFAULT 0,
    errors         jsonb NOT NULL DEFAULT '[]',
    PRIMARY KEY (run_id, emp_id)
);

CREATE TABLE IF NOT EXISTS erp.hr_payroll_line (
    run_id         integer NOT NULL REFERENCES erp.hr_payroll_run ON DELETE CASCADE,
    emp_id         integer NOT NULL,
    line_no        smallint NOT NULL,
    wage_code      varchar(50) NOT NULL,
    name           text,
    kind           text NOT NULL CHECK (kind IN ('earning', 'deduction')),
    fixed          boolean NOT NULL DEFAULT false,
    qty            numeric(19,4),
    rate           numeric(19,4),
    amount         numeric(19,2) NOT NULL,
    note           text,
    PRIMARY KEY (run_id, emp_id, line_no)
);

CREATE SEQUENCE IF NOT EXISTS erp.erp_emp_seq AS integer START WITH 900000 MINVALUE 900000;

-- ============ Read access ============
-- Is the signed-in user the manager of this employee? Used by the leave policy (runs with owner rights, so the employee
-- row is checked without the employee RLS, which shows a manager only their own record).
CREATE OR REPLACE FUNCTION erp.hr_manages(p_company varchar, p_emp integer) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM erp.employee e WHERE e.company_code = p_company AND e.emp_id = p_emp
                    AND e.manager_emp_id = erp.my_emp(p_company))
$$;
REVOKE ALL ON FUNCTION erp.hr_manages(varchar, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.hr_manages(varchar, integer) TO authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['hr_setting', 'hr_site', 'hr_shift', 'hr_duty', 'hr_holiday', 'hr_leave_policy', 'hr_leave_adjust', 'hr_wps_bank',
                           'hr_employee_extra', 'hr_pay', 'hr_document', 'leave_request', 'hr_attendance', 'hr_payroll_run',
                           'hr_payroll_input', 'hr_payroll_emp', 'hr_payroll_line'] LOOP
    EXECUTE format('ALTER TABLE erp.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON erp.%I FROM PUBLIC, anon, authenticated', t);
  END LOOP;
END $$;
REVOKE ALL ON SEQUENCE erp.erp_emp_seq FROM PUBLIC, anon, authenticated;
-- Salary and bank tables (hr_employee_extra, hr_pay, hr_payroll_*): no grant at all, functions only (audited).
GRANT SELECT ON erp.hr_site, erp.hr_shift, erp.hr_duty, erp.hr_holiday, erp.hr_leave_policy, erp.hr_wps_bank, erp.hr_setting,
                erp.hr_leave_adjust, erp.hr_document, erp.leave_request, erp.hr_attendance TO authenticated;
DROP POLICY IF EXISTS hr_site_read ON erp.hr_site;
CREATE POLICY hr_site_read ON erp.hr_site FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS hr_shift_read ON erp.hr_shift;
CREATE POLICY hr_shift_read ON erp.hr_shift FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS hr_duty_read ON erp.hr_duty;
CREATE POLICY hr_duty_read ON erp.hr_duty FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS hr_holiday_read ON erp.hr_holiday;
CREATE POLICY hr_holiday_read ON erp.hr_holiday FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS hr_leave_policy_read ON erp.hr_leave_policy;
CREATE POLICY hr_leave_policy_read ON erp.hr_leave_policy FOR SELECT TO authenticated USING (erp.can_see(company_code));
DROP POLICY IF EXISTS hr_wps_bank_read ON erp.hr_wps_bank;
CREATE POLICY hr_wps_bank_read ON erp.hr_wps_bank FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.module_level('hr')) IS NOT NULL);
DROP POLICY IF EXISTS hr_setting_read ON erp.hr_setting;
CREATE POLICY hr_setting_read ON erp.hr_setting FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.module_level('hr')) IS NOT NULL);
DROP POLICY IF EXISTS hr_leave_adjust_read ON erp.hr_leave_adjust;
CREATE POLICY hr_leave_adjust_read ON erp.hr_leave_adjust FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.module_level('hr')) IS NOT NULL OR emp_id = erp.my_emp(company_code)));
DROP POLICY IF EXISTS hr_document_read ON erp.hr_document;
CREATE POLICY hr_document_read ON erp.hr_document FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.module_level('hr')) IS NOT NULL OR emp_id = erp.my_emp(company_code)));
DROP POLICY IF EXISTS hr_attendance_read ON erp.hr_attendance;
CREATE POLICY hr_attendance_read ON erp.hr_attendance FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.module_level('hr')) IS NOT NULL OR emp_id = erp.my_emp(company_code)));
DROP POLICY IF EXISTS leave_request_read ON erp.leave_request;
CREATE POLICY leave_request_read ON erp.leave_request FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND ((SELECT erp.module_level('hr')) IS NOT NULL OR emp_id = erp.my_emp(company_code)
         OR erp.hr_manages(company_code, emp_id)));

-- HR with read-level access sees the employee master and ID documents (12 admitted HR full only, through has_module).
DROP POLICY IF EXISTS a9_employee_hr_read ON erp.employee;
CREATE POLICY a9_employee_hr_read ON erp.employee FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.module_level('hr')) IS NOT NULL);
DROP POLICY IF EXISTS a9_employee_document_hr_read ON erp.employee_document;
CREATE POLICY a9_employee_document_hr_read ON erp.employee_document FOR SELECT TO authenticated
  USING (erp.can_see(company_code) AND (SELECT erp.module_level('hr')) IS NOT NULL);
-- Salary tables from SAP: closed to direct reads; every view goes through an audited function.
DROP POLICY IF EXISTS a9_employee_pay_via_functions ON erp.employee_pay;
CREATE POLICY a9_employee_pay_via_functions ON erp.employee_pay AS RESTRICTIVE FOR SELECT TO authenticated USING (false);
DROP POLICY IF EXISTS a9_payroll_result_via_functions ON erp.payroll_result;
CREATE POLICY a9_payroll_result_via_functions ON erp.payroll_result AS RESTRICTIVE FOR SELECT TO authenticated USING (false);
DROP POLICY IF EXISTS a9_air_ticket_via_functions ON erp.air_ticket_accrual;
CREATE POLICY a9_air_ticket_via_functions ON erp.air_ticket_accrual AS RESTRICTIVE FOR SELECT TO authenticated USING (false);

-- ID document files: bucket hr-docs, object names <company>/<emp_id>/<file>. HR full uploads; HR (read or full) or the
-- employee reads. The app asks for signed URLs that last 600 seconds.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('hr-docs', 'hr-docs', false, 10485760)
ON CONFLICT (id) DO NOTHING;
DROP POLICY IF EXISTS hr_docs_insert ON storage.objects;
CREATE POLICY hr_docs_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'hr-docs' AND erp.can_see(((storage.foldername(name))[1])::varchar) AND erp.can_write('hr'));
DROP POLICY IF EXISTS hr_docs_select ON storage.objects;
CREATE POLICY hr_docs_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'hr-docs' AND erp.can_see(((storage.foldername(name))[1])::varchar)
         AND (erp.module_level('hr') IS NOT NULL
              OR (storage.foldername(name))[2] = erp.my_emp(((storage.foldername(name))[1])::varchar)::text));

-- ============ Small helpers ============
CREATE OR REPLACE FUNCTION erp._hr_d(p date) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT to_char(p, 'DD Mon YYYY')
$$;

CREATE OR REPLACE FUNCTION erp._hr_emp_name(p_company varchar, p_emp integer) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp
$$;

-- Who is calling. p_level: 'any' (any profile in the company), 'read' (HR read or full), 'full' (HR full),
-- 'salary' (HR full; message names salary).
CREATE OR REPLACE FUNCTION erp._hr_guard(p_company varchar, p_level text) RETURNS erp.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  lvl text;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Your sign-in has no active Super ERP profile. Ask the system admin to set one up.' USING ERRCODE = '42501';
  END IF;
  IF p_company IS NULL OR NOT erp.can_see(p_company) THEN
    RAISE EXCEPTION 'You don''t have access to company %.', coalesce(p_company, '(none)') USING ERRCODE = '42501';
  END IF;
  IF p_level = 'any' THEN
    RETURN u;
  END IF;
  lvl := erp.module_level('hr');
  IF lvl IS NULL THEN
    RAISE EXCEPTION 'Your position does not include Human Resources. Ask the system admin if you need it.' USING ERRCODE = '42501';
  END IF;
  IF p_level = 'read' OR lvl = 'full' THEN
    RETURN u;
  END IF;
  IF p_level = 'salary' THEN
    RAISE EXCEPTION 'Salary and payroll are for HR positions with full access only.' USING ERRCODE = '42501';
  END IF;
  RAISE EXCEPTION 'You have read-only access to Human Resources. Ask the system admin for full access.' USING ERRCODE = '42501';
END $$;

-- The employee record of the signed-in user in this company (NULL when the sign-in is not linked).
CREATE OR REPLACE FUNCTION erp._hr_me(p_company varchar) RETURNS erp.employee
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT e.* FROM erp.app_user u JOIN erp.employee e ON e.company_code = p_company AND e.emp_id = u.emp_id
   WHERE u.user_id = erp.current_user_id() AND u.active AND u.company_code = p_company
$$;

CREATE OR REPLACE FUNCTION erp._hr_salary_audit(p_company varchar, p_what text, p_ref text, p_detail jsonb DEFAULT '{}') RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'salary_view', p_what, p_ref, coalesce(p_detail, '{}'::jsonb))
$$;

-- Great-circle distance in metres.
CREATE OR REPLACE FUNCTION erp._hr_distance_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = erp, pg_temp AS $$
  SELECT (2 * 6371000 * asin(sqrt(power(sin(radians((lat2 - lat1)::float8) / 2), 2)
          + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lng2 - lng1)::float8) / 2), 2))))::numeric
$$;

-- IBAN check digits (ISO 13616 mod 97).
CREATE OR REPLACE FUNCTION erp._hr_iban_ok(p text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = erp, pg_temp AS $$
DECLARE
  s text := upper(replace(coalesce(p, ''), ' ', ''));
  r text := '';
  c text;
BEGIN
  IF s !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{8,30}$' THEN
    RETURN false;
  END IF;
  s := substr(s, 5) || substr(s, 1, 4);
  FOREACH c IN ARRAY regexp_split_to_array(s, '') LOOP
    r := r || CASE WHEN c ~ '[A-Z]' THEN (ascii(c) - 55)::text ELSE c END;
  END LOOP;
  RETURN r::numeric % 97 = 1;
END $$;

-- Leave days between two dates: every day ('calendar') or working days only (not the company's weekend or holidays).
CREATE OR REPLACE FUNCTION erp._hr_leave_days(p_company varchar, p_from date, p_to date, p_basis text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT count(*)::numeric
    FROM generate_series(p_from, p_to, interval '1 day') g(d)
   WHERE p_from <= p_to
     AND (p_basis = 'calendar'
          OR (NOT (extract(isodow FROM g.d)::smallint = ANY (coalesce((SELECT weekend FROM erp.hr_setting WHERE company_code = p_company), '{}')))
              AND NOT EXISTS (SELECT 1 FROM erp.hr_holiday h WHERE h.company_code = p_company AND h.day = g.d::date)))
$$;

-- Leave balance of one employee and leave type on a date: entitlement accrued in the leave year + adjustments − approved − waiting.
CREATE OR REPLACE FUNCTION erp._hr_leave_balance(p_company varchar, p_emp integer, p_code text, p_as_of date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  pol  erp.hr_leave_policy;
  e    erp.employee;
  v_sm smallint := coalesce((SELECT leave_year_start FROM erp.hr_setting WHERE company_code = p_company), 1);
  ys date; ye date; st date;
  ent numeric := NULL; adj numeric; taken numeric; pend numeric; months integer;
  a interval;
BEGIN
  SELECT * INTO pol FROM erp.hr_leave_policy WHERE company_code = p_company AND leave_code = p_code AND active;
  SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp;
  ys := make_date(extract(year FROM p_as_of)::int, v_sm, 1);
  IF ys > p_as_of THEN ys := (ys - interval '1 year')::date; END IF;
  ye := (ys + interval '1 year' - interval '1 day')::date;
  st := greatest(ys, coalesce(e.joined_on, ys));
  SELECT coalesce(sum(days), 0) INTO adj FROM erp.hr_leave_adjust
   WHERE company_code = p_company AND emp_id = p_emp AND leave_code = p_code AND leave_year = extract(year FROM ys)::int;
  SELECT coalesce(sum(days) FILTER (WHERE state = 'approved'), 0), coalesce(sum(days) FILTER (WHERE state = 'pending_approval'), 0)
    INTO taken, pend FROM erp.leave_request
   WHERE company_code = p_company AND emp_id = p_emp AND leave_code = p_code AND from_date BETWEEN ys AND ye;
  IF pol.leave_code IS NOT NULL AND pol.accrual <> 'none' THEN
    IF st > p_as_of THEN
      ent := 0;
    ELSIF pol.accrual = 'yearly' THEN
      ent := round(pol.annual_days * (ye - st + 1)::numeric / (ye - ys + 1), 2);
    ELSE
      a := age(p_as_of + 1, st);
      months := extract(year FROM a)::int * 12 + extract(month FROM a)::int;
      ent := round(pol.annual_days / 12 * months, 2);
    END IF;
  END IF;
  RETURN jsonb_build_object('leave_code', p_code, 'tracked', ent IS NOT NULL, 'year_start', ys, 'year_end', ye,
                            'entitled', ent, 'adjusted', adj, 'taken', taken, 'pending', pend,
                            'available', CASE WHEN ent IS NULL THEN NULL ELSE ent + adj - taken - pend END);
END $$;

CREATE OR REPLACE FUNCTION erp._hr_balances(p_company varchar, p_emp integer, p_as_of date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT coalesce(jsonb_agg(erp._hr_leave_balance(p_company, p_emp, t.code, p_as_of)
                            || jsonb_build_object('name', t.name, 'paid', t.paid, 'accrual', p.accrual, 'annual_days', p.annual_days)
                            ORDER BY t.code), '[]'::jsonb)
    FROM erp.leave_type t JOIN erp.hr_leave_policy p ON p.company_code = t.company_code AND p.leave_code = t.code AND p.active
   WHERE t.company_code = p_company
$$;

-- Pay of an employee on a date: Super ERP pay (hr_pay) when the employee has any, otherwise the migrated SAP basic pay.
CREATE OR REPLACE FUNCTION erp._hr_pay_at(p_company varchar, p_emp integer, p_date date)
RETURNS TABLE (wage_code varchar, amount numeric, valid_from date, source text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM erp.hr_pay h WHERE h.company_code = p_company AND h.emp_id = p_emp) THEN
    RETURN QUERY SELECT DISTINCT ON (h.wage_code) h.wage_code, h.amount, h.valid_from, 'erp'::text FROM erp.hr_pay h
                  WHERE h.company_code = p_company AND h.emp_id = p_emp AND h.valid_from <= p_date
                  ORDER BY h.wage_code, h.valid_from DESC;
  ELSE
    RETURN QUERY SELECT DISTINCT ON (ep.wage_type) ep.wage_type, ep.amount, ep.valid_from, 'sap'::text
                   FROM erp.employee_pay ep JOIN erp.employee e ON e.company_code = ep.company_code AND e.hr_code = ep.hr_code
                  WHERE ep.company_code = p_company AND e.emp_id = p_emp AND ep.valid_from <= p_date
                  ORDER BY ep.wage_type, ep.valid_from DESC;
  END IF;
END $$;

-- End-of-service gratuity on a date, from the hr_setting parameters. Shown only; never posted here.
CREATE OR REPLACE FUNCTION erp._hr_gratuity(p_company varchar, p_emp integer, p_as_of date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  s erp.hr_setting;
  e erp.employee;
  v_basic numeric;
  v_unpaid numeric;
  v_days numeric;
  v_years numeric;
  v_daily numeric;
  v_amt numeric;
  v_cap numeric;
BEGIN
  SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company;
  SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp;
  IF s.gratuity_days_first IS NULL OR s.gratuity_years_first IS NULL OR s.gratuity_days_after IS NULL OR s.gratuity_day_basis IS NULL THEN
    RETURN jsonb_build_object('set', false, 'message', 'The gratuity policy is not set for ' || p_company || '. Ask HR to set it in HR setup.');
  END IF;
  IF e.joined_on IS NULL THEN
    RETURN jsonb_build_object('set', false, 'message', 'The joining date is missing, so gratuity can''t be calculated.');
  END IF;
  SELECT amount INTO v_basic FROM erp._hr_pay_at(p_company, p_emp, p_as_of) WHERE wage_code = 'BASIC';
  IF v_basic IS NULL THEN
    RETURN jsonb_build_object('set', false, 'message', 'No basic pay is set, so gratuity can''t be calculated.');
  END IF;
  -- approved leave of types that don't count for end of service
  SELECT coalesce(sum(erp._hr_leave_days(p_company, r.from_date, least(r.to_date, p_as_of), 'calendar')), 0) INTO v_unpaid
    FROM erp.leave_request r JOIN erp.leave_type t ON t.company_code = r.company_code AND t.code = r.leave_code
   WHERE r.company_code = p_company AND r.emp_id = p_emp AND r.state = 'approved' AND t.counts_for_eos IS FALSE AND r.from_date <= p_as_of;
  v_days := greatest((least(p_as_of, coalesce(e.left_on, p_as_of)) - e.joined_on + 1) - v_unpaid, 0);
  v_years := round(v_days / 365.0, 4);
  v_daily := CASE s.gratuity_day_basis WHEN '30' THEN v_basic / 30 ELSE v_basic * 12 / 365 END;
  IF v_years < coalesce(s.gratuity_min_years, 0) THEN
    v_amt := 0;
  ELSE
    v_amt := v_daily * (s.gratuity_days_first * least(v_years, s.gratuity_years_first)
                        + s.gratuity_days_after * greatest(v_years - s.gratuity_years_first, 0));
  END IF;
  IF s.gratuity_cap_years IS NOT NULL THEN
    v_cap := v_basic * 12 * s.gratuity_cap_years;
    v_amt := least(v_amt, v_cap);
  END IF;
  RETURN jsonb_build_object('set', true, 'as_of', p_as_of, 'basic', v_basic, 'service_days', v_days, 'unpaid_days', v_unpaid,
                            'years', v_years, 'daily', round(v_daily, 4), 'amount', round(v_amt, 2), 'cap', v_cap, 'posted', false);
END $$;

-- Air ticket accrual on a date from the employee's entitlement (value per ticket, one ticket every n months). Shown only.
CREATE OR REPLACE FUNCTION erp._hr_ticket(p_company varchar, p_emp integer, p_as_of date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  x erp.hr_employee_extra;
  e erp.employee;
  v_from date;
  a interval;
  m integer;
BEGIN
  SELECT * INTO x FROM erp.hr_employee_extra WHERE company_code = p_company AND emp_id = p_emp;
  SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp;
  IF x.ticket_value IS NULL OR x.ticket_every_months IS NULL THEN
    RETURN jsonb_build_object('set', false, 'message', 'No air ticket entitlement is set for this employee.');
  END IF;
  v_from := coalesce(x.ticket_last_date, e.joined_on);
  IF v_from IS NULL OR v_from > p_as_of THEN
    RETURN jsonb_build_object('set', true, 'months', 0, 'amount', 0, 'posted', false);
  END IF;
  a := age(p_as_of + 1, v_from);
  m := extract(year FROM a)::int * 12 + extract(month FROM a)::int;
  RETURN jsonb_build_object('set', true, 'as_of', p_as_of, 'since', v_from, 'months', m, 'ticket_value', x.ticket_value,
                            'every_months', x.ticket_every_months, 'home_city', x.home_city,
                            'amount', round(x.ticket_value * m / x.ticket_every_months, 2),
                            'next_due', (v_from + make_interval(months => x.ticket_every_months))::date, 'posted', false);
END $$;

-- The shift of an employee: their own, otherwise the shift whose departments include theirs.
CREATE OR REPLACE FUNCTION erp._hr_shift_of(p_company varchar, p_emp integer) RETURNS erp.hr_shift
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  SELECT s.* FROM erp.hr_shift s
   WHERE s.company_code = p_company AND s.active
     AND (s.shift_code = (SELECT shift_code FROM erp.hr_employee_extra x WHERE x.company_code = p_company AND x.emp_id = p_emp)
          OR (NOT EXISTS (SELECT 1 FROM erp.hr_employee_extra x WHERE x.company_code = p_company AND x.emp_id = p_emp AND x.shift_code IS NOT NULL)
              AND (SELECT division FROM erp.employee e WHERE e.company_code = p_company AND e.emp_id = p_emp) = ANY (s.departments)))
   ORDER BY s.shift_code LIMIT 1
$$;

-- ============ API: employees ============
-- Create or change a Super ERP employee (HR full). New when emp_id is left out. SAP and sample employees are refused: change
-- them in SAP until the company goes live. Keys left out keep their value.
CREATE OR REPLACE FUNCTION erp.hr_employee_save(p_company varchar, p_emp jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u      erp.app_user;
  e      erp.employee;
  v_new  boolean := (p_emp->>'emp_id') IS NULL;
  v_id   integer;
  v_code text;
  ns     erp.number_series;
  v_first text; v_last text; v_join date; v_left date; v_mgr integer; v_email text; v_gov text; v_status text; v_birth date;
  v_cur  integer;
  v_n    integer := 0;
BEGIN
  u := erp._hr_guard(p_company, 'full');
  IF p_emp IS NULL OR jsonb_typeof(p_emp) <> 'object' THEN
    RAISE EXCEPTION 'Send the employee details.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_new THEN
    SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = (p_emp->>'emp_id')::integer FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Employee % was not found in company %.', p_emp->>'emp_id', p_company USING ERRCODE = 'P0001';
    END IF;
    IF e.source <> 'erp' THEN
      RAISE EXCEPTION 'This employee comes from SAP. Change it in SAP until % goes live on Super ERP. HR details (shift, site, WPS, tickets) can still be changed here.', p_company
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_first := CASE WHEN p_emp ? 'first_name' THEN nullif(btrim(p_emp->>'first_name'), '') ELSE e.first_name END;
  v_last  := CASE WHEN p_emp ? 'last_name' THEN nullif(btrim(p_emp->>'last_name'), '') ELSE e.last_name END;
  v_join  := CASE WHEN p_emp ? 'joined_on' THEN erp._date(p_emp->>'joined_on') ELSE e.joined_on END;
  v_left  := CASE WHEN p_emp ? 'left_on' THEN erp._date(p_emp->>'left_on') ELSE e.left_on END;
  v_birth := CASE WHEN p_emp ? 'birth_date' THEN erp._date(p_emp->>'birth_date') ELSE e.birth_date END;
  v_mgr   := CASE WHEN p_emp ? 'manager_emp_id' THEN (nullif(p_emp->>'manager_emp_id', ''))::integer ELSE e.manager_emp_id END;
  v_email := CASE WHEN p_emp ? 'email' THEN nullif(btrim(p_emp->>'email'), '') ELSE e.email END;
  v_gov   := CASE WHEN p_emp ? 'gov_id' THEN nullif(regexp_replace(coalesce(p_emp->>'gov_id', ''), '[\s-]', '', 'g'), '') ELSE e.gov_id END;
  v_status := CASE WHEN p_emp ? 'status' THEN coalesce(nullif(p_emp->>'status', ''), 'active') ELSE coalesce(e.status, 'active') END;
  IF v_first IS NULL THEN
    RAISE EXCEPTION 'Enter the first name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NULL THEN
    RAISE EXCEPTION 'Enter the last name.' USING ERRCODE = 'P0001';
  END IF;
  IF v_join IS NULL THEN
    RAISE EXCEPTION 'Enter the joining date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_left IS NOT NULL AND v_left < v_join THEN
    RAISE EXCEPTION 'The leaving date can''t be before the joining date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_birth IS NOT NULL AND v_birth >= v_join THEN
    RAISE EXCEPTION 'The date of birth must be before the joining date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('active', 'on_leave', 'left') THEN
    RAISE EXCEPTION 'Status must be active, on leave or left.' USING ERRCODE = 'P0001';
  END IF;
  IF v_status = 'left' AND v_left IS NULL THEN
    RAISE EXCEPTION 'Enter the leaving date for an employee who has left.' USING ERRCODE = 'P0001';
  END IF;
  IF v_email IS NOT NULL AND v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'The e-mail % doesn''t look right. Check it.', v_email USING ERRCODE = 'P0001';
  END IF;
  IF v_gov IS NOT NULL AND v_gov !~ '^784[0-9]{12}$' THEN
    RAISE EXCEPTION 'The Emirates ID must be 15 digits starting with 784.' USING ERRCODE = 'P0001';
  END IF;
  IF p_emp ? 'nationality' AND nullif(p_emp->>'nationality', '') IS NOT NULL AND p_emp->>'nationality' !~ '^[A-Za-z]{2,3}$' THEN
    RAISE EXCEPTION 'Nationality is a 2- or 3-letter country code, e.g. AE or IND.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mgr IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = v_mgr) THEN
      RAISE EXCEPTION 'The manager (employee %) was not found in company %.', v_mgr, p_company USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_new THEN
      v_cur := v_mgr;
      WHILE v_cur IS NOT NULL AND v_n < 50 LOOP
        IF v_cur = e.emp_id THEN
          RAISE EXCEPTION 'An employee can''t report to themself or to someone who reports to them.' USING ERRCODE = 'P0001';
        END IF;
        SELECT manager_emp_id INTO v_cur FROM erp.employee WHERE company_code = p_company AND emp_id = v_cur;
        v_n := v_n + 1;
      END LOOP;
    END IF;
  END IF;
  IF p_emp ? 'branch_id' AND nullif(p_emp->>'branch_id', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM erp.branch WHERE company_code = p_company AND branch_id = (p_emp->>'branch_id')::integer) THEN
    RAISE EXCEPTION 'Branch % does not exist in company %.', p_emp->>'branch_id', p_company USING ERRCODE = 'P0001';
  END IF;

  IF v_new THEN
    SELECT * INTO ns FROM erp.number_series WHERE company_code = p_company AND obj_type = 171 AND active FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Employee numbering is not set up for company %. Ask the system admin to add it (Administration › Document Numbering).', p_company
        USING ERRCODE = 'P0001';
    END IF;
    v_n := ns.next_num;
    LOOP
      v_code := ns.prefix || lpad(v_n::text, ns.pad, '0');
      EXIT WHEN NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND hr_code = v_code);
      v_n := v_n + 1;
    END LOOP;
    UPDATE erp.number_series SET next_num = v_n + 1 WHERE company_code = p_company AND obj_type = 171;
    v_id := nextval('erp.erp_emp_seq');
    INSERT INTO erp.employee (company_code, emp_id, hr_code, first_name, middle_name, last_name, job_title, division, branch_id, manager_emp_id,
                              mobile, office_phone, email, gender, birth_date, nationality, passport_no, passport_expires, gov_id, joined_on,
                              left_on, status, sponsor, pay_currency, active, source)
    VALUES (p_company, v_id, v_code, v_first, nullif(btrim(p_emp->>'middle_name'), ''), v_last, nullif(btrim(p_emp->>'job_title'), ''),
            nullif(btrim(p_emp->>'division'), ''), (nullif(p_emp->>'branch_id', ''))::integer, v_mgr, nullif(btrim(p_emp->>'mobile'), ''),
            nullif(btrim(p_emp->>'office_phone'), ''), v_email, nullif(p_emp->>'gender', ''), v_birth, upper(nullif(p_emp->>'nationality', '')),
            nullif(btrim(p_emp->>'passport_no'), ''), erp._date(p_emp->>'passport_expires'), v_gov, v_join, v_left, v_status,
            nullif(btrim(p_emp->>'sponsor'), ''), (SELECT currency FROM erp.company WHERE company_code = p_company), v_status <> 'left', 'erp');
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'employee_create', 'employee', v_id::text, jsonb_build_object('hr_code', v_code, 'name', v_first || ' ' || v_last));
  ELSE
    v_id := e.emp_id;
    v_code := e.hr_code;
    UPDATE erp.employee SET
      first_name = v_first, last_name = v_last,
      middle_name = CASE WHEN p_emp ? 'middle_name' THEN nullif(btrim(p_emp->>'middle_name'), '') ELSE middle_name END,
      job_title = CASE WHEN p_emp ? 'job_title' THEN nullif(btrim(p_emp->>'job_title'), '') ELSE job_title END,
      division = CASE WHEN p_emp ? 'division' THEN nullif(btrim(p_emp->>'division'), '') ELSE division END,
      branch_id = CASE WHEN p_emp ? 'branch_id' THEN (nullif(p_emp->>'branch_id', ''))::integer ELSE branch_id END,
      manager_emp_id = v_mgr,
      mobile = CASE WHEN p_emp ? 'mobile' THEN nullif(btrim(p_emp->>'mobile'), '') ELSE mobile END,
      office_phone = CASE WHEN p_emp ? 'office_phone' THEN nullif(btrim(p_emp->>'office_phone'), '') ELSE office_phone END,
      email = v_email,
      gender = CASE WHEN p_emp ? 'gender' THEN nullif(p_emp->>'gender', '') ELSE gender END,
      birth_date = v_birth,
      nationality = CASE WHEN p_emp ? 'nationality' THEN upper(nullif(p_emp->>'nationality', '')) ELSE nationality END,
      passport_no = CASE WHEN p_emp ? 'passport_no' THEN nullif(btrim(p_emp->>'passport_no'), '') ELSE passport_no END,
      passport_expires = CASE WHEN p_emp ? 'passport_expires' THEN erp._date(p_emp->>'passport_expires') ELSE passport_expires END,
      gov_id = v_gov, joined_on = v_join, left_on = v_left, status = v_status, active = v_status <> 'left',
      sponsor = CASE WHEN p_emp ? 'sponsor' THEN nullif(btrim(p_emp->>'sponsor'), '') ELSE sponsor END
    WHERE company_code = p_company AND emp_id = v_id;
    INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
    VALUES (u.user_id::text, p_company, 'employee_update', 'employee', v_id::text,
            jsonb_build_object('hr_code', v_code, 'fields', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_emp - 'emp_id' - 'extra') k)));
  END IF;
  IF jsonb_typeof(p_emp->'extra') = 'object' THEN
    PERFORM erp.hr_employee_extra_save(p_company, v_id, p_emp->'extra');
  END IF;
  RETURN jsonb_build_object('emp_id', v_id, 'hr_code', v_code);
END $$;

-- HR details any employee may have, SAP ones included (they live only in Super ERP): shift, site, WPS bank details, air tickets.
CREATE OR REPLACE FUNCTION erp.hr_employee_extra_save(p_company varchar, p_emp_id integer, p_extra jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  s  erp.hr_setting;
  x  erp.hr_employee_extra;
  v_iban text; v_rout text; v_mol text;
BEGIN
  u := erp._hr_guard(p_company, 'full');
  IF NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp_id) THEN
    RAISE EXCEPTION 'Employee % was not found in company %.', coalesce(p_emp_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company;
  SELECT * INTO x FROM erp.hr_employee_extra WHERE company_code = p_company AND emp_id = p_emp_id FOR UPDATE;
  v_iban := CASE WHEN p_extra ? 'iban' THEN nullif(upper(replace(coalesce(p_extra->>'iban', ''), ' ', '')), '') ELSE x.iban END;
  v_rout := CASE WHEN p_extra ? 'bank_routing' THEN nullif(btrim(p_extra->>'bank_routing'), '') ELSE x.bank_routing END;
  v_mol  := CASE WHEN p_extra ? 'mol_person_id' THEN nullif(btrim(p_extra->>'mol_person_id'), '') ELSE x.mol_person_id END;
  IF v_iban IS NOT NULL AND NOT erp._hr_iban_ok(v_iban) THEN
    RAISE EXCEPTION 'The IBAN % is not valid. Check the letters and digits.', v_iban USING ERRCODE = 'P0001';
  END IF;
  IF v_rout IS NOT NULL AND (v_rout !~ '^[0-9]+$' OR (s.wps_routing_len IS NOT NULL AND length(v_rout) <> s.wps_routing_len)) THEN
    RAISE EXCEPTION 'The bank routing code must be % digits.', coalesce(s.wps_routing_len::text, 'only') USING ERRCODE = 'P0001';
  END IF;
  IF v_mol IS NOT NULL AND (v_mol !~ '^[0-9]+$' OR (s.wps_person_id_len IS NOT NULL AND length(v_mol) <> s.wps_person_id_len)) THEN
    RAISE EXCEPTION 'The MOHRE personal number must be % digits.', coalesce(s.wps_person_id_len::text, 'only') USING ERRCODE = 'P0001';
  END IF;
  IF p_extra ? 'shift_code' AND nullif(p_extra->>'shift_code', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM erp.hr_shift WHERE company_code = p_company AND shift_code = p_extra->>'shift_code') THEN
    RAISE EXCEPTION 'Shift % does not exist. Add it in HR setup first.', p_extra->>'shift_code' USING ERRCODE = 'P0001';
  END IF;
  IF p_extra ? 'site_code' AND nullif(p_extra->>'site_code', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM erp.hr_site WHERE company_code = p_company AND site_code = p_extra->>'site_code') THEN
    RAISE EXCEPTION 'Site % does not exist. Add it in HR setup first.', p_extra->>'site_code' USING ERRCODE = 'P0001';
  END IF;
  IF p_extra ? 'wps_bank' AND nullif(p_extra->>'wps_bank', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM erp.hr_wps_bank WHERE company_code = p_company AND bank_code = p_extra->>'wps_bank') THEN
    RAISE EXCEPTION 'WPS bank % does not exist. Add it in HR setup first.', p_extra->>'wps_bank' USING ERRCODE = 'P0001';
  END IF;
  IF (p_extra ? 'ticket_value' AND erp._num(p_extra->>'ticket_value') < 0)
     OR (p_extra ? 'ticket_every_months' AND erp._num(p_extra->>'ticket_every_months') <= 0) THEN
    RAISE EXCEPTION 'The ticket value can''t be negative and the ticket period must be at least 1 month.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.hr_employee_extra AS t (company_code, emp_id, shift_code, site_code, iban, bank_routing, mol_person_id, labour_card_no, wps_bank,
                                          ticket_value, ticket_every_months, ticket_last_date, home_city, updated_by, updated_at)
  VALUES (p_company, p_emp_id,
          CASE WHEN p_extra ? 'shift_code' THEN nullif(p_extra->>'shift_code', '') ELSE x.shift_code END,
          CASE WHEN p_extra ? 'site_code' THEN nullif(p_extra->>'site_code', '') ELSE x.site_code END,
          v_iban, v_rout, v_mol,
          CASE WHEN p_extra ? 'labour_card_no' THEN nullif(btrim(p_extra->>'labour_card_no'), '') ELSE x.labour_card_no END,
          CASE WHEN p_extra ? 'wps_bank' THEN nullif(p_extra->>'wps_bank', '') ELSE x.wps_bank END,
          CASE WHEN p_extra ? 'ticket_value' THEN erp._num(p_extra->>'ticket_value') ELSE x.ticket_value END,
          CASE WHEN p_extra ? 'ticket_every_months' THEN erp._num(p_extra->>'ticket_every_months')::smallint ELSE x.ticket_every_months END,
          CASE WHEN p_extra ? 'ticket_last_date' THEN erp._date(p_extra->>'ticket_last_date') ELSE x.ticket_last_date END,
          CASE WHEN p_extra ? 'home_city' THEN nullif(btrim(p_extra->>'home_city'), '') ELSE x.home_city END,
          u.user_id, now())
  ON CONFLICT (company_code, emp_id) DO UPDATE SET shift_code = EXCLUDED.shift_code, site_code = EXCLUDED.site_code, iban = EXCLUDED.iban,
    bank_routing = EXCLUDED.bank_routing, mol_person_id = EXCLUDED.mol_person_id, labour_card_no = EXCLUDED.labour_card_no,
    wps_bank = EXCLUDED.wps_bank, ticket_value = EXCLUDED.ticket_value, ticket_every_months = EXCLUDED.ticket_every_months,
    ticket_last_date = EXCLUDED.ticket_last_date, home_city = EXCLUDED.home_city, updated_by = EXCLUDED.updated_by, updated_at = now();
  -- bank details are salary data: the log names the fields, not the values
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'employee_hr_details', 'employee', p_emp_id::text,
          jsonb_build_object('fields', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_extra) k)));
  RETURN jsonb_build_object('emp_id', p_emp_id, 'saved', true);
END $$;

-- Set one pay element from a date (HR full). Amount 0 stops it. Not before the end of the last locked payroll.
CREATE OR REPLACE FUNCTION erp.hr_pay_set(p_company varchar, p_emp_id integer, p_wage_code text, p_amount numeric, p_valid_from date, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  w  erp.wage_type;
  v_last date;
  v_old numeric;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  IF NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp_id) THEN
    RAISE EXCEPTION 'Employee % was not found in company %.', coalesce(p_emp_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO w FROM erp.wage_type WHERE company_code = p_company AND code = p_wage_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wage type % does not exist in company %.', coalesce(p_wage_code, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF NOT coalesce(w.is_earning, false) OR coalesce(w.calc_type, 'fixed') <> 'fixed' THEN
    RAISE EXCEPTION 'Only fixed earnings (basic, allowances) are set per employee. % is entered per payroll month.', coalesce(w.name, w.code) USING ERRCODE = 'P0001';
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'Enter an amount of 0 or more.' USING ERRCODE = 'P0001';
  END IF;
  IF p_valid_from IS NULL THEN
    RAISE EXCEPTION 'Choose the date the new amount starts.' USING ERRCODE = 'P0001';
  END IF;
  SELECT max(to_date) INTO v_last FROM erp.hr_payroll_run WHERE company_code = p_company AND state IN ('locked', 'posted');
  IF v_last IS NOT NULL AND p_valid_from <= v_last THEN
    RAISE EXCEPTION 'Payroll is locked up to %. A pay change must start after that.', erp._hr_d(v_last) USING ERRCODE = 'P0001';
  END IF;
  SELECT amount INTO v_old FROM erp._hr_pay_at(p_company, p_emp_id, p_valid_from) WHERE wage_code = p_wage_code;
  INSERT INTO erp.hr_pay (company_code, emp_id, wage_code, amount, valid_from, note, created_by)
  VALUES (p_company, p_emp_id, p_wage_code, round(p_amount, 2), p_valid_from, nullif(btrim(p_note), ''), u.user_id)
  ON CONFLICT (company_code, emp_id, wage_code, valid_from) DO UPDATE SET amount = EXCLUDED.amount, note = EXCLUDED.note,
    created_by = EXCLUDED.created_by, created_at = now();
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'salary_change', 'employee', p_emp_id::text,
          jsonb_build_object('wage_code', p_wage_code, 'from', v_old, 'to', round(p_amount, 2), 'valid_from', p_valid_from, 'note', nullif(btrim(p_note), '')));
  RETURN jsonb_build_object('emp_id', p_emp_id, 'wage_code', p_wage_code, 'amount', round(p_amount, 2), 'valid_from', p_valid_from);
END $$;

-- Add or change an ID document (HR full). storage_path must be <company>/<emp_id>/<file> in bucket hr-docs.
CREATE OR REPLACE FUNCTION erp.hr_document_save(p_company varchar, p_doc jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  d   erp.hr_document;
  v_emp integer := (nullif(p_doc->>'emp_id', ''))::integer;
  v_type text := nullif(p_doc->>'doc_type', '');
  v_path text := nullif(btrim(p_doc->>'storage_path'), '');
  v_iss date := erp._date(p_doc->>'issued_on');
  v_exp date := erp._date(p_doc->>'expires_on');
  v_id integer;
BEGIN
  u := erp._hr_guard(p_company, 'full');
  IF (p_doc->>'doc_id') IS NOT NULL THEN
    SELECT * INTO d FROM erp.hr_document WHERE company_code = p_company AND doc_id = (p_doc->>'doc_id')::integer FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Document % was not found.', p_doc->>'doc_id' USING ERRCODE = 'P0001';
    END IF;
    v_emp := d.emp_id;
    v_type := coalesce(v_type, d.doc_type);
    v_path := CASE WHEN p_doc ? 'storage_path' THEN v_path ELSE d.storage_path END;
    v_iss := CASE WHEN p_doc ? 'issued_on' THEN v_iss ELSE d.issued_on END;
    v_exp := CASE WHEN p_doc ? 'expires_on' THEN v_exp ELSE d.expires_on END;
  END IF;
  IF v_emp IS NULL OR NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = v_emp) THEN
    RAISE EXCEPTION 'Choose the employee.' USING ERRCODE = 'P0001';
  END IF;
  IF v_type IS NULL OR v_type NOT IN ('passport', 'visa', 'emirates_id', 'labour_card', 'other') THEN
    RAISE EXCEPTION 'Choose the document type: passport, visa, Emirates ID, labour card or other.' USING ERRCODE = 'P0001';
  END IF;
  IF v_type <> 'other' AND v_exp IS NULL THEN
    RAISE EXCEPTION 'Enter the expiry date. Expiry alerts depend on it.' USING ERRCODE = 'P0001';
  END IF;
  IF v_iss IS NOT NULL AND v_exp IS NOT NULL AND v_exp <= v_iss THEN
    RAISE EXCEPTION 'The expiry date must be after the issue date.' USING ERRCODE = 'P0001';
  END IF;
  IF v_path IS NOT NULL AND v_path NOT LIKE p_company || '/' || v_emp || '/%' THEN
    RAISE EXCEPTION 'The file must be stored under %/%/ in the hr-docs bucket.', p_company, v_emp USING ERRCODE = 'P0001';
  END IF;
  IF d.doc_id IS NULL THEN
    INSERT INTO erp.hr_document (company_code, emp_id, doc_type, doc_no, issued_on, expires_on, storage_path, file_name, uploaded_by)
    VALUES (p_company, v_emp, v_type, nullif(btrim(p_doc->>'doc_no'), ''), v_iss, v_exp, v_path, nullif(btrim(p_doc->>'file_name'), ''), u.user_id)
    RETURNING doc_id INTO v_id;
  ELSE
    v_id := d.doc_id;
    UPDATE erp.hr_document SET doc_type = v_type,
      doc_no = CASE WHEN p_doc ? 'doc_no' THEN nullif(btrim(p_doc->>'doc_no'), '') ELSE doc_no END,
      issued_on = v_iss, expires_on = v_exp, storage_path = v_path,
      file_name = CASE WHEN p_doc ? 'file_name' THEN nullif(btrim(p_doc->>'file_name'), '') ELSE file_name END,
      active = CASE WHEN p_doc ? 'active' THEN (p_doc->>'active')::boolean ELSE active END,
      uploaded_by = u.user_id, uploaded_at = now()
     WHERE doc_id = v_id;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN d.doc_id IS NULL THEN 'employee_document_add' ELSE 'employee_document_update' END, 'employee', v_emp::text,
          jsonb_build_object('doc_id', v_id, 'doc_type', v_type, 'expires_on', v_exp));
  RETURN jsonb_build_object('doc_id', v_id);
END $$;

-- Documents expiring (alert bands from hr_setting.expiry_alert_days, default 60 / 30 / 7) — Super ERP and SAP documents.
-- Own documents, or every employee's for HR (read or full). Owner-rights view with the access rule in WHERE.
CREATE OR REPLACE VIEW erp.hr_doc_expiry AS
WITH d AS (
  SELECT h.company_code, h.emp_id, h.doc_type, h.doc_no, h.expires_on, 'erp'::text AS source, h.doc_id
    FROM erp.hr_document h WHERE h.active AND h.expires_on IS NOT NULL
  UNION ALL
  SELECT ed.company_code, e.emp_id, lower(replace(ed.doc_type, ' ', '_')), ed.doc_no, ed.expires_on, 'sap', NULL
    FROM erp.employee_document ed JOIN erp.employee e ON e.company_code = ed.company_code AND e.hr_code = ed.hr_code
   WHERE ed.expires_on IS NOT NULL
)
SELECT d.company_code, d.emp_id, e.hr_code, concat_ws(' ', e.first_name, e.last_name) AS emp_name, e.division AS department,
       d.doc_type, d.doc_no, d.expires_on, d.expires_on - current_date AS days_left,
       CASE WHEN d.expires_on < current_date THEN 'expired'
            ELSE (SELECT 'd' || min(x) FROM unnest(coalesce(s.expiry_alert_days, '{60,30,7}')) x WHERE d.expires_on - current_date <= x) END AS band,
       d.source, d.doc_id
  FROM d
  JOIN erp.employee e ON e.company_code = d.company_code AND e.emp_id = d.emp_id
  LEFT JOIN erp.hr_setting s ON s.company_code = d.company_code
 WHERE e.active
   AND d.expires_on - current_date <= (SELECT max(x) FROM unnest(coalesce(s.expiry_alert_days, '{60,30,7}')) x)
   AND erp.can_see(d.company_code)
   AND (erp.module_level('hr') IS NOT NULL OR d.emp_id = erp.my_emp(d.company_code));
REVOKE ALL ON erp.hr_doc_expiry FROM PUBLIC, anon;
GRANT SELECT ON erp.hr_doc_expiry TO authenticated;

-- Everything the employee page needs. HR read: profile, HR details without bank, documents, leave, attendance.
-- HR full (or the employee themself): also pay, bank / WPS details, gratuity and air ticket — audited as 'salary_view'.
CREATE OR REPLACE FUNCTION erp.hr_employee_info(p_company varchar, p_emp_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  e   erp.employee;
  x   erp.hr_employee_extra;
  lvl text;
  v_self boolean;
  v_sal boolean;
  v_today date;
  r   jsonb;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = p_emp_id;
  lvl := erp.module_level('hr');
  v_self := coalesce(e.emp_id = erp.my_emp(p_company), false);
  IF e.emp_id IS NULL OR (lvl IS NULL AND NOT v_self) THEN
    IF lvl IS NULL THEN
      RAISE EXCEPTION 'Your position does not include Human Resources. Ask the system admin if you need it.' USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'Employee % was not found in company %.', coalesce(p_emp_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  v_sal := coalesce(lvl = 'full', false) OR v_self;
  v_today := (now() AT TIME ZONE coalesce((SELECT timezone FROM erp.hr_setting WHERE company_code = p_company), 'Asia/Dubai'))::date;
  SELECT * INTO x FROM erp.hr_employee_extra WHERE company_code = p_company AND emp_id = p_emp_id;
  r := jsonb_build_object(
    'employee', to_jsonb(e) || jsonb_build_object('manager_name', erp._hr_emp_name(p_company, e.manager_emp_id),
                                                  'branch_name', (SELECT name FROM erp.branch b WHERE b.company_code = p_company AND b.branch_id = e.branch_id)),
    'hr', jsonb_build_object('shift_code', x.shift_code, 'site_code', x.site_code, 'labour_card_no', x.labour_card_no, 'home_city', x.home_city,
                             'shift', to_jsonb(erp._hr_shift_of(p_company, p_emp_id))),
    'documents', coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.expires_on NULLS LAST) FROM erp.hr_document d
                            WHERE d.company_code = p_company AND d.emp_id = p_emp_id AND d.active), '[]'::jsonb),
    'sap_documents', coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.expires_on NULLS LAST) FROM erp.employee_document d
                                WHERE d.company_code = p_company AND d.hr_code = e.hr_code), '[]'::jsonb),
    'balances', erp._hr_balances(p_company, p_emp_id, v_today),
    'leave', coalesce((SELECT jsonb_agg(jsonb_build_object('request_id', l.request_id, 'leave_code', l.leave_code, 'from_date', l.from_date,
                                                           'to_date', l.to_date, 'days', l.days, 'state', l.state) ORDER BY l.from_date DESC)
                         FROM (SELECT * FROM erp.leave_request WHERE company_code = p_company AND emp_id = p_emp_id ORDER BY from_date DESC LIMIT 20) l), '[]'::jsonb),
    'attendance', coalesce((SELECT jsonb_agg(jsonb_build_object('work_date', a.work_date, 'check_in_at', a.check_in_at, 'check_out_at', a.check_out_at,
                                                                'in_flags', a.in_flags, 'out_flags', a.out_flags, 'late_min', a.late_min) ORDER BY a.work_date DESC)
                              FROM (SELECT * FROM erp.hr_attendance WHERE company_code = p_company AND emp_id = p_emp_id ORDER BY work_date DESC LIMIT 14) a), '[]'::jsonb),
    'can_edit', lvl = 'full' AND e.source = 'erp',
    'can_edit_hr', lvl = 'full',
    'edit_reason', CASE WHEN lvl IS DISTINCT FROM 'full' THEN 'read_only' WHEN e.source <> 'erp' THEN 'sap' END,
    'salary_visible', v_sal,
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company));
  IF v_sal THEN
    r := r || jsonb_build_object(
      'bank', jsonb_build_object('iban', x.iban, 'bank_routing', x.bank_routing, 'mol_person_id', x.mol_person_id, 'wps_bank', x.wps_bank),
      'pay', coalesce((SELECT jsonb_agg(jsonb_build_object('wage_code', p.wage_code, 'name', w.name, 'amount', p.amount, 'valid_from', p.valid_from,
                                                           'source', p.source) ORDER BY p.wage_code)
                         FROM erp._hr_pay_at(p_company, p_emp_id, v_today) p LEFT JOIN erp.wage_type w ON w.company_code = p_company AND w.code = p.wage_code
                        WHERE p.amount > 0), '[]'::jsonb),
      'pay_history', coalesce((SELECT jsonb_agg(jsonb_build_object('wage_code', h.wage_code, 'amount', h.amount, 'valid_from', h.valid_from, 'note', h.note)
                                                ORDER BY h.valid_from DESC, h.wage_code)
                                 FROM erp.hr_pay h WHERE h.company_code = p_company AND h.emp_id = p_emp_id), '[]'::jsonb),
      'ticket_entitlement', jsonb_build_object('ticket_value', x.ticket_value, 'ticket_every_months', x.ticket_every_months,
                                               'ticket_last_date', x.ticket_last_date),
      'gratuity', erp._hr_gratuity(p_company, p_emp_id, v_today),
      'ticket', erp._hr_ticket(p_company, p_emp_id, v_today));
    PERFORM erp._hr_salary_audit(p_company, 'employee', p_emp_id::text, jsonb_build_object('screen', 'employee', 'self', v_self));
  END IF;
  IF lvl IS NOT NULL THEN
    r := r || jsonb_build_object('history', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'detail', a.detail,
                                                                'actor', (SELECT display_name FROM erp.app_user au WHERE au.user_id::text = a.actor)) ORDER BY a.at DESC)
                                                       FROM (SELECT * FROM erp.audit_log WHERE company_code = p_company AND object = 'employee'
                                                               AND object_ref = p_emp_id::text AND action <> 'salary_view' ORDER BY at DESC LIMIT 30) a), '[]'::jsonb));
  END IF;
  RETURN r;
END $$;

-- ============ API: attendance ============
-- Check in or out with the browser's location. Outside the site area → flag 'outside_site' (rule "Check-in outside site area");
-- no location → 'no_location'; after shift start + grace → 'late'. The record is kept either way; HR sees the flags.
CREATE OR REPLACE FUNCTION erp.attendance_check(p_company varchar, p_kind text, p_lat numeric DEFAULT NULL, p_lng numeric DEFAULT NULL,
                                                p_accuracy numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u     erp.app_user;
  e     erp.employee;
  a     erp.hr_attendance;
  st    erp.hr_site;
  sh    erp.hr_shift;
  v_tz  text;
  v_now timestamp;
  v_day date;
  v_dist numeric;
  v_flags text[] := '{}';
  v_late integer := 0;
  v_msg text;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  e := erp._hr_me(p_company);
  IF e.emp_id IS NULL THEN
    RAISE EXCEPTION 'Your sign-in is not linked to an employee record in %. Ask HR to link it.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('in', 'out') THEN
    RAISE EXCEPTION 'Choose check in or check out.' USING ERRCODE = 'P0001';
  END IF;
  IF (p_lat IS NULL) <> (p_lng IS NULL) OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'The location sent by the phone is not valid. Try again.' USING ERRCODE = 'P0001';
  END IF;
  v_tz := coalesce((SELECT timezone FROM erp.hr_setting WHERE company_code = p_company), 'Asia/Dubai');
  v_now := now() AT TIME ZONE v_tz;
  v_day := v_now::date;
  SELECT * INTO a FROM erp.hr_attendance WHERE company_code = p_company AND emp_id = e.emp_id AND work_date = v_day FOR UPDATE;
  IF p_kind = 'in' AND a.att_id IS NOT NULL THEN
    RAISE EXCEPTION 'You already checked in today at %.', to_char(a.check_in_at AT TIME ZONE v_tz, 'HH24:MI') USING ERRCODE = 'P0001';
  END IF;
  IF p_kind = 'out' AND a.att_id IS NULL THEN
    RAISE EXCEPTION 'Check in first. There is no check-in for today.' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind = 'out' AND a.check_out_at IS NOT NULL THEN
    RAISE EXCEPTION 'You already checked out today at %.', to_char(a.check_out_at AT TIME ZONE v_tz, 'HH24:MI') USING ERRCODE = 'P0001';
  END IF;

  -- site: the employee's own, otherwise the nearest active one
  SELECT s.* INTO st FROM erp.hr_site s JOIN erp.hr_employee_extra x ON x.company_code = s.company_code AND x.site_code = s.site_code
   WHERE s.company_code = p_company AND x.emp_id = e.emp_id AND s.active;
  IF st.site_code IS NULL AND p_lat IS NOT NULL THEN
    SELECT * INTO st FROM erp.hr_site s WHERE s.company_code = p_company AND s.active
     ORDER BY erp._hr_distance_m(p_lat, p_lng, s.lat, s.lng) LIMIT 1;
  END IF;
  IF p_lat IS NULL THEN
    v_flags := v_flags || 'no_location'::text;
  ELSIF st.site_code IS NULL THEN
    v_flags := v_flags || 'no_site'::text;
  ELSE
    v_dist := round(erp._hr_distance_m(p_lat, p_lng, st.lat, st.lng));
    IF v_dist > st.radius_m THEN
      v_flags := v_flags || 'outside_site'::text;
    END IF;
  END IF;
  sh := erp._hr_shift_of(p_company, e.emp_id);
  IF p_kind = 'in' AND sh.shift_code IS NOT NULL AND v_now::time > sh.start_time + make_interval(mins => sh.grace_min) THEN
    v_late := floor(extract(epoch FROM (v_now::time - sh.start_time)) / 60)::integer;
    v_flags := v_flags || 'late'::text;
  END IF;
  IF p_kind = 'out' AND sh.shift_code IS NOT NULL AND v_now::time < sh.end_time THEN
    v_flags := v_flags || 'early_out'::text;
  END IF;

  IF p_kind = 'in' THEN
    INSERT INTO erp.hr_attendance (company_code, emp_id, work_date, shift_code, check_in_at, in_lat, in_lng, in_accuracy, in_site, in_distance_m, in_flags, late_min)
    VALUES (p_company, e.emp_id, v_day, sh.shift_code, now(), p_lat, p_lng, p_accuracy, st.site_code, v_dist, v_flags, v_late)
    RETURNING * INTO a;
  ELSE
    UPDATE erp.hr_attendance SET check_out_at = now(), out_lat = p_lat, out_lng = p_lng, out_accuracy = p_accuracy, out_site = st.site_code,
           out_distance_m = v_dist, out_flags = v_flags
     WHERE att_id = a.att_id RETURNING * INTO a;
  END IF;
  v_msg := CASE p_kind WHEN 'in' THEN 'Checked in at ' ELSE 'Checked out at ' END || to_char(v_now, 'HH24:MI') || '.';
  IF 'outside_site' = ANY (v_flags) THEN
    v_msg := v_msg || format(' Outside the site area: %s m from %s (allowed %s m). HR will see this under the rule "Check-in outside site area".',
                             v_dist, st.name, st.radius_m);
  ELSIF 'no_location' = ANY (v_flags) THEN
    v_msg := v_msg || ' No location was shared, so HR will see this check-in flagged.';
  END IF;
  IF 'late' = ANY (v_flags) THEN
    v_msg := v_msg || format(' %s minutes after the %s shift start (%s).', v_late, sh.name, to_char(sh.start_time, 'HH24:MI'));
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'attendance_check_' || p_kind, 'attendance', a.att_id::text,
          jsonb_build_object('emp_id', e.emp_id, 'work_date', v_day, 'flags', v_flags, 'distance_m', v_dist, 'site', st.site_code));
  RETURN jsonb_build_object('att_id', a.att_id, 'work_date', v_day, 'kind', p_kind, 'flags', v_flags, 'distance_m', v_dist,
                            'site_code', st.site_code, 'site_name', st.name, 'radius_m', st.radius_m, 'late_min', v_late, 'message', v_msg);
END $$;

-- Attendance list: own rows, or everyone's for HR (read or full). Owner-rights view with the access rule in WHERE.
CREATE OR REPLACE VIEW erp.attendance_list AS
SELECT a.att_id, a.company_code, a.emp_id, e.hr_code, concat_ws(' ', e.first_name, e.last_name) AS emp_name, e.division AS department,
       a.work_date, a.shift_code, a.check_in_at, a.check_out_at, a.in_site, a.in_distance_m, a.out_distance_m, a.late_min,
       a.in_flags, a.out_flags, array_to_string(a.in_flags || a.out_flags, ', ') AS flags,
       (cardinality(a.in_flags) + cardinality(a.out_flags)) > 0 AS flagged,
       ('outside_site' = ANY (a.in_flags) OR 'outside_site' = ANY (a.out_flags)) AS outside_site
  FROM erp.hr_attendance a JOIN erp.employee e ON e.company_code = a.company_code AND e.emp_id = a.emp_id
 WHERE erp.can_see(a.company_code) AND (erp.module_level('hr') IS NOT NULL OR a.emp_id = erp.my_emp(a.company_code));
REVOKE ALL ON erp.attendance_list FROM PUBLIC, anon;
GRANT SELECT ON erp.attendance_list TO authenticated;

-- ============ API: leave ============
-- Validate a leave request without saving. Returns {errors:[{field,message}], days, balance, steps:[…], emp_id}.
-- Steps: the employee's manager (one person: detail.for_user), then the HR approver position, then the owner position when
-- the leave is longer than hr_setting.long_leave_days.
CREATE OR REPLACE FUNCTION erp._leave_eval(p_company varchar, p_leave jsonb, p_user erp.app_user, p_exclude integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  errs   jsonb := '[]'::jsonb;
  steps  jsonb := '[]'::jsonb;
  e      erp.employee;
  me     erp.employee;
  t      erp.leave_type;
  pol    erp.hr_leave_policy;
  s      erp.hr_setting;
  mu     erp.app_user;
  v_from date := erp._date(p_leave->>'from_date');
  v_to   date := erp._date(p_leave->>'to_date');
  v_days numeric;
  v_bal  jsonb;
  v_ov   erp.leave_request;
  v_emp  integer := (nullif(p_leave->>'emp_id', ''))::integer;
  v_self boolean;
  v_name text;
BEGIN
  me := erp._hr_me(p_company);
  IF v_emp IS NULL OR v_emp = me.emp_id THEN
    IF me.emp_id IS NULL THEN
      RAISE EXCEPTION 'Your sign-in is not linked to an employee record in %. Ask HR to link it.', p_company USING ERRCODE = 'P0001';
    END IF;
    e := me;
  ELSE
    IF NOT coalesce(erp.can_write('hr'), false) THEN
      RAISE EXCEPTION 'Only HR with full access can request leave for another employee.' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = v_emp;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Employee % was not found in company %.', v_emp, p_company USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_self := e.emp_id = me.emp_id;
  SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company;

  IF nullif(p_leave->>'leave_code', '') IS NULL THEN
    errs := errs || jsonb_build_object('field', 'leave_code', 'message', 'Choose a leave type.');
  ELSE
    SELECT * INTO t FROM erp.leave_type WHERE company_code = p_company AND code = p_leave->>'leave_code';
    IF NOT FOUND THEN
      errs := errs || jsonb_build_object('field', 'leave_code', 'message', format('Leave type %s does not exist in %s.', p_leave->>'leave_code', p_company));
    ELSE
      SELECT * INTO pol FROM erp.hr_leave_policy WHERE company_code = p_company AND leave_code = t.code AND active;
      IF NOT FOUND THEN
        errs := errs || jsonb_build_object('field', 'leave_code', 'message',
                  format('%s is not set up for %s yet. Ask HR to add its policy in HR setup.', coalesce(t.name, t.code), p_company));
      END IF;
    END IF;
  END IF;
  IF v_from IS NULL THEN
    errs := errs || jsonb_build_object('field', 'from_date', 'message', 'Choose the first day of leave.');
  END IF;
  IF v_to IS NULL THEN
    errs := errs || jsonb_build_object('field', 'to_date', 'message', 'Choose the last day of leave.');
  END IF;
  IF v_from IS NOT NULL AND v_to IS NOT NULL AND v_to < v_from THEN
    errs := errs || jsonb_build_object('field', 'to_date', 'message', 'The last day can''t be before the first day.');
  ELSIF v_from IS NOT NULL AND v_to IS NOT NULL AND v_to - v_from > 366 THEN
    errs := errs || jsonb_build_object('field', 'to_date', 'message', 'A single request can''t be longer than a year.');
  END IF;
  IF v_from IS NOT NULL AND e.joined_on IS NOT NULL AND v_from < e.joined_on THEN
    errs := errs || jsonb_build_object('field', 'from_date', 'message', format('Leave can''t start before the joining date (%s).', erp._hr_d(e.joined_on)));
  END IF;
  IF s.company_code IS NULL OR s.hr_approver_position IS NULL THEN
    errs := errs || jsonb_build_object('field', NULL, 'message',
              format('Leave approval is not set up for %s. Ask HR to choose the HR approver position in HR setup.', p_company));
  END IF;

  IF jsonb_array_length(errs) = 0 THEN
    v_days := erp._hr_leave_days(p_company, v_from, v_to, pol.basis);
    IF v_days = 0 THEN
      errs := errs || jsonb_build_object('field', 'to_date', 'message', 'These dates fall on weekends or public holidays only. There is nothing to request.');
    END IF;
    IF t.max_days IS NOT NULL AND t.max_days > 0 AND v_days > t.max_days THEN
      errs := errs || jsonb_build_object('field', 'to_date', 'message',
                format('A single %s request can be at most %s days. This one is %s days.', coalesce(t.name, t.code), trim_scale(t.max_days), trim_scale(v_days)));
    END IF;
    IF t.min_days IS NOT NULL AND t.min_days > 0 AND v_days < t.min_days THEN
      errs := errs || jsonb_build_object('field', 'to_date', 'message',
                format('A %s request must be at least %s days.', coalesce(t.name, t.code), trim_scale(t.min_days)));
    END IF;
    SELECT * INTO v_ov FROM erp.leave_request
     WHERE company_code = p_company AND emp_id = e.emp_id AND state IN ('pending_approval', 'approved') AND request_id IS DISTINCT FROM p_exclude
       AND from_date <= v_to AND to_date >= v_from
     ORDER BY from_date LIMIT 1;
    IF v_ov.request_id IS NOT NULL THEN
      errs := errs || jsonb_build_object('field', 'from_date', 'message',
                format('%s already %s leave from %s to %s that overlaps these dates.', CASE WHEN v_self THEN 'You' ELSE 'This employee' END,
                       CASE WHEN v_self THEN 'have' ELSE 'has' END, erp._hr_d(v_ov.from_date), erp._hr_d(v_ov.to_date)));
    END IF;
    v_bal := erp._hr_leave_balance(p_company, e.emp_id, t.code, v_from);
    IF (v_bal->>'tracked')::boolean AND NOT coalesce(s.allow_negative_leave, false) AND v_days > (v_bal->>'available')::numeric THEN
      errs := errs || jsonb_build_object('field', 'to_date', 'message',
                format('Not enough %s: %s days left, this request needs %s days.', lower(coalesce(t.name, t.code)),
                       trim_scale((v_bal->>'available')::numeric), trim_scale(v_days)));
    END IF;
  END IF;

  -- approval steps
  IF e.manager_emp_id IS NOT NULL THEN
    SELECT * INTO mu FROM erp.app_user WHERE company_code = p_company AND emp_id = e.manager_emp_id AND active ORDER BY user_id LIMIT 1;
    IF mu.user_id IS NOT NULL AND mu.user_id <> p_user.user_id THEN
      v_name := coalesce(erp._hr_emp_name(p_company, e.manager_emp_id), mu.display_name);
      steps := steps || jsonb_build_object('step', 1, 'rule_code', 'leave_manager', 'approver_position', mu.position_code, 'for_user', mu.user_id,
                                           'approver_name', v_name, 'message', format('Manager approval by %s', v_name));
    END IF;
  END IF;
  IF s.hr_approver_position IS NOT NULL THEN
    steps := steps || jsonb_build_object('step', 2, 'rule_code', 'leave_hr', 'approver_position', s.hr_approver_position,
                                         'approver_name', (SELECT name FROM erp.position WHERE position_code = s.hr_approver_position),
                                         'message', 'HR approval');
  END IF;
  IF s.owner_position IS NOT NULL AND s.long_leave_days IS NOT NULL AND v_days > s.long_leave_days THEN
    steps := steps || jsonb_build_object('step', 3, 'rule_code', 'leave_long', 'approver_position', s.owner_position,
                                         'approver_name', (SELECT name FROM erp.position WHERE position_code = s.owner_position),
                                         'message', format('Long leave: %s days is more than %s days, so the owner approves too', trim_scale(v_days), trim_scale(s.long_leave_days)));
  END IF;
  RETURN jsonb_build_object('errors', errs, 'days', v_days, 'balance', v_bal, 'steps', steps, 'emp_id', e.emp_id,
                            'emp_name', erp._hr_emp_name(p_company, e.emp_id), 'basis', pol.basis);
END $$;

CREATE OR REPLACE FUNCTION erp.leave_checks(p_company varchar, p_leave jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE u erp.app_user;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  RETURN erp._leave_eval(p_company, coalesce(p_leave, '{}'::jsonb), u);
END $$;

CREATE OR REPLACE FUNCTION erp.leave_submit(p_company varchar, p_leave jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  ev jsonb;
  v_id integer;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  ev := erp._leave_eval(p_company, coalesce(p_leave, '{}'::jsonb), u);
  IF jsonb_array_length(ev->'errors') > 0 THEN
    RAISE EXCEPTION '%', ev->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  -- one request at a time per employee (overlap check above runs again under the lock)
  PERFORM 1 FROM erp.employee WHERE company_code = p_company AND emp_id = (ev->>'emp_id')::integer FOR UPDATE;
  ev := erp._leave_eval(p_company, p_leave, u);
  IF jsonb_array_length(ev->'errors') > 0 THEN
    RAISE EXCEPTION '%', ev->'errors'->0->>'message' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.leave_request (company_code, emp_id, leave_code, from_date, to_date, days, reason, requested_by)
  VALUES (p_company, (ev->>'emp_id')::integer, p_leave->>'leave_code', (p_leave->>'from_date')::date, (p_leave->>'to_date')::date,
          (ev->>'days')::numeric, nullif(btrim(p_leave->>'reason'), ''), u.user_id)
  RETURNING request_id INTO v_id;
  INSERT INTO erp.approval (company_code, object, object_ref, step, approver_position, rule_code, requested_by, requested_at, detail)
  SELECT p_company, 'leave', v_id::text, (x->>'step')::smallint, x->>'approver_position', x->>'rule_code', u.user_id, now(),
         jsonb_build_object('checks', jsonb_build_array(x), 'for_user', x->>'for_user')
    FROM jsonb_array_elements(ev->'steps') x;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'leave_submit', 'leave', v_id::text,
          jsonb_build_object('emp_id', ev->'emp_id', 'leave_code', p_leave->>'leave_code', 'from', p_leave->>'from_date', 'to', p_leave->>'to_date',
                             'days', ev->'days', 'steps', jsonb_array_length(ev->'steps')));
  RETURN jsonb_build_object('request_id', v_id, 'state', 'pending_approval', 'days', ev->'days', 'steps', ev->'steps');
END $$;

-- Approve or reject the current step. Managers need no HR access: the step names them (detail.for_user).
CREATE OR REPLACE FUNCTION erp.leave_decide(p_company varchar, p_request integer, p_decision text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  q   erp.leave_request;
  v_note text := nullif(btrim(p_note), '');
  v_step smallint;
  v_mine bigint[];
  v_who text;
  v_left integer;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  SELECT * INTO q FROM erp.leave_request WHERE company_code = p_company AND request_id = p_request FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Leave request % was not found in company %.', coalesce(p_request::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF q.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'This leave request is not waiting for approval.' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Choose approve or reject.' USING ERRCODE = 'P0001';
  END IF;
  IF q.requested_by = u.user_id OR coalesce(q.emp_id = erp.my_emp(p_company), false) THEN
    RAISE EXCEPTION 'You can''t decide your own leave request.' USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = 'leave' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded;
  SELECT array_agg(approval_id) INTO v_mine FROM erp.approval
   WHERE company_code = p_company AND object = 'leave' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded AND step = v_step
     AND approver_position = u.position_code AND (detail->>'for_user' IS NULL OR detail->>'for_user' = u.user_id::text);
  IF v_mine IS NULL THEN
    SELECT string_agg(DISTINCT coalesce(a.detail->'checks'->0->>'approver_name', p.name), ' or ') INTO v_who
      FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
     WHERE a.company_code = p_company AND a.object = 'leave' AND a.object_ref = p_request::text AND a.decision IS NULL AND NOT a.superseded AND a.step = v_step;
    RAISE EXCEPTION 'This leave request is waiting for approval from %. You can''t decide it.', coalesce(v_who, 'another person') USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Add a note saying why you are rejecting this leave request.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.approval SET decision = p_decision, approver_user = u.user_id, decided_at = now(), note = v_note WHERE approval_id = ANY (v_mine);
  IF p_decision = 'rejected' THEN
    UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = 'leave' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded;
    UPDATE erp.leave_request SET state = 'rejected', decided_at = now() WHERE request_id = p_request;
  ELSE
    SELECT count(*) INTO v_left FROM erp.approval WHERE company_code = p_company AND object = 'leave' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded;
    IF v_left = 0 THEN
      UPDATE erp.leave_request SET state = 'approved', decided_at = now() WHERE request_id = p_request;
    END IF;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, CASE WHEN p_decision = 'rejected' THEN 'leave_reject' ELSE 'leave_approve' END, 'leave', p_request::text,
          jsonb_build_object('step', v_step, 'note', v_note, 'open_steps', coalesce(v_left, 0)));
  RETURN jsonb_build_object('request_id', p_request,
                            'state', CASE WHEN p_decision = 'rejected' THEN 'rejected' WHEN v_left = 0 THEN 'approved' ELSE 'pending_approval' END,
                            'open_steps', coalesce(v_left, 0));
END $$;

-- Cancel: the requester or the employee (waiting, or approved and not started yet), or HR with full access.
CREATE OR REPLACE FUNCTION erp.leave_cancel(p_company varchar, p_request integer, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  q erp.leave_request;
  v_own boolean;
  v_today date;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  SELECT * INTO q FROM erp.leave_request WHERE company_code = p_company AND request_id = p_request FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Leave request % was not found in company %.', coalesce(p_request::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  v_own := q.requested_by = u.user_id OR coalesce(q.emp_id = erp.my_emp(p_company), false);
  IF NOT v_own AND NOT coalesce(erp.can_write('hr'), false) THEN
    RAISE EXCEPTION 'Only the employee or HR with full access can cancel this leave.' USING ERRCODE = '42501';
  END IF;
  IF q.state NOT IN ('pending_approval', 'approved') THEN
    RAISE EXCEPTION 'Only waiting or approved leave can be cancelled.' USING ERRCODE = 'P0001';
  END IF;
  v_today := (now() AT TIME ZONE coalesce((SELECT timezone FROM erp.hr_setting WHERE company_code = p_company), 'Asia/Dubai'))::date;
  IF q.state = 'approved' AND q.from_date <= v_today AND NOT coalesce(erp.can_write('hr'), false) THEN
    RAISE EXCEPTION 'This leave has already started. Ask HR to change it.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE erp.leave_request SET state = 'cancelled', cancelled_by = u.user_id, cancel_note = nullif(btrim(p_note), '') WHERE request_id = p_request;
  UPDATE erp.approval SET superseded = true WHERE company_code = p_company AND object = 'leave' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'leave_cancel', 'leave', p_request::text, jsonb_build_object('was', q.state, 'note', nullif(btrim(p_note), '')));
  RETURN jsonb_build_object('request_id', p_request, 'state', 'cancelled');
END $$;

-- One leave request with its approval steps, for the requester, the employee, their manager or HR.
CREATE OR REPLACE FUNCTION erp.leave_info(p_company varchar, p_request integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  q erp.leave_request;
  e erp.employee;
  v_me integer;
  v_step smallint;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  SELECT * INTO q FROM erp.leave_request WHERE company_code = p_company AND request_id = p_request;
  SELECT * INTO e FROM erp.employee WHERE company_code = p_company AND emp_id = q.emp_id;
  v_me := erp.my_emp(p_company);
  IF q.request_id IS NULL OR NOT coalesce(erp.module_level('hr') IS NOT NULL OR q.emp_id = v_me OR q.requested_by = u.user_id
                                  OR e.manager_emp_id = v_me
                                  OR EXISTS (SELECT 1 FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'leave'
                                               AND a.object_ref = p_request::text AND (a.detail->>'for_user' = u.user_id::text
                                                 OR (a.detail->>'for_user' IS NULL AND a.approver_position = u.position_code))), false) THEN
    RAISE EXCEPTION 'Leave request % was not found in company %.', coalesce(p_request::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT min(step) INTO v_step FROM erp.approval WHERE company_code = p_company AND object = 'leave' AND object_ref = p_request::text AND decision IS NULL AND NOT superseded;
  RETURN jsonb_build_object(
    'request', to_jsonb(q) || jsonb_build_object('emp_name', erp._hr_emp_name(p_company, q.emp_id), 'hr_code', e.hr_code, 'department', e.division,
                                                 'leave_name', (SELECT name FROM erp.leave_type t WHERE t.company_code = p_company AND t.code = q.leave_code),
                                                 'requested_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = q.requested_by)),
    'balance', erp._hr_leave_balance(p_company, q.emp_id, q.leave_code, q.from_date),
    'approvals', coalesce((SELECT jsonb_agg(jsonb_build_object('approval_id', a.approval_id, 'step', a.step, 'rule_code', a.rule_code,
                                   'approver_position', a.approver_position, 'approver_name', coalesce(a.detail->'checks'->0->>'approver_name', p.name),
                                   'message', a.detail->'checks'->0->>'message', 'decision', a.decision, 'note', a.note, 'decided_at', a.decided_at,
                                   'decided_by_name', du.display_name, 'superseded', a.superseded) ORDER BY a.step)
                             FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
                             LEFT JOIN erp.app_user du ON du.user_id = a.approver_user
                            WHERE a.company_code = p_company AND a.object = 'leave' AND a.object_ref = p_request::text), '[]'::jsonb),
    'can_decide', q.state = 'pending_approval' AND q.requested_by <> u.user_id AND q.emp_id IS DISTINCT FROM v_me
                  AND EXISTS (SELECT 1 FROM erp.approval a WHERE a.company_code = p_company AND a.object = 'leave' AND a.object_ref = p_request::text
                                AND a.decision IS NULL AND NOT a.superseded AND a.step = v_step AND a.approver_position = u.position_code
                                AND (a.detail->>'for_user' IS NULL OR a.detail->>'for_user' = u.user_id::text)),
    'can_cancel', q.state IN ('pending_approval', 'approved') AND (q.requested_by = u.user_id OR coalesce(q.emp_id = v_me, false) OR coalesce(erp.can_write('hr'), false)),
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'detail', a.detail,
                                 'actor', (SELECT display_name FROM erp.app_user au WHERE au.user_id::text = a.actor)) ORDER BY a.at)
                           FROM erp.audit_log a WHERE a.company_code = p_company AND a.object = 'leave' AND a.object_ref = p_request::text), '[]'::jsonb));
END $$;

-- Leave list: own requests, the team's (employees whose manager is me), or everyone's for HR. Owner-rights view, rule in WHERE.
CREATE OR REPLACE VIEW erp.leave_request_list AS
SELECT q.request_id, q.company_code, q.emp_id, e.hr_code, concat_ws(' ', e.first_name, e.last_name) AS emp_name, e.division AS department,
       q.leave_code, t.name AS leave_name, q.from_date, q.to_date, q.days, q.state, q.reason, q.requested_at, q.decided_at,
       (q.emp_id = erp.my_emp(q.company_code)) AS mine,
       (e.manager_emp_id = erp.my_emp(q.company_code)) AS my_team,
       (SELECT coalesce(a.detail->'checks'->0->>'approver_name', p.name) FROM erp.approval a JOIN erp.position p ON p.position_code = a.approver_position
         WHERE a.company_code = q.company_code AND a.object = 'leave' AND a.object_ref = q.request_id::text AND a.decision IS NULL AND NOT a.superseded
         ORDER BY a.step LIMIT 1) AS waiting_for
  FROM erp.leave_request q
  JOIN erp.employee e ON e.company_code = q.company_code AND e.emp_id = q.emp_id
  LEFT JOIN erp.leave_type t ON t.company_code = q.company_code AND t.code = q.leave_code
 WHERE erp.can_see(q.company_code)
   AND (erp.module_level('hr') IS NOT NULL OR q.emp_id = erp.my_emp(q.company_code) OR e.manager_emp_id = erp.my_emp(q.company_code));
REVOKE ALL ON erp.leave_request_list FROM PUBLIC, anon;
GRANT SELECT ON erp.leave_request_list TO authenticated;

-- ============ API: payroll ============
CREATE OR REPLACE FUNCTION erp._hr_period(p_period text) RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path = erp, pg_temp AS $$
BEGIN
  IF p_period IS NULL OR p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
    RAISE EXCEPTION 'Enter the payroll month as YYYY-MM, e.g. 2026-11.' USING ERRCODE = 'P0001';
  END IF;
  RETURN (p_period || '-01')::date;
END $$;

-- Add a payroll input for a month (HR full): overtime hours, unpaid days, a one-off deduction or earning (with its wage type).
CREATE OR REPLACE FUNCTION erp.payroll_input_save(p_company varchar, p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  r  erp.hr_payroll_run;
  w  erp.wage_type;
  v_period text := p_input->>'period';
  v_from date;
  v_kind text := p_input->>'kind';
  v_val numeric := erp._num(p_input->>'value');
  v_emp integer := (nullif(p_input->>'emp_id', ''))::integer;
  v_id integer;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  v_from := erp._hr_period(v_period);
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND period = v_period FOR UPDATE;
  IF r.state IN ('locked', 'posted') THEN
    RAISE EXCEPTION 'Payroll % is locked. Its inputs can''t change.', v_period USING ERRCODE = 'P0001';
  ELSIF r.state = 'reviewed' THEN
    RAISE EXCEPTION 'Payroll % is reviewed. Reopen it to change inputs.', v_period USING ERRCODE = 'P0001';
  END IF;
  IF v_emp IS NULL OR NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = v_emp) THEN
    RAISE EXCEPTION 'Choose the employee.' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IS NULL OR v_kind NOT IN ('overtime_hours', 'unpaid_days', 'deduction', 'earning') THEN
    RAISE EXCEPTION 'Choose what to enter: overtime hours, unpaid days, a deduction or an earning.' USING ERRCODE = 'P0001';
  END IF;
  IF v_val IS NULL OR v_val <= 0 THEN
    RAISE EXCEPTION 'Enter a value above 0.' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind = 'overtime_hours' AND v_val > 24 * 31 THEN
    RAISE EXCEPTION 'Overtime can''t be more than % hours in a month.', 24 * 31 USING ERRCODE = 'P0001';
  END IF;
  IF v_kind = 'unpaid_days' AND v_val > 31 THEN
    RAISE EXCEPTION 'Unpaid days can''t be more than 31 in a month.' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IN ('deduction', 'earning') THEN
    SELECT * INTO w FROM erp.wage_type WHERE company_code = p_company AND code = p_input->>'wage_code';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Choose the wage type for this %.', v_kind USING ERRCODE = 'P0001';
    END IF;
    IF (v_kind = 'deduction' AND NOT coalesce(w.is_deduction, false)) OR (v_kind = 'earning' AND NOT coalesce(w.is_earning, false))
       OR coalesce(w.calc_type, 'fixed') <> 'input' THEN
      RAISE EXCEPTION '% is not a monthly % wage type.', coalesce(w.name, w.code), v_kind USING ERRCODE = 'P0001';
    END IF;
  END IF;
  INSERT INTO erp.hr_payroll_input (company_code, period, emp_id, kind, wage_code, value, note, created_by)
  VALUES (p_company, v_period, v_emp, v_kind, CASE WHEN v_kind IN ('deduction', 'earning') THEN w.code END, round(v_val, 2),
          nullif(btrim(p_input->>'note'), ''), u.user_id)
  RETURNING input_id INTO v_id;
  UPDATE erp.hr_payroll_run SET stale = true WHERE run_id = r.run_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payroll_input_add', 'payroll', v_period, jsonb_build_object('input_id', v_id, 'emp_id', v_emp, 'kind', v_kind, 'wage_code', w.code));
  RETURN jsonb_build_object('input_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION erp.payroll_input_remove(p_company varchar, p_input_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  i erp.hr_payroll_input;
  r erp.hr_payroll_run;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  SELECT * INTO i FROM erp.hr_payroll_input WHERE company_code = p_company AND input_id = p_input_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll input % was not found.', coalesce(p_input_id::text, '(none)') USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND period = i.period FOR UPDATE;
  IF r.state IN ('reviewed', 'locked', 'posted') THEN
    RAISE EXCEPTION 'Payroll % is %. Its inputs can''t change.', i.period, r.state USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM erp.hr_payroll_input WHERE input_id = p_input_id;
  UPDATE erp.hr_payroll_run SET stale = true WHERE run_id = r.run_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payroll_input_remove', 'payroll', i.period, jsonb_build_object('input_id', p_input_id, 'emp_id', i.emp_id, 'kind', i.kind));
  RETURN jsonb_build_object('removed', p_input_id);
END $$;

-- Calculate (or recalculate) a month's payroll. Only a draft can be calculated.
--   fixed earnings × days paid / days in month (month_days_basis '30' or the calendar days)
--   unpaid leave: approved leave of loss-of-pay types in the month + unpaid-day inputs, × (basic or gross) / days in month
--   overtime: hours × (basic or gross) / days in month / hours per day × multiplier
--   one-off earnings and deductions from the inputs
CREATE OR REPLACE FUNCTION erp.payroll_calculate(p_company varchar, p_period text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u   erp.app_user;
  s   erp.hr_setting;
  r   erp.hr_payroll_run;
  e   record;
  p   record;
  i   record;
  v_from date; v_to date; v_dim numeric;
  st date; en date; v_paid numeric; v_ratio numeric;
  v_ln smallint; v_basic numeric; v_grossfull numeric; v_unpaid numeric; v_hours numeric; v_leave numeric;
  v_rate numeric; v_amt numeric; v_g numeric; v_d numeric; v_var numeric; v_fixed numeric;
  v_err jsonb; v_skip jsonb := '[]'::jsonb; v_n integer := 0;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  v_from := erp._hr_period(p_period);
  v_to := (v_from + interval '1 month' - interval '1 day')::date;
  SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company;
  IF s.month_days_basis IS NULL THEN
    RAISE EXCEPTION 'Payroll is not set up for %: choose the month-day basis in HR setup.', p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND period = p_period FOR UPDATE;
  IF r.state IN ('locked', 'posted') THEN
    RAISE EXCEPTION 'Payroll % is locked. Locked payroll can''t be recalculated.', p_period USING ERRCODE = 'P0001';
  ELSIF r.state = 'reviewed' THEN
    RAISE EXCEPTION 'Payroll % is reviewed. Reopen it before calculating again.', p_period USING ERRCODE = 'P0001';
  END IF;
  IF r.run_id IS NULL THEN
    INSERT INTO erp.hr_payroll_run (company_code, period, from_date, to_date, created_by) VALUES (p_company, p_period, v_from, v_to, u.user_id)
    RETURNING * INTO r;
  END IF;
  DELETE FROM erp.hr_payroll_line WHERE run_id = r.run_id;
  DELETE FROM erp.hr_payroll_emp WHERE run_id = r.run_id;
  v_dim := CASE s.month_days_basis WHEN '30' THEN 30 ELSE v_to - v_from + 1 END;

  FOR e IN SELECT em.*, x.wps_bank FROM erp.employee em
             LEFT JOIN erp.hr_employee_extra x ON x.company_code = em.company_code AND x.emp_id = em.emp_id
            WHERE em.company_code = p_company AND coalesce(em.joined_on, v_from) <= v_to AND (em.left_on IS NULL OR em.left_on >= v_from)
              AND (em.active OR em.left_on >= v_from)
            ORDER BY em.emp_id LOOP
    IF NOT EXISTS (SELECT 1 FROM erp._hr_pay_at(p_company, e.emp_id, v_to) pa JOIN erp.wage_type w ON w.company_code = p_company AND w.code = pa.wage_code
                    WHERE pa.amount > 0 AND w.is_earning) THEN
      v_skip := v_skip || jsonb_build_object('emp_id', e.emp_id, 'hr_code', e.hr_code, 'name', concat_ws(' ', e.first_name, e.last_name), 'reason', 'No pay is set.');
      CONTINUE;
    END IF;
    st := greatest(v_from, coalesce(e.joined_on, v_from));
    en := least(v_to, coalesce(e.left_on, v_to));
    v_paid := CASE WHEN st = v_from AND en = v_to THEN v_dim ELSE least(en - st + 1, v_dim) END;
    v_ratio := v_paid / v_dim;
    v_ln := 0; v_g := 0; v_d := 0; v_var := 0; v_err := '[]'::jsonb; v_basic := 0; v_grossfull := 0;
    -- fixed earnings
    FOR p IN SELECT pa.wage_code, pa.amount, w.name FROM erp._hr_pay_at(p_company, e.emp_id, v_to) pa
               JOIN erp.wage_type w ON w.company_code = p_company AND w.code = pa.wage_code
              WHERE pa.amount > 0 AND w.is_earning AND coalesce(w.calc_type, 'fixed') = 'fixed' ORDER BY (pa.wage_code <> 'BASIC'), pa.wage_code LOOP
      v_ln := v_ln + 1;
      v_amt := round(p.amount * v_ratio, 2);
      INSERT INTO erp.hr_payroll_line (run_id, emp_id, line_no, wage_code, name, kind, fixed, qty, rate, amount, note)
      VALUES (r.run_id, e.emp_id, v_ln, p.wage_code, p.name, 'earning', true, v_paid, p.amount, v_amt,
              CASE WHEN v_paid < v_dim THEN format('%s of %s days', trim_scale(v_paid), trim_scale(v_dim)) END);
      v_g := v_g + v_amt;
      v_grossfull := v_grossfull + p.amount;
      IF p.wage_code = 'BASIC' THEN v_basic := p.amount; END IF;
    END LOOP;
    -- leave in the month
    SELECT coalesce(sum(erp._hr_leave_days(p_company, greatest(q.from_date, st), least(q.to_date, en), coalesce(pol.basis, 'calendar'))), 0),
           coalesce(sum(erp._hr_leave_days(p_company, greatest(q.from_date, st), least(q.to_date, en), coalesce(pol.basis, 'calendar')))
                    FILTER (WHERE t.loss_of_pay), 0)
      INTO v_leave, v_unpaid
      FROM erp.leave_request q
      JOIN erp.leave_type t ON t.company_code = q.company_code AND t.code = q.leave_code
      LEFT JOIN erp.hr_leave_policy pol ON pol.company_code = q.company_code AND pol.leave_code = q.leave_code
     WHERE q.company_code = p_company AND q.emp_id = e.emp_id AND q.state = 'approved' AND q.from_date <= en AND q.to_date >= st;
    v_unpaid := v_unpaid + coalesce((SELECT sum(value) FROM erp.hr_payroll_input WHERE company_code = p_company AND period = p_period
                                       AND emp_id = e.emp_id AND kind = 'unpaid_days'), 0);
    IF v_unpaid > 0 THEN
      IF s.unpaid_wage_code IS NULL OR s.unpaid_basis IS NULL THEN
        v_err := v_err || to_jsonb('Unpaid leave can''t be deducted: set the unpaid-leave wage type and basis in HR setup.'::text);
      ELSE
        v_rate := round(CASE s.unpaid_basis WHEN 'basic' THEN v_basic ELSE v_grossfull END / v_dim, 4);
        v_amt := round(v_rate * v_unpaid, 2);
        v_ln := v_ln + 1;
        INSERT INTO erp.hr_payroll_line (run_id, emp_id, line_no, wage_code, name, kind, fixed, qty, rate, amount, note)
        VALUES (r.run_id, e.emp_id, v_ln, s.unpaid_wage_code, (SELECT name FROM erp.wage_type WHERE company_code = p_company AND code = s.unpaid_wage_code),
                'deduction', true, v_unpaid, v_rate, v_amt, format('%s unpaid days', trim_scale(v_unpaid)));
        v_d := v_d + v_amt;
      END IF;
    END IF;
    -- overtime
    v_hours := coalesce((SELECT sum(value) FROM erp.hr_payroll_input WHERE company_code = p_company AND period = p_period
                           AND emp_id = e.emp_id AND kind = 'overtime_hours'), 0);
    IF v_hours > 0 THEN
      IF s.ot_wage_code IS NULL OR s.ot_multiplier IS NULL OR s.ot_rate_basis IS NULL OR s.hours_per_day IS NULL THEN
        v_err := v_err || to_jsonb('Overtime can''t be paid: set the overtime rules (wage type, basis, multiplier, hours per day) in HR setup.'::text);
      ELSE
        v_rate := round(CASE s.ot_rate_basis WHEN 'basic' THEN v_basic ELSE v_grossfull END / v_dim / s.hours_per_day * s.ot_multiplier, 4);
        v_amt := round(v_rate * v_hours, 2);
        v_ln := v_ln + 1;
        INSERT INTO erp.hr_payroll_line (run_id, emp_id, line_no, wage_code, name, kind, fixed, qty, rate, amount, note)
        VALUES (r.run_id, e.emp_id, v_ln, s.ot_wage_code, (SELECT name FROM erp.wage_type WHERE company_code = p_company AND code = s.ot_wage_code),
                'earning', false, v_hours, v_rate, v_amt, format('%s hours × %s', trim_scale(v_hours), trim_scale(s.ot_multiplier)));
        v_g := v_g + v_amt;
        v_var := v_var + v_amt;
      END IF;
    END IF;
    -- one-off inputs
    FOR i IN SELECT pi.*, w.name FROM erp.hr_payroll_input pi JOIN erp.wage_type w ON w.company_code = pi.company_code AND w.code = pi.wage_code
              WHERE pi.company_code = p_company AND pi.period = p_period AND pi.emp_id = e.emp_id AND pi.kind IN ('earning', 'deduction')
              ORDER BY pi.input_id LOOP
      v_ln := v_ln + 1;
      INSERT INTO erp.hr_payroll_line (run_id, emp_id, line_no, wage_code, name, kind, fixed, amount, note)
      VALUES (r.run_id, e.emp_id, v_ln, i.wage_code, i.name, i.kind, false, i.value, i.note);
      IF i.kind = 'earning' THEN v_g := v_g + i.value; v_var := v_var + i.value; ELSE v_d := v_d + i.value; END IF;
    END LOOP;
    IF v_d > v_g THEN
      v_err := v_err || to_jsonb(format('Deductions (%s) are more than the pay (%s).', erp._money(v_d), erp._money(v_g)));
    END IF;
    v_fixed := v_g - v_d - v_var;
    IF v_fixed < 0 THEN v_var := greatest(v_g - v_d, 0); v_fixed := 0; END IF;
    INSERT INTO erp.hr_payroll_emp (run_id, emp_id, hr_code, name, department, wps_bank, days_in_period, days_paid, leave_days, unpaid_days,
                                    gross, deductions, net, fixed_income, variable_income, errors)
    VALUES (r.run_id, e.emp_id, e.hr_code, concat_ws(' ', e.first_name, e.last_name), e.division, e.wps_bank, v_dim, v_paid, v_leave, v_unpaid,
            v_g, v_d, v_g - v_d, v_fixed, v_var, v_err);
    v_n := v_n + 1;
  END LOOP;

  UPDATE erp.hr_payroll_run SET headcount = v_n, stale = false, skipped = v_skip, calculated_by = u.user_id, calculated_at = now(),
         gross = (SELECT coalesce(sum(gross), 0) FROM erp.hr_payroll_emp WHERE run_id = r.run_id),
         deductions = (SELECT coalesce(sum(deductions), 0) FROM erp.hr_payroll_emp WHERE run_id = r.run_id),
         net = (SELECT coalesce(sum(net), 0) FROM erp.hr_payroll_emp WHERE run_id = r.run_id)
   WHERE run_id = r.run_id RETURNING * INTO r;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payroll_calculate', 'payroll', r.run_id::text,
          jsonb_build_object('period', p_period, 'headcount', v_n, 'skipped', jsonb_array_length(v_skip), 'net', r.net));
  RETURN jsonb_build_object('run_id', r.run_id, 'period', p_period, 'state', r.state, 'headcount', v_n, 'gross', r.gross,
                            'deductions', r.deductions, 'net', r.net, 'skipped', v_skip,
                            'errors', (SELECT count(*) FROM erp.hr_payroll_emp WHERE run_id = r.run_id AND jsonb_array_length(errors) > 0));
END $$;

-- Everything the payroll page needs (HR full, audited).
CREATE OR REPLACE FUNCTION erp.payroll_info(p_company varchar, p_run_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  r erp.hr_payroll_run;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND run_id = p_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll run % was not found in company %.', coalesce(p_run_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  PERFORM erp._hr_salary_audit(p_company, 'payroll', p_run_id::text, jsonb_build_object('period', r.period));
  RETURN jsonb_build_object(
    'run', to_jsonb(r) || jsonb_build_object('currency', (SELECT currency FROM erp.company WHERE company_code = p_company),
                                             'calculated_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = r.calculated_by),
                                             'reviewed_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = r.reviewed_by),
                                             'locked_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = r.locked_by),
                                             'posted_by_name', (SELECT display_name FROM erp.app_user WHERE user_id = r.posted_by)),
    'employees', coalesce((SELECT jsonb_agg(to_jsonb(pe) || jsonb_build_object('lines',
                             (SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.line_no), '[]'::jsonb) FROM erp.hr_payroll_line l
                               WHERE l.run_id = pe.run_id AND l.emp_id = pe.emp_id)) ORDER BY pe.hr_code)
                             FROM erp.hr_payroll_emp pe WHERE pe.run_id = p_run_id), '[]'::jsonb),
    'inputs', coalesce((SELECT jsonb_agg(to_jsonb(i) || jsonb_build_object('emp_name', erp._hr_emp_name(p_company, i.emp_id),
                                                                      'hr_code', (SELECT hr_code FROM erp.employee e WHERE e.company_code = p_company AND e.emp_id = i.emp_id))
                                         ORDER BY i.input_id)
                          FROM erp.hr_payroll_input i WHERE i.company_code = p_company AND i.period = r.period), '[]'::jsonb),
    'banks', coalesce((SELECT jsonb_agg(jsonb_build_object('bank_code', b.bank_code, 'name', b.name) ORDER BY b.bank_code)
                         FROM erp.hr_wps_bank b WHERE b.company_code = p_company AND b.active), '[]'::jsonb),
    'journal', CASE WHEN r.trans_id IS NULL THEN NULL ELSE
                 (SELECT jsonb_agg(jsonb_build_object('acct_code', l.acct_code, 'name', a.name, 'debit', l.debit, 'credit', l.credit) ORDER BY l.line_id)
                    FROM erp.journal_line l LEFT JOIN erp.account a ON a.company_code = l.company_code AND a.acct_code = l.acct_code
                   WHERE l.company_code = p_company AND l.trans_id = r.trans_id) END,
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'detail', a.detail,
                                 'actor', (SELECT display_name FROM erp.app_user au WHERE au.user_id::text = a.actor)) ORDER BY a.at)
                           FROM erp.audit_log a WHERE a.company_code = p_company AND a.object = 'payroll' AND a.object_ref = p_run_id::text
                            AND a.action <> 'salary_view'), '[]'::jsonb));
END $$;

-- Review (draft → reviewed), reopen (reviewed → draft), lock (reviewed → locked). Locked payroll shows as payslips.
CREATE OR REPLACE FUNCTION erp.payroll_step(p_company varchar, p_run_id integer, p_action text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  r erp.hr_payroll_run;
  v_bad integer;
  v_new text;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND run_id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll run % was not found in company %.', coalesce(p_run_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO v_bad FROM erp.hr_payroll_emp WHERE run_id = p_run_id AND jsonb_array_length(errors) > 0;
  IF p_action = 'review' THEN
    IF r.state <> 'draft' THEN
      RAISE EXCEPTION 'Only a draft payroll can be reviewed. Payroll % is %.', r.period, r.state USING ERRCODE = 'P0001';
    END IF;
    IF r.calculated_at IS NULL OR r.stale THEN
      RAISE EXCEPTION 'Inputs changed after the last calculation. Calculate payroll % again before review.', r.period USING ERRCODE = 'P0001';
    END IF;
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'Fix the problems on % employee(s) before review.', v_bad USING ERRCODE = 'P0001';
    END IF;
    v_new := 'reviewed';
    UPDATE erp.hr_payroll_run SET state = v_new, reviewed_by = u.user_id, reviewed_at = now() WHERE run_id = p_run_id;
  ELSIF p_action = 'reopen' THEN
    IF r.state <> 'reviewed' THEN
      RAISE EXCEPTION 'Only a reviewed payroll can be reopened. Locked payroll can''t be reopened.' USING ERRCODE = 'P0001';
    END IF;
    v_new := 'draft';
    UPDATE erp.hr_payroll_run SET state = v_new, reviewed_by = NULL, reviewed_at = NULL WHERE run_id = p_run_id;
  ELSIF p_action = 'lock' THEN
    IF r.state <> 'reviewed' THEN
      RAISE EXCEPTION 'Review payroll % before locking it.', r.period USING ERRCODE = 'P0001';
    END IF;
    v_new := 'locked';
    UPDATE erp.hr_payroll_run SET state = v_new, locked_by = u.user_id, locked_at = now() WHERE run_id = p_run_id;
  ELSE
    RAISE EXCEPTION 'Choose review, reopen or lock.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payroll_' || p_action, 'payroll', p_run_id::text, jsonb_build_object('period', r.period, 'from', r.state, 'to', v_new));
  RETURN jsonb_build_object('run_id', p_run_id, 'state', v_new);
END $$;

-- Post a locked payroll through A3 (erp.post_journal): debit each earning's wage-type account, credit each deduction's account,
-- credit the net to hr_setting.payable_acct.
CREATE OR REPLACE FUNCTION erp.payroll_post(p_company varchar, p_run_id integer, p_date date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  r erp.hr_payroll_run;
  s erp.hr_setting;
  v_missing text;
  v_lines jsonb;
  v_trans integer;
  v_date date;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND run_id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll run % was not found in company %.', coalesce(p_run_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  IF r.state = 'posted' THEN
    RAISE EXCEPTION 'Payroll % is already posted (journal %).', r.period, r.trans_id USING ERRCODE = 'P0001';
  END IF;
  IF r.state <> 'locked' THEN
    RAISE EXCEPTION 'Lock payroll % before posting it.', r.period USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company;
  IF s.payable_acct IS NULL THEN
    RAISE EXCEPTION 'The salaries payable account is not set for %. Ask Finance to set it in HR setup.', p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT string_agg(DISTINCT l.wage_code, ', ') INTO v_missing
    FROM erp.hr_payroll_line l LEFT JOIN erp.wage_type w ON w.company_code = p_company AND w.code = l.wage_code
   WHERE l.run_id = p_run_id AND w.gl_account IS NULL;
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'Wage type % has no G/L account. Set it before posting.', v_missing USING ERRCODE = 'P0001';
  END IF;
  v_date := coalesce(p_date, r.to_date);
  SELECT jsonb_agg(x ORDER BY ord, x->>'acct_code') INTO v_lines FROM (
    SELECT 1 AS ord, jsonb_build_object('acct_code', w.gl_account, 'debit', sum(l.amount), 'credit', 0, 'memo', 'Payroll ' || r.period || ' earnings') AS x
      FROM erp.hr_payroll_line l JOIN erp.wage_type w ON w.company_code = p_company AND w.code = l.wage_code
     WHERE l.run_id = p_run_id AND l.kind = 'earning' GROUP BY w.gl_account HAVING sum(l.amount) <> 0
    UNION ALL
    SELECT 2, jsonb_build_object('acct_code', w.gl_account, 'debit', 0, 'credit', sum(l.amount), 'memo', 'Payroll ' || r.period || ' deductions')
      FROM erp.hr_payroll_line l JOIN erp.wage_type w ON w.company_code = p_company AND w.code = l.wage_code
     WHERE l.run_id = p_run_id AND l.kind = 'deduction' GROUP BY w.gl_account HAVING sum(l.amount) <> 0
    UNION ALL
    SELECT 3, jsonb_build_object('acct_code', s.payable_acct, 'debit', 0, 'credit', r.net, 'memo', 'Payroll ' || r.period || ' net pay') WHERE r.net <> 0
  ) q;
  v_trans := erp.post_journal(p_company, v_date, 'Payroll ' || r.period, v_lines,
                              jsonb_build_object('trans_type', 30, 'ref1', 'PAYROLL-' || r.period, 'base_ref', p_run_id::text, 'action', 'payroll_post',
                                                 'object', 'payroll', 'object_ref', p_run_id::text));
  UPDATE erp.hr_payroll_run SET state = 'posted', trans_id = v_trans, posted_by = u.user_id, posted_at = now() WHERE run_id = p_run_id;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'payroll_post', 'payroll', p_run_id::text, jsonb_build_object('period', r.period, 'trans_id', v_trans, 'net', r.net));
  RETURN jsonb_build_object('run_id', p_run_id, 'state', 'posted', 'trans_id', v_trans);
END $$;

-- Payroll runs (HR full only: totals are salary data). Owner-rights view, rule in WHERE.
CREATE OR REPLACE VIEW erp.payroll_run_list AS
SELECT r.run_id, r.company_code, r.period, r.from_date, r.to_date, r.state, r.stale, r.headcount, r.gross, r.deductions, r.net,
       c.currency, r.calculated_at, r.locked_at, r.posted_at, r.trans_id
  FROM erp.hr_payroll_run r JOIN erp.company c ON c.company_code = r.company_code
 WHERE erp.can_see(r.company_code) AND coalesce(erp.can_write('hr'), false);
REVOKE ALL ON erp.payroll_run_list FROM PUBLIC, anon;
GRANT SELECT ON erp.payroll_run_list TO authenticated;

-- ============ API: WPS salary information file (SIF) ============
-- Layout (UAE WPS SIF, as commonly published; confirm with the bank):
--   EDR,<employee MOHRE ID>,<employee bank routing>,<IBAN>,<pay start YYYY-MM-DD>,<pay end>,<days paid>,<fixed income>,<variable income>,<days on leave>
--   SCR,<employer MOHRE ID>,<employer bank routing>,<file date YYYY-MM-DD>,<file time HHMM>,<salary month MMYYYY>,<EDR count>,<total>,<currency>,<employer ref>
-- File name <employer ID><YYMMDDHHMMSS>.SIF. Field lengths come from hr_setting (wps_*_len).
CREATE OR REPLACE FUNCTION erp._wps_build(p_company varchar, p_run_id integer, p_bank text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  r erp.hr_payroll_run;
  s erp.hr_setting;
  b erp.hr_wps_bank;
  c erp.company;
  e record;
  errs jsonb := '[]'::jsonb;
  v_rows text[] := '{}';
  v_n integer := 0;
  v_total numeric := 0;
  v_now timestamp;
  v_nbanks integer;
BEGIN
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND run_id = p_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll run % was not found in company %.', coalesce(p_run_id::text, '(none)'), p_company USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company;
  SELECT * INTO c FROM erp.company WHERE company_code = p_company;
  SELECT * INTO b FROM erp.hr_wps_bank WHERE company_code = p_company AND bank_code = p_bank AND active;
  SELECT count(*) INTO v_nbanks FROM erp.hr_wps_bank WHERE company_code = p_company AND active;
  v_now := now() AT TIME ZONE coalesce(s.timezone, 'Asia/Dubai');
  IF r.state NOT IN ('locked', 'posted') THEN
    errs := errs || jsonb_build_object('field', 'run', 'message', format('Lock payroll %s before making the WPS file.', r.period));
  END IF;
  IF b.bank_code IS NULL THEN
    errs := errs || jsonb_build_object('field', 'bank', 'message', format('WPS bank %s is not set up for %s.', coalesce(p_bank, '(none)'), p_company));
  ELSIF b.employer_routing IS NULL OR b.employer_routing !~ '^[0-9]+$' OR (s.wps_routing_len IS NOT NULL AND length(b.employer_routing) <> s.wps_routing_len) THEN
    errs := errs || jsonb_build_object('field', 'bank', 'message', format('The employer routing code of %s must be %s digits.', b.name, coalesce(s.wps_routing_len::text, 'set and only')));
  END IF;
  IF s.wps_employer_id_len IS NULL OR s.wps_person_id_len IS NULL OR s.wps_routing_len IS NULL THEN
    errs := errs || jsonb_build_object('field', 'setting', 'message', format('The WPS file format is not set for %s. Ask HR to set the field lengths in HR setup.', p_company));
  END IF;
  IF s.employer_mol_id IS NULL OR s.employer_mol_id !~ '^[0-9]+$' OR (s.wps_employer_id_len IS NOT NULL AND length(s.employer_mol_id) <> s.wps_employer_id_len) THEN
    errs := errs || jsonb_build_object('field', 'setting', 'message', format('The employer MOHRE ID must be %s digits. Set it in HR setup.', coalesce(s.wps_employer_id_len::text, 'set and only')));
  END IF;
  FOR e IN SELECT pe.*, x.iban, x.bank_routing, x.mol_person_id, coalesce(x.wps_bank, CASE WHEN v_nbanks = 1 THEN p_bank END) AS bank
             FROM erp.hr_payroll_emp pe LEFT JOIN erp.hr_employee_extra x ON x.company_code = p_company AND x.emp_id = pe.emp_id
            WHERE pe.run_id = p_run_id ORDER BY pe.hr_code LOOP
    IF e.bank IS NULL THEN
      errs := errs || jsonb_build_object('field', 'employee', 'emp_id', e.emp_id, 'message', format('%s %s: no WPS bank is set.', e.hr_code, e.name));
      CONTINUE;
    END IF;
    CONTINUE WHEN e.bank <> p_bank;
    IF e.mol_person_id IS NULL OR e.mol_person_id !~ '^[0-9]+$' OR length(e.mol_person_id) <> coalesce(s.wps_person_id_len, -1) THEN
      errs := errs || jsonb_build_object('field', 'employee', 'emp_id', e.emp_id,
                'message', format('%s %s: the MOHRE personal number must be %s digits.', e.hr_code, e.name, coalesce(s.wps_person_id_len::text, '(not set)')));
    END IF;
    IF e.bank_routing IS NULL OR e.bank_routing !~ '^[0-9]+$' OR length(e.bank_routing) <> coalesce(s.wps_routing_len, -1) THEN
      errs := errs || jsonb_build_object('field', 'employee', 'emp_id', e.emp_id,
                'message', format('%s %s: the bank routing code must be %s digits.', e.hr_code, e.name, coalesce(s.wps_routing_len::text, '(not set)')));
    END IF;
    IF e.iban IS NULL OR NOT erp._hr_iban_ok(e.iban) OR e.iban !~ '^AE[0-9]{21}$' THEN
      errs := errs || jsonb_build_object('field', 'employee', 'emp_id', e.emp_id, 'message', format('%s %s: the IBAN is missing or not a valid UAE IBAN.', e.hr_code, e.name));
    END IF;
    IF e.net <= 0 THEN
      errs := errs || jsonb_build_object('field', 'employee', 'emp_id', e.emp_id, 'message', format('%s %s: the net pay is 0.', e.hr_code, e.name));
    END IF;
    v_rows := v_rows || concat_ws(',', 'EDR', e.mol_person_id, e.bank_routing, e.iban, to_char(r.from_date, 'YYYY-MM-DD'), to_char(r.to_date, 'YYYY-MM-DD'),
                                  trim_scale(e.days_paid)::text, to_char(e.fixed_income, 'FM9999999990.00'), to_char(e.variable_income, 'FM9999999990.00'),
                                  trim_scale(e.leave_days)::text);
    v_n := v_n + 1;
    v_total := v_total + e.fixed_income + e.variable_income;
  END LOOP;
  IF v_n = 0 THEN
    errs := errs || jsonb_build_object('field', 'bank', 'message', format('No employee in payroll %s is paid through %s.', r.period, coalesce(b.name, p_bank)));
  END IF;
  v_rows := v_rows || concat_ws(',', 'SCR', s.employer_mol_id, b.employer_routing, to_char(v_now, 'YYYY-MM-DD'), to_char(v_now, 'HH24MI'),
                                to_char(r.from_date, 'MMYYYY'), v_n::text, to_char(v_total, 'FM9999999990.00'), c.currency, coalesce(b.employer_ref, ''));
  RETURN jsonb_build_object('errors', errs, 'count', v_n, 'total', v_total, 'currency', c.currency, 'bank', p_bank, 'period', r.period,
                            'file_name', coalesce(s.employer_mol_id, 'EMPLOYER') || to_char(v_now, 'YYMMDDHH24MISS') || '.SIF',
                            'content', array_to_string(v_rows, E'\r\n') || E'\r\n');
END $$;

CREATE OR REPLACE FUNCTION erp.wps_check(p_company varchar, p_run_id integer, p_bank text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  w jsonb;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  w := erp._wps_build(p_company, p_run_id, p_bank);
  PERFORM erp._hr_salary_audit(p_company, 'payroll', p_run_id::text, jsonb_build_object('screen', 'wps_check', 'bank', p_bank));
  RETURN w - 'content' - 'file_name';
END $$;

CREATE OR REPLACE FUNCTION erp.wps_file(p_company varchar, p_run_id integer, p_bank text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  w jsonb;
BEGIN
  u := erp._hr_guard(p_company, 'salary');
  w := erp._wps_build(p_company, p_run_id, p_bank);
  IF jsonb_array_length(w->'errors') > 0 THEN
    RAISE EXCEPTION '%', w->'errors'->0->>'message' USING ERRCODE = 'P0001',
      HINT = CASE WHEN jsonb_array_length(w->'errors') > 1 THEN format('%s more problem(s). Run the WPS check to see them all.', jsonb_array_length(w->'errors') - 1) ELSE '' END;
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'wps_export', 'payroll', p_run_id::text,
          jsonb_build_object('bank', p_bank, 'file_name', w->>'file_name', 'count', w->'count', 'total', w->'total'));
  RETURN w - 'errors';
END $$;

-- ============ API: Staff Portal ============
CREATE OR REPLACE FUNCTION erp.portal_me(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  e  erp.employee;
  sh erp.hr_shift;
  v_tz text;
  v_today date;
  r jsonb;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  e := erp._hr_me(p_company);
  IF e.emp_id IS NULL THEN
    RETURN jsonb_build_object('linked', false, 'display_name', u.display_name);
  END IF;
  v_tz := coalesce((SELECT timezone FROM erp.hr_setting WHERE company_code = p_company), 'Asia/Dubai');
  v_today := (now() AT TIME ZONE v_tz)::date;
  sh := erp._hr_shift_of(p_company, e.emp_id);
  r := jsonb_build_object(
    'linked', true, 'today', v_today, 'timezone', v_tz,
    'employee', jsonb_build_object('emp_id', e.emp_id, 'hr_code', e.hr_code, 'name', concat_ws(' ', e.first_name, e.last_name), 'job_title', e.job_title,
                                   'department', e.division, 'mobile', e.mobile, 'email', e.email, 'joined_on', e.joined_on, 'nationality', e.nationality,
                                   'manager_name', erp._hr_emp_name(p_company, e.manager_emp_id), 'source', e.source),
    'shift', to_jsonb(sh),
    'site', (SELECT to_jsonb(s) FROM erp.hr_site s JOIN erp.hr_employee_extra x ON x.company_code = s.company_code AND x.site_code = s.site_code
              WHERE x.company_code = p_company AND x.emp_id = e.emp_id),
    'duties', coalesce((SELECT jsonb_agg(jsonb_build_object('duty_id', d.duty_id, 'title', d.title, 'detail', d.detail, 'shift_code', d.shift_code) ORDER BY d.sort, d.duty_id)
                          FROM erp.hr_duty d WHERE d.company_code = p_company AND d.active AND d.department = e.division), '[]'::jsonb),
    'attendance_today', (SELECT jsonb_build_object('check_in_at', a.check_in_at, 'check_out_at', a.check_out_at, 'in_flags', a.in_flags,
                                                   'out_flags', a.out_flags, 'late_min', a.late_min, 'in_distance_m', a.in_distance_m)
                           FROM erp.hr_attendance a WHERE a.company_code = p_company AND a.emp_id = e.emp_id AND a.work_date = v_today),
    'attendance', coalesce((SELECT jsonb_agg(jsonb_build_object('work_date', a.work_date, 'check_in_at', a.check_in_at, 'check_out_at', a.check_out_at,
                                                                'flags', a.in_flags || a.out_flags) ORDER BY a.work_date DESC)
                              FROM (SELECT * FROM erp.hr_attendance WHERE company_code = p_company AND emp_id = e.emp_id ORDER BY work_date DESC LIMIT 7) a), '[]'::jsonb),
    'balances', erp._hr_balances(p_company, e.emp_id, v_today),
    'leave_types', coalesce((SELECT jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'basis', p.basis) ORDER BY t.code)
                               FROM erp.leave_type t JOIN erp.hr_leave_policy p ON p.company_code = t.company_code AND p.leave_code = t.code AND p.active
                              WHERE t.company_code = p_company), '[]'::jsonb),
    'requests', coalesce((SELECT jsonb_agg(jsonb_build_object('request_id', q.request_id, 'leave_code', q.leave_code, 'from_date', q.from_date,
                                                              'to_date', q.to_date, 'days', q.days, 'state', q.state) ORDER BY q.from_date DESC)
                            FROM (SELECT * FROM erp.leave_request WHERE company_code = p_company AND emp_id = e.emp_id ORDER BY from_date DESC LIMIT 20) q), '[]'::jsonb),
    'payslips', coalesce((SELECT jsonb_agg(jsonb_build_object('run_id', pr.run_id, 'period', pr.period, 'net', pe.net, 'state', pr.state) ORDER BY pr.period DESC)
                            FROM erp.hr_payroll_run pr JOIN erp.hr_payroll_emp pe ON pe.run_id = pr.run_id AND pe.emp_id = e.emp_id
                           WHERE pr.company_code = p_company AND pr.state IN ('locked', 'posted')), '[]'::jsonb),
    'documents', coalesce((SELECT jsonb_agg(jsonb_build_object('doc_id', d.doc_id, 'doc_type', d.doc_type, 'doc_no', d.doc_no, 'expires_on', d.expires_on,
                                                               'storage_path', d.storage_path, 'file_name', d.file_name,
                                                               'days_left', d.expires_on - v_today) ORDER BY d.expires_on NULLS LAST)
                             FROM erp.hr_document d WHERE d.company_code = p_company AND d.emp_id = e.emp_id AND d.active), '[]'::jsonb),
    'team_waiting', (SELECT count(*) FROM erp.approval a
                      WHERE a.company_code = p_company AND a.object = 'leave' AND a.decision IS NULL AND NOT a.superseded
                        AND a.detail->>'for_user' = u.user_id::text),
    'is_manager', EXISTS (SELECT 1 FROM erp.employee m WHERE m.company_code = p_company AND m.manager_emp_id = e.emp_id),
    'currency', (SELECT currency FROM erp.company WHERE company_code = p_company));
  IF jsonb_array_length(r->'payslips') > 0 THEN
    PERFORM erp._hr_salary_audit(p_company, 'employee', e.emp_id::text, jsonb_build_object('screen', 'portal', 'self', true));
  END IF;
  RETURN r;
END $$;

-- One payslip: the employee's own (locked or posted payroll), or any employee's for HR full. Audited.
CREATE OR REPLACE FUNCTION erp.portal_payslip(p_company varchar, p_run_id integer, p_emp_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u  erp.app_user;
  r  erp.hr_payroll_run;
  pe erp.hr_payroll_emp;
  v_emp integer;
  v_self boolean;
BEGIN
  u := erp._hr_guard(p_company, 'any');
  v_emp := coalesce(p_emp_id, erp.my_emp(p_company));
  v_self := coalesce(v_emp = erp.my_emp(p_company), false);
  IF v_emp IS NULL THEN
    RAISE EXCEPTION 'Your sign-in is not linked to an employee record in %. Ask HR to link it.', p_company USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_self AND NOT coalesce(erp.can_write('hr'), false) THEN
    RAISE EXCEPTION 'Salary and payroll are for HR positions with full access only.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO r FROM erp.hr_payroll_run WHERE company_code = p_company AND run_id = p_run_id;
  SELECT * INTO pe FROM erp.hr_payroll_emp WHERE run_id = p_run_id AND emp_id = v_emp;
  IF r.run_id IS NULL OR pe.emp_id IS NULL OR (v_self AND r.state NOT IN ('locked', 'posted')) THEN
    RAISE EXCEPTION 'This payslip is not available.' USING ERRCODE = 'P0001';
  END IF;
  PERFORM erp._hr_salary_audit(p_company, 'payslip', v_emp::text, jsonb_build_object('run_id', p_run_id, 'period', r.period, 'self', v_self));
  RETURN jsonb_build_object('period', r.period, 'from_date', r.from_date, 'to_date', r.to_date, 'state', r.state,
                            'company', (SELECT jsonb_build_object('code', c.company_code, 'name', c.legal_name, 'currency', c.currency)
                                          FROM erp.company c WHERE c.company_code = p_company),
                            'employee', to_jsonb(pe),
                            'job_title', (SELECT job_title FROM erp.employee WHERE company_code = p_company AND emp_id = v_emp),
                            'lines', (SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.line_no), '[]'::jsonb) FROM erp.hr_payroll_line l
                                       WHERE l.run_id = p_run_id AND l.emp_id = v_emp));
END $$;

-- ============ API: setup ============
CREATE OR REPLACE FUNCTION erp.hr_setup(p_company varchar) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  u := erp._hr_guard(p_company, 'read');
  RETURN jsonb_build_object(
    'setting', (SELECT to_jsonb(s) FROM erp.hr_setting s WHERE s.company_code = p_company),
    'sites', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.site_code) FROM erp.hr_site s WHERE s.company_code = p_company), '[]'::jsonb),
    'shifts', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.shift_code) FROM erp.hr_shift s WHERE s.company_code = p_company), '[]'::jsonb),
    'duties', coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.department, d.sort, d.duty_id) FROM erp.hr_duty d WHERE d.company_code = p_company), '[]'::jsonb),
    'holidays', coalesce((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.day) FROM erp.hr_holiday h WHERE h.company_code = p_company), '[]'::jsonb),
    'leave_types', coalesce((SELECT jsonb_agg(to_jsonb(t) || jsonb_build_object('policy', to_jsonb(p)) ORDER BY t.code)
                               FROM erp.leave_type t LEFT JOIN erp.hr_leave_policy p ON p.company_code = t.company_code AND p.leave_code = t.code
                              WHERE t.company_code = p_company), '[]'::jsonb),
    'wage_types', coalesce((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.code) FROM erp.wage_type w WHERE w.company_code = p_company), '[]'::jsonb),
    'wps_banks', coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.bank_code) FROM erp.hr_wps_bank b WHERE b.company_code = p_company), '[]'::jsonb),
    'positions', coalesce((SELECT jsonb_agg(jsonb_build_object('code', p.position_code, 'name', p.name) ORDER BY p.name) FROM erp.position p), '[]'::jsonb),
    'departments', coalesce((SELECT jsonb_agg(DISTINCT e.division) FROM erp.employee e WHERE e.company_code = p_company AND e.division IS NOT NULL), '[]'::jsonb),
    'employees', coalesce((SELECT jsonb_agg(jsonb_build_object('emp_id', e.emp_id, 'hr_code', e.hr_code, 'name', concat_ws(' ', e.first_name, e.last_name),
                                                               'department', e.division) ORDER BY e.hr_code)
                             FROM erp.employee e WHERE e.company_code = p_company AND e.active), '[]'::jsonb),
    'branches', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.branch_id, 'name', b.name) ORDER BY b.branch_id) FROM erp.branch b WHERE b.company_code = p_company), '[]'::jsonb),
    'can_edit', coalesce(erp.can_write('hr'), false),
    'can_payroll', coalesce(erp.can_write('hr'), false),
    'can_set_account', coalesce(erp.can_write('finance'), false));
END $$;

-- Save one setup row (HR full). p_kind: setting | site | shift | duty | holiday | holiday_remove | policy | wps_bank | leave_adjust.
-- The payroll payable account needs full Financials access as well.
CREATE OR REPLACE FUNCTION erp.hr_setup_save(p_company varchar, p_kind text, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
  s erp.hr_setting;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_id integer;
  v_ref text;
  v_days int[];
BEGIN
  u := erp._hr_guard(p_company, 'full');
  IF p_kind = 'setting' THEN
    INSERT INTO erp.hr_setting (company_code) VALUES (p_company) ON CONFLICT DO NOTHING;
    SELECT * INTO s FROM erp.hr_setting WHERE company_code = p_company FOR UPDATE;
    IF d ? 'payable_acct' AND d->>'payable_acct' IS DISTINCT FROM s.payable_acct THEN
      IF NOT coalesce(erp.can_write('finance'), false) THEN
        RAISE EXCEPTION 'Only Finance with full access can change the salaries payable account.' USING ERRCODE = '42501';
      END IF;
      IF nullif(d->>'payable_acct', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.account WHERE company_code = p_company AND acct_code = d->>'payable_acct'
                                                                      AND postable AND NOT coalesce(frozen, false)) THEN
        RAISE EXCEPTION 'Account % is not a postable account in %.', d->>'payable_acct', p_company USING ERRCODE = 'P0001';
      END IF;
    END IF;
    IF d ? 'timezone' AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = d->>'timezone') THEN
      RAISE EXCEPTION 'Time zone % is not known. Use a name like Asia/Dubai.', d->>'timezone' USING ERRCODE = 'P0001';
    END IF;
    IF d ? 'weekend' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(d->'weekend') x WHERE x !~ '^[1-7]$') THEN
      RAISE EXCEPTION 'Weekend days are numbers 1 (Monday) to 7 (Sunday).' USING ERRCODE = 'P0001';
    END IF;
    IF d ? 'expiry_alert_days' THEN
      SELECT array_agg(x::int ORDER BY x::int DESC) INTO v_days FROM jsonb_array_elements_text(d->'expiry_alert_days') x;
      IF v_days IS NULL OR EXISTS (SELECT 1 FROM unnest(v_days) x WHERE x NOT BETWEEN 1 AND 365) THEN
        RAISE EXCEPTION 'Expiry alerts are days between 1 and 365.' USING ERRCODE = 'P0001';
      END IF;
    END IF;
    FOR v_ref IN SELECT x FROM unnest(ARRAY['hr_approver_position', 'owner_position']) x LOOP
      IF d ? v_ref AND nullif(d->>v_ref, '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.position WHERE position_code = d->>v_ref) THEN
        RAISE EXCEPTION 'Position % does not exist.', d->>v_ref USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
    FOR v_ref IN SELECT x FROM unnest(ARRAY['ot_wage_code', 'unpaid_wage_code']) x LOOP
      IF d ? v_ref AND nullif(d->>v_ref, '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.wage_type WHERE company_code = p_company AND code = d->>v_ref) THEN
        RAISE EXCEPTION 'Wage type % does not exist in %.', d->>v_ref, p_company USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
    IF d ? 'employer_mol_id' AND nullif(d->>'employer_mol_id', '') IS NOT NULL AND d->>'employer_mol_id' !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'The employer MOHRE ID has digits only.' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
      UPDATE erp.hr_setting SET
        timezone = CASE WHEN d ? 'timezone' THEN d->>'timezone' ELSE timezone END,
        weekend = CASE WHEN d ? 'weekend' THEN coalesce((SELECT array_agg(x::smallint ORDER BY x::smallint) FROM jsonb_array_elements_text(d->'weekend') x), '{}') ELSE weekend END,
        leave_year_start = CASE WHEN d ? 'leave_year_start' THEN (d->>'leave_year_start')::smallint ELSE leave_year_start END,
        long_leave_days = CASE WHEN d ? 'long_leave_days' THEN erp._num(d->>'long_leave_days') ELSE long_leave_days END,
        hr_approver_position = CASE WHEN d ? 'hr_approver_position' THEN nullif(d->>'hr_approver_position', '') ELSE hr_approver_position END,
        owner_position = CASE WHEN d ? 'owner_position' THEN nullif(d->>'owner_position', '') ELSE owner_position END,
        allow_negative_leave = CASE WHEN d ? 'allow_negative_leave' THEN coalesce((d->>'allow_negative_leave')::boolean, false) ELSE allow_negative_leave END,
        month_days_basis = CASE WHEN d ? 'month_days_basis' THEN nullif(d->>'month_days_basis', '') ELSE month_days_basis END,
        hours_per_day = CASE WHEN d ? 'hours_per_day' THEN erp._num(d->>'hours_per_day') ELSE hours_per_day END,
        ot_multiplier = CASE WHEN d ? 'ot_multiplier' THEN erp._num(d->>'ot_multiplier') ELSE ot_multiplier END,
        ot_rate_basis = CASE WHEN d ? 'ot_rate_basis' THEN nullif(d->>'ot_rate_basis', '') ELSE ot_rate_basis END,
        ot_wage_code = CASE WHEN d ? 'ot_wage_code' THEN nullif(d->>'ot_wage_code', '') ELSE ot_wage_code END,
        unpaid_wage_code = CASE WHEN d ? 'unpaid_wage_code' THEN nullif(d->>'unpaid_wage_code', '') ELSE unpaid_wage_code END,
        unpaid_basis = CASE WHEN d ? 'unpaid_basis' THEN nullif(d->>'unpaid_basis', '') ELSE unpaid_basis END,
        payable_acct = CASE WHEN d ? 'payable_acct' THEN nullif(d->>'payable_acct', '') ELSE payable_acct END,
        gratuity_min_years = CASE WHEN d ? 'gratuity_min_years' THEN erp._num(d->>'gratuity_min_years') ELSE gratuity_min_years END,
        gratuity_years_first = CASE WHEN d ? 'gratuity_years_first' THEN erp._num(d->>'gratuity_years_first') ELSE gratuity_years_first END,
        gratuity_days_first = CASE WHEN d ? 'gratuity_days_first' THEN erp._num(d->>'gratuity_days_first') ELSE gratuity_days_first END,
        gratuity_days_after = CASE WHEN d ? 'gratuity_days_after' THEN erp._num(d->>'gratuity_days_after') ELSE gratuity_days_after END,
        gratuity_cap_years = CASE WHEN d ? 'gratuity_cap_years' THEN erp._num(d->>'gratuity_cap_years') ELSE gratuity_cap_years END,
        gratuity_day_basis = CASE WHEN d ? 'gratuity_day_basis' THEN nullif(d->>'gratuity_day_basis', '') ELSE gratuity_day_basis END,
        employer_mol_id = CASE WHEN d ? 'employer_mol_id' THEN nullif(btrim(d->>'employer_mol_id'), '') ELSE employer_mol_id END,
        wps_employer_id_len = CASE WHEN d ? 'wps_employer_id_len' THEN erp._num(d->>'wps_employer_id_len')::smallint ELSE wps_employer_id_len END,
        wps_person_id_len = CASE WHEN d ? 'wps_person_id_len' THEN erp._num(d->>'wps_person_id_len')::smallint ELSE wps_person_id_len END,
        wps_routing_len = CASE WHEN d ? 'wps_routing_len' THEN erp._num(d->>'wps_routing_len')::smallint ELSE wps_routing_len END,
        expiry_alert_days = coalesce(v_days, expiry_alert_days),
        updated_by = u.user_id, updated_at = now()
      WHERE company_code = p_company;
    EXCEPTION WHEN check_violation OR invalid_text_representation THEN
      RAISE EXCEPTION 'One of the HR settings is out of range. Check the bases (30 or calendar, basic or gross) and that numbers are above 0.' USING ERRCODE = 'P0001';
    END;
    v_ref := p_company;
  ELSIF p_kind = 'site' THEN
    IF nullif(btrim(d->>'site_code'), '') IS NULL OR nullif(btrim(d->>'name'), '') IS NULL THEN
      RAISE EXCEPTION 'Enter the site code and name.' USING ERRCODE = 'P0001';
    END IF;
    IF erp._num(d->>'lat') IS NULL OR erp._num(d->>'lat') NOT BETWEEN -90 AND 90 OR erp._num(d->>'lng') IS NULL OR erp._num(d->>'lng') NOT BETWEEN -180 AND 180 THEN
      RAISE EXCEPTION 'Enter the site latitude (−90 to 90) and longitude (−180 to 180).' USING ERRCODE = 'P0001';
    END IF;
    IF erp._num(d->>'radius_m') IS NULL OR erp._num(d->>'radius_m') NOT BETWEEN 10 AND 100000 THEN
      RAISE EXCEPTION 'The site radius must be between 10 and 100,000 metres.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.hr_site (company_code, site_code, name, lat, lng, radius_m, active)
    VALUES (p_company, upper(btrim(d->>'site_code')), btrim(d->>'name'), erp._num(d->>'lat'), erp._num(d->>'lng'), erp._num(d->>'radius_m')::integer,
            coalesce((d->>'active')::boolean, true))
    ON CONFLICT (company_code, site_code) DO UPDATE SET name = EXCLUDED.name, lat = EXCLUDED.lat, lng = EXCLUDED.lng, radius_m = EXCLUDED.radius_m, active = EXCLUDED.active;
    v_ref := upper(btrim(d->>'site_code'));
  ELSIF p_kind = 'shift' THEN
    IF nullif(btrim(d->>'shift_code'), '') IS NULL OR nullif(btrim(d->>'name'), '') IS NULL THEN
      RAISE EXCEPTION 'Enter the shift code and name.' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
      IF (d->>'start_time')::time IS NULL OR (d->>'end_time')::time IS NULL THEN RAISE invalid_text_representation; END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Enter the shift start and end time as HH:MM.' USING ERRCODE = 'P0001';
    END;
    INSERT INTO erp.hr_shift (company_code, shift_code, name, start_time, end_time, grace_min, departments, active)
    VALUES (p_company, upper(btrim(d->>'shift_code')), btrim(d->>'name'), (d->>'start_time')::time, (d->>'end_time')::time,
            greatest(least(coalesce(erp._num(d->>'grace_min'), 0), 240), 0)::integer,
            coalesce((SELECT array_agg(btrim(x)) FROM jsonb_array_elements_text(coalesce(d->'departments', '[]')) x WHERE btrim(x) <> ''), '{}'),
            coalesce((d->>'active')::boolean, true))
    ON CONFLICT (company_code, shift_code) DO UPDATE SET name = EXCLUDED.name, start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time,
      grace_min = EXCLUDED.grace_min, departments = EXCLUDED.departments, active = EXCLUDED.active;
    v_ref := upper(btrim(d->>'shift_code'));
  ELSIF p_kind = 'duty' THEN
    IF nullif(btrim(d->>'department'), '') IS NULL OR nullif(btrim(d->>'title'), '') IS NULL THEN
      RAISE EXCEPTION 'Enter the department and the duty.' USING ERRCODE = 'P0001';
    END IF;
    IF nullif(d->>'shift_code', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM erp.hr_shift WHERE company_code = p_company AND shift_code = d->>'shift_code') THEN
      RAISE EXCEPTION 'Shift % does not exist.', d->>'shift_code' USING ERRCODE = 'P0001';
    END IF;
    IF (d->>'duty_id') IS NULL THEN
      INSERT INTO erp.hr_duty (company_code, department, title, detail, shift_code, sort, active)
      VALUES (p_company, btrim(d->>'department'), btrim(d->>'title'), nullif(btrim(d->>'detail'), ''), nullif(d->>'shift_code', ''),
              coalesce(erp._num(d->>'sort'), 0)::smallint, coalesce((d->>'active')::boolean, true))
      RETURNING duty_id INTO v_id;
    ELSE
      UPDATE erp.hr_duty SET department = btrim(d->>'department'), title = btrim(d->>'title'), detail = nullif(btrim(d->>'detail'), ''),
             shift_code = nullif(d->>'shift_code', ''), sort = coalesce(erp._num(d->>'sort'), sort)::smallint, active = coalesce((d->>'active')::boolean, active)
       WHERE company_code = p_company AND duty_id = (d->>'duty_id')::integer RETURNING duty_id INTO v_id;
      IF v_id IS NULL THEN
        RAISE EXCEPTION 'Duty % was not found.', d->>'duty_id' USING ERRCODE = 'P0001';
      END IF;
    END IF;
    v_ref := v_id::text;
  ELSIF p_kind = 'holiday' THEN
    IF erp._date(d->>'day') IS NULL OR nullif(btrim(d->>'name'), '') IS NULL THEN
      RAISE EXCEPTION 'Enter the holiday date and name.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.hr_holiday (company_code, day, name) VALUES (p_company, erp._date(d->>'day'), btrim(d->>'name'))
    ON CONFLICT (company_code, day) DO UPDATE SET name = EXCLUDED.name;
    v_ref := d->>'day';
  ELSIF p_kind = 'holiday_remove' THEN
    DELETE FROM erp.hr_holiday WHERE company_code = p_company AND day = erp._date(d->>'day');
    v_ref := d->>'day';
  ELSIF p_kind = 'policy' THEN
    IF NOT EXISTS (SELECT 1 FROM erp.leave_type WHERE company_code = p_company AND code = d->>'leave_code') THEN
      RAISE EXCEPTION 'Leave type % does not exist in %.', coalesce(d->>'leave_code', '(none)'), p_company USING ERRCODE = 'P0001';
    END IF;
    IF coalesce(d->>'accrual', '') NOT IN ('monthly', 'yearly', 'none') THEN
      RAISE EXCEPTION 'Choose how the leave builds up: monthly, yearly or not tracked.' USING ERRCODE = 'P0001';
    END IF;
    IF d->>'accrual' <> 'none' AND (erp._num(d->>'annual_days') IS NULL OR erp._num(d->>'annual_days') < 0 OR erp._num(d->>'annual_days') > 366) THEN
      RAISE EXCEPTION 'Enter the days per year (0 to 366).' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.hr_leave_policy (company_code, leave_code, annual_days, accrual, basis, active)
    VALUES (p_company, d->>'leave_code', erp._num(d->>'annual_days'), d->>'accrual', coalesce(nullif(d->>'basis', ''), 'working'), coalesce((d->>'active')::boolean, true))
    ON CONFLICT (company_code, leave_code) DO UPDATE SET annual_days = EXCLUDED.annual_days, accrual = EXCLUDED.accrual, basis = EXCLUDED.basis, active = EXCLUDED.active;
    v_ref := d->>'leave_code';
  ELSIF p_kind = 'wps_bank' THEN
    IF nullif(btrim(d->>'bank_code'), '') IS NULL OR nullif(btrim(d->>'name'), '') IS NULL THEN
      RAISE EXCEPTION 'Enter the bank code and name.' USING ERRCODE = 'P0001';
    END IF;
    IF nullif(d->>'employer_routing', '') IS NOT NULL AND d->>'employer_routing' !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'The routing code has digits only.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.hr_wps_bank (company_code, bank_code, name, employer_routing, employer_ref, active)
    VALUES (p_company, upper(btrim(d->>'bank_code')), btrim(d->>'name'), nullif(d->>'employer_routing', ''), nullif(btrim(d->>'employer_ref'), ''),
            coalesce((d->>'active')::boolean, true))
    ON CONFLICT (company_code, bank_code) DO UPDATE SET name = EXCLUDED.name, employer_routing = EXCLUDED.employer_routing,
      employer_ref = EXCLUDED.employer_ref, active = EXCLUDED.active;
    v_ref := upper(btrim(d->>'bank_code'));
  ELSIF p_kind = 'leave_adjust' THEN
    IF NOT EXISTS (SELECT 1 FROM erp.employee WHERE company_code = p_company AND emp_id = (nullif(d->>'emp_id', ''))::integer) THEN
      RAISE EXCEPTION 'Choose the employee.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM erp.hr_leave_policy WHERE company_code = p_company AND leave_code = d->>'leave_code' AND accrual <> 'none') THEN
      RAISE EXCEPTION 'Choose a leave type whose balance is tracked.' USING ERRCODE = 'P0001';
    END IF;
    IF erp._num(d->>'days') IS NULL OR erp._num(d->>'days') = 0 OR abs(erp._num(d->>'days')) > 366 THEN
      RAISE EXCEPTION 'Enter the days to add (or a minus number to take away).' USING ERRCODE = 'P0001';
    END IF;
    IF nullif(btrim(d->>'note'), '') IS NULL THEN
      RAISE EXCEPTION 'Add a note saying why the balance changes (e.g. carried forward from last year).' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO erp.hr_leave_adjust (company_code, emp_id, leave_code, leave_year, days, note, created_by)
    VALUES (p_company, (d->>'emp_id')::integer, d->>'leave_code', coalesce(erp._num(d->>'leave_year')::integer, extract(year FROM current_date)::integer),
            erp._num(d->>'days'), btrim(d->>'note'), u.user_id)
    RETURNING adjust_id INTO v_id;
    v_ref := v_id::text;
  ELSE
    RAISE EXCEPTION 'Unknown HR setup item %.', coalesce(p_kind, '(none)') USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (u.user_id::text, p_company, 'hr_setup_' || p_kind, 'hr_setup', v_ref, d);
  RETURN jsonb_build_object('kind', p_kind, 'ref', v_ref);
END $$;

-- ============ Approvals inbox (replaces A8's: the 10 earlier branches + leave; rows meant for one named user only) ============
CREATE OR REPLACE FUNCTION erp.approval_inbox() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE
  u erp.app_user;
BEGIN
  IF erp.current_user_id() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO u FROM erp.app_user WHERE user_id = erp.current_user_id() AND active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_approver', false, 'waiting', '[]'::jsonb, 'sent', '[]'::jsonb, 'decided', '[]'::jsonb);
  END IF;
  RETURN (
    WITH base AS (
      SELECT a.*, 'sales_order'::text AS kind, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 17 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'sales_order' AND erp.can_see(a.company_code)
      UNION ALL
      SELECT a.*, 'sales_quotation'::text, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 23 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'sales_quotation' AND erp.can_see(a.company_code)
      UNION ALL
      SELECT a.*, 'journal'::text, j.draft_id::text, j.state, j.reason, j.submitted_by, j.draft_id, NULL::varchar, j.memo, j.total, j.currency
        FROM erp.approval a
        JOIN erp.journal_draft j ON j.company_code = a.company_code AND j.draft_id::text = a.object_ref
       WHERE a.object = 'journal' AND erp.can_see(a.company_code) AND erp.can_read('finance')
      UNION ALL
      SELECT a.*, 'payment'::text, p.draft_id::text, p.state, p.reason, p.created_by, p.draft_id, p.card_code, p.card_name, p.total, p.currency
        FROM erp.approval a
        JOIN erp.payment_draft p ON p.company_code = a.company_code AND p.draft_id::text = a.object_ref
       WHERE a.object = 'payment' AND erp.can_see(a.company_code) AND (erp.can_read('banking') OR erp.can_read('finance'))
      UNION ALL
      SELECT a.*, 'purchase_order'::text, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, d.card_code, d.card_name, d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = 22 AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object = 'purchase_order' AND erp.can_see(a.company_code) AND (erp.can_read('purchase') OR erp.can_read('finance'))
      UNION ALL
      -- A7: goods receipts / issues (card_code = warehouse, card_name = reason) and counts (card_code = warehouse, total = variance value)
      SELECT a.*, a.object, w.doc_no, w.state, w.reason, w.submitted_by, d.doc_entry, w.whs_code::varchar,
             (SELECT name FROM erp.inventory_reason r WHERE r.company_code = w.company_code AND r.code = w.reason_code), d.total, d.currency
        FROM erp.approval a
        JOIN erp.doc_workflow w ON w.company_code = a.company_code AND w.obj_type = CASE a.object WHEN 'goods_receipt' THEN 59 ELSE 60 END
                               AND w.doc_entry::text = a.object_ref
        JOIN erp.document d ON d.company_code = w.company_code AND d.obj_type = w.obj_type AND d.doc_entry = w.doc_entry
       WHERE a.object IN ('goods_receipt', 'goods_issue') AND erp.can_see(a.company_code) AND erp.can_read('inventory')
      UNION ALL
      SELECT a.*, 'inventory_count'::text, c.doc_no, c.state, c.reason, c.submitted_by, c.count_id, c.whs_code::varchar,
             (SELECT name FROM erp.warehouse wh WHERE wh.company_code = c.company_code AND wh.whs_code = c.whs_code),
             coalesce(c.gain_value, 0) + coalesce(c.loss_value, 0), (SELECT currency FROM erp.company co WHERE co.company_code = c.company_code)
        FROM erp.approval a
        JOIN erp.inv_count c ON c.company_code = a.company_code AND c.count_id::text = a.object_ref
       WHERE a.object = 'inventory_count' AND erp.can_see(a.company_code) AND erp.can_read('inventory')
      UNION ALL
      -- A8: credit limit / bank detail changes (doc_no and card_code = partner code, total = new credit limit)
      SELECT a.*, 'bp_change'::text, q.card_code::text, q.state, q.reason, q.requested_by, q.request_id, q.card_code::varchar, bp.name,
             CASE WHEN q.kind = 'credit_limit' THEN (q.after->>'credit_limit')::numeric END, bp.currency
        FROM erp.approval a
        JOIN erp.bp_change_request q ON q.company_code = a.company_code AND q.request_id::text = a.object_ref
        JOIN erp.business_partner bp ON bp.company_code = q.company_code AND bp.card_code = q.card_code
       WHERE a.object = 'bp_change' AND erp.can_see(a.company_code)
         AND (erp.can_read('bp') OR erp.can_read('sales') OR erp.can_read('purchase') OR erp.can_read('finance') OR erp.can_read('banking'))
      UNION ALL
      -- A9: leave requests (doc_no = request id, card_code = employee code, card_name = employee name, total = days).
      SELECT a.*, 'leave'::text, q.request_id::text, q.state, q.reason, q.requested_by, q.request_id, e.hr_code::varchar,
             concat_ws(' ', e.first_name, e.last_name), q.days, NULL::varchar
        FROM erp.approval a
        JOIN erp.leave_request q ON q.company_code = a.company_code AND q.request_id::text = a.object_ref
        JOIN erp.employee e ON e.company_code = q.company_code AND e.emp_id = q.emp_id
       WHERE a.object = 'leave' AND erp.can_see(a.company_code)
    ), a AS (
      SELECT b.*, b.detail->>'for_user' AS for_user, p.name AS approver_position_name, ru.display_name AS requested_by_name, du.display_name AS decided_by_name,
             min(b.step) FILTER (WHERE b.decision IS NULL AND NOT b.superseded)
               OVER (PARTITION BY b.company_code, b.object, b.object_ref) AS current_step
        FROM base b
        JOIN erp.position p ON p.position_code = b.approver_position
        LEFT JOIN erp.app_user ru ON ru.user_id = b.requested_by
        LEFT JOIN erp.app_user du ON du.user_id = b.approver_user
    ), r AS (
      SELECT a.*, jsonb_build_object(
               'approval_id', a.approval_id, 'company_code', a.company_code, 'kind', a.kind, 'doc_entry', a.doc_entry,
               'doc_no', a.doc_no, 'rule_code', a.rule_code, 'step', a.step, 'card_code', a.card_code, 'card_name', a.card_name,
               'total', a.total, 'currency', a.currency, 'requested_by_name', a.requested_by_name, 'requested_at', a.requested_at,
               'reason', a.reason, 'decision', a.decision, 'decided_at', a.decided_at, 'decided_by_name', a.decided_by_name,
               'note', a.note, 'state', a.state, 'approver_position_name', a.approver_position_name, 'superseded', a.superseded,
               'message', a.detail->'checks'->0->>'message') AS j
        FROM a
    )
    SELECT jsonb_build_object(
      'is_approver', EXISTS (SELECT 1 FROM erp.approval_rule ar WHERE ar.approver_position = u.position_code AND ar.active AND erp.can_see(ar.company_code))
                     OR EXISTS (SELECT 1 FROM erp.hr_setting hs WHERE u.position_code IN (hs.hr_approver_position, hs.owner_position) AND erp.can_see(hs.company_code))
                     OR EXISTS (SELECT 1 FROM erp.approval ap WHERE ap.detail->>'for_user' = u.user_id::text),
      'waiting', coalesce((SELECT jsonb_agg(j ORDER BY requested_at) FROM r
                            WHERE decision IS NULL AND NOT superseded AND state = 'pending_approval' AND step = current_step
                              AND approver_position = u.position_code AND submitted_by IS DISTINCT FROM u.user_id
                              AND (for_user IS NULL OR for_user = u.user_id::text)), '[]'::jsonb),
      'sent', coalesce((SELECT jsonb_agg(j ORDER BY requested_at DESC, approval_id) FROM (SELECT * FROM r WHERE requested_by = u.user_id
                         ORDER BY requested_at DESC LIMIT 100) s), '[]'::jsonb),
      'decided', coalesce((SELECT jsonb_agg(j ORDER BY decided_at DESC) FROM (SELECT * FROM r WHERE approver_user = u.user_id AND decision IS NOT NULL
                            ORDER BY decided_at DESC LIMIT 100) s), '[]'::jsonb)));
END $$;


-- ============ Grants ============
REVOKE ALL ON FUNCTION erp._hr_d(date), erp._hr_emp_name(varchar, integer), erp._hr_guard(varchar, text), erp._hr_me(varchar),
  erp._hr_salary_audit(varchar, text, text, jsonb), erp._hr_distance_m(numeric, numeric, numeric, numeric), erp._hr_iban_ok(text),
  erp._hr_leave_days(varchar, date, date, text), erp._hr_leave_balance(varchar, integer, text, date), erp._hr_balances(varchar, integer, date),
  erp._hr_pay_at(varchar, integer, date), erp._hr_gratuity(varchar, integer, date), erp._hr_ticket(varchar, integer, date),
  erp._hr_shift_of(varchar, integer), erp._leave_eval(varchar, jsonb, erp.app_user, integer), erp._hr_period(text),
  erp._wps_build(varchar, integer, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.hr_employee_save(varchar, jsonb), erp.hr_employee_extra_save(varchar, integer, jsonb),
  erp.hr_pay_set(varchar, integer, text, numeric, date, text), erp.hr_document_save(varchar, jsonb), erp.hr_employee_info(varchar, integer),
  erp.attendance_check(varchar, text, numeric, numeric, numeric), erp.leave_checks(varchar, jsonb), erp.leave_submit(varchar, jsonb),
  erp.leave_decide(varchar, integer, text, text), erp.leave_cancel(varchar, integer, text), erp.leave_info(varchar, integer),
  erp.payroll_input_save(varchar, jsonb), erp.payroll_input_remove(varchar, integer), erp.payroll_calculate(varchar, text),
  erp.payroll_info(varchar, integer), erp.payroll_step(varchar, integer, text), erp.payroll_post(varchar, integer, date),
  erp.wps_check(varchar, integer, text), erp.wps_file(varchar, integer, text), erp.portal_me(varchar), erp.portal_payslip(varchar, integer, integer),
  erp.hr_setup(varchar), erp.hr_setup_save(varchar, text, jsonb), erp.approval_inbox()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.hr_employee_save(varchar, jsonb), erp.hr_employee_extra_save(varchar, integer, jsonb),
  erp.hr_pay_set(varchar, integer, text, numeric, date, text), erp.hr_document_save(varchar, jsonb), erp.hr_employee_info(varchar, integer),
  erp.attendance_check(varchar, text, numeric, numeric, numeric), erp.leave_checks(varchar, jsonb), erp.leave_submit(varchar, jsonb),
  erp.leave_decide(varchar, integer, text, text), erp.leave_cancel(varchar, integer, text), erp.leave_info(varchar, integer),
  erp.payroll_input_save(varchar, jsonb), erp.payroll_input_remove(varchar, integer), erp.payroll_calculate(varchar, text),
  erp.payroll_info(varchar, integer), erp.payroll_step(varchar, integer, text), erp.payroll_post(varchar, integer, date),
  erp.wps_check(varchar, integer, text), erp.wps_file(varchar, integer, text), erp.portal_me(varchar), erp.portal_payslip(varchar, integer, integer),
  erp.hr_setup(varchar), erp.hr_setup_save(varchar, text, jsonb), erp.approval_inbox()
  TO authenticated;

-- ============ SAMPLE values for the test company ZZ99 only ============
-- Everything below is fictional test data, marked 'SAMPLE'. Real companies get no rows: Ashif supplies the policy (see walkthrough).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM erp.company WHERE company_code = 'ZZ99') THEN
    RETURN;
  END IF;
  -- accounts for payroll posting
  INSERT INTO erp.account (company_code, acct_code, format_code, name, parent_code, level, postable, account_type, group_mask, currency, is_control, frozen, balance_local, source)
  VALUES ('ZZ99', '2300', '2300', 'Salaries payable (sample)', '2000', 2, true, 'other', 2, 'AED', false, false, 0, 'sample'),
         ('ZZ99', '1250', '1250', 'Staff advances (sample)', '1000', 2, true, 'other', 1, 'AED', false, false, 0, 'sample')
  ON CONFLICT DO NOTHING;
  -- managers (sample employees only)
  UPDATE erp.employee SET manager_emp_id = v.mgr
    FROM (VALUES (3, 2), (6, 7), (9, 7), (5, 4)) AS v(emp, mgr)
   WHERE company_code = 'ZZ99' AND source = 'sample' AND emp_id = v.emp AND manager_emp_id IS DISTINCT FROM v.mgr;
  -- numbering for new employees (SAP object 171 = employee)
  INSERT INTO erp.number_series (company_code, obj_type, prefix, next_num, pad) VALUES ('ZZ99', 171, 'EMP-', 1, 4)
  ON CONFLICT (company_code, obj_type) DO NOTHING;
  -- settings (UAE labour-law values used as SAMPLE only; Ashif confirms the real policy)
  INSERT INTO erp.hr_setting (company_code, timezone, weekend, leave_year_start, long_leave_days, hr_approver_position, owner_position,
                              month_days_basis, hours_per_day, ot_multiplier, ot_rate_basis, ot_wage_code, unpaid_wage_code, unpaid_basis, payable_acct,
                              gratuity_min_years, gratuity_years_first, gratuity_days_first, gratuity_days_after, gratuity_cap_years, gratuity_day_basis,
                              employer_mol_id, wps_employer_id_len, wps_person_id_len, wps_routing_len, note)
  VALUES ('ZZ99', 'Asia/Dubai', '{6,7}', 1, 14, (SELECT position_code FROM erp.position WHERE position_code = 'QA_HR'),
          (SELECT position_code FROM erp.position WHERE position_code = 'QA_OWNER'),
          '30', 8, 1.25, 'basic', 'OT', 'UNPAID', 'gross', '2300', 1, 5, 21, 30, 2, '30',
          '1000000000099', 13, 14, 9, 'SAMPLE setting for test company ZZ99 only')
  ON CONFLICT (company_code) DO NOTHING;
  INSERT INTO erp.hr_site (company_code, site_code, name, lat, lng, radius_m) VALUES
    ('ZZ99', 'DWC', 'Sample warehouse site (test data)', 24.896000, 55.161000, 300),
    ('ZZ99', 'OFFICE', 'Sample office (test data)', 25.204800, 55.270800, 200)
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.hr_shift (company_code, shift_code, name, start_time, end_time, grace_min, departments) VALUES
    ('ZZ99', 'DAY', 'Office day (sample)', '08:30', '17:30', 10, '{Finance,Sales,Purchasing,HR,IT}'),
    ('ZZ99', 'WH', 'Warehouse (sample)', '07:00', '16:00', 5, '{Warehouse,Logistics}')
  ON CONFLICT DO NOTHING;
  IF NOT EXISTS (SELECT 1 FROM erp.hr_duty WHERE company_code = 'ZZ99') THEN
    INSERT INTO erp.hr_duty (company_code, department, title, detail, shift_code, sort) VALUES
      ('ZZ99', 'Warehouse', 'Check the receiving bay before 08:00', 'Sample duty — test data', 'WH', 1),
      ('ZZ99', 'Warehouse', 'Count the fast movers on Thursdays', 'Sample duty — test data', 'WH', 2),
      ('ZZ99', 'Warehouse', 'Close open pick lists before leaving', 'Sample duty — test data', 'WH', 3),
      ('ZZ99', 'Sales', 'Follow up open quotations', 'Sample duty — test data', 'DAY', 1),
      ('ZZ99', 'Finance', 'Match yesterday''s bank lines', 'Sample duty — test data', 'DAY', 1),
      ('ZZ99', 'HR', 'Check documents expiring this month', 'Sample duty — test data', 'DAY', 1);
  END IF;
  INSERT INTO erp.hr_holiday (company_code, day, name) VALUES
    ('ZZ99', '2026-12-02', 'National Day (sample)'), ('ZZ99', '2026-12-03', 'National Day holiday (sample)'), ('ZZ99', '2027-01-01', 'New Year (sample)')
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.leave_type (company_code, code, name, paid, unit, max_days, min_days, loss_of_pay, counts_for_eos) VALUES
    ('ZZ99', 'AL', 'Annual leave', true, 'day', NULL, NULL, false, true),
    ('ZZ99', 'SL', 'Sick leave', true, 'day', NULL, NULL, false, true),
    ('ZZ99', 'UL', 'Unpaid leave', false, 'day', 30, NULL, true, false)
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.hr_leave_policy (company_code, leave_code, annual_days, accrual, basis) VALUES
    ('ZZ99', 'AL', 30, 'monthly', 'working'), ('ZZ99', 'SL', 15, 'yearly', 'working'), ('ZZ99', 'UL', NULL, 'none', 'calendar')
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.wage_type (company_code, code, name, is_earning, is_deduction, is_loan, calc_type, gl_account) VALUES
    ('ZZ99', 'BASIC', 'Basic salary', true, false, false, 'fixed', '6100'),
    ('ZZ99', 'HOUSING', 'Housing allowance', true, false, false, 'fixed', '6100'),
    ('ZZ99', 'TRANSPORT', 'Transport allowance', true, false, false, 'fixed', '6100'),
    ('ZZ99', 'OT', 'Overtime', true, false, false, 'overtime', '6100'),
    ('ZZ99', 'BONUS', 'One-off bonus', true, false, false, 'input', '6100'),
    ('ZZ99', 'UNPAID', 'Unpaid leave deduction', false, true, false, 'unpaid', '6100'),
    ('ZZ99', 'ADVANCE', 'Salary advance recovery', false, true, true, 'input', '1250')
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.hr_wps_bank (company_code, bank_code, name, employer_routing, employer_ref) VALUES
    ('ZZ99', 'SMPBANK', 'Sample Bank (test data)', '403520101', 'ZZ99-SAMPLE')
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.hr_pay (company_code, emp_id, wage_code, amount, valid_from, note)
  SELECT 'ZZ99', v.emp, w.code, w.amt, '2018-01-01', 'SAMPLE pay — test data'
    FROM (VALUES (1, 9000, 3500, 1000), (2, 14000, 5000, 1500), (3, 7000, 2500, 800), (4, 8000, 3000, 1000), (5, 6000, 2000, 800),
                 (6, 3000, 1200, 500), (7, 4500, 1500, 600), (8, 8500, 3000, 1000), (9, 2800, 1000, 400), (10, 6500, 2500, 800)) AS v(emp, b, h, t)
   CROSS JOIN LATERAL (VALUES ('BASIC', v.b), ('HOUSING', v.h), ('TRANSPORT', v.t)) AS w(code, amt)
   WHERE EXISTS (SELECT 1 FROM erp.employee e WHERE e.company_code = 'ZZ99' AND e.emp_id = v.emp)
  ON CONFLICT DO NOTHING;
  INSERT INTO erp.hr_employee_extra (company_code, emp_id, site_code, iban, bank_routing, mol_person_id, labour_card_no, wps_bank, ticket_value, ticket_every_months, home_city)
  SELECT 'ZZ99', v.emp, CASE WHEN v.emp IN (6, 7, 9) THEN 'DWC' ELSE 'OFFICE' END, v.iban, '403520101', lpad((10000000000000 + v.emp)::text, 14, '0'),
         'LC-SMP-' || v.emp, 'SMPBANK', CASE WHEN v.emp IN (3, 4) THEN 1800 END, CASE WHEN v.emp IN (3, 4) THEN 24 END,
         CASE WHEN v.emp IN (3, 4) THEN 'Sample home city' END
    FROM (VALUES (1, 'AE410330000001000007919'), (2, 'AE160330000001000015838'), (3, 'AE880330000001000023757'), (4, 'AE630330000001000031676'),
                 (5, 'AE380330000001000039595'), (6, 'AE130330000001000047514'), (7, 'AE850330000001000055433'), (8, 'AE600330000001000063352'),
                 (9, 'AE350330000001000071271'), (10, 'AE100330000001000079190')) AS v(emp, iban)
   WHERE EXISTS (SELECT 1 FROM erp.employee e WHERE e.company_code = 'ZZ99' AND e.emp_id = v.emp)
  ON CONFLICT DO NOTHING;
  -- ID documents with expiry dates relative to the day this file is loaded (so every alert band has an example)
  IF NOT EXISTS (SELECT 1 FROM erp.hr_document WHERE company_code = 'ZZ99') THEN
    INSERT INTO erp.hr_document (company_code, emp_id, doc_type, doc_no, issued_on, expires_on)
    SELECT 'ZZ99', v.emp, v.t, v.no, current_date - 700, current_date + v.days
      FROM (VALUES (2, 'passport', 'SMP-P-0002', 50), (6, 'visa', 'SMP-V-0006', 25), (4, 'emirates_id', '784199000000004', 5),
                   (1, 'labour_card', 'SMP-L-0001', 400), (9, 'visa', 'SMP-V-0009', -3)) AS v(emp, t, no, days)
     WHERE EXISTS (SELECT 1 FROM erp.employee e WHERE e.company_code = 'ZZ99' AND e.emp_id = v.emp);
  END IF;
END $$;
