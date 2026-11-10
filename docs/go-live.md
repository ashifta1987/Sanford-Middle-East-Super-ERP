# Go-live runbook (A14)

How Super ERP moves from the phase branches to production: merge plan, Supabase apply order, Vercel set-up, monitoring, rollback, and the go-live checklist per company.

> **Nothing in this document has been run against the live Supabase project (`xhsfkbbcejgwvqxpqdgq`) or Vercel production.** Each step below is for Ashif or IT to run, in this order, on a Supabase **branch or test project first**.

---

## 1. Order of work

```
1. Supabase branch / test project: apply 15_stage1_overview → 29, run the suites, check health      (section 3)
2. Vercel Preview of the a14 pull request, pointed at that branch: click through as test users      (section 4)
3. Live Supabase: apply the same files in the same order, in a quiet window, recording each release  (section 3.5)
4. Merge the pull request into main → Vercel production deploy                                     (section 2)
5. Smoke test production, then start the per-company go-live checklists                            (sections 5, 7)
```

The database goes first. Every file from 15 onwards only adds tables or functions, or replaces functions while keeping their behaviour, so the **current production UI (main) keeps working on the new database**. The new UI needs the new functions, so it must not be deployed before the database is ready.

## 2. Merge plan

The phase branches are stacked. Each one was branched from the one before it and contains all of it:

```
main ← stage-1-erp-shell (already merged) ← a1-module-access ← a2-sales-order ← … ← a13-production-service ← a14-deploy-go-live
```

- **Recommended: one pull request, `a14-deploy-go-live` → `main`.** It contains Stage 1 and A1 to A14. Use **"Create a merge commit"**, not squash, so each phase's small commits stay readable in the history.
- The CI workflow (`.github/workflows/ci.yml`) runs on the pull request. It covers the env guard, typecheck, build and bundle secret check, and then every SQL suite (a1 … a14) on a throwaway Postgres 17. Both jobs must be green.
- Vercel builds a **Preview** for the pull request. Point Preview at the Supabase branch (section 4) and click through before merging.
- After the merge, the older branches (`a1-…` to `a13-…`) are fully contained in `main` and can be deleted. Keep `a14-deploy-go-live` until production has been checked.
- If you'd rather review phase by phase: open `a1 → main` first, then retarget `a2 → main` after each merge. The result is the same, but it takes 14 merges.

## 3. Supabase: apply on a branch first

### 3.1 Before you start
- **Backups:** turn on point-in-time recovery (Pro plan add-on), then **do a test restore into a new project** so you know a restore actually works. Write the restore time down in the release log (section 8).
- **Exposed schemas:** API settings → exposed schemas must be **`erp` only**. `sap` must not be exposed.
- **Database setting:** `max_locks_per_transaction = 2048` before any real SAP load (`docs/hosting.md`).
- **Branch:** create a Supabase branch, or a separate test project restored from the latest backup, so it has the same 10–14 objects as live.

### 3.2 Files and order
The list is also in `scripts/local-stack/sql-order-supabase.txt`.

| # | File | Notes |
|---|---|---|
| — | 10_erp_schema, 11_erp_sync, 12_erp_security, 13_migration_console, 14_realtime, 14_console_views, 14_signoff_inbox | **Already live.** Don't re-run them: 10 and 12 were written before the "safe to run twice" rule and stop with "already exists". |
| 1 | `15_stage1_overview.sql` | Home KPIs and Control Tower checks (Stage 1). Check whether it is already live (`select to_regproc('erp.home_kpis')`). It is safe to run again. |
| 2 | `16_module_access.sql` | A1 module levels (Full / Read / None) |
| 3 | `17_sales_order.sql` | A2 |
| 4 | `18_posting.sql` | A3 posting engine, period lock |
| 5 | `19_sales_cycle.sql` | A4 |
| 6 | `20_banking.sql` | A5 |
| 7 | `21_purchasing.sql` | A6 |
| 8 | `22_inventory.sql` | A7 |
| 9 | `23_master_data.sql` | A8 |
| 10 | `24_hr.sql` | A9 |
| 11 | `25_admin.sql` | A10 (replaces `erp.can_see`: a deactivated user sees no company) |
| 12 | `26_reports.sql` | A11 |
| 13 | `27_migration_more.sql` | A12 (re-creates `erp.sync_company` with 4 more steps) |
| 14 | `28_production_service.sql` | A13 |
| 15 | `29_go_live.sql` | A14: go-live checklist, release log, `system_health()`, checklist gate on `company_go_live` |
| 16 | `30_numbering_company.sql` | B1: pilot company AE05 (also added to `sap._company`), Document Numbering (several series per type, user defaults), decided rule changes (decisions of 10 Nov 2026) |
| 17 | `31_approvals.sql` | B2: Approval Process (Approval Stages, Approval Templates, Approval Status Report). Migrates the existing `approval_rule` rows into templates; incoming payments can need approval. No templates are seeded for AE01–AE05 |
| 18 | `32_gl_setup.sql` | B3: G/L Account Determination by tab with item group and warehouse accounts, Warehouses, Item Groups, Landed Cost types, Resources, standard goods receipt / issue reasons (seeded for AE01–AE05 without accounts), bank statement formats and the matching rule. No accounts are seeded for AE01–AE05 |
| 19 | `33_multicurrency.sql` | B4: documents and payments in the business partner's currency (rates from Exchange Rates), foreign-currency amounts on journals, realised FX gain/loss at payment, soft-switch stock (SAP on-hand + Super ERP movements; the sync no longer wipes Super ERP stock). Generated from `supabase/sql/src/33_multicurrency/` |

