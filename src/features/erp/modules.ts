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

/**
 * A3 · Financials Setup (new in Super ERP). In SAP these two screens sit under Administration (System Initialization ›
 * Posting Periods, Setup › Financials › G/L Account Determination); Finance users have no Administration access, so the
 * same working screens are also listed here. Not part of design-data.json.
 */
const FIN_SETUP = (no: number): MenuFunction => ({
  no, name: 'Financials Setup', submenu: true, flag: 'new',
  desc: 'Where every posting goes and which dates are open for posting. Finance with full access can change them; every change is logged.',
  items: [
    { name: 'G/L Account Determination', desc: 'The account each kind of posting uses: receivables, revenue, VAT, inventory…' },
    { name: 'Posting Periods', desc: 'Open, close or lock months. Nothing posts on dates in a closed or locked period.' },
  ],
});
const menu = (k: string) => D.MENU[k] ?? { desc: '' };

export const MODULES: ModuleDef[] = [
  { key: 'administration', num: '01', title: 'Administration', desc: 'Same 13 functions, same order as SAP Business One. System admin only.', access: ['admin', 'it'], functions: toFunctions(D.F) },
  { key: 'financials', num: '02', title: 'Financials', ...menu('financials'), access: ['finance'], functions: [...toFunctions(D.FIN), FIN_SETUP(toFunctions(D.FIN).length + 1)] },
  { key: 'sales', num: '03', title: 'Sales', ...menu('sales'), access: ['sales'], functions: toFunctions(D.SAL) },
  { key: 'purchasing', num: '04', title: 'Purchasing', ...menu('purchasing'), access: ['purchase'], functions: toFunctions(D.PUR) },
  { key: 'bp', num: '05', title: 'Business Partners', ...menu('bp'), access: ['bp', 'sales', 'purchase', 'finance'], functions: toFunctions(D.BPF) },
  { key: 'banking', num: '06', title: 'Banking', ...menu('banking'), access: ['finance', 'banking'], functions: toFunctions(D.BNK) },
  { key: 'inventory', num: '07', title: 'Inventory', ...menu('inventory'), access: ['inventory', 'purchase', 'sales'], functions: toFunctions(D.INV) },
  { key: 'production', num: '08', title: 'Production', ...menu('production'), access: ['production', 'inventory'], functions: toFunctions(D.PRD) },
  { key: 'service', num: '09', title: 'Service', ...menu('service'), access: ['service', 'sales'], functions: toFunctions(D.SVC) },
  { key: 'hr', num: '10', title: 'Human Resources', ...menu('hr'), access: ['hr'], functions: toFunctions(D.HRF) },
  { key: 'reports', num: '11', title: 'Reports', ...menu('reports'), access: ['finance', 'sales', 'purchase', 'inventory', 'hr', 'reports'], functions: toFunctions(D.REP) },
];

export const moduleByKey = (k: string | undefined) => MODULES.find((m) => m.key === k);

/** Owner/CFO ('business') and system admin see every module; others by their position's modules (read or full). */
export function canOpenModule(m: ModuleDef, userModules: string[]) {
  if (userModules.includes('business') || userModules.includes('admin')) return true;
  return m.access.some((a) => userModules.includes(a));
}

/**
 * Full access to at least one of the module's position modules (same rule as erp.can_write in 16_module_access.sql).
 * Owner and admin do not get write automatically. The database functions check again on every write.
 */
export function canWriteModule(m: ModuleDef, levels: Record<string, 'read' | 'full'>) {
  return m.access.some((a) => levels[a] === 'full');
}

