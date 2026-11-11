# A0 · Context. Read this first, before every phase.

You are working in the **Southfield** repository (product name: **Southfield · AI-Powered ERP**; repo name `sanford-middle-east-super-erp`). Read this file fully, then the phase prompt that follows it. Before writing any code, produce an **Implementation Plan** artifact and wait for my approval.

## Product
Southfield (formerly "Super ERP") replaces SAP Business One for the Sanford Middle East DWC Group:
- AE01 Sanford Middle East DWC L.L.C (parent)
- AE02 A.T.M.M. Electronics
- AE03 Abdulla Mohamed Home Appliances
- AE04 Izaan General Trading
- more group companies later

The menus mirror SAP Business One: 11 modules with the same functions in the same order, so staff feel at home. During the **soft switch**, SAP stays live. Its data is copied into Supabase: schema `sap` holds the raw copy, and schema `erp` is the readable app layer, filled by `erp.sync_company`. SAP rows have `source = 'sap'` and are read-only in the app. Documents created in Southfield get `source = 'erp'` and their own number range, and are **not** sent back to SAP.

## Stack (fixed: don't add frameworks)
- React 18, TypeScript, Vite, React Router 6, TanStack Query 5, Tailwind CSS 3, i18next (en, ar), lucide-react
- Supabase: Postgres 17, Auth, Row-Level Security, Storage, Realtime, `@supabase/supabase-js` v2
- Vercel hosts the web app. The Python worker (`supabase/worker/`) runs on its own server for SAP loads.
- Tests:
  - SQL test scripts in `supabase/tests/`
  - Playwright browser tests, in the style of `scripts/local-stack/stage1-e2e.mjs`
  - `npm run typecheck` and `npm run build` must pass

## Repo map
| Path | What it is |
|---|---|
| `docs/ui-ux-spec.md` | **The UI/UX specification. Follow it exactly.** Brand (Southfield logo, colours, Outfit + IBM Plex), tokens, sign-in page, shell, list/detail/document-form patterns, states, RTL, accessibility, words, error messages |
| `src/brand/Logo.tsx`, `design/brand/` | The Southfield logo (vector) and brand files. Use `<Logo/>` / `<LogoMark/>`; never redraw it |
| `design/reference/*.png` | Screenshots of the built Stage 1 screens (look and feel to match) |
| `docs/design-inventory.md` | Screens, roles, workflows, gaps, decisions (including the 9 Nov answers) |
| `docs/implementation-plan.md`, `docs/stage-1.md` | What is built and what comes next |
| `docs/sap-migration-plan.md` | Migration plan (data inventory, mapping, import process, reconciliation) |
| `src/features/erp/modules.ts` | The 11 modules, their SAP functions, and the function → working-screen routes. **Update `LIVE_FUNCTIONS` / `LIVE_ITEMS` when a screen becomes real.** |
| `src/features/erp/design-data.json` | The canvas content (menus, sub-screens). Don't hand-edit; it is extracted from the design |
| `src/features/erp/components/ListScreen.tsx`, `ui.tsx`, `Guard.tsx` | List pattern, shared UI pieces, module guard. Reuse them; don't make new versions |
| `src/features/erp/pages/*` | Stage 1 pages (lists, details, home, Control Tower, previews, search) |
| `src/features/migration/*` | SAP migration console (working; don't restyle or rewrite) |
| `src/layout/*`, `src/theme/*`, `src/index.css`, `tailwind.config.js` | Shell (navy sidebar) and design tokens |
| `src/features/sana/*`, `supabase/functions/sana/*`, `supabase/sql/15_sana.sql`, `docs/sana-assistant.md` | **Sana**, the AI voice and text assistant (built: role-limited tools, Edge Function, panel, voice, home hero). Any new module that Sana should answer about needs a new read-only `erp.sana_*` tool with the same role checks |
| `src/auth/LoginPage.tsx` | Sign-in, forgot password, reset password, remember me (built; reuse its `authError()` for auth messages) |
| `src/lib/supabase.ts` | `erp()` = `supabase.schema('erp')`. Every call goes through it |
| `src/lib/i18n/en.json`, `ar.json` | All UI words. Add keys to **both** files |
| `supabase/sql/10`–`15_*.sql` | Existing schema, sync, security, console, Stage 1. **Never edit these** |
| `supabase/sql/15_sample_company.sql` | Fictional test company **ZZ99** (sanitized sample data) |
| `scripts/local-stack/` | Local Postgres + PostgREST + auth gateway for tests without Supabase, plus test users |

## Hard rules
1. **New SQL goes in new files only:** `supabase/sql/16_<topic>.sql`, `17_…`, one per phase. Every file must be safe to run twice.
2. **Writes go only through `SECURITY DEFINER` functions** in schema `erp`. Each function must:
   - set `search_path = erp, pg_temp`
   - check the user (`erp.current_user_id()`), the company (`erp.can_see`) and the module (`erp.has_module`, or the A1 helpers once they exist)
   - validate everything
   - write `erp.audit_log`

   Tables get **no** direct INSERT/UPDATE/DELETE grants for `authenticated`.
3. **Never write to SAP rows** (`source = 'sap'`). Never query or expose schema `sap` from the browser. Supabase exposes `erp` only.
4. **Keys:** the browser holds only the anon (publishable) key and the user's session. The service role key never appears in frontend code, `.env` files committed to git, or Vercel `VITE_*` variables.
5. **Data:** use sample company ZZ99 for development. Never import or touch production data or the live SAP system. If a task seems to need that, stop and ask me.
6. **Posted journals are permanent** (database trigger). Corrections are reversals.
7. **Real or labelled:** a screen counts as done only when it reads and writes real data through the rules above. Anything else stays a **Design preview** with the amber banner. Never present sample content as working.
8. **No invented business rules.** If a limit, account or rate isn't in the repo or the phase prompt, put it in a settings table, leave it empty, and list it under "Needs from Ashif" in the Walkthrough.

## Error handling (same everywhere)
- Raise errors in SQL with `RAISE EXCEPTION '<plain sentence the user can act on>' USING ERRCODE = 'P0001', HINT = '<optional next step>'`.
- In the UI, show the message next to the field or at the top of the form.
- `42501` → "You don't have access to this."
- `23505` → "This already exists: …"
- Network errors → "We couldn't reach the server. Check your connection and try again. Nothing was saved."
- Use `errorMessage()` from `src/lib/format.ts`.

## Users for tests (local stack, sample company only)
`qa.admin@sample.test` (all modules), `qa.sales@sample.test` (sales only), `qa.nobody@sample.test` (no profile). Add the positions and users a phase needs to `scripts/local-stack/test-users.sql` and `users.json`, for example a sales manager approver. Never add real people.

## How to work
1. Make an Implementation Plan artifact covering:
   - the SQL objects and functions with their checks
   - the routes and components
   - the tests
   - the open questions

   Wait for approval.
2. Build the SQL first, with a test script in `supabase/tests/<phase>.sql` that proves every rule: allowed, refused, and the error message.
3. Build the UI using the existing patterns. Add i18n keys in English and Arabic.
4. Update `src/features/erp/modules.ts` so the module page shows the new screens as **Live data**.
5. Run `npm run typecheck`, `npm run build`, the SQL tests and the Playwright tests.
6. Use the browser agent to take screenshots at 1440 px and 390 px, light and dark, English and Arabic.
7. Write a **Walkthrough** artifact with:
   - what you built
   - how to run it
   - what you tested (pass/fail counts)
   - screenshots
   - what is left
   - "Needs from Ashif"
8. Make small commits on a branch named after the phase (`a2-sales-order`). Don't push to `main`.
