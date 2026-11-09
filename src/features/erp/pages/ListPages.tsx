import { useMemo } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { erp } from '@/lib/supabase';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { LiveBadge, PageTitle, StatusTag, YesNo, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { DOC_KINDS, moduleByKey, type DocKind, type ModuleKey } from '../modules';
import type { Row } from '../api';
import { NewSalesOrderAction, StatePill } from './SalesOrderPages';
import { NewCycleAction } from './SalesCyclePages';
import { DraftsLink, NewJournalAction } from './JournalPages';
import { DraftsLink as PaymentDraftsLink, NewPaymentAction, PaymentsList } from './BankingPages';
import { NewPurchaseAction, isPurchaseKind } from './PurchasingPages';
import { NewInventoryAction } from './InventoryPages';
import { NewBpAction, NewItemAction } from './MasterDataPages';
import { HrLinks, NewEmployeeAction } from './HrAdminPages';
import { isInvKind } from '../inventory';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

function Frame({ module, title, desc, actions, children }: { module: ModuleKey; title: string; desc?: string; actions?: React.ReactNode; children: React.ReactNode }) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  return (
    <RequireModule module={module}>
      <PageTitle
        crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${m.key}`], [title, undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>}
        desc={desc}
        actions={actions}
      />
      {children}
    </RequireModule>
  );
}

// ---------- Business partners ----------
export function BusinessPartnersPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'business_partner', table: 'business_partner',
    select: 'company_code,card_code,kind,name,group_code,currency,credit_limit,balance,phone,email,city,country,active,source',
    searchCols: ['card_code', 'name', 'foreign_name', 'phone', 'email', 'trn'], searchLabel: t('erp.search.bp'),
    filters: [
      { key: 'kind', label: t('erp.col.type'), options: [['customer', t('erp.kind.customer')], ['supplier', t('erp.kind.supplier')], ['lead', t('erp.kind.lead')]] },
      { key: 'group_code', label: t('erp.col.group'), from: { table: 'bp_group', value: 'group_code', label: 'name' }, type: 'number' },
      { key: 'active', label: t('erp.col.status'), options: [['true', t('erp.status.active')], ['false', t('erp.status.inactive')]], type: 'boolean' },
      { key: 'source', label: t('erp.col.source'), options: [['erp', 'Super ERP'], ['sap', 'SAP Business One'], ['sample', t('erp.sampleData')]] },
    ],
    defaultSort: { col: 'card_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.card_code}`,
    rowLink: (r) => `/bp/${r.company_code}/${encodeURIComponent(r.card_code)}`,
    columns: [
      { key: 'card_code', header: t('erp.col.code'), mono: true },
      { key: 'name', header: t('erp.col.name') },
      { key: 'kind', header: t('erp.col.type'), cell: (r) => t(`erp.kind.${r.kind}`, { defaultValue: r.kind }) },
      { key: 'city', header: t('erp.col.city'), hideBelow: 'md', cell: (r) => [r.city, r.country].filter(Boolean).join(', ') || '—' },
      { key: 'phone', header: t('erp.col.phone'), hideBelow: 'lg' },
      { key: 'balance', header: t('erp.col.balance'), align: 'end', cell: (r) => fmtMoney(r.balance) },
      { key: 'credit_limit', header: t('erp.col.creditLimit'), align: 'end', hideBelow: 'md',
        cell: (r) => <span className={Number(r.credit_limit) > 0 && Number(r.balance) > Number(r.credit_limit) ? 'font-semibold text-crit-fg' : ''}>{fmtMoney(r.credit_limit)}</span> },
      { key: 'active', header: t('erp.col.status'), cell: (r) => <StatusTag value={r.active ? 'active' : 'inactive'} />, csv: (r) => (r.active ? 'active' : 'inactive') },
    ],
  }), [t]);
  return (
    <Frame module="bp" title={t('erp.page.bp')} desc={t('erp.page.bpDesc')} actions={<><Link to="/bp/changes" className="inline-flex min-h-[44px] items-center rounded-btn border border-line bg-surface px-4 text-[15px] font-medium hover:bg-page">{t('md.req.listTitle')}</Link><NewBpAction /></>}>
      <ListScreen config={cfg} />
    </Frame>
  );
}

