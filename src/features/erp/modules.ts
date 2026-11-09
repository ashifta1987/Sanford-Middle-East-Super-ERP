import data from './design-data.json';

/** One SAP function in a module menu (from the canvas design, matched to the SAP B1 menu photos). */
export interface MenuItem { name: string; desc: string; preview?: string }
export interface MenuFunction {
  no: number;
  name: string;
  submenu: boolean;
  desc: string;
  items: MenuItem[];
  note?: string;
  /** off = disabled in the current SAP · custom = SAP add-on/customisation · new = added in Super ERP */
  flag?: 'off' | 'custom' | 'new';
}
export type ModuleKey =
  | 'administration' | 'financials' | 'sales' | 'purchasing' | 'bp' | 'banking'
  | 'inventory' | 'production' | 'service' | 'hr' | 'reports';
export interface ModuleDef {
  key: ModuleKey;
  num: string;
  title: string;
  desc: string;
  primary?: string;
  /** position modules (erp.position.module_access) that open this module; owner ('business') and 'admin' see all */
  access: string[];
  functions: MenuFunction[];
}

type RawFn = [string, boolean, string, Array<[string, string, string?]>, string?, (string | boolean)?];

function toFunctions(raw: unknown): MenuFunction[] {
  return (raw as RawFn[]).map((f, i) => ({
    no: i + 1,
    name: f[0],
    submenu: Boolean(f[1]),
    desc: f[2],
    items: (f[3] ?? []).map(([name, desc, preview]) => ({ name, desc, preview: preview || undefined })),
    note: typeof f[4] === 'string' && f[4] ? f[4] : undefined,
    flag: f[5] === true ? 'off' : f[5] === 'custom' ? 'custom' : f[5] === 'new' ? 'new' : undefined,
  }));
}

const D = data as unknown as Record<string, unknown> & { MENU: Record<string, { desc: string; primary?: string }> };
const menu = (k: string) => D.MENU[k] ?? { desc: '' };

export const MODULES: ModuleDef[] = [
  { key: 'administration', num: '01', title: 'Administration', desc: 'Same 13 functions, same order as SAP Business One. System admin only.', access: ['admin', 'it'], functions: toFunctions(D.F) },
  { key: 'financials', num: '02', title: 'Financials', ...menu('financials'), access: ['finance'], functions: toFunctions(D.FIN) },
  { key: 'sales', num: '03', title: 'Sales', ...menu('sales'), access: ['sales'], functions: toFunctions(D.SAL) },
  { key: 'purchasing', num: '04', title: 'Purchasing', ...menu('purchasing'), access: ['purchase'], functions: toFunctions(D.PUR) },
  { key: 'bp', num: '05', title: 'Business Partners', ...menu('bp'), access: ['sales', 'purchase', 'finance'], functions: toFunctions(D.BPF) },
  { key: 'banking', num: '06', title: 'Banking', ...menu('banking'), access: ['finance', 'banking'], functions: toFunctions(D.BNK) },
  { key: 'inventory', num: '07', title: 'Inventory', ...menu('inventory'), access: ['inventory', 'purchase', 'sales'], functions: toFunctions(D.INV) },
  { key: 'production', num: '08', title: 'Production', ...menu('production'), access: ['production', 'inventory'], functions: toFunctions(D.PRD) },
  { key: 'service', num: '09', title: 'Service', ...menu('service'), access: ['service', 'sales'], functions: toFunctions(D.SVC) },
  { key: 'hr', num: '10', title: 'Human Resources', ...menu('hr'), access: ['hr'], functions: toFunctions(D.HRF) },
  { key: 'reports', num: '11', title: 'Reports', ...menu('reports'), access: ['finance', 'sales', 'purchase', 'inventory', 'hr', 'reports'], functions: toFunctions(D.REP) },
];

export const moduleByKey = (k: string | undefined) => MODULES.find((m) => m.key === k);

/** Owner/CFO ('business') and system admin see every module; others by their position's modules. */
export function canOpenModule(m: ModuleDef, userModules: string[]) {
  if (userModules.includes('business') || userModules.includes('admin')) return true;
  return m.access.some((a) => userModules.includes(a));
}

