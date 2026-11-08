# P3 · B6 Upload SAP backup (read P0 first; match `design/B6-upload-backup.jpg`)

## Resumable upload (`src/features/migration/upload/ResumableUpload.ts`)
- Use `tus-js-client` against `<SUPABASE_URL>/storage/v1/upload/resumable` with the user's access token, bucket `sap-exports`, object name `<company>/<run_id>/<relative path>`, and 6 MB chunks.
- Accept a folder (`<input type="file" webkitdirectory>`, keep relative paths), a `.zip`/`.tar.gz`, or loose files.
- Upload up to 4 files at a time. Show overall progress and per-file progress.
- Keep each upload's URL in IndexedDB with tus `urlStorage`. On return, show "Resume upload".
- Exports run to tens of GB, so a dropped connection or a closed tab must never restart from zero.

## Page content, top to bottom
1. Breadcrumb "SAP migration › Upload", the title, and a company picker that shows `AE01 · Sanford Middle East DWC · SBO_SANFORD`.
2. StepTracker. For each step: done gets a dark green dot, needs action gets an amber dot, and the current step is outlined.
3. Left column:
   - **Add files** drop zone: "Drop the HANA export folder or a .zip here", with Choose folder / Choose .zip or files.
   - **What this company needs** checklist with Received/Missing pills:
     - data export folder
     - `columns.csv` (query 1, column order; the data files have no header)
     - `constraints.csv` (query 2)
     - `row_counts.csv` (query 4)
     - field list (optional)
   - **Received** table: file, read as, rows in file, size, result. Data comes from `migration_file`.
4. Right column:
   - **What the check found**: a headline plus facts from `migration_review(run,'structure')`.
   - **Points to fix**: issues with Blocker / Send CSV / Info pills.
   - **Next step for SAP / IT** box:
     - **Copy message for IT** copies a ready text naming the SAP schema and queries 1, 2 and 4 plus the EXPORT step.
     - **Download script** serves `supabase/sql/05_hana_export.sql` with the schema filled in.
   - **Start load and rebuild**, disabled until the data folder and the 3 control files are in, with the reason shown below. Clicking it calls `migration_submit` and opens B7.

## Flow
- The first file chosen calls `migration_request(company, kind, notes)`, then the upload starts.
- If every file is a field list (Excel/CSV with columns Table Name, Field Name, Data Type, Length, Allow Nulls), use kind `structure_only` and submit automatically when the upload finishes. The worker checks the structure without touching data.

## Real case to reproduce
Sanford's 8 Nov upload for AE01 was 9 Excel files: `Table_With_Field.xlsx`, `Table.xlsx`, `OITM.xlsx`, `OITM__V.1.xlsx`, `OITB.xlsx`, `OITW.xlsx`, `ITM1.xlsx`, `OUGP.xlsx`, `UGP1.xlsx`. They are field lists only. The screen must show:
- "Structure matches 100% · No data rows yet"
- tables in SAP 3,691 · in Sanford ERP 3,250 · left out on purpose 441
- fields compared 117,772 · missing 0 · type differences 0
- item master fields 453 · 107 user fields
- the Blocker "No records in this upload"
- "Excel changed a table name" (AUG1 became a date): send CSV
- Start stays disabled.

## Done when
- The good export in `supabase/tests/testexp` uploads, resumes after a tab close, and Start opens B7.
- The real 8 Nov case looks like the design.
