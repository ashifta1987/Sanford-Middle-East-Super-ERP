import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, Pencil, Plus, Trash2, Wrench } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, SectionCard, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { moduleByKey, type ModuleKey } from '../modules';
import { FormError, Flash, fmtWhen, useDefaultCompany, useFlash } from './BankingPages';
import { SourcePill, today } from './SalesOrderPages';
import { parseLots } from '../inventory';
import {
  bomDelete, bomSave, maintRecord, orderCancel, orderClose, orderCreate, orderIssue, orderReceipt, orderRelease, prdSettingSet, resourceSave,
  searchAllItems, searchBoms, useBomInfo, useMould, useOrderInfo, usePrdSetup, type BomHit, type OrderState,
} from '../production';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const linkBtn = 'inline-flex min-h-[44px] items-center gap-2 rounded-btn px-4 text-[15px] font-medium';
export const primaryLink = `${linkBtn} bg-primary text-white hover:bg-primary-hover`;
export const secondaryLink = `${linkBtn} border border-line bg-surface text-ink hover:bg-page`;
export const label = 'block text-xs font-medium text-muted';
export const inputCls = 'input mt-1 text-[15px] text-ink';
const th = 'px-4 py-2 text-start font-medium';
const thEnd = 'px-4 py-2 text-end font-medium';

// ---------- Shared pieces ----------
/** Header for production and service screens: back link, breadcrumb (Home › 08 Production › list › record), title with pills, one line, actions. */
export function PsHeader({ module, title, pills, sub, actions, listTo, listLabel }: {
  module: ModuleKey; title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode; listTo: string; listLabel: string;
}) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  return (
    <header className="mb-4">
      <Link to={listTo} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {listLabel}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${m.key}`], [listLabel, listTo], [title, undefined]]} />
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <h1 dir="auto" className="flex flex-wrap items-center gap-3 text-[26px] font-semibold leading-tight sm:text-[28px]">{title} {pills}</h1>
          {sub && <p dir="auto" className="mt-1 text-[15px] text-muted">{sub}</p>}
        </div>
        {actions && <div className="flex flex-wrap items-start gap-2">{actions}</div>}
      </div>
    </header>
  );
}

/** List page frame with the primary "+ New …" action (disabled with the reason for read-only users). */
export function PsListFrame({ module, title, desc, newTo, newLabel, newId, children, extra }: {
  module: ModuleKey; title: string; desc: string; newTo?: string; newLabel?: string; newId?: string; children: ReactNode; extra?: ReactNode;
}) {
  const { t } = useTranslation();
  const m = moduleByKey(module)!;
  const { canWrite, readOnlyReason } = useModuleLevel(module);
  return (
    <RequireModule module={module}>
      <header className="mb-6">
        <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, `/m/${m.key}`], [title, undefined]]} />
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div><h1 className="flex flex-wrap items-center gap-3 text-[26px] font-semibold sm:text-[28px]">{title} <LiveBadge live /></h1><p className="mt-1 text-[15px] text-muted">{desc}</p></div>
          <div className="flex flex-wrap items-center gap-2">
            {extra}
            {newTo && (canWrite ? <Link to={newTo} id={newId} className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {newLabel}</Link>
              : <Button variant="primary" disabled id={newId} disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {newLabel}</Button>)}
          </div>
        </div>
      </header>
      {children}
    </RequireModule>
  );
}

export function NoteDialog({ id, open, title, labelText, required, confirm, variant = 'danger', onClose, onConfirm }: {
  id: string; open: boolean; title: string; labelText: string; required?: boolean; confirm: string; variant?: 'danger' | 'primary';
  onClose: () => void; onConfirm: (note: string) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (open) { setNote(''); setErr(null); } }, [open]);
  async function go() {
    if (required && !note.trim()) { setErr(t('ps.noteNeeded')); return; }
    setBusy(true);
    try { await onConfirm(note.trim()); onClose(); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <Dialog open={open} title={title} onClose={onClose}
      footer={<><Button variant="secondary" onClick={onClose}>{t('so.keep')}</Button><Button variant={variant} id={`${id}-confirm`} disabled={busy} onClick={go}>{confirm}</Button></>}>
      <label className={label}>{labelText} {required && <span className="text-crit-fg">*</span>}
        <textarea id={`${id}-note`} rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => { setNote(e.target.value); setErr(null); }} />
      </label>
      {err && <p role="alert" dir="auto" className="text-sm text-crit-fg">{err}</p>}
    </Dialog>
  );
}

export function ActivityList({ items, prefix }: { items: Array<{ at: string; action: string; actor_name: string | null; text?: string | null; note?: string | null }>; prefix: string }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('so.activity.title')}>
      {items.length === 0 ? <p className="p-5 text-sm text-muted">{t('so.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid="ps-activity">
          {items.map((a, i) => (
            <li key={i} className="flex gap-3">
              <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', /cancel|reject/.test(a.action) ? 'bg-crit-fg' : /close|resolved|activate|receipt/.test(a.action) ? 'bg-ok-fg' : 'bg-primary')} aria-hidden />
              <div className="min-w-0 text-sm">
                <p><span className="font-medium">{a.actor_name ?? '—'}</span> {t(`ps.act.${a.action.replace(prefix, '')}`, { defaultValue: a.action.replace(/_/g, ' ') })}</p>
                {(a.text || a.note) && <p dir="auto" className="text-ink-2">“{a.text ?? a.note}”</p>}
                <p className="num text-xs text-muted">{fmtWhen(a.at)}</p>
              </div>
            </li>
          ))}
        </ol>
      )}
    </SectionCard>
  );
}

const ORDER_TONE: Record<OrderState, string> = { planned: 'pill-neutral', released: 'pill-info', closed: 'pill-ok', cancelled: 'pill-crit' };
export function OrderStatePill({ state }: { state: OrderState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', ORDER_TONE[state])} data-testid="order-state">{t(`ps.order.state.${state}`)}</span>;
}
function MaintPill({ status }: { status: string }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', status === 'overdue' ? 'pill-crit' : status === 'ok' ? 'pill-ok' : 'pill-neutral')}>{t(`ps.mould.status.${status}`)}</span>;
}
const BOM_TYPES = ['production', 'assembly', 'sales'] as const;

// ---------- Bills of materials ----------
export function BomsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'bom', table: 'bom_list', select: 'company_code,item_code,item_name,bom_type,qty,whs_code,active,n_items,n_resources,resources,source',
    searchCols: ['item_code', 'item_name', 'resources'], searchLabel: t('ps.bom.search'),
    filters: [
      { key: 'bom_type', label: t('ps.bom.type'), options: BOM_TYPES.map((x) => [x, t(`ps.bom.types.${x}`)] as [string, string]) },
      { key: 'active', label: t('erp.col.status'), options: [['true', t('erp.status.active')], ['false', t('erp.status.inactive')]], type: 'boolean' },
    ],
    defaultSort: { col: 'item_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.item_code}`,
    rowLink: (r) => `/production/boms/${r.company_code}/${encodeURIComponent(r.item_code)}`,
    columns: [
      { key: 'item_code', header: t('ps.bom.parent'), mono: true },
      { key: 'item_name', header: t('erp.col.description'), cell: (r) => <span dir="auto">{r.item_name ?? '—'}</span>, hideBelow: 'sm' },
      { key: 'bom_type', header: t('ps.bom.type'), cell: (r) => t(`ps.bom.types.${r.bom_type}`) },
      { key: 'qty', header: t('ps.bom.makes'), align: 'end', cell: (r) => fmtQty(r.qty), hideBelow: 'md' },
      { key: 'n_items', header: t('ps.bom.components'), align: 'end', hideBelow: 'md' },
      { key: 'resources', header: t('ps.bom.resources'), cell: (r) => <span className="font-mono text-[13px]">{r.resources ?? '—'}</span>, hideBelow: 'lg' },
      { key: 'whs_code', header: t('erp.col.warehouse'), mono: true, hideBelow: 'lg' },
    ],
  }), [t]);
  return <PsListFrame module="production" title={t('ps.bom.title')} desc={t('ps.bom.desc')} newTo="/production/boms/new" newLabel={t('ps.bom.new')} newId="bom-new"><ListScreen config={cfg} /></PsListFrame>;
}