- **Never** run `15_sample_company.sql` or `scripts/local-stack/test-users.sql` on live. They are a fictional company and fictional users. On a throwaway branch they are fine for running the test suites (3.3).
- Files 15–33 were applied twice in a row on a fresh database **without** the sample company. Every file passed both times (CI checks this as well).
- **How to run each file:** in the SQL editor, paste the whole file and run it once. Or use `psql "$BRANCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/sql/<file>`. Stop at the first error and don't carry on with later files.

### 3.3 Tests on the branch
1. On the branch only, load the fictional data: `15_sample_company.sql`, then `scripts/local-stack/test-users.sql`.
2. Run each suite, `supabase/tests/a1_module_access.sql` to `a14_go_live.sql`, then `b1_numbering_company.sql` (after `scripts/local-stack/test-users-b1.sql`). Each one prints PASS/FAIL rows and a TOTAL row, and rolls back.
3. Expected result, the same as local and CI: **15 suites, 1,797 checks passed, 0 failed.**
4. Throw the branch away afterwards, or remove ZZ99 if it is a long-lived test project.

The `a14_go_live.sql` suite runs the same checks as the advisors (RLS on every table, `search_path` on every definer function, nothing callable by anon).

### 3.4 Verification queries (SQL editor, as `postgres`)
```sql
-- every phase function is in place (expect 18 rows, all true)
select f, exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'erp' and p.proname = f) as present
  from unnest(array['company_go_live','migration_inbox','home_kpis','module_level','sales_order_save','journal_submit','sales_delivery_create',
                    'bank_statement_import','landed_cost_create','inv_count_create','bp_save','leave_checks','admin_users','control_findings',
                    'custom_field_setup','prod_order_create','system_health','doc_series_save']) f;
-- RLS on every erp table (expect 0 rows)
select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'erp' and c.relkind in ('r','p') and not c.relrowsecurity;
-- definer functions anon could call (expect 0 rows)
select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'erp' and p.prosecdef and has_function_privilege('anon', p.oid, 'EXECUTE');
-- definer functions without a fixed search_path (expect 0 rows)
select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'erp' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) x where x like 'search_path=%');
-- direct write grants (expect exactly the 4 RLS-guarded ones from 12: shop_visit, shop_visit_item, trade_request, trip_stop)
select c.relname, r.rol from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join (values ('authenticated'),('anon')) r(rol)
 where n.nspname = 'erp' and c.relkind in ('r','p','v','m')
   and (has_table_privilege(r.rol, c.oid, 'INSERT') or has_table_privilege(r.rol, c.oid, 'UPDATE') or has_table_privilege(r.rol, c.oid, 'DELETE'));
```
Then open **Advisors → Security** and **Advisors → Performance** in the Supabase dashboard and fix every **error**. Write down any warnings in the release log.

Once signed in to the app, **Administration › Implementation Center › Go-live checklist › System health** (`/admin/health`) shows the same checks, the SQL files in place, the release log, and each company's last SAP load and go-live state.

### 3.5 Apply to live
Use the same files in the same order, in a quiet window (no migration run active). Afterwards, record every file in the release log:
```sql
select erp.schema_release_record(f, 'live', 'Ashif', 'A14 go-live apply')
  from unnest(array['15_stage1_overview.sql','16_module_access.sql','17_sales_order.sql','18_posting.sql','19_sales_cycle.sql','20_banking.sql',
                    '21_purchasing.sql','22_inventory.sql','23_master_data.sql','24_hr.sql','25_admin.sql','26_reports.sql',
                    '27_migration_more.sql','28_production_service.sql','29_go_live.sql','30_numbering_company.sql','31_approvals.sql',
                    '32_gl_setup.sql','33_multicurrency.sql']) f;
```
Do the same on the branch with `'branch'`. `schema_release_record` can only be run from the SQL editor (postgres) or with the service role. Signed-in users can only read the log, on the System health page.

