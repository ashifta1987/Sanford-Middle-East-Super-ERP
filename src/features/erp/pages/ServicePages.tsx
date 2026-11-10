import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertTriangle, CircleCheck, Pencil, Plus, ShieldAlert, ShieldCheck, Trash2 } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Fields, SectionCard, YesNo, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox } from '../components/Combobox';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { FormError, Flash, fmtWhen, useDefaultCompany, useFlash } from './BankingPages';
import { SourcePill, today } from './SalesOrderPages';
import { ActivityList, NoteDialog, PsHeader, PsListFrame, inputCls, label, primaryLink, secondaryLink } from './ProductionPages';
import { parseLots, searchStockItems, type StockItemHit } from '../inventory';
import { searchCustomers, type CustomerHit } from '../salesOrder';
import { searchAllItems } from '../production';
import {
  callParts, callSave, callStatus, cardSave, contractSave, contractStatus, invoicesFor, svcSettingSet, useCallInfo, useCardInfo, useContractInfo,
  useSvcSetup, warrantyCheck, warrantyRuleSave, type CallStatus, type Warranty, type WarrantyStatus,
} from '../service';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type ItemRow = Awaited<ReturnType<typeof searchAllItems>>[number];
const CALL_TONE: Record<CallStatus, string> = { open: 'pill-info', in_progress: 'pill-warning', resolved: 'pill-ok', closed: 'pill-neutral', cancelled: 'pill-crit' };
export function CallStatusPill({ status }: { status: CallStatus }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', CALL_TONE[status])} data-testid="call-status">{t(`ps.call.status.${status}`)}</span>;
}
const W_TONE: Record<string, string> = { in_warranty: 'pill-ok', contract: 'pill-ok', out_of_warranty: 'pill-crit', no_rule: 'pill-warning', unknown: 'pill-neutral', none: 'pill-neutral' };
export function WarrantyPill({ status }: { status: WarrantyStatus | null | undefined }) {
  const { t } = useTranslation();
  if (!status) return <span className="text-muted">—</span>;
  return <span className={clsx('pill', W_TONE[status])} data-testid="warranty-pill">{t(`ps.w.${status}`)}</span>;
}

/** Warranty result card: status, dates, basis, contract, and the server's messages as written. */
function WarrantyCard({ w, company }: { w: Warranty | null; company: string }) {
  const { t } = useTranslation();
  if (!w || w.status === 'none') return null;
  const bad = w.status === 'out_of_warranty';
  return (
    <section className={clsx('card p-5', bad ? 'border-crit-fg/40 bg-crit-bg text-crit-fg' : w.status === 'in_warranty' || w.status === 'contract' ? 'border-ok-fg/40 bg-ok-bg text-ok-fg' : '')} data-testid="warranty-card">
      <p className="flex items-center gap-2 font-semibold">{bad ? <ShieldAlert className="h-5 w-5" aria-hidden /> : <ShieldCheck className="h-5 w-5" aria-hidden />}{t(`ps.w.title.${w.status}`)}</p>
      <dl className="mt-2 space-y-1 text-sm">
        {w.warranty_end && <div><dt className="inline">{t('ps.w.ends')}: </dt><dd className="num inline font-medium">{fmtDay(w.warranty_end)}</dd></div>}
        {w.warranty_start && <div><dt className="inline">{t('ps.w.from')}: </dt><dd className="num inline">{fmtDay(w.warranty_start)}{w.months ? ` · ${t('ps.w.months', { n: w.months })}` : ''}</dd></div>}
        {w.basis && <div><dt className="inline">{t('ps.w.basis')}: </dt><dd className="inline">{t(`ps.w.b.${w.basis}`)}{w.invoice ? ` · ${w.invoice.doc_no}` : ''}
          {w.card_id && <> · <Link className="underline" to={`/service/equipment/${company}/${w.card_id}`}>{t('ps.eq.one')}</Link></>}</dd></div>}
        {w.contract && <div><dt className="inline">{t('ps.w.contract')}: </dt><dd className="inline"><Link className="underline" to={`/service/contracts/${company}/${w.contract.contract_id}`}>{w.contract.doc_no}</Link> · {fmtDay(w.contract.ends_on)}{w.contract.response_hours != null ? ` · ${t('ps.ct.respH', { n: fmtQty(w.contract.response_hours) })}` : ''}</dd></div>}
      </dl>
      {w.messages.map((m, i) => <p key={i} dir="auto" className="mt-2 flex items-start gap-1.5 text-[13px]"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{m}</p>)}
    </section>
  );
}

// ---------- Service calls ----------
export function ServiceCallsPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'service_call', table: 'service_call_list',
    select: 'company_code,call_id,doc_no,card_code,card_name,item_code,serial_no,subject,priority,status,technician_name,warranty_status,flagged,opened_at,overdue',
    searchCols: ['doc_no', 'card_code', 'card_name', 'item_code', 'serial_no', 'subject', 'technician_name'], searchLabel: t('ps.call.search'),
    filters: [
      { key: 'status', label: t('erp.col.status'), options: (['open', 'in_progress', 'resolved', 'closed', 'cancelled'] as const).map((s) => [s, t(`ps.call.status.${s}`)] as [string, string]) },
      { key: 'priority', label: t('ps.call.priority'), options: (['high', 'medium', 'low'] as const).map((s) => [s, t(`ps.call.prio.${s}`)] as [string, string]) },
      { key: 'flagged', label: t('ps.call.flagged'), options: [['true', t('erp.yes')], ['false', t('erp.no')]], type: 'boolean' },
      { key: 'overdue', label: t('ps.call.overdue'), options: [['true', t('erp.yes')], ['false', t('erp.no')]], type: 'boolean' },
    ],
    defaultSort: { col: 'opened_at', asc: false },
    rowKey: (r) => `${r.company_code}|${r.call_id}`,
    rowLink: (r) => `/service/calls/${r.company_code}/${r.call_id}`,
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'card_name', header: t('ps.call.customer'), cell: (r) => <span dir="auto">{r.card_name ?? r.card_code}</span> },
      { key: 'subject', header: t('ps.call.subject'), cell: (r) => <span dir="auto">{r.subject}</span>, hideBelow: 'md' },
      { key: 'serial_no', header: t('ps.call.serial'), cell: (r) => <span className="font-mono text-[13px]">{[r.item_code, r.serial_no].filter(Boolean).join(' · ') || '—'}</span>, hideBelow: 'lg' },
      { key: 'warranty_status', header: t('ps.call.warranty'), cell: (r) => <WarrantyPill status={r.warranty_status} />, csv: (r) => r.warranty_status },
      { key: 'status', header: t('erp.col.status'), cell: (r) => <span className="inline-flex flex-wrap gap-1"><CallStatusPill status={r.status} />{r.overdue && <span className="pill pill-crit">{t('ps.call.overdue')}</span>}</span>, csv: (r) => r.status },
      { key: 'technician_name', header: t('ps.call.technician'), hideBelow: 'lg' },
      { key: 'opened_at', header: t('ps.call.opened'), cell: (r) => fmtDay(r.opened_at), csv: (r) => r.opened_at, hideBelow: 'sm' },
    ],
  }), [t]);
  return <PsListFrame module="service" title={t('ps.call.title')} desc={t('ps.call.desc')} newTo="/service/calls/new" newLabel={t('ps.call.new')} newId="call-new"><ListScreen config={cfg} /></PsListFrame>;
}