interface BLine { key: string; comp_kind: 'item' | 'resource'; comp_code: string; text: string; qty: string; whs_code: string }
let seq = 0;
const newBLine = (kind: 'item' | 'resource' = 'item'): BLine => ({ key: `b${++seq}`, comp_kind: kind, comp_code: '', text: '', qty: '1', whs_code: '' });

export function BomFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const dflt = useDefaultCompany();
  const company = mode === 'edit' ? params.company ?? '' : dflt;
  const editItem = mode === 'edit' ? decodeURIComponent(params.item ?? '') : '';
  const { canWrite, readOnlyReason } = useModuleLevel('production');
  const setup = usePrdSetup(company || null);
  const info = useBomInfo(mode === 'edit' ? company : '', editItem);
  const [item, setItem] = useState(editItem);
  const [itemText, setItemText] = useState(editItem);
  const [type, setType] = useState('production');
  const [qty, setQty] = useState('1');
  const [whs, setWhs] = useState('WH01');
  const [note, setNote] = useState('');
  const [lines, setLines] = useState<BLine[]>([newBLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const b = info.data;
    if (!b) return;
    setType(b.bom.bom_type); setQty(String(Number(b.bom.qty))); setWhs(b.bom.whs_code ?? ''); setNote(b.bom.note ?? '');
    setItemText(`${b.bom.item_code} · ${b.bom.item_name}`);
    setLines(b.lines.map((l) => ({ key: `b${++seq}`, comp_kind: l.comp_kind, comp_code: l.comp_code, text: `${l.comp_code} · ${l.name ?? ''}`, qty: String(Number(l.qty)), whs_code: l.whs_code ?? '' })));
  }, [info.data]);
  const set = (k: string, f: Partial<BLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...f } : l)));
  const S = setup.data;
  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await bomSave(company, { item_code: item, bom_type: type, qty, whs_code: whs || null, note, edit: mode === 'edit',
        lines: lines.filter((l) => l.comp_code).map((l) => ({ comp_kind: l.comp_kind, comp_code: l.comp_code, qty: l.qty, whs_code: l.comp_kind === 'item' ? l.whs_code || null : null })) });
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['bom'] });
      nav(`/production/boms/${company}/${encodeURIComponent(r.item_code)}`, { state: { flash: t('ps.bom.saved', { item: r.item_code }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (setup.isLoading || (mode === 'edit' && info.isLoading)) return <RequireModule module="production"><PageLoading /></RequireModule>;
  return (
    <RequireModule module="production">
      <PsHeader module="production" title={mode === 'new' ? t('ps.bom.new') : `${t('ps.bom.one')} ${editItem}`} pills={<SourcePill source="erp" />}
        sub={t('ps.bom.formSub')} listTo="/production/boms" listLabel={t('ps.bom.title')} />
      <FormError message={err} />
      <div className="space-y-5">
        <SectionCard title={t('erp.section.header')}>
          <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-4">
            {mode === 'new' ? (
              <Combobox id="bom-item" label={t('ps.bom.parent')} required text={itemText} onText={(s) => { setItemText(s); setItem(''); }}
                onSelect={(o) => { setItem(o.value); setItemText(o.label); }}
                search={async (q) => (await searchAllItems(company, q)).map((i) => ({ value: i.item_code, label: `${i.item_code} · ${i.name}`, data: i }))} />
            ) : <div><span className={label}>{t('ps.bom.parent')}</span><p className="mt-3 font-mono">{itemText}</p></div>}
            <label className={label}>{t('ps.bom.type')}
              <select id="bom-type" className={inputCls} value={type} onChange={(e) => setType(e.target.value)}>{BOM_TYPES.map((x) => <option key={x} value={x}>{t(`ps.bom.types.${x}`)}</option>)}</select></label>
            <label className={label}>{t('ps.bom.makes')} <span className="text-crit-fg">*</span><input id="bom-qty" inputMode="decimal" className={`${inputCls} num`} value={qty} onChange={(e) => setQty(e.target.value)} /></label>
            <label className={label}>{t('ps.bom.receiveWhs')}
              <select id="bom-whs" className={inputCls} value={whs} onChange={(e) => setWhs(e.target.value)}><option value="">—</option>{(S?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}</select></label>
            <label className={`${label} sm:col-span-2 xl:col-span-4`}>{t('erp.col.remarks')}<input id="bom-note" dir="auto" className={inputCls} value={note} onChange={(e) => setNote(e.target.value)} /></label>
          </div>
        </SectionCard>
        <SectionCard title={t('ps.bom.lines')} right={<span className="text-sm text-muted">{t('ps.bom.perBatch', { qty: qty || '1' })}</span>}>
          <ul className="divide-y divide-line" data-testid="bom-lines">
            {lines.map((l, i) => (
              <li key={l.key} className="grid grid-cols-1 gap-3 px-5 py-4 sm:grid-cols-[140px_minmax(0,1fr)_120px_140px_auto]">
                <label className={label}>{t('ps.bom.kind')}
                  <select id={`bom-kind-${i}`} className={inputCls} value={l.comp_kind} onChange={(e) => set(l.key, { comp_kind: e.target.value as BLine['comp_kind'], comp_code: '', text: '' })}>
                    <option value="item">{t('ps.bom.kinds.item')}</option><option value="resource">{t('ps.bom.kinds.resource')}</option></select></label>
                {l.comp_kind === 'item' ? (
                  <Combobox id={`bom-comp-${i}`} label={t('ps.bom.component')} text={l.text} onText={(s) => set(l.key, { text: s, comp_code: '' })}
                    onSelect={(o) => set(l.key, { comp_code: o.value, text: o.label })}
                    search={async (q) => (await searchAllItems(company, q)).filter((x) => x.is_stock).map((x) => ({ value: x.item_code, label: `${x.item_code} · ${x.name}`, data: x, meta: <span className="text-xs text-muted">{x.inventory_uom}</span> }))} />
                ) : (
                  <label className={label}>{t('ps.bom.resource')}
                    <select id={`bom-res-${i}`} className={inputCls} value={l.comp_code} onChange={(e) => set(l.key, { comp_code: e.target.value })}>
                      <option value="">{t('inv.choose')}</option>{(S?.resources ?? []).filter((r) => r.active).map((r) => <option key={r.code} value={r.code}>{r.code} · {r.name} ({t(`ps.unit.${r.unit}`)})</option>)}</select></label>
                )}
                <label className={label}>{t('erp.col.qty')}<input id={`bom-lqty-${i}`} inputMode="decimal" className={`${inputCls} num text-end`} value={l.qty} onChange={(e) => set(l.key, { qty: e.target.value })} /></label>
                {l.comp_kind === 'item' ? (
                  <label className={label}>{t('ps.bom.issueWhs')}
                    <select id={`bom-lwhs-${i}`} className={inputCls} value={l.whs_code} onChange={(e) => set(l.key, { whs_code: e.target.value })}><option value="">{t('ps.bom.sameWhs')}</option>{(S?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code}</option>)}</select></label>
                ) : <span />}
                <div className="flex items-end"><Button variant="ghost" aria-label={t('so.removeLine')} onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} icon={<Trash2 className="h-4 w-4" aria-hidden />} /></div>
              </li>
            ))}
          </ul>
          <div className="flex flex-wrap gap-2 border-t border-line p-4">
            <Button id="bom-add-item" onClick={() => setLines((ls) => [...ls, newBLine('item')])} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('ps.bom.addItem')}</Button>
            <Button id="bom-add-res" onClick={() => setLines((ls) => [...ls, newBLine('resource')])} icon={<Wrench className="h-4 w-4" aria-hidden />}>{t('ps.bom.addResource')}</Button>
          </div>
        </SectionCard>
        <div className="flex flex-wrap gap-2">
          <Button variant="primary" id="bom-save" disabled={busy || !canWrite || !item} disabledReason={!canWrite ? readOnlyReason : !item ? t('ps.bom.chooseParent') : undefined} onClick={save}>{busy ? t('so.saving') : t('ps.bom.save')}</Button>
          <Link to={mode === 'edit' ? `/production/boms/${company}/${encodeURIComponent(editItem)}` : '/production/boms'} className={secondaryLink}>{t('so.cancelEdit')}</Link>
        </div>
      </div>
    </RequireModule>
  );
}

export function BomPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { company = '', item: rawItem = '' } = useParams();
  const item = decodeURIComponent(rawItem);
  const q = useBomInfo(company, item);
  const [flash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [delOpen, setDelOpen] = useState(false);
  const B = q.data;
  if (q.isLoading) return <RequireModule module="production"><PageLoading /></RequireModule>;
  if (q.error || !B) return <RequireModule module="production"><PsHeader module="production" title={item} listTo="/production/boms" listLabel={t('ps.bom.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  return (
    <RequireModule module="production">
      <PsHeader module="production" title={`${B.bom.item_code} · ${B.bom.item_name}`} pills={<><span className="pill pill-info">{t(`ps.bom.types.${B.bom.bom_type}`)}</span><SourcePill source={B.bom.source} /></>}
        listTo="/production/boms" listLabel={t('ps.bom.title')} sub={t('ps.bom.unitCostLine', { cost: fmtMoney(B.unit_cost, B.currency), uom: B.bom.uom ?? '' })}
        actions={B.can_write ? <>
          {B.bom.bom_type === 'production' && <Link id="bom-order" to={`/production/orders/new?item=${encodeURIComponent(item)}`} className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {t('ps.order.new')}</Link>}
          <Link id="bom-edit" to={`/production/boms/${company}/${encodeURIComponent(item)}/edit`} className={secondaryLink}><Pencil className="h-4 w-4" aria-hidden /> {t('ps.edit')}</Link>
          <Button variant="danger" id="bom-delete" onClick={() => setDelOpen(true)}>{t('ps.delete')}</Button>
        </> : undefined} />
      <Flash text={flash} />
      <FormError message={err} />
      <div className="space-y-5">
        <SectionCard title={t('erp.section.general')}>
          <Fields items={[[t('ps.bom.type'), t(`ps.bom.types.${B.bom.bom_type}`)], [t('ps.bom.makes'), `${fmtQty(B.bom.qty)} ${B.bom.uom ?? ''}`], [t('ps.bom.receiveWhs'), B.bom.whs_code],
            [t('erp.col.status'), B.bom.active ? t('erp.status.active') : t('erp.status.inactive')], [t('ps.updated'), `${fmtWhen(B.bom.updated_at)}${B.bom.updated_by_name ? ` · ${B.bom.updated_by_name}` : ''}`], [t('erp.col.remarks'), B.bom.note]]} />
        </SectionCard>
        <SectionCard title={t('ps.bom.lines')} right={<span className="text-sm text-muted">{t('ps.bom.perBatch', { qty: fmtQty(B.bom.qty) })}</span>}>
          <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="bom-table">
            <thead className="bg-surface-2 text-xs text-muted"><tr><th scope="col" className={th}>{t('ps.bom.component')}</th><th scope="col" className={thEnd}>{t('erp.col.qty')}</th>
              <th scope="col" className={`${th} max-sm:hidden`}>{t('erp.col.warehouse')}</th><th scope="col" className={`${thEnd} max-md:hidden`}>{t('ps.unitCost')}</th><th scope="col" className={thEnd}>{t('ps.cost')}</th></tr></thead>
            <tbody>{B.lines.map((l) => (
              <tr key={l.line_num} className="border-t border-line">
                <td className="px-4 py-2"><p dir="auto" className="font-medium">{l.name}</p><p className="font-mono text-[12px] text-muted">{l.comp_code} · {l.comp_kind === 'item' ? t('ps.bom.kinds.item') : t(`ps.res.kind.${l.kind}`, { defaultValue: l.kind ?? '' })}</p></td>
                <td className="num px-4 py-2 text-end">{fmtQty(l.qty)} {l.uom ? t(`ps.unit.${l.uom}`, { defaultValue: l.uom }) : ''}</td>
                <td className="px-4 py-2 font-mono max-sm:hidden">{l.whs_code ?? '—'}</td>
                <td className="num px-4 py-2 text-end max-md:hidden">{fmtMoney(l.unit_cost)}</td><td className="num px-4 py-2 text-end">{fmtMoney(l.cost)}</td>
              </tr>))}</tbody>
          </table></div>
        </SectionCard>
        {B.open_orders.length > 0 && (
          <SectionCard title={t('ps.bom.openOrders')}><ul className="divide-y divide-line">{B.open_orders.map((o) => (
            <li key={o.order_id} className="flex items-center justify-between gap-3 px-5 py-3"><Link className="font-mono text-primary hover:underline" to={`/production/orders/${company}/${o.order_id}`}>{o.doc_no}</Link><span className="num">{fmtQty(o.planned_qty)}</span><OrderStatePill state={o.state} /></li>))}</ul></SectionCard>
        )}
      </div>
      <NoteDialog id="bom-del" open={delOpen} title={t('ps.bom.deleteTitle', { item })} labelText={t('ps.optionalNote')} confirm={t('ps.delete')} onClose={() => setDelOpen(false)}
        onConfirm={async () => { try { await bomDelete(company, item); qc.invalidateQueries({ queryKey: ['erp-list'] }); nav('/production/boms'); } catch (e) { setErr(errorMessage(e)); throw e; } }} />
    </RequireModule>
  );
}

// ---------- Production orders ----------
export function ProdOrdersPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'prod_order', table: 'prod_order_list',
    select: 'company_code,order_id,doc_no,item_code,item_name,planned_qty,completed_qty,whs_code,post_date,due_date,state,late,received_value',
    searchCols: ['doc_no', 'item_code', 'item_name', 'comments'], searchLabel: t('ps.order.search'),
    filters: [
      { key: 'state', label: t('erp.col.status'), options: (['planned', 'released', 'closed', 'cancelled'] as const).map((s) => [s, t(`ps.order.state.${s}`)] as [string, string]) },
      { key: 'late', label: t('ps.order.late'), options: [['true', t('erp.yes')], ['false', t('erp.no')]], type: 'boolean' },
    ],
    defaultSort: { col: 'due_date', asc: true },
    rowKey: (r) => `${r.company_code}|${r.order_id}`,
    rowLink: (r) => `/production/orders/${r.company_code}/${r.order_id}`,
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'item_code', header: t('ps.order.item'), cell: (r) => <span><span className="font-mono">{r.item_code}</span><span dir="auto" className="block text-xs text-muted max-sm:hidden">{r.item_name}</span></span> },
      { key: 'completed_qty', header: t('ps.order.progress'), align: 'end', sortable: false, cell: (r) => `${fmtQty(r.completed_qty)} / ${fmtQty(r.planned_qty)}` },
      { key: 'due_date', header: t('ps.order.due'), cell: (r) => <span className={r.late ? 'font-medium text-crit-fg' : undefined}>{fmtDay(r.due_date)}</span>, csv: (r) => r.due_date },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <OrderStatePill state={r.state} />, csv: (r) => r.state },
      { key: 'whs_code', header: t('erp.col.warehouse'), mono: true, hideBelow: 'md' },
      { key: 'received_value', header: t('ps.order.received'), align: 'end', cell: (r) => fmtMoney(r.received_value), hideBelow: 'lg' },
    ],
  }), [t]);
  return <PsListFrame module="production" title={t('ps.order.title')} desc={t('ps.order.desc')} newTo="/production/orders/new" newLabel={t('ps.order.new')} newId="order-new"><ListScreen config={cfg} /></PsListFrame>;
}

