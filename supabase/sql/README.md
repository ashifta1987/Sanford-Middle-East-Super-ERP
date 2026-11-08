# Sanford ERP backend: corrected raw SAP layer + app layer

Corrected 6 Nov 2026 from the delivered scripts (`00_table_inventory.xlsx`, `01a`–`05`), for
12 companies that each have their own SAP Business One database. Revised the same day after an
independent review (security, loader, SAP -1 values, history tables, speed).

## Run order

| Step | File | When |
|---|---|---|
| 1 | `00_setup.sql` | Once. Company register (`sap._company`, one row per company) and load log. |
| 2 | `01a_sap_standard.sql`, `01b_addon_udt.sql` | Once. 3,250 raw tables, each with `company_code`. (01c, the ALT_HR working tables, is not used.) |
| 3 | `05_hana_export.sql` | On HANA, once per company: save query 1 as `columns.csv`, query 2 as `constraints.csv`, query 4 as `row_counts.csv`, then run the export (query 9). |
| 4 | `load_company.py` | Once per company: `python load_company.py --company AE01 --export <folder> --columns columns.csv --counts row_counts.csv --dsn <db>` |
| 5 | `02_clean_blank_keys.sql` | After all companies are loaded: blank text links and SAP's built-in -1 values become NULL. |
| 6 | `03_orphan_check.sql` | Must return no rows. Matches inside the same company only. |
| 7 | `04_foreign_keys.sql` | 3,656 links + indexes, each led by `company_code`; added NOT VALID, then validated. |
| 8 | `python apply_keys.py constraints.csv`, then `07_real_keys.sql` | Swaps the 1,710 guessed keys for SAP's real ones and rewrites 02/03/04/04z to match. |
| 9 | `06_security.sql` | Locks the raw layer away from the API. Also remove `sap` from Supabase's exposed schemas. |
| 10 | `10_erp_schema.sql`, `11_erp_sync.sql`, `12_erp_security.sql` | The app layer the React app uses. |
| 11 | `13_migration_console.sql` | The admin Migration console (tables, access rules, cross-check). Safe to run again. |
| 12 | `CALL erp.sync_company('AE01');` then `SELECT * FROM erp.check_sync('AE01');` and `SELECT * FROM erp.check_deleted('AE01');` | Per company. Commits after each step; progress in `erp.sync_log`. Every check must say `ok`. |
| 13 | `python migration_worker.py --dsn <db> --source storage --poll` | Runs on a server next to these files. Rebuilds a company each time the console queues a run (see below). |

Reload a company once links exist: `04z_drop_foreign_keys.sql`, the loader, then 02, 03, 04. If
`apply_keys.py` has run, these files already use the real keys. The migration worker does exactly this for
one company (02 limited to that company) and then syncs and cross-checks; use it instead of doing it by hand.

## What changed against the delivered scripts

1. **Company code everywhere.** The delivered schema had no company column, so 12 SAP databases
   would collide: `C0001`, `DocEntry 1` and `TransId 1` exist in every one. Every table starts with
   `company_code` (filled by the loader) and it leads every primary key, link and index. Tested: the
   old orphan check passed a Saudi invoice line pointing at a UAE-only item; the new one catches it.
2. **History tables no longer link to live tables.** 366 history/log tables are recognised from the
   vendor inventory's history list, SAP A-tables that mirror a live table (AITB→OITB, AOCR→OOCR),
   and add-on log tables (`@A…`), matching LogInstanc in any spelling. 131 links from them to live
   tables are dropped; links inside history are kept.
3. **SAP's -1 values.** SAP uses -1 for "manual" unit of measure, "last purchase price" list,
   "no branch" and similar. Part 2 of `02` sets -1 to NULL in 454 number link columns, only where the
   parent has no -1 row in that company. Required columns and key columns are not touched.
4. **Two keyless SAP tables** (OCAN, ODON) get a `_row_id` key (with `company_code`).
5. **Guessed keys flagged.** 1,710 tables use the "all required columns" key and are marked
   `[provisional key]`. `apply_keys.py` replaces them with SAP's keys and rewrites the link scripts.
