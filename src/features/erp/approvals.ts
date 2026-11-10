import { useQuery } from '@tanstack/react-query';
import { rpc } from './api';

/** Types and calls for B2 · Approval Process (supabase/sql/31_approvals.sql). The database is the authority. */
export type Unit = 'pct' | 'amount' | 'days';
export type Op = 'gt' | 'ge' | 'lt' | 'le' | 'eq' | 'ne' | 'between' | 'not_between';
export const OPS: Op[] = ['gt', 'ge', 'lt', 'le', 'eq', 'ne', 'between', 'not_between'];
export interface KindField { field: string; unit: Unit; line?: boolean }
export interface Kind {
  kind: string; label: string; obj_types: number[]; module: string; built_in: boolean; primary_field: string | null; primary_op: Op | null; fields: KindField[];
}
export interface Person { position_code: string | null; user_id: string | null; name?: string; kind?: 'position' | 'user' }
export interface Condition { field: string; op: Op; value1: number | string; value2: number | string | null }
export interface Stage {
  stage_id: number; name: string; description: string | null; required_approvals: number; required_rejections: number; active: boolean;
  source: 'erp' | 'migrated' | 'sample'; updated_at: string; authorizers: Person[]; people: number; templates: string[]; pending: number;
}
export interface Template {
  template_id: number; name: string; description: string | null; kind: string; kind_label: string; obj_type: number; active: boolean;
  version: number; source: 'erp' | 'migrated' | 'sample'; legacy_sync: boolean; originators: Person[];
  stages: Array<{ seq: number; stage_id: number; name: string }>; conditions: Condition[]; pending: number; used: number;
  updated_at: string; updated_by_name: string | null;
}
export interface ApprovalSetup {
  company_code: string; can_write: boolean; currency: string; owner_position: string | null; owner_position_name: string | null;
  kinds: Kind[]; positions: Array<{ position_code: string; name: string }>; users: Array<{ user_id: string; display_name: string; position_code: string }>;
  stages: Stage[]; templates: Template[];
  leave: { long_leave_days: number | null; hr_approver_name: string | null; owner_name: string | null } | null;
}
export interface TemplateVersion { version: number; active: boolean; action: string; snapshot: Omit<Template, 'template_id'>; changed_by_name: string; changed_at: string }
export interface TrailStep {
  approval_id: number; step: number; rule_code: string; template_name: string; template_id: number | null; template_version: number | null;
  stage_name: string | null; stage_id: number | null; who: string | null; need_approvals: number; need_rejections: number; approvals: number; rejections: number;
  votes: Array<{ user_name: string; decision: 'approved' | 'rejected'; note: string | null; at: string }>;
  decision: 'approved' | 'rejected' | null; decided_at: string | null; decided_by_name: string | null; note: string | null; superseded: boolean; current: boolean;
}
export type ReportStatus = 'pending' | 'approved' | 'rejected' | 'cancelled' | 'all';
export interface ReportRow {
  object: string; object_ref: string; kind: string; rule_code: string; doc_no: string; doc_entry: number; company_code: string; status: Exclude<ReportStatus, 'all'> | string;
  state: string; card_code: string | null; card_name: string | null; total: number | null; currency: string | null; requested_at: string;
  requested_by_name: string | null; templates: string; current_step: number | null; steps: number; last_decided_at: string | null;
  waiting_days: number | null; current_stage: string | null; current_who: string | null; trail: TrailStep[];
}
export interface StatusReport { counts: Record<'pending' | 'approved' | 'rejected' | 'cancelled', number>; rows: ReportRow[] }

export const useApprovalSetup = (company: string) =>
  useQuery({ queryKey: ['apr-setup', company], enabled: Boolean(company), queryFn: () => rpc<ApprovalSetup>('approval_setup', { p_company: company }) });
export const useTemplateHistory = (company: string, id: number | null) =>
  useQuery({ queryKey: ['apr-history', company, id], enabled: Boolean(company && id), queryFn: () => rpc<TemplateVersion[]>('approval_template_history', { p_company: company, p_template_id: id }) });
export const useStatusReport = (company: string, filter: Record<string, string>) =>
  useQuery({ queryKey: ['apr-report', company, filter], enabled: Boolean(company), queryFn: () => rpc<StatusReport>('approval_status_report', { p_company: company, p_filter: filter }) });

export const stageSave = (company: string, s: Record<string, unknown>) => rpc<{ stage_id: number; pending: number }>('approval_stage_save', { p_company: company, p_stage: s });
export const stageDelete = (company: string, id: number) => rpc<{ deleted: boolean }>('approval_stage_delete', { p_company: company, p_stage_id: id });
export const templateSave = (company: string, t: Record<string, unknown>) =>
  rpc<{ template_id: number; version: number; pending: number }>('approval_template_save', { p_company: company, p_tpl: t });
export const templateSetActive = (company: string, id: number, active: boolean) =>
  rpc<{ active: boolean; version: number; pending: number }>('approval_template_set_active', { p_company: company, p_template_id: id, p_active: active });
export const templateDelete = (company: string, id: number) => rpc<{ deleted: boolean }>('approval_template_delete', { p_company: company, p_template_id: id });

/** Where an approval request's document lives (same routes as the Approvals inbox). */
export function requestLink(r: { kind: string; company_code: string; doc_entry: number; card_code: string | null }): string {
  switch (r.kind) {
    case 'bp_change': return `/bp/${r.company_code}/${encodeURIComponent(r.card_code ?? '')}`;
    case 'payment': return `/banking/payment-drafts/${r.company_code}/${r.doc_entry}`;
    case 'inventory_count': return `/inventory/counts/${r.company_code}/${r.doc_entry}`;
    case 'leave': return `/hr/leave/${r.company_code}/${r.doc_entry}`;
    case 'company_details': return `/admin/company?company=${r.company_code}`;
    case 'sales_doc_request': return `/sales/requests/${r.company_code}/${r.doc_entry}`;
    case 'journal': return `/financials/journals/drafts/${r.company_code}/${r.doc_entry}`;
    default: return `/docs/${r.kind}/${r.company_code}/${r.doc_entry}`;
  }
}
