# A7 · Inventory transactions

SQL file: `supabase/sql/22_inventory.sql`.

## Build
- **Inventory transfer request → inventory transfer** between warehouses (Dubai main, Jebel Ali store, in transit, QC). Stock moves out and in; `stock_movement` is written; no posting unless the warehouses are on different stock accounts (then post through A3).
- **Goods receipt and goods issue** (non-PO) with a reason and an account. Approval above a value.
- **Inventory counting:**
  - Create a count for a warehouse or item group.
  - Count sheets can be filled on a phone (big inputs, barcode field).
  - The variance report needs approval when the variance is over 1 % (rule from the design).
  - Posting adjusts stock and posts the variance through A3.
- **Batches and serial numbers** for items that use them: required on receipt and issue, with history by batch or serial (Inventory › Item Management › Batches / Serial Numbers become live).
- **Bin locations:** optional per warehouse; put-away and pick by bin.
- Inventory status and Items stay as built in Stage 1. Add movement history to item detail.

## Tests
- Transfer keeps the total quantity.
- Issue beyond available stock is refused.
- A count with variance over 1 % waits for approval.
- A missing serial on issue is refused.
- Every movement row ties back to its document.

## Needs from Ashif
Which warehouses use bins, batch/serial-managed item groups, and the count approval rule.
