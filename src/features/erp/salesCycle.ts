import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';
import type { DocKind } from './modules';

/** Types and calls for the A4 sales cycle (supabase/sql/19_sales_cycle.sql). The database checks every write. */

/** Sales document types that take part in the cycle, in flow order. */
export const CYCLE: Array<{ obj: number; kind: DocKind; step: 'quotation' | 'order' | 'delivery' | 'invoice' | 'credit' | 'return' }> = [
  { obj: 23, kind: 'sales_quotation', step: 'quotation' },
  { obj: 17, kind: 'sales_order', step: 'order' },
  { obj: 15, kind: 'delivery', step: 'delivery' },
  { obj: 16, kind: 'sales_return', step: 'return' },
  { obj: 13, kind: 'ar_invoice', step: 'invoice' },
  { obj: 14, kind: 'ar_credit_note', step: 'credit' },
];
export const kindOfObj = (obj: number) => CYCLE.find((c) => c.obj === obj)?.kind;

export interface CopyLine {
  base_obj_type: number; base_doc_entry: number; base_line: number; base_doc_no: string; base_doc_date: string; card_code: string;
  item_code: string; description: string | null; uom: string | null; quantity: number; open_qty: number; price: number; discount_pct: number | null;
  tax_code: string | null; tax_rate: number | null; whs_code: string | null; line_total: number; vat: number; cost: number | null; is_stock: boolean;
  on_hand: number | null;
  /** B4: the base document's currency and rate. */
  currency?: string | null; fx_rate?: number | null; line_total_fc?: number | null; vat_fc?: number | null;
}
export interface CopySource {
  obj_type: number;
  header: {
    doc_entry: number; doc_no: string; card_code: string; card_name: string | null; doc_date: string; due_date: string | null;
    price_list: number | null; payment_terms: number | null; slp_code: number | null; whs_code: string | null; customer_ref: string | null;
    comments: string | null; currency: string; fx_rate?: number | null;
  } | null;
  lines: CopyLine[];
}
export const copySource = (company: string, obj: number, entry: number | null, card: string | null = null) =>
  rpc<CopySource>('sales_copy_source', { p_company: company, p_obj: obj, p_doc_entry: entry, p_card_code: card });

export interface FlowDoc {
  obj_type: number; doc_entry: number; doc_no: string; doc_date: string; status: string; state: string | null; total: number; currency: string;
  source: string; trans_id: number | null; current: boolean;
}
export function useFlow(company: string, obj: number, entry: number, enabled = true) {
  return useQuery({
    queryKey: ['sales-flow', company, obj, entry],
    enabled: enabled && Boolean(company && entry),
    queryFn: () => rpc<FlowDoc[]>('sales_doc_flow', { p_company: company, p_obj: obj, p_doc_entry: entry }),
  });
}

export interface DocView {
  workflow: boolean; source: string; doc_no: string; state: string | null; status: string; created_by_name: string | null; created_at: string | null;
  return_stock: boolean | null; trans_id: number | null; can_read_journal: boolean; can_copy: boolean;
  copy_block: 'source' | 'closed' | 'read_only' | null;
  activity: Array<{ at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }>;
}
export function useDocView(company: string, obj: number, entry: number) {
  return useQuery({
    queryKey: ['sales-view', company, obj, entry],
    queryFn: () => rpc<DocView | null>('sales_doc_view', { p_company: company, p_obj: obj, p_doc_entry: entry }),
  });
}

