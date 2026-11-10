import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { rpc } from './api';

/** Types and calls for A9 HR and Staff Portal (supabase/sql/24_hr.sql). The database checks every read of salary and every write. */

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = Record<string, any>;
export type LeaveState = 'pending_approval' | 'approved' | 'rejected' | 'cancelled';
export type RunState = 'draft' | 'reviewed' | 'locked' | 'posted';
export interface FieldError { field: string | null; message: string }
export interface Balance {
  leave_code: string; name: string; tracked: boolean; accrual: string; annual_days: number | null;
  entitled: number | null; adjusted: number; taken: number; pending: number; available: number | null;
}
export interface Shift { shift_code: string; name: string; start_time: string; end_time: string; grace_min: number; departments: string[]; active: boolean }
export interface Step { step: number; rule_code: string; approver_position: string; approver_name: string; message: string }

export interface PortalMe {
  linked: boolean; display_name?: string; today: string; timezone: string; currency: string;
  employee: { emp_id: number; hr_code: string; name: string; job_title: string | null; department: string | null; mobile: string | null; email: string | null;
              joined_on: string | null; nationality: string | null; manager_name: string | null; source: string };
  shift: Shift | null; site: { site_code: string; name: string; radius_m: number } | null;
  duties: Array<{ duty_id: number; title: string; detail: string | null }>;
  attendance_today: { check_in_at: string; check_out_at: string | null; in_flags: string[]; out_flags: string[]; late_min: number; in_distance_m: number | null } | null;
  attendance: Array<{ work_date: string; check_in_at: string; check_out_at: string | null; flags: string[] }>;
  balances: Balance[]; leave_types: Array<{ code: string; name: string; basis: string }>;
  requests: Array<{ request_id: number; leave_code: string; from_date: string; to_date: string; days: number; state: LeaveState }>;
  payslips: Array<{ run_id: number; period: string; net: number; state: RunState }>;
  documents: Array<{ doc_id: number; doc_type: string; doc_no: string | null; expires_on: string | null; storage_path: string | null; file_name: string | null; days_left: number | null }>;
  team_waiting: number; is_manager: boolean;
}
export function usePortal(company: string) {
  return useQuery({ queryKey: ['hr-portal', company], enabled: Boolean(company), queryFn: () => rpc<PortalMe>('portal_me', { p_company: company }) });
}
export interface CheckResult { kind: 'in' | 'out'; flags: string[]; distance_m: number | null; site_name: string | null; message: string }
export const attendanceCheck = (company: string, kind: 'in' | 'out', pos: GeolocationCoordinates | null) =>
  rpc<CheckResult>('attendance_check', { p_company: company, p_kind: kind, p_lat: pos?.latitude ?? null, p_lng: pos?.longitude ?? null, p_accuracy: pos?.accuracy ?? null });

/** The browser's location, or null when the user refuses or it takes too long (the check-in is then flagged, not blocked). */
export function currentPosition(timeoutMs = 10000): Promise<GeolocationCoordinates | null> {
  return new Promise((resolve) => {
    if (!('geolocation' in navigator)) { resolve(null); return; }
    navigator.geolocation.getCurrentPosition((p) => resolve(p.coords), () => resolve(null), { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 0 });
  });
}

export interface LeaveEval { errors: FieldError[]; days: number | null; balance: Balance | null; steps: Step[]; emp_id: number; emp_name: string }
export const leaveChecks = (company: string, leave: Any) => rpc<LeaveEval>('leave_checks', { p_company: company, p_leave: leave });
export const leaveSubmit = (company: string, leave: Any) => rpc<{ request_id: number; state: LeaveState; steps: Step[] }>('leave_submit', { p_company: company, p_leave: leave });
export const leaveDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: LeaveState }>('leave_decide', { p_company: company, p_request: id, p_decision: decision, p_note: note });
export const leaveCancel = (company: string, id: number, note: string | null) => rpc<{ state: LeaveState }>('leave_cancel', { p_company: company, p_request: id, p_note: note });
export interface LeaveInfo {
  request: Any; balance: Balance; can_decide: boolean; can_cancel: boolean;
  approvals: Array<{ approval_id: number; step: number; rule_code: string; approver_name: string; message: string; decision: string | null; note: string | null;
                     decided_at: string | null; decided_by_name: string | null; superseded: boolean }>;
  history: Array<{ at: string; action: string; actor: string | null; detail: Any | null }>;
}
export function useLeaveInfo(company: string, id: number) {
  return useQuery({ queryKey: ['hr-leave', company, id], enabled: Boolean(company && id), queryFn: () => rpc<LeaveInfo>('leave_info', { p_company: company, p_request: id }) });
}

