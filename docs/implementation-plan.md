# Implementation plan · Sanford Super ERP

Stack (existing, kept): React 18 + TypeScript + Vite + Tailwind + TanStack Query · Supabase (Postgres 17, Auth, RLS, Storage, Realtime) · Vercel · Python worker for SAP loads.

Rule for every stage: a screen is **working** only when it reads/writes real `erp` data through RLS or a checked function. Anything else is a labelled design preview.

## Stage 1 · Design system, navigation, screens (this branch: `stage-1-erp-shell`) — **done 9 Nov**
* Design tokens as CSS variables (canvas palette, light + dark), Tailwind mapped to them so the migration console restyles automatically.
* Shell: sidebar Home · 11 SAP modules · Control Tower · Approvals; top bar with company switcher, global search, theme toggle, language.
* Module menu screens for all 11 modules (exact SAP function lists, search over functions, sub-functions panel).
* Working list screens on live data, each with search, filters, sorting and paging:
  Business Partner Master Data · Item Master Data · sales and purchase documents (all 19 SAP document types) with line detail · Inventory status by warehouse · Chart of Accounts · Employee master (HR only, RLS).
* Admin › Data Import/Export › SAP B1 migration links to the existing console (unchanged).
* Setup / report sub-screens from the canvas: shown as design previews.
* Also built: price lists, journal entries with lines, incoming and outgoing payments, global search (Ctrl/⌘ K), Home KPIs and Control Tower checks from `15_stage1_overview.sql` (read only, SECURITY INVOKER), and CSV export on every list.
* How to run and what was tested: see `docs/stage-1.md`.

## Stage 2 · First end-to-end workflow: Sales order with approval
Chosen because it is the prototype screen in the design, touches masters, prices, stock, credit, approvals and audit, and has **no accounting posting** — safe during the soft switch.
* `15_sales_order.sql`: ERP number range, `erp.sales_order_save()`, `submit()`, `approve()`, `reject()` (SECURITY DEFINER), approval rules table (discount %, credit limit, below landed cost) per position, audit log entries.
* Validation: customer active and in the user's company, items sellable, qty > 0, price ≥ 0, discount within limit or routed to approval, VAT from tax code, credit check (balance + open orders + this order).
* Permissions: `sales` module to create; approver position by rule; can't approve your own order; RLS on reads.
* UI: list, new/edit form (customer + item search, price list lookup), submit, approvals inbox, approve/reject with note, clear error messages mapped from SQLSTATE.
* Tests: SQL tests for every rule + browser test of the full path with two users.

## Stage 3 · Module-by-module plan (remaining workflows)
| Order | Module | Workflow | Depends on |
|---|---|---|---|
| 3 | Sales | Quotation → order copy-to; Available-to-Promise check (switched on); delivery (stock commit → issue); A/R invoice (journal posting) | Stage 2; posting engine |
| 4 | Financials | Posting engine (journal from documents, G/L account determination, VAT), period lock, manual journals with approval | Real account determination from SAP OACP/OGAR |
| 5 | Purchasing | China flow: request → quotes → PO approval → PI + deposit → QC → shipment → GRPO → A/P invoice + landed costs | Posting engine, Banking |
| 6 | Banking | Incoming/outgoing payments, approvals, bank-detail-change block, PDC deposits, statement import + reconciliation | Posting engine |
| 7 | Inventory | Transfers, counting + posting with approval, batches/serials, bins | Posting engine for revaluation |
| 8 | Business Partners | Master data create/edit with approval, credit limits, dunning | — |
| 9 | HR + Staff Portal | Employees, attendance check-in, duties, leave approval, payroll + WPS (replacing ALT_HR) | — |
| 10 | Service, Production | Service calls/contracts; BOM, production orders | Inventory |
| 11 | Reports + Control Tower | Real KPIs, exception rules, AI assistant | All above |
| 12 | Administration | Users/positions UI, authorization matrix (Full/Read/None), approval templates, numbering, Add-Ons › AI Assistant settings | — |
| 2b | Security | Module checks in read policies (finance/sales/purchasing tables), not only company checks | before any real user gets access |

Cut-over: per company, after its migration run is signed off and go-live is recorded, SAP sync stops for that company and ERP documents become the source of truth.

## SAP migration
Planned separately in `docs/sap-migration-plan.md` (data inventory, field mapping, import process, reconciliation). No live SAP changes and no production imports without written approval.
