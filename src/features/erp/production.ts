import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

/** Types and calls for A13 production (supabase/sql/28_production_service.sql). The database checks every write. */

export type OrderState = 'planned' | 'released' | 'closed' | 'cancelled';
export interface Code { code: string; name: string }
export interface PrdSetup {
  currency: string;
  warehouses: Array<Code & { bins: boolean }>;
  resources: Array<Code & { kind: string; unit: string; unit_cost: number; acct_code: string | null; active: boolean }>;
  accounts: Code[];
  setting: { wip_acct: string | null; variance_acct: string | null; life_warn_pct: number | null; note: string | null };
  numbering: string | null;
  can_write: boolean;
  can_finance: boolean;
}
export function usePrdSetup(company: string | null) {
  return useQuery({ queryKey: ['prd-setup', company], enabled: Boolean(company), staleTime: 30_000,
    queryFn: () => rpc<PrdSetup>('production_setup', { p_company: company }) });
}

export interface BomLine { line_num: number; comp_kind: 'item' | 'resource'; comp_code: string; qty: number; whs_code: string | null; note: string | null;
  name: string | null; uom: string | null; unit_cost: number; on_hand: number | null; kind: string | null; cost: number }
export interface BomInfo {
  bom: { item_code: string; item_name: string; uom: string | null; bom_type: string; qty: number; whs_code: string | null; active: boolean; note: string | null;
    source: string; updated_at: string; updated_by_name: string | null };
  lines: BomLine[]; unit_cost: number; currency: string; used_in: string[];
  open_orders: Array<{ order_id: number; doc_no: string; state: OrderState; planned_qty: number }>; can_write: boolean;
}
export function useBomInfo(company: string, item: string) {
  return useQuery({ queryKey: ['bom', company, item], enabled: Boolean(company && item),
    queryFn: () => rpc<BomInfo>('bom_info', { p_company: company, p_item: item }) });
}
export const bomSave = (company: string, bom: Record<string, unknown>) => rpc<{ item_code: string }>('bom_save', { p_company: company, p_bom: bom });
export const bomDelete = (company: string, item: string) => rpc<unknown>('bom_delete', { p_company: company, p_item: item });

export interface Shortage { line_num: number; item_code: string; item_name: string | null; whs_code: string; needed: number; available: number; short: number;
  next_po: { doc_entry: number; doc_no: string; date: string | null; qty: number } | null }
export interface OrderLine { line_num: number; comp_kind: 'item' | 'resource'; comp_code: string; name: string | null; uom: string | null; base_qty: number;
  planned_qty: number; issued_qty: number; issued_value: number; whs_code: string | null; on_hand: number | null; avg_cost: number | null;
  serial: boolean; batch: boolean; bins: boolean; res_kind: string | null }
export interface OrderInfo {
  order: { order_id: number; doc_no: string; item_code: string; item_name: string | null; uom: string | null; planned_qty: number; completed_qty: number;
    whs_code: string; post_date: string; due_date: string; state: OrderState; comments: string | null; issued_value: number; comp_received_value: number;
    resource_value: number; received_value: number; variance_value: number | null; variance_trans: number | null; wip: number; late: boolean;
    serial: boolean; batch: boolean; bins: boolean; created_by_name: string | null; released_at: string | null; closed_at: string | null; cancel_note: string | null };
  lines: OrderLine[]; shortages: Shortage[]; shortage_messages: string[];
  documents: Array<{ obj_type: 59 | 60; doc_entry: number; doc_no: string; doc_date: string; total: number; qty: number; trans_id: number | null }>;
  resource_use: Array<{ use_id: number; res_code: string; qty: number; unit_cost: number; amount: number; doc_date: string; receipt_entry: number }>;
  activity: Array<{ at: string; action: string; actor_name: string | null; detail: Record<string, unknown> | null }>;
  currency: string; can_write: boolean;
}
export function useOrderInfo(company: string, id: number) {
  return useQuery({ queryKey: ['prod-order', company, id], enabled: Boolean(company && id),
    queryFn: () => rpc<OrderInfo>('prod_order_info', { p_company: company, p_order: id }) });
}
export const orderCreate = (company: string, h: Record<string, unknown>) => rpc<{ order_id: number; doc_no: string }>('prod_order_create', { p_company: company, p_header: h });
export const orderRelease = (company: string, id: number) => rpc<unknown>('prod_order_release', { p_company: company, p_order: id });
export const orderIssue = (company: string, id: number, h: Record<string, unknown>, lines: Array<Record<string, unknown>>) =>
  rpc<{ doc_entry: number; doc_no: string; value: number }>('prod_order_issue', { p_company: company, p_order: id, p_header: h, p_lines: lines });