// ---------- Items ----------
export function ItemsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'item', table: 'item',
    select: 'company_code,item_code,name,group_code,category,barcode,inventory_uom,is_stock,is_sold,is_bought,avg_cost,active,source',
    searchCols: ['item_code', 'name', 'foreign_name', 'barcode', 'category'], searchLabel: t('erp.search.item'),
    filters: [
      { key: 'group_code', label: t('erp.col.itemGroup'), from: { table: 'item_group', value: 'group_code', label: 'name' }, type: 'number' },
      { key: 'is_stock', label: t('erp.col.inventoryItem'), options: [['true', t('erp.yes')], ['false', t('erp.no')]], type: 'boolean' },
      { key: 'active', label: t('erp.col.status'), options: [['true', t('erp.status.active')], ['false', t('erp.status.inactive')]], type: 'boolean' },
      { key: 'source', label: t('erp.col.source'), options: [['erp', 'Super ERP'], ['sap', 'SAP Business One'], ['sample', t('erp.sampleData')]] },
    ],
    defaultSort: { col: 'item_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.item_code}`,
    rowLink: (r) => `/items/${r.company_code}/${encodeURIComponent(r.item_code)}`,
    columns: [
      { key: 'item_code', header: t('erp.col.itemNo'), mono: true },
      { key: 'name', header: t('erp.col.description') },
      { key: 'category', header: t('erp.col.category'), hideBelow: 'md' },
      { key: 'barcode', header: t('erp.col.barcode'), mono: true, hideBelow: 'lg' },
      { key: 'inventory_uom', header: t('erp.col.uom'), hideBelow: 'md' },
      { key: 'is_stock', header: t('erp.col.inventoryItem'), cell: (r) => <YesNo value={r.is_stock} />, hideBelow: 'sm' },
      { key: 'avg_cost', header: t('erp.col.avgCost'), align: 'end', cell: (r) => fmtMoney(r.avg_cost) },
      { key: 'active', header: t('erp.col.status'), cell: (r) => <StatusTag value={r.active ? 'active' : 'inactive'} />, csv: (r) => (r.active ? 'active' : 'inactive') },
    ],
  }), [t]);
  return (
    <Frame module="inventory" title={t('erp.page.items')} desc={t('erp.page.itemsDesc')} actions={<NewItemAction />}>
      <ListScreen config={cfg} />
    </Frame>
  );
}