### 3.6 Edge Functions
| Function | Deploy | Secrets it needs (names only) |
|---|---|---|
| `invite-user` (A10: invitations; the service key stays on the server) | `supabase functions deploy invite-user` | `APP_URL` (the production app address, for the invitation link). `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided by Supabase automatically. |
| `ai-assistant` (A10 settings, A11 Ask AI) | `supabase functions deploy ai-assistant` (only once a provider is chosen) | `AI_API_KEY`. Without it the app shows "AI not configured" and nothing is sent anywhere. |

Deploy them to the branch first (Preview), then to live. `supabase secrets set NAME=…` is run by Ashif or IT. The values never go into the repo or into Vercel.

### 3.7 Auth settings (dashboard)
- Email sign-in only. **Turn off "Allow new users to sign up"**: users join only through the Administration invitation.
- Password rules: minimum length and character classes as decided by Ashif. Turn on leaked-password protection.
- Site URL and redirect URLs: the production domain, plus the Vercel Preview domain pattern for the branch.
- **MFA for admin and finance positions:** turn on TOTP MFA in Auth. The app does not yet have an MFA enrolment screen or an enforcement check, so this is listed under "Needs from Ashif" and "What is left".

## 4. Vercel

| Setting | Value |
|---|---|
| Project | One project linked to the GitHub repo. Production branch `main`. Preview deployments for every pull request. |
| Framework / build | From `vercel.json`: Vite, `npm ci`, `npm run build`, output `dist`. |
| Region | Static site served from the edge (Dubai `dxb1` is closest). No server functions. |

**Environment variables: only these two.**

| Name | Production | Preview |
|---|---|---|
| `VITE_SUPABASE_URL` | `https://xhsfkbbcejgwvqxpqdgq.supabase.co` | the Supabase branch / test project URL |
| `VITE_SUPABASE_ANON_KEY` | live **publishable (anon)** key | the branch's publishable (anon) key |

