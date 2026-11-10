# Source of `32_gl_setup.sql`

`supabase/sql/32_gl_setup.sql` (phase B3) is **generated**. Do not hand-edit the copied functions in it; edit the sources here and rebuild.

| File | What it holds |
|---|---|
| `part1.sql` | Hand-written start: tables, the posting key catalogue (`gl_posting_key` INSERT with tab / ctx / used_in), `gl_account` resolution, setup APIs. |
| `build.py` | Copies earlier functions (`post_document`, `_count_post`, `_inv_eval`, `_lc_eval`, `landed_cost_create`, `prod_order_receipt`, `prod_resource_save`, `_series_take`, `_health_files`, …) out of the earlier SQL files and applies **asserted string patches** (each patch must match an exact number of times, or the build stops). |
| `part2.sql` | Hand-written middle: warehouses, item groups, landed cost types, reasons, bank statement formats. |
| `part3.sql` | Hand-written end: grants / revokes and the sample (ZZ99) rows. |

## Rebuild

```sh
python3 supabase/sql/src/32_gl_setup/build.py           # writes supabase/sql/32_gl_setup.sql
python3 supabase/sql/src/32_gl_setup/build.py --check   # exit 0 when the committed file is identical
```

The earlier SQL files never change (A0 rule), so the copies are stable. Paths are relative to this folder; no absolute paths.

Verified in B4: `--check` reports `identical` against the committed B3 file.

