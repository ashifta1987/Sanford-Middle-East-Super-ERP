
-- ============ 13. Grants ============
REVOKE ALL ON FUNCTION erp._gl_default(varchar, text, text), erp.gl_account(varchar, text, text, boolean, integer, text),
  erp._gl_item_acct(varchar, text, text, text, text), erp._gl_acct_problem(varchar, text, boolean, boolean),
  erp._gl_set_one(erp.app_user, varchar, text, text, text, text, text, boolean), erp._item_group_method(), erp._seed_std_reasons(varchar),
  erp._company_std_reasons(), erp._bk_norm_ref(text), erp._bk_jl_refs(varchar, integer), erp._bk_ref_ok(text, text[])
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION erp.gl_setup(varchar), erp.gl_determination_save(varchar, jsonb), erp.gl_override_save(varchar, text, text, jsonb),
  erp.warehouse_setup(varchar), erp.warehouse_save(varchar, jsonb), erp.warehouse_series_set(varchar, text, integer, bigint),
  erp.item_group_setup(varchar), erp.item_group_save(varchar, jsonb), erp.landed_cost_setup(varchar), erp.landed_cost_code_save(varchar, jsonb),
  erp.inventory_reason_save(varchar, jsonb), erp.gl_determination_set(varchar, text, text, text),
  erp.bank_statement_format_save(varchar, text, jsonb), erp.bank_statement_auto_match(varchar, integer), erp.bank_statement_activity(varchar, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION erp.gl_setup(varchar), erp.gl_determination_save(varchar, jsonb), erp.gl_override_save(varchar, text, text, jsonb),
  erp.warehouse_setup(varchar), erp.warehouse_save(varchar, jsonb), erp.warehouse_series_set(varchar, text, integer, bigint),
  erp.item_group_setup(varchar), erp.item_group_save(varchar, jsonb), erp.landed_cost_setup(varchar), erp.landed_cost_code_save(varchar, jsonb),
  erp.inventory_reason_save(varchar, jsonb), erp.gl_determination_set(varchar, text, text, text),
  erp.bank_statement_format_save(varchar, text, jsonb), erp.bank_statement_auto_match(varchar, integer), erp.bank_statement_activity(varchar, integer)
  TO authenticated;
