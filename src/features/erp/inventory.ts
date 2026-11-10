import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';
import type { WorkflowState } from './salesOrder';

/** Types and calls for A7 inventory transactions (supabase/sql/22_inventory.sql). The database checks every write. */

export type StockDocKind = 'goods_receipt' | 'goods_issue';
export type TransferKind = 'transfer_request' | 'inventory_transfer';
export type InvKind = StockDocKind | TransferKind;
export const INV_OBJ: Record<InvKind, number> = { goods_receipt: 59, goods_issue: 60, transfer_request: 1250000001, inventory_transfer: 67 };
export const isInvKind = (k: string): k is InvKind => k in INV_OBJ;

export interface Code<T = string> { code: T; name: string }
export interface InvSetup {
  currency: string;
  warehouses: Array<Code & { bins: boolean; stock_acct: string | null; allow_negative: boolean; locked: boolean }>;
  bins: Array<{ code: string; whs_code: string; name: string | null; active: boolean; qty: number }>;
  reasons: Array<Code & { direction: 'in' | 'out' | 'both'; acct_code: string | null; acct_name: string | null; active: boolean; source: string }>;
  accounts: Code[];
  item_groups: Code<number>[];
  numbering: Record<string, string> | null;
  my_limits: Record<string, number> | null;
  count_rules: { pct: number | null; value: number | null };
  blind_count: boolean;
  can_write: boolean;
  can_finance: boolean;
}
export function useInvSetup(company: string | null) {
  return useQuery({
    queryKey: ['inv-setup', company],
    enabled: Boolean(company),
    staleTime: 30_000,
    queryFn: () => rpc<InvSetup>('inventory_setup', { p_company: company }),
  });
}

export interface InvProblem { line: number | null; field: string; message: string }
export interface InvCheck { rule_code: string; step: number; approver_position: string; approver_name: string; line: number | null; value: number; limit: number; message: string }
export interface Lot { number: string; qty?: number; made_on?: string; expires_on?: string }
export interface InvEvalLine {
  line_num: number; item_code: string; description: string | null; uom: string | null; qty: number | null; price: number; line_total: number;
  bin_code?: string | null; from_whs?: string; to_whs?: string; from_bin?: string | null; to_bin?: string | null; lots: Lot[];
  serial: boolean; batch: boolean; on_hand: number; base_doc_no?: string | null;
}
export interface InvEval {
  errors: InvProblem[]; checks?: InvCheck[]; lines: InvEvalLine[];
  header: Record<string, unknown>; totals: { value: number; qty?: number; currency: string };
}
export const invChecks = (company: string, obj: number, header: Record<string, unknown>, lines: Array<Record<string, unknown>>) =>
  rpc<InvEval>('inventory_doc_checks', { p_company: company, p_obj: obj, p_header: header, p_lines: lines });
export const invCreate = (company: string, obj: number, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, reason: string | null, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; state: WorkflowState; status: string; value: number; trans_id: number | null }>('inventory_doc_create', {
    p_company: company, p_obj: obj, p_header: header, p_lines: lines, p_reason: reason, p_series: series,
  });
export const invDecide = (company: string, obj: number, entry: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: WorkflowState; trans_id: number | null }>('inventory_doc_decide', { p_company: company, p_obj: obj, p_doc_entry: entry, p_decision: decision, p_note: note });
export const invCancel = (company: string, obj: number, entry: number, note: string) =>
  rpc<{ state: WorkflowState }>('inventory_doc_cancel', { p_company: company, p_obj: obj, p_doc_entry: entry, p_note: note });

export const trChecks = (company: string, obj: number, header: Record<string, unknown>, lines: Array<Record<string, unknown>>) =>
  rpc<InvEval>('transfer_checks', { p_company: company, p_obj: obj, p_header: header, p_lines: lines });
