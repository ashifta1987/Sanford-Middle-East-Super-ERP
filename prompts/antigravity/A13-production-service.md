# A13 · Production and Service

SQL file: `supabase/sql/28_production_service.sql`. Lower priority. Build after A7.

## Production (moulded items made in-house)
- **Bills of materials:** components, quantity, warehouse, and moulds as resources.
- **Production order:** planned → released → issue components → report output → closed. Blocked when components are short (shown with the PO that will arrive, from A6).
- **Mould maintenance schedule** and shot counts (attribute group from the fixed-asset design).
- **Cost:** components + resource cost, posted through A3.

## Service
- **Service calls:** customer, item or serial, problem, assigned technician, status, solution.
- **Warranty check** from the serial number and invoice date.
- **Service contracts** and 3PL contracts (`tpl_contract` exists).
- **Spare parts issue** uses A7 goods issue.

## Tests
- Production order consumes components and adds finished stock at the right cost.
- A service call on an out-of-warranty serial is flagged.
