# Southfield · AI-Powered ERP · UI/UX specification

The single reference for how every screen looks and behaves. **Product name: Southfield** (tagline "AI-Powered ERP"), built for the Sanford Middle East DWC Group. It follows the canvas design ("Super ERP UI/UX Structure", 11 modules matched to SAP Business One) and the Stage 1 code, which already implements most of it. Reference screenshots: `design/reference/*.png`. Brand files: `design/brand/` (logo mark SVG, the original logo, the sign-in reference image).

When this document and a screenshot disagree, this document wins. When the code and this document disagree, fix the code.

---

## 1. Principles
1. **SAP-familiar, simpler.** The menus, function names and their order match SAP Business One, so staff find things where they expect them. Each screen still shows one job, in plain words.
2. **Real or clearly labelled.** A screen is either connected to data and marked **Live data**, or it is a **Design preview** under an amber banner. Never show sample numbers as if they were real.
3. **Every rule is visible.** If something blocks an action (an approval, a credit limit, a closed period), the screen names the rule, who can lift it, and what to do next.
4. **Same pattern everywhere.** One list pattern, one detail pattern and one document form pattern, shared by all modules.
5. **English and Arabic, light and dark, desktop and phone,** all from the first build of each screen.

## 2. Brand and design tokens
**Logo.** `src/brand/Logo.tsx`: `<LogoMark/>` is the vector mark (blue, yellow, teal and coral rounded square with the white turn arrow); `<Logo size tone/>` is the mark plus the live-text wordmark "Southfield" (Outfit 700) over "AI-POWERED ERP" (Outfit 600, letter-spaced, teal). Never stretch, recolour or re-draw the mark. Keep clear space equal to a quarter of the mark's width. The wordmark stays in Latin letters in Arabic. Favicon: `public/favicon.svg`; iOS icon `public/apple-touch-icon.png`.

**Brand colours** (logo only, sign-in panel, charts; never for status):
| Name | Hex | Tailwind |
|---|---|---|
| Southfield blue | #226AD9 | `brand-blue` (also `primary`) |
| Navy (text) | #012746 | `ink` |
| Sidebar navy | #011C45 | `brand-navy`, `side` |
| Teal | #08BBA9 | `brand-teal` |
| Yellow | #F7B646 | `brand-yellow` |
| Coral | #F4745B | `brand-coral` |

**Interface tokens.** They are defined once as CSS variables in `src/index.css` and used through Tailwind names (`tailwind.config.js`). Never hard-code a colour.

| Token (Tailwind) | Light | Dark | Use |
|---|---|---|---|
| `page` | #F6F7FB | #070F1F | App background |
| `surface` / `surface-2` | #FFFFFF / #F8FAFC | #0E1A2E / #13223A | Cards, top bar, inputs / table headers, hover rows |
| `line` / `line-strong` | #E3E8EF / #CBD3E1 | #1F3150 / #2B4166 | Borders / input borders |
| `ink` / `ink-2` / `muted` | #012746 / #3E5573 / #5F6F86 | #EEF3FA / #BCC8DA / #8D9BB3 | Text, secondary text, labels |
| `primary` | #226AD9 | #2F76E8 | Primary buttons, links, focus |
| `primary-soft` / `primary-text` / `primary-line` | #EAF2FF / #1A4FA8 / #BFD5F7 | #0F2A55 / #A9C8FF / #24467F | Selected items, AI notes |
| `side` / `side-text` / `side-muted` | #011C45 / #C7D2E5 / #7E8FAD | #040C1B / #BCC8DA / #70809C | Navy sidebar, its text and section labels |
| `side-hover` / `side-active` / `side-line` | #0C2856 / #123875 / #14305E | #0C1C36 / #10295A / #142440 | Sidebar hover, selected item (+ 3 px teal marker at the start), divider |
| `ok` bg/fg | #ECFDF3 / #067647 | #0A2A1C / #75E0A7 | Approved, posted, active, live |
| `warn` bg/fg | #FFFAEB / #B54708 | #2E1F06 / #FEC84B | Waiting, below minimum, preview banner |
| `crit` bg/fg | #FEF3F2 / #B42318 | #2D1212 / #FDA29B | Blocked, cancelled, errors |
| `info` bg/fg | #EAF2FF / #1A4FA8 | #0F2A55 / #A9C8FF | Open, in progress |
| `neutral` bg/fg | #F1F4F8 / #344054 | #1A263C / #D0D5DD | Closed, planned, off |

