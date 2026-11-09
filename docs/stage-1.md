# Stage 1 · What was built, how to run it, what was tested

Branch: `stage-1-erp-shell`. Nothing writes business data yet. Every working screen **reads** real `erp` tables through Supabase, with row-level security applied.

## Built
**Design system.** The canvas colours are CSS variables (light and dark) in `src/index.css`, and Tailwind uses them (`tailwind.config.js`). Fonts are IBM Plex Sans and Plex Sans Arabic. The theme toggle is in the top bar. The migration console picks up the new look automatically.

**Shell.** The sidebar shows Home, the 11 SAP modules (filtered by the user's position) and Oversight (Control Tower, Approvals). The top bar has the company switcher, global search (Ctrl/⌘ K), theme, language (EN/AR with RTL), password and sign-out. Layouts are responsive down to 390 px. Old menu paths redirect.

**Module screens** (`/m/:module`). Each module lists the exact SAP functions from the canvas, in SAP order, with a search box and the Off / Custom / New tags. Each function has a panel showing its sub-functions, and each sub-function is marked:
- **Live data:** opens a working screen.
- **Design preview:** opens the canvas sub-screen under a "not connected" banner.
- **Planned:** not built yet.

**Working screens.** All have server-side search, filters, sorting, paging, CSV export, links to detail, and empty, error and loading states:
| Module | Screen |
|---|---|
| Sales | All 7 sales document types → document detail with lines and totals |
| Purchasing | All 8 purchase document types → detail |
| Inventory | Item master → item detail (stock by warehouse, prices); inventory status; price lists; 4 inventory document types |
| Business Partners | Business partner master → detail with recent documents |
| Financials | Chart of accounts; journal entries → detail with debit/credit check |
| Banking | Incoming and outgoing payments |
| Human Resources | Employees (HR positions only; enforced by the database) |
| Home | KPIs from `erp.home_kpis` |
| Control Tower | Five rule checks from `erp.control_checks`: over credit limit, sold below cost, more than 60 days overdue, discount above 5 %, below minimum stock |
| Search | Partners, items and documents, limited to the modules the user can open |

**Database** (new files only; 10–14 not edited):
- `supabase/sql/15_stage1_overview.sql`: `home_kpis` and `control_checks`. They are read only, SECURITY INVOKER, and granted to `authenticated` only.
- `supabase/sql/15_sample_company.sql` and `15_sample_company_remove.sql`: the fictional test company ZZ99. It has 28 items, 26 partners, 160 documents, 14 payments, 18 journals and 10 employees. Generate it with `python3 scripts/gen-sample-company.py`.

**Design changes from your answers of 9 Nov** are applied to the canvas and to `src/features/erp/design-data.json`. See `docs/design-inventory.md` §6.

## How to run
Against Supabase (the normal setup):
```bash
cp .env.example .env.local      # VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY (publishable key only)
npm install && npm run dev      # http://localhost:5173
```
To see the new Home and Control Tower figures on Supabase, apply `supabase/sql/15_stage1_overview.sql` (read-only functions). Applying the sample company is optional. **Neither is applied to the Supabase project yet.**

Local stack, with no Supabase needed (this is how Stage 1 was tested):
1. Postgres 16 on port 5433. Load `10_erp_schema.sql`, `11`, `12`, `13`, `14`, `15_stage1_overview.sql` and `15_sample_company.sql`, then `scripts/local-stack/test-users.sql` (local only).
2. PostgREST with `scripts/local-stack/postgrest.conf` (port 3000).
3. `node scripts/local-stack/gateway.mjs`. This is a stand-in for Supabase Auth and REST on port 54321, with test users from `users.json`.
4. `.env.local` → `VITE_SUPABASE_URL=http://127.0.0.1:54321`, `VITE_SUPABASE_ANON_KEY=local`, then `npm run dev`.
5. `node scripts/local-stack/stage1-e2e.mjs ./shots` runs the browser tests and saves screenshots.

Local test logins (sample company only): `qa.admin@sample.test / local-only-1` (all modules), `qa.sales@sample.test / local-only-2` (sales only), `qa.nobody@sample.test / local-only-3` (no profile).

## Tested
- `npm run typecheck` and `npm run build`: pass.
- SQL: the sample company loads twice in a row, is removed, and reloads cleanly. `home_kpis` and `control_checks` return data for the sales user and nothing for a user with no profile.
- Browser (`stage1-e2e.mjs`, Chromium): **35 of 35 checks pass.** They cover:
  - KPIs and the 11-module sidebar.
  - Sales module with its 22 functions; MRP is gone from Reports.
  - Status filter and sort, both kept in the URL; CSV export row count equals the filtered count.
  - Document, BP, item and journal detail pages.
  - Search narrowing and the "No matches" state.
  - Every list has data; the preview banner shows; tax sample values are removed.
  - Global search; dark theme; Arabic RTL; no console errors.
  - No horizontal scroll at 390 px.
  - Permissions: the sales user cannot open HR or Financials and sees "New sales order" disabled; a user with no profile sees no modules.

## Not done / remaining
- **No create or edit yet.** The "New …" buttons are disabled and say which stage builds them. The sales order with approval is Stage 2.
- **Server-side module checks.** Read policies check the company for every table, but the module only for HR tables. A sales-only user can still read finance tables through the API. Fix planned before real users get access (`docs/implementation-plan.md`, item 2b).
- Not applied to Supabase yet: `15_stage1_overview.sql` and the sample company.
- Design previews: the setup and report sub-screens still show sample content from the canvas.
- AI assistant: shown as "Planned".
- Bundle size: the main chunk is 927 kB. Code-splitting the PDF and Excel libraries is a later clean-up.
