# A2 · First complete workflow: Sales order with approval

This is the first workflow built end to end. It was chosen because:
- it is the prototype screen in the design (`docs/ui-ux-spec.md` §4.4)
- it touches customers, items, prices, stock, credit, approvals and audit
- it posts **no accounting entries**, so it is safe during the soft switch

## Scope
Create, edit (while a draft), submit, approve, reject and cancel ERP sales orders, then show them in the existing Sales Orders list and detail screens next to the SAP orders.
Out of scope (A4): copy to delivery, invoicing and stock movement. The "Copy to delivery" button stays disabled with the reason "Delivery comes in a later stage".

## Database: `supabase/sql/17_sales_order.sql`
1. **Number series:** `erp.number_series(company_code, obj_type, prefix, next_num, …)`. Allocate `doc_num` inside the save function (row lock, no gaps on rollback is not required). Allocate ERP `doc_entry` values from a sequence starting at **900000000**, so they never collide with SAP's DocEntry. Prefix for ZZ99: `SO-26-`. Real prefixes are set up in A10.
2. **Workflow state:** `erp.document.status` only allows `draft/open/closed/cancelled/cancellation`. Keep the extra states in `erp.doc_workflow(company_code, obj_type, doc_entry, state, submitted_by, submitted_at, reason, …)` with state `draft | pending_approval | approved | rejected | cancelled`. The document stays `status = 'draft'` until it is approved, then becomes `'open'`.
3. **Approval rules:** `erp.approval_rule(company_code, rule_code, position_code, limit_value, approver_position, step, active)`. Rules for sales orders:
   - `discount_pct`: a line discount above the user's position limit
   - `credit_limit`: customer balance + open orders + this order > credit limit
   - `below_cost`: net unit price < item cost (`stock_balance.avg_cost` for the warehouse, or `item.avg_cost`)

   Seed rules **for ZZ99 only**:
   - discount limit 10 % for `QA_SALES`
   - credit → `QA_SALES_MGR`
   - below cost → `QA_ALL` (owner)

   Real limits are left empty and listed under "Needs from Ashif".
4. **Functions** (`SECURITY DEFINER`; each checks the user, the company (`can_see`) and `can_write('sales')`, and writes `erp.audit_log`):
   - `erp.sales_order_save(p_company, p_doc_entry nullable, p_header jsonb, p_lines jsonb) returns jsonb {doc_entry, doc_num, totals, checks}`
     - creates or replaces a **draft** owned by the caller
     - **Validation:**
       - customer exists, is active and is a `customer` in that company
       - at least one line
       - each item exists, is active and `is_sold`
       - qty > 0; price ≥ 0; discount 0–100
       - warehouse exists in the company
       - tax code exists
       - posting date in an open period (if a period table exists; otherwise skip and note it)
     - The server recalculates prices from the price list when the client sends none, and recalculates line totals, VAT (tax code rate), document total and `open_qty`.
     - Returns the rule checks it would trigger.
   - `erp.sales_order_submit(p_company, p_doc_entry, p_reason text)`: runs the rules. If none trigger → `approved` and `status 'open'`. Otherwise → `pending_approval`, with one `erp.approval` row per triggered rule/step. A `p_reason` is required when approval is needed.
   - `erp.sales_order_decide(p_company, p_doc_entry, p_decision 'approved'|'rejected', p_note, p_new_discount numeric default null)`
     - Only a user whose position is the pending step's `approver_position` may decide. The submitter can never approve their own order.
     - Rejecting needs a note.
     - "Approve at n %" lowers the flagged discounts to n (which must be within the approver's own limit) and recalculates.
     - When all steps are approved, the order becomes `open`.
   - `erp.sales_order_cancel(p_company, p_doc_entry, p_note)`: only before any delivery; the creator or an approver.
   - `erp.approval_inbox()`: waiting-for-me / sent-by-me / decided, for `/approvals`.
5. **Messages** (examples; keep this style):
   - "Customer C0099 is inactive. Choose an active customer."
   - "Line 2: SMP-1190 is not a sales item."
   - "Discount 18% is above your limit of 10%. Submit it for approval or lower the discount."
   - "You can't approve your own order."
   - "This order is waiting for approval and can't be edited. Ask the approver to reject it first."
6. **Grants:** `EXECUTE` on these functions to `authenticated` only. No table write grants.

## UI
- **Routes:**
  - `/docs/sales_order/new`
  - `/docs/sales_order/:company/:entry` (existing detail; becomes the document form)
  - `/docs/sales_order/:company/:entry/edit` (drafts only)
- **Form:** the document form pattern in `docs/ui-ux-spec.md` §4.4: header fields, customer and item comboboxes, lines, live totals, Save draft / Submit, the document flow strip, the approval card for approvers, and the activity timeline from `audit_log` + `approval`.
- **Detail for ERP vs SAP orders:**
  - For ERP orders, show the workflow state pill (Draft, Waiting approval, Approved, Rejected, Cancelled) and the source pill "Super ERP".
  - SAP orders stay read-only with the source "SAP Business One".
- **Sales Orders list:** enable "+ New sales order"; add a filter "Source: SAP / Super ERP" and a "Waiting approval" filter.
- **`/approvals`:** add a "Documents" tab using `approval_inbox()`. Keep the migration sign-off list as it is.
- **Home:** add a KPI "Waiting for my approval" (shown to approvers only).

## Tests
- `supabase/tests/a2_sales_order.sql` covers:
  - every validation message
  - totals and VAT maths
  - number allocation
  - each rule triggering and not triggering
  - self-approval refused
  - wrong approver refused
  - reject without a note refused
  - "Approve at n %" above the approver's limit refused
  - edit while pending refused
  - a read-only user refused
  - another company refused
  - the audit rows written
- Playwright, with two browser contexts:
  1. `qa.sales` creates an order with an 18 % discount.
  2. Submit shows "Needs approval".
  3. `qa.sales_mgr` sees it in Approvals and approves at 10 %.
  4. `qa.sales` sees "Approved", the totals are updated, and the order appears in the list as Open.

  Also test the reject path, and the phone layout at 390 px.

## Done when
A sales user can raise an order and a manager can approve or reject it, all on real tables with rules enforced in the database. All tests pass. `modules.ts` shows Sales › Sales Order as **Live data** with create enabled.
