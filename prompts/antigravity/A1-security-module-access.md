# A1 · Module-level access (Full / Read / None)

## Why
Today the read policies in `12_erp_security.sql` limit rows by **company** on every table, but by **module** only on HR tables. So a sales-only user is blocked in the UI yet can still read journal entries and payments through the API. This phase closes that gap. It also adds the Full / Read / None levels that the design's Authorizations matrix shows.

## Build: `supabase/sql/16_module_access.sql` (don't edit `12`)
1. **Table `erp.position_module`**
   - columns `position_code` → `erp.position`, `module text`, `level text CHECK (level IN ('read','full'))`
   - primary key (`position_code`, `module`)
   - RLS: readable by `authenticated`; writes only through an admin function (A10 builds its UI)

   Module keys: `admin, it, finance, sales, purchase, bp, banking, inventory, production, service, hr, reports, business`. `business` = Owner/MD (reads everything).
   **Backward compatible:** a module listed in `position.module_access` with no row in `position_module` counts as `full`.
2. **Helpers** (`SECURITY DEFINER`, `STABLE`, `search_path = erp, pg_temp`), granted to `authenticated`:
   - `erp.module_level(p_module text) returns text`: 'full' / 'read' / null for the current user
   - `erp.can_read(p_module text)`: true when the level is read or full, or the user has `business` or `admin`
   - `erp.can_write(p_module text)`: true when the level is full (admin does **not** automatically get write in finance)
3. **RESTRICTIVE policies.** They are AND-ed with the existing permissive company policies, which is why `12` doesn't need editing: `CREATE POLICY … AS RESTRICTIVE FOR SELECT TO authenticated USING (…)`:

   | Tables | Allowed when |
   |---|---|
   | `account`, `journal_entry`, `journal_line`, `cost_centre`, `fx_rate`, `tax_code` | can_read('finance') |
   | `payment`, `payment_allocation` | can_read('banking') or can_read('finance') |
   | `document`, `document_line` | by document kind: sales kinds → can_read('sales') or can_read('finance'); purchase kinds → can_read('purchase') or can_read('finance'); inventory kinds → can_read('inventory'). Use `obj_type` on lines (map in `src/features/erp/modules.ts` › `DOC_KINDS`) |
   | `business_partner`, `bp_address`, `bp_group` | can_read('bp') or can_read('sales') or can_read('purchase') or can_read('finance') |
   | `item`, `item_group`, `item_price`, `price_list`, `stock_balance`, `warehouse`, `batch`, `stock_movement` | can_read('inventory') or can_read('sales') or can_read('purchase') |

   Leave `company`, `branch`, `app_user`, `position`, `user_company` and the HR tables as they are.
4. **Indexes:** check `EXPLAIN` on a 1M-row `document` list query. The policy functions must be `STABLE` and must not run once per row in a way that turns a list into a full scan. Wrap them as `(SELECT erp.can_read('sales'))` so Postgres evaluates them once.

## UI
- `src/features/erp/modules.ts` › `canOpenModule` uses the same rules: read the user's levels from `position_module` in `AuthProvider` alongside `module_access`.
- When a user has **read** only, screens hide or disable "New…", "Edit" and "Approve", with the reason "Read-only access to Sales".

## Tests
- `supabase/tests/a1_module_access.sql`. As each test user, check:
  - sales-only user: sees sales documents; sees 0 rows of `journal_entry`, `payment` and purchase documents; gets an error for direct table writes
  - finance user: sees journals and both sales and purchase documents
  - owner (`business`): sees everything
  - user with no profile: sees nothing
  - **existing behaviour unchanged** for HR tables
- Extend the Playwright test: as the sales user, `/financials/journals` shows the no-access screen and a direct API fetch returns `[]`.

## Done when
All tests pass, the Stage 1 Playwright test still passes 35/35, and the Walkthrough lists every table with its new rule.
