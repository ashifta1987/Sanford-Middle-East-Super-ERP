import { useQuery } from '@tanstack/react-query';
import i18n from '@/lib/i18n';
import { rpc } from './api';

/**
 * A11 · Report library. Each report is a read-only SQL function in 26_reports.sql (SECURITY INVOKER: the user's own rights).
 * `needs`: position modules, any of which lets the user run it (owner 'business' and 'admin' read everything). The database
 * checks again and refuses with the same words.
 */
export type ColType = 'text' | 'code' | 'money' | 'qty' | 'int' | 'date' | 'pct';
export type Row = Record<string, unknown>;
export interface ReportCol { key: string; type: ColType; total?: boolean; hide?: 'sm' | 'md' | 'lg'; link?: (r: Row, company: string) => string | undefined }
export type ParamKey = 'range' | 'as_of' | 'by' | 'kind' | 'whs';
export type ReportCat = 'financials' | 'sales_purchasing' | 'bp' | 'inventory';
export interface ReportDef {
  code: string;
  rpc: string;
  cat: ReportCat;
  /** SAP menu item (design-data.json) this report fills, if any */
  menuItem?: string;
  needs: string[];
  needsLabel: string;
  params: ParamKey[];
  columns: ReportCol[];
  /** rows grouped by `section` with subtotals (balance sheet, P&L); the row with section `net_profit` is the grand total */
  sections?: string[];
  chart: { label: string; value: string; top?: number; sections?: boolean };
}

const bp = (r: Row, c: string) => (r.card_code ? `/bp/${c}/${encodeURIComponent(String(r.card_code))}` : undefined);
const item = (r: Row, c: string) => (r.item_code ? `/items/${c}/${encodeURIComponent(String(r.item_code))}` : undefined);
const acct = (r: Row) => (r.acct_code ? `/financials/accounts?q=${encodeURIComponent(String(r.acct_code))}` : undefined);

