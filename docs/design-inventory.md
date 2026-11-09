# Design inventory · Sanford Super ERP

Prepared 9 Nov 2026 from:

* the **canvas design** "Super ERP UI/UX Structure" (Claude design artifact): 61 boards, every menu matched to the SAP B1 photos;
* this repo (`src/`, `supabase/sql/10–14`, `docs/`, `design/B5–B8`);
* the live Supabase project `xhsfkbbcejgwvqxpqdgq` (schemas `sap`, `erp`);
* the SAP field dictionary `Table With Field.xlsx` (3,691 tables, 117,772 fields) and the item-table field lists (OITM, ITM1, OITB, OITW, OUGP, UGP1).

## 1. Screens

| Area | Screens in the design | Built in code before Stage 1 |
|---|---|---|
| Shell | Sidebar (Home · 11 modules · Control Tower), top bar (search, company switcher, theme, alerts, Ask AI), AI panel, light + dark | Sidebar with a different module list, top bar, EN/AR |
| Home | Role-first home: KPIs, AI brief, approvals waiting | Placeholder |
| Control Tower | Exceptions by severity (price, discount, stock, payment, staff) | — |
| 11 modules | One menu screen each: numbered SAP function list, sub-functions, AI/Note box, 4 KPIs | Placeholders (other names) |
| Documents | Sales order with approval (prototype) | — |
| Administration sub-screens | Company details, Authorizations (4 tabs), Document numbering, Exchange rates, Approval templates, SAP migration, Opening balances, Setup › General/Financials/Sales/Purchasing/BP/Banking/Inventory/Service/HR, G/L determination, Tax, Fixed assets, Bin locations, Data import/export, Utilities, Approval process, Licence, Add-ons, Workflow | Migration console only (B5 centre, B6 upload, B7 run, B8 cross-check + sign-off) — **working end to end** |
| Financials sub-screens | Fixed asset reports, Financial reports (Accounting, Aging, Tax, Financial, Comparison, Budget), Internal reconciliations, Budget setup, Cost accounting | — |
| BP / Inventory / Reports sub-screens | BP reports › Internal reconciliation, Serial numbers, Batches, Inventory counting, Reports › Financials/Sales & Purchasing/Inventory | — |
| Mobile | Staff Portal (duties, check-in, leave, payslip), light + dark | — |
| Foundations | Principles & roles, Sitemap, Purchase flow China → Dubai | (docs) |

## 2. User roles

| Role (design) | Lands on | Works in | In the database today |
|---|---|---|---|
| Owner / MD | Control Tower + approvals | Everything (read), approves above limits | `GROUP_CFO` (module `business`) is the nearest |
| Finance | Cash, ageing, payments due | Financials, Banking, Reports | `CHIEF_ACC` (`finance`) |
| Sales team | My orders and targets | Sales, Business Partners, Service | — |
| Purchase · China offices | Open POs, deposits due | Purchasing, BP, Inventory | — |
| Warehouse · Dubai | Receipts and dispatches | Inventory, Production | — |
| HR | Attendance and leave | Human Resources | — |
| Every employee | Staff Portal (phone) | My duties, leave, payslip | — |
| System admin / IT | Administration | Admin, migration | `IT_ADMIN` (`admin`, `it`) |

Access is enforced by `erp.position.module_access` + `erp.user_company` + row-level security (`12_erp_security.sql`). The design's authorization matrix (Full / Read / None per module) maps onto `module_access`; Read vs Full needs a new field (see gaps).

## 3. Modules and their SAP functions
All 11 modules (Administration … Reports) carry the exact SAP B1 function lists from the photos (see `src/features/erp/menus.ts`). Custom add-ons found in SAP and kept: PI Tracking Entry, Artwork Entry, Logistics, Trademark Master, Commitment Master, Sanford DWC Reports, Costing Sheet, Old Sales, Qatar Sales Data, ATMM (= AE02 A.T.M.M. Electronics) A/R report.

## 4. Business workflows identified

