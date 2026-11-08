# P5 · B8 Cross-check and sign-off (read P0 first; match `design/B8-cross-check-signoff.jpg`)

Data comes from `migration_status` and `migration_review(run, area)`.

## Page content
1. Breadcrumb, title "Cross-check and sign-off · <code>", **Download report**, **Run checks again** (admin/IT; re-queues the cross-check step if the backend supports it, otherwise hide it).
2. Key numbers: checks passed (x of y), critical issues open, notes, sign-offs (x of 3).
3. **Every area at a glance**: Structure, Row counts, Links (orphans), App tables, Finance, Stock, HR. Each has a pill and a one-line detail.
4. **Finance** table (AED), with columns Check · SAP report · SAP copy (`raw_value`) · App (`app_value`) · Difference · Result. Rows are the finance checks: debits minus credits, assets, liabilities, equity, revenue, expenses, open A/R, open A/P.
   - **SAP report** is `report_value`: what Finance prints from SAP itself.
   - **Enter SAP report figures** side panel (Finance signers and admin/IT): one input per `report_required` check, plus a source note (e.g. "SAP Trial Balance 31 Oct").
     - Save calls `migration_set_report_figure`, then re-read `migration_review`.
     - A missing figure shows an amber "Enter figure" pill.
     - Within 0.01 shows ok. Anything else is red and blocks sign-off.
   - Show the values exactly as returned. No rounding.
5. **Stock by warehouse**: pieces and value, SAP copy vs app, with a total row.
6. **Issues**: severity pill, title, detail, state.
   - Accept, mark fixed or reopen, with a note. These call `migration_resolve_issue`.
   - Accepting a critical issue requires a note.
7. **Sign-off** panel: Finance · Chief Accountant, IT · migration lead, Business · CFO.
   - Each shows state, who, when and the comment.
   - Approve and Reject (reason required) appear only for the matching signer. They call `migration_sign`.
   - Everything is locked while a critical issue is open, with that reason shown.
8. **Go live for <code>**:
   - Enabled only when `signed_off`, and only for the CFO.
   - Calls `company_go_live` (P1) after ConfirmDialog.
9. **Download report**: PDF (`@react-pdf/renderer`) and Excel (SheetJS) of every check, issue and sign-off, with the run id and the time.

## Done when
- With `supabase/tests/broken`:
  - critical issues appear and sign-off stays locked.
  - after the issues are accepted with notes and the figures are entered, all three can sign and go-live works.
- A wrong SAP report figure blocks sign-off until it is corrected.
- A Finance user sees only this screen and only the Finance actions.
