# Sanford Super ERP · Migration Console · Antigravity pack

This pack is about 3 MB, small enough for Antigravity. The large database scripts (about 16 MB) are in a separate package, `sanford-db-install.zip`. IT installs that on Supabase and on the worker server. Antigravity never needs it.

## How to use
1. Unzip this folder into your repo root, or open it as the Antigravity workspace.
2. Give Antigravity **one phase at a time**. Paste only the short message for that phase. Antigravity reads the details from the files itself, so don't attach the PDF or the zip.

| Phase | Paste this into Antigravity |
|---|---|
| 1 | `Read prompts/P0-context.md and prompts/P1-supabase-setup.md, then do phase P1. Stop when its "Done when" passes and show me the results.` |
| 2 | `Read prompts/P0-context.md and prompts/P2-app-shell.md, then do phase P2. Show screenshots at 1440 px and 390 px.` |
| 3 | `Read prompts/P0-context.md and prompts/P3-upload-screen.md and look at design/B6-upload-backup.jpg, then build B6.` |
| 4 | `Read prompts/P0-context.md and prompts/P4-run-screen.md and look at design/B7-rebuild-run.jpg, then build B7.` |
| 5 | `Read prompts/P0-context.md and prompts/P5-crosscheck-screen.md and look at design/B8-cross-check-signoff.jpg, then build B8.` |
| 6 | `Read prompts/P0-context.md and prompts/P6-centre-deploy-tests.md and look at design/B5-migration-centre.jpg, then build B5, the worker deploy files and run the final acceptance list.` |

3. After each phase, check the screenshots against `design/`, then move to the next phase.

## What's inside
- `prompts/`: P0 (context, read every time) and P1–P6 (one phase each).
- `design/`: the four screens at 1440 px (B5 centre, B6 upload, B7 rebuild run, B8 cross-check and sign-off).
- `supabase/sql/`: README (API contract), 05 (HANA export script), 10–13 (app schema, sync, security, migration console).
- `supabase/worker/`: migration worker and loader.
- `supabase/tests/`: test exports (`testexp` good, `broken` bad) and the backend test scripts with their passing results.

## Before phase 1 (IT, once)
Install the database from `sanford-db-install.zip` on Supabase, following its README run order 00 → 13. Copy that folder to the worker server too.
