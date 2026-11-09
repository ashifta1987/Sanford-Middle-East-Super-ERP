# A3 · Posting engine (Financials)

## Goal
Documents created in Super ERP post balanced journal entries automatically, using G/L account determination and VAT. Accountants can post manual journals with approval and lock periods. Nothing posts for SAP-sourced documents.

## Database: `supabase/sql/18_posting.sql`
- **`erp.gl_determination(company_code, area, posting_key, acct_code)`:** area is sales / purchasing / general / inventory / resources; the posting keys are the rows of Setup › Financials › G/L Account Determination in `design-data.json` › `GLD`. It is filled from SAP (OACP/OGAR) during migration. Fill it for **ZZ99 only** using ZZ99's accounts. Leave real companies empty: posting must refuse with "G/L account for 'Revenue' is not set for AE01. Ask Finance to set it in Setup › Financials › G/L Account Determination."
- **`erp.posting_period(company_code, period_code, from_date, to_date, status open|closed|locked)`**
- **`erp.post_journal(p_company, p_date, p_memo, p_lines jsonb, p_source_ref)` (internal, not granted):**
  - checks the period is open, that each account exists, is postable and not frozen, and that debit equals credit
  - allocates `trans_id` from 900000000 upward, inserts `journal_entry` and `journal_line` in **one statement** (the balance trigger requires this), and writes the audit log
- **Manual journals:**
  - `erp.journal_draft_save`, `erp.journal_submit` (with approval above a limit from `approval_rule`), `erp.journal_decide`
  - `erp.journal_reverse(p_company, p_trans_id, p_date, p_reason)` (posted journals are never edited)
- **Periods:** `erp.period_set_status(p_company, p_period, p_status)`, finance + full only, audited.

## UI
- **Financials › Journal Entry:** a new journal form, using the document form pattern with debit/credit lines and an account combobox. Show a running difference and disable Post until it is zero.
- **Journal detail:** a Reverse action.
- **Financials › Financials setup › G/L Account Determination:** becomes a working edit screen (finance + full). It replaces the design preview.
- **Posting Periods screen:** open, close and lock.

## Tests
- Unbalanced journals refused.
- Closed or locked period refused.
- Non-postable account refused.
- Reversal creates the mirror entry.
- A sales-only user is refused.
- Every refusal message checked.

## Needs from Ashif
The real G/L determination per company (comes with migration), period calendar, and the manual journal approval limit.