- `npm run build` starts with `scripts/check-env.mjs`. It **fails the build** if any `VITE_*` name looks like a secret (`SERVICE_ROLE`, `SECRET`, `PASSWORD`, `DATABASE_URL`, `PRIVATE`, `ACCESS_TOKEN`), if the anon key is a `service_role` JWT or an `sb_secret_…` key, or if the URL isn't https. Values are never printed.
- `scripts/check-bundle.mjs` runs after the build. It fails if a secret key or a `service_role` token ended up in `dist/assets`.
- **Headers (`vercel.json`):**
  - CSP: `default-src 'self'`, connect/img to `https://*.supabase.co` and `wss://*.supabase.co`, `frame-ancestors 'none'`, `object-src 'none'`.
  - `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `nosniff`, HSTS (2 years), COOP `same-origin`.
  - `Permissions-Policy`: camera off, geolocation and microphone for this site only. Geolocation is for the A9 phone check-in; the old `geolocation=()` would have blocked it.
- **Exact Supabase project in the CSP:** each build also writes a CSP `<meta>` tag with the exact `VITE_SUPABASE_URL`. Browsers apply both policies, so a production build can only talk to the live project and a Preview build only to its branch, even though the header allows any `*.supabase.co`.
- **Caching:** `/assets/*` (hashed file names) is cached for a year as immutable. Everything else, including `index.html` for every route, is `no-cache`, so a new deploy is picked up on the next page load.
- **Bundle:** pages load per route (`React.lazy`), and the PDF and Excel libraries load on demand. The start-up script is about 96 kB (it was 1.97 MB), plus cacheable vendor and translation chunks.
- **Rollback:** Vercel → Deployments → the previous production deployment → **Instant Rollback**. This only rolls back the UI; the database keeps the new functions, which the old UI ignores.

## 5. Monitoring and health checks
| What | Where | How often |
|---|---|---|
| App health (SQL files, RLS / grants / definer checks, releases, last SAP load and go-live per company) | `/admin/health` (Administration, IT, owner) | Daily during hypercare, then weekly |
| Supabase advisors (security, performance) | Supabase dashboard → Advisors | After every SQL release, and weekly |
| Database, API and Auth logs, slow queries | Supabase dashboard → Logs / Query performance | When something is reported |
| Edge Function errors | Supabase → Edge Functions → logs | During hypercare |
| Uptime | An external monitor (e.g. UptimeRobot) on the production URL (`/`, expect 200) and `https://<project>.supabase.co/auth/v1/health` (expect 200) | Every 5 minutes |
| Deploys and build failures | Vercel → Deployments (email on failure) | Each deploy |
| Migration worker | `sudo journalctl -u sanford-worker -f` on the EC2 worker (`docs/hosting.md`) | During migration waves |
| Daily reconciliation (hypercare) | Migration console → Cross-check for the company's go-live run (linked from checklist step 7) | Daily for 2 weeks after go-live |

## 6. Rollback
| Problem | Do this |
|---|---|
| New UI misbehaves after the merge | Vercel **Instant Rollback** to the previous production deployment. No database change is needed. |
| A SQL file fails half-way on live | The failed statement is rolled back on its own. Fix the cause, then run **the same file again**; files 15–29 are safe to re-run. Don't skip ahead to later files. |
| A replaced function behaves wrongly | Re-run the earlier file that defined it (for example, `company_go_live` is defined in `14_console_views.sql`, section 3), or restore that one function from the previous file. Record the change in the release log. |
| Data damaged or wrong file applied | **Point-in-time recovery** to just before the apply (check the restore first, 3.1). Then re-apply the files that should be there. |
| A company went live too early | `erp.company_cutover` is written only by the CFO through the checklist, and there is no "undo" in the app. A database admin can delete that row in the SQL editor, which restarts the SAP sync for that company. Write down why in the release log and in the audit trail. |

Posted journals are permanent (a trigger enforces this). Mistakes are corrected with reversals, never by deleting rows.

## 7. Go-live checklist per company
Each company works through this in the app at **Administration › System Initialization › Implementation Center** (`/admin/go-live`). Steps go in order. Every tick records who, when, a note and, where required, a reference. Steps 2–5 lock once the company is live. The CFO's **Go live** button only works once steps 1–5 are done, and the database enforces this as well (`company_go_live`).

| # | Step | Who records it | Evidence the app asks for |
|---|---|---|---|
| 1 | Migration run signed off by Finance, IT and Business | Automatic (console sign-offs) | Signed-off run with 3 approvals |
| 2 | Ashif's written approval to import production data | System admin | Where the approval is kept (email date and subject, or document reference). **Required.** |
| 3 | Users invited, positions and limits set, test sign-in by each department head | System admin | At least one active user other than the person ticking, and no unaccepted invitations |
| 4 | Opening balances reconciled (migration plan §5) | System admin, after Finance confirms | Note |
| 5 | SAP posting frozen → final backup → final run → reconcile → sign | System admin | Final backup reference. **Required.** |
| 6 | Go-live date recorded (`company_cutover`). The SAP sync stops and Super ERP becomes the source of truth | CFO (business signer), **Go live** button | Automatic |
| 7 | Hypercare for 2 weeks: daily reconciliation, issue list, fast fixes | System admin | Available 14 days after go-live, and only with no open issue |

### Per-company sign-off sheet (fill in as you go)
| Step | AE05 ATMM General Trading (pilot) | AE01 Sanford Middle East DWC | AE02 A.T.M.M. Electronics | AE03 Abdulla Mohamed Home Appliances | AE04 Izaan General Trading |
|---|---|---|---|---|---|
| 1 Run signed off | | | | | |
| 2 Written approval (ref.) | | | | | |
| 3 Users ready | | | | | |
| 4 Opening balances | | | | | |
| 5 SAP frozen, final run (backup ref.) | | | | | |
| 6 Go-live date | | | | | |
| 7 Hypercare closed | | | | | |

**Pilot:** AE05 · UAE - ATMM GENERAL TRADING LLC (decisions of 10 Nov 2026, seeded by `30_numbering_company.sql`). Its SAP backup is uploaded later through the Migration console and its go-live date is planned after that. Before its first document, enter its numbering series in Administration › System Initialization › Document Numbering (nothing is seeded for real companies). Start the next company only after the pilot's hypercare closes.

### Hypercare (2 weeks per company)
- **Daily:** open the company's cross-check (step 7 link) and compare the totals. Then check `/admin/health` (last SAP load must stop updating for a live company) and the Approvals inbox.
- **Issues:** log each one on the checklist page (critical / normal) and close it with how it was fixed. Step 7 can't close while an issue is open.
- **Fast path for fixes:** branch from `main` → pull request (CI) → Preview on the Supabase branch → merge. Any SQL fix goes in a **new** numbered file, on the branch first, then live, and is recorded in the release log.

## 8. Release log
The database keeps its own log (`erp.schema_release`, shown on `/admin/health`). Keep this table as the human record:

| Date / time (GST) | Environment | Files | Applied by | Restore point / backup | Advisors clean? | Notes |
|---|---|---|---|---|---|---|
| | branch | 15_stage1_overview → 29 | | | | |
| | live | 15_stage1_overview → 29 | | | | |
