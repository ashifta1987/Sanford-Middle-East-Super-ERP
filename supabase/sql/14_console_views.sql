-- Sanford ERP - 14_console_views.sql
-- What the Migration console (React app) needs on top of 13_migration_console.sql:
--   1. erp.migration_company_overview  one row per company for the B5 Migration centre
--   2. erp.company_cutover             go-live record per company
--   3. erp.company_go_live()           CFO-only go-live for a signed-off run
--   4. Storage bucket sap-exports + policies on storage.objects
-- Run after 13. Safe to run again (idempotent). Does not edit 10-13.

-- ============ 2. Cut-over table (created first: the view reads it) ============
CREATE TABLE IF NOT EXISTS erp.company_cutover (
    company_code   varchar(8) PRIMARY KEY REFERENCES sap._company,
    go_live_at     timestamptz NOT NULL DEFAULT now(),
    go_live_run    uuid NOT NULL REFERENCES erp.migration_run,
    go_live_by     uuid NOT NULL
);
ALTER TABLE erp.company_cutover ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON erp.company_cutover FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.company_cutover TO authenticated;
GRANT ALL ON erp.company_cutover TO service_role;
DROP POLICY IF EXISTS company_cutover_admin ON erp.company_cutover;
CREATE POLICY company_cutover_admin ON erp.company_cutover FOR SELECT TO authenticated
  USING (erp.migration_can_read(company_code));

-- ============ 1. Overview view ============
-- The browser cannot read sap.*, so this view (running with the owner's rights) exposes only the
-- columns the centre needs, and only for companies the caller may read as admin/IT.
-- security_barrier stops a caller's own WHERE functions from running before the access filter.
DROP VIEW IF EXISTS erp.migration_company_overview;
CREATE VIEW erp.migration_company_overview WITH (security_barrier = true) AS
SELECT
    c.company_code,
    c.legal_name                                        AS company_name,
    c.sap_schema,
    c.country,
    c.currency,
    c.in_scope,
    lr.run_id                                           AS latest_run_id,
    lr.kind                                             AS latest_kind,
    lr.status                                           AS latest_status,
    lr.created_at                                       AS latest_created_at,
    lr.started_at                                       AS latest_started_at,
    lr.finished_at                                      AS latest_finished_at,
    coalesce(ld.tables_loaded, 0)                       AS tables_loaded,
    coalesce(ld.rows_loaded, 0)                         AS rows_loaded,
    ld.loaded_at                                        AS last_loaded_at,
    coalesce(ck.row_count_differences, 0)               AS row_count_differences,
    coalesce(ck.orphans, 0)                             AS orphans,
    coalesce(ck.checks, 0)                              AS checks,
    coalesce(ck.checks_failed, 0)                       AS checks_failed,
    coalesce(ck.app_checks, 0)                          AS app_checks,
    coalesce(ck.app_checks_ok, 0)                       AS app_checks_ok,
    coalesce(iss.critical_open, 0)                      AS critical_open,
    coalesce(iss.warning_open, 0)                       AS warning_open,
    coalesce(iss.info_open, 0)                          AS info_open,
    coalesce(so.signoffs_approved, 0)                   AS signoffs_approved,
    so.signoffs                                         AS signoffs,
    cut.go_live_at,
    cut.go_live_run
FROM sap._company c
-- latest run of any kind/status
LEFT JOIN LATERAL (
    SELECT r.run_id, r.kind, r.status, r.created_at, r.started_at, r.finished_at
      FROM erp.migration_run r
     WHERE r.company_code = c.company_code
     ORDER BY r.created_at DESC
     LIMIT 1
) lr ON true
-- what the raw copy holds now: the most recent load of this company (sap._load_log)
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE l.status IN ('loaded', 'count_mismatch', 'column_mismatch')) AS tables_loaded,
           sum(l.rows_loaded) FILTER (WHERE l.status IN ('loaded', 'count_mismatch', 'column_mismatch')) AS rows_loaded,
           max(l.loaded_at) AS loaded_at
      FROM sap._load_log l
     WHERE l.company_code = c.company_code
       AND l.run_id = (SELECT l2.run_id FROM sap._load_log l2 WHERE l2.company_code = c.company_code
                        ORDER BY l2.loaded_at DESC LIMIT 1)
) ld ON true
-- checks for this company from the most recent run that checked it (a cross-check covers every company)
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE k.area = 'row_counts' AND NOT k.ok)               AS row_count_differences,
           coalesce(max(k.raw_value) FILTER (WHERE k.area = 'orphans'
                                             AND k.check_name = 'orphan rows over all links'), 0)::bigint AS orphans,
           count(*)                                                                 AS checks,
           count(*) FILTER (WHERE NOT k.ok)                                         AS checks_failed,
           count(*) FILTER (WHERE k.area = 'app_tables')                            AS app_checks,
           count(*) FILTER (WHERE k.area = 'app_tables' AND k.ok)                   AS app_checks_ok
      FROM erp.migration_check k
     WHERE k.company_code = c.company_code
       AND k.run_id = (SELECT k2.run_id FROM erp.migration_check k2 WHERE k2.company_code = c.company_code
                        ORDER BY k2.checked_at DESC LIMIT 1)
) ck ON true
-- open issues on the latest run
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE i.severity = 'critical') AS critical_open,
           count(*) FILTER (WHERE i.severity = 'warning')  AS warning_open,
           count(*) FILTER (WHERE i.severity = 'info')     AS info_open
      FROM erp.migration_issue i
     WHERE i.run_id = lr.run_id AND i.status = 'open'
       AND (i.company_code IS NULL OR i.company_code = c.company_code)
) iss ON true
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE s.decision = 'approved') AS signoffs_approved,
           jsonb_object_agg(s.role, jsonb_build_object('decision', s.decision, 'signed_at', s.signed_at)) AS signoffs
      FROM erp.migration_signoff s
     WHERE s.run_id = lr.run_id
) so ON true
LEFT JOIN erp.company_cutover cut ON cut.company_code = c.company_code
WHERE erp.migration_can_read(c.company_code);

