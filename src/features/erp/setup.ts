import { useQuery } from '@tanstack/react-query';
import { erp } from '@/lib/supabase';
import { ApiError } from '@/lib/format';
import { rpc } from './api';

// B3 · G/L Account Determination and the setup windows (32_gl_setup.sql). Every write goes through a SECURITY DEFINER
// function that checks the user, the company and the module and writes the audit log.

export const GL_TABS = ['sales', 'purchasing', 'inventory', 'banking', 'production', 'service', 'payroll', 'landed_costs', 'general'] as const;
export type GlTab = typeof GL_TABS[number];

export interface GlKey {
  area: string; posting_key: string; label: string; sort: number; tab: GlTab; ctx: boolean; store: string | null; control_ok: boolean;
  used_in: string | null; acct_code: string | null; acct_name: string | null; source: string | null; updated_at: string | null; overrides: number;
}
export interface GlOverride { area: string; posting_key: string; acct_code: string; acct_name: string | null; updated_at?: string }
export interface GlSetup {
  company: string; currency: string; can_write: boolean; tabs: GlTab[]; keys: GlKey[];
  groups: Array<{ group_code: number; name: string }>; warehouses: Array<{ whs_code: string; name: string }>;
  group_rows: Array<GlOverride & { group_code: number }>; warehouse_rows: Array<GlOverride & { whs_code: string }>;
}
export interface CtxKey { area: string; posting_key: string; label: string; tab: GlTab; default_acct: string | null }
export type AcctRow = { area: string; posting_key: string; acct_code: string | null };
export const keyId = (k: { area: string; posting_key: string }) => `${k.area}/${k.posting_key}`;

export const useGlSetup = (company: string) => useQuery({
  queryKey: ['gl-setup', company], enabled: Boolean(company), queryFn: () => rpc<GlSetup>('gl_setup', { p_company: company }),
});
export const glSave = (company: string, rows: AcctRow[]) => rpc<{ saved: number; changed: number }>('gl_determination_save', { p_company: company, p_rows: rows });
export const glOverrideSave = (company: string, level: 'group' | 'warehouse', ref: string, rows: AcctRow[]) =>
  rpc<{ saved: number; changed: number }>('gl_override_save', { p_company: company, p_level: level, p_ref: ref, p_rows: rows });

// ---------- Warehouses ----------
export interface WhsBin { bin_code: string; name: string | null; active: boolean; qty: number }
export interface Warehouse {
  whs_code: string; name: string; branch_id: number | null; classification: string | null; city: string | null; country: string | null;
  is_free_zone: boolean | null; locked: boolean; active: boolean; origin: 'sap' | 'erp'; bins_enabled: boolean; stock_acct: string | null;
  items_in_stock: number; bins: WhsBin[]; series: Array<{ obj_type: number; series_id: number; name: string | null; prefix: string | null; missing: boolean }>;
  accounts: GlOverride[];
}
export interface DocTypeSeries {
  obj_type: number; label: string; module: string;
  series: Array<{ series_id: number; name: string; prefix: string; whs_code: string | null; is_default: boolean; locked: boolean }>;
}
export interface WarehouseSetup {
  company: string; can_write: boolean; can_series: boolean; can_finance: boolean; can_read_finance: boolean;
  warehouses: Warehouse[]; doc_types: DocTypeSeries[]; keys: CtxKey[];
}
export const useWarehouseSetup = (company: string) => useQuery({
  queryKey: ['whs-setup', company], enabled: Boolean(company), queryFn: () => rpc<WarehouseSetup>('warehouse_setup', { p_company: company }),
});
export const warehouseSave = (company: string, w: Record<string, unknown>) => rpc<{ whs_code: string; created: boolean }>('warehouse_save', { p_company: company, p_whs: w });
export const warehouseSeriesSet = (company: string, whs: string, obj: number, series: number | null) =>
  rpc<{ name: string | null }>('warehouse_series_set', { p_company: company, p_whs: whs, p_obj: obj, p_series: series });
export const whsBinsSet = (company: string, whs: string, on: boolean) => rpc('warehouse_inv_set', { p_company: company, p_whs: whs, p_setting: { bins_enabled: on } });
export const binSave = (company: string, b: Record<string, unknown>) => rpc('bin_save', { p_company: company, p_bin: b });

