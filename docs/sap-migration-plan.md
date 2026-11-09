# SAP Business One → Super ERP · migration plan

Status: **plan only.** Nothing in this plan has been run against the live SAP system or production data.
Development and tests use the fictional company **ZZ99 "Sample Trading LLC (test data)"** (`supabase/sql/15_sample_company.sql`).

**Rules for every step**
- The live SAP system is never changed. We only read exported backups or a read-only database user.
- Production data is not imported into the live Super ERP until Ashif approves each company in writing (step 7).
- Real companies are AE01–AE04 (AE02 = A.T.M.M. Electronics). ZZ99 holds sample data and is removed before go-live with `15_sample_company_remove.sql`.

## 1. What we use today (inventory)

| Area | SAP source | What we know | Super ERP target |
|---|---|---|---|
| Companies | One SAP database per company | AE01 Sanford Middle East DWC (parent), AE02 A.T.M.M. Electronics, AE03 Abdulla Mohamed Home Appliances, AE04 Izaan General Trading | `erp.company`, `sap._company` |
| Data dictionary | CUFD / OUTB / OUDO | 3,691 tables, 117,772 fields, **610 user-defined tables** | — |
| Customers / suppliers | OCRD, CRD1, OCPR, OCRG | 36 user-defined fields on OCRD (Salesforce ID, 3PL rates, rent/incentive/discount terms, targets) | `business_partner`, `bp_address`, `bp_group`, `bp_merchandiser` |
| Items | OITM, OITB, OMRC, ITM1 | 107 user-defined fields on OITM (category levels, ODM division, sourcing, HS code, MOQ, container quantities, artwork) | `item`, `item_group`, `brand`, `item_price`, `price_list` |
| Stock | OITW, OWHS, OIBT/OBTN, OSRN, OIVL | Per-warehouse quantities, batches, serials, cost layers | `stock_balance`, `warehouse`, `batch`, `stock_movement` |
| Sales / purchasing / inventory documents | 19 document types (OQUT, ORDR, ODLN, ORDN, OINV, ORIN, ODPI, OPRQ, OPQT, OPOR, OPDN, ORPD, OPCH, ORPC, ODPO, OWTQ, OWTR, OIGN, OIGE + line tables) | 142 user-defined fields per document (PI, shipping mark, container, 3PL job, Salesforce order, intercompany ref) | `document`, `document_line` |
| Payments | ORCT, OVPM, RCT2/VPM2 | Cash, transfer, cheque, card | `payment`, `payment_allocation` |
| Accounting | OACT, OJDT, JDT1, OPRC, OVTG, ORTT | 46 user-defined fields on OJDT | `account`, `journal_entry`, `journal_line`, `cost_centre`, `tax_code`, `fx_rate` |
| Users and approvals | OUSR, OUSG, OWTM, OWST, OWDD | Approval templates and stages | `app_user`, `position`, `approval` (rebuilt, not copied: see 3.9) |
| Attachments | ATC1 plus the SAP attachments folder | Files live on the SAP file server, not in the database | Supabase Storage bucket `attachments` |
| HR / payroll / WPS add-on | `@ALT_HR_*` (489 tables) | Employees, pay, leave, air tickets, WPS | `employee`, `employee_pay`, `payroll_result`, `leave_type`, `wage_type`, `air_ticket_accrual` |
| Intercompany add-on | `@CTX_*` (60 tables) | Intercompany account map and transactions | `ic_account_map`, `ic_transaction` |
| Mobile warehouse (WMS) | `@BXP*` | Scanning and pick/pack | Rebuilt in Super ERP; history kept in the raw SAP copy |
| 3PL warehousing | `TPL_*` fields | Storage and handling rates, jobs | `tpl_contract`, document `tpl_job_no` |
| Other custom tables | `@TRADEMARK`, `@ARTWORKMASTER`, `@OLDSALEDATA`, `@PISTATUS`, `@QTRSALESDATA`, `@CATEGORY` and others | Trademark Master and Commitment Master are user-defined tables and stay as they are | `trademark`, `artwork_request`, `supplier_pi`, kept as-is where no target exists |

**Processes we use today** (from the SAP menus matched in the design): quotation → order → delivery → invoice → payment; purchase request → PO → goods receipt PO → A/P invoice with landed costs from China; stock transfers between Dubai warehouses; month-end journals and VAT; payroll and WPS through the HR add-on; intercompany postings between AE01–AE04.

