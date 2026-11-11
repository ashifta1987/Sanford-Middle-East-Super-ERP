import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';
import type { DocKind } from './modules';
import type { WorkflowState } from './salesOrder';

/** Types and calls for the A6 purchasing China flow (supabase/sql/21_purchasing.sql). The database checks every write. */

export type PurchaseKind = 'purchase_request' | 'purchase_quotation' | 'purchase_order';
export const PURCHASE_OBJ: Record<PurchaseKind, number> = { purchase_request: 1470000113, purchase_quotation: 540000006, purchase_order: 22 };
export type PurchaseViewKind = 'goods_receipt_po' | 'ap_down_payment' | 'ap_invoice';
export const VIEW_OBJ: Record<PurchaseViewKind, number> = { goods_receipt_po: 20, ap_down_payment: 204, ap_invoice: 18 };
/** Purchasing document types in flow order (obj_type → list kind). */
export const PURCHASE_FLOW: Array<{ obj: number; kind: DocKind }> = [
  { obj: 1470000113, kind: 'purchase_request' }, { obj: 540000006, kind: 'purchase_quotation' }, { obj: 22, kind: 'purchase_order' },
  { obj: 204, kind: 'ap_down_payment' }, { obj: 20, kind: 'goods_receipt_po' }, { obj: 18, kind: 'ap_invoice' }, { obj: 19, kind: 'ap_credit_note' },
];
export const purchaseKindOfObj = (obj: number) => PURCHASE_FLOW.find((f) => f.obj === obj)?.kind;

export interface Code<T = string> { code: T; name: string }
export interface PuSetup {
  currency: string;
  tax_codes: Array<Code & { rate: number }>;
  warehouses: Code[];
  payment_terms: Array<Code<number> & { days: number | null }>;
  offices: Code[];
  pi_statuses: Code[];
  qc_checklist: Code[];
  landed_cost_codes: Array<Code & { split_method: 'cbm' | 'qty' | 'value' | 'weight' | 'equal' }>;
  default_tax_code: string | null;
  default_whs_code: string | null;
  require_qc_pass: boolean;
  numbering: Record<string, string> | null;
  my_po_limit: number | null;
  price_increase_pct: number | null;
  can_write: boolean;
  can_request: boolean;
  can_finance: boolean;
}
export function usePuSetup(company: string | null) {
  return useQuery({
    queryKey: ['pu-setup', company],
    enabled: Boolean(company),
    staleTime: 60_000,
    queryFn: () => rpc<PuSetup>('purchase_doc_setup', { p_company: company }),
  });
}

export interface PuProblem { line: number | null; field: string; message: string }
export interface PuCheck { rule_code: 'po_amount' | 'po_price_increase'; step: number; approver_position: string; approver_name: string; line: number | null; value: number; limit: number; message: string }
export interface PuEvalLine {
  line_num: number; item_code: string; description: string | null; uom: string | null; qty: number; price: number | null; tax_code: string | null;
  tax_rate: number | null; whs_code: string | null; cbm: number | null; line_total: number; vat: number; last_price: number | null;
  last_doc_no: string | null; last_doc_date: string | null; base_obj_type: number | null; base_doc_entry: number | null; base_line: number | null;
}
export interface PuEval {
  errors: PuProblem[]; checks: PuCheck[]; lines: PuEvalLine[];
  header: Record<string, unknown>; totals: { net: number; vat: number; total: number; currency: string; rate?: number | null; local_currency?: string; total_lc?: number | null };
}
export interface PuHeaderInput {
  card_code: string; doc_date: string; due_date: string; whs_code: string; china_office: string; payment_terms: number | ''; customer_ref: string; comments: string;
  /** B4: document currency ('' = the supplier's own) and a typed rate ('' = the posting date's rate; Financials only). */
  currency?: string; fx_rate?: string;
}
export interface PuLineInput {
  item_code: string; qty: string; price: string; tax_code: string; whs_code?: string; cbm: string;
  base_obj_type?: number | null; base_doc_entry?: number | null; base_line?: number | null;
}
const headerPayload = (h: PuHeaderInput) => ({
  card_code: h.card_code || null, doc_date: h.doc_date, due_date: h.due_date || null, whs_code: h.whs_code || null, china_office: h.china_office || null,
  payment_terms: h.payment_terms === '' ? null : h.payment_terms, customer_ref: h.customer_ref, comments: h.comments,
  currency: h.currency || null, fx_rate: h.fx_rate || null,
});
const linesPayload = (ls: PuLineInput[]) => ls.map((l) => ({
  item_code: l.item_code, qty: l.qty, price: l.price === '' ? null : l.price, tax_code: l.tax_code || null, whs_code: l.whs_code || null,
  cbm: l.cbm === '' ? null : l.cbm,
  ...(l.base_doc_entry != null ? { base_obj_type: l.base_obj_type, base_doc_entry: l.base_doc_entry, base_line: l.base_line } : {}),
}));
export const puChecks = (company: string, obj: number, entry: number | null, h: PuHeaderInput, ls: PuLineInput[]) =>
  rpc<PuEval>('purchase_doc_checks', { p_company: company, p_obj: obj, p_doc_entry: entry, p_header: headerPayload(h), p_lines: linesPayload(ls) });
