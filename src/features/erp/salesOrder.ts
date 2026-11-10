import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/**
 * Types and calls for the sales quotation / order workflow (A2 17_sales_order.sql, generalised in A4 19_sales_cycle.sql).
 * The database is the authority.
 */
export type SalesKind = 'sales_order' | 'sales_quotation';
export const SALES_OBJ: Record<SalesKind, number> = { sales_order: 17, sales_quotation: 23 };
export type WorkflowState = 'draft' | 'pending_approval' | 'approved' | 'rejected' | 'cancelled';
export type RuleCode = 'discount_pct' | 'credit_limit' | 'below_cost' | 'journal_amount' | 'payment_amount' | 'bank_change' | 'po_amount' | 'po_price_increase'
  | 'stock_doc_amount' | 'count_variance_pct' | 'count_variance_value' | 'bp_credit_limit' | 'bp_bank_detail' | 'leave_manager' | 'leave_hr' | 'leave_long' | 'company_details' | 'credit_memo_amount' | 'incoming_payment';

export interface Code<T = string> { code: T; name: string }
export interface SoSetup {
  currency: string;
  tax_codes: Array<Code & { rate: number }>;
  warehouses: Code[];
  price_lists: Array<Code<number>>;
  payment_terms: Array<Code<number> & { days: number | null }>;
  salespersons: Array<Code<number>>;
  default_tax_code: string | null;
  default_whs_code: string | null;
  numbering: { prefix: string; next_num: number } | null;
  my_discount_limit: number | null;
  atp_on?: boolean;
  can_write: boolean;
}
export interface SoProblem { line: number | null; field: string; message: string }
export interface SoCheck {
  rule_code: RuleCode; step: number; approver_position: string; approver_name: string;
  line: number | null; value: number; limit: number; message: string;
}
export interface SoTotals { before_discount: number; discount: number; net: number; vat: number; total: number; currency: string; rate?: number | null; local_currency?: string; total_lc?: number | null; rate_overridden?: boolean }
export interface SoCredit { limit: number | null; balance: number; open_orders: number; this_order: number; left: number | null; currency?: string }
export interface AtpInfo { available: number | null; date: string; rule_code: string; no_check: boolean; on_hand?: number; committed?: number; purchase_orders?: number; transfers?: number }
export interface AtpShort { line: number; item_code: string; whs_code: string; qty: number; available: number; date: string; message: string }
export interface SoEvalLine { line_num: number; item_code: string; atp: AtpInfo | null; is_stock: boolean; price?: number | null; line_total?: number | null }
export interface SoEval { errors: SoProblem[]; checks: SoCheck[]; totals: SoTotals; credit: SoCredit | null; atp?: AtpShort[]; lines?: SoEvalLine[] }
export interface SoApproval {
  approval_id: number; step: number; rule_code: RuleCode; approver_position: string; approver_position_name: string;
  decision: 'approved' | 'rejected' | null; note: string | null; decided_at: string | null; decided_by_name: string | null; decided_by_me: boolean;
  requested_by_name: string | null; requested_at: string | null; superseded: boolean; current: boolean; mine: boolean;
  detail: { checks?: SoCheck[]; lines?: number[]; max_value?: number; limit?: number; approved_at?: number } | null;
}
export interface SoActivity { at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }
export interface SoInfo {
  workflow: boolean; source: string; doc_no?: string; state?: WorkflowState;
  created_by_name?: string; created_at?: string; submitted_by_name?: string | null; submitted_at?: string | null;
  reason?: string | null; cancel_note?: string | null; cancelled_at?: string | null;
  price_list?: number | null; payment_terms?: number | null; whs_code?: string | null;
  is_creator?: boolean; is_submitter?: boolean; can_edit?: boolean; can_submit?: boolean; can_cancel?: boolean; can_decide?: boolean;
  my_discount_limit?: number | null; requester_discount_limit?: number | null;
  approvals?: SoApproval[]; activity?: SoActivity[];
  obj_type?: number; status?: string; can_copy?: boolean; copy_block?: 'not_approved' | 'closed' | 'read_only' | null;
}
export interface InboxRow {
  approval_id: number; company_code: string; kind: 'sales_order' | 'sales_quotation' | 'journal' | 'payment' | 'purchase_order' | 'goods_receipt' | 'goods_issue' | 'inventory_count' | 'bp_change' | 'leave' | 'company_details' | 'sales_doc_request'; doc_entry: number; doc_no: string; rule_code: RuleCode; step: number;
  card_code: string | null; card_name: string | null; total: number; currency: string; requested_by_name: string | null; requested_at: string;
  reason: string | null; decision: 'approved' | 'rejected' | null; decided_at: string | null; decided_by_name: string | null; note: string | null;
  state: WorkflowState | 'posted'; approver_position_name: string; superseded: boolean; message: string | null;
  /** B2: the approval template and stage of this row (built-in = leave / rows sent before B2). */
  template_name?: string | null; stage_name?: string | null; stages?: number; need_approvals?: number; approvals?: number; built_in?: boolean;
}
export interface Inbox { is_approver: boolean; waiting: InboxRow[]; sent: InboxRow[]; decided: InboxRow[] }

export interface SoHeaderInput {
  card_code: string; doc_date: string; due_date: string; price_list: number | ''; payment_terms: number | ''; slp_code: number | '';
  whs_code: string; customer_ref: string; comments: string;
  /** B4: document currency ('' = the customer's own) and a typed rate ('' = the posting date's rate; Financials only). */
  currency?: string; fx_rate?: string;
}
export interface SoLineInput {
  item_code: string; qty: string; price: string; discount_pct: string; tax_code: string;
  /** Copied from a quotation (A4): the quotation line this order line uses up. */
  base_obj_type?: number | null; base_doc_entry?: number | null; base_line?: number | null;
}