export function ServiceCallFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const dflt = useDefaultCompany();
  const company = mode === 'edit' ? params.company ?? '' : dflt;
  const cid = mode === 'edit' ? Number(params.id) : 0;
  const { canWrite, readOnlyReason } = useModuleLevel('service');
  const setup = useSvcSetup(company || null);
  const info = useCallInfo(company, cid);
  const [f, setF] = useState<Record<string, string>>({ priority: 'medium' });
  const [custText, setCustText] = useState('');
  const [itemText, setItemText] = useState('');
  const [serialItem, setSerialItem] = useState(false);
  const [w, setW] = useState<Warranty | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const c = info.data?.call;
    if (!c) return;
    setF({ card_code: c.card_code, contact: c.contact ?? '', phone: c.phone ?? '', item_code: c.item_code ?? '', serial_no: c.serial_no ?? '', invoice_entry: c.invoice_entry ? String(c.invoice_entry) : '',
      subject: c.subject, problem: c.problem ?? '', priority: c.priority, technician: c.technician ?? '' });
    setCustText(`${c.card_code} · ${c.card_name ?? ''}`); setItemText(c.item_code ? `${c.item_code} · ${c.item_name ?? ''}` : ''); setSerialItem(Boolean(c.serial_managed));
  }, [info.data]);
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const inv = useQuery({ queryKey: ['svc-inv', company, f.card_code, f.item_code], enabled: Boolean(company && f.card_code && f.item_code),
    queryFn: () => invoicesFor(company, f.card_code, f.item_code) });
  const sig = JSON.stringify([f.card_code, f.item_code, f.serial_no, f.invoice_entry]);
  useEffect(() => {
    if (!company || !f.item_code) { setW(null); return; }
    const h = setTimeout(() => { warrantyCheck(company, { card_code: f.card_code, item_code: f.item_code, serial_no: f.serial_no, invoice_entry: f.invoice_entry || null }).then(setW).catch(() => undefined); }, 350);
    return () => clearTimeout(h);
  }, [sig, company]); // eslint-disable-line react-hooks/exhaustive-deps
  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await callSave(company, { ...f, call_id: cid || null, invoice_entry: f.invoice_entry || null, technician: f.technician || null });
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['svc-call'] });
      nav(`/service/calls/${company}/${r.call_id}`, { state: { flash: t(r.warranty.flagged ? 'ps.call.savedFlagged' : 'ps.call.saved', { no: r.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (setup.isLoading || (mode === 'edit' && info.isLoading)) return <RequireModule module="service"><PageLoading /></RequireModule>;
  const S = setup.data;
  return (
    <RequireModule module="service">
      <PsHeader module="service" title={mode === 'new' ? t('ps.call.new') : `${t('ps.call.one')} ${info.data?.call.doc_no ?? ''}`} pills={<SourcePill source="erp" />}
        sub={t('ps.call.formSub')} listTo="/service/calls" listLabel={t('ps.call.title')} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('ps.call.customerProduct')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
              <Combobox<CustomerHit> id="call-customer" label={t('ps.call.customer')} required text={custText} onText={(s) => { setCustText(s); set('card_code', ''); }}
                onSelect={(o) => { setCustText(o.label); setF((x) => ({ ...x, card_code: o.value, phone: x.phone || (o.data.phone ?? ''), invoice_entry: '' })); }}
                search={async (q) => (await searchCustomers(company, q)).map((c) => ({ value: c.card_code, label: `${c.card_code} · ${c.name}`, data: c, meta: <span className="text-xs text-muted">{[c.city, c.phone].filter(Boolean).join(' · ')}</span> }))} />
              <label className={label}>{t('ps.call.contact')}<input id="call-contact" dir="auto" className={inputCls} value={f.contact ?? ''} onChange={(e) => set('contact', e.target.value)} /></label>
              <Combobox<ItemRow> id="call-item" label={t('ps.call.item')} text={itemText} onText={(s) => { setItemText(s); set('item_code', ''); }}
                onSelect={(o) => { setItemText(o.label); setSerialItem(o.data.serial_managed); setF((x) => ({ ...x, item_code: o.value, invoice_entry: '' })); }}
                search={async (q) => (await searchAllItems(company, q)).map((i) => ({ value: i.item_code, label: `${i.item_code} · ${i.name}`, data: i, meta: i.serial_managed ? <span className="text-xs text-muted">S/N</span> : undefined }))} />
              <label className={label}>{t('ps.call.serial')}{serialItem && <span className="text-crit-fg"> *</span>}<input id="call-serial" className={`${inputCls} font-mono`} value={f.serial_no ?? ''} onChange={(e) => set('serial_no', e.target.value)} /></label>
              <label className={label}>{t('ps.call.invoice')}
                <select id="call-invoice" className={inputCls} value={f.invoice_entry ?? ''} onChange={(e) => set('invoice_entry', e.target.value)} disabled={!f.card_code || !f.item_code}>
                  <option value="">{t('ps.call.noInvoice')}</option>{(inv.data ?? []).map((d) => <option key={d.doc_entry} value={d.doc_entry}>{d.doc_num} · {fmtDay(d.doc_date)}</option>)}</select>
                <span className="mt-1 block text-xs text-muted">{t('ps.call.invoiceHelp')}</span></label>
              <label className={label}>{t('ps.call.phone')}<input id="call-phone" className={`${inputCls} num`} value={f.phone ?? ''} onChange={(e) => set('phone', e.target.value)} /></label>
            </div>
          </SectionCard>
          <SectionCard title={t('ps.call.problem')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
              <label className={`${label} sm:col-span-2`}>{t('ps.call.subject')} <span className="text-crit-fg">*</span><input id="call-subject" dir="auto" className={inputCls} value={f.subject ?? ''} onChange={(e) => set('subject', e.target.value)} /></label>
              <label className={`${label} sm:col-span-2`}>{t('ps.call.details')}<textarea id="call-problem" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={f.problem ?? ''} onChange={(e) => set('problem', e.target.value)} /></label>
              <label className={label}>{t('ps.call.priority')}<select id="call-priority" className={inputCls} value={f.priority} onChange={(e) => set('priority', e.target.value)}>{(['high', 'medium', 'low'] as const).map((p) => <option key={p} value={p}>{t(`ps.call.prio.${p}`)}</option>)}</select></label>
              <label className={label}>{t('ps.call.technician')}<select id="call-tech" className={inputCls} value={f.technician ?? ''} onChange={(e) => set('technician', e.target.value)}><option value="">{t('ps.call.unassigned')}</option>{(S?.technicians ?? []).map((u) => <option key={u.user_id} value={u.user_id}>{u.name}</option>)}</select></label>
            </div>
          </SectionCard>
          <div className="flex flex-wrap gap-2">
            <Button variant="primary" id="call-save" disabled={busy || !canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={save}>{busy ? t('so.saving') : mode === 'new' ? t('ps.call.log') : t('ps.save')}</Button>
            <Link to={mode === 'edit' ? `/service/calls/${company}/${cid}` : '/service/calls'} className={secondaryLink}>{t('so.cancelEdit')}</Link>
          </div>
        </div>
        <aside className="min-w-0 space-y-5">
          {w ? <WarrantyCard w={w} company={company} /> : <SectionCard title={t('ps.call.warranty')}><p className="p-5 text-sm text-muted">{t('ps.call.warrantyHint')}</p></SectionCard>}
        </aside>
      </div>
    </RequireModule>
  );
}

const NEXT: Record<CallStatus, CallStatus[]> = { open: ['in_progress', 'resolved', 'cancelled'], in_progress: ['resolved', 'cancelled'], resolved: ['closed', 'in_progress'], closed: [], cancelled: [] };
export function ServiceCallPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const cid = Number(id);
  const qc = useQueryClient();
  const q = useCallInfo(company, cid);
  const setup = useSvcSetup(company || null);
  const C = q.data;
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [solution, setSolution] = useState('');
  const [cancelOpen, setCancelOpen] = useState(false);
  const [pWhs, setPWhs] = useState('WH01');
  const [pDate, setPDate] = useState(today());
  const [pItem, setPItem] = useState(''); const [pText, setPText] = useState(''); const [pQty, setPQty] = useState('1'); const [pLots, setPLots] = useState('');
  const [pSerial, setPSerial] = useState(false); const [pBatch, setPBatch] = useState(false); const [pWhy, setPWhy] = useState('');
  useEffect(() => { if (C?.call.solution) setSolution(C.call.solution); }, [C?.call.solution]);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['svc-call', company, cid] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); };
  async function move(s: CallStatus, text: string | null) {
    setErr(null); setBusy(true);
    try { await callStatus(company, cid, s, text); setFlash(t(`ps.call.moved.${s}`, { no: C!.call.doc_no })); refresh(); }
    catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  async function parts() {
    setErr(null); setBusy(true);
    try {
      const r = await callParts(company, cid, { doc_date: pDate, whs_code: pWhs }, [{ item_code: pItem, qty: pQty, lots: pSerial || pBatch ? parseLots(pLots, pBatch) : [] }], pWhy || null);
      setPItem(''); setPText(''); setPQty('1'); setPLots(''); setPWhy('');
      setFlash(t(r.state === 'approved' ? 'ps.call.partsPosted' : 'ps.call.partsWaiting', { no: r.doc_no, value: fmtMoney(r.value) })); refresh();
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (q.isLoading) return <RequireModule module="service"><PageLoading /></RequireModule>;
  if (q.error || !C) return <RequireModule module="service"><PsHeader module="service" title={id} listTo="/service/calls" listLabel={t('ps.call.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  const c = C.call;
  const live = c.status !== 'closed' && c.status !== 'cancelled';
  return (
    <RequireModule module="service">
      <PsHeader module="service" title={`${t('ps.call.one')} ${c.doc_no}`} listTo="/service/calls" listLabel={t('ps.call.title')}
        pills={<><CallStatusPill status={c.status} /><WarrantyPill status={c.warranty_status} />{c.overdue && <span className="pill pill-crit">{t('ps.call.overdue')}</span>}<SourcePill source="erp" /></>}
        sub={[`${c.card_code} · ${c.card_name ?? ''}`, t(`ps.call.prio.${c.priority}`), c.technician_name ?? t('ps.call.unassigned'), fmtWhen(c.opened_at)].join(' · ')}
        actions={C.can_write && live ? <Link id="call-edit" to={`/service/calls/${company}/${cid}/edit`} className={secondaryLink}><Pencil className="h-4 w-4" aria-hidden /> {t('ps.edit')}</Link> : undefined} />
      <Flash text={flash} />
      <FormError message={err} />
      {c.flagged && <p role="alert" className="mb-5 flex items-start gap-2 rounded-card border border-crit-fg/30 bg-crit-bg p-4 font-semibold text-crit-fg" data-testid="call-flag"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" aria-hidden /><span dir="auto">{t('ps.call.flagText', { d: fmtDay(c.warranty_end) })}</span></p>}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <Fields items={[[t('ps.call.subject'), <span dir="auto">{c.subject}</span>], [t('ps.call.item'), c.item_code ? `${c.item_code} · ${c.item_name ?? ''}` : null],
              [t('ps.call.serial'), c.serial_no ? <span className="font-mono">{c.serial_no}</span> : null], [t('ps.call.invoice'), c.invoice?.doc_no],
              [t('ps.call.contact'), [c.contact, c.phone].filter(Boolean).join(' · ')], [t('ps.call.dueBy'), c.due_by ? fmtWhen(c.due_by) : null],
              [t('ps.call.details'), c.problem ? <span dir="auto" className="whitespace-pre-wrap">{c.problem}</span> : null], [t('ps.w.contract'), c.contract_no], [t('ps.call.createdBy'), c.created_by_name]]} />
          </SectionCard>
          {(c.solution || (C.can_write && live)) && (
            <SectionCard title={t('ps.call.solution')}>
              {C.can_write && (c.status === 'open' || c.status === 'in_progress') ? (
                <div className="space-y-3 p-5">
                  <textarea id="call-solution" rows={3} dir="auto" className="input py-2 text-[15px] text-ink" value={solution} onChange={(e) => setSolution(e.target.value)} placeholder={t('ps.call.solutionPh')} />
                </div>
              ) : <p dir="auto" className="whitespace-pre-wrap p-5 text-sm">{c.solution ?? '—'}</p>}
              {C.can_write && live && (
                <div className="flex flex-wrap gap-2 border-t border-line p-4">
                  {NEXT[c.status].filter((s) => s !== 'cancelled').map((s) => (
                    <Button key={s} id={`call-${s}`} variant={s === 'resolved' || s === 'closed' ? 'primary' : 'secondary'} disabled={busy} onClick={() => move(s, s === 'resolved' ? solution : null)}>{t(`ps.call.to.${s}`)}</Button>))}
                  {NEXT[c.status].includes('cancelled') && <Button variant="danger" id="call-cancel" onClick={() => setCancelOpen(true)}>{t('ps.call.to.cancelled')}</Button>}
                </div>
              )}
            </SectionCard>
          )}
          <SectionCard title={t('ps.call.parts')}>
            {C.parts.length === 0 ? <p className="p-5 text-sm text-muted">{t('ps.call.noParts')}</p> : (
              <ul className="divide-y divide-line" data-testid="call-parts">{C.parts.map((p) => (
                <li key={p.doc_entry} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3">
                  <Link className="font-mono text-primary hover:underline" to={`/docs/goods_issue/${company}/${p.doc_entry}`}>{p.doc_no}</Link>
                  <span className="text-sm text-muted">{fmtDay(p.doc_date)}</span><span className="num text-sm">{fmtMoney(p.total)}</span>
                  <span className={clsx('pill', p.state === 'approved' ? 'pill-ok' : p.state === 'pending_approval' ? 'pill-warning' : 'pill-neutral')}>{t(`ps.gi.${p.state}`, { defaultValue: p.state })}</span>
                </li>))}</ul>
            )}
            {C.can_write && live && (C.can_inventory ? (
              <div className="grid grid-cols-1 gap-3 border-t border-line p-5 sm:grid-cols-2 xl:grid-cols-4">
                <label className={label}>{t('erp.col.warehouse')}<select id="parts-whs" className={inputCls} value={pWhs} onChange={(e) => setPWhs(e.target.value)}>{(setup.data?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}</select></label>
                <Combobox<StockItemHit> id="parts-item" label={t('ps.call.part')} text={pText} onText={(s) => { setPText(s); setPItem(''); }}
                  onSelect={(o) => { setPItem(o.value); setPText(o.label); setPSerial(o.data.serial_managed); setPBatch(o.data.batch_managed); }}
                  search={async (s) => (await searchStockItems(company, s)).map((i) => ({ value: i.item_code, label: `${i.item_code} · ${i.name}`, data: i }))} />
                <label className={label}>{t('erp.col.qty')}<input id="parts-qty" inputMode="decimal" className={`${inputCls} num`} value={pQty} onChange={(e) => setPQty(e.target.value)} /></label>
                <label className={label}>{t('erp.col.postingDate')}<input id="parts-date" type="date" className={`${inputCls} num`} value={pDate} onChange={(e) => setPDate(e.target.value)} /></label>
                {(pSerial || pBatch) && <label className={`${label} sm:col-span-2`}>{t('inv.lots')}<input id="parts-lots" className={inputCls} value={pLots} onChange={(e) => setPLots(e.target.value)} placeholder={t(pSerial ? 'ps.serialsPh' : 'ps.batchesPh')} /></label>}
                <label className={`${label} sm:col-span-2`}>{t('ps.call.partsReason')}<input id="parts-why" dir="auto" className={inputCls} value={pWhy} onChange={(e) => setPWhy(e.target.value)} /></label>
                <div className="flex items-end sm:col-span-2 xl:col-span-4"><Button variant="primary" id="parts-issue" disabled={busy || !pItem} onClick={parts}>{t('ps.call.issueParts')}</Button></div>
                <p className="text-[13px] text-muted sm:col-span-2 xl:col-span-4">{t('ps.call.partsHelp', { reason: setup.data?.setting.parts_reason_code ?? t('ps.notSet') })}</p>
              </div>
            ) : <p className="border-t border-line px-5 py-3 text-[13px] text-muted" data-testid="parts-no-inventory">{t('ps.call.partsNeedInventory')}</p>)}
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('ps.call.warranty')}>
            <div className="space-y-2 p-5 text-sm">
              <p><WarrantyPill status={c.warranty_status} /></p>
              {c.warranty_end && <p>{t('ps.w.ends')}: <span className="num font-medium">{fmtDay(c.warranty_end)}</span></p>}
              {c.warranty_note && <p dir="auto" className="text-ink-2">{c.warranty_note}</p>}
              {c.equipment_card_id && <Link className="text-primary hover:underline" to={`/service/equipment/${company}/${c.equipment_card_id}`}>{t('ps.eq.open')}</Link>}
            </div>
          </SectionCard>
          {C.history.length > 0 && (
            <SectionCard title={t('ps.call.history')}><ul className="divide-y divide-line text-sm">{C.history.map((h) => (
              <li key={h.call_id} className="flex items-center justify-between gap-2 px-5 py-2"><Link className="font-mono text-primary hover:underline" to={`/service/calls/${company}/${h.call_id}`}>{h.doc_no}</Link><span dir="auto" className="truncate">{h.subject}</span><CallStatusPill status={h.status} /></li>))}</ul></SectionCard>
          )}
          <ActivityList items={C.activity} prefix="service_call_" />
        </aside>
      </div>
      <NoteDialog id="call-cancel" open={cancelOpen} required title={t('ps.call.cancelTitle', { no: c.doc_no })} labelText={t('inv.cancelNote')} confirm={t('ps.call.to.cancelled')}
        onClose={() => setCancelOpen(false)} onConfirm={async (n) => { await callStatus(company, cid, 'cancelled', n); setFlash(t('ps.call.moved.cancelled', { no: c.doc_no })); refresh(); }} />
    </RequireModule>
  );
}

// ---------- Equipment cards ----------
export function EquipmentPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'equipment_card', table: 'equipment_card_list',
    select: 'company_code,card_id,item_code,item_name,serial_no,card_code,card_name,sold_on,warranty_end,warranty_status,n_calls,source',
    searchCols: ['serial_no', 'item_code', 'item_name', 'card_code', 'card_name'], searchLabel: t('ps.eq.search'),
    filters: [{ key: 'warranty_status', label: t('ps.call.warranty'), options: (['in_warranty', 'out_of_warranty', 'unknown'] as const).map((s) => [s, t(`ps.w.${s}`)] as [string, string]) }],
    defaultSort: { col: 'serial_no', asc: true },
    rowKey: (r) => `${r.company_code}|${r.card_id}`,
    rowLink: (r) => `/service/equipment/${r.company_code}/${r.card_id}`,
    columns: [
      { key: 'serial_no', header: t('ps.call.serial'), mono: true },
      { key: 'item_code', header: t('ps.call.item'), cell: (r) => <span><span className="font-mono">{r.item_code}</span><span dir="auto" className="block text-xs text-muted max-sm:hidden">{r.item_name}</span></span> },
      { key: 'card_name', header: t('ps.call.customer'), cell: (r) => <span dir="auto">{r.card_name ?? r.card_code}</span>, hideBelow: 'md' },
      { key: 'warranty_end', header: t('ps.w.ends'), cell: (r) => fmtDay(r.warranty_end), csv: (r) => r.warranty_end, hideBelow: 'sm' },
      { key: 'warranty_status', header: t('ps.call.warranty'), cell: (r) => <WarrantyPill status={r.warranty_status} />, csv: (r) => r.warranty_status },
      { key: 'n_calls', header: t('ps.eq.calls'), align: 'end', hideBelow: 'md' },
    ],
  }), [t]);
  return <PsListFrame module="service" title={t('ps.eq.title')} desc={t('ps.eq.desc')} newTo="/service/equipment/new" newLabel={t('ps.eq.new')} newId="eq-new"><ListScreen config={cfg} /></PsListFrame>;
}

export function EquipmentCardPage({ mode }: { mode: 'new' | 'view' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const dflt = useDefaultCompany();
  const company = mode === 'view' ? params.company ?? '' : dflt;
  const id = mode === 'view' ? Number(params.id) : 0;
  const { canWrite, readOnlyReason } = useModuleLevel('service');
  const q = useCardInfo(company, id);
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [f, setF] = useState<Record<string, string>>({});
  const [custText, setCustText] = useState(''); const [itemText, setItemText] = useState('');
  useEffect(() => {
    const c = q.data?.card;
    if (!c) return;
    setF({ item_code: c.item_code, serial_no: c.serial_no, card_code: c.card_code, invoice_entry: c.invoice_entry ? String(c.invoice_entry) : '', sold_on: c.sold_on ?? '', warranty_end: c.warranty_end ?? '', note: c.note ?? '' });
    setCustText(`${c.card_code} · ${c.card_name ?? ''}`); setItemText(`${c.item_code} · ${c.item_name ?? ''}`);
  }, [q.data]);
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const inv = useQuery({ queryKey: ['svc-inv', company, f.card_code, f.item_code], enabled: Boolean(company && f.card_code && f.item_code), queryFn: () => invoicesFor(company, f.card_code, f.item_code) });
  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await cardSave(company, { ...f, card_id: id || null, invoice_entry: f.invoice_entry || null, sold_on: f.sold_on || null, warranty_end: f.warranty_end || null });
      qc.invalidateQueries({ queryKey: ['svc-card'] }); qc.invalidateQueries({ queryKey: ['erp-list'] });
      if (mode === 'new') nav(`/service/equipment/${company}/${r.card_id}`, { state: { flash: t('ps.eq.saved') } }); else setFlash(t('ps.eq.saved'));
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  if (mode === 'view' && q.isLoading) return <RequireModule module="service"><PageLoading /></RequireModule>;
  const D = q.data;
  if (mode === 'view' && (q.error || !D)) return <RequireModule module="service"><PsHeader module="service" title={String(id)} listTo="/service/equipment" listLabel={t('ps.eq.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  return (
    <RequireModule module="service">
      <PsHeader module="service" title={D ? `${D.card.serial_no} · ${D.card.item_name ?? D.card.item_code}` : t('ps.eq.new')} listTo="/service/equipment" listLabel={t('ps.eq.title')}
        pills={D ? <><WarrantyPill status={D.warranty.status} /><SourcePill source={D.card.source} /></> : <SourcePill source="erp" />} sub={D ? `${D.card.card_code} · ${D.card.card_name ?? ''}` : t('ps.eq.newSub')} />
      <Flash text={flash} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
              <Combobox id="eq-item" label={t('ps.call.item')} required text={itemText} onText={(s) => { setItemText(s); set('item_code', ''); }} onSelect={(o) => { setItemText(o.label); set('item_code', o.value); }}
                search={async (s) => (await searchAllItems(company, s)).map((i) => ({ value: i.item_code, label: `${i.item_code} · ${i.name}`, data: i }))} />
              <label className={label}>{t('ps.call.serial')} <span className="text-crit-fg">*</span><input id="eq-serial" className={`${inputCls} font-mono`} value={f.serial_no ?? ''} onChange={(e) => set('serial_no', e.target.value)} /></label>
              <Combobox id="eq-customer" label={t('ps.call.customer')} required text={custText} onText={(s) => { setCustText(s); set('card_code', ''); }} onSelect={(o) => { setCustText(o.label); set('card_code', o.value); }}
                search={async (s) => (await searchCustomers(company, s)).map((c) => ({ value: c.card_code, label: `${c.card_code} · ${c.name}`, data: c }))} />
              <label className={label}>{t('ps.call.invoice')}<select id="eq-invoice" className={inputCls} value={f.invoice_entry ?? ''} onChange={(e) => set('invoice_entry', e.target.value)}><option value="">{t('ps.call.noInvoice')}</option>{(inv.data ?? []).map((d) => <option key={d.doc_entry} value={d.doc_entry}>{d.doc_num} · {fmtDay(d.doc_date)}</option>)}</select></label>
              <label className={label}>{t('ps.eq.soldOn')}<input id="eq-sold" type="date" disabled={Boolean(f.invoice_entry)} className={`${inputCls} num`} value={f.sold_on ?? ''} onChange={(e) => set('sold_on', e.target.value)} /></label>
              <label className={label}>{t('ps.eq.endOverride')}<input id="eq-end" type="date" className={`${inputCls} num`} value={f.warranty_end ?? ''} onChange={(e) => set('warranty_end', e.target.value)} /><span className="mt-1 block text-xs text-muted">{t('ps.eq.endHelp')}</span></label>
              <label className={`${label} sm:col-span-2`}>{t('erp.col.remarks')}<input id="eq-note" dir="auto" className={inputCls} value={f.note ?? ''} onChange={(e) => set('note', e.target.value)} /></label>
            </div>
            <div className="flex flex-wrap gap-2 border-t border-line p-5"><Button variant="primary" id="eq-save" disabled={busy || !canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={save}>{t('ps.save')}</Button></div>
          </SectionCard>
          {D && (
            <SectionCard title={t('ps.eq.history')}>
              {D.calls.length === 0 ? <p className="p-5 text-sm text-muted">{t('ps.eq.noCalls')}</p> : (
                <ul className="divide-y divide-line text-sm" data-testid="eq-calls">{D.calls.map((h) => (
                  <li key={h.call_id} className="flex flex-wrap items-center justify-between gap-2 px-5 py-3"><Link className="font-mono text-primary hover:underline" to={`/service/calls/${company}/${h.call_id}`}>{h.doc_no}</Link><span dir="auto">{h.subject}</span><span className="text-muted">{fmtDay(h.opened_at)}</span><CallStatusPill status={h.status} /></li>))}</ul>
              )}
              {canWrite && <div className="border-t border-line p-4"><Link className={primaryLink} id="eq-new-call" to="/service/calls/new"><Plus className="h-4 w-4" aria-hidden /> {t('ps.call.new')}</Link></div>}
            </SectionCard>
          )}
        </div>
        <aside className="min-w-0 space-y-5">{D && <WarrantyCard w={D.warranty} company={company} />}</aside>
      </div>
    </RequireModule>
  );
}

// ---------- Service contracts (and 3PL contracts from SAP) ----------
export function ContractsPage() {
  const { t } = useTranslation();
  const [sp, setSp] = useSearchParams();
  const tab = sp.get('tab') === 'tpl' ? 'tpl' : 'service';
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'service_contract', table: 'service_contract_list',
    select: 'company_code,contract_id,doc_no,card_code,card_name,starts_on,ends_on,response_hours,covers_parts,covers_labour,all_items,state,expired,n_lines',
    searchCols: ['doc_no', 'card_code', 'card_name'], searchLabel: t('ps.ct.search'),
    filters: [{ key: 'state', label: t('erp.col.status'), options: (['draft', 'active', 'ended', 'cancelled'] as const).map((s) => [s, t(`ps.ct.state.${s}`)] as [string, string]) }],
    defaultSort: { col: 'ends_on', asc: true },
    rowKey: (r) => `${r.company_code}|${r.contract_id}`,
    rowLink: (r) => `/service/contracts/${r.company_code}/${r.contract_id}`,
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'card_name', header: t('ps.call.customer'), cell: (r) => <span dir="auto">{r.card_name ?? r.card_code}</span> },
      { key: 'ends_on', header: t('ps.ct.period'), cell: (r) => `${fmtDay(r.starts_on)} – ${fmtDay(r.ends_on)}`, csv: (r) => r.ends_on },
      { key: 'response_hours', header: t('ps.ct.response'), align: 'end', cell: (r) => (r.response_hours == null ? '—' : t('ps.ct.respH', { n: fmtQty(r.response_hours) })), hideBelow: 'md' },
      { key: 'n_lines', header: t('ps.ct.covers'), sortable: false, cell: (r) => (r.all_items ? t('ps.ct.allItems') : t('ps.ct.nItems', { n: r.n_lines })), hideBelow: 'lg' },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <span className="inline-flex gap-1"><span className={clsx('pill', r.state === 'active' ? 'pill-ok' : r.state === 'cancelled' ? 'pill-crit' : 'pill-neutral')}>{t(`ps.ct.state.${r.state}`)}</span>{r.expired && <span className="pill pill-warning">{t('ps.ct.expired')}</span>}</span>, csv: (r) => r.state },
    ],
  }), [t]);
  const tpl = useMemo<ListConfig<R>>(() => ({
    id: 'tpl_contract', table: 'tpl_contract',
    select: 'company_code,job_code,client_code,client_name,status,active,starts_on,ends_on,extended_to,storage_fee,min_storage_fee',
    searchCols: ['job_code', 'client_code', 'client_name'], searchLabel: t('ps.ct.tplSearch'),
    defaultSort: { col: 'job_code', asc: true },
    rowKey: (r) => `${r.company_code}|${r.job_code}`,
    columns: [
      { key: 'job_code', header: t('ps.ct.job'), mono: true },
      { key: 'client_name', header: t('ps.ct.client'), cell: (r) => <span dir="auto">{r.client_name ?? r.client_code}</span> },
      { key: 'ends_on', header: t('ps.ct.period'), cell: (r) => `${fmtDay(r.starts_on)} – ${fmtDay(r.extended_to ?? r.ends_on)}`, csv: (r) => r.ends_on },
      { key: 'storage_fee', header: t('ps.ct.storageFee'), align: 'end', cell: (r) => fmtMoney(r.storage_fee), hideBelow: 'md' },
      { key: 'active', header: t('erp.col.status'), cell: (r) => <YesNo value={r.active} /> },
    ],
    emptyTitle: t('ps.ct.tplEmpty'), emptyBody: t('ps.ct.tplEmptyBody'),
  }), [t]);
  return (
    <PsListFrame module="service" title={t('ps.ct.title')} desc={t('ps.ct.desc')} newTo={tab === 'service' ? '/service/contracts/new' : undefined} newLabel={t('ps.ct.new')} newId="ct-new">
      <div role="tablist" className="mb-4 flex gap-2">
        {(['service', 'tpl'] as const).map((k) => (
          <button key={k} role="tab" aria-selected={tab === k} id={`ct-tab-${k}`} className={clsx('min-h-[40px] rounded-btn border px-4 text-sm font-medium', tab === k ? 'border-primary-line bg-primary-soft text-primary-text' : 'border-line bg-surface text-ink-2 hover:bg-page')}
            onClick={() => setSp(k === 'tpl' ? { tab: 'tpl' } : {})}>{t(`ps.ct.tab.${k}`)}</button>))}
      </div>
      {tab === 'tpl' && <p className="mb-3 text-[13px] text-muted">{t('ps.ct.tplNote')}</p>}
      {tab === 'service' ? <ListScreen key="svc" config={cfg} /> : <ListScreen key="tpl" config={tpl} />}
    </PsListFrame>
  );
}

