import { useQuery } from '@tanstack/react-query';
import { rpc } from './api';

/** Types and calls for B5 · Financials › Exchange Rate Differences (supabase/sql/34_open_items.sql). The database is the authority. */
export interface FxrRow {
  card_code: string; card_name: string | null; side: 'receivable' | 'payable'; currency: string; docs: number; open_fc: number; book_lc: number;
  rate: number; new_lc: number; diff: number; gain: number;
}
export interface FxrPreview {
  date: string; currencies: string[]; rates: Record<string, { rate: number; list_rate: number | null; overridden: boolean }>; local_currency: string;
  reverse_date: string; rows: FxrRow[]; totals: { gain: number; loss: number; net: number; partners: number };
  already: { reval_id: number; doc_no: string; date: string } | null; later: { reval_id: number; doc_no: string; date: string } | null;
}
export interface FxrListRow {
  reval_id: number; company_code: string; doc_no: string; reval_date: string; currencies: string[]; auto_reverse: boolean; reverse_date: string | null;
  trans_id: number | null; reverse_trans_id: number | null; gain: number; loss: number; net: number; state: 'posted' | 'cancelled'; memo: string | null;
  created_at: string; created_by_name: string | null; lines: number;
}
export interface FxrSetup {
  company_code: string; local_currency: string; can_write: boolean; currencies: string[]; open_currencies: string[];
  gain_acct: string | null; loss_acct: string | null; history: FxrListRow[];
}
export interface FxrInfo extends Omit<FxrListRow, 'net' | 'lines' | 'created_by_name'> {
  rates: FxrPreview['rates']; local_currency: string; net: number; created_by_name: string | null; cancelled_by_name: string | null; cancelled_at: string | null;
  cancel_reason: string | null; can_cancel: boolean; cancel_trans_ids: number[] | null;
  lines: Array<FxrRow & { line_no: number; acct_code: string | null }>;
  journals: Array<{ trans_id: number; ref_date: string; memo: string | null; total: number; lines: Array<{ acct_code: string; short_name: string | null; debit: number; credit: number; memo: string | null }> }>;
  activity: Array<{ at: string; action: string; actor_name: string }>;
}
export interface FxrInput { date: string; currencies: string[]; rates: Record<string, string>; auto_reverse?: boolean; memo?: string }

const clean = (i: FxrInput) => ({
  date: i.date, currencies: i.currencies,
  rates: Object.fromEntries(Object.entries(i.rates).filter(([, v]) => v !== '' && v != null)),
  ...(i.auto_reverse !== undefined ? { auto_reverse: i.auto_reverse } : {}), ...(i.memo ? { memo: i.memo } : {}),
});

export const useFxrSetup = (company: string) =>
  useQuery({ queryKey: ['fxr-setup', company], enabled: Boolean(company), queryFn: () => rpc<FxrSetup>('fx_revaluation_setup', { p_company: company }) });
export const fxrPreview = (company: string, i: FxrInput) => rpc<FxrPreview>('fx_revaluation_preview', { p_company: company, p_in: clean(i) });
export const fxrPost = (company: string, i: FxrInput) =>
  rpc<{ reval_id: number; doc_no: string; trans_id: number; reverse_trans_id: number | null; net: number }>('fx_revaluation_post', { p_company: company, p_in: clean(i) });
export const fxrCancel = (company: string, id: number, reason: string) =>
  rpc<{ state: 'cancelled' }>('fx_revaluation_cancel', { p_company: company, p_reval_id: id, p_reason: reason });
export const useFxrInfo = (company: string, id: number) =>
  useQuery({ queryKey: ['fxr-info', company, id], enabled: Boolean(company && id), queryFn: () => rpc<FxrInfo | null>('fx_revaluation_info', { p_company: company, p_reval_id: id }) });
