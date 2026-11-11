import { useQuery } from '@tanstack/react-query';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** Types and calls for A10 · Administration (supabase/sql/25_admin.sql). The database is the authority. */
export type Level = 'full' | 'read';
export const ADMIN_MODULES = ['admin', 'it', 'finance', 'sales', 'purchase', 'bp', 'banking', 'inventory', 'production', 'service', 'hr', 'reports', 'business'] as const;
export type AdminModule = typeof ADMIN_MODULES[number];

export interface AdminUser {
  user_id: string; display_name: string; email: string | null; mobile: string | null; position_code: string; position_name: string;
  company_code: string; companies: string[]; emp_id: number | null; emp_name: string | null; emp_code: string | null;
  language: 'en' | 'ar'; active: boolean; last_sign_in_at: string | null; invited_at: string | null;
}
export interface AdminInvite {
  invite_id: number; email: string; display_name: string; position_code: string; company_code: string; companies: string[];
  invited_at: string; invited_by_name: string | null;
}
export interface AdminUsers {
  can_write: boolean; me: string; users: AdminUser[]; invites: AdminInvite[];
  positions: Array<{ position_code: string; name: string }>; companies: Array<{ company_code: string; short_name: string }>;
}
export interface UserInput {
  display_name: string; position_code: string; company_code: string; companies: string[]; emp_id: number | null;
  language: 'en' | 'ar'; mobile: string; active?: boolean; email?: string;
}
export interface PositionRow { position_code: string; name: string; levels: Partial<Record<AdminModule, Level>>; users: number; rules: number }
export interface AdminPositions { can_write: boolean; my_position: string; modules: AdminModule[]; positions: PositionRow[] }
export interface AccessChange { module: AdminModule; from: Level | 'none'; to: Level | 'none'; gain: boolean }
export interface AccessPreview {
  position_code: string; changes: AccessChange[]; gain: AccessChange[]; lose: AccessChange[];
  users: Array<{ user_id: string; display_name: string; email: string | null }>;
}
export type LimitKind = 'pct' | 'pct_any' | 'amount' | 'days' | 'none';
export interface RuleSpec { rule_code: string; obj_types: number[]; position_required: boolean; limit_kind: LimitKind }
export interface ApprovalRule {
  rule_id: number; obj_type: number; rule_code: string; position_code: string | null; position_name: string | null; limit_value: number | null;
  approver_position: string; approver_name: string; step: number; active: boolean; note: string | null;
}
export interface TemplateSetup {
  can_write: boolean; currency: string; catalogue: RuleSpec[]; positions: Array<{ position_code: string; name: string }>; rules: ApprovalRule[];
  pending: number; leave: { long_leave_days: number | null; hr_approver_position: string | null; owner_position: string | null } | null;
}
export interface Series { obj_type: number; label: string; module: string; prefix: string | null; next_num: number | null; pad: number | null; active: boolean | null; example: string | null }
export interface Profile {
  legal_name: string | null; trading_name: string | null; tax_id: string | null; licence_no: string | null; address: string | null;
  phone: string | null; email: string | null; logo_path: string | null; fiscal_year_start: number | null;
}
export interface CompanyInfo {
  company: { company_code: string; legal_name: string; short_name: string; country: string; currency: string; licence_type: string; licence_authority: string | null };
  profile: Profile;
  setting: { owner_position: string | null; owner_position_name: string | null; fx_currencies: string[] };
  can_write: boolean;
  pending: null | {
    request_id: number; before: Profile; after: Profile; reason: string | null; requested_by_name: string | null; requested_at: string;
    is_requester: boolean; approver_position: string | null; can_decide: boolean;
    approvals?: Array<{ step: number; template_name: string | null; stage_name: string | null; need_approvals: number; votes: Array<{ decision: string }>; current: boolean }>;
  };
  history: Array<{ request_id: number; state: string; after: Profile; reason: string | null; requested_by_name: string | null; requested_at: string; decided_by_name: string | null; decided_at: string | null; note: string | null }>;
}
export interface FxSetup { currency: string; currencies: string[]; can_write: boolean }
export interface FxRow { company_code: string; rate_date: string; currency: string; rate: number; source: 'sap' | 'manual' | 'import'; entered_by_name: string | null; entered_at: string | null }
/** U0+S1 · Add-Ons › AI Assistant (Sana): settings and usage counts (never question text). */
export interface SanaSetup {
  company: string; can_edit: boolean; all_languages: string[];
  settings: { enabled: boolean; voice_enabled: boolean; daily_limit: number; languages: string[]; saved: boolean; updated_at: string | null; updated_by: string | null };
  usage: {
    days: Array<{ day: string; questions: number; refused: number; voice: number; ai: number; basic: number; users: number }>;
    total_30_days: { questions: number; refused: number; voice: number; ai: number; basic: number; fallback: number; users: number };
    feedback: { up: number; down: number };
  };
}
export interface AuditRow { at: string; actor_name: string; company_code: string | null; action: string; object: string; object_ref: string | null; detail: Record<string, unknown> | null }

export const useAdminUsers = () => useQuery({ queryKey: ['adm-users'], queryFn: () => rpc<AdminUsers>('admin_users', {}) });
export const useAdminPositions = () => useQuery({ queryKey: ['adm-positions'], queryFn: () => rpc<AdminPositions>('admin_positions', {}) });
export const useAudit = (objects: string[]) => useQuery({
  queryKey: ['adm-audit', objects.join(',')], queryFn: () => rpc<AuditRow[]>('admin_audit_recent', { p_objects: objects, p_limit: 15 }),
});