// ---------- Item groups ----------
export interface ItemGroup {
  group_code: number; name: string; origin: 'sap' | 'erp'; manage_method: 'none' | 'batch' | 'serial'; warranty_months: number | null;
  warranty_source: string | null; items: number; accounts: GlOverride[];
}
export interface ItemGroupSetup { company: string; can_write: boolean; can_finance: boolean; can_read_finance: boolean; groups: ItemGroup[]; keys: CtxKey[] }
export const useItemGroupSetup = (company: string) => useQuery({
  queryKey: ['ig-setup', company], enabled: Boolean(company), queryFn: () => rpc<ItemGroupSetup>('item_group_setup', { p_company: company }),
});
export const itemGroupSave = (company: string, g: Record<string, unknown>) => rpc<{ group_code: number; created: boolean }>('item_group_save', { p_company: company, p_group: g });

// ---------- Landed cost types ----------
export type LcMethod = 'qty' | 'weight' | 'cbm' | 'value' | 'equal';
export interface LcType { code: string; name: string; split_method: LcMethod; acct_code: string | null; acct_name: string | null; active: boolean; source: string; used: boolean }
export interface LcSetup { company: string; can_write: boolean; can_finance: boolean; clearing_acct: string | null; price_difference_acct: string | null; methods: LcMethod[]; codes: LcType[] }
export const useLcSetup = (company: string) => useQuery({
  queryKey: ['lc-setup', company], enabled: Boolean(company), queryFn: () => rpc<LcSetup>('landed_cost_setup', { p_company: company }),
});
export const lcTypeSave = (company: string, c: Record<string, unknown>) => rpc<LcType>('landed_cost_code_save', { p_company: company, p_code: c });

// ---------- Goods receipt / issue reasons ----------
export interface Reason { code: string; name: string; direction: 'in' | 'out' | 'both'; acct_code: string | null; gl_area: string | null; gl_key: string | null; active: boolean; source: string; note: string | null }
export const useReasons = (company: string) => useQuery({
  queryKey: ['reasons', company], enabled: Boolean(company),
  queryFn: async () => {
    const [r, k] = await Promise.all([
      erp().from('inventory_reason').select('code,name,direction,acct_code,gl_area,gl_key,active,source,note').eq('company_code', company).order('code'),
      erp().from('gl_posting_key').select('area,posting_key,label,tab,sort').order('sort'),
    ]);
    if (r.error) throw new ApiError(r.error);
    if (k.error) throw new ApiError(k.error);
    return { reasons: (r.data ?? []) as Reason[], keys: (k.data ?? []) as Array<{ area: string; posting_key: string; label: string; tab: GlTab }> };
  },
});
export const reasonSave = (company: string, r: Record<string, unknown>) => rpc<Reason & { gl_key: string | null }>('inventory_reason_save', { p_company: company, p_reason: r });

// ---------- Production resources ----------
export interface Resource { code: string; name: string; kind: 'mould' | 'machine' | 'labour' | 'other'; unit: 'shot' | 'hour' | 'unit'; unit_cost: number; acct_code: string | null; active: boolean }
export interface ProdSetup { currency: string; resources: Resource[]; accounts: Array<{ code: string; name: string }>; can_write: boolean; can_finance: boolean }
export const useProdSetup = (company: string) => useQuery({
  queryKey: ['prod-setup-b3', company], enabled: Boolean(company), queryFn: () => rpc<ProdSetup>('production_setup', { p_company: company }),
});
export const resourceSave = (company: string, r: Record<string, unknown>) => rpc<{ res_code: string }>('prod_resource_save', { p_company: company, p_res: r });
export const useAbsorptionAcct = (company: string) => useQuery({
  queryKey: ['gl-absorb', company], enabled: Boolean(company),
  queryFn: async () => {
    const { data, error } = await erp().from('gl_determination').select('acct_code').eq('company_code', company).eq('area', 'resources').eq('posting_key', 'resource_cost').maybeSingle();
    if (error) return null;   // no Financials access: the hint is simply not shown
    return (data as { acct_code: string } | null)?.acct_code ?? null;
  },
});
