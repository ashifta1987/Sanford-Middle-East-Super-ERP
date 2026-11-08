# P0 · Context. Read this first, before every phase.

## Product
**Sanford Super ERP** is the group ERP for the 12 Sanford companies. AE01 Sanford Middle East DWC is the parent, in the Dubai South free zone. AE02 A.T.M.M. Electronics is mainland UAE. The others are in KSA, Qatar, Kuwait, Bahrain, Oman and India. Each company runs its own SAP Business One on HANA today. The new ERP keeps an exact copy of SAP in Supabase (schema `sap`) and builds the app on a readable layer (schema `erp`).

**This job: the Migration Console.** An admin uploads one company's SAP HANA backup. The worker rebuilds that company, the system cross-checks every total against SAP, then Finance, IT and the CFO sign off before go-live.

## Stack (fixed)
- React 18 + TypeScript + Vite, React Router, TanStack Query, Tailwind CSS, lucide-react icons
- Supabase: Postgres, Auth, Storage, Realtime, `supabase-js` v2
- Vercel hosts the web app
- `supabase/worker/migration_worker.py` (already written) does the heavy loading on its own server. It never runs on Vercel or in the browser.

## What is in this workspace
| Path | Use |
|---|---|
| `supabase/sql/README.md` | Backend reference. **Section "Migration console" is the API contract.** |
| `supabase/sql/10_erp_schema.sql`, `11_erp_sync.sql`, `12_erp_security.sql` | App schema, sync, row-level security: read for names and helpers |
| `supabase/sql/13_migration_console.sql` | The console's tables and RPC functions: your API |
| `supabase/sql/05_hana_export.sql` | The script IT runs on HANA (served by the "Download script" button) |
| `supabase/worker/` | Worker + loader (deploy only, don't rewrite) |
| `supabase/tests/` | `testexp/` (good export, 2 test companies), `broken/` (bad export), test scripts |
| `design/B5…B8 *.jpg` | The four screens to build, 1440 px wide |

**Not in this workspace on purpose:** the raw SAP schema and link scripts (`01a`, `01b`, `02`, `03`, `04`, `04z`, `06`, `_model.json`, about 16 MB). IT installs them on Supabase from the separate `sanford-db-install` package, and the worker server keeps them beside the worker. Don't look for them, regenerate them, or query `sap.*` from the browser.

## Rules
- Don't edit `10`–`13`. Put anything new in `supabase/sql/14_*.sql` and explain it in the PR.
- Supabase exposes `erp` only (Settings › API › Exposed schemas), never `sap`.
- The browser holds only the anon key and the user's session. The service role key lives only on the worker server.
- Every RPC call is `supabase.schema('erp').rpc(name, args)`. Types come from `supabase gen types typescript --schema erp`.

## API (details and return columns: README › Migration console)
| RPC | Who | Use |
|---|---|---|
| `migration_request(p_company, p_kind, p_notes)` kind `full`/`tables`/`structure_only` | admin/IT | creates the run (status `uploading`), returns run_id. Upload to `sap-exports/<company>/<run_id>/` |
| `migration_submit(p_run)` | admin/IT | → `queued`, the worker picks it up |
| `migration_cancel(p_run)` | admin/IT | uploading/queued → `cancelled`. While running → `stop_requested`: the worker stops before the next step and restores the company |
| `migration_status(p_run)` | admin/IT, signers | one row per step plus run totals, open issues by severity, signoffs (jsonb), stop_requested_at, report_figures, report_missing |
| `migration_review(p_run, p_area?)` | admin/IT; signers once in review | checks + issues: area, name, severity, status, sap_value, raw_value, app_value, difference, ok, detail, report_value, report_source, report_ok, report_required |
| `migration_set_report_figure(p_run, p_company, p_area, p_check_name, p_value, p_source)` | finance signers, admin/IT | Finance types the figure from SAP's own report. `p_value = null` removes it |
| `migration_resolve_issue(p_issue, p_status, p_note)` status `open`/`accepted`/`fixed` | admin/IT | accepting a critical issue needs a note |
| `migration_sign(p_run, p_role, p_decision, p_comment)` role `finance`/`it`/`business` | matching signer | refused while a critical issue is open. The third approval makes the run `signed_off` |
| tables `migration_run`, `_file`, `_step`, `_check`, `_issue`, `_signoff` | admin/IT (RLS) | lists, live log, history |

Run status: `uploading → queued → validating → loading → rebuilding → checking → needs_review → signed_off`, or `failed` / `cancelled`.
Pills: running states blue, `needs_review` amber, `signed_off` green, `failed` red, `cancelled` grey.

What the UI may promise, because the worker guarantees it:
- A failed or stopped run leaves the company exactly as it was before the run.
- Other companies are never touched. Their SAP updates wait until the run ends.
- A clean run still shows 8 warnings until Finance enters the SAP report figures. That is intended.

Error mapping: SQLSTATE `42501` → "You don't have access to this". For everything else, show the database's own message.

## Look (match `design/*.jpg`)
- **Type:** IBM Plex Sans, plus IBM Plex Sans Arabic for RTL. IBM Plex Mono for file names and the log. Tabular numbers.
- **Colours:**
  - page `#F6F7F9`
  - cards `#FFFFFF` with border `#E2E5EA`, radius 12
  - text `#16191F`, secondary text `#5B6270`
  - primary `#1D4ED8`
- **Pills:** ok `#E7F6EC`/`#14532D` · warning `#FFF4E5`/`#8A3B00` · critical `#FDECEC`/`#8F1D1D` · info `#EEF2FF`/`#1E3A8A` · neutral `#F1F3F6`/`#4A5160`.
- **Buttons:** at least 44 px high, radius 10. A disabled button is grey and shows its reason underneath.
- No emoji, no gradients.
- **Language:** English and Arabic through i18n (`en`, `ar`). Use `dir="rtl"` and logical CSS (`ms-`, `me-`, `start`, `end`).
- **Accessibility:** real `<button>`, `<a>`, `<label>`. `<th scope>` on table headers. `role="progressbar"` with values. Contrast at least 4.5:1, visible focus.
- **Phone (390 px):** cards stack, wide tables scroll inside their box.

## Who sees what
- Admin/IT positions get the whole module.
- Finance and CFO signers reach only the Cross-check screen, from their Approvals inbox, and sign only their own role. The IT signer signs as IT.
- Everyone else gets no menu entry, a blocked route, and an RLS error from the server.
- Uploaded files are private. Signed URLs last 10 minutes or less.
- Audit logging is done by the database functions, not the UI.

## How to work
Do one phase at a time (P1 … P6). Make small commits. At the end of each phase, show screenshots at 1440 px and 390 px and list what you couldn't do.
