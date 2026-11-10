// A12 · migration completion: settings, custom-field register, run report. One typed function per RPC.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { mk } from './queries';

export interface MigrationSetting {
  company_code: string;
  opening_date: string | null;
  opening_clearing_acct: string | null;
  net_pay_wage_codes: string[];
  vat_period_from: string | null;
  vat_period_to: string | null;
  updated_at: string;
}

export type CfDecision = 'mapped' | 'raw_only' | 'drop';
export interface CustomField {
  company_code: string;
  table_name: string;
  field_name: string;
  kind: 'field' | 'table';
  description: string | null;
  field_type: string | null;
  decision: CfDecision;
  target: string | null;
  suggested: string | null;
  rows_used: number | null;
  total_rows: number | null;
  last_used: string | null;
  in_raw: boolean;
  decided_by: string | null;
  decided_at: string | null;
  note: string | null;
  drop_state: 'pending' | 'approved' | 'rejected' | null;
  drop_note: string | null;
}
export interface CfSetup {
  company: string;
  can_edit: boolean;
  can_approve_drop: boolean;
  owner_position: string | null;
  built_at: string | null;
  dict_source: string | null;
  summary: { total: number; fields: number; tables: number; mapped: number; raw_only: number; drop_pending: number; drop_approved: number; unused: number; decided: number };
  tables: string[];
}
export interface CfFilter { search: string; table: string; decision: '' | CfDecision | 'drop_pending'; unused: boolean; page: number }
export const CF_PAGE = 100;

/** migration_report: everything an auditor needs for one run. */
export interface MigrationReport {
  generated_at: string;
  generated_by: string | null;
  run: { run_id: string; company_code: string; kind: string; status: string; created_at: string; started_at: string | null; finished_at: string | null; notes: string | null; created_by: string | null };
  company: { code: string; name: string; currency: string; sap_schema: string | null } | null;
  steps: Array<{ step_no: number; code: string; status: string; rows: number | null; started_at: string | null; finished_at: string | null; message: string | null }>;
  files: { total: number; data_files: number; bytes: number; skipped: number; errors: number };
  checks: Array<{ id: number; company_code: string | null; area: string; name: string; sap_value: number | null; raw_value: number | null; app_value: number | null; difference: number | null; ok: boolean | null; report_value: number | null; report_source: string | null; report_ok: boolean | null; detail: unknown }>;
  issues: Array<{ id: number; company_code: string | null; area: string; name: string; severity: string; status: string; ok: boolean; detail: { detail?: string | null; table?: string | null; note?: string | null; resolved_at?: string | null } | null }>;
  signoffs: Array<{ role: string; decision: string; signed_by: string; signed_by_name: string | null; signed_at: string; comment: string | null }>;
  custom_fields: { total: number; mapped: number; raw_only: number; drop_pending: number; drop_approved: number };
  attachments: { total: number; copied: number; missing: number; errors: number; bytes: number };
  settings: Partial<MigrationSetting> | null;
}

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await erp().rpc(name, args);
  if (error) throw new ApiError(error);
  return data as T;
}

export const moreApi = {
  async setting(company: string): Promise<MigrationSetting | null> {
    const { data, error } = await erp().from('migration_setting').select('*').eq('company_code', company).maybeSingle();
    if (error) throw new ApiError(error);
    return data as MigrationSetting | null;
  },
  saveSetting: (company: string, p: Record<string, unknown>) => rpc<MigrationSetting>('migration_setting_save', { p_company: company, p }),
  report: (run: string) => rpc<MigrationReport>('migration_report', { p_run: run }),
  cfSetup: (company: string) => rpc<CfSetup>('custom_field_setup', { p_company: company }),
  cfBuild: (company: string) => rpc<number>('custom_field_register_build', { p_company: company }),
  cfDecide: (company: string, items: Array<{ table: string; field: string }>, decision: CfDecision, target?: string | null, note?: string | null) =>
    rpc<number>('custom_field_decide', { p_company: company, p_items: items, p_decision: decision, p_target: target ?? null, p_note: note ?? null }),
  cfDropDecide: (company: string, items: Array<{ table: string; field: string }>, approve: boolean, note?: string | null) =>
    rpc<number>('custom_field_drop_decide', { p_company: company, p_items: items, p_approve: approve, p_note: note ?? null }),
  async cfList(company: string, f: CfFilter): Promise<{ rows: CustomField[]; count: number }> {
    let q = erp().from('custom_field_register').select('*', { count: 'exact' }).eq('company_code', company);
    if (f.table) q = q.eq('table_name', f.table);
    if (f.decision === 'drop_pending') q = q.eq('decision', 'drop').eq('drop_state', 'pending');
    else if (f.decision) q = q.eq('decision', f.decision);
    if (f.unused) q = q.eq('in_raw', true).or('rows_used.is.null,rows_used.eq.0');
    const s = f.search.trim().replace(/[%,()*]/g, ' ');
    if (s) q = q.or(`field_name.ilike.*${s}*,description.ilike.*${s}*,target.ilike.*${s}*`);
    const { data, error, count } = await q.order('table_name').order('field_name').range(f.page * CF_PAGE, f.page * CF_PAGE + CF_PAGE - 1);
    if (error) throw new ApiError(error);
    return { rows: (data ?? []) as CustomField[], count: count ?? 0 };
  },
};

