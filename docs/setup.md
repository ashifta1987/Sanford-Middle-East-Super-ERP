# Setup · Supabase project `xhsfkbbcejgwvqxpqdgq`

## 1. Install the database (IT, once)
From the `sanford-db-install` package, run in order on the **direct** connection (not the pooler):

```
00_setup.sql → 01a_sap_standard.sql → 01b_addon_udt.sql → 02_clean_blank_keys.sql → 03_orphan_check.sql
→ 04_foreign_keys.sql → 06_security.sql → 10_erp_schema.sql → 11_erp_sync.sql → 12_erp_security.sql
→ 13_migration_console.sql
```
Then this repo's additions:
```
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/sql/14_realtime.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/sql/14_console_views.sql
```
Both 14 files are idempotent (safe to run twice).

## 2. Project settings
1. **Settings › API › Exposed schemas**: add `erp`. Make sure `sap` is **not** listed.
2. **Database locks** — the rebuild runs as one transaction holding about 38,000 locks. Before the first real load:
   ```
   supabase postgres-config update --config max_locks_per_transaction=2048 --remote=xhsfkbbcejgwvqxpqdgq --experimental
   ```
   (CLI 1.69+, restarts the database.)
3. **Storage** — bucket `sap-exports` is created by `14_console_views.sql` (private). In
   *Storage › Settings* set the global upload size limit to the plan maximum; resumable (TUS) uploads are on by default.
4. **Auth** — create users in *Authentication › Users*, then add rows to `erp.app_user` (with a `position_code`
   whose `module_access` contains `admin` or `it` for the console, `finance` / `business` for signers) and
   `erp.user_company` for each company they may see.

## 3. Types
```
npx supabase gen types typescript --project-id xhsfkbbcejgwvqxpqdgq --schema erp > src/lib/database.types.ts
```

## 4. Keys
| Key | Where |
|---|---|
| Publishable (anon) `sb_publishable_…` | Browser / Vercel `VITE_SUPABASE_ANON_KEY` |
| Secret / service role `sb_secret_…` | **Only** on the worker server (`SUPABASE_SERVICE_ROLE_KEY`). Never in this repo or Vercel. |

