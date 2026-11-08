-- Sanford ERP - 14_signoff_inbox.sql
-- Approvals inbox for sign-off users (Finance, IT, CFO). They cannot read erp.migration_run (admin/IT only),
-- so this SECURITY DEFINER function lists the runs waiting for them: runs that need review (or are signed off and
-- not live yet) in companies they can see, with what each role has decided. Safe to run again.

CREATE OR REPLACE FUNCTION erp.migration_inbox()
RETURNS TABLE (run_id uuid, company_code varchar, company_name text, kind text, status text, finished_at timestamptz,
               critical_open bigint, warning_open bigint, signoffs jsonb, my_roles text[], waiting_for_me boolean, live boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = erp, pg_temp AS $$
  WITH me AS (
    SELECT coalesce(array_agg(DISTINCT m.role ORDER BY m.role), '{}') AS roles
      FROM erp.migration_role_module m WHERE erp.has_module(m.module)
  )
  SELECT r.run_id, r.company_code, c.legal_name, r.kind, r.status, r.finished_at,
         (SELECT count(*) FROM erp.migration_issue i WHERE i.run_id = r.run_id AND i.status = 'open' AND i.severity = 'critical'),
         (SELECT count(*) FROM erp.migration_issue i WHERE i.run_id = r.run_id AND i.status = 'open' AND i.severity = 'warning'),
         (SELECT coalesce(jsonb_agg(jsonb_build_object('role', o.role, 'decision', o.decision, 'signed_at', o.signed_at) ORDER BY o.role), '[]')
            FROM erp.migration_signoff o WHERE o.run_id = r.run_id),
         me.roles,
         r.status = 'needs_review' AND EXISTS (
           SELECT 1 FROM unnest(me.roles) x(role)
            WHERE NOT EXISTS (SELECT 1 FROM erp.migration_signoff o WHERE o.run_id = r.run_id AND o.role = x.role AND o.decision = 'approved')),
         EXISTS (SELECT 1 FROM erp.company_cutover k WHERE k.go_live_run = r.run_id)
    FROM erp.migration_run r
    JOIN sap._company c USING (company_code)
    CROSS JOIN me
   WHERE cardinality(me.roles) > 0
     AND erp.can_see(r.company_code)
     AND r.kind <> 'structure_only'
     AND r.status IN ('needs_review', 'signed_off')
   ORDER BY (r.status = 'needs_review') DESC, r.finished_at DESC NULLS LAST
   LIMIT 50
$$;
REVOKE ALL ON FUNCTION erp.migration_inbox() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.migration_inbox() TO authenticated, service_role;
