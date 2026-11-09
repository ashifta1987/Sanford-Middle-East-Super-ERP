# A5 · Banking: incoming and outgoing payments

SQL file: `supabase/sql/20_banking.sql`. Depends on A3.

## Build
- **Incoming payment** against open A/R invoices: allocate to one or many, or leave on account. Means of payment: cash, transfer, cheque (with due date → post-dated cheques), card. Posts through A3 and updates the customer balance and `payment_allocation`.
- **Outgoing payment** to suppliers against A/P invoices and down payments. It needs approval above a limit (`approval_rule`).
- **Bank-detail-change block:** if the supplier's bank details changed in the last 30 days, approval by Finance manager **and** Owner is required (rule from the design's approval templates).
- **Deposits** of cheques and cash to a bank account.
- **Bank statement import (CSV)** and matching to payments and journal lines, using the existing `match_no`. Unmatched lines stay listed.
- **Banking Reports:** list the menu items from `design-data.json`; build only the cash position report now, the rest stay previews.

## Tests
- Allocation maths.
- Over-allocation refused.
- An outgoing payment above the limit waits for approval.
- A changed bank account triggers the two-step approval.
- Postings balance.
- Statement matching is idempotent.

## Needs from Ashif
Payment approval limits, the bank accounts per company, and the bank statement CSV formats (one sample per bank).
