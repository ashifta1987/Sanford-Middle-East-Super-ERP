# Final acceptance (P6)

Recorded 8 Nov 2026. ✅ passed · ⏳ blocked until the database is installed on Supabase (`docs/setup.md`) and the worker is running (`docs/worker.md`).

| # | Check | Result | How it was checked |
|---|---|---|---|
| 1 | `npm run build` passes; live on Vercel with only the two `VITE_` variables; no service key in `dist/` | ✅ | Build passes; https://sanford-super-erp.vercel.app deploys from GitHub `main`; Vercel env has only `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY`; grep of `dist/` for the secret key: 0 matches; security headers (CSP, `X-Frame-Options: DENY`, Referrer-Policy) confirmed on the live site |
| 2 | The 8 Nov Excel files reproduce B6 | ✅ (sample data) · ⏳ real | File reader tested on look-alike Excel files (453 · 107 item fields, AUG1 repaired, structure-only); B6 rendered in Chrome with the 8 Nov figures matches the design. Needs the real files + worker for the server-side check |
| 3 | `testexp` goes queued → loading → rebuilding → checking → needs review, live on B7 | ⏳ | Client side: `testexp/AE01` read as 30 tables + columns.csv + row_counts.csv; B7 live view rendered with sample data. Needs DB + worker |
| 4 | `broken` raises row-count and orphan issues; sign-off locked; wrong SAP report figure blocks sign-off | ⏳ | B8 lock and figure logic rendered with sample data; the rules themselves are enforced by `13_migration_console.sql` (tested by the backend team, `tests/mc_tests_result.txt`) |
| 5 | Stop mid-run / forced failure leaves the company unchanged | ⏳ | Worker behaviour (`tests/safety_tests_result.txt`); UI Stop run + "Stopping after the current step…" built |
| 6 | Non-admin: no menu entry, blocked route, RLS error on direct RPC; signed-out gets nothing | ✅ UI · ⏳ RLS | Chrome: Finance user sees no Back Office migration tabs and gets "No access" on B5; signed-out users are sent to sign-in. RLS needs the DB |
| 7 | Closed tab mid-upload resumes | ⏳ | Upload URLs and finished files kept in IndexedDB, "Resume upload" banner built; needs the `sap-exports` bucket |
| 8 | B5–B8 match the design at 1440 px, work at 390 px and in Arabic | ✅ | Chrome screenshots of every screen at 1440/390, EN/AR, compared with `design/` |

## To finish the ⏳ rows
1. Install `sanford-db-install` 00 → 13 on Supabase, then `14_realtime.sql` and `14_console_views.sql`.
2. Expose schema `erp`; raise `max_locks_per_transaction`.
3. Create the first users (`erp.app_user`, `erp.user_company`).
4. Start the worker.
5. Re-run rows 2–7 with `supabase/tests/testexp` and `supabase/tests/broken`.