export const deliveryCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; total: number; trans_id: number | null }>('sales_delivery_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });
/** B1: an invoice with a service-line discount above the user's limit, or a credit memo above the credit-memo limit, comes back as a request. */
export interface PendingRequest { state: 'pending_approval'; request_id: number; doc_no: string; obj_type: number; checks: Array<{ message: string; approver_name: string }>; total: number }
type Created = { doc_entry: number; doc_no: string; total: number; trans_id: number | null; state?: undefined };
export const invoiceCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<(Created & { due_date: string }) | PendingRequest>('sales_invoice_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });
export const creditMemoCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<Created | PendingRequest>('sales_credit_memo_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });

export interface SalesRequestInfo {
  request: {
    request_id: number; company_code: string; obj_type: 13 | 14; card_code: string | null; card_name: string | null; total: number | null; currency: string | null;
    header: Record<string, unknown>; lines: Array<Record<string, unknown>>; checks: Array<{ rule_code: string; message: string; approver_name: string; step: number }>;
    state: 'pending_approval' | 'approved' | 'rejected' | 'cancelled'; reason: string | null; requested_by: string; requested_at: string; decided_at: string | null;
    doc_entry: number | null; doc_no: string | null; note: string | null; doc_no_req: string; requested_by_name: string | null; series: string | null;
  };
  approvals: Array<{ step: number; approver_name: string; decision: string | null; decided_at: string | null; decided_by_name: string | null; note: string | null; superseded: boolean }>;
  is_requester: boolean; can_decide: boolean;
}
export const useSalesRequest = (company: string, id: number) => useQuery({
  queryKey: ['sales-request', company, id], enabled: Boolean(company && id),
  queryFn: () => rpc<SalesRequestInfo>('sales_doc_request_info', { p_company: company, p_request_id: id }),
});
export const salesRequestDecide = (company: string, id: number, decision: 'approved' | 'rejected', note: string) =>
  rpc<{ state: string; doc_entry: number | null; doc_no: string | null; obj_type: number }>('sales_doc_request_decide', { p_company: company, p_request_id: id, p_decision: decision, p_note: note || null });
export const salesRequestCancel = (company: string, id: number, note: string) =>
  rpc<{ state: string }>('sales_doc_request_cancel', { p_company: company, p_request_id: id, p_note: note || null });

export interface PrintData {
  company: { code: string; legal_name: string; short_name: string; tax_id: string | null; licence_authority: string | null; country: string; currency: string };
  customer: {
    card_code: string | null; name: string | null; foreign_name: string | null; trn: string | null; phone: string | null; email: string | null;
    city: string | null; country: string | null; address: { street: string | null; block: string | null; building: string | null; city: string | null; country: string | null } | null;
  };
  doc: {
    obj_type: number; doc_no: string; doc_date: string; due_date: string | null; customer_ref: string | null; comments: string | null; total: number;
    vat_total: number; currency: string; status: string; source: string; salesperson: string | null; base_docs: string[] | null;
    /** B4: foreign-currency documents: amounts above are in the document currency; these are LC. */
    fx_rate?: number | null; total_lc?: number | null; vat_total_lc?: number | null;
  };
  lines: Array<{ line_num: number; item_code: string; description: string | null; foreign_name: string | null; qty: number; uom: string | null; price: number;
    discount_pct: number | null; line_total: number; tax_code: string | null; vat: number; whs_code: string | null }>;
  vat: Array<{ tax_code: string | null; rate: number | null; net: number; vat: number }>;
}
export const printData = (company: string, obj: number, entry: number) =>
  rpc<PrintData | null>('sales_print_data', { p_company: company, p_obj: obj, p_doc_entry: entry });

export interface AtpCheck {
  rule_code: string | null; rule_name?: string; no_check?: boolean; available: number | null; date: string; item_code: string; item_name: string;
  whs_code: string; is_stock?: boolean; scope?: string; on_hand?: number; committed?: number; purchase_orders?: number; transfers?: number; in_transit?: number;
  message?: string;
  incoming?: Array<{ obj_type: number; doc_entry: number; doc_no: string; due_date: string; whs_code: string; open_qty: number; counted: boolean }>;
}
export const atpCheck = (company: string, item: string, whs: string, date: string) =>
  rpc<AtpCheck>('atp_check', { p_company: company, p_item: item, p_whs: whs, p_date: date });

export interface AtpRule {
  rule_id: number; company_code: string; rule_code: string; name: string; whs_scope: 'order_whs' | 'all_whs'; subtract_committed: boolean;
  include_purchase_orders: boolean; include_transfers: boolean; include_in_transit: boolean; no_check: boolean; item_group: number | null;
  is_default: boolean; active: boolean; note: string | null; updated_at: string;
}
export function useAtpRules(company: string | null) {
  return useQuery({
    queryKey: ['atp-rules', company],
    enabled: Boolean(company),
    queryFn: async () => {
      const { data, error } = await erp().from('atp_rule').select('*').eq('company_code', company!).order('is_default', { ascending: false }).order('rule_code');
      if (error) throw new ApiError(error);
      return (data ?? []) as unknown as AtpRule[];
    },
  });
}
export const atpRuleSave = (company: string, rule: Partial<AtpRule>) => rpc<AtpRule>('atp_rule_save', { p_company: company, p_rule: rule });

const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();
/** Service (non-stock) sales items for a direct invoice. */
export async function searchServiceItems(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('item').select('item_code,name,sales_uom,item_price(list_num,price)')
    .eq('company_code', company).eq('active', true).eq('is_sold', true).eq('is_stock', false);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,name.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as Array<{ item_code: string; name: string; sales_uom: string | null; item_price: Array<{ list_num: number; price: number | null }> }>;
}
/** Stock items for the ATP check. */
export async function searchStockItems(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('item').select('item_code,name').eq('company_code', company).eq('is_stock', true);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,name.ilike.*${s}*,barcode.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as Array<{ item_code: string; name: string }>;
}
