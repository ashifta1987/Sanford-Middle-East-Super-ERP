# P2 · App shell and data layer (read P0 first)

If the ERP app already exists in this repo, add to it and reuse its layout, sidebar and top bar. If it doesn't, create a Vite + React + TS app with this layout.

## Layout
- Left sidebar, 240 px. The Back office item is active.
- Top bar with the company switcher.
- Module tabs: Requests · Licences and contracts · IT and equipment · System admin · **SAP migration · Upload backup · Rebuild run · Cross-check** (see the tab row in `design/B6-upload-backup.jpg`).
- Content column up to 1180 px wide, padding 24/28.

## Routes
- `/backoffice/migration` → B5 Migration centre
- `/backoffice/migration/upload?company=AE01` → B6 Upload backup
- `/backoffice/migration/runs/:runId` → B7 Rebuild run
- `/backoffice/migration/runs/:runId/check` → B8 Cross-check and sign-off

Guard every route by role (P0 › Who sees what). Signers get B8 only.

## Files
```
src/lib/supabase.ts           createClient(VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY)
src/lib/database.types.ts     generated in P1
src/lib/i18n/en.json, ar.json every label, no hard-coded strings
src/features/migration/
  api.ts                      one typed function per RPC in P0, errors mapped
  queries.ts                  TanStack Query hooks: useOverview, useRun, useStatus, useReview, mutations
  useRunRealtime.ts           channel on migration_run/_step/_check/_issue filtered by run_id → invalidate queries;
                              if the channel errors or closes, poll migration_status every 5 s
  components/StatusPill.tsx   ok | warning | critical | info | neutral + run-status mapping
  components/KeyNumber.tsx    label, value, note, tone
  components/StepTracker.tsx  6 steps: Upload, Check files, Load SAP copy, Rebuild app tables, Cross-check, Sign-off
  components/Card.tsx, DataTable.tsx (scrolls inside its box), ConfirmDialog.tsx (no window.confirm)
```

## Done when
- `npm run build` passes and the routes render with loading and empty states.
- Arabic flips the layout.
- A non-admin is redirected with a "No access" page.
