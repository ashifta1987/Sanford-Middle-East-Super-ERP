# Sanford Middle East · Super ERP

Group ERP for the 12 Sanford companies (AE01 Sanford Middle East DWC is the parent).
React 18 + TypeScript + Vite · Supabase (Postgres, Auth, Storage, Realtime) · Vercel.

First job: the **SAP Migration Console** — upload one company's SAP HANA backup, rebuild it, cross-check every total
against SAP, then Finance, IT and the CFO sign off before go-live. See `prompts/P0-context.md`.

## Run locally
```bash
cp .env.example .env.local   # fill in the publishable key
npm install
npm run dev
```

## Layout
| Path | What |
|---|---|
| `src/` | Web app (`features/migration` = console) |
| `supabase/sql/` | DB scripts. `10`–`13` are delivered (don't edit); `14_*` are this repo's additions |
| `supabase/worker/` | Migration worker (runs on its own server, never on Vercel) |
| `design/` | Target screens B5–B8 |
| `prompts/` | Build phases P0–P6 |
| `docs/` | Setup, worker deploy, acceptance |

## Build phases
| Phase | Status |
|---|---|
| P1 Supabase setup (`14_realtime.sql`, `14_console_views.sql`, storage) | Written — waiting for DB install to run |
| P2 App shell, routing, data layer, i18n (EN/AR) | Done |
| P3 B6 Upload backup (TUS resumable, folder/zip, structure check) | Done — needs DB to test end to end |
| P4 B7 Rebuild run (live steps, log, stop, earlier runs) | Done — needs DB + worker to test live |
| P5 B8 Cross-check and sign-off (areas, finance + SAP report figures, stock, issues, sign-off, go-live, PDF/Excel) | Done — needs DB to test end to end |
| P6 B5 Migration centre, worker deploy, acceptance | Next |

> Only `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` go to the browser / Vercel. The secret key lives only on the worker server.