export const trRequestCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string }>('transfer_request_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });
export const trRequestCancel = (company: string, entry: number, note: string) =>
  rpc<{ status: string }>('transfer_request_cancel', { p_company: company, p_doc_entry: entry, p_note: note });
export const trCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; qty: number; value: number; trans_id: number | null }>('transfer_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });
export interface TrSource {
  header: { doc_entry: number; doc_no: string; doc_date: string; due_date: string | null; from_whs: string | null; to_whs: string | null; status: string; source: string; comments: string | null } | null;
  lines: Array<{ base_doc_entry: number; base_line: number; item_code: string; description: string | null; uom: string | null; quantity: number; open_qty: number;
    from_whs: string; to_whs: string; on_hand: number; serial: boolean; batch: boolean }>;
}
export const trSource = (company: string, entry: number) => rpc<TrSource>('transfer_source', { p_company: company, p_doc_entry: entry });

export interface InvApproval {
  approval_id: number; step: number; rule_code: string; approver_position_name: string; decision: 'approved' | 'rejected' | null; note: string | null;
  decided_at: string | null; decided_by_name: string | null; decided_by_me: boolean; requested_by_name: string | null; requested_at: string | null;
  detail: { checks?: InvCheck[] } | null; superseded: boolean; current: boolean; mine: boolean;
}
export interface InvActivity { at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }
export interface InvInfo {
  workflow: boolean; obj_type: number; source: string; doc_no: string; state: WorkflowState | null; status: string; whs_code: string | null;
  reason_code: string | null; reason_name: string | null; acct_code: string | null; acct_name: string | null;
  created_by_name: string | null; created_at: string | null; submitted_by_name: string | null; submitted_at: string | null; reason: string | null;
  cancel_note: string | null; cancelled_at: string | null; is_creator: boolean; is_submitter: boolean;
  can_decide: boolean; can_cancel: boolean; can_copy: boolean; can_write: boolean; trans_id: number | null; can_read_journal: boolean;
  approvals: InvApproval[]; details: Array<{ line_num: number; bin_code: string | null; from_bin_code: string | null; lots: Lot[] }>;
  movements: Array<{ trans_seq: number; doc_line: number; item_code: string; whs_code: string; qty_in: number; qty_out: number; price: number }>;
  flow: Array<{ obj_type: number; doc_entry: number; doc_no: string; doc_date: string; status: string }>;
  activity: InvActivity[];
}
export function useInvInfo(company: string, obj: number, entry: number) {
  return useQuery({ queryKey: ['inv-info', company, obj, entry], queryFn: () => rpc<InvInfo | null>('inventory_doc_info', { p_company: company, p_obj: obj, p_doc_entry: entry }) });
}

// ---------- Counting ----------
export type CountState = 'counting' | 'pending_approval' | 'posted' | 'rejected' | 'cancelled';
export interface CountLine {
  line_num: number; item_code: string; description: string | null; barcode: string | null; uom: string | null; bin_code: string | null;
  counted_qty: number | null; added: boolean; counted_by_name: string | null; counted_at: string | null; serial: boolean; batch: boolean;
  system_qty: number | null; variance: number | null;
}
export interface CountReportLine { line_num: number; item_code: string; description: string | null; bin_code: string | null; system_qty: number; counted_qty: number; variance: number; pct: number | null; cost: number; value: number }
export interface CountInfo {
  count_id: number; doc_no: string; whs_code: string; whs_name: string | null; bins: boolean; item_group: number | null; item_group_name: string | null;
  count_date: string; state: CountState; comments: string | null; reason: string | null; n_lines: number; n_counted: number;
  gain_value: number | null; loss_value: number | null; trans_id: number | null; currency: string;
  created_by_name: string | null; created_at: string; submitted_by_name: string | null; submitted_at: string | null; posted_at: string | null;
  cancel_note: string | null; cancelled_at: string | null; blind: boolean; is_submitter: boolean;
  can_count: boolean; can_cancel: boolean; can_decide: boolean; can_read_journal: boolean;
  lines: CountLine[];
  report: { lines: CountReportLine[]; totals: { gain: number; loss: number; net: number; currency: string; uncounted: number }; errors: InvProblem[] } | null;
  approvals: InvApproval[]; activity: InvActivity[];
}
export function useCountInfo(company: string, id: number) {
  return useQuery({ queryKey: ['inv-count', company, id], queryFn: () => rpc<CountInfo | null>('inv_count_info', { p_company: company, p_count_id: id }) });
}
export const countCreate = (company: string, header: Record<string, unknown>, series: number | null = null) =>
  rpc<{ count_id: number; doc_no: string; lines: number }>('inv_count_create', { p_company: company, p_header: header, p_series: series });
export const countSave = (company: string, id: number, lines: Array<Record<string, unknown>>) =>
  rpc<{ n_lines: number; n_counted: number; saved: number; added: number; state: CountState }>('inv_count_save', { p_company: company, p_count_id: id, p_lines: lines });
export const countSubmit = (company: string, id: number, reason: string | null) =>
  rpc<{ state: CountState; checks: InvCheck[]; trans_id: number | null }>('inv_count_submit', { p_company: company, p_count_id: id, p_reason: reason });
export const countDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: CountState; trans_id: number | null }>('inv_count_decide', { p_company: company, p_count_id: id, p_decision: decision, p_note: note });
export const countCancel = (company: string, id: number, note: string) =>
  rpc<{ state: CountState }>('inv_count_cancel', { p_company: company, p_count_id: id, p_note: note });

