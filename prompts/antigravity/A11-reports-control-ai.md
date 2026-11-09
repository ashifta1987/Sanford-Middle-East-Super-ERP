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

## AI assistant (only after A10 sets the provider)
- "Ask AI" in the top bar, and "Ask AI about this order" on documents.
- The model answers only from data the user can already read: tool calls go to existing `SECURITY INVOKER` functions with the user's JWT. Show the sources (record links).
- **No AI action changes data;** it may draft a document for the user to review and submit.
- Every question and the tools used are logged in `audit_log` with `actor = 'ai:assistant'`.

## Tests
- Report totals equal the journal sums.
- A sales user can't run finance reports.
- An AI answer for a sales user never contains finance data.
- Exported CSV matches what is on screen.