// ---------- Which functions are connected to real data (Stage 1 read; A2 adds Sales Order create + approval) ----------
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
  // A10 · Administration
  administration: {
    'Exchange Rates and Indexes': '/admin/exchange-rates', 'Approval Process': '/admin/approval-templates', License: '/admin/users',
    'Data Import/Export': '/backoffice/migration',
  },
  financials: {
    'Chart of Accounts': '/financials/accounts', 'Journal Entry': '/financials/journals', 'Financials Setup': '/financials/gl-determination',
    // A11 · reports
    'Financial Reports': '/reports?cat=financials',
  },
  sales: {
    'Sales Quotation': '/docs/sales_quotation', 'Sales Order': '/docs/sales_order', Delivery: '/docs/delivery', Return: '/docs/sales_return',
    'A/R Down Payment Invoice': '/docs/ar_down_payment', 'A/R Invoice': '/docs/ar_invoice', 'A/R Credit Memo': '/docs/ar_credit_note',
    'Available-to-Promise Check': '/sales/atp',
    // A11 · reports
    'Sales Reports': '/reports?cat=sales_purchasing',
  },
  purchasing: {
    'Purchase Request': '/docs/purchase_request', 'Purchase Quotation': '/docs/purchase_quotation', 'Purchase Order': '/docs/purchase_order',
    'Goods Receipt PO': '/docs/goods_receipt_po', 'Goods Return': '/docs/goods_return', 'A/P Down Payment Invoice': '/docs/ap_down_payment',
    'A/P Invoice': '/docs/ap_invoice', 'A/P Credit Memo': '/docs/ap_credit_note',
    // A6 · China flow
    'Landed Costs': '/purchasing/landed-costs', 'PI Tracking Entry': '/docs/purchase_order?f_status=open',
    // A11 · reports
    'Purchasing Reports': '/reports?cat=sales_purchasing',
  },
  bp: { 'Business Partner Master Data': '/bp', 'Trademark Master': '/bp/trademarks', 'Business Partner Reports': '/reports?cat=bp' },
  banking: {
    'Incoming Payments': '/banking/payments/in', 'Outgoing Payments': '/banking/payments/out', Deposits: '/banking/deposits',
    'Bank Statements and External Reconciliations': '/banking/statements', 'Banking Reports': '/banking/cash-position',
  },
  inventory: {
    'Item Master Data': '/items', 'Price Lists': '/inventory/prices',
    // A7 · inventory transactions
    'Bin Locations': '/inventory/setup', 'Inventory Transactions': '/docs/inventory_transfer',
    // A11 · reports
    'Inventory Reports': '/reports?cat=inventory',
  },
  hr: {
    'Employee Master Data': '/hr/employees',
    // A9 · HR and Staff Portal
    'Human Resources Reports': '/hr/expiry', 'Roles and Duties': '/hr/setup', 'Attendance and Check-in': '/hr/attendance', Leave: '/hr/leave',
    Payroll: '/hr/payroll', 'Staff Portal': '/portal',
  },
  // A13 · Production and Service
  production: {
    'Bill of Materials': '/production/boms', 'Production Order': '/production/orders', 'Receipt from Production': '/production/orders?f_state=released',
    'Issue for Production': '/production/orders?f_state=released', 'Bill of Materials Management': '/production/boms',
  },
  service: {
    'Service Call': '/service/calls', 'Equipment Card': '/service/equipment', 'Service Contract': '/service/contracts',
  },
  // A11 · Reports: report library (read-only SQL functions with the user's own rights), Ask AI for a Report
  reports: {
    Financials: '/reports?cat=financials', 'Sales and Purchasing': '/reports?cat=sales_purchasing', 'Business Partners': '/reports?cat=bp',
    Inventory: '/reports?cat=inventory', 'Ask AI for a Report': '/reports?ask=1',
  },
};
/** sub-function (item) name → working screen, wherever it appears */
const LIVE_ITEMS: Record<string, string> = {
  'Goods Receipt': '/docs/goods_receipt', 'Goods Issue': '/docs/goods_issue', 'Inventory Transfer Request': '/docs/transfer_request',
  'Inventory Transfer': '/docs/inventory_transfer', 'Inventory Status': '/inventory/stock', 'Items List': '/items',
  'Inventory in Warehouse Report': '/reports/inventory-in-warehouse', 'Find an item': '/items', 'Stock per warehouse': '/inventory/stock', 'Price Report': '/inventory/prices',
  'SAP B1 migration (new, one-time)': '/backoffice/migration', 'Daily rates table': '/admin/exchange-rates',
  // A12 · special prices and period/volume discounts from SAP (OSPP/SPP1, OEDG/EDG1)
  'Special prices for partners': '/inventory/special-prices', 'Period and volume discounts': '/inventory/discounts',
  'Approval Status Report': '/approvals', 'Approval Decision Report': '/approvals?view=decided',
  'New sales order': '/docs/sales_order/new',
  // A4 · sales cycle
  'New quotation': '/docs/sales_quotation/new', 'Open quotations': '/docs/sales_quotation?f_status=open', 'Copy to sales order': '/docs/sales_quotation?f_status=open',
  'Copy to delivery': '/docs/sales_order?f_status=open', 'New delivery': '/docs/sales_order?f_status=open',
  'Delivery note': '/docs/delivery', 'New invoice': '/docs/ar_invoice/new', 'UAE tax invoice': '/docs/ar_invoice',
  'Check an item': '/sales/atp', 'Promise a date': '/sales/atp', 'Sales ›': '/sales/atp-rules',
  // A3 · posting engine
  'New journal entry': '/financials/journals/new', 'Recent entries': '/financials/journals',
  'G/L Account Determination': '/financials/gl-determination', 'G/L Account Determination ›': '/financials/gl-determination',
  'Posting Periods': '/financials/periods',
  // A5 · banking
  'Incoming Payments': '/banking/payments/in', 'Outgoing Payments': '/banking/payments/out', 'Check Register': '/banking/deposits/new',
  Deposit: '/banking/deposits/new', 'Postdated Check Deposit': '/banking/deposits/new',
  'Import bank statement': '/banking/statements', 'Auto-match': '/banking/statements', 'Manual reconciliation': '/banking/statements',
  'Manage previous reconciliations': '/banking/statements', 'Payment Drafts Report': '/banking/payment-drafts',
  'BP Bank Accounts Query': '/banking/bp-bank-accounts', 'House Bank Accounts Query': '/banking/cash-position', 'Bank balances': '/banking/cash-position',
  'House Bank Accounts': '/banking/setup', 'Banking ›': '/banking/setup',
  // A6 · purchasing, China flow
  'Requests waiting': '/docs/purchase_request?f_status=open', Convert: '/docs/purchase_request?f_status=open',
  'New quotation request': '/docs/purchase_quotation/new', 'Compare quotes': '/docs/purchase_request?f_status=open',
  'Purchase Quotation Comparison Report': '/docs/purchase_request?f_status=open', 'Copy to purchase order': '/docs/purchase_quotation?f_status=open',
  'New purchase order': '/docs/purchase_order/new', 'Waiting approval': '/docs/purchase_order?f_state=pending_approval', 'Open POs': '/docs/purchase_order?f_status=open',
  'Copy to goods receipt': '/docs/purchase_order?f_status=open', 'Receive against PO': '/docs/purchase_order?f_status=open',
  'Record deposit invoice': '/docs/purchase_order?f_status=open', 'Open deposits': '/docs/ap_down_payment?f_status=open',
  'New A/P invoice': '/docs/goods_receipt_po?f_status=open', 'New landed cost': '/purchasing/landed-costs/new', 'Cost lines': '/purchasing/landed-costs',
  'Allocation method': '/purchasing/setup', 'Update item costs': '/purchasing/landed-costs', 'Purchasing ›': '/purchasing/setup',
  'New PI entry': '/docs/purchase_order?f_status=open', 'Deposit status': '/docs/ap_down_payment',
  // A7 · inventory: counting, batches / serials, bins, item history
  'Inventory Counting Transactions ›': '/inventory/counts', 'Item Serial Numbers ›': '/inventory/serials', 'Batches ›': '/inventory/batches',
  'Batches and serials': '/inventory/serials', 'Bin Location Master Data': '/inventory/setup', 'Bin Location Management': '/inventory/setup',
  'Item history': '/items', 'Inventory ›': '/inventory/setup', 'Bin Locations': '/inventory/setup',
  // A8 · master data
  'New business partner': '/bp/new', Customers: '/bp?f_kind=customer', 'Suppliers and factories': '/bp?f_kind=supplier', Leads: '/bp?f_kind=lead',
  'Credit limits and payment terms': '/bp/changes', '360° view': '/bp', 'Trademark registrations': '/bp/trademarks', 'Brand list': '/bp/trademarks',
  'New item': '/items/new', 'Barcodes per item': '/items',
  // A9 · HR and Staff Portal
  'Find an employee': '/hr/employees', 'New employee': '/hr/employees/new', 'Document expiry dates': '/hr/expiry', 'Employee List': '/hr/employees',
  'Absence Report': '/hr/leave?f_state=approved', 'Duty templates per role': '/hr/setup', 'Today\u2019s attendance': '/hr/attendance', 'Phone check-in': '/portal',
  'Late and absent': '/hr/attendance?f_flagged=true', Shifts: '/hr/setup', 'Leave requests': '/hr/leave', 'Leave balances': '/portal', 'Holiday calendar': '/hr/setup',
  'Monthly payroll run': '/hr/payroll', 'WPS salary file': '/hr/payroll', Payslips: '/portal', 'End-of-service': '/hr/employees', 'My day': '/portal',
  'Check in and out': '/portal', 'Leave and payslips': '/portal',
  // A10 · Administration
  'Company Details': '/admin/company', 'Authorizations ›': '/admin/authorizations', 'Document Numbering': '/admin/numbering',
  'Rate history': '/admin/exchange-rates', 'Approval Templates': '/admin/approval-templates', 'Approval Stages': '/admin/approval-templates',
  'General ›': '/admin/users', 'License Administration': '/admin/users', 'AI Assistant (new)': '/admin/ai-assistant',
  // A14 · go-live checklist and system health
  'Implementation Center ›': '/admin/go-live',
  // A11 · reports and Ask AI
  'Financial ›': '/reports?cat=financials', 'Open Items List': '/reports/open-items', 'Sales Analysis': '/reports/sales-analysis',
  'Customer receivables ageing': '/reports/ar-aging', 'Supplier liabilities ageing': '/reports/ap-aging', 'Aging ›': '/reports/ar-aging',
  'Customer Receivables by Customer Cross-Section': '/reports/ar-aging', 'Inventory in warehouse': '/reports/inventory-in-warehouse',
  'Inventory valuation': '/reports/inventory-valuation', 'Ask in plain words': '/reports?ask=1',
  // A13 · production and service
  'Find a BOM': '/production/boms', 'New BOM': '/production/boms/new', 'BOM types': '/production/boms', 'Mould or tool used': '/production/moulds',
  'New production order': '/production/orders/new', 'Open orders': '/production/orders?f_state=released', 'Release to the floor': '/production/orders?f_state=planned',
  'Close order': '/production/orders?f_state=released', 'Receive output': '/production/orders?f_state=released', 'Issue components': '/production/orders?f_state=released',
  'Extra issue': '/production/orders?f_state=released', 'Find where used': '/production/boms', 'Bill of Materials Report': '/production/boms',
  'Production ›': '/production/setup', 'Route stages and production settings, mould records': '/production/moulds',
  'New service call': '/service/calls/new', 'Open calls': '/service/calls?f_status=open', 'Assign technician': '/service/calls?f_status=open',
  'Parts and labour': '/service/calls?f_status=in_progress', 'Close with solution': '/service/calls?f_status=resolved',
  'Find by serial number': '/service/equipment', 'Warranty status': '/service/equipment', 'Service history': '/service/equipment',
  'New contract': '/service/contracts/new', Coverage: '/service/contracts', 'Response time': '/service/contracts', 'Renewals due': '/service/contracts?f_state=active',
  'Service Calls': '/service/calls', 'Service Contracts': '/service/contracts', 'Equipment Card Report': '/service/equipment',
  'My Service Calls': '/service/calls', 'Service ›': '/service/setup',
};

