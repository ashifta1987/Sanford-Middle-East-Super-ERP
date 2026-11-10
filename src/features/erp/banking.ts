import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** Types and calls for A5 Banking (supabase/sql/20_banking.sql). The database is the authority. */
export type Dir = 'I' | 'O';
export const dirOf = (p: string | undefined): Dir => (p === 'out' ? 'O' : 'I');
export const dirPath = (d: Dir) => (d === 'O' ? 'out' : 'in');
export type DraftState = 'pending_approval' | 'posted' | 'rejected' | 'cancelled';

export interface BankRef { bank_code: string; name: string; acct_code: string; bank_name?: string | null }
export interface PaySetup {
  currency: string; can_write: boolean; banks: BankRef[]; accounts: { cash: boolean; cheque: boolean; card: boolean };
  numbering: boolean; my_limit: number | null; bank_change_days: number | null; needs_approval?: boolean | null;
}
export interface OpenDoc { obj_type: number; doc_entry: number; doc_no: string; doc_date: string; due_date: string; total: number; open: number; reserved: number; sign: 1 | -1 }
export interface OpenDocs { card_code: string; card_name: string; currency: string | null; balance: number; bank_changed_at: string | null; docs: OpenDoc[]; other_open: number }
export interface PayProblem { line: number | null; field: string; message: string }
export interface PayCheck { rule_code: 'payment_amount' | 'bank_change' | 'incoming_payment'; step: number; approver_position: string; approver_name: string; value: number | string; limit: number; message: string }
export interface PayEval { errors: PayProblem[]; checks: PayCheck[]; totals: { total: number; applied: number; on_account: number; currency: string } }
export interface ChequeInput { cheque_no: string; bank_name: string; due_date: string; amount: string }
export interface PayHeaderInput {
  card_code: string; doc_date: string; memo: string; cash: string; transfer: string; transfer_bank: string; transfer_ref: string;
  cheques: ChequeInput[]; cheque_bank: string; card: string; card_ref: string;
}
export interface PayLineInput { obj_type: number; doc_entry: number; amount: string }
export interface Activity { at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }
export interface Approval {
  approval_id: number; step: number; rule_code: string; approver_position: string; approver_position_name: string;
  decision: 'approved' | 'rejected' | null; note: string | null; decided_at: string | null; decided_by_name: string | null; decided_by_me: boolean;
  requested_at: string | null; superseded: boolean; current: boolean; mine: boolean; detail: { checks?: PayCheck[] } | null;
}
export interface DraftInfo {
  draft_id: number; company_code: string; direction: Dir; state: DraftState; doc_date: string; card_code: string; card_name: string | null;
  total: number; currency: string | null; reason: string | null; doc_entry: number | null; doc_no: string | null; created_by_name: string | null;
  created_at: string; cancel_note: string | null; cancelled_at: string | null; decided_at: string | null; is_creator: boolean; can_cancel: boolean; can_decide: boolean;
  header: { cash: number; transfer: number; transfer_bank: string | null; transfer_ref: string | null; cheque_total: number; cheque_bank: string | null; memo: string | null;
            cheques: Array<{ cheque_no: string; due_date: string; amount: number }> };
  lines: Array<{ obj_type: number; doc_entry: number; doc_no: string; amount: number; sign: number }>;
  checks: PayCheck[] | null; approvals: Approval[]; activity: Activity[];
}
export interface PaymentInfo {
  company_code: string; direction: Dir; doc_entry: number; doc_num: number; doc_no: string; doc_type: string | null; doc_date: string;
  card_code: string | null; card_name: string | null; currency: string | null; total: number; cash: number | null; transfer: number | null; cheque: number | null;
  card: number | null; on_account: number | null; cancelled: boolean; trans_id: number | null; memo: string | null; source: string;
  transfer_bank: string | null; transfer_bank_name: string | null; transfer_ref: string | null; cheque_bank: string | null; card_ref: string | null; draft_id: number | null;
  created_by_name: string | null; created_at: string | null; cancelled_at: string | null; cancel_note: string | null; cancel_trans_id: number | null;
  can_read_journal: boolean; can_cancel: boolean; cancel_block: string | null;
  allocations: Array<{ line_no: number; obj_type: number; doc_entry: number; doc_no: string | null; applied: number; doc_total: number | null; doc_date: string | null }>;
  cheques: Array<{ cheque_id: number; cheque_no: string; bank_name: string | null; due_date: string; amount: number; post_dated: boolean; deposit_id: number | null; deposit_no: string | null }>;
  activity: Activity[];
}
export interface DepositCheque { cheque_id: number; cheque_no: string; bank_name: string | null; due_date: string; amount: number; doc_entry: number; doc_no: string; card_code: string; card_name: string; payment_date: string }
export interface DepositSetup { currency: string; can_write: boolean; numbering: boolean; banks: BankRef[]; cash_acct: string | null; cheque_acct: string | null; cash_on_hand: number | null; cheques: DepositCheque[] }
export interface JlSource { kind: 'payment' | 'deposit' | 'document'; direction?: Dir; doc_entry: number; doc_no?: string | null; obj_type?: number }
export interface StatementLine {
  line_id: number; line_no: number; value_date: string; description: string | null; reference: string | null; amount: number;
  match: { match_no: number; trans_id: number; jl_line_id: number; how: 'auto' | 'manual'; matched_at: string; memo: string | null; ref_date: string; source: JlSource | null } | null;
}
export interface StatementInfo {
  statement_id: number; company_code: string; bank_code: string; bank_name: string | null; acct_code: string | null; file_name: string | null;
  from_date: string | null; to_date: string | null; lines_imported: number; lines_skipped: number; imported_at: string; imported_by_name: string | null;
  currency: string; can_write: boolean; match_days: number | null; lines: StatementLine[];
}
export interface Candidate { trans_id: number; line_id: number; ref_date: string; amount: number; memo: string | null; ref1: string | null; days: number; source: JlSource | null }
export interface CashPosition {
  company_code: string; currency: string; as_of: string; total: number;
  accounts: Array<{ bank_code: string; name: string; kind: 'bank' | 'cash'; acct_code: string; bank_name: string | null; iban: string | null; currency: string | null;
                    balance: number; unmatched: number; unmatched_amount: number; last_statement: string | null }>;
  cheque_acct: { acct_code: string; balance: number } | null; card_acct: { acct_code: string; balance: number } | null;
  cheques: { count: number; amount: number; due_count: number; due_amount: number; post_dated_count: number; post_dated_amount: number };
  pending_out: { count: number; amount: number };
}
export interface StatementRow { date: string; description: string; reference: string; amount: string }

