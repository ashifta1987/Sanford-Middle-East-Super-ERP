# A6 · Purchasing: China sourcing flow and landed costs

SQL file: `supabase/sql/21_purchasing.sql`. Depends on A3 and A5.

## Flow (from the design; four China offices: Shenzhen, Foshan, Dongguan, Ningbo → Dubai)
1. **Purchase request:** any staff member, with an item, quantity and needed-by date.
2. **Purchase quotation (RFQ):** several suppliers, compared side by side (Purchase Quotation Comparison).
3. **Purchase order:** approval above an amount (`approval_rule`, e.g. "Large purchase order"). There is also a "purchase price over last +10 %" check.
4. **Proforma invoice (PI) and deposit:** `supplier_pi` (exists in `10`) with status tracking (custom PI Status from SAP), and an A/P down payment invoice plus an outgoing payment for the deposit.
5. **QC inspection** before shipment: pass, fail or rework, with photos stored in Storage `qc/<company>/<po>/`.
6. **Shipment:** container number, shipping mark, ETA, mode (fields already on `document`). The ETA feeds ATP (A4).
7. **Goods receipt PO** into a Dubai warehouse: stock in, at PO price.
8. **A/P invoice:** clears the down payment and posts through A3.
9. **Landed costs:** freight, duty, insurance, clearing, local transport. Each cost is split by the method set per landed cost code (volume CBM, quantity, value, weight), and average cost is updated. Landed cost codes come from SAP. **No sample values** for real companies (decision of 9 Nov); create codes for ZZ99 only.

## UI
- Each step uses the document form pattern with the flow strip: Request → Quotation → PO → PI/Deposit → QC → Shipment → GRPO → A/P invoice → Landed costs.
- A "China office" filter on the lists.

## Tests
- Full path for ZZ99.
- The landed cost split adds up exactly (the rounding remainder goes on the last line).
- Average cost is updated.
- PO approval is enforced.
- GRPO beyond the PO quantity is refused.

## Needs from Ashif
The real landed cost codes and split methods, PO approval limits, and the QC checklist.