export const REPORTS: ReportDef[] = [
  {
    code: 'trial-balance', rpc: 'rpt_trial_balance', cat: 'financials', needs: ['finance'], needsLabel: 'Financials', params: ['range'],
    columns: [
      { key: 'acct_code', type: 'code', link: acct }, { key: 'acct_name', type: 'text' },
      { key: 'opening', type: 'money', total: true, hide: 'md' }, { key: 'debit', type: 'money', total: true },
      { key: 'credit', type: 'money', total: true }, { key: 'closing', type: 'money', total: true },
    ],
    chart: { label: 'acct_name', value: 'closing', top: 8 },
  },
  {
    code: 'balance-sheet', rpc: 'rpt_balance_sheet', cat: 'financials', needs: ['finance'], needsLabel: 'Financials', params: ['as_of'],
    columns: [{ key: 'acct_code', type: 'code', link: acct }, { key: 'acct_name', type: 'text' }, { key: 'amount', type: 'money' }],
    sections: ['assets', 'liabilities', 'equity'],
    chart: { label: 'section', value: 'amount', sections: true },
  },
  {
    code: 'profit-loss', rpc: 'rpt_profit_loss', cat: 'financials', needs: ['finance'], needsLabel: 'Financials', params: ['range'],
    columns: [{ key: 'acct_code', type: 'code', link: acct }, { key: 'acct_name', type: 'text' }, { key: 'amount', type: 'money' }],
    sections: ['revenue', 'cost_of_sales', 'expenses', 'other'],
    chart: { label: 'section', value: 'amount', sections: true },
  },
  {
    code: 'ar-aging', rpc: 'rpt_ar_aging', cat: 'bp', menuItem: 'Customer receivables ageing', needs: ['sales', 'finance'], needsLabel: 'Sales or Financials',
    params: ['as_of'],
    columns: [
      { key: 'card_code', type: 'code', link: bp }, { key: 'card_name', type: 'text' }, { key: 'docs', type: 'int', hide: 'lg' },
      { key: 'not_due', type: 'money', total: true, hide: 'md' }, { key: 'd1_30', type: 'money', total: true, hide: 'md' },
      { key: 'd31_60', type: 'money', total: true, hide: 'md' }, { key: 'd61_90', type: 'money', total: true, hide: 'md' },
      { key: 'd90_plus', type: 'money', total: true, hide: 'sm' }, { key: 'total', type: 'money', total: true },
    ],
    chart: { label: 'card_name', value: 'total', top: 8 },
  },
  {
    code: 'ap-aging', rpc: 'rpt_ap_aging', cat: 'bp', menuItem: 'Supplier liabilities ageing', needs: ['purchase', 'finance'], needsLabel: 'Purchasing or Financials',
    params: ['as_of'],
    columns: [
      { key: 'card_code', type: 'code', link: bp }, { key: 'card_name', type: 'text' }, { key: 'docs', type: 'int', hide: 'lg' },
      { key: 'not_due', type: 'money', total: true, hide: 'md' }, { key: 'd1_30', type: 'money', total: true, hide: 'md' },
      { key: 'd31_60', type: 'money', total: true, hide: 'md' }, { key: 'd61_90', type: 'money', total: true, hide: 'md' },
      { key: 'd90_plus', type: 'money', total: true, hide: 'sm' }, { key: 'total', type: 'money', total: true },
    ],
    chart: { label: 'card_name', value: 'total', top: 8 },
  },
  {
    code: 'sales-analysis', rpc: 'rpt_sales_analysis', cat: 'sales_purchasing', menuItem: 'Sales Analysis', needs: ['sales', 'finance'],
    needsLabel: 'Sales or Financials', params: ['range', 'by'],
    columns: [
      { key: 'key', type: 'code', link: (r, c) => (r.by === 'customer' ? `/bp/${c}/${encodeURIComponent(String(r.key))}` : r.by === 'item' ? `/items/${c}/${encodeURIComponent(String(r.key))}` : undefined) },
      { key: 'name', type: 'text' }, { key: 'docs', type: 'int', total: true, hide: 'md' }, { key: 'qty', type: 'qty', total: true, hide: 'md' },
      { key: 'net_sales', type: 'money', total: true }, { key: 'gross_profit', type: 'money', total: true, hide: 'sm' }, { key: 'margin_pct', type: 'pct', hide: 'sm' },
    ],
    chart: { label: 'name', value: 'net_sales', top: 8 },
  },
  {
    code: 'open-items', rpc: 'rpt_open_items', cat: 'sales_purchasing', menuItem: 'Open Items List', needs: ['sales', 'purchase', 'finance', 'inventory'],
    needsLabel: 'Sales, Purchasing, Inventory or Financials', params: ['kind'],
    columns: [
      { key: 'doc_no', type: 'code', link: (r) => r.link as string }, { key: 'doc_kind', type: 'text' }, { key: 'doc_date', type: 'date', hide: 'sm' },
      { key: 'card_name', type: 'text', hide: 'sm' }, { key: 'days_open', type: 'int', hide: 'md' },
      { key: 'total', type: 'money', total: true, hide: 'md' }, { key: 'open_amount', type: 'money', total: true },
    ],
    chart: { label: 'doc_kind', value: 'open_amount', top: 8 },
  },
  {
    code: 'inventory-in-warehouse', rpc: 'rpt_inventory_in_warehouse', cat: 'inventory', menuItem: 'Inventory in Warehouse Report',
    needs: ['inventory', 'sales', 'purchase'], needsLabel: 'Inventory, Sales or Purchasing', params: ['whs'],
    columns: [
      { key: 'whs_code', type: 'code' }, { key: 'item_code', type: 'code', link: item }, { key: 'item_name', type: 'text', hide: 'sm' },
      { key: 'on_hand', type: 'qty', total: true }, { key: 'committed', type: 'qty', total: true, hide: 'md' }, { key: 'on_order', type: 'qty', total: true, hide: 'md' },
      { key: 'available', type: 'qty', total: true, hide: 'lg' }, { key: 'avg_cost', type: 'money', hide: 'lg' }, { key: 'value', type: 'money', total: true },
    ],
    chart: { label: 'whs_code', value: 'value', top: 8 },
  },
  {
    code: 'inventory-valuation', rpc: 'rpt_inventory_valuation', cat: 'inventory', needs: ['inventory'], needsLabel: 'Inventory', params: [],
    columns: [
      { key: 'item_code', type: 'code', link: item }, { key: 'item_name', type: 'text' }, { key: 'group_name', type: 'text', hide: 'md' },
      { key: 'on_hand', type: 'qty', total: true }, { key: 'avg_cost', type: 'money', hide: 'sm' }, { key: 'value', type: 'money', total: true },
    ],
    chart: { label: 'group_name', value: 'value', top: 8 },
  },
];
export const reportByCode = (c: string | undefined) => REPORTS.find((r) => r.code === c);
export const REPORT_CATS: Array<{ key: ReportCat; menu: string }> = [
  { key: 'financials', menu: 'Financials' }, { key: 'sales_purchasing', menu: 'Sales and Purchasing' },
  { key: 'bp', menu: 'Business Partners' }, { key: 'inventory', menu: 'Inventory' },
];
export const OPEN_KINDS = ['sales_quotation', 'sales_order', 'delivery', 'ar_invoice', 'ar_credit_note', 'ar_down_payment', 'purchase_request',
  'purchase_quotation', 'purchase_order', 'goods_receipt_po', 'ap_invoice', 'ap_credit_note', 'ap_down_payment', 'transfer_request'] as const;

/** Can this user run the report (same rule as erp._rpt_need: any of the modules, or owner / admin)? */
export function canRun(def: ReportDef, modules: string[]) {
  return modules.includes('business') || modules.includes('admin') || def.needs.some((m) => modules.includes(m));
}

const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
export const todayIso = () => iso(new Date());
export const yearStartIso = () => `${new Date().getFullYear()}-01-01`;

