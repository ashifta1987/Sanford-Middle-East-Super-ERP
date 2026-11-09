# A10 · Administration

SQL file: `supabase/sql/25_admin.sql`. Admin/IT positions only, every change audited. Changes to company details need Owner approval (design).

## Build (the functions marked "Planned" in Administration)
- **Users:**
  - invite by email (Supabase Auth invite, sent from an Edge Function using the service role, **never from the browser**)
  - assign position, companies, employee link and language; activate or deactivate
  - a list with last sign-in
- **Positions and Authorizations:**
  - the Full / Read / None matrix per module (from the design's Authorizations screen), writing `erp.position_module` from A1
  - shows who would gain or lose access before saving
- **Approval templates:** a UI for `erp.approval_rule` (A2): rule, documents, condition, approvers by step. The design's examples:
  - discount above salesperson limit
  - credit limit exceeded
  - large purchase order
  - payment to new or changed bank account
  - sale below landed cost
  - long leave
- **Document numbering:** a UI for `erp.number_series`, per document type and branch, with prefix and next number.
- **Company details:** legal name, TRN, address and logo for printing.
- **Exchange rates:** a daily rates table (USD, SAR, CNY, EUR → AED), entered by Finance or imported.
- **Add-Ons › AI Assistant (decision of 9 Nov: lives under Add-Ons):**
  - provider for chat and voice
  - which modules and tables it may read (never `sap`, never salary)
  - monthly usage limit
  - on/off per company

  The API key is stored only as a Supabase secret, used by an Edge Function. **It is never stored in a table readable by the browser.**
- **Setup screens** currently shown as design previews (tax, G/L determination, fixed assets, landed costs, etc.) become live only when their phase builds the data. Until then they stay previews with "No sample values" for real companies.

## Tests
- A non-admin is refused everywhere.
- The invite flow works with a test inbox.
- A matrix change takes effect on the next request.
- An approval template change applies to new documents only.
- The AI key can't be read from the client.

## Needs from Ashif
The real users, positions and companies list; the approval limits; and the AI provider choice.