// ---------- Which functions are connected to real data (Stage 1) ----------
/** SAP document types as stored in erp.document (obj_type + doc_kind, see 11_erp_sync.sql). */
export const DOC_KINDS = {
  sales_quotation: { obj: 23, title: 'Sales quotations', side: 'customer', module: 'sales' },
  sales_order: { obj: 17, title: 'Sales orders', side: 'customer', module: 'sales' },
  delivery: { obj: 15, title: 'Deliveries', side: 'customer', module: 'sales' },
  sales_return: { obj: 16, title: 'Returns', side: 'customer', module: 'sales' },
  ar_down_payment: { obj: 203, title: 'A/R down payment invoices', side: 'customer', module: 'sales' },
  ar_invoice: { obj: 13, title: 'A/R invoices', side: 'customer', module: 'sales' },
  ar_credit_note: { obj: 14, title: 'A/R credit memos', side: 'customer', module: 'sales' },
  purchase_request: { obj: 1470000113, title: 'Purchase requests', side: 'none', module: 'purchasing' },
  purchase_quotation: { obj: 540000006, title: 'Purchase quotations', side: 'supplier', module: 'purchasing' },
  purchase_order: { obj: 22, title: 'Purchase orders', side: 'supplier', module: 'purchasing' },
  goods_receipt_po: { obj: 20, title: 'Goods receipt POs', side: 'supplier', module: 'purchasing' },
  goods_return: { obj: 21, title: 'Goods returns', side: 'supplier', module: 'purchasing' },
  ap_down_payment: { obj: 204, title: 'A/P down payment invoices', side: 'supplier', module: 'purchasing' },
  ap_invoice: { obj: 18, title: 'A/P invoices', side: 'supplier', module: 'purchasing' },
  ap_credit_note: { obj: 19, title: 'A/P credit memos', side: 'supplier', module: 'purchasing' },
  transfer_request: { obj: 1250000001, title: 'Inventory transfer requests', side: 'none', module: 'inventory' },
  inventory_transfer: { obj: 67, title: 'Inventory transfers', side: 'none', module: 'inventory' },
  goods_receipt: { obj: 59, title: 'Goods receipts', side: 'none', module: 'inventory' },
  goods_issue: { obj: 60, title: 'Goods issues', side: 'none', module: 'inventory' },
} as const;
export type DocKind = keyof typeof DOC_KINDS;
export const docKindByObj = (obj: number) => (Object.keys(DOC_KINDS) as DocKind[]).find((k) => DOC_KINDS[k].obj === obj);

/** module › SAP function name → working screen */
const LIVE_FUNCTIONS: Partial<Record<ModuleKey, Record<string, string>>> = {
  financials: { 'Chart of Accounts': '/financials/accounts', 'Journal Entry': '/financials/journals' },
  sales: {
    'Sales Quotation': '/docs/sales_quotation', 'Sales Order': '/docs/sales_order', Delivery: '/docs/delivery', Return: '/docs/sales_return',
    'A/R Down Payment Invoice': '/docs/ar_down_payment', 'A/R Invoice': '/docs/ar_invoice', 'A/R Credit Memo': '/docs/ar_credit_note',
  },
  purchasing: {
    'Purchase Request': '/docs/purchase_request', 'Purchase Quotation': '/docs/purchase_quotation', 'Purchase Order': '/docs/purchase_order',
    'Goods Receipt PO': '/docs/goods_receipt_po', 'Goods Return': '/docs/goods_return', 'A/P Down Payment Invoice': '/docs/ap_down_payment',
    'A/P Invoice': '/docs/ap_invoice', 'A/P Credit Memo': '/docs/ap_credit_note',
  },
  bp: { 'Business Partner Master Data': '/bp' },
  banking: { 'Incoming Payments': '/banking/payments/in', 'Outgoing Payments': '/banking/payments/out' },
  inventory: { 'Item Master Data': '/items', 'Price Lists': '/inventory/prices' },
  hr: { 'Employee Master Data': '/hr/employees' },
};
/** sub-function (item) name → working screen, wherever it appears */
const LIVE_ITEMS: Record<string, string> = {
  'Goods Receipt': '/docs/goods_receipt', 'Goods Issue': '/docs/goods_issue', 'Inventory Transfer Request': '/docs/transfer_request',
  'Inventory Transfer': '/docs/inventory_transfer', 'Inventory Status': '/inventory/stock', 'Items List': '/items',
  'Inventory in Warehouse Report': '/inventory/stock', 'Find an item': '/items', 'Stock per warehouse': '/inventory/stock', 'Price Report': '/inventory/prices',
  'SAP B1 migration (new, one-time)': '/backoffice/migration', 'Daily rates table': '',
};

export const liveRouteForFunction = (m: ModuleKey, fn: string) => LIVE_FUNCTIONS[m]?.[fn];
export const liveRouteForItem = (name: string) => LIVE_ITEMS[name] || undefined;

/** Sub-screens drawn in the canvas (shown as labelled design previews until built). */
export const PREVIEW_SCREENS = D.SUBS as Record<string, { parent: string; title: string; desc: string; primary?: string }>;
export const designData = D;