export const puSave = (company: string, obj: number, entry: number | null, h: PuHeaderInput, ls: PuLineInput[], series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; checks: PuCheck[]; totals: PuEval['totals'] }>('purchase_doc_save', {
    p_company: company, p_obj: obj, p_doc_entry: entry, p_header: headerPayload(h), p_lines: linesPayload(ls), p_series: series,
  });
export const puSubmit = (company: string, obj: number, entry: number, reason: string | null) =>
  rpc<{ state: WorkflowState; status: string; checks: PuCheck[] }>('purchase_doc_submit', { p_company: company, p_obj: obj, p_doc_entry: entry, p_reason: reason });
export const puDecide = (company: string, entry: number, decision: 'approved' | 'rejected', note: string | null) =>
  rpc<{ state: WorkflowState; status: string }>('purchase_doc_decide', { p_company: company, p_obj: 22, p_doc_entry: entry, p_decision: decision, p_note: note });
export const puCancel = (company: string, obj: number, entry: number, note: string) =>
  rpc<{ state: WorkflowState }>('purchase_doc_cancel', { p_company: company, p_obj: obj, p_doc_entry: entry, p_note: note });

export interface PuApproval {
  approval_id: number; step: number; rule_code: string; approver_position_name: string; decision: 'approved' | 'rejected' | null; note: string | null;
  decided_at: string | null; decided_by_name: string | null; decided_by_me: boolean; requested_by_name: string | null; requested_at: string | null;
  detail: { checks?: PuCheck[] } | null; superseded: boolean; current: boolean; mine: boolean;
}
export interface PuPi { pi_id: number; vendor_pi_no: string; pi_date: string; amount: number | null; eta: string | null; status: string; status_name: string | null; deposit_doc_entry: number | null; deposit_doc_no: string | null; note: string | null; updated_at: string }
export interface PuDeposit { doc_entry: number; doc_no: string; doc_date: string; total: number; paid: number; drawn: number; status: string }
export interface PuQc { qc_id: number; inspected_on: string; inspector: string | null; result: 'pass' | 'fail' | 'rework'; checklist: Array<{ code: string; name: string; ok: boolean; note: string | null }>; photos: string[]; note: string | null; created_at: string; created_by_name: string | null }
export interface PuShipment {
  shipment_id: number; container_no: string | null; shipping_mark: string | null; shipment_mode: string | null; etd: string | null; eta: string; status: 'in_transit' | 'arrived'; note: string | null;
  lines: Array<{ po_line: number; item_code: string; whs_code: string | null; qty: number; received_qty: number }> | null;
}
export interface PuActivity { at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }
export interface PuInfo {
  workflow: boolean; obj_type: number; source: string; doc_no: string; state: WorkflowState; status: string; china_office: string | null; china_office_name: string | null;
  whs_code: string | null; payment_terms: number | null; created_by_name: string | null; created_at: string | null; submitted_by_name: string | null; submitted_at: string | null;
  reason: string | null; cancel_note: string | null; cancelled_at: string | null; is_creator: boolean; is_submitter: boolean;
  can_edit: boolean; can_submit: boolean; can_cancel: boolean; can_decide: boolean; can_copy: boolean; copy_block: 'not_approved' | 'closed' | 'read_only' | null;
  can_write: boolean; can_finance: boolean; require_qc_pass: boolean; last_qc: string | null;
  approvals: PuApproval[]; pis: PuPi[] | null; deposits: PuDeposit[] | null; qcs: PuQc[] | null; shipments: PuShipment[] | null; activity: PuActivity[];
}
export function usePuInfo(company: string, obj: number, entry: number) {
  return useQuery({
    queryKey: ['pu-info', company, obj, entry],
    queryFn: () => rpc<PuInfo | null>('purchase_doc_info', { p_company: company, p_obj: obj, p_doc_entry: entry }),
  });
}