### Open items for the inventory
- Confirm which of the 610 user-defined tables still get new rows. Those carry over; tables that are no longer used stay only in the raw SAP copy.
- Get the attachment folder path and its size from IT.
- Get the go-live (opening balance) date. It stays as `[GO-LIVE DATE]` until you give it.

## 2. Two ways to load

1. **Full history (recommended, already built).** The existing migration console (Back office › SAP migration) takes a SAP backup, copies every table into the hidden `sap` schema, then fills the app tables with `erp.sync_company` (83 steps) and cross-checks them. History stays queryable. Posted journals keep their SAP numbers.
2. **Opening balances only.** This loads master data, open documents and balances as at the go-live date. It is used if a company does not need history in Super ERP. The mapping in section 3 covers both ways; for option 2 the document scope shrinks to open documents only.

## 3. Field mapping

The source → target mapping for each column is already written as SQL in `supabase/sql/11_erp_sync.sql`. The rules that need a decision or a check are below.

### 3.1 Customers and suppliers (OCRD → `erp.business_partner`)
| SAP | Super ERP | Rule |
|---|---|---|
| CardCode | card_code | Kept exactly as in SAP, unique per company |
| CardType C/S/L | kind customer/supplier/lead | |
| CardName, CardFName | name, foreign_name | Trim spaces. Arabic is kept as written |
| GroupCode | group_code → `bp_group` | |
| Currency, CreditLine, Balance | currency, credit_limit, balance | Balance is checked against the sum of open A/R or A/P (section 5) |
| LicTradNum | trn | Checked as a 15-digit UAE TRN for UAE partners. Bad ones go on the error report and are not fixed by the import |
| SlpCode, ListNum, GroupNum | slp_code, price_list, payment_terms | Links checked |
| U_* (36 fields) | named columns (salesforce_id, tpl_*, rent_terms, …) | Fields that are not mapped are kept in the raw copy and listed on the custom-field report |
| CRD1 / OCPR | `bp_address`, contacts | Ship-to/bill-to kept |

### 3.2 Items (OITM → `erp.item`)
ItemCode is kept as the key. Category levels, ODM division, sourcing type, HS code, MOQ, container quantities and artwork reference come from the U_ fields. InvntItem, SellItem and PrchseItem become is_stock, is_sold and is_bought. Batch and serial flags are kept. AvgPrice becomes avg_cost (checked in 5.3).

### 3.3 Stock (OITW → `erp.stock_balance`; OIBT/OSRN → `batch`, serials)
OnHand, IsCommited, OnOrder and MinStock are copied per item and warehouse. Inventory value = Σ on hand × average cost per warehouse. It must equal the inventory G/L accounts (5.3).

### 3.4 Pricing (OPLN, ITM1 → `price_list`, `item_price`)
Base list and factor are kept. Special prices for partners (OSPP/SPP1) and period/volume discounts (OEDG) go to a planned `special_price` table before go-live. Until then they are listed on the custom-field report.

### 3.5 Open sales and purchase documents
All 19 types map into `document` / `document_line` using obj_type (see `src/features/erp/modules.ts`). For an opening-balances-only load:
- Open sales orders, POs, deliveries not yet invoiced, and goods receipts not yet invoiced are copied with their **open quantity** (OpenQty) and base-document links.
- Open A/R and A/P invoices and credit memos are brought in with their **open amount**. They are posted against an opening-balance clearing account, so the sub-ledger matches the control accounts.
- Down payments that are not cleared are kept as open down payments.

### 3.6 Accounting balances
| SAP | Super ERP | Rule |
|---|---|---|
| OACT | `account` | Account codes kept exactly, using SAP's real numbers. No sample values are used |
| Trial balance on the go-live date | One opening journal per company | Debit must equal credit (enforced by the database trigger). Control accounts (A/R, A/P, inventory) are posted through the sub-ledgers, not directly |
| OVTG | `tax_code` | Real SAP tax codes. No sample codes are used |
| ORTT | `fx_rate` | Daily rates from the go-live date onwards |
| OPRC / OOCR | `cost_centre` | Dimensions 1–5 kept |
| Fixed assets | asset classes, useful lives, depreciation accounts | Taken from SAP's fixed-asset setup. The design shows these screens empty until then |

### 3.7 Users
SAP users (OUSR) are **not** copied as logins. Each person gets a Super ERP account (Supabase Auth, email sign-in) and a `position`. SAP user codes are kept in `app_user` so history still shows who created a document. A table of SAP user → person → position goes to the system admin for sign-off before go-live.