- **Type:**
  - **Outfit** (600–700) for the wordmark, page titles (`h1`) and the sign-in headings: Tailwind `font-display`.
  - IBM Plex Sans for everything else, and IBM Plex Sans Arabic for Arabic (Outfit has no Arabic letters, so Arabic headings fall back to Plex Arabic automatically).
  - IBM Plex Mono for codes.
  - Tabular numbers everywhere.
- **Sizes:** page title 28 px / 600 (26 px on phones); section title 15 px / 600; body 15 px; table 14 px; labels and pills 12–13 px.
- **Radius:** cards 16 px, buttons and inputs 10 px (12 px on the sign-in page), pills fully round.
- **Shadow:** a 1 px soft navy shadow in light mode, none in dark.
- **Spacing:** 4 px grid. Card padding 20 px, gaps 20 px. Page gutter 28 px on desktop and 16 px on phones. Max content width 1280 px.
- **Icons:** module icons in `src/features/erp/icons.tsx`, `lucide-react` elsewhere, 18 px, stroke 1.8. No emoji.

### 2.1 Sign-in page (`/login`, `/reset-password`): `src/auth/LoginPage.tsx`
Built from the sign-in reference image (`design/brand/login-reference.png`).
- **Layout:** two columns on desktop. Left (45 %) is the navy brand panel: logo-colour ribbons, the headline "Your business, in motion." (Outfit 700, white) with a teal underline, and a glass dashboard card. The panel is decorative only (`aria-hidden`) and is hidden on phones. Right (55 %) has a warm off-white background (#FCF8F5; `page` in dark mode).
- **Form contents:** the large logo, "Welcome back" / "Sign in to your workspace", then:
  - **Work email** (mail icon) and **Password** (lock icon, show/hide eye button)
  - **Remember me** (unticked by default: ticked keeps the session in localStorage, unticked in sessionStorage, so it ends when the browser closes)
  - **Forgot password?**
  - a full-width **Sign in →** button (#0A47F0, 56 px)
  - the language toggle at the top
- **Forgot password:** the same page switches to "Reset your password", which sends a Supabase reset link to `/reset-password`. It always says "Check your email" and never reveals whether an account exists. `/reset-password` sets a new password (at least 10 characters, typed twice) or says "This link has expired".
- **Errors** are in plain words, in English and Arabic: wrong email or password, too many attempts, email not confirmed, no connection, plus field checks.

## 3. App shell
- **Sidebar (248 px, sticky, navy `side`):**
  - Southfield logo (`<Logo size="sm" tone="light"/>`, links Home)
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

### 4.9 Sana assistant and the Sana-powered home page
The full design is in `docs/sana-assistant.md`.
- **Sana logo:** `src/features/sana/SanaMark.tsx` (vector). "Powered by SANA" badge: `PoweredBySana`. The name is written **SANA** in Outfit 700, with "Southfield AI Neural Assistant" under it.
- **Ways to open it:** top-bar button "Ask Sana" (Sana mark + text, primary-soft), Ctrl/⌘ J, the floating round Sana button on phones, the home page box and suggestion chips.
- **Panel:** desktop is a 440 px side panel with a dimmed page; phones get a full-screen sheet. Esc closes it.
  - **Header:** navy `brand-navy`, mark, SANA / full name, answer-language select, read-aloud toggle, new conversation, close.
  - **Messages:** user bubbles on the end side (primary, 18 px radius). Sana cards on the start side (surface, border), with source chips (primary-soft pills linking to records) and a Listen button. Refusals are neutral grey with a lock icon. Errors are `crit`. A three-dot typing indicator shows while waiting.
  - **Empty state:** large mark, "Hi {name}, how can I help?", one line on role limits, up to four suggestions for the user's modules.
  - **Composer:** auto-growing text box, 48 px round microphone (coral while listening, with a live transcript and pulsing dot), 48 px round send button, and the privacy line with a teal shield.
  - **Basic mode:** an amber note when no AI model is connected.
- **Home page hero** (`src/features/sana/SanaHero.tsx`): a navy card with soft brand ribbons.
  - **Left:** "Powered by SANA", a time-based greeting (Outfit 700), one lead line, a white Ask Sana box with mark, microphone and send, and suggestion chips (glass pills).
  - **Right:** the **Needs attention** glass card, showing the top 3 rule findings the role may see, a "Control Tower rules" label, a link to the Control Tower with the count, and an "Ask Sana" button.

  Below the hero come "Today at a glance" (KPI cards), then the modules. On phones everything stacks, with no horizontal scroll.

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
The home page is Sana-powered. See §4.9, with the hero, Needs attention, Today at a glance and Modules.

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