export const usePaySetup = (company: string | null, dir: Dir) => useQuery({
  queryKey: ['pay-setup', company, dir], enabled: Boolean(company), staleTime: 60_000,
  queryFn: () => rpc<PaySetup>('payment_setup', { p_company: company, p_dir: dir }),
});
export const useOpenDocs = (company: string, dir: Dir, card: string) => useQuery({
  queryKey: ['pay-open', company, dir, card], enabled: Boolean(company && card),
  queryFn: () => rpc<OpenDocs>('payment_open_docs', { p_company: company, p_dir: dir, p_card: card }),
});
export const usePaymentInfo = (company: string, dir: Dir, entry: number) => useQuery({
  queryKey: ['pay-info', company, dir, entry], enabled: Boolean(company && entry),
  queryFn: () => rpc<PaymentInfo | null>('payment_info', { p_company: company, p_dir: dir, p_doc_entry: entry }),
});
export const useDraftInfo = (company: string, id: number) => useQuery({
  queryKey: ['pay-draft', company, id], enabled: Boolean(company && id),
  queryFn: () => rpc<DraftInfo | null>('payment_draft_info', { p_company: company, p_draft_id: id }),
});
export const useDepositSetup = (company: string | null) => useQuery({
  queryKey: ['dep-setup', company], enabled: Boolean(company),
  queryFn: () => rpc<DepositSetup>('deposit_setup', { p_company: company }),
});
export const useStatementInfo = (company: string, id: number) => useQuery({
  queryKey: ['stmt', company, id], enabled: Boolean(company && id),
  queryFn: () => rpc<StatementInfo | null>('bank_statement_info', { p_company: company, p_statement_id: id }),
});
export const useCashPosition = (company: string | null) => useQuery({
  queryKey: ['cash-position', company], enabled: Boolean(company),
  queryFn: () => rpc<CashPosition>('cash_position', { p_company: company }),
});

/** The header as the database expects it (numbers as strings are parsed and checked there). */
const header = (h: PayHeaderInput) => ({ ...h, cheques: h.cheques.filter((c) => c.cheque_no.trim() || c.amount.trim() || c.due_date) });
export const payChecks = (company: string, dir: Dir, h: PayHeaderInput, lines: PayLineInput[]) =>
  rpc<PayEval>('payment_checks', { p_company: company, p_dir: dir, p_header: header(h), p_lines: lines });
export const paySubmit = (company: string, dir: Dir, h: PayHeaderInput, lines: PayLineInput[], reason: string | null, series: number | null = null) =>
  rpc<{ state: 'posted' | 'pending_approval'; doc_entry?: number; doc_no?: string; draft_id?: number; trans_id?: number }>('payment_submit', {
    p_company: company, p_dir: dir, p_header: header(h), p_lines: lines, p_reason: reason, p_series: series,
  });
export const payDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: DraftState; doc_entry: number | null; doc_no: string | null; direction: Dir }>('payment_decide', { p_company: company, p_draft_id: id, p_decision: decision, p_note: note });
export const payDraftCancel = (company: string, id: number, note: string) =>
  rpc<{ state: DraftState }>('payment_draft_cancel', { p_company: company, p_draft_id: id, p_note: note });
export const payCancel = (company: string, dir: Dir, entry: number, date: string, reason: string) =>
  rpc<{ trans_id: number }>('payment_cancel', { p_company: company, p_dir: dir, p_doc_entry: entry, p_date: date, p_reason: reason });
