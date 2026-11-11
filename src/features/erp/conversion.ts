import { useQuery } from '@tanstack/react-query';
import { rpc } from './api';

/** Types and calls for B6 · system currency and Financials › Conversion Differences (supabase/sql/35_final_items.sql). The database is the authority. */
export interface SysCurInfo {
  company_code: string; local_currency: string; system_currency: string; active: boolean; currencies: string[]; can_write: boolean;
  locked: boolean; journals: number; rate_today: number | null; updated_by_name: string | null; updated_at: string | null;
}
export const useSysCur = (company: string) =>
  useQuery({ queryKey: ['sys-cur', company], enabled: Boolean(company), queryFn: () => rpc<SysCurInfo>('system_currency_info', { p_company: company }) });
export const sysCurSave = (company: string, currency: string) =>
  rpc<{ system_currency: string; active: boolean; changed: boolean }>('system_currency_save', { p_company: company, p_currency: currency });

export interface CvdRow {
  kind: 'account' | 'partner'; acct_code: string; acct_name: string | null; card_code: string | null; card_name: string | null;
  lc_balance: number; sc_balance: number; journals: number;
}
export interface CvdPreview {
  date: string; accounts: boolean; partners: boolean; local_currency: string; sys_currency: string; acct_code: string | null; rows: CvdRow[];
  totals: { rows: number; debit: number; credit: number; net: number };
}
export interface CvdListRow {
  run_id: number; company_code: string; doc_no: string; run_date: string; accounts: boolean; partners: boolean; sys_currency: string;
  debit: number; credit: number; trans_id: number | null; cancel_trans_id: number | null; state: 'posted' | 'cancelled'; memo: string | null;
  created_at: string; created_by_name: string | null; lines: number;
}
export interface CvdSetup {
  company_code: string; local_currency: string; sys_currency: string; active: boolean; can_write: boolean; acct_code: string | null; history: CvdListRow[];
}
export interface CvdJournalLine { acct_code: string; short_name: string | null; debit: number; credit: number; sys_debit: number | null; sys_credit: number | null; memo: string | null }
export interface CvdInfo extends Omit<CvdListRow, 'lines' | 'created_by_name'> {
  local_currency: string; acct_code: string | null; created_by_name: string | null; cancelled_by_name: string | null; cancelled_at: string | null;
  cancel_reason: string | null; can_cancel: boolean;
  lines: Array<CvdRow & { line_no: number }>;
  journals: Array<{ trans_id: number; ref_date: string; memo: string | null; total: number; total_sys: number; lines: CvdJournalLine[] }>;
  activity: Array<{ at: string; action: string; actor_name: string }>;
}
export interface CvdInput { date: string; accounts: boolean; partners: boolean; memo?: string }

export const useCvdSetup = (company: string) =>
  useQuery({ queryKey: ['cvd-setup', company], enabled: Boolean(company), queryFn: () => rpc<CvdSetup>('conversion_diff_setup', { p_company: company }) });
export const cvdPreview = (company: string, i: CvdInput) => rpc<CvdPreview>('conversion_diff_preview', { p_company: company, p_in: i });
export const cvdPost = (company: string, i: CvdInput) =>
  rpc<{ run_id: number; doc_no: string; trans_id: number; rows: number; net: number }>('conversion_diff_post', { p_company: company, p_in: i });
export const cvdCancel = (company: string, id: number, reason: string) =>
  rpc<{ state: 'cancelled' }>('conversion_diff_cancel', { p_company: company, p_run_id: id, p_reason: reason });
export const useCvdInfo = (company: string, id: number) =>
  useQuery({ queryKey: ['cvd-info', company, id], enabled: Boolean(company && id), queryFn: () => rpc<CvdInfo | null>('conversion_diff_info', { p_company: company, p_run_id: id }) });