// ---------- Batches / serials, setup ----------
export interface LotHistory {
  lot_id: number; kind: 'B' | 'S'; item_code: string; item_name: string | null; number: string; made_on: string | null; expires_on: string | null;
  received_on: string | null; source: string; created_at: string;
  balances: Array<{ whs_code: string; qty: number }>;
  moves: Array<{ move_id: number; obj_type: number; doc_entry: number; doc_line: number; doc_no: string; doc_date: string; whs_code: string; qty_in: number; qty_out: number }>;
}
export function useLotHistory(company: string, id: number) {
  return useQuery({ queryKey: ['inv-lot', company, id], queryFn: () => rpc<LotHistory | null>('lot_history', { p_company: company, p_lot_id: id }) });
}
export const binSave = (company: string, bin: Record<string, unknown>) => rpc<{ bin_code: string }>('bin_save', { p_company: company, p_bin: bin });
export const whsInvSet = (company: string, whs: string, s: Record<string, unknown>) =>
  rpc<{ bins_enabled: boolean; stock_acct: string | null }>('warehouse_inv_set', { p_company: company, p_whs: whs, p_setting: s });
export const reasonSave = (company: string, r: Record<string, unknown>) => rpc<{ code: string }>('inventory_reason_save', { p_company: company, p_reason: r });
export const invSettingSet = (company: string, s: Record<string, unknown>) => rpc<{ blind_count: boolean }>('inventory_setting_set', { p_company: company, p_setting: s });

// ---------- Combobox search (RLS decides what the user may read) ----------
const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();
export interface StockItemHit { item_code: string; name: string; inventory_uom: string | null; barcode: string | null; serial_managed: boolean; batch_managed: boolean }
export async function searchStockItems(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('item').select('item_code,name,inventory_uom,barcode,serial_managed,batch_managed').eq('company_code', company).eq('active', true).eq('is_stock', true);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,name.ilike.*${s}*,barcode.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as StockItemHit[];
}

/** "SN-1, SN-2" or one per line; batches "B-01:60". Returns lots for the server. */
export function parseLots(text: string, batch: boolean): Lot[] {
  return text.split(/[\n,;]+/).map((s) => s.trim()).filter(Boolean).map((s) => {
    if (!batch) return { number: s };
    const m = s.match(/^(.+?)\s*:\s*([0-9.]+)$/);
    return m ? { number: m[1].trim(), qty: Number(m[2]) } : { number: s };
  });
}
export const lotsText = (lots: Lot[], batch: boolean) => lots.map((l) => (batch && l.qty != null ? `${l.number}:${l.qty}` : l.number)).join(', ');