### 3.8 Attachments
ATC1 rows give the file name and path. A worker job copies each file from the SAP attachments folder into the Storage bucket `attachments/<company>/<obj_type>/<doc_entry>/`, keeps the original name, and records size and SHA-256. Missing files go on the error report. The SAP folder is only read.

### 3.9 Approvals and custom fields
SAP approval templates (OWTM) are recreated as Super ERP approval rules: discount limit, credit limit, sale below landed cost, large PO, and changed bank details. Approvals still pending in SAP at cut-over are finished in SAP first. Every U_ field and @ table gets a line on the **custom-field register**: mapped to a column, kept in the raw copy only, or dropped as unused (needs your OK).

## 4. Import process

```
Backup → 1 Check files → 2 Stage → 3 Copy to SAP copy → 4 Clean & link checks → 5 Fill app tables → 6 Reconcile → 7 Sign-off → 8 Go live
```

1. **Test runs first.** Every run starts on a separate Supabase branch or a test database, never the live project. We run each company at least twice. The first run produces the error report. The second run, after fixes in SAP or the mapping, must come back with zero critical issues.
2. **Error report.** Each run writes to `erp.migration_issue`, which is shown on the Run and Cross-check screens and can be exported as CSV. Every issue has a severity (critical / warning), the table, the SAP key, the field, the value and the rule broken. Critical issues block sign-off.
3. **Duplicate handling.**
   - Same key twice in a table: the run stops (critical).
   - Same customer or supplier under two codes (same TRN, phone, or a name match after normalising): this is a warning. The import does **not** merge them; Finance decides, and any merge is done in SAP before the final run.
   - Same item under two codes (same barcode, or the same supplier part number from the same supplier): a warning, handled the same way.
   - Re-running a company replaces that company's rows table by table, so a run never creates duplicates.
4. **Reconciliation** (section 5) runs automatically after every load.
5. **Sign-off.** Finance, IT and Business sign each company in the migration console (`erp.migration_signoff`). Nothing goes live without all three **and Ashif's written approval to import production data.**
6. **Cut-over.** Freeze SAP posting at the end of the last day → take the final backup → final run → reconcile → sign → switch users over. SAP stays read-only for look-ups.

## 5. Reconciliation checks (must match before sign-off)

| # | Check | SAP side | Super ERP side | Tolerance |
|---|---|---|---|---|
| 5.1 | Record counts per table and per document type | COUNT(*) in the backup | Raw copy and app tables | 0 |
| 5.2 | Trial balance per account on the go-live date | JDT1 sums | `journal_line` sums | 0.00 |
| 5.3 | Inventory value = inventory G/L accounts | OITW × AvgPrice, OIVL | `stock_balance`, `account` | 0.00 per warehouse |
| 5.4 | Stock quantity per item and warehouse | OITW.OnHand | `stock_balance.on_hand` | 0 |
| 5.5 | A/R and A/P control accounts = open invoices − open credits − unapplied payments | OCRD.Balance, aging | Open `document` totals | 0.00 per partner |
| 5.6 | Open sales and purchase orders: count, open quantity, value | ORDR/OPOR open lines | `document_line.open_qty` | 0 |
| 5.7 | VAT payable and recoverable for the last open period | VAT accounts | VAT accounts | 0.00 |
| 5.8 | Intercompany balances net to zero across AE01–AE04 | `@CTX_*`, IC accounts | `ic_transaction` | 0.00 |
| 5.9 | Payroll: active employees and last month's net pay | `@ALT_HR_*` | `employee`, `payroll_result` | 0 |
| 5.10 | Attachments: files found, sizes and hashes | ATC1 + folder | Storage | 0 missing |

Checks 5.1, 5.2 and 5.4 already exist in the migration console's cross-check (`13_migration_console.sql`). Checks 5.3 and 5.5–5.10 are to be added (see section 6).

## 6. Work still to do for migration
1. The custom-field register: generate one line per U_ field and @ table from CUFD/OUTB, then review it with you.
2. Add reconciliation checks 5.3 and 5.5–5.10 to the cross-check.
3. Duplicate detection (TRN, phone, barcode, supplier part number) as warnings.
4. The attachment copy job in the worker.
5. A special prices table (OSPP/SPP1, OEDG).
6. The opening-balances-only loader (option 2), if any company chooses it.
7. A dry run on a **sanitized** backup: names, phones, emails, TRNs and bank details replaced, amounts kept. Your folder "sap back up tables" on your computer is not read until you say which files may be used and how they are sanitized.
