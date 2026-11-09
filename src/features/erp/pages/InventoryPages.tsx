import { Fragment, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, Check, CircleCheck, CircleX, Plus, ScanLine, Trash2, X } from 'lucide-react';
import { erp } from '@/lib/supabase';
import { ApiError, errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, SectionCard, StatusTag, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { DOC_KINDS, moduleByKey, type DocKind } from '../modules';
import { FormError, Flash, fmtWhen, useDefaultCompany, useFlash } from './BankingPages';
import { SourcePill, StatePill, today } from './SalesOrderPages';
import {
  INV_OBJ, binSave, countCancel, countCreate, countDecide, countSave, countSubmit, invCancel, invChecks, invCreate, invDecide, invSettingSet, lotsText,
  parseLots, reasonSave, searchStockItems, trChecks, trCreate, trRequestCancel, trRequestCreate, trSource, useCountInfo, useInvInfo, useInvSetup,
  useLotHistory, whsInvSet,
  type CountState, type InvApproval, type InvEval, type InvKind, type StockDocKind, type StockItemHit, type TransferKind,
} from '../inventory';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const linkBtn = 'inline-flex min-h-[44px] items-center gap-2 rounded-btn px-4 text-[15px] font-medium';
const primaryLink = `${linkBtn} bg-primary text-white hover:bg-primary-hover`;
const secondaryLink = `${linkBtn} border border-line bg-surface text-ink hover:bg-page`;
const label = 'block text-xs font-medium text-muted';
const inputCls = 'input mt-1 text-[15px] text-ink';
const invPath = (obj: number, company: string, entry: number) => {
  const k = (Object.keys(INV_OBJ) as InvKind[]).find((x) => INV_OBJ[x] === obj);
  return k ? `/docs/${k}/${company}/${entry}` : undefined;
};

// ---------- Shared pieces ----------
/** Header for inventory screens: back link, breadcrumb (Home › 07 Inventory › list › record), title with pills, one line, actions. */
export function InvHeader({ title, pills, sub, actions, listTo, listLabel }: { title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode; listTo: string; listLabel: string }) {
  const { t } = useTranslation();
  const m = moduleByKey('inventory')!;
  return (
    <header className="mb-4">
      <Link to={listTo} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('inv.back')}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/inventory'], [listLabel, listTo], [title, undefined]]} />
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

function CheckNote({ message }: { message: string }) {
  const { t } = useTranslation();
  return (
    <p className="mt-1 flex items-start gap-1.5 text-[13px] text-warn-fg">
      <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden /><span dir="auto"><b>{t('so.check')}</b> {message}</span>
    </p>
  );
}
function LineError({ message }: { message?: string }) {
  if (!message) return null;
  return <p role="alert" dir="auto" className="mt-1 text-[13px] text-crit-fg" data-testid="inv-line-error">{message}</p>;
}

function ActivityCard({ items }: { items: Array<{ at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }> }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('so.activity.title')}>
      {items.length === 0 ? <p className="p-5 text-sm text-muted">{t('so.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid="inv-activity">
          {items.map((a, i) => {
            const det = (a.detail ?? {}) as R;
            const base = a.action.replace(/^(goods_receipt|goods_issue|inventory_transfer|transfer_request|inventory_count)_/, '');
            const verb = a.action === 'inventory_count_create' ? 'count_create' : base;
            return (
              <li key={i} className="flex gap-3">
                <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', /approve/.test(a.action) || det.result === 'posted' ? 'bg-ok-fg' : /reject|cancel/.test(a.action) ? 'bg-crit-fg' : 'bg-primary')} aria-hidden />
                <div className="min-w-0 text-sm">
                  <p><span className="font-medium">{a.actor_name}</span> {t(`inv.activity.${verb}${verb === 'create' || verb === 'submit' ? `_${det.result ?? 'posted'}` : ''}`, { defaultValue: a.action.replace(/_/g, ' '), ...det })}</p>
                  {(det.reason || det.note) && <p dir="auto" className="text-ink-2">“{String(det.reason ?? det.note)}”</p>}
                  <p className="num text-xs text-muted">{fmtWhen(a.at)}</p>
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </SectionCard>
  );
}

/** Approval card (spec §4.4 aside): approve / reject for the approver, the outcome afterwards, or who it waits for. */
function ApprovalCard({ approvals, state, canDecide, isSubmitter, submittedBy, submittedAt, reason, docNo, noun, onDecide }: {
  approvals: InvApproval[]; state: string | null; canDecide: boolean; isSubmitter: boolean; submittedBy: string | null; submittedAt: string | null;
  reason: string | null; docNo: string; noun: string; onDecide: (d: 'approved' | 'rejected', note: string | null) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [busy, setBusy] = useState(false);
  const [rejOpen, setRejOpen] = useState(false);
  const [note, setNote] = useState('');
  const [noteErr, setNoteErr] = useState<string | null>(null);
  const current = approvals.filter((a) => a.current);
  const myLast = [...approvals].reverse().find((a) => a.decided_by_me && a.decision);
  const msgs = (a: InvApproval) => (a.detail?.checks ?? []).map((c) => c.message);
  async function decide(d: 'approved' | 'rejected') {
    if (d === 'rejected' && !note.trim()) { setNoteErr(t('inv.rejectNoteNeeded')); return; }
    setBusy(true);
    try { await onDecide(d, d === 'rejected' ? note.trim() : null); setRejOpen(false); } finally { setBusy(false); }
  }
  if (!approvals.length) return null;
  if (state === 'pending_approval' && canDecide) {
    return (
      <section className="card border-warn-fg/40 p-5" data-testid="inv-approval-card">
        <div className="space-y-3">
          <p className="text-[15px] font-semibold">{t('so.approval.needed')}</p>
          {current.map((a) => msgs(a).map((m, k) => <p key={`${a.approval_id}-${k}`} dir="auto" className="text-sm text-ink-2">{m}</p>))}
          <p className="text-sm text-muted">{t('so.approval.requested', { name: submittedBy ?? '—', when: fmtWhen(submittedAt) })}</p>
          {reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 text-[15px] italic text-ink-2">“{reason}”</blockquote>}
          <div className="flex flex-col gap-2 pt-1">
            <Button variant="success" id="inv-approve" className="w-full" disabled={busy} onClick={() => decide('approved')} icon={<Check className="h-4 w-4" aria-hidden />}>{t('inv.approvePost')}</Button>
            <Button variant="danger" id="inv-reject" className="w-full" disabled={busy} onClick={() => { setRejOpen(true); setNoteErr(null); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('so.approval.reject')}</Button>
          </div>
        </div>
        <Dialog open={rejOpen} title={t('inv.rejectTitle', { noun, no: docNo })} onClose={() => setRejOpen(false)}
          footer={<>
            <Button variant="secondary" onClick={() => setRejOpen(false)}>{t('so.keep')}</Button>
            <Button variant="danger" id="inv-reject-confirm" disabled={busy} onClick={() => decide('rejected')}>{t('so.approval.reject')}</Button>
          </>}>
          <label className={label}>{t('so.approval.rejectNote')} <span className="text-crit-fg">*</span>
            <textarea id="inv-reject-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => { setNote(e.target.value); setNoteErr(null); }} />
          </label>
          {noteErr && <p role="alert" className="text-sm text-crit-fg">{noteErr}</p>}
        </Dialog>
      </section>
    );
  }
  if (myLast && state !== 'pending_approval') {
    const ok = myLast.decision === 'approved';
    return (
      <section data-testid="inv-decided-card" className={clsx('card p-5', ok ? 'border-ok-fg/40 bg-ok-bg text-ok-fg' : 'border-crit-fg/40 bg-crit-bg text-crit-fg')}>
        <p className="flex items-center gap-2 font-semibold">{ok ? <CircleCheck className="h-5 w-5" aria-hidden /> : <CircleX className="h-5 w-5" aria-hidden />}
          {t(ok ? 'inv.approvedByYou' : 'so.approval.rejectedByYou', { when: fmtWhen(myLast.decided_at) })}</p>
        {myLast.note && <p dir="auto" className="mt-2 text-sm">“{myLast.note}”</p>}
      </section>
    );
  }
  const lastRej = [...approvals].reverse().find((a) => a.decision === 'rejected');
  const lastOk = [...approvals].reverse().find((a) => a.decision === 'approved');
  return (
    <SectionCard title={t('so.approval.status')}>
      <div className="space-y-2 p-5 text-sm" data-testid="inv-status-card">
        {state === 'pending_approval' && (
          <>
            <p className="font-semibold text-warn-fg">{t('so.approval.waitingFor', { names: [...new Set(current.map((a) => a.approver_position_name))].join(', ') })}</p>
            {current.map((a) => msgs(a).map((m, k) => <p key={`${a.approval_id}-${k}`} dir="auto" className="text-ink-2">{m}</p>))}
            {reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{reason}”</blockquote>}
            {isSubmitter && <p className="text-muted">{t('inv.youCantApprove')}</p>}
          </>
        )}
        {lastOk && state !== 'pending_approval' && state !== 'rejected' && (
          <p className="flex items-center gap-2 font-semibold text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{t('so.approval.approvedBy', { name: lastOk.decided_by_name ?? '—', when: fmtWhen(lastOk.decided_at) })}</p>
        )}
        {lastRej && state !== 'pending_approval' && (
          <>
            <p className="flex items-center gap-2 font-semibold text-crit-fg"><CircleX className="h-4 w-4" aria-hidden />{t('so.approval.rejectedBy', { name: lastRej.decided_by_name ?? '—', when: fmtWhen(lastRej.decided_at) })}</p>
            {lastRej.note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{lastRej.note}”</blockquote>}
          </>
        )}
      </div>
    </SectionCard>
  );
}

/** Cancel with a note (destructive: confirmation dialog). */
function CancelButton({ id, title, onCancel }: { id: string; title: string; onCancel: (note: string) => Promise<void> }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    if (!note.trim()) { setErr(t('inv.cancelNoteNeeded')); return; }
    setBusy(true);
    try { await onCancel(note.trim()); setOpen(false); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <>
      <Button variant="danger" id={id} onClick={() => { setOpen(true); setErr(null); }}>{t('inv.cancel')}</Button>
      <Dialog open={open} title={title} onClose={() => setOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('so.keep')}</Button><Button variant="danger" id={`${id}-confirm`} disabled={busy} onClick={go}>{t('inv.cancel')}</Button></>}>
        <label className={label}>{t('inv.cancelNote')} <span className="text-crit-fg">*</span>
          <textarea id={`${id}-note`} rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => { setNote(e.target.value); setErr(null); }} />
        </label>
        {err && <p role="alert" dir="auto" className="text-sm text-crit-fg">{err}</p>}
      </Dialog>
    </>
  );
}

const itemOptions = (company: string) => async (q: string): Promise<Array<ComboOption<StockItemHit>>> =>
  (await searchStockItems(company, q)).map((i) => ({ value: i.item_code, label: `${i.item_code} · ${i.name}`, data: i,
    meta: <span className="text-xs text-muted">{[i.barcode, i.serial_managed ? 'S/N' : i.batch_managed ? 'Batch' : null].filter(Boolean).join(' · ')}</span> }));

/** The "+ New …" action on the inventory document lists. */
export function NewInventoryAction({ kind }: { kind: DocKind }) {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('inventory');
  const to = ({ goods_receipt: '/inventory/goods-receipt/new', goods_issue: '/inventory/goods-issue/new', transfer_request: '/inventory/transfer-request/new',
    inventory_transfer: '/inventory/transfer/new' } as Record<string, string>)[kind];
  if (!to) return null;
  const text = t(`inv.new.${kind}`);
  if (!canWrite) return <Button variant="primary" disabled id="inv-new" disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {text}</Button>;
  return <Link to={to} id="inv-new" className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {text}</Link>;
}

// ---------- Goods receipt / goods issue form ----------
interface GLine { key: string; item_code: string; text: string; qty: string; price: string; bin_code: string; lots: string; serial: boolean; batch: boolean }
let seq = 0;
const newGLine = (): GLine => ({ key: `g${++seq}`, item_code: '', text: '', qty: '1', price: '', bin_code: '', lots: '', serial: false, batch: false });

export function StockDocNewPage({ kind }: { kind: StockDocKind }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const company = useDefaultCompany();
  const obj = INV_OBJ[kind];
  const receipt = kind === 'goods_receipt';
  const { canWrite, readOnlyReason } = useModuleLevel('inventory');
  const setup = useInvSetup(company || null);
  const S = setup.data;
  const [date, setDate] = useState(today());
  const [whs, setWhs] = useState('WH01');
  const [reasonCode, setReasonCode] = useState('');
  const [acct, setAcct] = useState('');
  const [ref, setRef] = useState('');
  const [comments, setComments] = useState('');
  const [lines, setLines] = useState<GLine[]>([newGLine()]);
  const [why, setWhy] = useState('');
  const [ev, setEv] = useState<InvEval | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const reasons = (S?.reasons ?? []).filter((r) => r.active && (r.direction === 'both' || r.direction === (receipt ? 'in' : 'out')));
  const wh = S?.warehouses.find((w) => w.code === whs);
  const bins = (S?.bins ?? []).filter((b) => b.whs_code === whs && b.active);
  const header = { doc_date: date, whs_code: whs, reason_code: reasonCode, acct_code: acct || null, customer_ref: ref, comments };
  const payload = lines.filter((l) => l.item_code).map((l) => ({ item_code: l.item_code, qty: l.qty, price: receipt ? l.price : null, bin_code: l.bin_code || null,
    lots: l.serial || l.batch ? parseLots(l.lots, l.batch) : [] }));
  const sig = JSON.stringify([header, payload]);
  useEffect(() => {
    if (!company || !payload.length) { setEv(null); return; }
    const h = setTimeout(() => { invChecks(company, obj, header, payload).then(setEv).catch(() => undefined); }, 350);
    return () => clearTimeout(h);
  }, [sig, company]); // eslint-disable-line react-hooks/exhaustive-deps
  const errs = ev?.errors ?? [];
  const lineErr = (i: number) => errs.filter((e) => e.line === i).map((e) => e.message).join(' ');
  const checks = ev?.checks ?? [];
  const set = (k: string, f: Partial<GLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...f } : l)));
  async function submit() {
    setErr(null);
    if (checks.length && !why.trim()) { setErr(t('inv.reasonNeeded')); return; }
    setBusy(true);
    try {
      const res = await invCreate(company, obj, header, payload, checks.length ? why.trim() : null);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      nav(`/docs/${kind}/${company}/${res.doc_entry}`, { state: { flash: t(res.state === 'approved' ? 'inv.flash.posted' : 'inv.flash.waiting', { no: res.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (setup.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  const title = t(`inv.new.${kind}`);
  return (
    <RequireModule module="inventory">
      <InvHeader title={title} pills={<SourcePill source="erp" />} sub={t(`inv.sub.${kind}`)} listTo={`/docs/${kind}`} listLabel={t(`erp.doc.${kind}`)} />
      <FormError message={err} />
      {setup.error && <div className="card mb-5"><ErrorState error={setup.error} onRetry={() => setup.refetch()} /></div>}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              <label className={label}>{t('erp.col.postingDate')} <span className="text-crit-fg">*</span><input id="inv-date" type="date" className={`${inputCls} num`} value={date} onChange={(e) => setDate(e.target.value)} /></label>
              <label className={label}>{t('erp.col.warehouse')} <span className="text-crit-fg">*</span>
                <select id="inv-whs" className={inputCls} value={whs} onChange={(e) => { setWhs(e.target.value); setLines((ls) => ls.map((l) => ({ ...l, bin_code: '' }))); }}>
                  {(S?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}{w.bins ? ` · ${t('inv.usesBins')}` : ''}</option>)}
                </select>
              </label>
              <label className={label}>{t('inv.reason')} <span className="text-crit-fg">*</span>
                <select id="inv-reason" className={inputCls} value={reasonCode} onChange={(e) => { setReasonCode(e.target.value); setAcct(''); }}>
                  <option value="">{t('inv.choose')}</option>
                  {reasons.map((r) => <option key={r.code} value={r.code}>{r.name}</option>)}
                </select>
                {!reasons.length && <span className="mt-1 block text-xs text-warn-fg">{t('inv.noReasons')}</span>}
              </label>
              <label className={label}>{t('inv.account')}
                <select id="inv-acct" className={inputCls} value={acct} onChange={(e) => setAcct(e.target.value)}>
                  <option value="">{(() => { const r = reasons.find((x) => x.code === reasonCode); return r?.acct_code ? t('inv.reasonAccount', { code: r.acct_code, name: r.acct_name ?? '' }) : t('inv.choose'); })()}</option>
                  {(S?.accounts ?? []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}
                </select>
              </label>
              <label className={label}>{t('inv.reference')}<input id="inv-ref" className={inputCls} value={ref} onChange={(e) => setRef(e.target.value)} /></label>
              <label className={label}>{t('erp.col.remarks')}<input id="inv-comments" dir="auto" className={inputCls} value={comments} onChange={(e) => setComments(e.target.value)} /></label>
            </div>
            {errs.filter((e) => e.line === null && payload.length).map((e, i) => <p key={i} role="alert" dir="auto" className="px-5 pb-3 text-[13px] text-crit-fg" data-testid="inv-header-error">{e.message}</p>)}
          </SectionCard>
          <SectionCard title={t('inv.lines')}>
            <ul className="divide-y divide-line">
              {lines.map((l, i) => {
                const idx = lines.filter((y) => y.item_code).indexOf(l);
                const evl = idx >= 0 ? ev?.lines.find((x) => x.line_num === idx) : undefined;
                const e = idx >= 0 ? lineErr(idx) : '';
                return (
                  <li key={l.key} className={clsx('space-y-3 p-5', e && 'bg-crit-bg/40')} data-testid="inv-line">
                    <div className="grid grid-cols-1 gap-3 sm:grid-cols-[minmax(0,1fr)_110px_130px_auto]">
                      <Combobox<StockItemHit> id={`inv-item-${i}`} label={t('inv.itemN', { n: i + 1 })} text={l.text} onText={(s) => set(l.key, { text: s, item_code: '' })}
                        onSelect={(o) => set(l.key, { text: o.label, item_code: o.value, serial: o.data.serial_managed, batch: o.data.batch_managed })}
                        search={itemOptions(company)} placeholder={t('inv.itemPh')} noMatch={t('inv.noItem')} />
                      <label className={label}>{t('erp.col.qty')}<input id={`inv-qty-${i}`} inputMode="decimal" className={`${inputCls} num text-end`} value={l.qty} onChange={(ev2) => set(l.key, { qty: ev2.target.value })} /></label>
                      {receipt ? (
                        <label className={label}>{t('inv.unitCost')}<input id={`inv-price-${i}`} inputMode="decimal" className={`${inputCls} num text-end`} placeholder={evl ? String(evl.price) : ''} value={l.price} onChange={(ev2) => set(l.key, { price: ev2.target.value })} /></label>
                      ) : (
                        <div className={label}>{t('inv.unitCost')}<p className="num mt-3 text-end text-[15px] text-ink">{evl ? fmtMoney(evl.price) : '—'}</p></div>
                      )}
                      <div className="flex items-end"><Button variant="ghost" aria-label={t('inv.removeLine', { n: i + 1 })} onClick={() => setLines((ls) => (ls.length > 1 ? ls.filter((x) => x.key !== l.key) : [newGLine()]))}><Trash2 className="h-4 w-4" aria-hidden /></Button></div>
                    </div>
                    {(wh?.bins || l.serial || l.batch) && (
                      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                        {wh?.bins && (
                          <label className={label}>{receipt ? t('inv.putAwayBin') : t('inv.pickBin')}
                            <select id={`inv-bin-${i}`} className={inputCls} value={l.bin_code} onChange={(ev2) => set(l.key, { bin_code: ev2.target.value })}>
                              <option value="">{receipt ? t('inv.choose') : t('inv.outsideBins')}</option>
                              {bins.map((b) => <option key={b.code} value={b.code}>{b.code}{b.name ? ` · ${b.name}` : ''}</option>)}
                            </select>
                          </label>
                        )}
                        {(l.serial || l.batch) && (
                          <label className={label}>{l.serial ? t('inv.serials') : t('inv.batches')} <span className="text-crit-fg">*</span>
                            <textarea id={`inv-lots-${i}`} rows={2} className="input mt-1 py-2 font-mono text-[14px] text-ink" placeholder={l.serial ? t('inv.serialsPh') : t('inv.batchesPh')}
                              value={l.lots} onChange={(ev2) => set(l.key, { lots: ev2.target.value })} />
                          </label>
                        )}
                      </div>
                    )}
                    {evl && <p className="num text-[13px] text-muted">{t('inv.inStock', { n: fmtQty(evl.on_hand), whs })} · {t('inv.lineValue', { v: fmtMoney(evl.line_total) })}</p>}
                    <LineError message={e} />
                  </li>
                );
              })}
            </ul>
            <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line p-5">
              <Button id="inv-add-line" onClick={() => setLines((ls) => [...ls, newGLine()])} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('inv.addLine')}</Button>
              <p className="num text-[17px] font-semibold" data-testid="inv-total">{t('inv.totalValue', { v: fmtMoney(ev?.totals.value ?? 0, ev?.totals.currency ?? S?.currency) })}</p>
            </div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={receipt ? t('inv.postReceipt') : t('inv.postIssue')}>
            <div className="space-y-3 p-5" data-testid="inv-preview">
              {!payload.length ? <p className="text-sm text-muted">{t('inv.previewEmpty')}</p>
                : errs.length ? <p className="text-sm text-crit-fg">{t('inv.problems', { count: errs.length })}</p>
                : checks.length ? (
                  <>
                    <p className="font-semibold text-warn-fg">{t('inv.needsApproval')}</p>
                    {checks.map((c, i) => <CheckNote key={i} message={c.message} />)}
                    <label className={label}>{t('inv.reasonForApprover')} <span className="text-crit-fg">*</span>
                      <textarea id="inv-why" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={why} onChange={(e) => setWhy(e.target.value)} />
                    </label>
                  </>
                ) : <p className="font-semibold text-ok-fg">{t('inv.postsNow')}</p>}
              <Button variant="primary" id="inv-submit" className="w-full" onClick={submit} disabled={busy || !canWrite || !payload.length}
                disabledReason={!canWrite ? readOnlyReason : undefined}>
                {busy ? t('so.saving') : checks.length ? t('inv.submitForApproval') : receipt ? t('inv.postReceipt') : t('inv.postIssue')}
              </Button>
              <Link to={`/docs/${kind}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
              {S?.my_limits?.[String(obj)] != null && <p className="text-xs text-muted">{t('inv.myLimit', { v: fmtMoney(S.my_limits[String(obj)], S.currency) })}</p>}
            </div>
          </SectionCard>
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Transfer request / transfer form ----------
interface TLine extends GLine { from_bin: string; to_bin: string; base_doc_entry?: number; base_line?: number; baseNo?: string; from_whs?: string; to_whs?: string }
const newTLine = (): TLine => ({ ...newGLine(), from_bin: '', to_bin: '' });

export function TransferNewPage({ kind }: { kind: TransferKind }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const defCompany = useDefaultCompany();
  const company = params.get('company') ?? defCompany;
  const reqEntry = Number(params.get('request')) || null;
  const isReq = kind === 'transfer_request';
  const obj = INV_OBJ[kind];
  const { canWrite, readOnlyReason } = useModuleLevel('inventory');
  const setup = useInvSetup(company || null);
  const S = setup.data;
  const src = useQuery({ queryKey: ['inv-tr-src', company, reqEntry], enabled: Boolean(company && reqEntry && !isReq), queryFn: () => trSource(company, reqEntry!) });
  const [date, setDate] = useState(today());
  const [due, setDue] = useState('');
  const [from, setFrom] = useState('WH01');
  const [to, setTo] = useState('WH02');
  const [ref, setRef] = useState('');
  const [comments, setComments] = useState('');
  const [lines, setLines] = useState<TLine[]>([newTLine()]);
  const [ev, setEv] = useState<InvEval | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const s = src.data;
    if (!s?.header) return;
    if (s.header.from_whs) setFrom(s.header.from_whs);
    if (s.header.to_whs) setTo(s.header.to_whs);
    setLines(s.lines.map((l) => ({ ...newTLine(), item_code: l.item_code, text: `${l.item_code} · ${l.description ?? ''}`, qty: String(Number(l.open_qty)), serial: l.serial, batch: l.batch,
      base_doc_entry: l.base_doc_entry, base_line: l.base_line, baseNo: s.header!.doc_no, from_whs: l.from_whs, to_whs: l.to_whs })));
  }, [src.data]);
  const binsOf = (w: string) => (S?.bins ?? []).filter((b) => b.whs_code === w && b.active);
  const usesBins = (w: string) => Boolean(S?.warehouses.find((x) => x.code === w)?.bins);
  const header = { doc_date: date, due_date: isReq ? due || null : null, from_whs: from, to_whs: to, customer_ref: ref, comments };
  const filled = lines.filter((l) => l.item_code);
  const payload = filled.map((l) => ({ item_code: l.item_code, qty: l.qty, from_bin: l.from_bin || null, to_bin: l.to_bin || null,
    lots: l.serial || l.batch ? parseLots(l.lots, l.batch) : [],
    ...(l.base_doc_entry != null ? { base_doc_entry: l.base_doc_entry, base_line: l.base_line } : {}) }));
  const sig = JSON.stringify([header, payload]);
  useEffect(() => {
    if (!company || !payload.length) { setEv(null); return; }
    const h = setTimeout(() => { trChecks(company, obj, header, payload).then(setEv).catch(() => undefined); }, 350);
    return () => clearTimeout(h);
  }, [sig, company]); // eslint-disable-line react-hooks/exhaustive-deps
  const errs = ev?.errors ?? [];
  const set = (k: string, f: Partial<TLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...f } : l)));
  async function submit() {
    setErr(null);
    setBusy(true);
    try {
      const res = isReq ? await trRequestCreate(company, header, payload) : await trCreate(company, header, payload);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      nav(`/docs/${kind}/${company}/${res.doc_entry}`, { state: { flash: t(isReq ? 'inv.flash.request' : 'inv.flash.transfer', { no: res.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  if (setup.isLoading || src.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  const fromReq = Boolean(src.data?.header);
  return (
    <RequireModule module="inventory">
      <InvHeader title={t(`inv.new.${kind}`)} pills={<SourcePill source="erp" />} listTo={`/docs/${kind}`} listLabel={t(`erp.doc.${kind}`)}
        sub={fromReq ? t('inv.fromRequest', { no: src.data!.header!.doc_no }) : t(`inv.sub.${kind}`)} />
      <FormError message={err ?? (src.error ? errorMessage(src.error) : null)} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              <label className={label}>{t('erp.col.postingDate')} <span className="text-crit-fg">*</span><input id="tr-date" type="date" className={`${inputCls} num`} value={date} onChange={(e) => setDate(e.target.value)} /></label>
              {isReq && <label className={label}>{t('inv.neededBy')}<input id="tr-due" type="date" className={`${inputCls} num`} value={due} onChange={(e) => setDue(e.target.value)} /></label>}
              <label className={label}>{t('inv.fromWhs')} <span className="text-crit-fg">*</span>
                <select id="tr-from" className={inputCls} value={from} disabled={fromReq} onChange={(e) => setFrom(e.target.value)}>
                  {(S?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}
                </select>
              </label>
              <label className={label}>{t('inv.toWhs')} <span className="text-crit-fg">*</span>
                <select id="tr-to" className={inputCls} value={to} disabled={fromReq} onChange={(e) => setTo(e.target.value)}>
                  {(S?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}{w.bins ? ` · ${t('inv.usesBins')}` : ''}</option>)}
                </select>
              </label>
              <label className={label}>{t('inv.reference')}<input id="tr-ref" className={inputCls} value={ref} onChange={(e) => setRef(e.target.value)} /></label>
              <label className={label}>{t('erp.col.remarks')}<input id="tr-comments" dir="auto" className={inputCls} value={comments} onChange={(e) => setComments(e.target.value)} /></label>
            </div>
          </SectionCard>
          <SectionCard title={t('inv.lines')}>
            <ul className="divide-y divide-line">
              {lines.map((l, i) => {
                const idx = filled.indexOf(l);
                const evl = idx >= 0 ? ev?.lines.find((x) => x.line_num === idx) : undefined;
                const e = idx >= 0 ? errs.filter((x) => x.line === idx).map((x) => x.message).join(' ') : '';
                const lf = l.from_whs ?? from;
                const lt = l.to_whs ?? to;
                return (
                  <li key={l.key} className={clsx('space-y-3 p-5', e && 'bg-crit-bg/40')} data-testid="tr-line">
                    <div className="grid grid-cols-1 gap-3 sm:grid-cols-[minmax(0,1fr)_110px_auto]">
                      {l.base_doc_entry != null ? (
                        <div className={label}>{t('inv.itemN', { n: i + 1 })}<p className="mt-2 text-[15px] text-ink"><b>{l.text}</b><span className="block text-xs text-muted">{t('inv.fromRequest', { no: l.baseNo })} · {lf} → {lt}</span></p></div>
                      ) : (
                        <Combobox<StockItemHit> id={`tr-item-${i}`} label={t('inv.itemN', { n: i + 1 })} text={l.text} onText={(s) => set(l.key, { text: s, item_code: '' })}
                          onSelect={(o) => set(l.key, { text: o.label, item_code: o.value, serial: o.data.serial_managed, batch: o.data.batch_managed })}
                          search={itemOptions(company)} placeholder={t('inv.itemPh')} noMatch={t('inv.noItem')} />
                      )}
                      <label className={label}>{t('erp.col.qty')}<input id={`tr-qty-${i}`} inputMode="decimal" className={`${inputCls} num text-end`} value={l.qty} onChange={(x) => set(l.key, { qty: x.target.value })} /></label>
                      <div className="flex items-end"><Button variant="ghost" aria-label={t('inv.removeLine', { n: i + 1 })} onClick={() => setLines((ls) => (ls.length > 1 ? ls.filter((x) => x.key !== l.key) : [newTLine()]))}><Trash2 className="h-4 w-4" aria-hidden /></Button></div>
                    </div>
                    {!isReq && (usesBins(lf) || usesBins(lt) || l.serial || l.batch) && (
                      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                        {usesBins(lf) && (
                          <label className={label}>{t('inv.fromBin')}
                            <select id={`tr-from-bin-${i}`} className={inputCls} value={l.from_bin} onChange={(x) => set(l.key, { from_bin: x.target.value })}>
                              <option value="">{t('inv.outsideBins')}</option>
                              {binsOf(lf).map((b) => <option key={b.code} value={b.code}>{b.code}</option>)}
                            </select>
                          </label>
                        )}
                        {usesBins(lt) && (
                          <label className={label}>{t('inv.toBin')} <span className="text-crit-fg">*</span>
                            <select id={`tr-to-bin-${i}`} className={inputCls} value={l.to_bin} onChange={(x) => set(l.key, { to_bin: x.target.value })}>
                              <option value="">{t('inv.choose')}</option>
                              {binsOf(lt).map((b) => <option key={b.code} value={b.code}>{b.code}</option>)}
                            </select>
                          </label>
                        )}
                        {(l.serial || l.batch) && (
                          <label className={label}>{l.serial ? t('inv.serials') : t('inv.batches')} <span className="text-crit-fg">*</span>
                            <textarea id={`tr-lots-${i}`} rows={2} className="input mt-1 py-2 font-mono text-[14px] text-ink" placeholder={l.serial ? t('inv.serialsPh') : t('inv.batchesPh')}
                              value={l.lots} onChange={(x) => set(l.key, { lots: x.target.value })} />
                          </label>
                        )}
                      </div>
                    )}
                    {evl && <p className="num text-[13px] text-muted">{t('inv.inStock', { n: fmtQty(evl.on_hand), whs: lf })}</p>}
                    <LineError message={e} />
                  </li>
                );
              })}
            </ul>
            {!fromReq && (
              <div className="border-t border-line p-5">
                <Button id="tr-add-line" onClick={() => setLines((ls) => [...ls, newTLine()])} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('inv.addLine')}</Button>
              </div>
            )}
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={isReq ? t('inv.new.transfer_request') : t('inv.new.inventory_transfer')}>
            <div className="space-y-3 p-5" data-testid="tr-preview">
              <p className="text-sm text-muted">{isReq ? t('inv.requestWhat') : t('inv.transferWhat')}</p>
              {errs.length > 0 && <p className="text-sm text-crit-fg">{t('inv.problems', { count: errs.length })}</p>}
              {!isReq && ev && !errs.length && <p className="num text-sm text-ink-2">{t('inv.transferTotals', { q: fmtQty(ev.totals.qty), v: fmtMoney(ev.totals.value, ev.totals.currency) })}</p>}
              <Button variant="primary" id="tr-submit" className="w-full" onClick={submit} disabled={busy || !canWrite || !payload.length} disabledReason={!canWrite ? readOnlyReason : undefined}>
                {busy ? t('so.saving') : isReq ? t('inv.addRequest') : t('inv.addTransfer')}
              </Button>
              <Link to={`/docs/${kind}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
            </div>
          </SectionCard>
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Inventory document page (goods receipt, goods issue, transfer request, transfer) ----------
export function InvDocPage({ kind }: { kind: InvKind }) {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const obj = INV_OBJ[kind];
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const doc = useQuery({
    queryKey: ['inv-doc', company, obj, id],
    queryFn: async () => {
      const { data: d, error } = await erp().from('document').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).maybeSingle();
      if (error) throw new ApiError(error);
      const { data: ls, error: e2 } = await erp().from('document_line').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).order('line_num');
      if (e2) throw new ApiError(e2);
      return { d: d as R | null, lines: (ls ?? []) as R[] };
    },
  });
  const info = useInvInfo(company, obj, id);
  const I = info.data;
  const D = doc.data?.d;
  const refresh = () => { qc.invalidateQueries({ queryKey: ['inv-doc', company, obj, id] }); qc.invalidateQueries({ queryKey: ['inv-info', company, obj, id] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); };
  const listLabel = t(`erp.doc.${kind}`);
  if (doc.isLoading || info.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  if (doc.error || info.error) return <RequireModule module="inventory"><InvHeader title={entry} listTo={`/docs/${kind}`} listLabel={listLabel} /><div className="card"><ErrorState error={doc.error ?? info.error} onRetry={() => { doc.refetch(); info.refetch(); }} /></div></RequireModule>;
  if (!D || !I) return <RequireModule module="inventory"><InvHeader title={entry} listTo={`/docs/${kind}`} listLabel={listLabel} /><div className="card"><EmptyState title={t('erp.notFound')} /></div></RequireModule>;
  const title = `${t(`inv.one.${kind}`)} ${I.doc_no}`;
  const noun = t(`inv.noun.${kind}`);
  const det = (n: number) => I.details.find((x) => x.line_num === n);
  const transfer = kind === 'inventory_transfer' || kind === 'transfer_request';
  async function decide(d: 'approved' | 'rejected', note: string | null) {
    setErr(null);
    try { const r = await invDecide(company, obj, id, d, note); setFlash(t(d === 'approved' ? 'inv.flash.approved' : 'inv.flash.rejected', { no: I!.doc_no, trans: r.trans_id ?? '' })); refresh(); }
    catch (e) { setErr(errorMessage(e)); }
  }
  async function cancel(note: string) {
    if (kind === 'transfer_request') await trRequestCancel(company, id, note); else await invCancel(company, obj, id, note);
    setFlash(t('inv.flash.cancelled', { no: I!.doc_no })); refresh();
  }
  const pill = I.state && I.state !== 'approved' ? <StatePill state={I.state} /> : <StatusTag value={D.status} />;
  return (
    <RequireModule module="inventory">
      <InvHeader title={title} pills={<>{pill}<SourcePill source={D.source} /></>} listTo={`/docs/${kind}`} listLabel={listLabel}
        sub={[transfer ? [D.from_whs, D.to_whs].filter(Boolean).join(' → ') : I.whs_code, I.reason_name, I.created_by_name, I.created_at ? fmtWhen(I.created_at) : fmtDay(D.doc_date)].filter(Boolean).join(' · ')}
        actions={<>
          {I.can_copy && <Link id="inv-copy-transfer" to={`/inventory/transfer/new?company=${company}&request=${id}`} className={primaryLink}>{t('inv.copyToTransfer')}</Link>}
          {I.can_cancel && <CancelButton id="inv-cancel" title={t('inv.cancelTitle', { noun, no: I.doc_no })} onCancel={cancel} />}
        </>} />
      <Flash text={flash} />
      <FormError message={err} />
      {transfer && (
        <ol className="mb-5 flex flex-wrap items-center gap-1.5" aria-label={t('so.flow.label')} data-testid="inv-flow">
          {(['transfer_request', 'inventory_transfer'] as const).map((s, i) => {
            const mine = s === kind ? [{ doc_no: I.doc_no, doc_entry: id, obj_type: obj }] : I.flow.filter((f) => f.obj_type === INV_OBJ[s]);
            const cur = s === kind;
            return (
              <li key={s} className="flex items-center gap-1.5">
                {i > 0 && <span aria-hidden className="text-muted rtl:rotate-180">›</span>}
                <span aria-current={cur ? 'step' : undefined} className={clsx('inline-flex min-h-[32px] flex-wrap items-center gap-x-1.5 rounded-full border px-3 text-[13px] font-medium',
                  cur ? 'border-primary bg-primary-soft text-primary-text' : mine.length ? 'border-ok-fg/30 bg-ok-bg text-ok-fg' : 'border-line bg-surface text-muted')}>
                  {t(`erp.doc.${s}`)}
                  {mine.map((f, k) => <Fragment key={f.doc_entry}>{k > 0 && ','}{cur ? <span className="font-mono text-[12px]">{f.doc_no}</span> : <Link className="font-mono text-[12px] hover:underline" to={invPath(f.obj_type, company, f.doc_entry)!}>{f.doc_no}</Link>}</Fragment>)}
                </span>
              </li>
            );
          })}
        </ol>
      )}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              [t('erp.col.postingDate'), fmtDay(D.doc_date)],
              ...(kind === 'transfer_request' ? [[t('inv.neededBy'), fmtDay(D.due_date)] as [string, ReactNode]] : []),
              ...(transfer ? [[t('inv.fromWhs'), D.from_whs], [t('inv.toWhs'), D.to_whs]] as Array<[string, ReactNode]>
                : [[t('erp.col.warehouse'), I.whs_code], [t('inv.reason'), I.reason_name], [t('inv.account'), I.acct_code ? `${I.acct_code} · ${I.acct_name ?? ''}` : null]] as Array<[string, ReactNode]>),
              [t('inv.reference'), D.customer_ref], [t('erp.col.remarks'), D.comments],
              ...(kind !== 'transfer_request' ? [[t('inv.value'), <span key="v" className="num">{fmtMoney(D.total, D.currency)}</span>] as [string, ReactNode]] : []),
              [t('inv.journal'), I.trans_id ? (I.can_read_journal ? <Link key="j" id="inv-journal" className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${I.trans_id}`}>{I.trans_id}</Link> : <span key="j" className="font-mono">{I.trans_id}</span>)
                : (D.status === 'closed' ? t('inv.noJournal') : '—')],
            ]} />
          </SectionCard>
          <SectionCard title={t('inv.lines')}>
            <div className="overflow-x-auto">
              <table className="w-full text-sm" data-testid="inv-lines">
                <thead className="bg-surface-2 text-start text-xs text-muted"><tr>
                  <th scope="col" className="px-4 py-2 text-start">{t('inv.item')}</th>
                  <th scope="col" className="px-4 py-2 text-end">{t('erp.col.qty')}</th>
                  {kind === 'transfer_request' && <th scope="col" className="px-4 py-2 text-end">{t('inv.openQty')}</th>}
                  {transfer && <th scope="col" className="px-4 py-2 text-start max-sm:hidden">{t('erp.col.warehouses')}</th>}
                  {kind !== 'transfer_request' && <th scope="col" className="px-4 py-2 text-end max-sm:hidden">{t('inv.unitCost')}</th>}
                  {kind !== 'transfer_request' && <th scope="col" className="px-4 py-2 text-end">{t('inv.value')}</th>}
                </tr></thead>
                <tbody>
                  {doc.data!.lines.map((l) => {
                    const x = det(l.line_num);
                    return (
                      <tr key={l.line_num} className="border-t border-line align-top">
                        <td className="px-4 py-2.5"><b dir="auto">{l.description ?? l.item_code}</b>
                          <div className="font-mono text-[12px] text-muted">{l.item_code}{x?.from_bin_code ? ` · ${t('inv.fromBin')} ${x.from_bin_code}` : ''}{x?.bin_code ? ` · ${t('inv.bin')} ${x.bin_code}` : ''}</div>
                          {x && x.lots.length > 0 && <div className="font-mono text-[12px] text-ink-2" data-testid="inv-lots">{lotsText(x.lots, x.lots.some((z) => z.qty != null && z.qty !== 1))}</div>}
                        </td>
                        <td className="num px-4 py-2.5 text-end">{fmtQty(l.quantity)}</td>
                        {kind === 'transfer_request' && <td className="num px-4 py-2.5 text-end">{fmtQty(l.open_qty)}</td>}
                        {transfer && <td className="px-4 py-2.5 font-mono text-[13px] max-sm:hidden">{l.from_whs} → {l.whs_code}</td>}
                        {kind !== 'transfer_request' && <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(l.price)}</td>}
                        {kind !== 'transfer_request' && <td className="num px-4 py-2.5 text-end">{fmtMoney(l.line_total)}</td>}
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </SectionCard>
          {I.movements.length > 0 && (
            <SectionCard title={t('inv.movements')}>
              <div className="overflow-x-auto">
                <table className="w-full text-sm" data-testid="inv-movements">
                  <thead className="bg-surface-2 text-xs text-muted"><tr>
                    <th scope="col" className="px-4 py-2 text-start">{t('inv.item')}</th><th scope="col" className="px-4 py-2 text-start">{t('erp.col.warehouse')}</th>
                    <th scope="col" className="px-4 py-2 text-end">{t('inv.in')}</th><th scope="col" className="px-4 py-2 text-end">{t('inv.out')}</th>
                  </tr></thead>
                  <tbody>{I.movements.map((m) => (
                    <tr key={m.trans_seq} className="border-t border-line"><td className="px-4 py-2 font-mono text-[13px]">{m.item_code}</td><td className="px-4 py-2 font-mono text-[13px]">{m.whs_code}</td>
                      <td className="num px-4 py-2 text-end text-ok-fg">{Number(m.qty_in) ? fmtQty(m.qty_in) : ''}</td><td className="num px-4 py-2 text-end text-crit-fg">{Number(m.qty_out) ? fmtQty(m.qty_out) : ''}</td></tr>
                  ))}</tbody>
                </table>
              </div>
            </SectionCard>
          )}
        </div>
        <aside className="min-w-0 space-y-5">
          <ApprovalCard approvals={I.approvals} state={I.state} canDecide={I.can_decide} isSubmitter={I.is_submitter} submittedBy={I.submitted_by_name} submittedAt={I.submitted_at}
            reason={I.reason} docNo={I.doc_no} noun={noun} onDecide={decide} />
          {I.state === 'cancelled' && (
            <SectionCard title={t('so.approval.status')}><div className="space-y-2 p-5 text-sm"><p className="font-semibold text-crit-fg">{t('so.approval.cancelled', { when: fmtWhen(I.cancelled_at) })}</p>
              {I.cancel_note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{I.cancel_note}”</blockquote>}</div></SectionCard>
          )}
          <ActivityCard items={I.activity} />
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Inventory counting ----------
const COUNT_TONE: Record<CountState, string> = { counting: 'pill-info', pending_approval: 'pill-warning', posted: 'pill-ok', rejected: 'pill-crit', cancelled: 'pill-neutral' };
export function CountStatePill({ state }: { state: CountState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', COUNT_TONE[state])}>{t(`inv.count.state.${state}`)}</span>;
}

export function CountsPage() {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('inventory');
  const m = moduleByKey('inventory')!;
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'inv_count', table: 'inv_count_list',
    select: 'company_code,count_id,doc_no,whs_code,whs_name,item_group_name,count_date,state,n_lines,n_counted,gain_value,loss_value,created_by_name',
    searchCols: ['doc_no', 'whs_code', 'comments'], searchLabel: t('inv.count.search'),
    filters: [
      { key: 'state', label: t('erp.col.status'), options: (['counting', 'pending_approval', 'posted', 'rejected', 'cancelled'] as const).map((s) => [s, t(`inv.count.state.${s}`)] as [string, string]) },
      { key: 'whs_code', label: t('erp.col.warehouse'), from: { table: 'warehouse', value: 'whs_code', label: 'name' } },
    ],
    defaultSort: { col: 'count_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.count_id}`,
    rowLink: (r) => `/inventory/counts/${r.company_code}/${r.count_id}`,
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'count_date', header: t('erp.col.date'), cell: (r) => fmtDay(r.count_date), csv: (r) => r.count_date },
      { key: 'whs_code', header: t('erp.col.warehouse'), cell: (r) => `${r.whs_code} · ${r.whs_name ?? ''}` },
      { key: 'item_group_name', header: t('erp.col.itemGroup'), hideBelow: 'md', cell: (r) => r.item_group_name ?? t('inv.count.allItems') },
      { key: 'n_counted', header: t('inv.count.progress'), align: 'end', sortable: false, cell: (r) => `${fmtQty(r.n_counted)} / ${fmtQty(r.n_lines)}` },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <CountStatePill state={r.state} />, csv: (r) => r.state },
      { key: 'loss_value', header: t('inv.count.variance'), align: 'end', hideBelow: 'sm', sortable: false,
        cell: (r) => (r.gain_value == null && r.loss_value == null ? '—' : fmtMoney(Number(r.gain_value ?? 0) - Number(r.loss_value ?? 0))) },
    ],
  }), [t]);
  return (
    <RequireModule module="inventory">
      <header className="mb-6">
        <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/inventory'], [t('inv.count.title'), undefined]]} />
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div><h1 className="flex flex-wrap items-center gap-3 text-[26px] font-semibold sm:text-[28px]">{t('inv.count.title')} <LiveBadge live /></h1><p className="mt-1 text-[15px] text-muted">{t('inv.count.desc')}</p></div>
          {canWrite ? <Link to="/inventory/counts/new" id="count-new" className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {t('inv.count.new')}</Link>
            : <Button variant="primary" disabled id="count-new" disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {t('inv.count.new')}</Button>}
        </div>
      </header>
      <ListScreen config={cfg} />
    </RequireModule>
  );
}

export function CountNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const company = useDefaultCompany();
  const { canWrite, readOnlyReason } = useModuleLevel('inventory');
  const setup = useInvSetup(company || null);
  const [whs, setWhs] = useState('WH01');
  const [grp, setGrp] = useState('');
  const [date, setDate] = useState(today());
  const [comments, setComments] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    setErr(null); setBusy(true);
    try {
      const r = await countCreate(company, { whs_code: whs, item_group: grp || null, count_date: date, comments });
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      nav(`/inventory/counts/${company}/${r.count_id}`, { state: { flash: t('inv.flash.countStarted', { no: r.doc_no, n: r.lines }) } });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  if (setup.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  return (
    <RequireModule module="inventory">
      <InvHeader title={t('inv.count.new')} listTo="/inventory/counts" listLabel={t('inv.count.title')} sub={t('inv.count.newSub')} />
      <FormError message={err} />
      <SectionCard title={t('erp.section.header')} className="max-w-3xl">
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <label className={label}>{t('erp.col.warehouse')} <span className="text-crit-fg">*</span>
            <select id="count-whs" className={inputCls} value={whs} onChange={(e) => setWhs(e.target.value)}>{(setup.data?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}</select></label>
          <label className={label}>{t('erp.col.itemGroup')}
            <select id="count-group" className={inputCls} value={grp} onChange={(e) => setGrp(e.target.value)}>
              <option value="">{t('inv.count.allItems')}</option>{(setup.data?.item_groups ?? []).map((g) => <option key={g.code} value={g.code}>{g.name}</option>)}</select></label>
          <label className={label}>{t('inv.count.date')} <span className="text-crit-fg">*</span><input id="count-date" type="date" className={`${inputCls} num`} value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label className={label}>{t('erp.col.remarks')}<input id="count-comments" dir="auto" className={inputCls} value={comments} onChange={(e) => setComments(e.target.value)} /></label>
        </div>
        <div className="flex flex-wrap gap-2 border-t border-line p-5">
          <Button variant="primary" id="count-create" disabled={busy || !canWrite} disabledReason={!canWrite ? readOnlyReason : undefined} onClick={go}>{busy ? t('so.saving') : t('inv.count.start')}</Button>
          <Link to="/inventory/counts" className={secondaryLink}>{t('so.cancelEdit')}</Link>
        </div>
      </SectionCard>
    </RequireModule>
  );
}

export function CountPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const cid = Number(id);
  const qc = useQueryClient();
  const q = useCountInfo(company, cid);
  const C = q.data;
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [vals, setVals] = useState<Record<number, string>>({});
  const [dirty, setDirty] = useState(false);
  const [scan, setScan] = useState('');
  const [scanQty, setScanQty] = useState('1');
  const [why, setWhy] = useState('');
  const [busy, setBusy] = useState(false);
  const scanRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (C && !dirty) setVals(Object.fromEntries(C.lines.map((l) => [l.line_num, l.counted_qty == null ? '' : String(Number(l.counted_qty))])));
  }, [C, dirty]);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['inv-count', company, cid] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); };
  async function save(extra: Array<Record<string, unknown>> = []) {
    if (!C) return;
    setErr(null); setBusy(true);
    try {
      const changed = C.lines.filter((l) => (vals[l.line_num] ?? '') !== (l.counted_qty == null ? '' : String(Number(l.counted_qty))))
        .map((l) => ({ line_num: l.line_num, counted_qty: vals[l.line_num] ?? '' }));
      const r = await countSave(company, cid, [...changed, ...extra]);
      setDirty(false);
      setFlash(t('inv.flash.countSaved', { n: r.n_counted, of: r.n_lines }));
      refresh();
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  function onScan() {
    if (!C || !scan.trim()) return;
    const code = scan.trim();
    const line = C.lines.find((l) => (l.item_code === code || l.barcode === code) && !l.bin_code) ?? C.lines.find((l) => l.item_code === code || l.barcode === code);
    if (line) {
      const cur = Number(vals[line.line_num] || 0);
      setVals((v) => ({ ...v, [line.line_num]: String(cur + Number(scanQty || 1)) }));
      setDirty(true);
      setScan('');
      document.getElementById(`count-qty-${line.line_num}`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    } else {
      void save([{ item_code: code, counted_qty: scanQty || '1' }]);
      setScan('');
    }
    scanRef.current?.focus();
  }
  async function submit() {
    setErr(null); setBusy(true);
    try {
      if (dirty) await save();
      const r = await countSubmit(company, cid, why.trim() || null);
      setFlash(t(r.state === 'posted' ? 'inv.flash.countPosted' : 'inv.flash.countWaiting', { no: C!.doc_no }));
      refresh();
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  async function decide(d: 'approved' | 'rejected', note: string | null) {
    setErr(null);
    try { await countDecide(company, cid, d, note); setFlash(t(d === 'approved' ? 'inv.flash.countApproved' : 'inv.flash.rejected', { no: C!.doc_no })); refresh(); }
    catch (e) { setErr(errorMessage(e)); }
  }
  if (q.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  if (q.error || !C) return <RequireModule module="inventory"><InvHeader title={id} listTo="/inventory/counts" listLabel={t('inv.count.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  const counted = C.lines.filter((l) => (vals[l.line_num] ?? '') !== '').length;
  const rep = C.report;
  return (
    <RequireModule module="inventory">
      <InvHeader title={`${t('inv.count.one')} ${C.doc_no}`} pills={<CountStatePill state={C.state} />} listTo="/inventory/counts" listLabel={t('inv.count.title')}
        sub={[`${C.whs_code} · ${C.whs_name ?? ''}`, C.item_group_name ?? t('inv.count.allItems'), fmtDay(C.count_date), C.created_by_name].filter(Boolean).join(' · ')}
        actions={C.can_cancel ? <CancelButton id="count-cancel" title={t('inv.cancelTitle', { noun: t('inv.count.noun'), no: C.doc_no })}
          onCancel={async (n) => { await countCancel(company, cid, n); setFlash(t('inv.flash.cancelled', { no: C.doc_no })); refresh(); }} /> : undefined} />
      <Flash text={flash} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          {C.can_count && (
            <SectionCard title={t('inv.count.scanTitle')}>
              <div className="grid grid-cols-[minmax(0,1fr)_90px] gap-3 p-5 sm:grid-cols-[minmax(0,1fr)_110px_auto]">
                <label className={label}>{t('inv.count.scan')}
                  <input ref={scanRef} id="count-scan" autoComplete="off" inputMode="text" className="input mt-1 min-h-[52px] font-mono text-[18px] text-ink" placeholder={t('inv.count.scanPh')}
                    value={scan} onChange={(e) => setScan(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); onScan(); } }} />
                </label>
                <label className={label}>{t('erp.col.qty')}<input id="count-scan-qty" inputMode="decimal" className="input num mt-1 min-h-[52px] text-end text-[18px] text-ink" value={scanQty} onChange={(e) => setScanQty(e.target.value)} /></label>
                <div className="col-span-2 flex items-end sm:col-span-1"><Button id="count-scan-add" className="w-full" onClick={onScan} icon={<ScanLine className="h-4 w-4" aria-hidden />}>{t('inv.count.add')}</Button></div>
              </div>
            </SectionCard>
          )}
          <SectionCard title={t('inv.count.sheet')} right={<span className="num text-sm text-muted" aria-live="polite" data-testid="count-progress">{t('inv.count.counted', { n: counted, of: C.lines.length })}</span>}>
            {C.blind && <p className="border-b border-line bg-info-bg px-5 py-2 text-[13px] text-info-fg">{t('inv.count.blindNote')}</p>}
            <ul className="divide-y divide-line" data-testid="count-sheet">
              {C.lines.map((l) => (
                <li key={l.line_num} className="flex flex-wrap items-center gap-3 px-5 py-3" data-testid="count-line" data-item={l.item_code}>
                  <div className="min-w-0 flex-1">
                    <p dir="auto" className="font-medium">{l.description ?? l.item_code}</p>
                    <p className="font-mono text-[12px] text-muted">{l.item_code}{l.bin_code ? ` · ${t('inv.bin')} ${l.bin_code}` : C.bins ? ` · ${t('inv.outsideBins')}` : ''}{l.barcode ? ` · ${l.barcode}` : ''}{l.added ? ` · ${t('inv.count.added')}` : ''}</p>
                    {l.system_qty != null && (
                      <p className="num text-[12px] text-ink-2">{t('inv.count.expected', { n: fmtQty(l.system_qty) })}{l.variance != null && Number(l.variance) !== 0 ? <span className={Number(l.variance) < 0 ? ' text-crit-fg' : ' text-ok-fg'}> · {Number(l.variance) > 0 ? '+' : ''}{fmtQty(l.variance)}</span> : null}</p>
                    )}
                  </div>
                  <label className="sr-only" htmlFor={`count-qty-${l.line_num}`}>{t('inv.count.countedOf', { item: l.item_code })}</label>
                  <input id={`count-qty-${l.line_num}`} inputMode="decimal" disabled={!C.can_count} className="input num min-h-[52px] w-28 text-end text-[20px] text-ink"
                    value={vals[l.line_num] ?? ''} onChange={(e) => { setVals((v) => ({ ...v, [l.line_num]: e.target.value })); setDirty(true); }} />
                </li>
              ))}
            </ul>
            {C.can_count && (
              <div className="sticky bottom-0 flex flex-wrap gap-2 border-t border-line bg-surface p-4">
                <Button variant="secondary" id="count-save" className="min-h-[52px] flex-1" disabled={busy || !dirty} onClick={() => save()}>{busy ? t('so.saving') : t('inv.count.save')}</Button>
              </div>
            )}
          </SectionCard>
          {rep && (
            <SectionCard title={t('inv.count.report')} right={<span className="num text-sm">{t('inv.count.gainLoss', { g: fmtMoney(rep.totals.gain), l: fmtMoney(rep.totals.loss), cur: rep.totals.currency })}</span>}>
              {rep.errors.map((e, i) => <p key={i} role="alert" dir="auto" className="px-5 pt-3 text-[13px] text-crit-fg">{e.message}</p>)}
              <div className="overflow-x-auto">
                <table className="w-full text-sm" data-testid="count-report">
                  <thead className="bg-surface-2 text-xs text-muted"><tr>
                    <th scope="col" className="px-4 py-2 text-start">{t('inv.item')}</th><th scope="col" className="px-4 py-2 text-end">{t('inv.count.system')}</th>
                    <th scope="col" className="px-4 py-2 text-end">{t('inv.count.countedCol')}</th><th scope="col" className="px-4 py-2 text-end">{t('inv.count.variance')}</th>
                    <th scope="col" className="px-4 py-2 text-end max-sm:hidden">%</th><th scope="col" className="px-4 py-2 text-end">{t('inv.value')}</th>
                  </tr></thead>
                  <tbody>{rep.lines.filter((l) => Number(l.variance) !== 0).map((l) => {
                    const over = C.approvals.some((a) => (a.detail?.checks ?? []).some((c) => c.line === l.line_num));
                    return (
                      <tr key={l.line_num} className={clsx('border-t border-line', over && 'bg-warn-bg')} data-testid="count-variance-row">
                        <td className="px-4 py-2"><span className="font-mono text-[13px]">{l.item_code}</span>{l.bin_code && <span className="text-xs text-muted"> · {l.bin_code}</span>}</td>
                        <td className="num px-4 py-2 text-end">{fmtQty(l.system_qty)}</td><td className="num px-4 py-2 text-end">{fmtQty(l.counted_qty)}</td>
                        <td className={clsx('num px-4 py-2 text-end', Number(l.variance) < 0 ? 'text-crit-fg' : 'text-ok-fg')}>{Number(l.variance) > 0 ? '+' : ''}{fmtQty(l.variance)}</td>
                        <td className="num px-4 py-2 text-end max-sm:hidden">{l.pct == null ? '—' : `${fmtQty(l.pct)}%`}</td><td className="num px-4 py-2 text-end">{fmtMoney(l.value)}</td>
                      </tr>
                    );
                  })}
                  {!rep.lines.some((l) => Number(l.variance) !== 0) && <tr><td colSpan={6} className="px-4 py-4 text-center text-muted">{t('inv.count.noVariance')}</td></tr>}</tbody>
                </table>
              </div>
            </SectionCard>
          )}
        </div>
        <aside className="min-w-0 space-y-5">
          {C.can_count && (
            <SectionCard title={t('inv.count.submitTitle')}>
              <div className="space-y-3 p-5">
                <p className="text-sm text-muted">{t('inv.count.submitWhat')}</p>
                <label className={label}>{t('inv.count.reasonIf')}
                  <textarea id="count-why" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={why} onChange={(e) => setWhy(e.target.value)} /></label>
                <Button variant="primary" id="count-submit" className="w-full" disabled={busy || counted < C.lines.length}
                  disabledReason={counted < C.lines.length ? t('inv.count.notAllCounted', { n: C.lines.length - counted }) : undefined} onClick={submit}>{t('inv.count.submit')}</Button>
              </div>
            </SectionCard>
          )}
          {C.state === 'posted' && (
            <SectionCard title={t('inv.count.posting')}><div className="space-y-2 p-5 text-sm" data-testid="count-posted">
              <p className="flex items-center gap-2 font-semibold text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{t('inv.count.postedAt', { when: fmtWhen(C.posted_at) })}</p>
              {C.trans_id ? (C.can_read_journal ? <Link id="count-journal" className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${C.trans_id}`}>{t('inv.journalN', { n: C.trans_id })}</Link> : <p className="font-mono">{t('inv.journalN', { n: C.trans_id })}</p>) : <p className="text-muted">{t('inv.count.noJournal')}</p>}
            </div></SectionCard>
          )}
          <ApprovalCard approvals={C.approvals} state={C.state === 'posted' ? 'approved' : C.state} canDecide={C.can_decide} isSubmitter={C.is_submitter} submittedBy={C.submitted_by_name}
            submittedAt={C.submitted_at} reason={C.reason} docNo={C.doc_no} noun={t('inv.count.noun')} onDecide={decide} />
          <ActivityCard items={C.activity} />
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Batches / serial numbers ----------
export function LotsPage({ kind }: { kind: 'B' | 'S' }) {
  const { t } = useTranslation();
  const m = moduleByKey('inventory')!;
  const title = kind === 'S' ? t('inv.lots.serials') : t('inv.lots.batches');
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: `lot-${kind}`, table: 'lot_list',
    select: 'company_code,lot_key,lot_id,kind,item_code,item_name,number,expires_on,received_on,qty,whs_codes,status,source',
    searchCols: ['number', 'item_code', 'item_name'], searchLabel: t('inv.lots.search'), fixed: { kind },
    filters: [
      { key: 'status', label: t('erp.col.status'), options: [['in_stock', t('inv.lots.inStock')], ['out', t('inv.lots.out')]] },
      { key: 'source', label: t('so.filter.source'), options: [['erp', 'Super ERP'], ['sap', 'SAP']] },
    ],
    defaultSort: { col: 'number', asc: true },
    rowKey: (r) => `${r.company_code}|${r.lot_key}`,
    rowLink: (r) => (r.lot_id ? `/inventory/lots/${r.company_code}/${r.lot_id}` : ''),
    columns: [
      { key: 'number', header: kind === 'S' ? t('inv.lots.serialNo') : t('inv.lots.batchNo'), mono: true },
      { key: 'item_code', header: t('inv.item'), cell: (r) => <span><span className="font-mono text-[13px] text-muted">{r.item_code}</span> {r.item_name}</span>, csv: (r) => r.item_code },
      { key: 'whs_codes', header: t('erp.col.warehouse'), sortable: false, cell: (r) => r.whs_codes ?? '—' },
      { key: 'qty', header: t('erp.col.qty'), align: 'end', cell: (r) => (r.qty == null ? '—' : fmtQty(r.qty)) },
      { key: 'expires_on', header: t('inv.lots.expires'), hideBelow: 'md', cell: (r) => fmtDay(r.expires_on), csv: (r) => r.expires_on },
      { key: 'source', header: t('erp.col.source'), hideBelow: 'lg', cell: (r) => (r.source === 'sap' ? 'SAP' : 'Super ERP') },
    ],
  }), [t, kind]);
  return (
    <RequireModule module="inventory">
      <header className="mb-6">
        <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/inventory'], [title, undefined]]} />
        <h1 className="flex flex-wrap items-center gap-3 text-[26px] font-semibold sm:text-[28px]">{title} <LiveBadge live /></h1>
        <p className="mt-1 text-[15px] text-muted">{t('inv.lots.desc')}</p>
      </header>
      <ListScreen key={kind} config={cfg} />
    </RequireModule>
  );
}

export function LotPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const q = useLotHistory(company, Number(id));
  const L = q.data;
  const listTo = L?.kind === 'B' ? '/inventory/batches' : '/inventory/serials';
  const listLabel = L?.kind === 'B' ? t('inv.lots.batches') : t('inv.lots.serials');
  if (q.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  if (q.error || !L) return <RequireModule module="inventory"><InvHeader title={id} listTo="/inventory/serials" listLabel={t('inv.lots.serials')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} />}</div></RequireModule>;
  return (
    <RequireModule module="inventory">
      <InvHeader title={`${L.number} · ${L.item_code}`} pills={<SourcePill source={L.source} />} listTo={listTo} listLabel={listLabel} sub={L.item_name ?? undefined} />
      <div className="space-y-5">
        <SectionCard title={t('erp.section.general')}>
          <Fields items={[[t('inv.lots.kind'), L.kind === 'S' ? t('inv.lots.serialNo') : t('inv.lots.batchNo')], [t('inv.lots.received'), fmtDay(L.received_on)],
            [t('inv.lots.made'), fmtDay(L.made_on)], [t('inv.lots.expires'), fmtDay(L.expires_on)],
            [t('inv.lots.where'), L.balances.length ? L.balances.map((b) => `${b.whs_code} ${fmtQty(b.qty)}`).join(', ') : t('inv.lots.out')]]} />
        </SectionCard>
        <SectionCard title={t('inv.lots.history')}>
          <div className="overflow-x-auto">
            <table className="w-full text-sm" data-testid="lot-history">
              <thead className="bg-surface-2 text-xs text-muted"><tr>
                <th scope="col" className="px-4 py-2 text-start">{t('erp.col.date')}</th><th scope="col" className="px-4 py-2 text-start">{t('erp.col.docNo')}</th>
                <th scope="col" className="px-4 py-2 text-start">{t('erp.col.warehouse')}</th><th scope="col" className="px-4 py-2 text-end">{t('inv.in')}</th><th scope="col" className="px-4 py-2 text-end">{t('inv.out')}</th>
              </tr></thead>
              <tbody>{L.moves.map((m) => (
                <tr key={m.move_id} className="border-t border-line">
                  <td className="px-4 py-2">{fmtDay(m.doc_date)}</td>
                  <td className="px-4 py-2">{invPath(m.obj_type, company, m.doc_entry) ? <Link className="font-mono text-[13px] text-primary hover:underline" to={invPath(m.obj_type, company, m.doc_entry)!}>{m.doc_no}</Link> : <span className="font-mono text-[13px]">{m.doc_no}</span>}
                    <span className="block text-xs text-muted">{t(`inv.obj.${m.obj_type}`, { defaultValue: String(m.obj_type) })}</span></td>
                  <td className="px-4 py-2 font-mono text-[13px]">{m.whs_code}</td>
                  <td className="num px-4 py-2 text-end text-ok-fg">{Number(m.qty_in) ? fmtQty(m.qty_in) : ''}</td><td className="num px-4 py-2 text-end text-crit-fg">{Number(m.qty_out) ? fmtQty(m.qty_out) : ''}</td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        </SectionCard>
      </div>
    </RequireModule>
  );
}

// ---------- Bin locations and inventory setup ----------
export function InventorySetupPage() {
  const { t } = useTranslation();
  const company = useDefaultCompany();
  const qc = useQueryClient();
  const setup = useInvSetup(company || null);
  const S = setup.data;
  const [flash, setFlash] = useFlash();
  const [err, setErr] = useState<string | null>(null);
  const [bin, setBin] = useState({ bin_code: '', whs_code: '', name: '' });
  const [rs, setRs] = useState({ code: '', name: '', direction: 'both', acct_code: '' });
  const m = moduleByKey('inventory')!;
  const done = (msg: string) => { setFlash(msg); setErr(null); qc.invalidateQueries({ queryKey: ['inv-setup'] }); };
  const run = async (f: () => Promise<unknown>, msg: string) => { try { await f(); done(msg); } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } };
  if (setup.isLoading) return <RequireModule module="inventory"><PageLoading /></RequireModule>;
  const canW = Boolean(S?.can_write);
  const canF = Boolean(S?.can_finance);
  const binWhs = (S?.warehouses ?? []).filter((w) => w.bins);
  return (
    <RequireModule module="inventory">
      <header className="mb-6">
        <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/inventory'], [t('inv.setup.title'), undefined]]} />
        <h1 className="flex flex-wrap items-center gap-3 text-[26px] font-semibold sm:text-[28px]">{t('inv.setup.title')} <LiveBadge live /></h1>
        <p className="mt-1 text-[15px] text-muted">{t('inv.setup.desc')}</p>
      </header>
      <Flash text={flash} />
      <FormError message={err ?? (setup.error ? errorMessage(setup.error) : null)} />
      <div className="space-y-5">
        <SectionCard title={t('inv.setup.warehouses')} right={<label className="flex items-center gap-2 text-sm"><input id="inv-blind" type="checkbox" className="h-5 w-5" disabled={!canW} checked={Boolean(S?.blind_count)}
          onChange={(e) => run(() => invSettingSet(company, { blind_count: e.target.checked }), t('inv.setup.saved'))} />{t('inv.setup.blind')}</label>}>
          <div className="overflow-x-auto">
            <table className="w-full text-sm" data-testid="inv-whs-table">
              <thead className="bg-surface-2 text-xs text-muted"><tr>
                <th scope="col" className="px-4 py-2 text-start">{t('erp.col.warehouse')}</th><th scope="col" className="px-4 py-2 text-start">{t('inv.setup.bins')}</th>
                <th scope="col" className="px-4 py-2 text-start">{t('inv.setup.stockAcct')}</th>
              </tr></thead>
              <tbody>{(S?.warehouses ?? []).map((w) => (
                <tr key={w.code} className="border-t border-line" data-whs={w.code}>
                  <td className="px-4 py-2"><span className="font-mono">{w.code}</span> · {w.name}</td>
                  <td className="px-4 py-2"><label className="inline-flex min-h-[40px] items-center gap-2"><input type="checkbox" id={`whs-bins-${w.code}`} className="h-5 w-5" disabled={!canW} checked={w.bins}
                    onChange={(e) => run(() => whsInvSet(company, w.code, { bins_enabled: e.target.checked }), t('inv.setup.saved'))} />{w.bins ? t('inv.usesBins') : t('erp.no')}</label></td>
                  <td className="px-4 py-2">
                    <select id={`whs-acct-${w.code}`} aria-label={t('inv.setup.stockAcctOf', { whs: w.code })} className="input min-h-[40px] max-w-[260px] text-sm" disabled={!canF} value={w.stock_acct ?? ''}
                      onChange={(e) => run(() => whsInvSet(company, w.code, { stock_acct: e.target.value }), t('inv.setup.saved'))}>
                      <option value="">{t('inv.setup.companyAcct')}</option>
                      {(S?.accounts ?? []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}
                    </select>
                  </td>
                </tr>
              ))}</tbody>
            </table>
          </div>
          {!canF && <p className="px-5 py-3 text-xs text-muted">{t('inv.setup.financeOnly')}</p>}
        </SectionCard>

        <SectionCard title={t('inv.setup.binsTitle')}>
          <div className="overflow-x-auto">
            <table className="w-full text-sm" data-testid="inv-bins-table">
              <thead className="bg-surface-2 text-xs text-muted"><tr>
                <th scope="col" className="px-4 py-2 text-start">{t('inv.bin')}</th><th scope="col" className="px-4 py-2 text-start">{t('erp.col.warehouse')}</th>
                <th scope="col" className="px-4 py-2 text-end">{t('erp.col.qty')}</th><th scope="col" className="px-4 py-2 text-start">{t('erp.col.status')}</th>
              </tr></thead>
              <tbody>{(S?.bins ?? []).map((b) => (
                <tr key={b.code} className="border-t border-line"><td className="px-4 py-2"><span className="font-mono">{b.code}</span>{b.name && <span className="block text-xs text-muted">{b.name}</span>}</td>
                  <td className="px-4 py-2 font-mono">{b.whs_code}</td><td className="num px-4 py-2 text-end">{fmtQty(b.qty)}</td>
                  <td className="px-4 py-2"><label className="inline-flex min-h-[40px] items-center gap-2"><input type="checkbox" className="h-5 w-5" disabled={!canW} checked={b.active}
                    onChange={(e) => run(() => binSave(company, { bin_code: b.code, active: e.target.checked }), t('inv.setup.saved'))} />{b.active ? t('erp.status.active') : t('erp.status.inactive')}</label></td></tr>
              ))}</tbody>
            </table>
          </div>
          {canW && (
            <div className="grid grid-cols-1 gap-3 border-t border-line p-5 sm:grid-cols-4">
              <label className={label}>{t('inv.setup.binCode')}<input id="bin-code" className={`${inputCls} font-mono`} placeholder="WH02-C-01-L1" value={bin.bin_code} onChange={(e) => setBin({ ...bin, bin_code: e.target.value })} /></label>
              <label className={label}>{t('erp.col.warehouse')}<select id="bin-whs" className={inputCls} value={bin.whs_code} onChange={(e) => setBin({ ...bin, whs_code: e.target.value })}>
                <option value="">{t('inv.choose')}</option>{(binWhs.length ? binWhs : S?.warehouses ?? []).map((w) => <option key={w.code} value={w.code}>{w.code}</option>)}</select></label>
              <label className={label}>{t('erp.col.name')}<input id="bin-name" dir="auto" className={inputCls} value={bin.name} onChange={(e) => setBin({ ...bin, name: e.target.value })} /></label>
              <div className="flex items-end"><Button id="bin-add" className="w-full" icon={<Plus className="h-4 w-4" aria-hidden />}
                onClick={() => run(async () => { await binSave(company, bin); setBin({ bin_code: '', whs_code: bin.whs_code, name: '' }); }, t('inv.setup.binAdded'))}>{t('inv.setup.addBin')}</Button></div>
            </div>
          )}
        </SectionCard>

        <SectionCard title={t('inv.setup.reasons')}>
          <div className="overflow-x-auto">
            <table className="w-full text-sm" data-testid="inv-reasons-table">
              <thead className="bg-surface-2 text-xs text-muted"><tr>
                <th scope="col" className="px-4 py-2 text-start">{t('erp.col.code')}</th><th scope="col" className="px-4 py-2 text-start">{t('erp.col.name')}</th>
                <th scope="col" className="px-4 py-2 text-start">{t('inv.setup.usedFor')}</th><th scope="col" className="px-4 py-2 text-start">{t('inv.account')}</th>
              </tr></thead>
              <tbody>{(S?.reasons ?? []).map((r) => (
                <tr key={r.code} className="border-t border-line"><td className="px-4 py-2 font-mono">{r.code}</td><td className="px-4 py-2" dir="auto">{r.name}{r.source === 'sample' && <span className="ms-2 pill pill-warning">{t('erp.sampleData')}</span>}</td>
                  <td className="px-4 py-2">{t(`inv.setup.dir.${r.direction}`)}</td><td className="px-4 py-2">{r.acct_code ? `${r.acct_code} · ${r.acct_name ?? ''}` : <span className="pill pill-warning">{t('inv.setup.notSet')}</span>}</td></tr>
              ))}
              {!(S?.reasons ?? []).length && <tr><td colSpan={4} className="px-4 py-4 text-center text-muted">{t('inv.noReasons')}</td></tr>}</tbody>
            </table>
          </div>
          {canF ? (
            <div className="grid grid-cols-1 gap-3 border-t border-line p-5 sm:grid-cols-5">
              <label className={label}>{t('erp.col.code')}<input id="reason-code" className={`${inputCls} font-mono`} value={rs.code} onChange={(e) => setRs({ ...rs, code: e.target.value })} /></label>
              <label className={label}>{t('erp.col.name')}<input id="reason-name" dir="auto" className={inputCls} value={rs.name} onChange={(e) => setRs({ ...rs, name: e.target.value })} /></label>
              <label className={label}>{t('inv.setup.usedFor')}<select id="reason-dir" className={inputCls} value={rs.direction} onChange={(e) => setRs({ ...rs, direction: e.target.value })}>
                {(['in', 'out', 'both'] as const).map((d) => <option key={d} value={d}>{t(`inv.setup.dir.${d}`)}</option>)}</select></label>
              <label className={label}>{t('inv.account')}<select id="reason-acct" className={inputCls} value={rs.acct_code} onChange={(e) => setRs({ ...rs, acct_code: e.target.value })}>
                <option value="">{t('inv.choose')}</option>{(S?.accounts ?? []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}</select></label>
              <div className="flex items-end"><Button id="reason-save" className="w-full" onClick={() => run(async () => { await reasonSave(company, rs); setRs({ code: '', name: '', direction: 'both', acct_code: '' }); }, t('inv.setup.saved'))}>{t('inv.setup.saveReason')}</Button></div>
            </div>
          ) : <p className="border-t border-line px-5 py-3 text-xs text-muted">{t('inv.setup.reasonsFinance')}</p>}
        </SectionCard>
      </div>
    </RequireModule>
  );
}

/** Item detail › movement history (Item Master Data › Item history). */
export function ItemHistoryCard({ company, item }: { company: string; item: string }) {
  const { t } = useTranslation();
  const q = useQuery({
    queryKey: ['item-history', company, item],
    queryFn: async () => {
      const { data, error } = await erp().from('item_movement_list').select('trans_seq,trans_type,doc_entry,doc_date,whs_code,qty_in,qty_out,price,doc_no,source')
        .match({ company_code: company, item_code: item }).order('doc_date', { ascending: false }).order('trans_seq', { ascending: false }).limit(50);
      if (error) throw new ApiError(error);
      return (data ?? []) as R[];
    },
  });
  return (
    <SectionCard title={t('inv.history.title')} right={<span className="text-xs text-muted">{t('inv.history.last')}</span>}>
      {q.isLoading ? <p className="p-5 text-sm text-muted">{t('inv.loading')}</p> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !q.data!.length ? <EmptyState title={t('inv.history.empty')} /> : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm" data-testid="item-history">
            <thead className="bg-surface-2 text-xs text-muted"><tr>
              <th scope="col" className="px-4 py-2 text-start">{t('erp.col.date')}</th><th scope="col" className="px-4 py-2 text-start">{t('erp.col.docNo')}</th>
              <th scope="col" className="px-4 py-2 text-start">{t('erp.col.warehouse')}</th><th scope="col" className="px-4 py-2 text-end">{t('inv.in')}</th>
              <th scope="col" className="px-4 py-2 text-end">{t('inv.out')}</th><th scope="col" className="px-4 py-2 text-end max-sm:hidden">{t('inv.unitCost')}</th>
            </tr></thead>
            <tbody>{q.data!.map((m) => {
              const to = m.trans_type === 1470000065 ? `/inventory/counts/${company}/${m.doc_entry}` : invPath(m.trans_type, company, m.doc_entry)
                ?? (DOC_KINDS && Object.entries(DOC_KINDS).find(([, d]) => d.obj === m.trans_type)?.[0] ? `/docs/${Object.entries(DOC_KINDS).find(([, d]) => d.obj === m.trans_type)![0]}/${company}/${m.doc_entry}` : undefined);
              return (
                <tr key={m.trans_seq} className="border-t border-line" data-testid="item-history-row">
                  <td className="px-4 py-2">{fmtDay(m.doc_date)}</td>
                  <td className="px-4 py-2">{to ? <Link className="font-mono text-[13px] text-primary hover:underline" to={to}>{m.doc_no}</Link> : <span className="font-mono text-[13px]">{m.doc_no}</span>}
                    <span className="block text-xs text-muted">{t(`inv.obj.${m.trans_type}`, { defaultValue: String(m.trans_type) })}</span></td>
                  <td className="px-4 py-2 font-mono text-[13px]">{m.whs_code}</td>
                  <td className="num px-4 py-2 text-end text-ok-fg">{Number(m.qty_in) ? fmtQty(m.qty_in) : ''}</td>
                  <td className="num px-4 py-2 text-end text-crit-fg">{Number(m.qty_out) ? fmtQty(m.qty_out) : ''}</td>
                  <td className="num px-4 py-2 text-end max-sm:hidden">{fmtMoney(m.price)}</td>
                </tr>
              );
            })}</tbody>
          </table>
        </div>
      )}
    </SectionCard>
  );
}