export function ProdOrderNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const company = useDefaultCompany();
  const { canWrite, readOnlyReason } = useModuleLevel('production');
  const setup = usePrdSetup(company || null);
  const pre = new URLSearchParams(window.location.search).get('item') ?? '';
  const [item, setItem] = useState(pre);
  const [itemText, setItemText] = useState(pre);
  const [qty, setQty] = useState('');
  const [due, setDue] = useState('');
  const [post, setPost] = useState(today());
  const [whs, setWhs] = useState('');
  const [comments, setComments] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    setErr(null); setBusy(true);
    try {
      const r = await orderCreate(company, { item_code: item, planned_qty: qty, due_date: due, post_date: post, whs_code: whs || null, comments });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      nav(`/production/orders/${company}/${r.order_id}`, { state: { flash: t('ps.order.created', { no: r.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  if (setup.isLoading) return <RequireModule module="production"><PageLoading /></RequireModule>;
  return (
    <RequireModule module="production">
      <PsHeader module="production" title={t('ps.order.new')} pills={<SourcePill source="erp" />} sub={t('ps.order.newSub')} listTo="/production/orders" listLabel={t('ps.order.title')} />
      <FormError message={err} />
      <SectionCard title={t('erp.section.header')} className="max-w-3xl">
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <Combobox<BomHit> id="order-item" label={t('ps.order.item')} required text={itemText} onText={(s) => { setItemText(s); setItem(''); }}
            onSelect={(o) => { setItem(o.value); setItemText(o.label); setWhs(o.data.whs_code ?? ''); }} noMatch={t('ps.order.noBom')}
            search={async (q) => (await searchBoms(company, q)).map((b) => ({ value: b.item_code, label: `${b.item_code} · ${b.item_name ?? ''}`, data: b }))} />
          <label className={label}>{t('ps.order.planned')} <span className="text-crit-fg">*</span><input id="order-qty" inputMode="decimal" className={`${inputCls} num`} value={qty} onChange={(e) => setQty(e.target.value)} /></label>
          <label className={label}>{t('ps.order.orderDate')}<input id="order-post" type="date" className={`${inputCls} num`} value={post} onChange={(e) => setPost(e.target.value)} /></label>
          <label className={label}>{t('ps.order.due')} <span className="text-crit-fg">*</span><input id="order-due" type="date" className={`${inputCls} num`} value={due} onChange={(e) => setDue(e.target.value)} /></label>
          <label className={label}>{t('ps.bom.receiveWhs')}
            <select id="order-whs" className={inputCls} value={whs} onChange={(e) => setWhs(e.target.value)}><option value="">{t('ps.order.bomWhs')}</option>{(setup.data?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}</select></label>
          <label className={label}>{t('erp.col.remarks')}<input id="order-comments" dir="auto" className={inputCls} value={comments} onChange={(e) => setComments(e.target.value)} /></label>
        </div>
        <div className="flex flex-wrap gap-2 border-t border-line p-5">
          <Button variant="primary" id="order-create" disabled={busy || !canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={go}>{busy ? t('so.saving') : t('ps.order.create')}</Button>
          <Link to="/production/orders" className={secondaryLink}>{t('so.cancelEdit')}</Link>
        </div>
      </SectionCard>
    </RequireModule>
  );
}

export function ProdOrderPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const oid = Number(id);
  const qc = useQueryClient();
  const q = useOrderInfo(company, oid);
  const O = q.data;
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [issueQty, setIssueQty] = useState<Record<number, string>>({});
  const [issueLots, setIssueLots] = useState<Record<number, string>>({});
  const [issueDate, setIssueDate] = useState(today());
  const [issueWhy, setIssueWhy] = useState('');
  const [rQty, setRQty] = useState('');
  const [rDate, setRDate] = useState(today());
  const [rBin, setRBin] = useState('');
  const [rLots, setRLots] = useState('');
  const [closeOpen, setCloseOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['prod-order', company, oid] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); };
  async function run(f: () => Promise<string>) {
    setErr(null); setBusy(true);
    try { setFlash(await f()); refresh(); } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (q.isLoading) return <RequireModule module="production"><PageLoading /></RequireModule>;
  if (q.error || !O) return <RequireModule module="production"><PsHeader module="production" title={id} listTo="/production/orders" listLabel={t('ps.order.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  const o = O.order;
  const cur = O.currency;
  const items = O.lines.filter((l) => l.comp_kind === 'item');
  const left = Number(o.planned_qty) - Number(o.completed_qty);
  const released = o.state === 'released';
  const extra = items.some((l) => Number(issueQty[l.line_num] || 0) + Number(l.issued_qty) > Number(l.planned_qty));
  const issueRemaining = () => setIssueQty(Object.fromEntries(items.map((l) => [l.line_num, String(Math.max(0, Number(l.planned_qty) - Number(l.issued_qty)))])));
  return (
    <RequireModule module="production">
      <PsHeader module="production" title={`${t('ps.order.one')} ${o.doc_no}`} pills={<><OrderStatePill state={o.state} />{o.late && <span className="pill pill-crit">{t('ps.order.late')}</span>}<SourcePill source="erp" /></>}
        listTo="/production/orders" listLabel={t('ps.order.title')}
        sub={[`${o.item_code} · ${o.item_name ?? ''}`, t('ps.order.dueOn', { d: fmtDay(o.due_date) }), o.whs_code, o.created_by_name].filter(Boolean).join(' · ')}
        actions={O.can_write ? <>
          {o.state === 'planned' && <Button variant="primary" id="order-release" disabled={busy} onClick={() => run(async () => { await orderRelease(company, oid); return t('ps.order.releasedFlash', { no: o.doc_no }); })}>{t('ps.order.release')}</Button>}
          {released && <Button variant="success" id="order-close" disabled={busy} onClick={() => setCloseOpen(true)}>{t('ps.order.close')}</Button>}
          {(o.state === 'planned' || (released && Number(o.issued_value) === 0 && Number(o.completed_qty) === 0)) && <Button variant="danger" id="order-cancel" onClick={() => setCancelOpen(true)}>{t('inv.cancel')}</Button>}
        </> : undefined} />
      <Flash text={flash} />
      <FormError message={err} />
      {O.shortage_messages.length > 0 && (
        <section className="mb-5 rounded-card border border-warn-fg/30 bg-warn-bg p-4 text-warn-fg" data-testid="order-shortages">
          <p className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" aria-hidden />{t(o.state === 'planned' ? 'ps.order.shortTitle' : 'ps.order.shortTitleReleased')}</p>
          <ul className="mt-2 space-y-1 text-sm">{O.shortages.map((s, i) => (
            <li key={i} dir="auto">{O.shortage_messages[i]} {s.next_po && <Link className="font-medium underline" to={`/docs/purchase_order/${company}/${s.next_po.doc_entry}`}>{t('ps.order.openPo')}</Link>}</li>))}</ul>
        </section>
      )}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('ps.order.components')}>
            <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="order-lines">
              <thead className="bg-surface-2 text-xs text-muted"><tr><th scope="col" className={th}>{t('ps.bom.component')}</th><th scope="col" className={thEnd}>{t('ps.order.planned')}</th>
                <th scope="col" className={thEnd}>{t('ps.order.issued')}</th><th scope="col" className={`${thEnd} max-sm:hidden`}>{t('ps.order.inStock')}</th>
                {released && O.can_write && <th scope="col" className={thEnd}>{t('ps.order.issueNow')}</th>}</tr></thead>
              <tbody>{O.lines.map((l) => {
                const short = O.shortages.find((s) => s.line_num === l.line_num);
                return (
                  <tr key={l.line_num} className={clsx('border-t border-line align-top', short && 'bg-warn-bg')}>
                    <td className="px-4 py-2"><p dir="auto" className="font-medium">{l.name}</p><p className="font-mono text-[12px] text-muted">{l.comp_code}{l.whs_code ? ` · ${l.whs_code}` : ` · ${t(`ps.res.kind.${l.res_kind}`, { defaultValue: '' })}`}</p></td>
                    <td className="num px-4 py-2 text-end">{fmtQty(l.planned_qty)} {l.uom ? t(`ps.unit.${l.uom}`, { defaultValue: l.uom }) : ''}</td>
                    <td className="num px-4 py-2 text-end">{fmtQty(l.issued_qty)}<span className="block text-xs text-muted">{fmtMoney(l.issued_value)}</span></td>
                    <td className="num px-4 py-2 text-end max-sm:hidden">{l.comp_kind === 'item' ? fmtQty(l.on_hand) : '—'}</td>
                    {released && O.can_write && <td className="px-4 py-2 text-end">{l.comp_kind === 'item' ? (
                      <div className="flex flex-col items-end gap-1">
                        <input id={`issue-qty-${l.line_num}`} aria-label={t('ps.order.issueOf', { item: l.comp_code })} inputMode="decimal" className="input num w-24 text-end text-[15px] text-ink" value={issueQty[l.line_num] ?? ''} onChange={(e) => setIssueQty((v) => ({ ...v, [l.line_num]: e.target.value }))} />
                        {(l.serial || l.batch) && <input aria-label={t('inv.lots')} placeholder={t(l.serial ? 'ps.serialsPh' : 'ps.batchesPh')} className="input w-40 text-[13px] text-ink" value={issueLots[l.line_num] ?? ''} onChange={(e) => setIssueLots((v) => ({ ...v, [l.line_num]: e.target.value }))} />}
                      </div>) : <span className="text-xs text-muted">{t('ps.order.onReceipt')}</span>}</td>}
                  </tr>
                );
              })}</tbody>
            </table></div>
            {released && O.can_write && items.length > 0 && (
              <div className="grid grid-cols-1 gap-3 border-t border-line p-5 sm:grid-cols-[160px_minmax(0,1fr)_auto]">
                <label className={label}>{t('erp.col.postingDate')}<input id="issue-date" type="date" className={`${inputCls} num`} value={issueDate} onChange={(e) => setIssueDate(e.target.value)} /></label>
                <label className={label}>{t('ps.order.extraReason')}{extra && <span className="text-crit-fg"> *</span>}<input id="issue-reason" dir="auto" className={inputCls} value={issueWhy} onChange={(e) => setIssueWhy(e.target.value)} placeholder={extra ? t('ps.order.extraNeeded') : ''} /></label>
                <div className="flex flex-wrap items-end gap-2">
                  <Button id="issue-fill" onClick={issueRemaining}>{t('ps.order.fillRemaining')}</Button>
                  <Button variant="primary" id="issue-post" disabled={busy} onClick={() => run(async () => {
                    const lines = items.filter((l) => Number(issueQty[l.line_num] || 0) > 0).map((l) => ({ line_num: l.line_num, qty: issueQty[l.line_num],
                      lots: (l.serial || l.batch) ? parseLots(issueLots[l.line_num] ?? '', l.batch) : [] }));
                    const r = await orderIssue(company, oid, { doc_date: issueDate, reason: issueWhy || null }, lines);
                    setIssueQty({}); setIssueLots({}); setIssueWhy('');
                    return t('ps.order.issuedFlash', { no: r.doc_no, value: fmtMoney(r.value, cur) });
                  })}>{t('ps.order.issue')}</Button>
                </div>
              </div>
            )}
          </SectionCard>
          {released && O.can_write && (
            <SectionCard title={t('ps.order.receiptTitle')}>
              <div className="grid grid-cols-1 gap-3 p-5 sm:grid-cols-4">
                <label className={label}>{t('ps.order.qtyMade')} <span className="text-crit-fg">*</span><input id="receipt-qty" inputMode="decimal" className={`${inputCls} num`} value={rQty} onChange={(e) => setRQty(e.target.value)} placeholder={fmtQty(left)} /></label>
                <label className={label}>{t('erp.col.postingDate')}<input id="receipt-date" type="date" className={`${inputCls} num`} value={rDate} onChange={(e) => setRDate(e.target.value)} /></label>
                {o.bins && <label className={label}>{t('inv.bin')}<input id="receipt-bin" className={`${inputCls} font-mono`} value={rBin} onChange={(e) => setRBin(e.target.value)} /></label>}
                {(o.serial || o.batch) && <label className={label}>{t('inv.lots')}<input id="receipt-lots" className={inputCls} value={rLots} onChange={(e) => setRLots(e.target.value)} placeholder={t(o.serial ? 'ps.serialsPh' : 'ps.batchesPh')} /></label>}
                <div className="flex items-end sm:col-span-4">
                  <Button variant="primary" id="receipt-post" disabled={busy} onClick={() => run(async () => {
                    const r = await orderReceipt(company, oid, { doc_date: rDate, qty: rQty, bin_code: rBin || null, lots: (o.serial || o.batch) ? parseLots(rLots, o.batch) : [] });
                    setRQty(''); setRLots('');
                    return t('ps.order.receivedFlash', { no: r.doc_no, qty: fmtQty(r.qty), cost: fmtMoney(r.unit_cost, cur) });
                  })}>{t('ps.order.receive')}</Button>
                </div>
              </div>
              <p className="border-t border-line px-5 py-3 text-[13px] text-muted">{t('ps.order.costRule')}</p>
            </SectionCard>
          )}
          <SectionCard title={t('ps.order.documents')}>
            {O.documents.length === 0 ? <p className="p-5 text-sm text-muted">{t('ps.order.noDocs')}</p> : (
              <ul className="divide-y divide-line" data-testid="order-docs">{O.documents.map((d) => (
                <li key={d.doc_entry} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3">
                  <span><Link className="font-mono text-primary hover:underline" to={`/docs/${d.obj_type === 59 ? 'goods_receipt' : 'goods_issue'}/${company}/${d.doc_entry}`}>{d.doc_no}</Link>
                    <span className="ms-2 text-sm text-muted">{t(d.obj_type === 59 ? 'ps.order.receiptDoc' : 'ps.order.issueDoc')} · {fmtDay(d.doc_date)}</span></span>
                  <span className="num text-sm">{fmtQty(d.qty)} · {fmtMoney(d.total, cur)}</span>
                </li>))}</ul>
            )}
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('ps.order.cost')}>
            <dl className="space-y-2 p-5 text-sm" data-testid="order-cost">
              {([['ps.order.issuedValue', o.issued_value], ['ps.order.resourceValue', o.resource_value], ['ps.order.receivedValue', o.received_value], ['ps.order.wip', o.wip]] as Array<[string, number]>).map(([k, v]) => (
                <div key={k} className="flex justify-between gap-3"><dt className="text-muted">{t(k)}</dt><dd className="num">{fmtMoney(v, cur)}</dd></div>))}
              {o.variance_value != null && <div className="flex justify-between gap-3 border-t border-line pt-2 font-semibold"><dt>{t('ps.order.variance')}</dt><dd className="num">{fmtMoney(o.variance_value, cur)}</dd></div>}
              <div className="flex justify-between gap-3 border-t border-line pt-2"><dt className="text-muted">{t('ps.order.progress')}</dt><dd className="num">{fmtQty(o.completed_qty)} / {fmtQty(o.planned_qty)} {o.uom ?? ''}</dd></div>
            </dl>
          </SectionCard>
          {O.resource_use.length > 0 && (
            <SectionCard title={t('ps.order.resources')}><ul className="divide-y divide-line text-sm">{O.resource_use.map((u) => (
              <li key={u.use_id} className="flex justify-between gap-3 px-5 py-2"><span className="font-mono">{u.res_code}</span><span className="num">{fmtQty(u.qty)} · {fmtMoney(u.amount)}</span></li>))}</ul></SectionCard>
          )}
          <ActivityList items={O.activity.map((a) => ({ ...a, text: (a.detail?.note as string) ?? (a.detail?.reason as string) ?? null }))} prefix="prod_order_" />
        </aside>
      </div>
      <NoteDialog id="order-close" open={closeOpen} variant="primary" title={t('ps.order.closeTitle', { no: o.doc_no })} labelText={t('ps.optionalNote')} confirm={t('ps.order.close')}
        onClose={() => setCloseOpen(false)} onConfirm={async (n) => { const r = await orderClose(company, oid, n || null); setFlash(t('ps.order.closedFlash', { no: o.doc_no, v: fmtMoney(r.variance, cur) })); refresh(); }} />
      <NoteDialog id="order-cancel" open={cancelOpen} required title={t('ps.order.cancelTitle', { no: o.doc_no })} labelText={t('inv.cancelNote')} confirm={t('inv.cancel')}
        onClose={() => setCancelOpen(false)} onConfirm={async (n) => { await orderCancel(company, oid, n); setFlash(t('ps.order.cancelledFlash', { no: o.doc_no })); refresh(); }} />
    </RequireModule>
  );
}

// ---------- Moulds and resources ----------
export function MouldsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'mould', table: 'mould_schedule',
    select: 'company_code,res_code,name,kind,unit,unit_cost,shots_done,rated_life_shots,life_pct,life_warn,maint_status,next_due_shots,next_due_on,location,active',
    searchCols: ['res_code', 'name', 'location', 'asset_no'], searchLabel: t('ps.mould.search'),
    filters: [
      { key: 'kind', label: t('ps.mould.kind'), options: (['mould', 'machine', 'labour', 'other'] as const).map((k) => [k, t(`ps.res.kind.${k}`)] as [string, string]) },
      { key: 'maint_status', label: t('ps.mould.maint'), options: (['overdue', 'ok', 'not_scheduled'] as const).map((k) => [k, t(`ps.mould.status.${k}`)] as [string, string]) },
      { key: 'life_warn', label: t('ps.mould.lifeWarn'), options: [['true', t('erp.yes')], ['false', t('erp.no')]], type: 'boolean' },
    ],
    defaultSort: { col: 'res_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.res_code}`,
    rowLink: (r) => `/production/moulds/${r.company_code}/${encodeURIComponent(r.res_code)}`,
    columns: [
      { key: 'res_code', header: t('ps.mould.code'), mono: true },
      { key: 'name', header: t('erp.col.name'), cell: (r) => <span dir="auto">{r.name}</span> },
      { key: 'kind', header: t('ps.mould.kind'), cell: (r) => t(`ps.res.kind.${r.kind}`), hideBelow: 'md' },
      { key: 'shots_done', header: t('ps.mould.shots'), align: 'end', cell: (r) => (r.unit === 'shot' ? fmtQty(r.shots_done) : '—'), hideBelow: 'sm' },
      { key: 'life_pct', header: t('ps.mould.life'), align: 'end', cell: (r) => (r.life_pct == null ? '—' : <span className={r.life_warn ? 'font-medium text-crit-fg' : undefined}>{fmtQty(r.life_pct)} %</span>) },
      { key: 'maint_status', header: t('ps.mould.maint'), cell: (r) => <MaintPill status={r.maint_status} />, csv: (r) => r.maint_status },
      { key: 'next_due_on', header: t('ps.mould.nextDue'), cell: (r) => [r.next_due_shots != null ? t('ps.mould.atShots', { n: fmtQty(r.next_due_shots) }) : null, r.next_due_on ? fmtDay(r.next_due_on) : null].filter(Boolean).join(' · ') || '—', hideBelow: 'lg' },
    ],
  }), [t]);
  return <PsListFrame module="production" title={t('ps.mould.title')} desc={t('ps.mould.desc')} newTo="/production/moulds/new" newLabel={t('ps.mould.new')} newId="mould-new"><ListScreen config={cfg} /></PsListFrame>;
}

const RES_FIELDS = ['name', 'kind', 'unit', 'unit_cost', 'acct_code', 'cavities', 'rated_life_shots', 'shots_done', 'location', 'asset_no', 'maint_every_shots', 'maint_every_days', 'note'] as const;
export function MouldPage({ mode }: { mode: 'new' | 'view' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const dflt = useDefaultCompany();
  const company = mode === 'view' ? params.company ?? '' : dflt;
  const code = mode === 'view' ? decodeURIComponent(params.code ?? '') : '';
  const { canWrite, readOnlyReason } = useModuleLevel('production');
  const setup = usePrdSetup(company || null);
  const q = useMould(company, code);
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [f, setF] = useState<Record<string, string>>({ kind: 'mould', unit: 'shot' });
  const [newCode, setNewCode] = useState('');
  const [mDate, setMDate] = useState(today());
  const [mKind, setMKind] = useState('preventive');
  const [mNote, setMNote] = useState('');
  useEffect(() => {
    const m = q.data?.mould;
    if (!m) return;
    setF(Object.fromEntries(RES_FIELDS.map((k) => [k, k === 'acct_code' ? q.data?.acct_code ?? '' : k === 'note' ? q.data?.note ?? '' : (m as unknown as R)[k] == null ? '' : String((m as unknown as R)[k])])));
  }, [q.data]);
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await resourceSave(company, { ...f, res_code: mode === 'new' ? newCode : code, edit: mode === 'view' });
      qc.invalidateQueries({ queryKey: ['mould'] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['prd-setup'] });
      if (mode === 'new') nav(`/production/moulds/${company}/${encodeURIComponent(r.res_code)}`, { state: { flash: t('ps.mould.saved', { code: r.res_code }) } });
      else setFlash(t('ps.mould.saved', { code: r.res_code }));
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  async function maint() {
    setErr(null); setBusy(true);
    try { await maintRecord(company, code, { done_on: mDate, kind: mKind, note: mNote }); setMNote(''); setFlash(t('ps.mould.maintSaved')); qc.invalidateQueries({ queryKey: ['mould'] }); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  if (setup.isLoading || (mode === 'view' && q.isLoading)) return <RequireModule module="production"><PageLoading /></RequireModule>;
  const M = q.data?.mould;
  if (mode === 'view' && (q.error || !M)) return <RequireModule module="production"><PsHeader module="production" title={code} listTo="/production/moulds" listLabel={t('ps.mould.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  const fld = (k: string, lbl: string, opts: { num?: boolean; type?: string } = {}) => (
    <label key={k} className={label}>{lbl}<input id={`res-${k}`} type={opts.type ?? 'text'} inputMode={opts.num ? 'decimal' : undefined} dir={opts.num ? undefined : 'auto'} disabled={!canWrite || (k === 'shots_done' && mode === 'view')}
      className={clsx(inputCls, opts.num && 'num')} value={f[k] ?? ''} onChange={(e) => set(k, e.target.value)} /></label>
  );
  return (
    <RequireModule module="production">
      <PsHeader module="production" title={mode === 'new' ? t('ps.mould.new') : `${code} · ${M?.name}`} listTo="/production/moulds" listLabel={t('ps.mould.title')}
        pills={M ? <><MaintPill status={M.maint_status} />{M.life_warn && <span className="pill pill-crit">{t('ps.mould.lifeWarnPill', { n: fmtQty(M.life_pct) })}</span>}<SourcePill source={M.source} /></> : <SourcePill source="erp" />}
        sub={M ? [t(`ps.res.kind.${M.kind}`), M.location, M.asset_no].filter(Boolean).join(' · ') : t('ps.mould.newSub')} />
      <Flash text={flash} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          {M && M.unit === 'shot' && (
            <SectionCard title={t('ps.mould.schedule')}>
              <Fields items={[[t('ps.mould.shots'), fmtQty(M.shots_done)], [t('ps.mould.ratedLife'), fmtQty(M.rated_life_shots)], [t('ps.mould.life'), M.life_pct == null ? '—' : `${fmtQty(M.life_pct)} %`],
                [t('ps.mould.since'), fmtQty(M.shots_since)], [t('ps.mould.nextDue'), [M.next_due_shots != null ? t('ps.mould.atShots', { n: fmtQty(M.next_due_shots) }) : null, M.next_due_on ? fmtDay(M.next_due_on) : null].filter(Boolean).join(' · ')],
                [t('ps.mould.lastMaint'), fmtDay(M.last_maint_on)]]} />
            </SectionCard>
          )}
          <SectionCard title={t('erp.section.general')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              {mode === 'new' && <label className={label}>{t('ps.mould.code')} <span className="text-crit-fg">*</span><input id="res-code" className={`${inputCls} font-mono uppercase`} value={newCode} onChange={(e) => setNewCode(e.target.value)} /></label>}
              {fld('name', t('erp.col.name'))}
              <label className={label}>{t('ps.mould.kind')}<select id="res-kind" disabled={!canWrite} className={inputCls} value={f.kind ?? 'mould'} onChange={(e) => { set('kind', e.target.value); if (e.target.value === 'mould') set('unit', 'shot'); }}>{(['mould', 'machine', 'labour', 'other'] as const).map((k) => <option key={k} value={k}>{t(`ps.res.kind.${k}`)}</option>)}</select></label>
              <label className={label}>{t('ps.mould.unit')}<select id="res-unit" disabled={!canWrite} className={inputCls} value={f.unit ?? 'hour'} onChange={(e) => set('unit', e.target.value)}>{(['shot', 'hour', 'unit'] as const).map((k) => <option key={k} value={k}>{t(`ps.unit.${k}`)}</option>)}</select></label>
              {fld('unit_cost', t('ps.mould.unitCost'), { num: true })}
              <label className={label}>{t('ps.mould.acct')}<select id="res-acct" disabled={!canWrite} className={inputCls} value={f.acct_code ?? ''} onChange={(e) => set('acct_code', e.target.value)}><option value="">—</option>{(setup.data?.accounts ?? []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}</select>
                {!setup.data?.can_finance && <span className="mt-1 block text-xs text-muted">{t('ps.financeOnly')}</span>}</label>
              {f.kind === 'mould' && <>{fld('cavities', t('ps.mould.cavities'), { num: true })}{fld('rated_life_shots', t('ps.mould.ratedLife'), { num: true })}{fld('shots_done', t('ps.mould.shots'), { num: true })}</>}
              {fld('location', t('ps.mould.location'))}{fld('asset_no', t('ps.mould.asset'))}
              {f.kind === 'mould' && fld('maint_every_shots', t('ps.mould.everyShots'), { num: true })}
              {fld('maint_every_days', t('ps.mould.everyDays'), { num: true })}
              {fld('note', t('erp.col.remarks'))}
            </div>
            <div className="flex flex-wrap gap-2 border-t border-line p-5">
              <Button variant="primary" id="res-save" disabled={busy || !canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={save}>{busy ? t('so.saving') : t('ps.save')}</Button>
            </div>
          </SectionCard>
        </div>
        {mode === 'view' && (
          <aside className="min-w-0 space-y-5">
            {canWrite && (
              <SectionCard title={t('ps.mould.recordMaint')}>
                <div className="space-y-3 p-5">
                  <label className={label}>{t('ps.mould.doneOn')}<input id="maint-date" type="date" className={`${inputCls} num`} value={mDate} onChange={(e) => setMDate(e.target.value)} /></label>
                  <label className={label}>{t('ps.mould.maintKind')}<select id="maint-kind" className={inputCls} value={mKind} onChange={(e) => setMKind(e.target.value)}>{(['preventive', 'repair', 'inspection'] as const).map((k) => <option key={k} value={k}>{t(`ps.mould.mk.${k}`)}</option>)}</select></label>
                  <label className={label}>{t('erp.col.remarks')}<input id="maint-note" dir="auto" className={inputCls} value={mNote} onChange={(e) => setMNote(e.target.value)} /></label>
                  <Button variant="primary" id="maint-save" className="w-full" disabled={busy} onClick={maint} icon={<Wrench className="h-4 w-4" aria-hidden />}>{t('ps.mould.recordMaint')}</Button>
                </div>
              </SectionCard>
            )}
            <SectionCard title={t('ps.mould.history')}>
              {(q.data?.log ?? []).length === 0 ? <p className="p-5 text-sm text-muted">{t('ps.mould.noHistory')}</p> : (
                <ul className="divide-y divide-line text-sm" data-testid="maint-log">{q.data!.log.map((m) => (
                  <li key={m.maint_id} className="px-5 py-3"><p className="font-medium">{t(`ps.mould.mk.${m.kind}`)} · {fmtDay(m.done_on)}</p><p className="num text-xs text-muted">{t('ps.mould.atShots', { n: fmtQty(m.shots_at) })}</p>{m.note && <p dir="auto" className="text-ink-2">{m.note}</p>}</li>))}</ul>
              )}
            </SectionCard>
          </aside>
        )}
      </div>
    </RequireModule>
  );
}

// ---------- Production setup ----------
export function ProductionSetupPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const company = useDefaultCompany();
  const setup = usePrdSetup(company || null);
  const S = setup.data;
  const [wip, setWip] = useState('');
  const [vari, setVari] = useState('');
  const [pct, setPct] = useState('');
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (S) { setWip(S.setting.wip_acct ?? ''); setVari(S.setting.variance_acct ?? ''); setPct(S.setting.life_warn_pct == null ? '' : String(Number(S.setting.life_warn_pct))); } }, [S]);
  async function save() {
    setErr(null); setBusy(true);
    try {
      const body: Record<string, unknown> = { life_warn_pct: pct };
      if (wip !== (S?.setting.wip_acct ?? '') || vari !== (S?.setting.variance_acct ?? '')) Object.assign(body, { wip_acct: wip, variance_acct: vari });
      await prdSettingSet(company, body); setFlash(t('ps.setupSaved')); qc.invalidateQueries({ queryKey: ['prd-setup'] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  if (setup.isLoading) return <RequireModule module="production"><PageLoading /></RequireModule>;
  return (
    <PsListFrame module="production" title={t('ps.setup.title')} desc={t('ps.setup.desc')}>
      <Flash text={flash} />
      <FormError message={err} />
      {setup.error && <div className="card mb-5"><ErrorState error={setup.error} onRetry={() => setup.refetch()} /></div>}
      <SectionCard title={t('ps.setup.accounts')} className="max-w-3xl">
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <label className={label}>{t('ps.setup.wip')}<select id="setup-wip" disabled={!S?.can_finance} className={inputCls} value={wip} onChange={(e) => setWip(e.target.value)}><option value="">{t('ps.notSet')}</option>{(S?.accounts ?? []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}</select></label>
          <label className={label}>{t('ps.setup.variance')}<select id="setup-var" disabled={!S?.can_finance} className={inputCls} value={vari} onChange={(e) => setVari(e.target.value)}><option value="">{t('ps.notSet')}</option>{(S?.accounts ?? []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}</select></label>
          <label className={label}>{t('ps.setup.lifeWarn')}<input id="setup-pct" inputMode="decimal" disabled={!S?.can_write} className={`${inputCls} num`} value={pct} onChange={(e) => setPct(e.target.value)} /></label>
          <div><span className={label}>{t('ps.setup.numbering')}</span><p className="mt-3 font-mono">{S?.numbering ?? t('ps.notSet')}</p></div>
        </div>
        {!S?.can_finance && <p className="border-t border-line px-5 py-3 text-[13px] text-muted">{t('ps.financeOnly')}</p>}
        <div className="flex flex-wrap gap-2 border-t border-line p-5">
          <Button variant="primary" id="setup-save" disabled={busy || !S?.can_write} disabledReason={!S?.can_write ? t('erp.readOnly', { module: 'Production' }) : undefined} onClick={save}>{t('ps.save')}</Button>
        </div>
      </SectionCard>
    </PsListFrame>
  );
}