6. **A loader.** The HANA CSV has no header and the delivered table definitions are not in HANA
   column order. `load_company.py` takes column order from query 1 (or each table's `create.sql`),
   reads only `data.csv` / `data.csv.N` (not `data.ctl`), stages as text, decodes binary columns from
   hex, casts into the typed table, and logs rows loaded against `row_counts.csv`. Tables whose
   columns differ from the export are loaded but marked `column_mismatch`.
7. **05 queries added.** Company details (`OADM`), the 7 HANA views that are not tables (`OINM`,
   `OIBT`, `IBT1`, `OSRD`, `OSRI`, `SRI1`, `VTSP`), and the data export itself.

## The app layer (`erp` schema)

59 tables with readable names that keep SAP's codes and numbers (`card_code`, `item_code`,
`whs_code`, `acct_code`, `doc_entry` + `doc_num`, `trans_id`), filled from `sap` by 83 steps:
masters (with merchandiser slots, certificates, market prices, Top 100), all 19 SAP marketing and
stock documents (`document` / `document_line`, `sign` = -1 for credit notes and returns,
`cancellation` for the document that cancels another), journals, payments (with `doc_type` and the
journal line they paid), inter-company map (CTX), HR from the ALT_HR add-on (org units, employees,
ID documents, basic pay from `@ALT_HR_BASICPAYL`, leave types, payroll results by wage code, air
tickets), 3PL jobs, packaging artwork, supplier proforma invoices, trademarks.

* Each step only rewrites rows that changed; a second run on unchanged data writes 0 rows.
* "Active" for customers and items follows SAP's frozen/valid date ranges.
* The sync only adds and updates. `erp.check_deleted()` lists rows that have gone from SAP.

## Access rules (`12_erp_security.sql`)

* Data synced from SAP is **read-only** to app users. Postings, orders and approvals will go through
  functions that check the user's position and limits (to be built with the app).
* A user sees only the companies listed in `erp.user_company` and cannot change that list or
  `erp.app_user`.
* Salary, payroll, ID documents and air tickets: HR positions, or the employee's own record.
* App records: a field user writes only their own visits; a trade request only in their own name;
  a driver updates only the stops on their own trips.
* Posted journals cannot be updated, deleted or added to, and a new journal must balance
  (checked once per insert). Only the sync and the service role write journals.
* The sync procedure, sync log and audit log are not callable or readable by app users
  (audit log: admin positions only). Anonymous users have no access to the schema.

## Tested (Postgres 16, the engine Supabase runs)

* Delivered scripts: run without errors on empty tables.
* Corrected pipeline with two companies sharing codes: load, 02 (including -1 values), 03, 04
  (3,657 links validated), app layer, sync, all `check_sync` rows ok, second sync writes 0 rows.
* Access: a finance user could not change customers, grant access or add journal lines; saw no
  salaries; HR saw them; an employee saw only their own; anonymous users had no access; a
  merchandiser could log a visit only as themselves.
* Loader on test export folders: shuffled columns, Arabic, quotes and commas in names, nine-digit
  time fractions, `data.ctl` present, binary columns, NCHAR and SMALLDECIMAL types, extra columns,
  count mismatch. **Not yet tested on a real HANA export:** check one table with long text (NCLOB)
  and one with binary columns on the first real folder, because their layout depends on the HANA version.
