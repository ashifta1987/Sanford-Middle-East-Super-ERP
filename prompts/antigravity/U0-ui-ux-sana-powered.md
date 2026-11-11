# U0 · Southfield UI/UX, Sana-powered (design system and screens)

Paste `A0-context.md` first, then this file. It is also the standing design brief for **every** later phase: each new screen must pass the checklist at the end.

## Goal
One consistent, Sana-powered interface for the whole ERP:
- the Southfield brand
- the navy shell
- **SANA** visible as the assistant everywhere (top bar, home page, phone button, "Ask Sana about this" on records)
- one pattern each for lists, details and document forms
- English and Arabic, light and dark, desktop and phone

The full reference is `docs/ui-ux-spec.md`; screenshots are in `design/reference/`; brand files are in `design/brand/`.

**Step 0 (audit before changing):** open every route in the browser at 1440 and 390 px, light and dark, English and Arabic. List every place that does not match this brief, in the Implementation Plan, with a screenshot each. Then fix those places. Don't redesign what already matches.

## 1. Brand
- **Product:** **Southfield · AI-Powered ERP** for the Sanford Middle East DWC Group. The assistant is **SANA**, the Southfield AI Neural Assistant.
- **Logos (vectors, never redraw, recolour or stretch):**
  - Southfield: `src/brand/Logo.tsx`, with `<LogoMark/>` and `<Logo size tone/>`. The wordmark "Southfield" in Outfit 700 over "AI-POWERED ERP" in teal.
  - Sana: `src/features/sana/SanaMark.tsx`, with `<SanaMark/>` and `<PoweredBySana/>`.
  - Source files: `design/brand/*.svg`.
- Brand names stay in Latin letters in Arabic.
- **Brand colours** are for logo, panels, charts and the hero, never for status:
  - blue #226AD9
  - navy text #012746
  - sidebar navy #011C45
  - teal #08BBA9
  - yellow #F7B646
  - coral #F4745B
  - The Sana mark uses its own #004ED6 / #FCB001 / #029A96 / #FB5B44.
- **Type:**
  - **Outfit** (600–700) for the wordmark, page titles and hero headings (`font-display`)
  - **IBM Plex Sans** for everything else, **IBM Plex Sans Arabic** for Arabic, **IBM Plex Mono** for codes
  - tabular numbers everywhere

## 2. Tokens (only through Tailwind names backed by the CSS variables in `src/index.css`; never hard-code colours in components)
| Token | Light | Dark |
|---|---|---|
| page | #F6F7FB | #070F1F |
| surface / surface-2 | #FFFFFF / #F8FAFC | #0E1A2E / #13223A |
| line / line-strong | #E3E8EF / #CBD3E1 | #1F3150 / #2B4166 |
| ink / ink-2 / muted | #012746 / #3E5573 / #5F6F86 | #EEF3FA / #BCC8DA / #8D9BB3 |
| primary / hover | #226AD9 / #1B56B3 | #2F76E8 / #5491F0 |
| primary-soft / primary-text / primary-line | #EAF2FF / #1A4FA8 / #BFD5F7 | #0F2A55 / #A9C8FF / #24467F |
| side / side-text / side-muted / side-active | #011C45 / #C7D2E5 / #7E8FAD / #123875 | #040C1B / #BCC8DA / #70809C / #10295A |
| ok · warn · crit · info · neutral (bg/fg) | #ECFDF3/#067647 · #FFFAEB/#B54708 · #FEF3F2/#B42318 · #EAF2FF/#1A4FA8 · #F1F4F8/#344054 | dark equivalents in `index.css` |

- **Radius:** cards 16 px, buttons and inputs 10 px, sign-in fields 12 px, hero 20 px, bubbles 18 px, pills full.
- **Spacing:** 4 px grid. Card padding 20 px. Page gutter 28 px (desktop) and 16 px (phone). Content max width 1280 px.
- **Shadow:** a soft 1 px shadow in light mode, none in dark. The phone Sana button has a soft drop shadow.
- **Motion:** 150–200 ms ease for hover and panel open. Typing dots and the microphone pulse only when the user hasn't asked for reduced motion.

## 3. Shell
- **Sidebar (248 px, navy, sticky; a drawer on phones):**
  - Southfield logo, linking Home
  - Home
  - **Modules** 01–11 in SAP order: Administration, Financials, Sales, Purchasing, Business Partners, Banking, Inventory, Production, Service, Human Resources, Reports. Each with an icon and number, and only those the position allows.
  - **Oversight:** Control Tower, Approvals
  - the user card
  - The active item has a lighter navy fill and a 3 px teal marker at the start edge.
- **Top bar:**
  - company switcher (code chip + legal name; "GRP" = all companies)
  - global search (Ctrl/⌘ K)
  - **Ask Sana** button (Sana mark + label, primary-soft, Ctrl/⌘ J)
  - Approvals bell
  - theme, language EN · ع
  - password, sign out
- **Phone:** the Ask Sana button is replaced by a floating round Sana button (bottom end corner, 56 px).
- **Breadcrumb** on every inner page: Home › NN Module › Screen › Record.

## 4. Key screens