// ---------- Documents (all 19 SAP marketing / inventory document types) ----------
export function DocumentsPage() {
  const { t } = useTranslation();
  const { kind = '' } = useParams();
  const def = DOC_KINDS[kind as DocKind];
  // Sales orders read sales_order_list (17); quotations, deliveries, invoices and credit memos read sales_doc_list (19): both carry
  // the Super ERP workflow state and number. Other kinds read erp.document.
  const cycle = ['sales_quotation', 'delivery', 'ar_invoice', 'ar_credit_note'].includes(kind);
  // A6: purchasing kinds read purchase_doc_list (Super ERP number, state and China office).
  const pu = isPurchaseKind(kind);
  // A7: inventory kinds read inventory_doc_list (Super ERP number and state, from / to warehouse).
  const inv = isInvKind(kind);
  const so = kind === 'sales_order' || cycle || pu || inv;
  const cfg = useMemo<ListConfig<R> | null>(() => def ? ({
    id: `document-${kind}`,
    table: kind === 'sales_order' ? 'sales_order_list' : cycle ? 'sales_doc_list' : pu ? 'purchase_doc_list' : inv ? 'inventory_doc_list' : 'document',
    select: so
      ? `company_code,obj_type,doc_entry,doc_num,doc_no,doc_kind,status,state,doc_date,due_date,card_code,card_name,customer_ref,currency,total,vat_total,source${cycle || pu ? ',paid' : ''}${pu ? ',china_office' : ''}${inv ? ',from_whs,to_whs' : ''}`
      : 'company_code,obj_type,doc_entry,doc_num,doc_kind,status,doc_date,due_date,card_code,card_name,customer_ref,currency,total,vat_total,paid,from_whs,to_whs',
    searchCols: so ? ['card_code', 'card_name', 'customer_ref', 'comments', 'doc_no'] : ['card_code', 'card_name', 'customer_ref', 'comments'],
    numberSearchCols: ['doc_num'], searchLabel: t('erp.search.doc'),
    fixed: { doc_kind: kind },
    filters: [
      { key: 'status', label: t('erp.col.status'), options: [
        ...(so ? [['draft', t('erp.status.draft')] as [string, string]] : []),
        ['open', t('erp.status.open')], ['closed', t('erp.status.closed')], ['cancelled', t('erp.status.cancelled')]] },
      ...(so ? [
        { key: 'source', label: t('so.filter.source'), options: [['sap', 'SAP'], ['erp', 'Super ERP'], ['sample', t('erp.sampleData')]] as Array<[string, string]> },
      ] : []),
      ...(kind === 'sales_order' || kind === 'sales_quotation' || kind === 'purchase_order' || kind === 'goods_receipt' || kind === 'goods_issue' ? [
        { key: 'state', label: t('so.filter.approval'), options: [['pending_approval', t('so.state.pending_approval')], ['rejected', t('so.state.rejected')], ['draft', t('so.state.draft')]] as Array<[string, string]> },
      ] : []),
      ...(pu ? [{ key: 'china_office', label: t('pu.office'), from: { table: 'china_office', value: 'code', label: 'name' } }] : []),
    ],
    defaultSort: { col: 'doc_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.obj_type}|${r.doc_entry}`,
    rowLink: (r) => `/docs/${kind}/${r.company_code}/${r.doc_entry}`,
    columns: [
      so ? { key: 'doc_no', header: t('erp.col.docNo'), mono: true } : { key: 'doc_num', header: t('erp.col.docNo'), mono: true },
      { key: 'doc_date', header: t('erp.col.date'), cell: (r) => fmtDay(r.doc_date), csv: (r) => r.doc_date },
      ...(def.side === 'none'
        ? [{ key: 'from_whs', header: t('erp.col.warehouses'), cell: (r: R) => [r.from_whs, r.to_whs].filter(Boolean).join(' → ') || '—' }]
        : [{ key: 'card_name', header: def.side === 'customer' ? t('erp.col.customer') : t('erp.col.supplier'),
             cell: (r: R) => <span><span className="font-mono text-[13px] text-muted">{r.card_code}</span> {r.card_name}</span>, csv: (r: R) => `${r.card_code} ${r.card_name ?? ''}` }]),
      { key: 'due_date', header: t('erp.col.dueDate'), cell: (r) => fmtDay(r.due_date), csv: (r) => r.due_date, hideBelow: 'md' },
      { key: 'status', header: t('erp.col.status'),
        cell: (r) => (so && r.state && r.state !== 'approved' && r.state !== 'cancelled' ? <StatePill state={r.state} /> : <StatusTag value={r.status} />),
        csv: (r) => (so && r.state && r.state !== 'approved' && r.state !== 'cancelled' ? r.state : r.status) },
      ...(pu ? [{ key: 'china_office', header: t('pu.office'), hideBelow: 'lg' as const, cell: (r: R) => r.china_office ?? '—' }] : []),
      ...(so ? [{ key: 'source', header: t('erp.col.source'), hideBelow: 'lg' as const, cell: (r: R) => (r.source === 'erp' ? 'Super ERP' : r.source === 'sap' ? 'SAP' : t('erp.sampleData')) }] : []),
      { key: 'total', header: t('erp.col.total'), align: 'end', cell: (r) => fmtMoney(r.total, r.currency) },
      ...(kind.endsWith('invoice') ? [{ key: 'paid', header: t('erp.col.openAmount'), align: 'end' as const, sortable: false,
        cell: (r: R) => fmtMoney(Number(r.total) - Number(r.paid ?? 0)), csv: (r: R) => Number(r.total) - Number(r.paid ?? 0) }] : []),
    ],
  }) : null, [t, kind, def, so, cycle, pu, inv]);
  if (!def || !cfg) return <PageTitle title={t('erp.notFound')} />;
  const title = t(`erp.doc.${kind}`, { defaultValue: def.title });
  return (
    <Frame module={def.module as ModuleKey} title={title} desc={t('erp.page.docsDesc')}
      actions={kind === 'sales_order' ? <NewSalesOrderAction /> : cycle ? <NewCycleAction kind={kind as DocKind} /> : pu ? <NewPurchaseAction kind={kind as DocKind} /> : inv ? <NewInventoryAction kind={kind as DocKind} /> : undefined}>
      <ListScreen key={kind} config={cfg} />
    </Frame>
  );
}

// ---------- Inventory status ----------
export function StockPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'stock_balance', table: 'stock_balance',
    select: 'company_code,item_code,whs_code,on_hand,committed,on_order,avg_cost,min_stock,item(name),warehouse(name)',
    searchCols: ['item_code', 'whs_code'], searchLabel: t('erp.search.stock'),
    filters: [{ key: 'whs_code', label: t('erp.col.warehouse'), from: { table: 'warehouse', value: 'whs_code', label: 'name' } }],
    defaultSort: { col: 'item_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.item_code}|${r.whs_code}`,
    rowLink: (r) => `/items/${r.company_code}/${encodeURIComponent(r.item_code)}`,
    columns: [
      { key: 'item_code', header: t('erp.col.itemNo'), mono: true },
      { key: 'name', header: t('erp.col.description'), sortable: false, cell: (r) => r.item?.name ?? '—', csv: (r) => r.item?.name },
      { key: 'whs_code', header: t('erp.col.warehouse'), cell: (r) => `${r.whs_code} · ${r.warehouse?.name ?? ''}` },
      { key: 'on_hand', header: t('erp.col.onHand'), align: 'end',
        cell: (r) => <span className={Number(r.min_stock) > 0 && Number(r.on_hand) < Number(r.min_stock) ? 'font-semibold text-crit-fg' : ''}>{fmtQty(r.on_hand)}</span> },
      { key: 'committed', header: t('erp.col.committed'), align: 'end', cell: (r) => fmtQty(r.committed), hideBelow: 'sm' },
      { key: 'on_order', header: t('erp.col.ordered'), align: 'end', cell: (r) => fmtQty(r.on_order), hideBelow: 'sm' },
      { key: 'available', header: t('erp.col.available'), align: 'end', sortable: false,
        cell: (r) => fmtQty(Number(r.on_hand) - Number(r.committed) + Number(r.on_order)), csv: (r) => Number(r.on_hand) - Number(r.committed) + Number(r.on_order) },
      { key: 'min_stock', header: t('erp.col.minStock'), align: 'end', cell: (r) => fmtQty(r.min_stock), hideBelow: 'md' },
    ],
  }), [t]);
  return <Frame module="inventory" title={t('erp.page.stock')} desc={t('erp.page.stockDesc')}><ListScreen config={cfg} /></Frame>;
}