REVOKE ALL ON erp.migration_company_overview FROM PUBLIC, anon, authenticated;
GRANT SELECT ON erp.migration_company_overview TO authenticated;
GRANT SELECT ON erp.migration_company_overview TO service_role;
COMMENT ON VIEW erp.migration_company_overview IS
  'B5 Migration centre: one row per company the caller may read as admin/IT (erp.migration_can_read).';

-- ============ 3. Go live ============
-- Only a business (CFO) signer, only for a signed_off run of a company they can see, only once per company.
CREATE OR REPLACE FUNCTION erp.company_go_live(p_company varchar, p_run uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, pg_temp AS $$
DECLARE r erp.migration_run; v_at timestamptz;
BEGIN
  IF erp.current_user_id() IS NULL THEN RAISE EXCEPTION 'go-live needs a signed-in user' USING ERRCODE = '42501'; END IF;
  IF NOT erp.can_see(p_company) THEN RAISE EXCEPTION 'company % is not in your company list', p_company USING ERRCODE = '42501'; END IF;
  IF NOT erp.migration_can_sign('business') THEN
    RAISE EXCEPTION 'only the business (CFO) signer can take a company live' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO r FROM erp.migration_run WHERE run_id = p_run FOR UPDATE;
  IF NOT FOUND OR r.company_code <> p_company THEN RAISE EXCEPTION 'run % is not a run of %', p_run, p_company; END IF;
  IF r.status <> 'signed_off' THEN RAISE EXCEPTION 'run is %, go-live needs a signed-off run', r.status; END IF;
  PERFORM 1 FROM erp.company_cutover WHERE company_code = p_company FOR UPDATE;
  IF FOUND THEN RAISE EXCEPTION 'company % is already live', p_company; END IF;
  INSERT INTO erp.company_cutover (company_code, go_live_at, go_live_run, go_live_by)
  VALUES (p_company, now(), p_run, erp.current_user_id())
  RETURNING go_live_at INTO v_at;
  INSERT INTO erp.audit_log (actor, company_code, action, object, object_ref, detail)
  VALUES (erp.current_user_id()::text, p_company, 'company_go_live', 'migration_run', p_run::text,
          jsonb_build_object('go_live_at', v_at));
  RETURN v_at;
END $$;
REVOKE ALL ON FUNCTION erp.company_go_live(varchar, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.company_go_live(varchar, uuid) TO authenticated, service_role;

-- ============ 4. Storage: private bucket sap-exports ============
-- Object names: <company>/<run_id>/<relative path>. Upload with TUS (resumable). Limit = Pro plan maximum (500 GB);
-- lower it if the plan allows less (Free: 50 MB, which is too small for real exports).
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('sap-exports', 'sap-exports', false, 536870912000)
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = EXCLUDED.file_size_limit;

DROP POLICY IF EXISTS sap_exports_insert ON storage.objects;
CREATE POLICY sap_exports_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'sap-exports'
              AND erp.migration_is_admin()
              AND erp.can_see(((storage.foldername(name))[1])::varchar));

DROP POLICY IF EXISTS sap_exports_select ON storage.objects;
CREATE POLICY sap_exports_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'sap-exports'
         AND erp.migration_is_admin()
         AND erp.can_see(((storage.foldername(name))[1])::varchar));
-- No UPDATE / DELETE policies: the client can neither overwrite nor remove an uploaded file.

-- storage.objects policies call these as the signed-in user
GRANT USAGE ON SCHEMA erp TO authenticated;
GRANT EXECUTE ON FUNCTION erp.migration_is_admin(), erp.migration_can_read(varchar), erp.migration_can_sign(text) TO authenticated;