/** module › SAP function name → create screen (documents that can be raised in Super ERP; the database checks every write) */
const CREATE_FUNCTIONS: Partial<Record<ModuleKey, Record<string, string>>> = {
  sales: { 'Sales Quotation': '/docs/sales_quotation/new', 'Sales Order': '/docs/sales_order/new', 'A/R Invoice': '/docs/ar_invoice/new' },
  financials: { 'Journal Entry': '/financials/journals/new' },
  banking: { 'Incoming Payments': '/banking/payments/in/new', 'Outgoing Payments': '/banking/payments/out/new', Deposits: '/banking/deposits/new' },
  purchasing: {
    'Purchase Request': '/docs/purchase_request/new', 'Purchase Quotation': '/docs/purchase_quotation/new', 'Purchase Order': '/docs/purchase_order/new',
    'Landed Costs': '/purchasing/landed-costs/new',
  },
  inventory: { 'Inventory Transactions': '/inventory/transfer/new', 'Item Master Data': '/items/new' },
  bp: { 'Business Partner Master Data': '/bp/new' },
  hr: { 'Employee Master Data': '/hr/employees/new', Leave: '/portal' },
  administration: { License: '/admin/users/invite' },
  production: { 'Bill of Materials': '/production/boms/new', 'Production Order': '/production/orders/new' },
  service: { 'Service Call': '/service/calls/new', 'Service Contract': '/service/contracts/new', 'Equipment Card': '/service/equipment/new' },
};

export const liveRouteForFunction = (m: ModuleKey, fn: string) => LIVE_FUNCTIONS[m]?.[fn];
export const createRouteForFunction = (m: ModuleKey, fn: string) => CREATE_FUNCTIONS[m]?.[fn];
export const liveRouteForItem = (name: string) => LIVE_ITEMS[name] || undefined;

/** Sub-screens drawn in the canvas (shown as labelled design previews until built). */
export const PREVIEW_SCREENS = D.SUBS as Record<string, { parent: string; title: string; desc: string; primary?: string }>;
export const designData = D;
