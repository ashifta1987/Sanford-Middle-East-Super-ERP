# Source of `35_final_items.sql`

`supabase/sql/35_final_items.sql` (phase B6) is **generated**, like 32–34. Edit the sources here and rebuild; don't hand-edit the copied functions in 35.

| File | What it holds |
|---|---|
| `part1.sql` | Header, section 1: `landed_cost_charge.card_code` (vendor per cost line); section 2: system currency per company (`system_currency_setting`, `_sys_cur`, `_sys_cur_used`, `system_currency_info / save`). |
| `build.py` | Copies of earlier functions with asserted patches: `_lc_eval`, `landed_cost_create`, `landed_cost_info`, `_health_files` (34); `post_journal`, `_reverse_journal` (33). Every patch must match an exact number of times. |
| `part2.sql` | Section 4: Conversion Differences (posting key `general/conversion_diff`, ZZ99 SAMPLE account 7120, `conv_diff_run / conv_diff_line`, `conv_diff_list`, `_cvd_rows`, `_cvd_eval`, `conversion_diff_setup / preview / post / cancel / info`); section 5: grants. |

```sh
python3 supabase/sql/src/35_final_items/build.py           # writes supabase/sql/35_final_items.sql
python3 supabase/sql/src/35_final_items/build.py --check   # exit 0 when the committed file is identical
```