* Speed: 1.5 million journal lines for one company synced in 41 s the first time and 8.5 s when
  nothing had changed (test machine; Supabase timing depends on the plan's compute size).
* `apply_keys.py`: key swapped, the link that no longer fits removed, and the reload path
  (04z, 02, 03, 04) ran clean afterwards.
* 8 Nov 2026, full rebuild in a fresh database (00 → 13) from HANA-style export folders made from the
  two-company seed (`mctest/rebuild.sh`, `mctest/make_testexp.py`): 54/54 tables loaded with matching counts,
  0 orphans, 3,657 links validated, all check_sync ok, second sync 0 rows, access rules unchanged, 13 runs twice.
* Migration console (`mctest/mc_tests.py`, 60 checks): clean reload ok in every step; a broken upload (one
  journal line deleted, one invoice line pointing at a missing item) ended in needs_review with 9 critical issues
  (row count, orphan, unbalanced journal, trial balance, account group, supplier balance, check_sync) and refused sign-off;
  only that link stayed NOT VALID and the other company was unchanged; after the issues were accepted, finance,
  IT and business signed it off. The real field list (`Table_With_Field.xlsx`: 3,691 tables, 117,772 fields)
  matched 3,250 tables, 441 not in the schema, 0 missing columns, 0 type mismatches, AUG1 repaired, no data
  touched. RLS: anonymous users have no access; non-admins read 0 rows and cannot call worker functions; an admin
  limited to AE01 sees no SA01 run. `--source storage` was tested against a local mock of the Storage API
  (`mctest/storage_mock_test.py`), not against Supabase itself.
* Failure safety, Stop run and report figures (`mctest/safety_tests.py`, 34 checks). An unreadable CSV, a duplicate
  key in the last table cast, and an app-sync failure after the raw rows, 02 and 04 were done each ended `failed`.
  "Stop run" after `cast` ended `cancelled` before the next step. Each time, SA01's raw rows and hashes, app rows,
  check_sync totals, load log and links were identical to before, and AE01 was unchanged. Report figures: 8 missing
  warnings, a wrong A/P figure gave a critical issue and blocked sign-off, the corrected one cleared it, and the
  figures survived a cross-check re-run.

## Migration console (`13_migration_console.sql`, `migration_worker.py`)

An admin uploads one company's HANA export (or a structure-only field list), the worker rebuilds that company
and cross-checks every company, and finance, IT and business sign the run off.

**Flow.** UI: `migration_request` → upload the files to Storage bucket `sap-exports` under the returned run's
`storage_prefix` (`<company>/<run_id>/`; a .zip/.tar.gz of the export folder is fine) → `migration_submit`.
Worker: `queued` → `validating` → `loading` → `rebuilding` → `checking` → `needs_review` (or `failed`, with a
critical issue and the failed step's message). Admin resolves or accepts issues. Finance, IT and business each
call `migration_sign`; when all three have approved, the run becomes `signed_off`.

**Tables** (schema `erp`; readable by positions with module `admin` or `it`, for companies in their
`user_company` list; written only by the worker and the functions below):

| Table | Holds |
|---|---|
| `migration_run` | run_id, company_code, kind (`full` / `tables` / `structure_only`), status, created_by, created_at, started_at, finished_at, storage_prefix, notes, worker, stop_requested_at, stop_requested_by |
| `migration_file` | every uploaded file: path, kind (`data_csv`, `create_sql`, `columns_csv`, `constraints_csv`, `row_counts_csv`, `structure_xlsx`, `structure_csv`, `other`), bytes, table_name, status, message |
| `migration_step` | step_no, code, status (`pending` / `running` / `ok` / `warning` / `failed` / `skipped`), rows, started_at, finished_at, message |
| `migration_check` | company_code, area (`structure`, `row_counts`, `orphans`, `app_tables`, `finance`, `stock`, `hr`), check_name, sap_value (SAP's own figure or the expected value), raw_value (sap schema = "SAP copy"), app_value (erp), difference, ok (raw vs app), detail, report_value + report_source (the "SAP report" figure, copied from migration_report_figure) |
| `migration_report_figure` | run_id, company_code, area, check_name, value, source, entered_by, entered_at: figures Finance prints from SAP; kept when the cross-check is re-run |
| `migration_issue` | severity (`critical` / `warning` / `info`), area, title, detail, table_name, status (`open` / `accepted` / `fixed`), resolved_by, resolved_at, note |
| `migration_signoff` | role (`finance` / `it` / `business`), signed_by, signed_at, decision, comment |
| `migration_role_module` | which position modules may sign which role: finance→`finance`, it→`it`/`admin`, business→`business`/`sales` |

**What the React app calls** (`supabase.schema('erp').rpc(...)`; add `erp` to the exposed schemas):

| Call | Who | Returns |
|---|---|---|
| `migration_request(p_company, p_kind, p_notes)` | admin/IT | `uuid` run_id (status `uploading`) |
| `migration_submit(p_run)` | admin/IT | `'queued'` |
| `migration_cancel(p_run)` ("Stop run") | admin/IT | uploading/queued: `'cancelled'` at once; validating/loading/rebuilding/checking: `'stop_requested'` (the worker stops before its next step, rolls the company back and marks the run `cancelled` with an info issue) |
| `migration_status(p_run)` | admin/IT, or a sign-off user | one row per step: run_id, company_code, kind, run_status, created_at, started_at, finished_at, step_no, step_code, step_status, step_rows, step_started_at, step_finished_at, step_seconds, step_message, files, data_files, tables_loaded, checks, checks_failed, critical_open, warning_open, info_open, signoffs (jsonb), stop_requested_at, stop_requested_by, report_figures, report_missing |
| `migration_review(p_run, p_area default null)` | admin/IT; sign-off users once the run needs review | item (`issue` / `check`), id, company_code, area, name, severity, status, sap_value, raw_value, app_value, difference, ok, detail, report_value, report_source, report_ok, report_required |
| `migration_set_report_figure(p_run, p_company, p_area, p_check_name, p_value, p_source)` | finance sign-off users, admin/IT; while the run needs review; `p_value` null removes it | check_name, report_value, raw_value, app_value, report_ok |
| `migration_resolve_issue(p_issue, p_status, p_note)` | admin/IT; accepting a critical issue needs a note | the new status |
| `migration_sign(p_run, p_role, p_decision, p_comment)` | a user whose position carries a module for that role | the run status (`needs_review` or `signed_off`); refused while a critical issue is open |
| `from('migration_run' / 'migration_file' / 'migration_step' / 'migration_check' / 'migration_issue' / 'migration_signoff')` | admin/IT | the rows (RLS) |

Every request, submit, cancel, issue decision and sign-off is written to `erp.audit_log`.
Worker-only (service role / owner, not callable by app users): `migration_cross_check(p_company, p_run)`
(NULL company = every in-scope company; returns companies, checks, failed, critical_open, warning_open, info_open),
`migration_orphans(p_company)` (orphans per link for one company, from `sap._link`, which 03 refreshes),
`migration_sync_company(p_company)` (the 83 steps of `erp.sync_company`, read from it, in one transaction),
`migration_compare_report(p_run, p_company)` and `migration_add_issue(...)`.

**Cross-check** (per company): row counts per table (`row_counts.csv` vs rows loaded vs rows now in the raw table;
this run's load, else the latest), orphan links, `check_sync` and `check_deleted`, journals balance (all lines and
per journal), trial balance per account (raw JDT1 vs app journal_line), open A/R and A/P from the documents
(invoices + down payments − credit notes), customer and supplier balances from journal lines posted to business
partners, totals per account group from `OACT.GroupMask` (1 assets, 2 liabilities, 3 equity, 4 revenue, 5–8 expenses:
cost of sales, operating, non-operating, tax; 9 or none: "other", a warning), stock quantity and value
(OnHand × AvgPrice) per warehouse and in total (OITW vs stock_balance), employees and active employees (OHEM vs employee).
All balances are debit − credit over every journal line in the export (cumulative, as at the export date).
**SAP report figures.** Finance enters what SAP itself prints with `migration_set_report_figure` (for any check;
same sign: debit − credit). A figure more than 0.01 away from the raw or the app value opens a critical issue, so
sign-off is refused until it is fixed or accepted; a matching figure closes it. For the run's company, the 8
headline checks (open A/R, open A/P, the 5 account groups, stock value in total) each carry the warning "Finance
has not entered the SAP report figure" until a figure is entered. Figures are kept when the cross-check is re-run
and compared with the fresh values. A failed check opens a critical issue (column differences and rows gone from SAP:
warning; skipped tables: info). Re-running updates issues instead of duplicating them, keeps accepted ones, and marks
as fixed the ones that are no longer found.

**Worker.**
```
pip install "psycopg[binary]" openpyxl
export SUPABASE_URL=https://<project>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<service role key>
python migration_worker.py --dsn "$DB" --source storage --poll              # serve the console
python migration_worker.py --dsn "$DB" --run <run_id> --source local --folder /data/SA01   # one run, files already here
python migration_worker.py --dsn "$DB" --new SA01 --kind full --source local --folder /data/SA01   # no UI
```
`--dsn` is the database owner on the direct connection or session pooler (it loads `sap` and drops/adds links).
Steps: `validate` (unpack archives, classify files, read the field list if any), `stage` (every table copied to
temporary tables first: an unreadable file stops the run before any company data changes), `cast` (04z, then that
company's rows replaced table by table; for `full`, its rows in tables missing from the export are removed),
`clean_02` (02 limited to that company), `orphans_03`, `links_04` (links with orphans stay NOT VALID and become
critical issues), `real_keys` (if `constraints.csv` was uploaded: compares SAP's keys with ours; changing keys stays
a manual `apply_keys.py` + 07 job because it affects every company), `security_06` (checks RLS and API roles;
re-applies 06 if needed), `app_sync`, `check_sync`, `check_deleted`, `cross_check`. One rebuild runs at a time
(advisory lock), because links are shared by all companies.
**Failure safety and Stop run.** `stage` only fills temporary tables. Everything from `cast` to `cross_check` is
one database transaction (Postgres rolls back DDL too): the dropped and re-added links, the company's rows, 02, the
app sync (`migration_sync_company`, not the committing `sync_company`) and the checks. It commits only after
`cross_check`. If a step fails, or "Stop run" was pressed (checked between steps and again, under a row lock, just
before the commit), the transaction is rolled back. The company keeps exactly its previous raw rows, links and app
rows, and other companies are never touched. The run becomes `failed` with a critical issue, or `cancelled` with an
info issue. Steps done before the rollback are marked "[rolled back]". If the worker process dies, Postgres rolls
back the same way (the run row then stays in its running status: cancel or re-queue it).
While a rebuild is open, other sessions reading the locked `sap` tables (another company's `CALL erp.sync_company`)
wait until it ends. The app layer stays readable. **Database setting:** the transaction holds about 38,000 locks
(3,656 links × constraint and trigger locks, plus the tables). Set `max_locks_per_transaction` so that
`max_locks_per_transaction × max_connections` is comfortably above that (tested with 4096; on Supabase, raise it in
the database settings or CLI `postgres-config`, then restart). The older standalone 04z already needed about 22,000.
**Structure-only upload:** an .xlsx or .csv with columns Table Name, Field Name, Data Type, Length, Allow Nulls.
It is compared with the sap schema (tables, fields, missing columns, type and length, nullability). Table names
that Excel turned into dates (`AUG1` → 1 Aug) are repaired. The run ends in `needs_review` with the info issue
"Structure only, no data rows", and no data is touched. A data-run kind with only a field list is treated the same way.

## Confirmed by Sanford (6 Nov 2026)

`@TOP_100.Code` is the item code · `@ALT_HR_EMD`: `U_ALTPYARE` payroll area, `U_ALTPAREA` personnel
area · `@ALT_HR_WAGE` not used (basic pay from `@ALT_HR_BASICPAYL`) · 01c working tables not used ·
CTX account map: `U_CTX_OACC` company account, `U_CTX_MACC` group account.

## Not covered yet

Posting and approval functions for the app, payroll calculation (results are synced), leave
requests and balances, fixed assets, budgets, bank statements, payment account lines (SAP RCT4,
kept in the raw layer), and a stock-movement view equal to `OINM` (built once query 8 returns the
HANA definition). Migration console: the worker needs a host (a small VM or container next to the database; it is not an
Edge Function), the upload screen itself is not built, a stop takes effect between steps (not inside a long step), and a large export
should go up as resumable (TUS) uploads, because Supabase limits the size of a single standard upload.

## Test material (`tests/`)

`testexp/` is a HANA-style export folder for two test companies (AE01, SA01) built from the seed data; `broken/`
is the same with one journal line removed and one invoice line pointing at a missing item. `rebuild.sh` rebuilds the
whole backend in a fresh database; `mc_tests.py`, `safety_tests.py` and `storage_mock_test.py` test the migration
console and worker. The `*_result.txt` files are the passing results from 8 Nov 2026.