1. **Sales document flow:** Quotation → Order → Delivery → A/R Invoice → Incoming payment, with returns and credit memos.
2. **Sales approvals:** discount above the salesperson limit; credit limit exceeded; sale below landed cost.
3. **Purchase China → Dubai (9 steps):** request → supplier quotes → PO (owner approves above USD 20,000) → proforma + deposit → production + QC → balance payment → shipment/container → goods receipt (scan, count) → A/P invoice + landed cost.
4. **Payments:** outgoing payments with approval, block on changed supplier bank details; PDC deposits; bank reconciliation.
5. **Inventory:** transfers, counting (blind count on phone) → posting with approval above AED 5,000; batches/serials; bins.
6. **Month-end and VAT:** period closing, UAE VAT 201 return from tax groups, reverse charge on imports.
7. **HR / Staff portal:** check-in, duties, leave (long leave approval), payroll + WPS (ALT_HR add-on in SAP today).
8. **3PL warehousing:** client contracts, storage/handling fees (TPL fields on documents).
9. **SAP migration:** upload → rebuild → cross-check → Finance/IT/CFO sign-off → go-live (built).

## 5. Gaps and missing information

**Design gaps**
* No designed **document form** except the sales order prototype (no designed quotation, delivery, invoice, PO, payment forms). Stage 2 reuses the sales order layout for all marketing documents.
* No designed **list screens** (e.g. "all sales orders"); the canvas goes from menu straight to a form. Stage 1 adds one consistent list pattern (search, filters, sort, paging).
* No designed **empty, error, loading and no-access** states beyond the migration console. Stage 1 reuses the console's states.
* Arabic/RTL was not part of the canvas; the code supports it — kept.
* Authorization matrix shows Full / Read / None per module, but positions only store a module list (no read-only level).
* Control Tower and Home KPIs have no defined formulas.

**Data / process information still missing (not blocking Stage 1)**
* Real approval limits per position (discount %, credit, PO amount) — the design shows examples only.
* Real users, positions and company access for the 12 companies (only 3 test users and AE01–AE04 exist).
* Rest of the Banking Reports menu (photo was cut off); Electronic Reports and Sanford DWC Reports submenus.
* Whether ERP-made documents must also be posted back into SAP during the soft switch (assumed **no** — see below).

## 6. Decisions and assumptions
* **Stack:** keep the repo stack — React 18 + TypeScript + Vite + Tailwind + TanStack Query, Supabase (Postgres, Auth, RLS, Storage, Realtime), Vercel. (Answered 9 Nov.)
* **Look:** canvas colours, layout, sidebar and dark mode, with IBM Plex Sans / Plex Sans Arabic kept for Arabic. (Answered 9 Nov.)
* **Database:** new objects go into the existing Supabase project as `supabase/sql/15_*.sql`; files 10–14 are not edited. (Answered 9 Nov.)
* **Soft switch:** while SAP is still live, SAP rows stay read-only in the app (`source = 'sap'`). Documents made in the ERP get `source = 'erp'`, their own number range, and are not sent to SAP.
* **Screens without a backend** are shown as clearly labelled **design previews**; they are not counted as working functionality.
* **Test data:** a sample company `ZZ99 · Sample data` holds sanitized sample rows; it can be removed with one script and is never mixed with AE01–AE12.
* **Answers of 9 Nov (design questions):**
  * Trademark Master (Business Partners) and Commitment Master (Inventory) are SAP user-defined tables. They stay as they are.
  * The 6 new HR functions stay.
  * MRP is left out of Reports, as it is from the sidebar.
  * Go-live (opening balance) date stays the placeholder `[GO-LIVE DATE]`.
  * Sample tax codes, G/L account numbers, asset classes, useful lives and landed cost codes are removed. Those screens stay empty until they are loaded from SAP.
  * Available-to-Promise is **switched on** in Super ERP. It was off in SAP.
  * "ATMM AR Invoice + Credit memo", "Old Sales UAE" and "Global Old Sales" are removed from Sales Reports. The Sales › Old Sales Data function, which uses the @OLDSALEDATA table, is kept.
  * Reports › Sales and Purchasing: the two Management Reports menus are merged into one, and so are the two Sanford DWC Reports menus.
  * AI Assistant settings live under Administration › Add-Ons › AI Assistant. This is a Super ERP addition, not a copy of SAP.

**Found while building Stage 1 (security):** row-level security in `12_erp_security.sql` limits rows by **company** for every table, and by **HR module** for HR tables only. Module access for finance, sales and purchasing is currently enforced in the UI only. For example, a sales-only user could read journal entries through the API. Before go-live, add module checks to the read policies (planned with Stage 2 as `15_*` policies; file 12 is not edited).

