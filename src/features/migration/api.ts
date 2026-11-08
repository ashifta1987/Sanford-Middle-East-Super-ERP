import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import type {
  CompanyOverviewRow, Decision, IssueStatus, MigrationFile, MigrationIssue, MigrationReviewRow, MigrationRun,
  MigrationStatusRow, MigrationStep, RunKind, SignRole,
} from '@/lib/database.types';

// One typed function per RPC (P0 › API). Errors become ApiError with the P0 mapping (42501 → no access).

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await erp().rpc(name, args);
  if (error) throw new ApiError(error);
  return data as T;
}

export const migrationApi = {
  request: (company: string, kind: RunKind, notes?: string | null) =>
    rpc<string>('migration_request', { p_company: company, p_kind: kind, p_notes: notes ?? null }),

  submit: (run: string) => rpc<string>('migration_submit', { p_run: run }),

  cancel: (run: string) => rpc<string>('migration_cancel', { p_run: run }),

  status: (run: string) => rpc<MigrationStatusRow[]>('migration_status', { p_run: run }),

  review: (run: string, area?: string | null) =>
    rpc<MigrationReviewRow[]>('migration_review', { p_run: run, p_area: area ?? null }),

  setReportFigure: (a: { run: string; company: string; area: string; checkName: string; value: number | string | null; source?: string | null }) =>
    rpc<Array<{ check_name: string; report_value: number | null; raw_value: number | null; app_value: number | null; report_ok: boolean | null }>>(
      'migration_set_report_figure',
      { p_run: a.run, p_company: a.company, p_area: a.area, p_check_name: a.checkName, p_value: a.value, p_source: a.source ?? null },
    ),

  resolveIssue: (issue: number, status: IssueStatus, note?: string | null) =>
    rpc<string>('migration_resolve_issue', { p_issue: issue, p_status: status, p_note: note ?? null }),

  sign: (run: string, role: SignRole, decision: Decision, comment?: string | null) =>
    rpc<string>('migration_sign', { p_run: run, p_role: role, p_decision: decision, p_comment: comment ?? null }),

  goLive: (company: string, run: string) => rpc<string>('company_go_live', { p_company: company, p_run: run }),

  // ---- tables / views (RLS: admin/IT) ----
  async overview(): Promise<CompanyOverviewRow[]> {
    const { data, error } = await erp().from('migration_company_overview').select('*').order('company_code');
    if (error) throw new ApiError(error);
    return data as CompanyOverviewRow[];
  },

  async run(run: string): Promise<MigrationRun | null> {
    const { data, error } = await erp().from('migration_run').select('*').eq('run_id', run).maybeSingle();
    if (error) throw new ApiError(error);
    return data as MigrationRun | null;
  },

  async steps(run: string): Promise<MigrationStep[]> {
    const { data, error } = await erp().from('migration_step').select('*').eq('run_id', run).order('step_no');
    if (error) throw new ApiError(error);
    return data as MigrationStep[];
  },

  async files(run: string): Promise<MigrationFile[]> {
    const { data, error } = await erp().from('migration_file').select('*').eq('run_id', run).order('path');
    if (error) throw new ApiError(error);
    return data as MigrationFile[];
  },

  async openIssues(limit = 20): Promise<MigrationIssue[]> {
    const { data, error } = await erp().from('migration_issue').select('*').eq('status', 'open')
      .order('created_at', { ascending: false }).limit(limit);
    if (error) throw new ApiError(error);
    return data as MigrationIssue[];
  },

  async latestRunForCompany(company: string): Promise<MigrationRun | null> {
    const { data, error } = await erp().from('migration_run').select('*').eq('company_code', company)
      .order('created_at', { ascending: false }).limit(1).maybeSingle();
    if (error) throw new ApiError(error);
    return data as MigrationRun | null;
  },
};