/** Lines as the database expects them (empty price = take it from the price list). */
export const toLinesPayload = (lines: SoLineInput[]) =>
  lines.map((l) => ({
    item_code: l.item_code, qty: l.qty, price: l.price === '' ? null : l.price, discount_pct: l.discount_pct || '0', tax_code: l.tax_code,
    ...(l.base_doc_entry != null ? { base_obj_type: l.base_obj_type, base_doc_entry: l.base_doc_entry, base_line: l.base_line } : {}),
  }));
export const toHeaderPayload = (h: SoHeaderInput) => ({
  ...h, price_list: h.price_list === '' ? null : h.price_list, payment_terms: h.payment_terms === '' ? null : h.payment_terms,
  slp_code: h.slp_code === '' ? null : h.slp_code, due_date: h.due_date || null, currency: h.currency || null, fx_rate: h.fx_rate || null,
});

export function useSoSetup(company: string | null, obj = 17) {
  return useQuery({
    queryKey: ['so-setup', company, obj],
    enabled: Boolean(company),
    staleTime: 5 * 60_000,
    queryFn: () => rpc<SoSetup>('sales_doc_setup', { p_company: company, p_obj: obj }),
  });
}

export function useSoInfo(company: string, entry: number, enabled = true, obj = 17) {
  return useQuery({
    queryKey: ['so-info', company, entry, obj],
    enabled,
    queryFn: () => rpc<SoInfo | null>('sales_doc_info', { p_company: company, p_obj: obj, p_doc_entry: entry }),
  });
}

export function useInbox() {
  return useQuery({ queryKey: ['approval-inbox'], queryFn: () => rpc<Inbox>('approval_inbox', {}), refetchInterval: 30_000 });
}

export const soSave = (company: string, entry: number | null, header: SoHeaderInput, lines: SoLineInput[], obj = 17, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; state: WorkflowState; totals: SoTotals; checks: SoCheck[] }>('sales_doc_save', {
    p_company: company, p_obj: obj, p_doc_entry: entry, p_header: toHeaderPayload(header), p_lines: toLinesPayload(lines), p_series: series,
  });
export const soChecks = (company: string, entry: number | null, header: SoHeaderInput, lines: SoLineInput[], obj = 17) =>
  rpc<SoEval>('sales_doc_checks', { p_company: company, p_obj: obj, p_doc_entry: entry, p_header: toHeaderPayload(header), p_lines: toLinesPayload(lines) });
export const soSubmit = (company: string, entry: number, reason: string | null, obj = 17) =>
  rpc<{ state: WorkflowState; status: string; checks: SoCheck[] }>('sales_doc_submit', { p_company: company, p_obj: obj, p_doc_entry: entry, p_reason: reason });
export const soDecide = (company: string, entry: number, decision: 'approved' | 'rejected', note: string | null, newDiscount: number | null = null, obj = 17) =>
  rpc<{ state: WorkflowState; status: string; total: number }>('sales_doc_decide', {
    p_company: company, p_obj: obj, p_doc_entry: entry, p_decision: decision, p_note: note, p_new_discount: newDiscount,
  });
export const soCancel = (company: string, entry: number, note: string, obj = 17) =>
  rpc<{ state: WorkflowState }>('sales_doc_cancel', { p_company: company, p_obj: obj, p_doc_entry: entry, p_note: note });

// ---------- Combobox searches (RLS decides what the user may read) ----------
const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();

export interface CustomerHit {
  card_code: string; name: string; city: string | null; phone: string | null; trn: string | null; balance: number | null;
  credit_limit: number | null; price_list: number | null; payment_terms: number | null; slp_code: number | null; currency: string | null;
}
export async function searchCustomers(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('business_partner')
    .select('card_code,name,city,phone,trn,balance,credit_limit,price_list,payment_terms,slp_code,currency')
    .eq('company_code', company).eq('kind', 'customer').eq('active', true);
  if (s) qb = qb.or(`card_code.ilike.*${s}*,name.ilike.*${s}*,phone.ilike.*${s}*,trn.ilike.*${s}*`);
  const { data, error } = await qb.order('card_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as CustomerHit[];
}

export interface ItemHit {
  item_code: string; name: string; barcode: string | null; sales_uom: string | null;
  item_price: Array<{ list_num: number; price: number | null }>; stock_balance: Array<{ whs_code: string; on_hand: number; committed: number }>;
}
export async function searchItems(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('item')
    .select('item_code,name,barcode,sales_uom,item_price(list_num,price),stock_balance(whs_code,on_hand,committed)')
    .eq('company_code', company).eq('active', true).eq('is_sold', true);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,name.ilike.*${s}*,barcode.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as ItemHit[];
}
export const itemPrice = (it: ItemHit, list: number | '' | null) => it.item_price.find((p) => p.list_num === list)?.price ?? null;
export const itemStock = (it: ItemHit, whs: string) => {
  const s = it.stock_balance.find((b) => b.whs_code === whs);
  return s ? Number(s.on_hand) - Number(s.committed) : null;
};

/** Live line maths in the browser (the server recalculates and is the authority on save). */
export function lineTotal(qty: number, price: number, disc: number) {
  return Math.round(qty * price * (1 - disc / 100) * 100) / 100;
}
export const round2 = (n: number) => Math.round(n * 100) / 100;
