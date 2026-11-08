# Final acceptance (P6)

Recorded 8 Nov 2026. ✅ passed · ⏳ blocked until the database is installed on Supabase (`docs/setup.md`) and the worker is running (`docs/worker.md`).

| # | Check | Result | How it was checked |
|---|---|---|---|
| 1 | `npm run build` passes; live on Vercel with only the two `VITE_` variables; no service key in `dist/` | ✅ | Build passes; https://sanford-super-erp.vercel.app deploys from GitHub `main`; Vercel env has only `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY`; grep of `dist/` for the secret key: 0 matches; security headers (CSP, `X-Frame-Options: DENY`, Referrer-Policy) confirmed on the live site |
| 2 | The 8 Nov Excel files reproduce B6 | ✅ live (field lists built from the real schema) · ⏳ Sanford's own files | File reader tested on look-alike Excel files (453 · 107 item fields, AUG1 repaired, structure-only); Live 8 Nov: 9 Excel field lists uploaded on the live site, auto-submitted, worker result: 3,262 tables / 112,904 fields, 3,250 matched, 12 left out, 0 missing, 0 type differences, AUG1 repaired on 9 fields, Start stays disabled |
| 3 | `testexp` goes queued → loading → rebuilding → checking → needs review, live on B7 | ◐ | Live 8 Nov: `testexp/AE01` (62 files) uploaded on the live site, Start → B7 updated live: Checking files → Loading (stage ok, 30 tables) → **failed at cast: out of shared memory** because `max_locks_per_transaction` is still 64. Re-run after raising it to 2048 |
| 4 | `broken` raises row-count and orphan issues; sign-off locked; wrong SAP report figure blocks sign-off | ⏳ | B8 lock and figure logic rendered with sample data; the rules themselves are enforced by `13_migration_console.sql` (tested by the backend team, `tests/mc_tests_result.txt`) |
| 5 | Stop mid-run / forced failure leaves the company unchanged | ◐ | Live 8 Nov: the lock failure above rolled back ("AE01 is exactly as before the run"), B7 showed the failed step, the message and the issue link. Stop mid-run still to test |
| 6 | Non-admin: no menu entry, blocked route, RLS error on direct RPC; signed-out gets nothing | ✅ | Chrome: Finance user sees no Back Office migration tabs and gets "No access" on B5; signed-out users are sent to sign-in. Database (8 Nov, `scripts/test-access.mjs`, 10/10 PASS): admin sees the overview, non-admin 0 rows, anonymous "permission denied for schema erp", non-admin upload to `sap-exports` refused, go-live refused before signed-off / for non-CFO / a second time |
| 7 | Closed tab mid-upload resumes | ◐ | Live: uploads to `sap-exports` work (TUS); the resume banner appeared correctly for a partly recorded upload. A real tab-close test is still to do. Fixed on the way: parallel files could lose their "done" mark |
| 8 | B5–B8 match the design at 1440 px, work at 390 px and in Arabic | ✅ | Chrome screenshots of every screen at 1440/390, EN/AR, compared with `design/` |

## Database
Installed 8 Nov 2026 with `node scripts/install-db.mjs`: 3,253 sap tables, 68 erp tables, 3,657 links; companies AE01–AE04; 13 and 14 run twice without errors.

## To finish the ⏳ rows
1. ~~Install the database~~ done.
2. Expose schema `erp`; raise `max_locks_per_transaction`.
3. Create the first users (`erp.app_user`, `erp.user_company`).
4. Start the worker.
5. Re-run rows 2–7 with `supabase/tests/testexp` and `supabase/tests/broken`.


## Worker change (8 Nov)
`supabase/worker/migration_worker.py`: with several field lists in one upload, the structure check now uses the **biggest**
file (the full `Table_With_Field.xlsx`) instead of the first by name (`ITM1.xlsx`). Without this the real 8 Nov upload
(9 Excel files) reported 1 table instead of 3,691. Only change to the delivered worker.
