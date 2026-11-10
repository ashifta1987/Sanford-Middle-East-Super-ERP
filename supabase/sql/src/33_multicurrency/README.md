# Source of `33_multicurrency.sql`

`supabase/sql/33_multicurrency.sql` (phase B4) is **generated**, like 32. Edit the sources here and rebuild; don't hand-edit the copied functions in 33.

| File | What it holds |
|---|---|
| `part1.sql` | Columns (`vat_fc`, `vat_total_fc`, `paid_fc`, payment `total_fc` / `fx_diff`, …), rate helpers (`_cur_rate`, `_cur_pick`, `currency_rate`), the document context (`_cur_ctx_*`), the line trigger `cur_line_fc`, `_sd_retotal`, open amounts in the document currency, `bp_balance_fc`, `_pd_last_price`. |
| `build.py` | Copies of earlier functions with asserted patches: `post_journal`, `_reverse_journal`, `_sd_new_doc`, `_pd_new_doc`, `_sd_base_lines`, delivery / invoice / credit memo executors, `_sd_eval`, `sales_doc_save`, `_sd_stored`, `_pd_stored`, `_pd_eval`, `purchase_doc_save`, GRPO, A/P invoice, deposit, `post_document`, copy sources, `_pay_eval`, `_pay_post`, `payment_cancel`, `payment_open_docs`, `_health_files`. Every patch must match an exact number of times. |
| `part2.sql` | Aging reports with the document currency (`rpt_ar_aging_fc`, `rpt_ap_aging_fc`). |
| `part3.sql` | Soft-switch stock (`stock_soft_switch`, `stock_movement` keep trigger, `stock_balance_parts`), ranked manual bank candidates, revaluation note, grants. |

```sh
python3 supabase/sql/src/33_multicurrency/build.py           # writes supabase/sql/33_multicurrency.sql
python3 supabase/sql/src/33_multicurrency/build.py --check   # exit 0 when the committed file is identical
```