// ---------- Price lists ----------
export function PricesPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'item_price', table: 'item_price',
    select: 'company_code,list_num,item_code,price,currency,item(name),price_list(name)',
    searchCols: ['item_code'], searchLabel: t('erp.search.price'),
    filters: [{ key: 'list_num', label: t('erp.col.priceList'), from: { table: 'price_list', value: 'list_num', label: 'name' }, type: 'number' }],
    defaultSort: { col: 'item_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.list_num}|${r.item_code}`,
    rowLink: (r) => `/items/${r.company_code}/${encodeURIComponent(r.item_code)}`,
    columns: [
      { key: 'item_code', header: t('erp.col.itemNo'), mono: true },
      { key: 'name', header: t('erp.col.description'), sortable: false, cell: (r) => r.item?.name ?? '—', csv: (r) => r.item?.name },
      { key: 'list_num', header: t('erp.col.priceList'), cell: (r) => r.price_list?.name ?? r.list_num, csv: (r) => r.price_list?.name },
      { key: 'price', header: t('erp.col.price'), align: 'end', cell: (r) => fmtMoney(r.price, r.currency) },
    ],
  }), [t]);
  return <Frame module="inventory" title={t('erp.page.prices')} desc={t('erp.page.pricesDesc')}><ListScreen config={cfg} /></Frame>;
}

// ---------- Chart of accounts ----------
export function AccountsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'account', table: 'account',
    select: 'company_code,acct_code,format_code,name,level,postable,account_type,group_mask,currency,is_control,frozen,balance_local',
    searchCols: ['acct_code', 'format_code', 'name'], searchLabel: t('erp.search.account'), pageSize: 50,
    filters: [
      { key: 'postable', label: t('erp.col.kind'), options: [['true', t('erp.acct.postable')], ['false', t('erp.acct.title')]], type: 'boolean' },
      { key: 'group_mask', label: t('erp.col.drawer'), type: 'number', options: [['1', t('erp.drawer.1')], ['2', t('erp.drawer.2')], ['3', t('erp.drawer.3')], ['4', t('erp.drawer.4')], ['5', t('erp.drawer.5')], ['6', t('erp.drawer.6')], ['7', t('erp.drawer.7')]] },
    ],
    defaultSort: { col: 'acct_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.acct_code}`,
    columns: [
      { key: 'acct_code', header: t('erp.col.account'), mono: true, cell: (r) => <span style={{ paddingInlineStart: `${Math.max(0, (Number(r.level) || 1) - 1) * 12}px` }}>{r.format_code || r.acct_code}</span> },
      { key: 'name', header: t('erp.col.name'), cell: (r) => <span className={r.postable ? '' : 'font-semibold'}>{r.name}</span> },
      { key: 'group_mask', header: t('erp.col.drawer'), cell: (r) => t(`erp.drawer.${r.group_mask}`, { defaultValue: String(r.group_mask ?? '—') }), hideBelow: 'md' },
      { key: 'postable', header: t('erp.col.kind'), cell: (r) => (r.postable ? t('erp.acct.postable') : t('erp.acct.title')), hideBelow: 'sm' },
      { key: 'balance_local', header: t('erp.col.balance'), align: 'end', cell: (r) => (r.postable ? fmtMoney(r.balance_local) : '') },
    ],
  }), [t]);
  return <Frame module="financials" title={t('erp.page.accounts')} desc={t('erp.page.accountsDesc')}><ListScreen config={cfg} /></Frame>;
}

