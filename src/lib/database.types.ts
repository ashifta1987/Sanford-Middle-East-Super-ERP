// Hand-written from supabase/sql/13_migration_console.sql and 14_console_views.sql.
// Replace with the generated file once the erp schema is exposed:
//   npm run gen:types

export type RunKind = 'full' | 'tables' | 'structure_only';
export type RunStatus =
  | 'uploading' | 'queued' | 'validating' | 'loading' | 'rebuilding' | 'checking'
  | 'needs_review' | 'signed_off' | 'failed' | 'cancelled';
export type StepStatus = 'pending' | 'running' | 'ok' | 'warning' | 'failed' | 'skipped';
export type Severity = 'critical' | 'warning' | 'info';
export type IssueStatus = 'open' | 'accepted' | 'fixed';
export type SignRole = 'finance' | 'it' | 'business';
export type Decision = 'approved' | 'rejected';
export type CheckArea = 'structure' | 'row_counts' | 'orphans' | 'app_tables' | 'finance' | 'stock' | 'hr';

export interface MigrationRun {
  run_id: string;
  company_code: string;
  kind: RunKind;
  status: RunStatus;
  created_by: string | null;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  storage_prefix: string | null;
  notes: string | null;
  worker: string | null;
  stop_requested_at: string | null;
  stop_requested_by: string | null;
}

export interface MigrationFile {
  file_id: number;
  run_id: string;
  path: string;
  kind: 'data_csv' | 'create_sql' | 'columns_csv' | 'constraints_csv' | 'row_counts_csv' | 'structure_xlsx' | 'structure_csv' | 'other';
  bytes: number | null;
  table_name: string | null;
  status: 'ok' | 'ignored' | 'skipped' | 'error';
  message: string | null;
}

export interface MigrationStep {
  run_id: string;
  step_no: number;
  code: string;
  status: StepStatus;
  rows: number | null;
  started_at: string | null;
  finished_at: string | null;
  message: string | null;
}

export interface MigrationIssue {
  issue_id: number;
  run_id: string;
  company_code: string | null;
  severity: Severity;
  area: string;
  title: string;
  detail: string | null;
  table_name: string | null;
  status: IssueStatus;
  resolved_by: string | null;
  resolved_at: string | null;
  note: string | null;
  created_at: string;
}

export interface MigrationStatusRow {
  run_id: string;
  company_code: string;
  kind: RunKind;
  run_status: RunStatus;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  step_no: number | null;
  step_code: string | null;
  step_status: StepStatus | null;
  step_rows: number | null;
  step_started_at: string | null;
  step_finished_at: string | null;
  step_seconds: number | null;
  step_message: string | null;
  files: number;
  data_files: number;
  tables_loaded: number;
  checks: number;
  checks_failed: number;
  critical_open: number;
  warning_open: number;
  info_open: number;
  signoffs: Record<string, { decision: Decision; signed_by?: string; signed_at?: string; comment?: string | null }> | null;
  stop_requested_at: string | null;
  stop_requested_by: string | null;
  report_figures: number;
  report_missing: number;
}

export interface MigrationReviewRow {
  item: 'issue' | 'check';
  id: number;
  company_code: string | null;
  area: string;
  name: string;
  severity: Severity | null;
  status: string | null;
  sap_value: string | number | null;
  raw_value: string | number | null;
  app_value: string | number | null;
  difference: string | number | null;
  ok: boolean | null;
  detail: unknown;
  report_value: string | number | null;
  report_source: string | null;
  report_ok: boolean | null;
  report_required: boolean | null;
}

export interface CompanyOverviewRow {
  company_code: string;
  company_name: string;
  sap_schema: string;
  country: string;
  currency: string;
  in_scope: boolean;
  latest_run_id: string | null;
  latest_kind: RunKind | null;
  latest_status: RunStatus | null;
  latest_created_at: string | null;
  latest_started_at: string | null;
  latest_finished_at: string | null;
  tables_loaded: number;
  rows_loaded: number;
  last_loaded_at: string | null;
  row_count_differences: number;
  orphans: number;
  checks: number;
  checks_failed: number;
  app_checks: number;
  app_checks_ok: number;
  critical_open: number;
  warning_open: number;
  info_open: number;
  signoffs_approved: number;
  signoffs: Record<string, { decision: Decision; signed_at: string }> | null;
  go_live_at: string | null;
  go_live_run: string | null;
}

export interface AppUser {
  user_id: string;
  company_code: string;
  emp_id: number | null;
  display_name: string;
  email: string | null;
  position_code: string;
  language: 'en' | 'ar';
  active: boolean;
}

export interface Position {
  position_code: string;
  name: string;
  module_access: string[];
}

export interface Company {
  company_code: string;
  legal_name: string;
  short_name: string;
  country: string;
  currency: string;
  licence_type: string;
  sap_schema: string | null;
  is_parent: boolean;
}
