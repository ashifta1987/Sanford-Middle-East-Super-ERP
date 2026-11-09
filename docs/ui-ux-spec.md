# Sanford Super ERP · UI/UX specification

The single reference for how every screen looks and behaves. It follows the canvas design ("Super ERP UI/UX Structure", 11 modules matched to SAP Business One) and the Stage 1 code, which already implements most of it. Reference screenshots: `design/reference/*.png`.

When this document and a screenshot disagree, this document wins. When the code and this document disagree, fix the code.

---

## 1. Principles
1. **SAP-familiar, simpler.** The menus, function names and their order match SAP Business One, so staff find things where they expect them. Each screen still shows one job, in plain words.
2. **Real or clearly labelled.** A screen is either connected to data and marked **Live data**, or it is a **Design preview** under an amber banner. Never show sample numbers as if they were real.
3. **Every rule is visible.** If something blocks an action (an approval, a credit limit, a closed period), the screen names the rule, who can lift it, and what to do next.
4. **Same pattern everywhere.** One list pattern, one detail pattern and one document form pattern, shared by all modules.
5. **English and Arabic, light and dark, desktop and phone,** all from the first build of each screen.

## 2. Design tokens
Defined once as CSS variables in `src/index.css` and used through Tailwind names (`tailwind.config.js`). Never hard-code a colour.

| Token (Tailwind) | Light | Dark | Use |
|---|---|---|---|
| `page` | #F4F5F7 | #0B0F17 | App background |
| `surface` | #FFFFFF | #121826 | Cards, top bar, inputs |
| `surface-2` | #F8F9FB | #182032 | Table headers, hover rows |
| `line` / `line-strong` | #E4E7EC / #D0D5DD | #253049 / #33405A | Borders / input borders |
| `ink` / `ink-2` / `muted` | #101828 / #475467 / #5D6B82 | #F2F4F7 / #C0C7D4 / #98A2B3 | Text, secondary text, labels |
| `primary` | #4338CA | #4F46E5 | Primary buttons, links, focus |
| `primary-soft` / `primary-text` / `primary-line` | #EEF0FF / #3730A3 / #C7CBFA | #1E2050 / #C7D2FE / #3B3F8F | Selected items, AI notes |
| `side` / `side-active` / `side-active-text` | #FFFFFF / #EEF0FF / #3730A3 | #0E1420 / #1E2050 / #E0E7FF | Sidebar |
| `ok` bg/fg | #ECFDF3 / #067647 | #0A2A1C / #75E0A7 | Approved, posted, active, live |
| `warn` bg/fg | #FFFAEB / #B54708 | #2E1F06 / #FEC84B | Waiting, below minimum, preview banner |
| `crit` bg/fg | #FEF3F2 / #B42318 | #2D1212 / #FDA29B | Blocked, cancelled, errors |
| `info` bg/fg | #EEF0FF / #3730A3 | #1E2050 / #C7D2FE | Open, in progress |
| `neutral` bg/fg | #F2F4F7 / #344054 | #1D2638 / #D0D5DD | Closed, planned, off |

- **Type:** IBM Plex Sans (Latin) and IBM Plex Sans Arabic (Arabic), IBM Plex Mono for codes (item no., account, document no.). Tabular numbers everywhere.
- **Sizes:** page title 28 px / 600 (26 px on phones); section title 15 px / 600; body 15 px; table 14 px; labels and pills 12–13 px. Eyebrow: 12 px uppercase, letter-spacing .05em, `muted`.
- **Radius:** cards 16 px, buttons and inputs 10 px, pills fully round.
- **Shadow:** a 1 px soft shadow on cards in light mode, none in dark.
- **Spacing:** 4 px grid. Card padding is 20 px. Gaps between cards are 20 px. Page gutter is 28 px on desktop and 16 px on phones. Content max width is 1280 px.
- **Icons:** the canvas set in `src/features/erp/icons.tsx` for modules, `lucide-react` elsewhere. 18 px, stroke 1.8.
- No emoji, gradients or decorative images.

## 3. App shell
- **Sidebar (248 px, sticky):**
  - brand block
  - **Home**
  - **Modules** 01–11 in SAP order: Administration, Financials, Sales, Purchasing, Business Partners, Banking, Inventory, Production, Service, Human Resources, Reports. Each row shows its icon and number.
  - **Oversight:** Control Tower, Approvals
  - the user card at the bottom

  A user sees only the modules their position allows. The module stays highlighted on its list, detail and form pages. On phones the sidebar becomes a drawer behind the menu button.
- **Top bar (sticky):**
  - company switcher (code chip, legal name, currency; "GRP" = all companies the user may see)
  - global search (Ctrl/⌘ K, Enter goes to `/search?q=`)
  - Ask AI (planned until Add-Ons › AI Assistant is built)
  - Approvals bell (hidden on phones)
  - theme toggle
  - language toggle EN · ع
  - change password
  - sign out
- **Breadcrumb** on every inner page: Home › NN Module › Screen › Record.

## 4. Page patterns