export const orderReceipt = (company: string, id: number, h: Record<string, unknown>) =>
  rpc<{ doc_entry: number; doc_no: string; qty: number; unit_cost: number; value: number }>('prod_order_receipt', { p_company: company, p_order: id, p_header: h });
export const orderClose = (company: string, id: number, note: string | null) =>
  rpc<{ variance: number }>('prod_order_close', { p_company: company, p_order: id, p_note: note });
export const orderCancel = (company: string, id: number, note: string) => rpc<unknown>('prod_order_cancel', { p_company: company, p_order: id, p_note: note });

export const resourceSave = (company: string, r: Record<string, unknown>) => rpc<{ res_code: string }>('prod_resource_save', { p_company: company, p_res: r });
export const maintRecord = (company: string, code: string, m: Record<string, unknown>) =>
  rpc<{ maint_id: number }>('mould_maintenance_record', { p_company: company, p_res_code: code, p_maint: m });
export const prdSettingSet = (company: string, s: Record<string, unknown>) => rpc<unknown>('production_setting_set', { p_company: company, p_setting: s });

export interface MouldRow {
  company_code: string; res_code: string; name: string; kind: string; unit: string; unit_cost: number; cavities: number | null; rated_life_shots: number | null;
  shots_done: number; location: string | null; asset_no: string | null; maint_every_shots: number | null; maint_every_days: number | null;
  last_maint_on: string | null; last_maint_shots: number; active: boolean; shots_since: number; next_due_shots: number | null; next_due_on: string | null;
  life_pct: number | null; maint_status: 'ok' | 'overdue' | 'not_scheduled'; life_warn: boolean; source: string;
}
export function useMould(company: string, code: string) {
  return useQuery({ queryKey: ['mould', company, code], enabled: Boolean(company && code), queryFn: async () => {
    const [{ data, error }, m, r] = await Promise.all([
      erp().from('mould_schedule').select('*').eq('company_code', company).eq('res_code', code).maybeSingle(),
      erp().from('mould_maintenance').select('maint_id,done_on,kind,shots_at,note,created_at').eq('company_code', company).eq('res_code', code).order('done_on', { ascending: false }),
      erp().from('prod_resource').select('acct_code,note').eq('company_code', company).eq('res_code', code).maybeSingle(),
    ]);
    if (error) throw new ApiError(error);
    if (m.error) throw new ApiError(m.error);
    return { mould: data as MouldRow | null, log: (m.data ?? []) as Array<{ maint_id: number; done_on: string; kind: string; shots_at: number; note: string | null }>,
      acct_code: (r.data as { acct_code: string | null } | null)?.acct_code ?? null, note: (r.data as { note: string | null } | null)?.note ?? null };
  } });
}

const clean = (s: string) => s.replace(/[,()*%\\:"]/g, ' ').trim();
export interface BomHit { item_code: string; item_name: string | null; whs_code: string | null; qty: number }
export async function searchBoms(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('bom_list').select('item_code,item_name,whs_code,qty').eq('company_code', company).eq('bom_type', 'production').eq('active', true);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,item_name.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as BomHit[];
}
export async function searchAllItems(company: string, q: string) {
  const s = clean(q);
  let qb = erp().from('item').select('item_code,name,inventory_uom,is_stock,serial_managed').eq('company_code', company).eq('active', true);
  if (s) qb = qb.or(`item_code.ilike.*${s}*,name.ilike.*${s}*,barcode.ilike.*${s}*`);
  const { data, error } = await qb.order('item_code').limit(8);
  if (error) throw new ApiError(error);
  return (data ?? []) as unknown as Array<{ item_code: string; name: string; inventory_uom: string | null; is_stock: boolean; serial_managed: boolean }>;
}
