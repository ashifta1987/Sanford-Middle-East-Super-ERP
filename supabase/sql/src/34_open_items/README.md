# Source of `34_open_items.sql`

`supabase/sql/34_open_items.sql` (phase B5) is **generated**, like 32 and 33. Edit the sources here and rebuild; don't hand-edit the copied functions in 34.

| File | What it holds |
|---|---|
| `part1.sql` | Header, section 1: Substitute Authorizer (`apr_substitute`, `approval_vote.on_behalf_of`, `approval.on_behalf_of`, `_apr_sub_principal`, `_apr_sub_of_stage`, `_apr_user_stages`, vote / decision triggers, `approval_substitute_list / save / end`). |
| `build.py` | Copies of earlier functions with asserted patches: `_apr_is_mine`, `_apr_can_act`, `_apr_votes`, `_apr_trail`, `approval_inbox` (31); `_cur_ctx_base`, `_cur_line_fc`, `_sd_cm_exec` (33); `_lc_eval`, `landed_cost_create` (32); `landed_cost_info` (21); `_health_files` (33). Every patch must match an exact number of times. |
| `part2.sql` | Landed cost charge columns (currency, FC amount, rate, linked A/P invoice, clearing amount, rate difference). |
| `part3.sql` | `sales_doc_list_fc`, `purchase_doc_list_fc`, `payment_list_fc`; period-end revaluation (posting keys `general/fx_reval_gain` / `fx_reval_loss`, ZZ99 SAMPLE accounts 7110 / 7210, `fx_revaluation(_line)`, `fx_revaluation_list`, `_fxr_open`, `_fxr_eval`, `_fxr_mirror`, `fx_revaluation_setup / preview / post / cancel / info`); grants. |

```sh
python3 supabase/sql/src/34_open_items/build.py           # writes supabase/sql/34_open_items.sql
python3 supabase/sql/src/34_open_items/build.py --check   # exit 0 when the committed file is identical
```
