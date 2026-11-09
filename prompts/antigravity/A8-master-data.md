# A8 · Master data: business partners and items

SQL file: `supabase/sql/23_master_data.sql`.

## Build
- **Business partner create and edit** (customer, supplier, lead) for ERP-sourced partners:
  - code from a series per type (`C`, `S`, `L` + number, per company)
  - name, foreign (Arabic) name, group, currency, TRN (15-digit UAE format check for UAE partners), contacts, addresses, payment terms, price list, salesperson, credit limit
  - **Credit limit changes and bank detail changes need approval** (Finance manager); the history is kept in `audit_log`
- **SAP partners stay read-only** until the company's cut-over. The edit button explains: "This partner comes from SAP. Change it in SAP until AE01 goes live on Super ERP."
- **Duplicate warning before saving:** same TRN, same phone, or a similar name (trigram similarity > 0.8). The user must confirm with a reason.
- **Item create and edit:**
  - code, names, group, units, barcode (unique per company), HS code, MOQ, container quantities, sourcing type, preferred supplier, tax code, sales/purchase/inventory flags, batch/serial management
  - Duplicate warning on barcode or supplier part number.
- **Trademark Master** (Business Partners) and **Commitment Master** (Inventory) stay as SAP user-defined tables (decision of 9 Nov). Show them read-only from the migrated data. Don't redesign them.

## Tests
- Every validation.
- Duplicate warning shown.
- Credit limit change waits for approval.
- SAP rows can't be edited.
- A read-only user is refused.

## Needs from Ashif
Code series per company, which fields are mandatory, and who approves credit limit changes.
