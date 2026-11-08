# P6 · B5 Migration centre, worker deploy, final tests (read P0 first; match `design/B5-migration-centre.jpg`)

## B5 Migration centre
- Data comes from `erp.migration_company_overview` (P1).
- Key numbers: companies loaded (x of 12), tables loaded, row-count differences, orphan links, checks passed.
- **By company** table: company, SAP database, export, tables, rows, row counts, orphans, app checks, signed. Each row opens that company's latest run (B7, or B8 when in review).
- **To fix before the final run**: open issues across companies, newest first.
- Buttons: Load log, Cross-check, **Upload backup** (primary → B6).

## Worker deploy (`worker/Dockerfile`, `docs/worker.md`)
- **Machine:** a small Linux VM or container in the same region as the Supabase project. Python 3.11, `pip install "psycopg[binary]" openpyxl requests`.
- **Files beside the worker:** `supabase/worker/*` plus the `02`, `03`, `04`, `04z` and `06` scripts from the `sanford-db-install` package. Pass them with `--scripts <folder>`. They are not in this repo.
- **Environment:** `DATABASE_URL` is the direct session connection, not the transaction pooler, because a run is one long transaction. Also set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
- **Command:** `python migration_worker.py --dsn "$DATABASE_URL" --source storage --poll --scripts /opt/sanford/sql`
- Run it as a systemd service or Docker restart policy. Logs go to stdout.

## Vercel
- Framework Vite. Add an SPA rewrite to `index.html`.
- Env vars: `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` only.
- Add security headers: CSP limited to self and the Supabase URL, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`.

## Final acceptance (all must pass; record results in `docs/acceptance.md`)
1. `npm run build` passes. The app is live on Vercel with only the two `VITE_` variables, and no service key is in the bundle (grep `dist/`).
2. The 8 Nov Excel files reproduce B6 exactly (P3 › Real case).
3. `supabase/tests/testexp` goes queued → loading → rebuilding → checking → needs review, with live updates on B7.
4. `supabase/tests/broken` raises the row-count and orphan issues, and sign-off is locked until they are resolved. A wrong SAP report figure also blocks sign-off.
5. Stop mid-run, or a forced failure, leaves the company's totals exactly as before.
6. A non-admin gets no menu entry, a blocked route, and an RLS error on a direct RPC. Signed-out users get nothing.
7. A closed tab mid-upload resumes.
8. B5–B8 match the design at 1440 px, work at 390 px, and work in Arabic.