### 4.1 Sign-in (`/login`, `/reset-password`), already built: match `design/brand/login-reference.png`
- **Left (45 %, desktop only):** the navy panel with brand ribbons, the headline "Your business, in motion." with a teal underline, and a glass dashboard card.
- **Right (warm #FCF8F5):**
  - the large logo
  - "Welcome back" / "Sign in to your workspace"
  - Work email (mail icon), Password (lock + show/hide eye)
  - **Remember me** (unticked = session ends when the browser closes)
  - **Forgot password?** → reset link → `/reset-password`
  - full-width **Sign in →** (#0A47F0, 56 px)
  - EN · ع toggle
- **Errors:** plain messages in English and Arabic.

### 4.2 Home, Sana-powered (`/`)
1. **Hero** (navy, 20 px radius, soft brand ribbons on the end side, mirrored in RTL):
   - "POWERED BY [Sana mark] SANA"
   - a time-based greeting ("Good evening, Ashif", Outfit 700, 40 px desktop / 30 px phone)
   - one lead line
   - a white **Ask Sana** box with the Sana mark, input, microphone (coral while listening, live transcript under it) and send
   - 3–4 suggestion chips **for the user's role** (glass pills)
2. **Needs attention** card inside the hero (glass): the top 3 rule findings the role may see, each with a severity dot, rule · subject and detail; the label "Control Tower rules"; a link "Open Control Tower (n)"; and an "Ask Sana" button. "Nothing needs your attention right now" when empty. **These are rule results, not AI, and must be labelled so.**
3. **Today at a glance:** KPI cards (only for the user's modules), each linking to its filtered list. A red number for overdue, amber for stock below minimum.
4. **Modules:** a card each with icon, number, title, description, and "n SAP functions · m with working screens".

On phones everything stacks in one column, with no horizontal scroll.

### 4.3 Sana panel (`docs/ui-ux-spec.md` §4.9, `docs/sana-assistant.md`)
- **Layout:** 440 px side panel over a dimmed page (desktop); full-screen sheet (phone). A focus-trapped dialog; Esc closes it.
- **Header (navy):** Sana mark, "SANA" (Outfit 700) and "Southfield AI Neural Assistant", answer-language select (Auto + 11 languages), read-aloud toggle, History, New conversation, Close.
- **Empty state:** large mark, "Hi ‹name›, how can I help?", one line about role limits, up to 4 role suggestions as full-width cards.
- **Messages:**
  - user on the end side (primary blue bubble; a microphone icon when asked by voice)
  - Sana on the start side (white card with border, source chips as primary-soft pills linking to records, Listen / Stop, 👍/👎)
  - refusal: grey card with a lock and the standard sentence
  - error: red card
  - waiting: three dots; streaming: text grows in place
- **Composer:** auto-growing text box, 48 px round microphone and send buttons, and the privacy line with a teal shield: "Sana answers only from data your role can see, never shares other people's information, and cannot change anything. Conversations are kept for audit."
- **Basic mode:** an amber note when no AI model is connected.

### 4.4 Lists, details, document forms
- **Lists:** one `ListScreen` component with:
  - server search (300 ms debounce), filter drop-downs, sortable headers, paging (25), CSV export
  - "n results", "Clear search and filters"
  - state kept in the URL
  - first column links; whole row clickable
  - numbers end-aligned, codes in mono, status pills
  - columns hidden by priority on small screens
- **Details:** title `code · name` + status pill + **Live data** pill, then cards: General (label/value grid), related tables. Always show the record's Source (SAP Business One / Southfield / Sample test data). Add **"Ask Sana about this"** (secondary button with the Sana mark) on document, customer/supplier and item pages.
- **Document form:** the sales order pattern:
  - header row (back link, title, status, Print / PDF, Copy to …)
  - document flow strip
  - six header fields
  - lines table (item with code · stock under it; Qty, Price, Disc. pill, Line total)
  - rule warnings on lines (amber row with a "Check" note)
  - totals block
  - aside: approval card (Approve / Approve at n % / Reject with note), activity timeline, Ask Sana about this order

### 4.5 Other patterns
- **Control Tower:** check cards with counts, severity chips, findings linking to records.
- **Design preview pages:** an amber banner "Design preview — not connected…". Tables without data say "No sample values. Filled from your SAP during migration."
- **States:**
  - skeleton rows while loading
  - empty: icon + title + one helpful sentence
  - error: message + Try again
  - no access: lock + "Your position does not include ‹module›"
  - a disabled action always says why ("Stage 2", "Read-only access")

## 5. Language, direction, accessibility
- **Text:** every word in `src/lib/i18n/en.json` and `ar.json`.
- **RTL:** logical CSS only (`ms-`, `me-`, `ps-`, `start-`, `end-`, `rtl:rotate-180` on arrows). SAP function names, codes and English data in `dir="auto"`. Western digits; dates formatted `ar-AE` in Arabic.
- **Accessibility:**
  - real buttons, links and labels
  - `aria-live` for result counts, Sana messages and the transcript
  - visible 2 px focus ring
  - contrast at least 4.5:1 in both themes
  - targets of at least 40 px (44 px for primary actions)
  - a skip link
- **Words:** SAP names for functions and documents; plain short sentences elsewhere. Buttons name the action. Amounts show their currency. Never "successfully". Refusals and errors say what to do next.

## 6. Checklist for every screen (put the answers in the Walkthrough)
1. Uses only tokens, shared components and the patterns above. No new colours, fonts or one-off cards.
2. Works at 390 and 1440 px (no horizontal page scroll), in light and dark, in English and Arabic.
3. Live data is marked **Live data**. Anything not connected is a **Design preview** with the amber banner.
4. Every action works or is disabled with a reason. Every error is understandable and actionable.
5. Sana can be opened from the screen. If the screen shows a record, "Ask Sana about this" is present (S1 adds the context).
6. Keyboard only: you can reach and use everything. Screen reader: headings, labels and live regions make sense.
7. Screenshots attached: 1440 light EN, 1440 dark EN, 1440 light AR, 390 light EN.

## Done when
The audit list from Step 0 is empty, all checklist items pass on every existing route, `npm run typecheck` and `npm run build` pass, the Playwright suite passes, and `design/reference/` is refreshed with the new screenshots.