export interface EmployeeInfo {
  employee: Any; hr: Any; documents: Any[]; sap_documents: Any[]; balances: Balance[]; leave: Any[]; attendance: Any[];
  currency: string; can_edit: boolean; can_edit_hr: boolean; edit_reason: 'read_only' | 'sap' | null; salary_visible: boolean;
  bank?: { iban: string | null; bank_routing: string | null; mol_person_id: string | null; wps_bank: string | null };
  pay?: Array<{ wage_code: string; name: string | null; amount: number; valid_from: string; source: string }>;
  pay_history?: Array<{ wage_code: string; amount: number; valid_from: string; note: string | null }>;
  ticket_entitlement?: Any; gratuity?: Any; ticket?: Any;
  history?: Array<{ at: string; action: string; actor: string | null; detail: Any | null }>;
}
export function useEmployeeInfo(company: string, id: number) {
  return useQuery({ queryKey: ['hr-emp', company, id], enabled: Boolean(company && id), queryFn: () => rpc<EmployeeInfo>('hr_employee_info', { p_company: company, p_emp_id: id }) });
}
export const employeeSave = (company: string, emp: Any, series: number | null = null) => rpc<{ emp_id: number; hr_code: string }>('hr_employee_save', { p_company: company, p_emp: emp, p_series: series });
export const employeeExtraSave = (company: string, id: number, extra: Any) => rpc<{ saved: boolean }>('hr_employee_extra_save', { p_company: company, p_emp_id: id, p_extra: extra });
export const paySet = (company: string, id: number, wage: string, amount: number, from: string, note: string | null) =>
  rpc('hr_pay_set', { p_company: company, p_emp_id: id, p_wage_code: wage, p_amount: amount, p_valid_from: from, p_note: note });
export const documentSave = (company: string, doc: Any) => rpc<{ doc_id: number }>('hr_document_save', { p_company: company, p_doc: doc });

export const HR_BUCKET = 'hr-docs';
export async function uploadHrFile(company: string, empId: number, file: File) {
  const safe = file.name.replace(/[^A-Za-z0-9._-]+/g, '_');
  const path = `${company}/${empId}/${Date.now()}-${safe}`;
  const { error } = await supabase.storage.from(HR_BUCKET).upload(path, file, { upsert: false });
  if (error) throw error;
  return path;
}
/** Signed links last 10 minutes (600 s) at most. */
export async function openHrFile(path: string) {
  const { data, error } = await supabase.storage.from(HR_BUCKET).createSignedUrl(path, 600);
  if (error) throw error;
  window.open(data.signedUrl, '_blank', 'noopener');
}

export interface HrSetup {
  setting: Any | null; sites: Any[]; shifts: Shift[]; duties: Any[]; holidays: Array<{ day: string; name: string }>;
  leave_types: Array<Any & { policy: Any | null }>; wage_types: Any[]; wps_banks: Any[]; positions: Array<{ code: string; name: string }>;
  departments: string[]; employees: Array<{ emp_id: number; hr_code: string; name: string; department: string | null }>;
  branches: Array<{ id: number; name: string }>; can_edit: boolean; can_payroll: boolean; can_set_account: boolean;
}
export function useHrSetup(company: string, enabled = true) {
  return useQuery({ queryKey: ['hr-setup', company], enabled: Boolean(company) && enabled, queryFn: () => rpc<HrSetup>('hr_setup', { p_company: company }) });
}
export const setupSave = (company: string, kind: string, data: Any) => rpc<{ kind: string; ref: string }>('hr_setup_save', { p_company: company, p_kind: kind, p_data: data });

export interface PayrollInfo {
  run: Any; employees: Array<Any & { lines: Any[]; errors: string[] }>; inputs: Any[]; banks: Array<{ bank_code: string; name: string }>;
  journal: Array<{ acct_code: string; name: string | null; debit: number; credit: number }> | null; history: Any[];
}
export function usePayroll(company: string, id: number) {
  return useQuery({ queryKey: ['hr-payroll', company, id], enabled: Boolean(company && id), queryFn: () => rpc<PayrollInfo>('payroll_info', { p_company: company, p_run_id: id }) });
}
export const payrollCalculate = (company: string, period: string) => rpc<{ run_id: number; headcount: number; net: number; skipped: Any[] }>('payroll_calculate', { p_company: company, p_period: period });
export const payrollStep = (company: string, id: number, action: 'review' | 'reopen' | 'lock') => rpc<{ state: RunState }>('payroll_step', { p_company: company, p_run_id: id, p_action: action });
export const payrollPost = (company: string, id: number) => rpc<{ trans_id: number }>('payroll_post', { p_company: company, p_run_id: id });
export const payrollInputSave = (company: string, input: Any) => rpc('payroll_input_save', { p_company: company, p_input: input });
export const payrollInputRemove = (company: string, id: number) => rpc('payroll_input_remove', { p_company: company, p_input_id: id });
export const wpsCheck = (company: string, id: number, bank: string) =>
  rpc<{ errors: Array<{ field: string; message: string; emp_id?: number }>; count: number; total: number; currency: string }>('wps_check', { p_company: company, p_run_id: id, p_bank: bank });
export const wpsFile = (company: string, id: number, bank: string) =>
  rpc<{ file_name: string; content: string; count: number; total: number }>('wps_file', { p_company: company, p_run_id: id, p_bank: bank });
export interface Payslip { period: string; from_date: string; to_date: string; state: RunState; company: { code: string; name: string; currency: string }; employee: Any; job_title: string | null; lines: Any[] }
export function usePayslip(company: string, run: number, emp?: number) {
  return useQuery({ queryKey: ['hr-payslip', company, run, emp], enabled: Boolean(company && run),
    queryFn: () => rpc<Payslip>('portal_payslip', { p_company: company, p_run_id: run, p_emp_id: emp ?? null }) });
}

/** Save a text file in the browser (WPS SIF). */
export function downloadText(name: string, content: string) {
  const url = URL.createObjectURL(new Blob([content], { type: 'text/plain;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
