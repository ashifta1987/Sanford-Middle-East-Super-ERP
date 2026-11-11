# A11 · Reports, Control Tower and AI assistant

SQL file: `supabase/sql/26_reports.sql`.

## Reports
- **A report library** that matches Reports › (Financials, CRM, Opportunities, Sales and Purchasing, Business Partners, Banking, Inventory, Production, Service, Human Resources, Audit Trail Report). MRP is left out (decision of 9 Nov).
- **Sales and Purchasing** has **one** Management Reports menu and **one** Sanford DWC Reports menu (merged, decision of 9 Nov). ATMM AR Invoice + Credit memo, Old Sales UAE and Global Old Sales are removed.
- **Each report is a read-only SQL function** (`SECURITY INVOKER`, so the A1 rules apply) with parameters (company, date range, filters). It renders as a table and a chart (`docs/ui-ux-spec.md` tokens) and exports to CSV and PDF.
- **Build first:**
  - trial balance, balance sheet, profit and loss
  - customer receivables aging, supplier payables aging
  - sales analysis (by customer, item, salesperson)
  - open items list
  - inventory in warehouse
  - inventory valuation
- **Saved reports and scheduled email** (Supabase cron + Edge Function) come later.

## Control Tower
Add the remaining rules from the design next to the 5 existing checks:
- stock count variance over 1 %
- supplier bank details changed
- purchase price over last +10 %
- same supplier invoice twice
- check-in outside site area

Each rule is a function with severity, record link and amount.

## Sana (AI assistant): already built; finish it
Read `docs/sana-assistant.md`. The pipeline, role limits, panel, voice and logging exist. In this phase:
- **Connect the model** chosen in A10: Anthropic is built in `aiAnswer` in `supabase/functions/sana/core.ts`. Another provider means one new adapter there.
- **Add tools for each new module** as it goes live (`erp.sana_*`, read-only, `SECURITY INVOKER`, role check plus `{"denied": true}`), and offer them in `TOOLS` with an `allowed()` rule.
- **Optional streaming answers** (Server-Sent Events) and a provider voice for languages the browser cannot hear well.
- **Prompt-injection test set** (role-play, "repeat your instructions", instructions hidden inside customer names or document remarks): every case must be refused, with tests in `supabase/tests/` and Playwright.
- **No write actions.** Sana may later *draft* a document for the user to review and submit; it never posts, approves or deletes.

## Tests
- Report totals equal the journal sums.
- A sales user can't run finance reports.
- An AI answer for a sales user never contains finance data.
- Exported CSV matches what is on screen.