export interface PuCopyLine {
  base_obj_type: number; base_doc_entry: number; base_line: number; base_doc_no: string; base_doc_date: string; card_code: string | null; item_code: string;
  description: string | null; uom: string | null; quantity: number; open_qty: number; price: number | null; discount_pct: number; tax_code: string | null;
  tax_rate: number | null; whs_code: string | null; line_total: number; vat: number; cbm: number | null; cost: number | null; is_stock: boolean;
  on_hand: number | null; in_transit: number | null;
  currency?: string | null; fx_rate?: number | null; line_total_fc?: number | null; vat_fc?: number | null;
}
export interface PuCopySource {
  obj_type: number;
  header: { doc_entry: number; doc_no: string; card_code: string | null; card_name: string | null; doc_date: string; due_date: string | null; payment_terms: number | null;
    whs_code: string | null; china_office: string | null; customer_ref: string | null; comments: string | null; currency: string; total: number;
    fx_rate?: number | null; total_fc?: number | null } | null;
  lines: PuCopyLine[];
}
export const puCopySource = (company: string, obj: number, entry: number | null, card: string | null = null) =>
  rpc<PuCopySource>('purchase_copy_source', { p_company: company, p_obj: obj, p_doc_entry: entry, p_card_code: card });

export interface PuCompare {
  request: { doc_entry: number; doc_no: string; doc_date: string; due_date: string | null; status: string; state: string | null; source: string; currency: string; comments: string | null; china_office: string | null };
  quotations: Array<{ doc_entry: number; doc_no: string; card_code: string; card_name: string | null; doc_date: string; due_date: string | null; status: string; state: string; total: number; customer_ref: string | null }>;
  lines: Array<{ line_num: number; item_code: string; description: string | null; quantity: number; open_qty: number; uom: string | null; last_price: number | null;
    offers: Array<{ doc_entry: number; line_num: number; card_code: string; card_name: string | null; doc_no: string; price: number; qty: number; open_qty: number; line_total: number; status: string; state: string; best: boolean }> }>;
}
export const puCompare = (company: string, request: number) => rpc<PuCompare>('purchase_quotation_compare', { p_company: company, p_request: request });

export interface PuFlow {
  docs: Array<{ obj_type: number; doc_entry: number; doc_no: string; doc_date: string; status: string; state: string | null; total: number; paid: number | null; currency: string; source: string; card_name: string | null; trans_id: number | null; current: boolean }>;
  pis?: Array<{ pi_id: number; vendor_pi_no: string; status: string; po_doc_entry: number }>;
  qcs?: Array<{ qc_id: number; result: string; inspected_on: string; po_doc_entry: number }>;
  shipments?: Array<{ shipment_id: number; container_no: string | null; eta: string; status: string; po_doc_entry: number }>;
  payments?: Array<{ doc_entry: number; doc_no: string; doc_date: string; total: number; cancelled: boolean }>;
  landed_costs?: Array<{ doc_entry: number; doc_no: string; doc_date: string; total: number; current: boolean }>;
}
export function usePuFlow(company: string, obj: number, entry: number, enabled = true) {
  return useQuery({
    queryKey: ['pu-flow', company, obj, entry],
    enabled: enabled && Boolean(company && entry),
    queryFn: () => rpc<PuFlow>('purchase_doc_flow', { p_company: company, p_obj: obj, p_doc_entry: entry }),
  });
}

