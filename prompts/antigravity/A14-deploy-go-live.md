# A14 · Deploy and go-live

## Vercel
- **Projects:** a production project linked to `main`, and preview deployments for every pull request.
- **Environment variables:** only `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (Production → live Supabase, Preview → the Supabase branch or test project). Fail the build if a variable named like `SERVICE_ROLE` appears in any `VITE_*`.
- **Routing:** `vercel.json` with an SPA rewrite to `/index.html`, and security headers: CSP limited to self + the Supabase URL, `X-Frame-Options DENY`, `Referrer-Policy strict-origin-when-cross-origin`.
- **Bundle:** split the PDF and Excel libraries out of the main bundle (the main chunk is 927 kB today).

## Supabase
- Apply SQL files in order to a **branch** first, run every `supabase/tests/*.sql`, then apply to live. Keep a log of which file went live, when and by whom.
- **Auth:** email sign-in, invite-only, password rules, MFA for admin and finance positions.
- **Backups:** point-in-time recovery on; check that a restore actually works.
- Run the Supabase security and performance advisors; fix every error.

## Go-live per company (checklist screen in Administration)
1. Migration run signed off by Finance, IT and Business (console).
2. **Ashif's written approval** to import production data for this company.
3. Users invited, positions and limits set, and test sign-in done by each department head.
4. Opening balances reconciled (plan §5).
5. SAP posting frozen. Final backup → final run → reconcile → sign.
6. Record the go-live date (`company_cutover`). The SAP sync stops for that company, and ERP documents become the source of truth.
7. Hypercare for 2 weeks: daily reconciliation report, issue list, and a fast path for fixes.

## Done when
The production URL works for a pilot company, the advisors are clean, the checklist is complete, and a rollback plan is written.
