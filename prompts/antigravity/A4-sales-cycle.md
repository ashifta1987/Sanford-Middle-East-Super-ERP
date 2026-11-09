# A4 · Sales cycle: quotation → order → delivery → invoice → credit memo, with ATP

Depends on A2 (sales order) and A3 (posting). SQL file: `supabase/sql/19_sales_cycle.sql`.

## Build
- **Sales quotation:** same form and rules as the sales order (discount and below-cost rules). Copy to sales order keeps the base document links (`base_obj_type`, `base_doc_entry`, `base_line`) and the remaining quantities.
- **Available-to-Promise (switched on, decision of 9 Nov):**
  - `erp.atp(p_company, p_item, p_whs, p_date)` = on hand − committed + incoming POs and transfers due by that date. It uses ETAs from shipments when A6 provides them.
  - The order form shows "Can promise 120 by 13 Nov" per line. Promising more than ATP needs a confirmation with a reason, which is logged.
  - Read the ATP rules from Setup › Sales › ATP Checking Rule List: a new settings table, editable by sales + full.
- **Delivery from an approved order:**
  - picks the warehouse
  - reduces `stock_balance.on_hand` and `committed`, and writes `stock_movement`
  - closes order lines by quantity
  - posts cost of goods sold through A3 (inventory → COGS), at average cost
  - refuses negative stock unless the warehouse allows it
- **A/R invoice** from delivery(s), or directly for service items. It posts A/R, revenue and VAT through A3, and updates the customer balance.
- **A/R credit memo** based on an invoice. It reverses revenue and VAT, and optionally returns stock.
- **Document flow strip** on every sales document, using the base links in both directions.
- **Print / PDF:** a clean A4 layout in English and Arabic, with company details from `erp.company` and the TRN. Use a server-rendered PDF or the browser's print CSS. No external services.

## Tests
- Full path for ZZ99: quotation → order (approval) → partial delivery → invoice → credit memo.
- Stock, open quantities, customer balance, journal totals and VAT all reconcile.
- ATP warning shown.
- Over-delivery refused.
- Invoice in a closed period refused.

## Needs from Ashif
The invoice layout (or a sample PDF), and whether negative stock is ever allowed.