export interface PuView {
  workflow: boolean; source: string; doc_no: string; status: string; china_office: string | null; created_by_name: string | null; created_at: string | null;
  trans_id: number | null; can_read_journal: boolean; can_copy: boolean; can_landed_cost: boolean; copy_block: 'source' | 'closed' | 'read_only' | null;
  gross: number | null; open_amount: number | null; draws: Array<{ dp_entry: number; doc_no: string; amount: number }> | null;
  drawn_by: Array<{ invoice_entry: number; doc_no: string; amount: number }> | null; po_doc_entry: number | null;
  landed_costs: Array<{ doc_entry: number; doc_no: string; total: number }> | null; activity: PuActivity[];
}
export function usePuView(company: string, obj: number, entry: number) {
  return useQuery({
    queryKey: ['pu-view', company, obj, entry],
    queryFn: () => rpc<PuView | null>('purchase_view', { p_company: company, p_obj: obj, p_doc_entry: entry }),
  });
}

export const piSave = (company: string, id: number | null, data: Record<string, unknown>) =>
  rpc<{ pi_id: number; status: string }>('purchase_pi_save', { p_company: company, p_pi_id: id, p_data: data });
export const depositCreate = (company: string, po: number, header: Record<string, unknown>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; total: number; trans_id: number; card_code: string }>('purchase_deposit_create', { p_company: company, p_po: po, p_header: header, p_series: series });
export const qcSave = (company: string, data: Record<string, unknown>) => rpc<{ qc_id: number; result: string }>('purchase_qc_save', { p_company: company, p_data: data });
export const shipmentSave = (company: string, id: number | null, header: Record<string, unknown>, lines: Array<Record<string, unknown>>) =>
  rpc<{ shipment_id: number; eta: string }>('purchase_shipment_save', { p_company: company, p_shipment_id: id, p_header: header, p_lines: lines });
export const grpoCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; total: number; trans_id: number | null }>('purchase_grpo_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });
export const apInvoiceCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; gross: number; drawn: number; total: number; trans_id: number }>('purchase_invoice_create', { p_company: company, p_header: header, p_lines: lines, p_series: series });

export interface LcLine {
  line_num: number; grpo_entry: number; grpo_line: number; grpo_no: string; item_code: string; description: string | null; whs_code: string; qty: number; value: number;
  cbm: number | null; weight: number | null; allocated: number; to_inventory: number; to_cogs: number; on_hand: number; avg_before: number | null; avg_after: number | null;
  allocs?: Record<string, number> | null;
}
export interface LcCharge {
  charge_no: number; code: string; name: string; split_method: 'cbm' | 'qty' | 'value' | 'weight'; amount: number;
  /** B5: the charge's currency, FC amount and rate; the linked broker A/P invoice; LC credited to clearing; rate difference (clearing − amount). */
  currency?: string; amount_fc?: number | null; fx_rate?: number | null; ap_invoice_entry?: number | null; ap_invoice_no?: string | null;
  clear_amount?: number; fx_diff?: number;
  /** B6: the cost line's vendor (supplier). */
  card_code?: string | null; card_name?: string | null;
}
export interface LcEval {
  header: Record<string, unknown>; lines: LcLine[]; charges: LcCharge[]; allocs: Array<{ charge_no: number; line_num: number; basis: number; amount: number }>;
  totals: { total: number; to_inventory: number; to_cogs: number; currency: string; clearing?: number; fx_diff?: number };
}
export const lcPreview = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, charges: Array<Record<string, unknown>>) =>
  rpc<LcEval>('landed_cost_preview', { p_company: company, p_header: header, p_lines: lines, p_charges: charges });