export interface ReportParams { company: string; from: string; to: string; as_of: string; by: string; kind: string; whs: string }
export function defaultParams(sp: URLSearchParams, company: string): ReportParams {
  return {
    company: sp.get('company') || company, from: sp.get('from') || yearStartIso(), to: sp.get('to') || todayIso(),
    as_of: sp.get('as_of') || todayIso(), by: sp.get('by') || 'customer', kind: sp.get('kind') || '', whs: sp.get('whs') || '',
  };
}
function args(def: ReportDef, p: ReportParams): Record<string, unknown> {
  const a: Record<string, unknown> = { p_company: p.company };
  if (def.params.includes('range')) { a.p_from = p.from || null; a.p_to = p.to || null; }
  if (def.params.includes('as_of')) a.p_as_of = p.as_of || null;
  if (def.params.includes('by')) a.p_by = p.by;
  if (def.params.includes('kind')) a.p_kind = p.kind || null;
  if (def.params.includes('whs')) a.p_whs = p.whs || null;
  return a;
}
export const useReport = (def: ReportDef | undefined, p: ReportParams, enabled: boolean) => useQuery({
  queryKey: ['report', def?.code, p], enabled: Boolean(def) && enabled, retry: false,
  queryFn: async () => {
    const rows = await rpc<Row[]>(def!.rpc, args(def!, p));
    return def!.code === 'sales-analysis' ? rows.map((r) => ({ ...r, by: p.by })) : rows;
  },
});

/** Search-param string for links (report page, print sheet). */
export function paramString(def: ReportDef, p: ReportParams) {
  const s = new URLSearchParams({ company: p.company });
  if (def.params.includes('range')) { s.set('from', p.from); s.set('to', p.to); }
  if (def.params.includes('as_of')) s.set('as_of', p.as_of);
  if (def.params.includes('by')) s.set('by', p.by);
  if (def.params.includes('kind') && p.kind) s.set('kind', p.kind);
  if (def.params.includes('whs') && p.whs) s.set('whs', p.whs);
  return s.toString();
}

// ---------- Values on screen and in the CSV (same function, so the export matches the table) ----------
const money = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const qty = new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 });
const int = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const isNil = (v: unknown) => v === null || v === undefined || v === '';

/** Label of a column or a section in the current language. */
export const colLabel = (k: string) => i18n.t(`rpt.col.${k}`, { defaultValue: k });
export const sectionLabel = (k: string) => i18n.t(`rpt.section.${k}`, { defaultValue: k });

/** Text of a cell for the screen. */
export function cellText(c: ReportCol, r: Row): string {
  const v = r[c.key];
  if (isNil(v)) {
    if (c.key === 'acct_name' && r.section === 'equity') return i18n.t('rpt.currentResult');
    return '—';
  }
  switch (c.type) {
    case 'money': return money.format(Number(v));
    case 'qty': return qty.format(Number(v));
    case 'int': return int.format(Number(v));
    case 'pct': return `${Number(v).toFixed(1)} %`;
    case 'date': return new Intl.DateTimeFormat(i18n.language === 'ar' ? 'ar-AE' : 'en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(String(v)));
    default:
      if (c.key === 'doc_kind') return i18n.t(`erp.doc.${String(v)}`, { defaultValue: String(v) });
      if (c.key === 'name' && r.key === '-1') return i18n.t('rpt.noSalesperson');
      if (c.key === 'acct_name' && isNil(r.acct_code) && r.section === 'equity') return i18n.t('rpt.currentResult');
      return String(v);
  }
}
/** Value of a cell for the CSV: plain numbers (2 decimals for money), ISO dates, the same text otherwise. */
export function csvValue(c: ReportCol, r: Row): string {
  const v = r[c.key];
  if (isNil(v)) return c.key === 'acct_name' && r.section === 'equity' ? i18n.t('rpt.currentResult') : '';
  switch (c.type) {
    case 'money': return Number(v).toFixed(2);
    case 'qty': return String(Number(v));
    case 'int': return String(Math.round(Number(v)));
    case 'pct': return Number(v).toFixed(1);
    case 'date': return String(v).slice(0, 10);
    default: return cellText(c, r);
  }
}
/** Data rows in screen order (sections first, in their order; the net-profit row is a total, not data). */
export function orderedRows(def: ReportDef, rows: Row[]) {
  if (!def.sections) return rows;
  return def.sections.flatMap((s) => rows.filter((r) => r.section === s));
}
export function buildCsv(def: ReportDef, rows: Row[]) {
  const esc = (s: string) => (/[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
  const cols = def.columns;
  const head = [...(def.sections ? [i18n.t('rpt.col.section')] : []), ...cols.map((c) => colLabel(c.key))];
  const body = orderedRows(def, rows).map((r) => [...(def.sections ? [sectionLabel(String(r.section))] : []), ...cols.map((c) => csvValue(c, r))]);
  return '\ufeff' + [head, ...body].map((l) => l.map(esc).join(',')).join('\r\n');
}
export function downloadCsv(def: ReportDef, rows: Row[], company: string) {
  const blob = new Blob([buildCsv(def, rows)], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${def.code}-${company}-${todayIso()}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
