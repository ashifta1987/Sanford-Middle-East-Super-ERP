# Building Southfield (AI-Powered ERP) with Google Antigravity

This folder holds the prompts that build the rest of the ERP, one phase at a time, on top of this repo. The stack is React + TypeScript + Vite, with Supabase and Vercel.

## Before you start (one time)
1. **Get Stage 1 into GitHub.** The branch `stage-1-erp-shell` must be on GitHub, merged into `main`, before Antigravity opens the repo.
2. **Open the repo in Antigravity.** Clone `sanford-middle-east-super-erp` and open the folder (File › Open Folder).
3. **Install and test.** Run `npm install`, then `npm run typecheck`, then `npm run build`.
4. **Point the app at Supabase.** Copy `.env.example` to `.env.local` and fill in `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (the publishable key only, never the service role key).
5. **Use a Supabase branch or a separate test project for development,** never the live project. Apply `supabase/sql/15_stage1_overview.sql`, `15_sample_company.sql`, then each new `16_*`, `17_*` … file that a phase creates.
6. **Agent settings:**
   - Use **Planning** mode, not Fast.
   - Set the review policy to **"Request review"**, so you approve each implementation plan before code is written.
   - Turn terminal auto-execution off, or allow only `npm`, `npx`, `git status/diff/add/commit`.
   - Never let the agent run SQL against the live Supabase project.

## How to run a phase
1. Start a new Agent Manager conversation for each phase.
2. Either paste **`A0-context.md` first, then the phase file** (for example `A2-sales-order-approval.md`) in the same message. For phases with screens, add `U0-ui-ux-sana-powered.md` too. Or type:
   `Read prompts/antigravity/A0-context.md and prompts/antigravity/A2-sales-order-approval.md, then follow them. Start with the Implementation Plan.`
3. The agent writes an **Implementation Plan** artifact. Read it, comment on anything wrong, then approve.
4. When it finishes, check its **Walkthrough** artifact for:
   - screenshots at 1440 px and 390 px, light and dark, English and Arabic
   - the test results
   - the list of what it couldn't do
5. Open a pull request, review, merge. Then start the next phase.

## Suggested order
U0 (design audit) → A1 (security) → S1 (Sana, can run any time after A1) → A2 … A14. Each module phase that adds data also adds a read-only Sana tool for it (see S1 › role matrix).

## Phase order
| File | Phase | Writes data? |
|---|---|---|
| A0-context.md | Read first, every time | — |
| **U0-ui-ux-sana-powered.md** | **Design brief: Southfield brand, navy shell, sign-in, Sana-powered home, Sana panel, list/detail/form patterns. Run once as an audit and fix pass, then keep it open as the checklist for every phase** | No |
| **S1-sana-assistant.md** | **SANA, the AI voice and text assistant:** verify what is built, connect the AI model (streaming), "Ask Sana about this", history and feedback, voice in 11 languages, admin settings, evaluation set with injection tests | Logs and settings only |
| A1-security-module-access.md | Module-level read rules; Full / Read / None per position | Policies only |
| A2-sales-order-approval.md | **First complete workflow:** sales order with approval | Yes |
| A3-posting-engine.md | Journal posting from documents, G/L determination, VAT, period lock | Yes |
| A4-sales-cycle.md | Quotation → order → delivery → A/R invoice → credit memo, ATP | Yes |
| A5-banking.md | Incoming and outgoing payments, approvals, reconciliation | Yes |
| A6-purchasing-china.md | Request → PO → PI and deposit → QC → shipment → GRPO → A/P invoice and landed costs | Yes |
| A7-inventory.md | Transfers, goods receipt/issue, counting, batches/serials, bins | Yes |
| A8-master-data.md | Business partners and items: create/edit with approval | Yes |
| A9-hr-staff-portal.md | Staff portal, attendance, leave, payroll and WPS | Yes |
| A10-administration.md | Users, positions, authorizations, approval templates, numbering, Add-Ons › AI Assistant | Yes |
| A11-reports-control-ai.md | Report library, Control Tower rules, AI assistant | Read only + AI |
| A12-migration-completion.md | Finishes the SAP migration tools (see `docs/sap-migration-plan.md`) | Test data only |
| A13-production-service.md | BOM, production orders, service calls and contracts | Yes |
| A14-deploy-go-live.md | Vercel production, monitoring, go-live checklist per company | — |

## Things only you can provide (the agent will stop and ask)
- Real approval limits per position: discount %, credit, PO amount, payment amount.
- The list of real users, their positions and companies.
- The go-live date for each company.
- A **sanitized** SAP backup for test runs: names, phones, emails, TRNs and bank details replaced, amounts kept.
- The AI provider and model for Sana (chat and voice), with its API key stored as a Supabase secret. Sana already works in basic mode without it.
- Any SAP report layouts (invoices, delivery notes) to match for printing.
