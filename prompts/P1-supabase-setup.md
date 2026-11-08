# P1 · Supabase setup (read P0 first)

The database already holds `sap` and `erp` with files 00–13, installed by IT from `sanford-db-install`. Add only what the console needs, in two new files.

## `supabase/sql/14_realtime.sql`
- Add `erp.migration_run`, `erp.migration_step`, `erp.migration_check` and `erp.migration_issue` to the `supabase_realtime` publication. Make it idempotent: skip a table that is already in the publication.

## `supabase/sql/14_console_views.sql`
1. `erp.migration_company_overview`
   - A view with `security_barrier`.
   - Readable by the same admin/IT check the migration tables use (see `erp.migration_can_read` in 13).
   - One row per company from `sap._company`: code, name, SAP schema, latest run id, kind, status, started/finished, tables loaded, rows loaded, row-count differences, orphans, checks, failed checks, open issues by severity, sign-offs, go-live date.
   - The browser cannot read `sap`, so this view is how the centre screen gets its rows.
2. `erp.company_cutover(company_code pk, go_live_at, go_live_run uuid, go_live_by)`, with RLS: admin/IT read.
3. `erp.company_go_live(p_company, p_run)`
   - SECURITY DEFINER.
   - Only the business (CFO) signer may call it, and only for a run that is `signed_off`.
   - Writes `company_cutover` and `erp.audit_log`.
   - Refuses a second go-live.

## Storage
- Private bucket `sap-exports`.
- Policies on `storage.objects`:
  - insert and select only for admin/IT users.
  - The first path segment must be a company the user can see (`erp.can_see`).
  - No update. No delete from the client.
- Enable resumable uploads (TUS). Set the bucket's file size limit to the largest your plan allows.

## Project settings (write the steps in `docs/setup.md`)
- Exposed schemas: `erp` (remove `sap` if present).
- The rebuild runs as one transaction and takes about 38,000 locks. Before the first real load, run:
  `supabase postgres-config update --config max_locks_per_transaction=2048 --remote=<project-ref> --experimental` (CLI 1.69+, restarts the database).
- Generate types: `supabase gen types typescript --schema erp > src/lib/database.types.ts`.

## Done when
- Both files run twice without errors.
- An admin sees the overview rows. A non-admin sees 0 rows. Anonymous gets permission denied.
- A non-admin upload to `sap-exports` is refused.
- `company_go_live` is refused before `signed_off` and for a non-CFO.