### 4.1 Module page (`/m/:module`)
- **Left card:** "Functions (n)", a search box, then the SAP functions in SAP order, each with its number, name ("›" when it has a submenu), a green dot when something inside is live, and a tag: `Off in SAP` (neutral), `Custom` (amber), `New` (indigo).
- **Right:**
  - a card with the function's number (`03.02`), name, description, the AI note (indigo box), and the main **Open …** button when the function has a working screen
  - below it, the sub-functions list, each with a **Live data**, **Design preview** or **Planned** tag

  The selected function is kept in the URL (`?fn=`).

### 4.2 List page
One component: `src/features/erp/components/ListScreen.tsx`.
- **Header:** breadcrumb, title, **Live data** pill, one-line description, and the primary action on the right (e.g. "+ New sales order"). A disabled action shows why ("Stage 2").
- **Toolbar:**
  - search box, which searches on the server (debounced 300 ms; Enter searches at once)
  - one drop-down per filter
  - **Export CSV**: the same filters and sort, up to 5,000 rows, with UTF-8 BOM so Excel opens Arabic correctly
- **Under the toolbar:** "n results", "updating…", and "Clear search and filters".
- **Table:**
  - sortable headers with an arrow and `aria-sort`
  - the first column is the record link
  - the whole row is clickable
  - numbers right-aligned and tabular
  - codes in mono
  - status as pills
  - columns hidden on small screens by priority
- **Paging:** 25 rows per page (50 for the chart of accounts), Previous / Next.
- **State in the URL:** `q`, `f_<field>`, `sort`, `dir` and `page`, so Back and shared links work.

### 4.3 Detail page
Breadcrumb and title (`code · name`) with a status pill. Then cards: **General** (a label/value grid, 3 columns on desktop and 1 on phones), then related tables (stock by warehouse, prices, recent documents, lines). Every record shows its **Source**: SAP Business One, Super ERP, or Sample test data.

### 4.4 Document form (the sales order prototype: the pattern for all 19 document types)
Two columns on desktop (main + 360 px aside); on phones the aside follows the main column.

**Main column**
1. **Header row:** back link "← Sales", breadcrumb, title "Sales order SO-26-00042", status pill, source pill. On the right: **Print / PDF** and **Copy to …** (e.g. Copy to delivery; disabled until approved, with the reason underneath). Under the title, one line: customer · city · salesperson · created at.
2. **Document flow strip:** Quotation → Order → Delivery → Invoice → Payment. Done steps are green and link to the document; the current step is indigo; future steps are grey.
3. **Header fields (grid of 6):** Customer, Posting date, Delivery date, Price list, Payment terms (with credit left), Warehouse.
4. **Lines table:** Item (name in bold, then "code · n in stock" in muted), Qty, Unit price, Disc. (pill), Line total.
   - A line that breaks a rule gets a `warn` background and a note under it, e.g. "**Check** 18% is above Rahul K.'s discount limit of 10%. This customer's last 6 orders averaged 7%."
   - Totals block on the right: Before discount, Discount, VAT 5%, **Total AED**.

**Aside**
- **Approval card**, only while waiting, and only to an approver: "Your approval is needed", the rule name, requested by / when, the requester's reason in quotes, and buttons **Approve**, **Approve at n%** (when a lower value would pass the rule) and **Reject** (needs a note).
- After a decision, the card turns green or red, e.g. "Approved by you, just now. Rahul K. and the warehouse were notified."
- **Activity timeline:** created, checks run, sent for approval, decisions. Times in the user's time zone.
- **Ask AI about this order:** stays "Planned" until AI Assistant is built.

