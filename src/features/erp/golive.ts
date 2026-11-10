import { useQuery } from '@tanstack/react-query';
import { rpc } from './api';

/** Types and calls for A14 · Go-live checklist and system health (supabase/sql/29_go_live.sql). The database is the authority. */
export interface GoLiveCompany {
  company_code: string; company_name: string; active: boolean; steps_done: number; steps_total: number; next_step: number | null;
  go_live_at: string | null; hypercare_until: string | null; open_issues: number;
}
export interface GoLiveStep {
  step: number; title: string; auto: boolean; done: boolean; note: string | null; evidence: string | null;
  done_at: string | null; done_by: string | null; updated_at: string | null; waiting_for: number | null;
}
export interface GoLiveIssue {
  issue_id: number; title: string; severity: 'critical' | 'normal'; status: 'open' | 'fixed'; raised_by: string | null; raised_at: string;
  fixed_by: string | null; fixed_at: string | null; fix_note: string | null;
}
export interface GoLiveChecklist {
  company_code: string; company_name: string; can_write: boolean; can_go_live: boolean; live: boolean;
  go_live_at: string | null; go_live_by: string | null; go_live_run: string | null; hypercare_until: string | null;
  run: null | { run_id: string; status: string; kind: string; created_at: string; finished_at: string | null;
                signoffs: Array<{ role: 'finance' | 'it' | 'business'; decision: 'approved' | 'rejected'; signed_at: string; signed_by: string | null }> };
  users: { active: number; positions: number; pending_invites: number };
  steps: GoLiveStep[]; issues: GoLiveIssue[];
  activity: Array<{ at: string; action: string; by: string | null; detail: Record<string, unknown> | null }>;
}
export type HealthStatus = 'ok' | 'warn' | 'error';
export interface SystemHealth {
  status: HealthStatus; server_time: string;
  database: { version: string; size_mb: number; max_locks_per_transaction: string };
  files: Array<{ file: string; object: string; present: boolean }>;
  releases: Array<{ file: string; environment: string; applied_at: string; applied_by: string; note: string | null }>;
  checks: Array<{ key: string; status: HealthStatus; count: number; items: string[] }>;
  companies: Array<{ company_code: string; company_name: string; last_sap_load: string | null; go_live_at: string | null; checklist_done: number; open_issues: number }>;
}

export const useGoLiveOverview = () => useQuery({ queryKey: ['golive-overview'], queryFn: () => rpc<GoLiveCompany[]>('go_live_overview', {}) });
export const useGoLiveChecklist = (company: string) => useQuery({
  queryKey: ['golive', company], enabled: Boolean(company), queryFn: () => rpc<GoLiveChecklist>('go_live_checklist', { p_company: company }),
});
export const useSystemHealth = () => useQuery({ queryKey: ['system-health'], queryFn: () => rpc<SystemHealth>('system_health', {}) });

export const goLiveStepSet = (company: string, step: number, done: boolean, note: string, evidence: string) =>
  rpc<{ step: number; done: boolean }>('go_live_step_set', { p_company: company, p_step: step, p_done: done, p_note: note || null, p_evidence: evidence || null });
export const goLiveIssueSave = (company: string, title: string, severity: 'critical' | 'normal') =>
  rpc<{ issue_id: number }>('go_live_issue_save', { p_company: company, p_issue: { title, severity } });
export const goLiveIssueClose = (company: string, id: number, note: string) =>
  rpc<{ status: string }>('go_live_issue_close', { p_company: company, p_issue_id: id, p_note: note });
/** Step 6: the existing CFO go-live (14_console_views.sql, gated by the checklist in 29). */
export const companyGoLive = (company: string, run: string) => rpc<string>('company_go_live', { p_company: company, p_run: run });

/** Steps that need a reference (written approval, final backup) before they can be marked done. */
export const STEP_NEEDS_EVIDENCE = new Set([2, 5]);