export const lcCreate = (company: string, header: Record<string, unknown>, lines: Array<Record<string, unknown>>, charges: Array<Record<string, unknown>>, series: number | null = null) =>
  rpc<{ doc_entry: number; doc_no: string; total: number; to_inventory: number; to_cogs: number; trans_id: number; fx_diff: number }>('landed_cost_create', { p_company: company, p_header: header, p_lines: lines, p_charges: charges, p_series: series });
export interface LcInfo {
  doc_entry: number; doc_no: string; doc_date: string; card_code: string | null; card_name: string | null; reference: string | null; comments: string | null;
  total: number; to_inventory: number; to_cogs: number; currency: string; trans_id: number | null; can_read_journal: boolean; created_by_name: string | null; created_at: string;
  lines: LcLine[]; charges: LcCharge[]; activity: PuActivity[];
}
export function useLcInfo(company: string, entry: number) {
  return useQuery({ queryKey: ['lc-info', company, entry], queryFn: () => rpc<LcInfo | null>('landed_cost_info', { p_company: company, p_doc_entry: entry }) });
}

export const puSettingSet = (company: string, s: Record<string, unknown>) => rpc<Record<string, unknown>>('purchase_setting_set', { p_company: company, p_setting: s });
export const puListSave = (company: string, kind: 'china_office' | 'pi_status' | 'qc_check', item: Record<string, unknown>) =>
  rpc<Record<string, unknown>>('purchase_list_save', { p_company: company, p_kind: kind, p_item: item });
export const lcCodeSave = (company: string, code: Record<string, unknown>) => rpc<Record<string, unknown>>('landed_cost_code_save', { p_company: company, p_code: code });

/** Setup lists including inactive rows (Purchasing Setup screen; RLS: Purchasing or Financials). */
export function usePuLists(company: string | null) {
  return useQuery({
    queryKey: ['pu-lists', company],
    enabled: Boolean(company),
    queryFn: async () => {
      const get = async (t: string, order: string) => {
        const { data, error } = await erp().from(t).select('*').eq('company_code', company!).order(order);
        if (error) throw new ApiError(error);
        return (data ?? []) as unknown as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
      };
      const [offices, statuses, checks, codes, setting] = await Promise.all([
        get('china_office', 'sort'), get('pi_status', 'sort'), get('qc_checklist_item', 'sort'), get('landed_cost_code', 'code'), get('purchase_setting', 'company_code'),
      ]);
      return { offices, statuses, checks, codes, setting: setting[0] ?? null };
    },
  });
}

// ---------- Combobox searches (RLS decides what the user may read) ----------
const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();
export interface SupplierHit { card_code: string; name: string; city: string | null; country: string | null; currency: string | null; balance: number | null; payment_terms: number | null }
export async function searchSuppliers(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('business_partner').select('card_code,name,city,country,currency,balance,payment_terms')
    .eq('company_code', company).eq('kind', 'supplier').eq('active', true);
  if (s) qb = qb.or(`card_code.ilike.*${s}*,name.ilike.*${s}*,city.ilike.*${s}*`);
  const { data, error } = await qb.order('card_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as SupplierHit[];
}
export interface BuyItemHit { item_code: string; name: string; purchase_uom: string | null; barcode: string | null }
export async function searchBuyItems(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('item').select('item_code,name,purchase_uom,barcode').eq('company_code', company).eq('active', true).eq('is_bought', true).eq('is_stock', true);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,name.ilike.*${s}*,barcode.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as BuyItemHit[];
}
/** Open Super ERP goods receipt lines (for landed costs): every receipt, open or invoiced, that is not cancelled. */
export async function grpoLines(company: string, entry: number) {
  const { data, error } = await erp().from('document_line').select('line_num,item_code,description,quantity,price,line_total,whs_code,cbm')
    .match({ company_code: company, obj_type: 20, doc_entry: entry }).order('line_num');
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as Array<{ line_num: number; item_code: string; description: string | null; quantity: number; price: number; line_total: number; whs_code: string; cbm: number | null }>;
}