**Edit mode** (new, or a draft)
- **Customer and items:** the customer is a search combobox (code, name, phone, TRN; shows balance and credit left). Each line has an item combobox (code, name, barcode; shows stock in the chosen warehouse and the price from the customer's price list).
- **Line entry:** quantity, price and discount are number inputs with tabular digits. Enter adds a line, and a line can be removed (with Undo).
- **Totals:** they recalculate as you type, but the server recalculates and is the authority on save.
- **Buttons:** **Save draft** (secondary) and **Submit** (primary). Submit shows what will happen: "Goes straight to Open", or "Needs approval: discount above your 10% limit".
- **Validation:** shown inline under the field, plus a summary at the top that links to each problem. The server's message is shown as written (section 8).
- **Leaving with unsaved changes** asks for confirmation.

### 4.5 Approvals inbox (`/approvals`)
- **Tabs:** Waiting for me / Sent by me / Decided.
- **Rows:** rule, document (link), requester, amount, how long it has waited.
- **Actions:** approve and reject happen on the document page, not in the list, so the approver sees the full context.

### 4.6 Control Tower (`/control`)
- **Check cards:** one per rule, with a count, clickable to filter.
- **Severity chips:** All / Critical / Warning.
- **Findings list:** severity pill, "rule · subject", company · detail, amount or shortfall. Each links to the record.
- **Note:** says that checks run with the user's own access rights.

### 4.7 Design preview (`/preview/:key`)
- **Amber banner:** "Design preview — not connected. This screen shows the layout and sample wording from the design. It does not read or save your data and is not working functionality yet."
- **Tables** with no sample values show "No sample values. Filled from your SAP during migration."

### 4.8 Home
- **Greeting and description.**
- **KPI cards** (2–4 per row): open sales orders, open POs, overdue A/R, below minimum stock, A/P due in 7 days, open quotations, customers, items. Each card links to the filtered list. A card appears only when the user has that module.
- **Module cards:** number, title, description, "n SAP functions · m with working screens".

## 5. Components and states
| Component | Rules |
|---|---|
| Button | Min height 44 px. Variants: primary, secondary, ghost, danger, success. A disabled button is grey with its reason underneath (`disabledReason`). One primary button per area. |
| Input / select | Min height 44 px (40 px in toolbars), label above, help or error text below. Errors in `crit-fg` with an icon and `aria-describedby`. |
| Pill | Status only; don't use pills as buttons. Tones as in section 2. |
| Card / SectionCard | Title bar (15 px / 600) with optional right-side content; body has no extra padding when it holds a table. |
| Combobox | Type at least 1 character, results after 250 ms, arrow keys plus Enter, "No match — check the code or create it in Business Partners". |
| Dialog | Only for destructive or irreversible confirmations. Title says the action ("Reject sales order SO-26-00042?"). Esc closes it and focus returns to the trigger. |
| Toast | Short confirmation after a save ("Saved as draft"). Errors are not shown as toasts; they stay on the page. |
| Loading | Skeleton rows in tables, "Loading…" with a spinner for pages. No layout jump. |
| Empty | Icon, title and one helpful sentence ("No matches. Try a shorter search or clear the filters."). |
| Error | Alert icon, the message (section 8) and **Try again**. |
| No access | Lock icon: "You don't have access to this", "Your position does not include Financials. Ask the system admin if you need it.", and a link Home. |

## 6. Responsive, RTL, accessibility
- **Breakpoints:** phone up to 639 px, tablet 640–1023, desktop 1024 and up. Check at 390 and 1440 px.
- **Phones:** no horizontal page scroll at 390 px. Cards stack, wide tables scroll inside their card, and less important columns hide.
- **RTL:** use logical CSS only (`ms-`, `me-`, `ps-`, `start-`, `end-`); mirror arrows with `rtl:rotate-180`. SAP function names and English data stay in English with `dir="auto"`. Numbers stay in Western digits, and dates use `ar-AE` formatting.
- **Accessibility:**
  - real `button`, `a` and `label` elements; `th scope="col"`; `aria-sort`; `aria-live` for result counts
  - a skip link; visible focus (2 px primary outline)
  - contrast at least 4.5:1 in both themes
  - a target size of at least 40 px

## 7. Words
- Use SAP names for functions and documents (Sales Order, A/R Invoice, Goods Receipt PO). Write everything else in plain, short sentences.
- Button labels name the action: "Submit for approval", not "OK".
- Amounts show their currency ("6,097.39 AED"). Dates look like "08 Nov 2026".
- Never say "successfully". Say what happened: "Approved. Rahul K. was notified."

## 8. Error messages (the server is the authority)
Database functions raise errors with a clear message; the UI shows it as written, next to the field or at the top of the form. Fixed mappings:

| Code | Message shown |
|---|---|
| `42501` | You don't have access to this. |
| `23505` | This already exists: {detail}. |
| `P0001` (from our functions) | The function's own message, e.g. "Discount 18% is above your limit of 10%. Submit it for approval or lower the discount." |
| Network / timeout | We couldn't reach the server. Check your connection and try again. Nothing was saved. |

## 9. Screen inventory and status
Each SAP function is in `src/features/erp/design-data.json` (from the canvas) and in `src/features/erp/modules.ts`, which records which ones have a working screen. Status after Stage 1:

| Module | Live (read only) | Next to build |
|---|---|---|
| 01 Administration | SAP B1 migration console | Users, positions, authorizations, approval templates, numbering, Add-Ons › AI Assistant |
| 02 Financials | Chart of accounts, journal entries | Posting engine, manual journals, period lock, G/L determination |
| 03 Sales | All 7 sales document lists + detail | Sales order with approval (Stage 2), copy-to, ATP, delivery, invoice |
| 04 Purchasing | All 8 purchase document lists + detail | China flow: request → PO → PI/deposit → QC → shipment → GRPO → A/P + landed costs |
| 05 Business Partners | BP master list + detail | Create/edit with approval, credit limits |
| 06 Banking | Incoming and outgoing payments | Create payments, approvals, bank-detail-change block, reconciliation |
| 07 Inventory | Items, stock, prices, 4 inventory doc lists | Transfers, goods receipt/issue, counting, batches/serials, bins |
| 08 Production | — | BOM, production orders |
| 09 Service | — | Service calls, contracts |
| 10 Human Resources | Employees (HR only) | Staff portal, attendance, leave, payroll + WPS |
| 11 Reports | — (Control Tower is under Oversight) | Report library, saved reports, Ask AI for a Report |
