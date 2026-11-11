# Decisions · Ashif's answers of 10 Nov 2026

The answers to every "Needs from Ashif" item in the A1–A14 walkthroughs. This file wins over the phase prompts where they disagree.
Principle: **anything company-specific is entered by Sanford in the front end later.** The system must offer a configuration screen for it (SAP Business One style). Keep empty settings for AE01–AE04. ZZ99 keeps its marked SAMPLE values.

## 1. New pilot company
- Create company **AE05 · UAE - ATMM GENERAL TRADING LLC** (country AE, currency AED, licence type to be confirmed, SAP schema not known yet).
- It is the **pilot company**. The SAP backup is uploaded later through the Migration console, and the go-live date is planned after that.
- Companies are created from the front end (Administration › Companies) and seeded in SQL for AE05.

## 2. Configuration modules to build (front end, SAP B1 style)
| # | Module | What it must do |
|---|---|---|
| C1 | **Document Numbering** (Administration › System Initialization › Document Numbering) | Covers every transaction type. Several series per document type, per company, each with name, prefix, first/next/last number, optional period/year and branch/warehouse, and locked/active. **Default series per document type per user** (and a company default). A user picks a series on new documents. Next numbers only move forward. |
| C2 | **G/L Account Determination** (Administration › Setup › Financials) | Fully editable mapping like SAP B1 for Sales, Purchasing, Inventory, Banking, Production, Service, Payroll, Landed costs and Price difference. Levels: company default → **item group** → **warehouse (Accounting tab)**. All AE01–AE05 accounts are entered here later. |
| C3 | **Approval Management** (Administration › Approval Procedures) | A separate module. Create, update and deactivate approval templates for every document type (sales, credit memo, purchase, incoming payment, outgoing payment, goods receipt/issue, stock count, journal, credit limit, BP bank details, master data, company details …). Each template has **originators** (positions or users) that can be added or removed, **authorizers** and stages that can be changed, conditions (amount, discount %, deviation % …) and an active flag. Limits are set later by Sanford. |
| C4 | **Landed Cost setup** (Purchasing setup) | Master list of landed cost types, each with allocation method (quantity, weight, volume, value, equal) and account mapping. Fully customizable. |
| C5 | **Warehouse setup** | Each warehouse has an Accounting tab (its own stock / variance / price-difference accounts, empty = company default), a bin locations switch, and default numbering series. |
| C6 | **Item group setup** | Management method (none / batch / serial), warranty months, and G/L accounts per group. |
| C7 | **Production setup** | Resources with hourly rates, plus WIP, variance, resource absorption and spare-parts accounts through C2. |
| C8 | **Service setup** | Who may issue spare parts is a configurable permission (default: the Service Manager position). It can be changed any time, per position or user. |
| C9 | **Multi-currency** | Sales and purchase documents and payments use the business partner's currency (BP currency, or "all currencies"). Rates come from `fx_rate_list`. Posting stores local and foreign amounts. Realised FX gain/loss happens at payment. |

## 3. Rules decided
| Area | Decision |
|---|---|
| Approvals (all) | Logic and limits are configured later in C3. No hard-coded limits for real companies. |
| Incoming payments | Must support approval, through C3. Logic is configured later. |
| Credit memos | Approval through C3 (template "credit memo", amount condition). **Direct service invoices** use the same discount-approval template as sales orders. |
| Expired quotation | **Blocks** copying into an order. |
| Negative stock | **Never allowed.** |
| QC | **QC must pass before goods can ship.** |
| Landed cost on goods already sold | Goes to the **price difference account**. |
| BP duplicate check | **Remove** the name-similarity duplicate warning for business partners. OEM/ODM types are kept as configurable values. |
| Commitment Master | Keep it as a design preview. Nothing to migrate. |
| Production issue | Skips the goods-issue approval (as built). |
| Production receipt | Can't exceed the planned quantity or come before an issue (as built). |
| Mould maintenance | Sensible defaults: maintenance every 50,000 shots, rated life 500,000 shots, warn at 80% of the interval or life. All editable per mould. |
| Stock count approval | Keep the ZZ99 samples (1% per line and AED 5,000). Real values are configured later. |
| GR/GI reasons (AE01–AE05) | Seed the standard reasons (damage, sample, internal use, write-off, found, opening, service), each mapped to a G/L determination key. The accounts themselves are entered in C2. |
| Bank statement matching | Best practice: a generic CSV import with column mapping saved per bank account. Auto-match needs an exact amount, a date within ±3 days, and a reference/cheque number when one exists. Anything else goes to manual match. |
| Supplier bank change | The 30-day block is confirmed for all outgoing payment types. Who may change bank details is configured in C3. |
| Soft-switch stock | Best option: SAP stays the baseline. **Super ERP stock = SAP on-hand (from the latest sync) + net Super ERP movements** (documents with source = 'erp'), because those are never sent back to SAP. The sync must never wipe out Super ERP movements. |
| Invoice layout | Standard layout for now. Sanford supplies its own later. |
| Custom-field register | **Approved.** |
| SAP column names and OCRD.Balance sign | **Confirmed.** |
| Master data after go-live | Uploaded module by module later. |
| AI | Provider key set as a Supabase secret and the function deployed by IT (done by Ashif). |
| Control Tower | Limits and the 30-day look-back are confirmed. |
| Partner codes | Confirmed (C/S/L + 5 digits pattern, configurable via C1-style series). |

## 4. Entered later in the front end, no build needed
Real users and positions, owner position, approval limits, currencies, number prefixes, leave/weekend/holidays, overtime/unpaid leave, WPS routing/MOHRE/SIF, attendance sites, gratuity/air tickets, payroll accounts, bank accounts, PI statuses, China offices, required fields, bins/batches per warehouse/group, warranty months, opening date/clearing account/VAT period, attachments folder, opening balances, which reports come next.


## 5. Added 11 Nov 2026
| Area | Decision |
|---|---|
| Sana languages | **English and Malayalam are the priority languages.** They are listed first in the Sana panel and admin screen. Basic mode understands and answers Malayalam on every topic. The other 9 languages stay available. |
| Sana AI mode | No provider key yet: Sana runs in basic mode. Set `ANTHROPIC_API_KEY` as a Supabase secret to switch on AI answers. |
| Sana live | `36_sana.sql` applied on live (5 tables, 29 functions). Edge Function `sana` deployed (v1). `main` = 449ac5f on Vercel production. |
