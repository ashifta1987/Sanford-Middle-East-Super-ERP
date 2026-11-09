# A12 · Finish the SAP migration tools

Read `docs/sap-migration-plan.md` first. **Never connect to the live SAP system and never import production data.** Use ZZ99 and a **sanitized** backup only, supplied by Ashif. SQL file: `supabase/sql/27_migration_more.sql`. The existing console (`src/features/migration/`, `13_migration_console.sql`) works; extend it, don't rewrite it.

## Build (plan §6)
1. **Custom-field register:** `erp.custom_field_register(company_code, table_name, field_name, description, decision mapped|raw_only|drop, target, rows_used, last_used)`, generated from CUFD/OUTB in the raw copy. The admin reviews it on a new console tab; "drop" needs Ashif's approval.
2. **New reconciliation checks** in the cross-check (plan §5):
   - 5.3 inventory value = inventory G/L accounts
   - 5.5 A/R and A/P control accounts = open documents per partner
   - 5.6 open orders quantity and value
   - 5.7 VAT accounts
   - 5.8 intercompany nets to zero
   - 5.9 payroll headcount and net pay
   - 5.10 attachments

   Each check writes `migration_check` with SAP / raw / app values and the difference.
3. **Duplicate detection:** customers and suppliers by TRN, phone and normalised name; items by barcode and supplier part number. Write **warnings** to `migration_issue`, never merges.
4. **Attachment copy job** in the worker:
   - copy ATC1 paths to Storage `attachments/<company>/<obj_type>/<doc_entry>/`
   - record the size and SHA-256
   - missing files become issues
   - the SAP folder is read only
5. **Special prices:** `special_price` (OSPP/SPP1) and period/volume discounts (OEDG), plus sync steps.
6. **Opening-balances-only loader** (plan §2 option 2), behind a run kind `opening_only`.
7. **Run report export:** one PDF/CSV per run with all checks, issues and sign-offs, for the auditors.

## Tests
- Run the console end to end on the test exports in `supabase/tests/` (`testexp/`, `broken/`).
- The new checks pass on good data and catch planted errors.
- Duplicates are found in a planted pair.
- The attachment job reports a missing file.

## Needs from Ashif
A sanitized backup, the attachments folder path and size, and approval of the custom-field register.