export const userSave = (id: string, u: UserInput) => rpc<{ user_id: string; active: boolean }>('admin_user_save', { p_user_id: id, p_user: u });
export const employeeOptions = (company: string, q: string) =>
  rpc<Array<{ emp_id: number; hr_code: string | null; name: string; linked_to: string | null }>>('admin_employee_options', { p_company: company, p_q: q });
export const inviteCancel = (id: number) => rpc<{ state: string }>('admin_invite_cancel', { p_invite_id: id });

/**
 * Invite by email through the invite-user Edge Function (server side, service role). The browser sends only the admin's
 * own session; the function checks it with erp.admin_invite_create before creating the Supabase Auth user.
 */
export async function inviteUser(u: UserInput & { email: string }) {
  const { data, error } = await supabase.functions.invoke('invite-user', { body: u });
  if (error) {
    if (error instanceof FunctionsHttpError) {
      const body = await (error.context as Response).json().catch(() => ({}));
      throw new ApiError({ code: body.code, message: body.message ?? error.message });
    }
    throw new ApiError({ message: error.message });
  }
  return data as { invite_id: number; user_id: string; email: string; state: 'sent' };
}

export const positionSave = (code: string, name: string, isNew: boolean) => rpc('position_save', { p_code: code, p_name: name, p_new: isNew });
export const positionDelete = (code: string) => rpc('position_delete', { p_code: code });
export const accessPreview = (pos: string, levels: Record<string, string>) => rpc<AccessPreview>('position_access_preview', { p_position: pos, p_levels: levels });
export const accessSave = (pos: string, levels: Record<string, string>) => rpc<{ changes: AccessChange[] }>('position_access_save', { p_position: pos, p_levels: levels });

export const useTemplates = (company: string) => useQuery({
  queryKey: ['adm-templates', company], enabled: Boolean(company), queryFn: () => rpc<TemplateSetup>('approval_template_setup', { p_company: company }),
});
export const ruleSave = (company: string, r: Record<string, unknown>) => rpc<{ rule_id: number }>('approval_rule_save', { p_company: company, p_rule: r });
export const ruleDelete = (company: string, id: number) => rpc('approval_rule_delete', { p_company: company, p_rule_id: id });

export const useSeries = (company: string) => useQuery({
  queryKey: ['adm-series', company], enabled: Boolean(company), queryFn: () => rpc<{ can_write: boolean; series: Series[] }>('number_series_setup', { p_company: company }),
});
export const seriesSave = (company: string, obj: number, prefix: string, next: number, pad: number, active: boolean) =>
  rpc<{ example: string }>('number_series_save', { p_company: company, p_obj: obj, p_prefix: prefix, p_next: next, p_pad: pad, p_active: active });

export const useCompanyInfo = (company: string) => useQuery({
  queryKey: ['adm-company', company], enabled: Boolean(company), queryFn: () => rpc<CompanyInfo>('company_details_info', { p_company: company }),
});
export const companySubmit = (company: string, changes: Partial<Profile>, reason: string) =>
  rpc<{ request_id: number; approver_position: string }>('company_details_submit', { p_company: company, p_changes: changes, p_reason: reason || null });
export const companyDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string) =>
  rpc('company_details_decide', { p_company: company, p_request_id: id, p_decision: decision, p_note: note || null });
export const companyCancel = (company: string, id: number) => rpc('company_details_cancel', { p_company: company, p_request_id: id });
export const adminSettingSave = (company: string, p: { owner_position?: string | null; fx_currencies?: string[] }) =>
  rpc('admin_setting_save', { p_company: company, p });
export const BRANDING_BUCKET = 'branding';
export async function uploadLogo(company: string, file: File) {
  const path = `${company}/${Date.now()}-${file.name.replace(/[^A-Za-z0-9._-]/g, '_')}`;
  const { error } = await supabase.storage.from(BRANDING_BUCKET).upload(path, file, { upsert: false });
  if (error) throw new ApiError({ message: error.message });
  return path;
}

export const useFxSetup = (company: string) => useQuery({
  queryKey: ['adm-fx-setup', company], enabled: Boolean(company), queryFn: () => rpc<FxSetup>('fx_setup', { p_company: company }),
});
export const fxSave = (company: string, date: string, currency: string, rate: number) =>
  rpc('fx_rate_save', { p_company: company, p_date: date, p_currency: currency, p_rate: rate });
export const fxImport = (company: string, rows: Array<{ date: string; currency: string; rate: string }>) =>
  rpc<{ saved: number; errors: Array<{ row: number; message: string }> }>('fx_rate_import', { p_company: company, p_rows: rows });

export const useSanaSetup = (company: string) => useQuery({
  queryKey: ['adm-sana', company], enabled: Boolean(company), queryFn: () => rpc<SanaSetup>('sana_setup', { p_company: company }),
});
export const sanaSave = (company: string, p: Record<string, unknown>) => rpc<{ enabled: boolean }>('sana_settings_save', { p_company: company, p });

/** Parse "date,currency,rate" CSV text (header optional; comma or semicolon). */
export function parseRatesCsv(text: string) {
  const rows: Array<{ date: string; currency: string; rate: string }> = [];
  for (const raw of text.replace(/^\uFEFF/, '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const [date = '', currency = '', rate = ''] = line.split(/[;,\t]/).map((s) => s.trim().replace(/^"|"$/g, ''));
    if (/^date$/i.test(date)) continue;
    rows.push({ date, currency: currency.toUpperCase(), rate });
  }
  return rows;
}