const cfKey = (company: string) => [...mk.all, 'cf', company] as const;

export function useMigrationSetting(company: string | undefined) {
  return useQuery({ queryKey: [...mk.all, 'setting', company], queryFn: () => moreApi.setting(company!), enabled: Boolean(company) });
}
export function useSaveSetting(company: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (p: Record<string, unknown>) => moreApi.saveSetting(company, p),
    onSuccess: () => qc.invalidateQueries({ queryKey: [...mk.all, 'setting', company] }),
  });
}
export function useCfSetup(company: string | undefined) {
  return useQuery({ queryKey: [...cfKey(company ?? ''), 'setup'], queryFn: () => moreApi.cfSetup(company!), enabled: Boolean(company), retry: false });
}
export function useCfList(company: string | undefined, f: CfFilter) {
  return useQuery({ queryKey: [...cfKey(company ?? ''), 'list', f], queryFn: () => moreApi.cfList(company!, f), enabled: Boolean(company), placeholderData: (p) => p });
}
export function useCfMutations(company: string) {
  const qc = useQueryClient();
  const done = () => qc.invalidateQueries({ queryKey: cfKey(company) });
  return {
    build: useMutation({ mutationFn: () => moreApi.cfBuild(company), onSuccess: done }),
    decide: useMutation({
      mutationFn: (a: { items: Array<{ table: string; field: string }>; decision: CfDecision; target?: string | null; note?: string | null }) =>
        moreApi.cfDecide(company, a.items, a.decision, a.target, a.note),
      onSuccess: done,
    }),
    drop: useMutation({
      mutationFn: (a: { items: Array<{ table: string; field: string }>; approve: boolean; note?: string | null }) => moreApi.cfDropDecide(company, a.items, a.approve, a.note),
      onSuccess: done,
    }),
  };
}

// ---- CSV of the run report (one file, sections one after the other)
const cell = (v: unknown) => {
  if (v === null || v === undefined) return '';
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
export function reportCsv(r: MigrationReport): string {
  const out: unknown[][] = [];
  const sec = (title: string, head: string[], rows: unknown[][]) => { out.push([], [title], head, ...rows); };
  out.push(['Sanford Super ERP · SAP migration run report'], ['Run', r.run.run_id], ['Company', `${r.run.company_code} ${r.company?.name ?? ''}`],
    ['Kind', r.run.kind], ['Status', r.run.status], ['Started', r.run.started_at], ['Finished', r.run.finished_at],
    ['Generated', r.generated_at], ['Generated by', r.generated_by]);
  sec('Steps', ['No', 'Step', 'Status', 'Rows', 'Started', 'Finished', 'Message'],
    r.steps.map((s) => [s.step_no, s.code, s.status, s.rows, s.started_at, s.finished_at, s.message]));
  sec('Files', ['Total', 'Data files', 'Bytes', 'Skipped', 'Errors'], [[r.files.total, r.files.data_files, r.files.bytes, r.files.skipped, r.files.errors]]);
  sec('Checks', ['Company', 'Area', 'Check', 'SAP', 'SAP copy', 'App', 'Difference', 'OK', 'SAP report', 'Report source', 'Report OK'],
    r.checks.map((c) => [c.company_code, c.area, c.name, c.sap_value, c.raw_value, c.app_value, c.difference, c.ok, c.report_value, c.report_source, c.report_ok]));
  sec('Issues', ['Company', 'Area', 'Severity', 'Title', 'Detail', 'Status', 'Note', 'Resolved at'],
    r.issues.map((i) => [i.company_code, i.area, i.severity, i.name, i.detail?.detail, i.status, i.detail?.note, i.detail?.resolved_at]));
  sec('Sign-offs', ['Role', 'Decision', 'Signed by', 'Signed at', 'Comment'],
    ['finance', 'it', 'business'].map((role) => { const s = r.signoffs.find((x) => x.role === role); return [role, s?.decision ?? 'waiting', s?.signed_by_name ?? s?.signed_by, s?.signed_at, s?.comment]; }));
  sec('Custom-field register', ['Total', 'Mapped', 'Raw copy only', 'Drop waiting', 'Drop approved'],
    [[r.custom_fields.total, r.custom_fields.mapped, r.custom_fields.raw_only, r.custom_fields.drop_pending, r.custom_fields.drop_approved]]);
  sec('Attachments', ['Listed', 'Copied', 'Missing', 'Errors', 'Bytes copied'], [[r.attachments.total, r.attachments.copied, r.attachments.missing, r.attachments.errors, r.attachments.bytes]]);
  return '\ufeff' + out.map((row) => row.map(cell).join(',')).join('\r\n') + '\r\n';
}
export function downloadText(text: string, name: string, type = 'text/csv;charset=utf-8') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
