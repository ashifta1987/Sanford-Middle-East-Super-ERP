import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** Types and calls for the A3 posting engine (supabase/sql/18_posting.sql). The database is the authority. */
export type JeState = 'draft' | 'pending_approval' | 'posted' | 'rejected' | 'cancelled';
export type PeriodStatus = 'open' | 'closed' | 'locked';

export interface JeSetup { currency: string; can_write: boolean; my_limit: number | null; has_periods: boolean }
export interface JeProblem { line: number | null; field: string; message: string }
export interface JeCheck { rule_code: 'journal_amount'; step: number; approver_position: string; approver_name: string; value: number; limit: number; message: string }
export interface JeTotals { debit: number; credit: number; difference: number; currency: string }
export interface JeEval { errors: JeProblem[]; checks: JeCheck[]; totals: JeTotals }
export interface JeHeaderInput { ref_date: string; due_date: string; memo: string; ref1: string }
export interface JeLineInput { acct_code: string; debit: string; credit: string; memo: string }
export interface JeApproval {
  approval_id: number; step: number; rule_code: string; approver_position: string; approver_position_name: string;
  decision: 'approved' | 'rejected' | null; note: string | null; decided_at: string | null; decided_by_name: string | null; decided_by_me: boolean;
  requested_at: string | null; superseded: boolean; current: boolean; mine: boolean; detail: { checks?: JeCheck[] } | null;
}
export interface JeActivity { at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }
export interface JeDraftInfo {
  draft_id: number; company_code: string; state: JeState; ref_date: string | null; due_date: string | null; memo: string | null;
  ref1: string | null; ref2: string | null; total: number; currency: string | null; trans_id: number | null; posted_at: string | null;
  reason: string | null; cancel_note: string | null; cancelled_at: string | null; created_by_name: string | null; created_at: string;
  submitted_by_name: string | null; submitted_at: string | null; is_creator: boolean; is_submitter: boolean;
  can_edit: boolean; can_cancel: boolean; can_decide: boolean;
  lines: Array<{ line_num: number; acct_code: string | null; acct_name: string | null; debit: number; credit: number; memo: string | null }>;
  approvals: JeApproval[]; activity: JeActivity[];
}
export interface JournalInfo {
  trans_id: number; source: string; reversal_of: number | null; reversed_by: number | null; draft_id: number | null;
  document: { obj_type: number; doc_entry: number } | null; can_reverse: boolean; reverse_block: string | null; activity: JeActivity[];
}
export interface AccountHit { acct_code: string; format_code: string | null; name: string; frozen: boolean; is_control: boolean }

export const useJeSetup = (company: string | null) => useQuery({
  queryKey: ['je-setup', company], enabled: Boolean(company), staleTime: 60_000,
  queryFn: () => rpc<JeSetup>('journal_setup', { p_company: company }),
});
export const useJeDraftInfo = (company: string, id: number) => useQuery({
  queryKey: ['je-draft', company, id], enabled: Boolean(company && id),
  queryFn: () => rpc<JeDraftInfo | null>('journal_draft_info', { p_company: company, p_draft_id: id }),
});
export const useJournalInfo = (company: string, id: number) => useQuery({
  queryKey: ['je-info', company, id], enabled: Boolean(company && id),
  queryFn: () => rpc<JournalInfo | null>('journal_info', { p_company: company, p_trans_id: id }),
});

const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();
/** Postable accounts for the account combobox (code, account number or name). */
export async function searchAccounts(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('account').select('acct_code,format_code,name,frozen,is_control').eq('company_code', company).eq('postable', true);
  if (s) qb = qb.or(`acct_code.ilike.*${s}*,format_code.ilike.*${s}*,name.ilike.*${s}*`);
  const { data, error } = await qb.order('acct_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as AccountHit[];
}

const lines = (ls: JeLineInput[]) => ls.map((l) => ({ acct_code: l.acct_code, debit: l.debit, credit: l.credit, memo: l.memo }));
export const jeChecks = (company: string, h: JeHeaderInput, ls: JeLineInput[]) =>
  rpc<JeEval>('journal_checks', { p_company: company, p_header: h, p_lines: lines(ls) });
export const jeSave = (company: string, id: number | null, h: JeHeaderInput, ls: JeLineInput[]) =>
  rpc<{ draft_id: number; state: JeState }>('journal_draft_save', { p_company: company, p_draft_id: id, p_header: h, p_lines: lines(ls) });
export const jeSubmit = (company: string, id: number, reason: string | null) =>
  rpc<{ draft_id: number; state: JeState; trans_id?: number }>('journal_submit', { p_company: company, p_draft_id: id, p_reason: reason });
export const jeDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: JeState; trans_id: number | null }>('journal_decide', { p_company: company, p_draft_id: id, p_decision: decision, p_note: note });
export const jeCancel = (company: string, id: number, note: string) =>
  rpc<{ state: JeState }>('journal_draft_cancel', { p_company: company, p_draft_id: id, p_note: note });
export const jeReverse = (company: string, trans: number, date: string, reason: string) =>
  rpc<{ trans_id: number; reversal_of: number }>('journal_reverse', { p_company: company, p_trans_id: trans, p_date: date, p_reason: reason });
export const periodSetStatus = (company: string, period: string, status: PeriodStatus) =>
  rpc<{ status: PeriodStatus }>('period_set_status', { p_company: company, p_period: period, p_status: status });
export const periodAddYear = (company: string, year: number) => rpc<{ year: number }>('period_add_year', { p_company: company, p_year: year });
export const glSet = (company: string, area: string, key: string, acct: string | null) =>
  rpc<{ acct_code: string | null }>('gl_determination_set', { p_company: company, p_area: area, p_key: key, p_acct: acct });

export const round2 = (n: number) => Math.round(n * 100) / 100;
export function todayIso() {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 10);
}