interface CLine { key: string; item_code: string; text: string; serial_no: string }
let cseq = 0;
export function ContractFormPage({ mode }: { mode: 'new' | 'edit' }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const params = useParams();
  const dflt = useDefaultCompany();
  const company = mode === 'edit' ? params.company ?? '' : dflt;
  const id = mode === 'edit' ? Number(params.id) : 0;
  const { canWrite, readOnlyReason } = useModuleLevel('service');
  const info = useContractInfo(company, id);
  const [f, setF] = useState<Record<string, string>>({ starts_on: today() });
  const [flags, setFlags] = useState({ covers_parts: true, covers_labour: true, covers_travel: false, all_items: false });
  const [custText, setCustText] = useState('');
  const [lines, setLines] = useState<CLine[]>([{ key: `c${++cseq}`, item_code: '', text: '', serial_no: '' }]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const k = info.data?.contract;
    if (!k) return;
    setF({ card_code: k.card_code, starts_on: k.starts_on, ends_on: k.ends_on, response_hours: k.response_hours == null ? '' : String(Number(k.response_hours)), terms: k.terms ?? '' });
    setFlags({ covers_parts: k.covers_parts, covers_labour: k.covers_labour, covers_travel: k.covers_travel, all_items: k.all_items });
    setCustText(`${k.card_code} · ${k.card_name ?? ''}`);
    setLines(info.data!.lines.map((l) => ({ key: `c${++cseq}`, item_code: l.item_code, text: `${l.item_code} · ${l.item_name ?? ''}`, serial_no: l.serial_no ?? '' })));
  }, [info.data]);
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const setL = (k: string, p: Partial<CLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));
  async function save() {
    setErr(null); setBusy(true);
    try {
      const r = await contractSave(company, { ...f, ...flags, contract_id: id || null, response_hours: f.response_hours || null,
        lines: flags.all_items ? [] : lines.filter((l) => l.item_code).map((l) => ({ item_code: l.item_code, serial_no: l.serial_no || null })) });
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['svc-contract'] });
      nav(`/service/contracts/${company}/${r.contract_id}`, { state: { flash: t('ps.ct.saved', { no: r.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (mode === 'edit' && info.isLoading) return <RequireModule module="service"><PageLoading /></RequireModule>;
  return (
    <RequireModule module="service">
      <PsHeader module="service" title={mode === 'new' ? t('ps.ct.new') : `${t('ps.ct.one')} ${info.data?.contract.doc_no ?? ''}`} pills={<SourcePill source="erp" />} sub={t('ps.ct.formSub')} listTo="/service/contracts" listLabel={t('ps.ct.title')} />
      <FormError message={err} />
      <div className="space-y-5">
        <SectionCard title={t('erp.section.header')}>
          <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-4">
            <Combobox id="ct-customer" label={t('ps.call.customer')} required text={custText} onText={(s) => { setCustText(s); set('card_code', ''); }} onSelect={(o) => { setCustText(o.label); set('card_code', o.value); }}
              search={async (s) => (await searchCustomers(company, s)).map((c) => ({ value: c.card_code, label: `${c.card_code} · ${c.name}`, data: c }))} />
            <label className={label}>{t('ps.ct.starts')} <span className="text-crit-fg">*</span><input id="ct-from" type="date" className={`${inputCls} num`} value={f.starts_on ?? ''} onChange={(e) => set('starts_on', e.target.value)} /></label>
            <label className={label}>{t('ps.ct.ends')} <span className="text-crit-fg">*</span><input id="ct-to" type="date" className={`${inputCls} num`} value={f.ends_on ?? ''} onChange={(e) => set('ends_on', e.target.value)} /></label>
            <label className={label}>{t('ps.ct.responseHours')}<input id="ct-resp" inputMode="decimal" className={`${inputCls} num`} value={f.response_hours ?? ''} onChange={(e) => set('response_hours', e.target.value)} /></label>
            <fieldset className="sm:col-span-2 xl:col-span-4"><legend className={label}>{t('ps.ct.coverage')}</legend>
              <div className="mt-2 flex flex-wrap gap-4">{(['covers_parts', 'covers_labour', 'covers_travel', 'all_items'] as const).map((k) => (
                <label key={k} className="inline-flex min-h-[40px] items-center gap-2 text-[15px]"><input id={`ct-${k}`} type="checkbox" className="h-4 w-4" checked={flags[k]} onChange={(e) => setFlags((x) => ({ ...x, [k]: e.target.checked }))} />{t(`ps.ct.${k}`)}</label>))}</div></fieldset>
            <label className={`${label} sm:col-span-2 xl:col-span-4`}>{t('ps.ct.terms')}<textarea id="ct-terms" rows={2} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={f.terms ?? ''} onChange={(e) => set('terms', e.target.value)} /></label>
          </div>
        </SectionCard>
        {!flags.all_items && (
          <SectionCard title={t('ps.ct.lines')}>
            <ul className="divide-y divide-line">{lines.map((l, i) => (
              <li key={l.key} className="grid grid-cols-1 gap-3 px-5 py-4 sm:grid-cols-[minmax(0,1fr)_220px_auto]">
                <Combobox id={`ct-item-${i}`} label={t('ps.call.item')} text={l.text} onText={(s) => setL(l.key, { text: s, item_code: '' })} onSelect={(o) => setL(l.key, { item_code: o.value, text: o.label })}
                  search={async (s) => (await searchAllItems(company, s)).map((x) => ({ value: x.item_code, label: `${x.item_code} · ${x.name}`, data: x }))} />
                <label className={label}>{t('ps.ct.serialOpt')}<input id={`ct-serial-${i}`} className={`${inputCls} font-mono`} value={l.serial_no} onChange={(e) => setL(l.key, { serial_no: e.target.value })} /></label>
                <div className="flex items-end"><Button variant="ghost" aria-label={t('so.removeLine')} onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} icon={<Trash2 className="h-4 w-4" aria-hidden />} /></div>
              </li>))}</ul>
            <div className="border-t border-line p-4"><Button id="ct-add" onClick={() => setLines((ls) => [...ls, { key: `c${++cseq}`, item_code: '', text: '', serial_no: '' }])} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('ps.ct.addLine')}</Button></div>
          </SectionCard>
        )}
        <div className="flex flex-wrap gap-2">
          <Button variant="primary" id="ct-save" disabled={busy || !canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={save}>{busy ? t('so.saving') : t('ps.ct.saveDraft')}</Button>
          <Link to="/service/contracts" className={secondaryLink}>{t('so.cancelEdit')}</Link>
        </div>
      </div>
    </RequireModule>
  );
}

export function ContractPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const kid = Number(id);
  const qc = useQueryClient();
  const q = useContractInfo(company, kid);
  const K = q.data;
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [dlg, setDlg] = useState<'end' | 'cancel' | null>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['svc-contract', company, kid] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); };
  if (q.isLoading) return <RequireModule module="service"><PageLoading /></RequireModule>;
  if (q.error || !K) return <RequireModule module="service"><PsHeader module="service" title={id} listTo="/service/contracts" listLabel={t('ps.ct.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  const k = K.contract;
  const cov = (['covers_parts', 'covers_labour', 'covers_travel'] as const).filter((x) => k[x]).map((x) => t(`ps.ct.${x}`)).join(', ');
  return (
    <RequireModule module="service">
      <PsHeader module="service" title={`${t('ps.ct.one')} ${k.doc_no}`} listTo="/service/contracts" listLabel={t('ps.ct.title')}
        pills={<><span className={clsx('pill', k.state === 'active' ? 'pill-ok' : k.state === 'cancelled' ? 'pill-crit' : 'pill-neutral')} data-testid="ct-state">{t(`ps.ct.state.${k.state}`)}</span>{k.expired && <span className="pill pill-warning">{t('ps.ct.expired')}</span>}<SourcePill source="erp" /></>}
        sub={`${k.card_code} · ${k.card_name ?? ''} · ${fmtDay(k.starts_on)} – ${fmtDay(k.ends_on)}`}
        actions={K.can_write ? <>
          {k.state === 'draft' && <><Button variant="primary" id="ct-activate" onClick={async () => { setErr(null); try { await contractStatus(company, kid, 'activate', null); setFlash(t('ps.ct.activated', { no: k.doc_no })); refresh(); } catch (e) { setErr(errorMessage(e)); } }}>{t('ps.ct.activate')}</Button>
            <Link id="ct-edit" to={`/service/contracts/${company}/${kid}/edit`} className={secondaryLink}><Pencil className="h-4 w-4" aria-hidden /> {t('ps.edit')}</Link>
            <Button variant="danger" id="ct-cancel" onClick={() => setDlg('cancel')}>{t('inv.cancel')}</Button></>}
          {k.state === 'active' && <Button variant="danger" id="ct-end" onClick={() => setDlg('end')}>{t('ps.ct.end')}</Button>}
        </> : undefined} />
      <Flash text={flash} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <Fields items={[[t('ps.ct.period'), `${fmtDay(k.starts_on)} – ${fmtDay(k.ends_on)}`], [t('ps.ct.response'), k.response_hours == null ? null : t('ps.ct.respH', { n: fmtQty(k.response_hours) })],
              [t('ps.ct.coverage'), cov || '—'], [t('ps.ct.covers'), k.all_items ? t('ps.ct.allItems') : t('ps.ct.nItems', { n: K.lines.length })], [t('ps.ct.terms'), k.terms ? <span dir="auto">{k.terms}</span> : null],
              [t('ps.call.createdBy'), k.created_by_name], ...(k.end_note ? [[t('ps.ct.endNote'), <span dir="auto">{k.end_note}</span>] as [string, React.ReactNode]] : [])]} />
          </SectionCard>
          {!k.all_items && (
            <SectionCard title={t('ps.ct.lines')}><ul className="divide-y divide-line text-sm" data-testid="ct-lines">{K.lines.map((l) => (
              <li key={l.line_num} className="flex flex-wrap justify-between gap-2 px-5 py-3"><span><span className="font-mono">{l.item_code}</span> <span dir="auto" className="text-muted">{l.item_name}</span></span><span className="font-mono">{l.serial_no ?? t('ps.ct.everyUnit')}</span></li>))}</ul></SectionCard>
          )}
          <SectionCard title={t('ps.eq.history')}>
            {K.calls.length === 0 ? <p className="p-5 text-sm text-muted">{t('ps.eq.noCalls')}</p> : <ul className="divide-y divide-line text-sm">{K.calls.map((h) => (
              <li key={h.call_id} className="flex flex-wrap items-center justify-between gap-2 px-5 py-3"><Link className="font-mono text-primary hover:underline" to={`/service/calls/${company}/${h.call_id}`}>{h.doc_no}</Link><span dir="auto">{h.subject}</span><CallStatusPill status={h.status} /></li>))}</ul>}
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5"><ActivityList items={K.activity} prefix="service_contract_" /></aside>
      </div>
      <NoteDialog id="ct-note" open={dlg !== null} required title={t(dlg === 'end' ? 'ps.ct.endTitle' : 'ps.ct.cancelTitle', { no: k.doc_no })} labelText={t('ps.ct.why')} confirm={t(dlg === 'end' ? 'ps.ct.end' : 'inv.cancel')}
        onClose={() => setDlg(null)} onConfirm={async (n) => { await contractStatus(company, kid, dlg!, n); setFlash(t(dlg === 'end' ? 'ps.ct.ended' : 'ps.ct.cancelled', { no: k.doc_no })); refresh(); }} />
    </RequireModule>
  );
}

// ---------- Service setup ----------
export function ServiceSetupPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const company = useDefaultCompany();
  const setup = useSvcSetup(company || null);
  const S = setup.data;
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [rTarget, setRTarget] = useState<'group' | 'item'>('group');
  const [rGroup, setRGroup] = useState(''); const [rItem, setRItem] = useState(''); const [rItemText, setRItemText] = useState(''); const [rMonths, setRMonths] = useState('');
  useEffect(() => { if (S) setReason(S.setting.parts_reason_code ?? ''); }, [S]);
  const refresh = () => qc.invalidateQueries({ queryKey: ['svc-setup'] });
  async function run(f: () => Promise<unknown>, msg: string) { setErr(null); try { await f(); setFlash(msg); refresh(); } catch (e) { setErr(errorMessage(e)); } }
  if (setup.isLoading) return <RequireModule module="service"><PageLoading /></RequireModule>;
  const can = Boolean(S?.can_write);
  return (
    <PsListFrame module="service" title={t('ps.ssetup.title')} desc={t('ps.ssetup.desc')}>
      <Flash text={flash} />
      <FormError message={err} />
      {setup.error && <div className="card mb-5"><ErrorState error={setup.error} onRetry={() => setup.refetch()} /></div>}
      <div className="grid gap-5 lg:grid-cols-2">
        <SectionCard title={t('ps.ssetup.parts')}>
          <div className="space-y-3 p-5">
            <label className={label}>{t('ps.ssetup.reason')}<select id="ss-reason" disabled={!can} className={inputCls} value={reason} onChange={(e) => setReason(e.target.value)}><option value="">{t('ps.notSet')}</option>{(S?.reasons ?? []).map((r) => <option key={r.code} value={r.code}>{r.name}{r.acct_code ? ` · ${r.acct_code}` : ''}</option>)}</select></label>
            <p className="text-[13px] text-muted">{t('ps.ssetup.reasonHelp')}</p>
            <Button variant="primary" id="ss-save" disabled={!can} disabledReason={!can ? t('erp.readOnly', { module: 'Service' }) : undefined} onClick={() => run(() => svcSettingSet(company, { parts_reason_code: reason }), t('ps.setupSaved'))}>{t('ps.save')}</Button>
            <p className="text-sm">{t('ps.ssetup.numbering')}: <span className="font-mono">{S?.numbering.call ?? t('ps.notSet')}</span> · <span className="font-mono">{S?.numbering.contract ?? t('ps.notSet')}</span></p>
          </div>
        </SectionCard>
        <SectionCard title={t('ps.ssetup.warranty')}>
          <ul className="divide-y divide-line text-sm" data-testid="ss-rules">{(S?.warranty_rules ?? []).map((r) => (
            <li key={r.rule_id} className="flex flex-wrap items-center justify-between gap-2 px-5 py-3">
              <span>{r.group_code != null ? t('ps.ssetup.group', { name: r.name ?? r.group_code }) : <><span className="font-mono">{r.item_code}</span> <span className="text-muted">{r.name}</span></>}</span>
              <span className="num font-medium">{t('ps.w.months', { n: r.months })}</span>
              {can && <Button variant="ghost" aria-label={t('ps.delete')} onClick={() => run(() => warrantyRuleSave(company, { rule_id: r.rule_id, delete: true }), t('ps.setupSaved'))} icon={<Trash2 className="h-4 w-4" aria-hidden />} />}
            </li>))}
            {(S?.warranty_rules ?? []).length === 0 && <li className="px-5 py-4 text-muted">{t('ps.ssetup.noRules')}</li>}
          </ul>
          {can && (
            <div className="grid grid-cols-1 gap-3 border-t border-line p-5 sm:grid-cols-2">
              <label className={label}>{t('ps.ssetup.for')}<select id="ss-target" className={inputCls} value={rTarget} onChange={(e) => setRTarget(e.target.value as 'group' | 'item')}><option value="group">{t('ps.ssetup.itemGroup')}</option><option value="item">{t('ps.call.item')}</option></select></label>
              {rTarget === 'group'
                ? <label className={label}>{t('ps.ssetup.itemGroup')}<select id="ss-group" className={inputCls} value={rGroup} onChange={(e) => setRGroup(e.target.value)}><option value="">{t('inv.choose')}</option>{(S?.item_groups ?? []).map((g) => <option key={g.code} value={g.code}>{g.name}</option>)}</select></label>
                : <Combobox id="ss-item" label={t('ps.call.item')} text={rItemText} onText={(s) => { setRItemText(s); setRItem(''); }} onSelect={(o) => { setRItem(o.value); setRItemText(o.label); }}
                    search={async (s) => (await searchAllItems(company, s)).map((x) => ({ value: x.item_code, label: `${x.item_code} · ${x.name}`, data: x }))} />}
              <label className={label}>{t('ps.ssetup.months')}<input id="ss-months" inputMode="numeric" className={`${inputCls} num`} value={rMonths} onChange={(e) => setRMonths(e.target.value)} /></label>
              <div className="flex items-end"><Button id="ss-add" icon={<CircleCheck className="h-4 w-4" aria-hidden />}
                onClick={() => run(() => warrantyRuleSave(company, rTarget === 'group' ? { group_code: rGroup, months: rMonths } : { item_code: rItem, months: rMonths }), t('ps.setupSaved'))}>{t('ps.ssetup.add')}</Button></div>
            </div>
          )}
        </SectionCard>
      </div>
    </PsListFrame>
  );
}
