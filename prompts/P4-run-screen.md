# P4 · B7 Rebuild run (read P0 first; match `design/B7-rebuild-run.jpg`)

Data comes from `migration_status(run)` plus the `migration_step` rows, live through `useRunRealtime`.

## Page content
1. Breadcrumb, title "Rebuild run · <code> <company name>", and the note "Runs on the migration server, not in this browser · you can close this page and come back".
2. Key numbers: steps done (e.g. 8 of 12), rows loaded, time so far, notes (warnings).
3. **Steps**: 12 rows in the worker's order. Each row shows the number, a plain name, a one-line description, rows, time and a status pill (Done / Done · note / Running / Waiting / Failed / Skipped). Plain names for the step codes:
   - `validate` Check the files
   - `stage` Read the data files
   - `cast` Copy into the SAP copy
   - `clean_02` Clean blank links
   - `orphans_03` Look for broken links
   - `links_04` Add table links
   - `real_keys` Use SAP's real keys
   - `security_06` Lock the SAP copy
   - `app_sync` Fill the app tables
   - `check_sync` App checks
   - `check_deleted` Deleted in SAP
   - `cross_check` Cross-check the whole system

   The running step shows a progress bar when its message carries "n of m". Otherwise it shows a moving (indeterminate) bar.
4. **Live log**: dark panel, monospace, newest first, the time on each line, built from step start/finish and messages.
5. **Safe for the other companies**: "Only <code> rows are replaced. The other companies keep working; their SAP updates wait until this run ends. If a step fails or you stop the run, <code> goes back to exactly the data it had before, and the reason goes to the issue list. Stop takes effect before the next step."
6. **Earlier runs** for this company, with status pills.
7. **Stop run** opens ConfirmDialog, then calls `migration_cancel`. While `stop_requested_at` is set, show "Stopping after the current step…" and disable the button.

## Navigation
- At `needs_review`, show a banner with "Open cross-check" → B8.
- At `failed`, show the failed step's message and a link to its issue.

## Done when
- A run on `supabase/tests/testexp` updates live with no reload, all the way to needs review.
- Stop mid-run ends `cancelled`, and the company's totals are unchanged.
- At 390 px the rows stay readable.