export const depositCreate = (company: string, h: { deposit_date: string; bank_code: string; cash_amount: string; memo: string }, cheques: number[], series: number | null = null) =>
  rpc<{ deposit_id: number; doc_no: string; total: number; trans_id: number }>('deposit_create', { p_company: company, p_header: h, p_cheques: cheques, p_series: series });
export const statementImport = (company: string, bank: string, file: string, rows: StatementRow[]) =>
  rpc<{ statement_id: number | null; imported: number; skipped: number }>('bank_statement_import', { p_company: company, p_bank_code: bank, p_file_name: file, p_rows: rows });
export const autoMatch = (company: string, id: number) => rpc<{ matched: number; unmatched: number }>('bank_statement_auto_match', { p_company: company, p_statement_id: id });
export const candidates = (company: string, line: number) => rpc<Candidate[]>('bank_statement_candidates', { p_company: company, p_line_id: line });
export const matchLine = (company: string, line: number, trans: number, jl: number) =>
  rpc<{ match_no: number }>('bank_statement_match', { p_company: company, p_line_id: line, p_trans_id: trans, p_jl_line_id: jl });
export const unmatchLine = (company: string, line: number) => rpc<{ unmatched: boolean }>('bank_statement_unmatch', { p_company: company, p_line_id: line });
export const bankAccountSave = (company: string, a: Record<string, unknown>) => rpc<Record<string, unknown>>('bank_account_save', { p_company: company, p_acct: a });
export const bankingSettingSet = (company: string, s: Record<string, unknown>) => rpc<Record<string, unknown>>('banking_setting_set', { p_company: company, p_setting: s });
export const bpBankSave = (company: string, card: string, b: Record<string, unknown>) =>
  rpc<{ bp_bank_id: number | null; change: string; request_id?: number; state?: string }>('bp_bank_account_save', { p_company: company, p_card: card, p_bank: b });

export interface BpHit { card_code: string; name: string; kind: string; currency: string | null; balance: number | null }
const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();
/** Customers (I) or suppliers (O) for the payment form; any kind when kind is null. */
export async function searchPartners(company: string, kind: 'customer' | 'supplier' | null, q: string) {
  const s = clean(q);
  let qb = erp().from('business_partner').select('card_code,name,kind,currency,balance').eq('company_code', company).eq('active', true);
  if (kind) qb = qb.eq('kind', kind);
  if (s) qb = qb.or(`card_code.ilike.*${s}*,name.ilike.*${s}*,phone.ilike.*${s}*,trn.ilike.*${s}*`);
  const { data, error } = await qb.order('card_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as BpHit[];
}

/** Parse a bank CSV in the browser: delimiter , ; or tab, quoted fields, first row = headers. */
export function parseCsv(text: string): { headers: string[]; rows: string[][] } {
  const src = text.replace(/^\uFEFF/, '');
  const first = src.split(/\r?\n/, 1)[0] ?? '';
  const delim = [';', '\t', ','].map((d) => [d, first.split(d).length] as const).sort((a, b) => b[1] - a[1])[0][0];
  const out: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let q = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (q) {
      if (ch === '"' && src[i + 1] === '"') { cell += '"'; i++; } else if (ch === '"') q = false; else cell += ch;
    } else if (ch === '"') q = true;
    else if (ch === delim) { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++;
      row.push(cell); cell = '';
      if (row.some((c) => c.trim() !== '')) out.push(row);
      row = [];
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim() !== '')) out.push(row);
  const [headers = [], ...rows] = out;
  return { headers: headers.map((h) => h.trim()), rows };
}
export type DateFormat = 'YYYY-MM-DD' | 'DD/MM/YYYY' | 'MM/DD/YYYY' | 'DD-MM-YYYY' | 'DD.MM.YYYY';
/** A date in the chosen format → YYYY-MM-DD, or the text unchanged (the database then names the bad row). */
export function toIsoDate(s: string, f: DateFormat): string {
  const v = s.trim();
  const m = v.match(/^(\d{1,4})[-/.](\d{1,2})[-/.](\d{1,4})/);
  if (!m) return v;
  const [a, b, c] = [m[1], m[2], m[3]];
  const pad = (x: string) => x.padStart(2, '0');
  if (f === 'YYYY-MM-DD') return a.length === 4 ? `${a}-${pad(b)}-${pad(c)}` : v;
  if (c.length !== 4) return v;
  return f === 'MM/DD/YYYY' ? `${c}-${pad(a)}-${pad(b)}` : `${c}-${pad(b)}-${pad(a)}`;
}
/** "1,234.50", "(12.00)", "12.00-" → a plain number string. */
export function toAmount(s: string | undefined): string {
  if (s === undefined) return '';
  let v = s.trim().replace(/[\s,]/g, '').replace(/[A-Z]{3}$/i, '');
  let neg = false;
  if (/^\(.*\)$/.test(v)) { neg = true; v = v.slice(1, -1); }
  if (v.endsWith('-')) { neg = true; v = v.slice(0, -1); }
  if (v === '') return '';
  return neg && !v.startsWith('-') ? `-${v}` : v;
}