// ---------- Journal entries ----------
export function JournalsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'journal_entry', table: 'journal_entry',
    select: 'company_code,trans_id,number,ref_date,memo,ref1,ref2,trans_type,total_local,currency,source',
    searchCols: ['memo', 'ref1', 'ref2'], numberSearchCols: ['number', 'trans_id'], searchLabel: t('erp.search.journal'),
    defaultSort: { col: 'ref_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.trans_id}`,
    rowLink: (r) => `/financials/journals/${r.company_code}/${r.trans_id}`,
    columns: [
      { key: 'number', header: t('erp.col.number'), mono: true },
      { key: 'ref_date', header: t('erp.col.postingDate'), cell: (r) => fmtDay(r.ref_date), csv: (r) => r.ref_date },
      { key: 'memo', header: t('erp.col.remarks') },
      { key: 'ref1', header: t('erp.col.ref'), mono: true, hideBelow: 'md' },
      { key: 'total_local', header: t('erp.col.total'), align: 'end', cell: (r) => fmtMoney(r.total_local, r.currency) },
    ],
  }), [t]);
  return (
    <Frame module="financials" title={t('erp.page.journals')} desc={t('erp.page.journalsDesc')} actions={<><DraftsLink /><NewJournalAction /></>}>
      <ListScreen config={cfg} />
    </Frame>
  );
}

// ---------- Incoming / outgoing payments (A5: Super ERP payments, new payment, drafts) ----------
export function PaymentsPage() {
  const { t } = useTranslation();
  const { dir = 'in' } = useParams();
  const incoming = dir !== 'out';
  return (
    <Frame module="banking" title={incoming ? t('erp.page.paymentsIn') : t('erp.page.paymentsOut')} desc={t('erp.page.paymentsDesc')}
      actions={<>{!incoming && <PaymentDraftsLink />}<NewPaymentAction dir={incoming ? 'I' : 'O'} /></>}>
      <PaymentsList dir={incoming ? 'I' : 'O'} />
    </Frame>
  );
}

// ---------- Employees ----------
export function EmployeesPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'employee', table: 'employee',
    select: 'company_code,emp_id,hr_code,first_name,last_name,job_title,division,mobile,email,joined_on,status,active',
    searchCols: ['first_name', 'last_name', 'hr_code', 'job_title', 'email', 'division'], numberSearchCols: ['emp_id'], searchLabel: t('erp.search.employee'),
    filters: [{ key: 'active', label: t('erp.col.status'), options: [['true', t('erp.status.active')], ['false', t('erp.status.inactive')]], type: 'boolean' }],
    defaultSort: { col: 'emp_id', asc: true },
    rowKey: (r) => `${r.company_code}|${r.emp_id}`,
    rowLink: (r) => `/hr/employees/${r.company_code}/${r.emp_id}`,
    emptyTitle: t('erp.list.emptyHr'), emptyBody: t('erp.list.emptyHrBody'),
    columns: [
      { key: 'hr_code', header: t('erp.col.code'), mono: true },
      { key: 'last_name', header: t('erp.col.name'), cell: (r) => `${r.first_name ?? ''} ${r.last_name ?? ''}`.trim(), csv: (r) => `${r.first_name ?? ''} ${r.last_name ?? ''}`.trim() },
      { key: 'job_title', header: t('erp.col.jobTitle') },
      { key: 'division', header: t('erp.col.department'), hideBelow: 'md' },
      { key: 'email', header: t('erp.col.email'), hideBelow: 'lg' },
      { key: 'joined_on', header: t('erp.col.joined'), cell: (r) => fmtDay(r.joined_on), csv: (r) => r.joined_on, hideBelow: 'sm' },
      { key: 'active', header: t('erp.col.status'), cell: (r) => <StatusTag value={r.active ? 'active' : 'inactive'} />, csv: (r) => (r.active ? 'active' : 'inactive') },
    ],
  }), [t]);
  return <Frame module="hr" title={t('erp.page.employees')} desc={t('erp.page.employeesDesc')} actions={<><HrLinks /><NewEmployeeAction /></>}><ListScreen config={cfg} /></Frame>;
}

/** Used by detail pages: one-off reads with company scoping by RLS. */
export const one = async (table: string, select: string, match: Record<string, string | number>) => {
  const { data, error } = await erp().from(table).select(select).match(match).maybeSingle();
  if (error) throw error;
  return data as R | null;
};
export { Link };
