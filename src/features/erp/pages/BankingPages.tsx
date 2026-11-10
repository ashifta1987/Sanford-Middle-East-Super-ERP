import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, ArrowLeft, Check, CircleCheck, CircleX, FileText, Plus, Trash2, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { errorMessage } from '@/lib/format';
import i18n from '@/lib/i18n';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney } from '../components/ui';
import { SeriesPicker } from '../components/SeriesPicker';
import { CurrencyFields } from '../components/CurrencyFields';
import { defaultCurrency, fmtRate, lcLabel, useLocalCurrencies, useLocalCurrency } from '../currency';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { moduleByKey } from '../modules';
import type { Row } from '../api';
import {
  dirOf, dirPath, payCancel, payChecks, payDecide, payDraftCancel, paySubmit, searchPartners, useDraftInfo, useOpenDocs, usePaySetup, usePaymentInfo,
  type Activity, type BpHit, type ChequeInput, type Dir, type DraftInfo, type DraftState, type PayEval, type PayHeaderInput,
} from '../banking';
import { ApprovalStageNote } from '../components/ApprovalStageNote';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const r2 = (n: number) => Math.round(n * 100) / 100;
const num = (s: string) => (s.trim() === '' ? 0 : Number(s) || 0);
export function todayIso() {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 10);
}
export const fmtWhen = (iso: string | null | undefined) =>
  !iso ? '—' : new Intl.DateTimeFormat(i18n.language === 'ar' ? 'ar-AE' : 'en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
export const sourceName = (s: string | null | undefined) => (s === 'sap' ? 'SAP Business One' : s === 'erp' ? 'Super ERP' : i18n.t('erp.sampleData'));
export const docLabel = (obj: number) => i18n.t(`bk.obj.${obj}`, { defaultValue: String(obj) });
export const docLink = (obj: number, company: string, entry: number) => {
  const kind = ({ 13: 'ar_invoice', 14: 'ar_credit_note', 18: 'ap_invoice', 19: 'ap_credit_note', 204: 'ap_down_payment' } as Record<number, string>)[obj];
  return kind ? `/docs/${kind}/${company}/${entry}` : undefined;
};

export function useDefaultCompany() {
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const companies = profile?.companies ?? [];
  return top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? '';
}

export function FormError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div role="alert" className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-crit-fg">
      <p className="flex items-start gap-2 font-semibold"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="bk-error">{message}</span></p>
    </div>
  );
}
export function Flash({ text }: { text: string | null }) {
  if (!text) return null;
  return <p role="status" data-testid="bk-flash" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{text}</p>;
}
export function useFlash() {
  const loc = useLocation();
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  useEffect(() => { if (flash) { const h = setTimeout(() => setFlash(null), 8000); return () => clearTimeout(h); } }, [flash]);
  return [flash, setFlash] as const;
}

/** Header for banking forms and records: back link, breadcrumb, title with pills, one line under it, actions. */
export function BkHeader({ title, back, parent, pills, sub, actions, onBack }: {
  title: string; back: [string, string]; parent?: [string, string]; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode; onBack?: (e: React.MouseEvent) => void;
}) {
  const { t } = useTranslation();
  const m = moduleByKey('banking')!;
  const p = parent ?? back;
  return (
    <header className="mb-4">
      <Link to={back[1]} onClick={onBack} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {back[0]}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/banking'], [p[0], p[1]], [title, undefined]]} />
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

export function ActivityCard({ items }: { items: Activity[] }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('je.activity.title')}>
      {items.length === 0 ? <p className="p-5 text-sm text-muted">{t('je.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid="bk-activity">
          {items.map((a, i) => {
            const det = (a.detail ?? {}) as R;
            const tone = /approve|post|create|match/.test(a.action) && !/unmatch/.test(a.action) ? 'bg-ok-fg' : /reject|cancel|unmatch/.test(a.action) ? 'bg-crit-fg' : 'bg-primary';
            return (
              <li key={i} className="flex gap-3">
                <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', tone)} aria-hidden />
                <div className="min-w-0 text-sm">
                  <p><span className="font-medium">{a.actor_name.startsWith('system:') ? t('je.activity.system') : a.actor_name}</span> {t(`bk.activity.${a.action}`, { defaultValue: a.action, no: det.doc_no ?? '' })}</p>
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

const STATE_TONE: Record<DraftState, string> = { pending_approval: 'pill-warning', posted: 'pill-ok', rejected: 'pill-crit', cancelled: 'pill-crit' };
export function DraftStatePill({ state }: { state: DraftState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', STATE_TONE[state])}>{t(`bk.state.${state}`)}</span>;
}

// ---------- Lists ----------
export function PaymentsList({ dir }: { dir: Dir }) {
  const { t } = useTranslation();
  const localOf = useLocalCurrencies();
  const incoming = dir === 'I';
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: `payment-${dir}`, table: 'payment_list',
    select: 'company_code,direction,doc_entry,doc_num,doc_no,doc_date,card_code,card_name,currency,total,cash,transfer,cheque,card,on_account,cancelled,source',
    searchCols: ['card_code', 'card_name', 'memo', 'doc_no'], numberSearchCols: ['doc_num'], searchLabel: t('erp.search.payment'),
    fixed: { direction: dir },
    filters: [
      { key: 'cancelled', label: t('erp.col.status'), options: [['false', t('erp.status.posted')], ['true', t('erp.status.cancelled')]], type: 'boolean' },
      { key: 'source', label: t('erp.col.source'), options: [['erp', 'Super ERP'], ['sap', 'SAP Business One'], ['sample', t('erp.sampleData')]] },
    ],
    defaultSort: { col: 'doc_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.direction}|${r.doc_entry}`,
    rowLink: (r) => `/banking/payments/${dirPath(dir)}/${r.company_code}/${r.doc_entry}`,
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'doc_date', header: t('erp.col.date'), cell: (r) => fmtDay(r.doc_date), csv: (r) => r.doc_date },
      { key: 'card_name', header: incoming ? t('erp.col.customer') : t('erp.col.supplier'),
        cell: (r) => <span><span className="font-mono text-[13px] text-muted">{r.card_code}</span> {r.card_name}</span> },
      { key: 'means', header: t('erp.col.means'), sortable: false, hideBelow: 'md',
        cell: (r) => (['cash', 'transfer', 'cheque', 'card'] as const).filter((k) => Number(r[k]) > 0).map((k) => t(`erp.means.${k}`)).join(', ') || '—' },
      { key: 'source', header: t('erp.col.source'), hideBelow: 'lg', cell: (r) => sourceName(r.source) },
      { key: 'cancelled', header: t('erp.col.status'), cell: (r) => <span className={clsx('pill', r.cancelled ? 'pill-crit' : 'pill-ok')}>{r.cancelled ? t('erp.status.cancelled') : t('erp.status.posted')}</span>,
        csv: (r) => (r.cancelled ? 'cancelled' : 'posted') },
      { key: 'total', header: t('erp.col.amount'), align: 'end', cell: (r) => lcLabel(r.total, r.currency, localOf(r.company_code), fmtMoney) },
    ],
  }), [t, dir, incoming]);
  return <ListScreen key={dir} config={cfg} />;
}

export function NewPaymentAction({ dir }: { dir: Dir }) {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  const label = dir === 'I' ? t('bk.newIn') : t('bk.newOut');
  if (!canWrite) return <Button variant="primary" disabled id={`new-payment-${dirPath(dir)}`} disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {label}</Button>;
  return (
    <Link to={`/banking/payments/${dirPath(dir)}/new`} id={`new-payment-${dirPath(dir)}`} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover">
      <Plus className="h-4 w-4" aria-hidden /> {label}
    </Link>
  );
}
export function DraftsLink() {
  const { t } = useTranslation();
  return <Link to="/banking/payment-drafts" id="bk-drafts-link" className="inline-flex min-h-[44px] items-center rounded-btn border border-line bg-surface px-4 text-[15px] font-medium text-ink hover:bg-page">{t('bk.drafts')}</Link>;
}

// ---------- Payment form ----------
let chqSeq = 0;
interface FormCheque extends ChequeInput { key: string }
const newCheque = (): FormCheque => ({ key: `c${++chqSeq}`, cheque_no: '', bank_name: '', due_date: todayIso(), amount: '' });

export function PaymentNewPage() {
  const { dir: dp } = useParams();
  const dir = dirOf(dp);
  return <RequireModule module="banking"><PaymentForm key={dir} dir={dir} /></RequireModule>;
}

function PaymentForm({ dir }: { dir: Dir }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { profile } = useAuth();
  const { canWrite, readOnlyReason } = useModuleLevel('banking');
  const companies = profile?.companies ?? [];
  // A6: Purchasing links here with ?company=&card=&apply=<obj>:<entry>:<amount> to pay a deposit or an A/P invoice.
  const [params] = useSearchParams();
  const defCompany = useDefaultCompany();
  const pre = (params.get('apply') ?? '').split(':');
  const preCard = params.get('card') ?? '';
  const preAmt = pre.length === 3 && Number(pre[2]) > 0 ? String(Number(pre[2])) : '';
  const [company, setCompany] = useState(params.get('company') || defCompany);
  const setup = usePaySetup(company || null, dir);
  const incoming = dir === 'I';
  const [bpText, setBpText] = useState(preCard);
  const [h, setHdr] = useState<Omit<PayHeaderInput, 'cheques'>>({ card_code: preCard, doc_date: todayIso(), memo: '', cash: '', transfer: preAmt, transfer_bank: '', transfer_ref: '', cheque_bank: '', card: '', card_ref: '' });
  const [cheques, setCheques] = useState<FormCheque[]>([]);
  const [apply, setApply] = useState<Record<string, string>>(preAmt ? { [`${pre[0]}:${pre[1]}`]: preAmt } : {});
  const [reason, setReason] = useState('');
  const [reasonErr, setReasonErr] = useState<string | null>(null);
  const [preview, setPreview] = useState<PayEval | null>(null);
  const [attempted, setAttempted] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [series, setSeries] = useState<number | null>(null);
  const docsQ = useOpenDocs(company, dir, h.card_code);
  // B4: the payment is in one currency (the partner's own by default); it pays that currency's documents only.
  const localCur = useLocalCurrency(company);
  const [payCur, setPayCur] = useState('');
  const [fxRate, setFxRate] = useState('');
  const bpCur = docsQ.data?.currency ?? null;
  const cur = payCur || defaultCurrency(bpCur, localCur) || setup.data?.currency || '';
  const docs = { ...docsQ, data: docsQ.data ? { ...docsQ.data, docs: docsQ.data.docs.filter((d) => (d.currency ?? localCur) === cur) } : docsQ.data };
  const otherCurDocs = (docsQ.data?.docs ?? []).filter((d) => (d.currency ?? localCur) !== cur).length;
  const banks = setup.data?.banks ?? [];

  useEffect(() => {
    if (!dirty) return;
    const fn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', fn);
    return () => window.removeEventListener('beforeunload', fn);
  }, [dirty]);
  useEffect(() => { if (banks.length === 1) setHdr((x) => ({ ...x, transfer_bank: x.transfer_bank || banks[0].bank_code, cheque_bank: x.cheque_bank || banks[0].bank_code })); }, [banks]);

  const set = (patch: Partial<typeof h>) => { setHdr((x) => ({ ...x, ...patch })); setDirty(true); };
  const setChq = (key: string, patch: Partial<FormCheque>) => { setCheques((cs) => cs.map((c) => (c.key === key ? { ...c, ...patch } : c))); setDirty(true); };
  const header: PayHeaderInput = { ...h, currency: payCur, fx_rate: fxRate, cheques: cheques.map(({ key: _k, ...c }) => c) }; // eslint-disable-line @typescript-eslint/no-unused-vars
  const lines = (docs.data?.docs ?? []).filter((d) => num(apply[`${d.obj_type}:${d.doc_entry}`] ?? '') !== 0)
    .map((d) => ({ obj_type: d.obj_type, doc_entry: d.doc_entry, amount: apply[`${d.obj_type}:${d.doc_entry}`] }));
  const total = r2(num(h.cash) + num(h.transfer) + cheques.reduce((s, c) => s + num(c.amount), 0) + (incoming ? num(h.card) : 0));
  const applied = r2((docs.data?.docs ?? []).reduce((s, d) => s + d.sign * num(apply[`${d.obj_type}:${d.doc_entry}`] ?? ''), 0));

  const key = JSON.stringify([company, header, lines]);
  useEffect(() => {
    if (!company || !h.card_code) { setPreview(null); return; }
    let live = true;
    const tm = setTimeout(() => { payChecks(company, dir, header, lines).then((r) => { if (live) setPreview(r); }).catch(() => { if (live) setPreview(null); }); }, 400);
    return () => { live = false; clearTimeout(tm); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  const errors = preview?.errors ?? [];
  const shown = attempted ? errors : errors.filter((e) => ['period', 'setup', 'applied'].includes(e.field) || (e.line != null && e.field === 'amount'));
  const checks = preview && !errors.length ? preview.checks : [];
  const needsApproval = checks.length > 0;
  const fieldErr = (f: string) => (attempted ? errors.find((e) => e.field === f && e.line == null)?.message : undefined);
  const lineErr = (i: number) => errors.find((e) => e.line === i + 1)?.message;

  function applyAll() {
    let left = total;
    const next: Record<string, string> = {};
    for (const d of [...(docs.data?.docs ?? [])].sort((a, b) => b.sign - a.sign || a.due_date.localeCompare(b.due_date))) {
      const avail = r2(d.open - d.reserved);
      if (d.sign < 0) { next[`${d.obj_type}:${d.doc_entry}`] = String(avail); left = r2(left + avail); continue; }
      const take = Math.min(avail, left);
      if (take > 0) { next[`${d.obj_type}:${d.doc_entry}`] = String(r2(take)); left = r2(left - take); }
    }
    setApply(next); setDirty(true);
  }

  async function submit() {
    setAttempted(true); setServerError(null); setReasonErr(null);
    if (needsApproval && !reason.trim()) { setReasonErr(t('bk.reasonNeeded')); document.getElementById('bk-reason')?.focus(); return; }
    setBusy(true);
    try {
      const r = await paySubmit(company, dir, header, lines, needsApproval ? reason.trim() : null, series);
      setDirty(false);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      qc.invalidateQueries({ queryKey: ['approval-inbox'] });
      qc.invalidateQueries({ queryKey: ['pay-open'] });
      if (r.state === 'posted') nav(`/banking/payments/${dirPath(dir)}/${company}/${r.doc_entry}`, { state: { flash: t('bk.flash.posted', { no: r.doc_no }) } });
      else nav(`/banking/payment-drafts/${company}/${r.draft_id}`, { state: { flash: t('bk.flash.pending', { names: [...new Set(checks.map((c) => c.approver_name))].join(', ') }) } });
    } catch (e) {
      setServerError(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally { setBusy(false); }
  }

  const back = (e: React.MouseEvent) => { if (dirty && !window.confirm(t('je.leave'))) e.preventDefault(); };
  const listPath = `/banking/payments/${dirPath(dir)}`;
  const listName = incoming ? t('erp.page.paymentsIn') : t('erp.page.paymentsOut');
  const blocked = !canWrite ? readOnlyReason : !setup.data?.numbering && setup.data ? t('bk.noNumbering') : undefined;
  const postReason = blocked ?? (!h.card_code ? (incoming ? t('bk.chooseCustomer') : t('bk.chooseSupplier')) : total <= 0 ? t('bk.enterAmount') : undefined);
  const bpOpts = async (q: string): Promise<Array<ComboOption<BpHit>>> => (await searchPartners(company, incoming ? 'customer' : 'supplier', q)).map((b) => ({
    value: b.card_code, label: `${b.card_code} · ${b.name}`, data: b, meta: [b.currency, b.balance != null ? fmtMoney(b.balance) : null].filter(Boolean).join(' · '),
  }));
  const bankSelect = (id: string, value: string, onChange: (v: string) => void, label: string, err?: string) => (
    <label className="block text-xs font-medium text-muted">{label}
      <select id={id} className={clsx('input mt-1 text-[15px] text-ink', err && 'border-crit-fg')} value={value} onChange={(e) => onChange(e.target.value)} aria-invalid={Boolean(err)}>
        <option value="">{t('bk.chooseBank')}</option>
        {banks.map((b) => <option key={b.bank_code} value={b.bank_code}>{b.bank_code} · {b.name}</option>)}
      </select>
      {err && <span className="mt-1 flex items-start gap-1 text-crit-fg"><AlertCircle className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden />{err}</span>}
    </label>
  );
  const amountInput = (id: string, label: string, value: string, onChange: (v: string) => void, err?: string) => (
    <label className="block text-xs font-medium text-muted">{label}
      <input id={id} inputMode="decimal" className={clsx('input num mt-1 text-end text-[15px] text-ink', err && 'border-crit-fg')} value={value} onChange={(e) => onChange(e.target.value)} placeholder="0.00" aria-invalid={Boolean(err)} />
      {err && <span className="mt-1 flex items-start gap-1 text-crit-fg"><AlertCircle className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden />{err}</span>}
    </label>
  );

  return (
    <div>
      <BkHeader title={incoming ? t('bk.titleNewIn') : t('bk.titleNewOut')} back={[listName, listPath]} onBack={back}
        pills={<span className="pill pill-info">Super ERP</span>} sub={incoming ? t('bk.subNewIn') : t('bk.subNewOut')} />
      <FormError message={serverError} />
      {shown.length > 0 && !serverError && (
        <div role="alert" className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-sm text-crit-fg" data-testid="bk-problems">
          <ul className="list-disc space-y-1 ps-5">{shown.map((p, i) => <li key={i} dir="auto">{p.message}</li>)}</ul>
        </div>
      )}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              {companies.length > 1 && (
                <label className="block text-xs font-medium text-muted">{t('je.company')}
                  <select id="bk-company" className="input mt-1 text-[15px] text-ink" value={company} onChange={(e) => { setCompany(e.target.value); set({ card_code: '' }); setBpText(''); setApply({}); }}>
                    {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
                  </select>
                </label>
              )}
              <div className="sm:col-span-2 xl:col-span-1">
                <Combobox<BpHit> id="bk-bp" label={incoming ? t('erp.col.customer') : t('erp.col.supplier')} required text={bpText}
                  onText={(s) => { setBpText(s); if (h.card_code) { set({ card_code: '' }); setApply({}); } }}
                  search={bpOpts} placeholder={t('bk.bpPh')} error={fieldErr('card_code')}
                  onSelect={(o) => { setBpText(o.label); set({ card_code: o.value }); setApply({}); setPayCur(''); setFxRate(''); }} />
              </div>
              <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
                <input id="bk-date" type="date" className="input num mt-1 text-[15px] text-ink" value={h.doc_date} onChange={(e) => set({ doc_date: e.target.value })} />
              </label>
              {h.card_code && (
                <CurrencyFields company={company} date={h.doc_date} bpCurrency={bpCur} idPrefix="bk" currency={cur} onCurrency={(c) => { setPayCur(c); setApply({}); setDirty(true); }}
                  rate={fxRate} onRate={(r) => { setFxRate(r); setDirty(true); }} errors={{ currency: fieldErr('currency'), fx_rate: fieldErr('fx_rate') }} />
              )}
              <SeriesPicker company={company} obj={incoming ? 24 : 46} value={series} onChange={setSeries} date={h.doc_date} />
              <label className="block text-xs font-medium text-muted sm:col-span-2 xl:col-span-3">{t('erp.col.remarks')}
                <input id="bk-memo" dir="auto" className="input mt-1 text-[15px] text-ink" value={h.memo} onChange={(e) => set({ memo: e.target.value })} />
              </label>
            </div>
            {docs.data && (
              <p className="border-t border-line px-5 py-3 text-sm text-muted" data-testid="bk-bp-info">
                {t('bk.balance', { amount: fmtMoney(docs.data.balance, localCur || cur) })}
                {otherCurDocs > 0 && <span className="ms-2" data-testid="bk-other-cur">{t('cur.otherCurrencyDocs', { n: otherCurDocs })}</span>}
                {docs.data.bank_changed_at && !incoming && <span className="ms-2 pill pill-warning">{t('bk.bankChanged', { when: fmtDay(docs.data.bank_changed_at) })}</span>}
              </p>
            )}
          </SectionCard>

          <SectionCard title={t('bk.means')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
              {amountInput('bk-cash', t('erp.means.cash'), h.cash, (v) => set({ cash: v }), fieldErr('cash'))}
              <div className="hidden sm:block" />
              {amountInput('bk-transfer', t('erp.means.transfer'), h.transfer, (v) => set({ transfer: v }), fieldErr('transfer'))}
              {bankSelect('bk-transfer-bank', h.transfer_bank, (v) => set({ transfer_bank: v }), incoming ? t('bk.transferInto') : t('bk.transferFrom'), fieldErr('transfer_bank'))}
              <label className="block text-xs font-medium text-muted sm:col-span-2">{t('bk.transferRef')}
                <input id="bk-transfer-ref" dir="auto" className="input mt-1 text-[15px] text-ink" value={h.transfer_ref} onChange={(e) => set({ transfer_ref: e.target.value })} />
              </label>
              {incoming && amountInput('bk-card', t('erp.means.card'), h.card, (v) => set({ card: v }), fieldErr('card'))}
              {incoming && (
                <label className="block text-xs font-medium text-muted">{t('bk.cardRef')}
                  <input id="bk-card-ref" dir="auto" className="input mt-1 text-[15px] text-ink" value={h.card_ref} onChange={(e) => set({ card_ref: e.target.value })} />
                </label>
              )}
            </div>
            <div className="border-t border-line p-5">
              <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                <h3 className="text-sm font-semibold">{t('bk.cheques')}</h3>
                <Button variant="secondary" id="bk-add-cheque" onClick={() => { setCheques((cs) => [...cs, newCheque()]); setDirty(true); }}><Plus className="h-4 w-4" aria-hidden /> {t('bk.addCheque')}</Button>
              </div>
              {fieldErr('cheques') && <p className="mb-2 flex items-start gap-1 text-[13px] text-crit-fg"><AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{fieldErr('cheques')}</p>}
              {cheques.length === 0 ? <p className="text-sm text-muted">{t('bk.noCheques')}</p> : (
                <ul className="space-y-3">
                  {cheques.map((c, i) => (
                    <li key={c.key} data-testid="bk-cheque" className="grid grid-cols-2 items-end gap-3 md:grid-cols-[1fr_1fr_150px_130px_44px]">
                      <label className="block text-xs font-medium text-muted">{t('bk.chequeNo', { n: i + 1 })}
                        <input id={`bk-chq-${c.key}-no`} className="input mt-1 font-mono text-[15px] text-ink" value={c.cheque_no} onChange={(e) => setChq(c.key, { cheque_no: e.target.value })} />
                      </label>
                      {incoming ? (
                        <label className="block text-xs font-medium text-muted">{t('bk.drawnOn')}
                          <input id={`bk-chq-${c.key}-bank`} dir="auto" className="input mt-1 text-[15px] text-ink" value={c.bank_name} onChange={(e) => setChq(c.key, { bank_name: e.target.value })} />
                        </label>
                      ) : <div />}
                      <label className="block text-xs font-medium text-muted">{t('erp.col.dueDate')}
                        <input id={`bk-chq-${c.key}-due`} type="date" className="input num mt-1 text-[15px] text-ink" value={c.due_date} onChange={(e) => setChq(c.key, { due_date: e.target.value })} />
                        {c.due_date > h.doc_date && <span className="mt-1 block text-warn-fg">{t('bk.postDated')}</span>}
                      </label>
                      <label className="block text-xs font-medium text-muted">{t('erp.col.amount')}
                        <input id={`bk-chq-${c.key}-amount`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={c.amount} onChange={(e) => setChq(c.key, { amount: e.target.value })} />
                      </label>
                      <div className="flex min-h-[44px] items-center justify-end">
                        <button type="button" onClick={() => { setCheques((cs) => cs.filter((x) => x.key !== c.key)); setDirty(true); }} aria-label={t('bk.removeCheque', { n: i + 1 })}
                          className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg"><Trash2 className="h-4 w-4" aria-hidden /></button>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
              {!incoming && cheques.length > 0 && <div className="mt-3 max-w-sm">{bankSelect('bk-cheque-bank', h.cheque_bank, (v) => set({ cheque_bank: v }), t('bk.chequeBank'), fieldErr('cheque_bank'))}</div>}
            </div>
          </SectionCard>

          <SectionCard title={incoming ? t('bk.openInvoices') : t('bk.openApInvoices')}
            right={docs.data?.docs.length ? <Button variant="secondary" id="bk-apply-all" onClick={applyAll} disabled={total <= 0}>{t('bk.applyAll')}</Button> : undefined}>
            {!h.card_code ? <p className="p-5 text-sm text-muted">{incoming ? t('bk.pickCustomerFirst') : t('bk.pickSupplierFirst')}</p>
              : docs.isLoading ? <p className="p-5 text-sm text-muted">{t('je.checking')}</p>
              : docs.error ? <ErrorState error={docs.error} onRetry={() => docs.refetch()} />
              : (
                <>
                  {docs.data!.docs.length === 0 ? <p className="p-5 text-sm text-muted" data-testid="bk-no-docs">{t('bk.noOpenDocs')}</p> : (
                    <div className="overflow-x-auto">
                      <table className="w-full text-[14px] sm:min-w-[620px]" data-testid="bk-docs">
                        <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                          <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.document')}</th>
                          <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('erp.col.dueDate')}</th>
                          <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('erp.col.total')}</th>
                          <th scope="col" className="px-4 py-2.5 text-end">{t('bk.open')}</th>
                          <th scope="col" className="px-4 py-2.5 text-end">{t('bk.apply')}</th>
                        </tr></thead>
                        <tbody>
                          {docs.data!.docs.map((d, i) => {
                            const k = `${d.obj_type}:${d.doc_entry}`;
                            const idx = lines.findIndex((l) => l.obj_type === d.obj_type && l.doc_entry === d.doc_entry);
                            const err = idx >= 0 ? lineErr(idx) : undefined;
                            return (
                              <tr key={k} data-testid="bk-doc" className={clsx('border-t border-line align-top', err && 'bg-crit-bg/40')}>
                                <td className="px-4 py-2.5">
                                  <div className="font-mono text-[13px] font-medium">{d.doc_no}</div>
                                  <div className="text-xs text-muted">{docLabel(d.obj_type)} · {fmtDay(d.doc_date)}</div>
                                  {d.reserved > 0 && <div className="text-xs text-warn-fg">{t('bk.reserved', { amount: fmtMoney(d.reserved, cur) })}</div>}
                                  {err && <div className="mt-1 text-[13px] text-crit-fg" dir="auto">{err}</div>}
                                </td>
                                <td className={clsx('num px-4 py-2.5 max-sm:hidden', d.due_date < todayIso() && 'font-semibold text-crit-fg')}>{fmtDay(d.due_date)}</td>
                                <td className="num px-4 py-2.5 text-end max-md:hidden">{fmtMoney(d.total)}</td>
                                <td className="num px-4 py-2.5 text-end">{fmtMoney(d.sign * d.open)}</td>
                                <td className="px-4 py-2.5 text-end">
                                  <input id={`bk-apply-${i}`} aria-label={t('bk.applyTo', { no: d.doc_no })} inputMode="decimal" className="input num ms-auto w-32 text-end text-[15px]"
                                    value={apply[k] ?? ''} onChange={(e) => { setApply((a) => ({ ...a, [k]: e.target.value })); setDirty(true); }} placeholder="0.00" />
                                </td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                  )}
                  {docs.data!.other_open > 0 && <p className="border-t border-line px-5 py-3 text-sm text-muted">{t('bk.otherOpen', { n: docs.data!.other_open })}</p>}
                </>
              )}
            <dl className="num ms-auto grid w-full max-w-xs grid-cols-2 gap-x-6 gap-y-1 border-t border-line p-5 text-[15px]" aria-live="polite">
              <dt className="text-muted">{t('bk.paymentTotal')}</dt><dd className="text-end" data-testid="bk-total">{fmtMoney(total)}</dd>
              <dt className="text-muted">{t('bk.applied')}</dt><dd className="text-end" data-testid="bk-applied">{fmtMoney(applied)}</dd>
              <dt className={clsx('text-[17px] font-semibold', applied > total && 'text-crit-fg')}>{t('bk.onAccount', { cur })}</dt>
              <dd className={clsx('text-end text-[17px] font-semibold', applied > total && 'text-crit-fg')} data-testid="bk-on-account">{fmtMoney(r2(total - applied))}</dd>
              {cur !== localCur && preview?.totals?.total_lc != null && !errors.length && (
                <>
                  <dt className="text-muted">{t('cur.totalLc', { cur: localCur })}<span className="block text-xs">{t('cur.atRate', { rate: fmtRate(preview.totals.rate) })}</span></dt>
                  <dd className="text-end text-muted" data-testid="bk-total-lc">{fmtMoney(preview.totals.total_lc, localCur)}</dd>
                </>
              )}
            </dl>
          </SectionCard>
        </div>

        <aside className="min-w-0 space-y-5">
          <SectionCard title={incoming ? t('bk.postTitleIn') : t('bk.postTitleOut')}>
            <div className="space-y-3 p-5">
              {!h.card_code ? <p className="text-sm text-muted">{incoming ? t('bk.pickCustomerFirst') : t('bk.pickSupplierFirst')}</p>
                : !preview ? <p className="text-sm text-muted">{t('je.checking')}</p>
                : errors.length ? <p className="text-sm text-muted" data-testid="bk-preview">{t('je.previewErrors', { count: errors.length })}</p>
                : needsApproval ? (
                  <div data-testid="bk-preview" className="rounded-btn border border-warn-fg/30 bg-warn-bg p-3 text-sm text-warn-fg">
                    <p className="font-semibold">{t('bk.needsApproval')}</p>
                    {[...new Set(checks.map((c) => c.message))].map((m) => <p key={m} dir="auto" className="mt-1">{m}</p>)}
                    <ol className="mt-1 list-decimal space-y-0.5 ps-5">{[...new Map(checks.map((c) => [`${c.step}:${c.approver_position}`, c])).values()].sort((a, b) => a.step - b.step)
                      .map((c) => <li key={`${c.step}${c.approver_position}`}>{t('bk.approverStep', { step: c.step, name: c.approver_name })}</li>)}</ol>
                  </div>
                ) : <p data-testid="bk-preview" className="flex items-center gap-2 rounded-btn bg-ok-bg p-3 text-sm font-medium text-ok-fg"><Check className="h-4 w-4" aria-hidden />{t('bk.postsNow')}</p>}
              {needsApproval && (
                <label className="block text-xs font-medium text-muted">{t('je.reason')} <span className="text-crit-fg">*</span>
                  <textarea id="bk-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} placeholder={t('bk.reasonPh')}
                    onChange={(e) => { setReason(e.target.value); setReasonErr(null); }} aria-invalid={Boolean(reasonErr)} aria-describedby={reasonErr ? 'bk-reason-err' : undefined} />
                  {reasonErr && <span id="bk-reason-err" className="mt-1 block text-crit-fg">{reasonErr}</span>}
                </label>
              )}
              <Button variant="primary" id="bk-submit" className="w-full" onClick={submit} disabled={Boolean(postReason) || busy} disabledReason={postReason}>
                {busy ? t('je.posting') : needsApproval ? t('bk.submitForApproval') : incoming ? t('bk.postIn') : t('bk.postOut')}
              </Button>
              <Link to={listPath} onClick={back} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('je.cancelEdit')}</Link>
            </div>
          </SectionCard>
          {!incoming && setup.data?.my_limit != null && <p className="px-1 text-sm text-muted">{t('bk.myLimit', { amount: fmtMoney(setup.data.my_limit, cur) })}</p>}
          {!incoming && setup.data?.bank_change_days != null && <p className="px-1 text-sm text-muted">{t('bk.bankRule', { n: setup.data.bank_change_days })}</p>}
          {incoming && setup.data?.needs_approval && <p className="px-1 text-sm text-muted" data-testid="bk-in-approval">{setup.data.my_limit != null ? t('bk.inApprovalAbove', { amount: fmtMoney(setup.data.my_limit, cur) }) : t('bk.inApproval')}</p>}
        </aside>
      </div>
    </div>
  );
}

// ---------- Payment record ----------
export function PaymentDetailPage() {
  const { t } = useTranslation();
  const { dir: dp, company = '', entry = '' } = useParams();
  const dir = dirOf(dp);
  const q = usePaymentInfo(company, dir, Number(entry));
  const localCur = useLocalCurrency(company);
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const listName = dir === 'I' ? t('erp.page.paymentsIn') : t('erp.page.paymentsOut');
  const back: [string, string] = [listName, `/banking/payments/${dirPath(dir)}`];
  if (q.isLoading || q.error || !q.data) {
    return (
      <RequireModule module="banking">
        <BkHeader title={entry} back={back} />
        {q.isLoading ? <PageLoading /> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
          : <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>}
      </RequireModule>
    );
  }
  const p = q.data;
  const cur = p.currency ?? '';
  // B4: a foreign-currency payment keeps its own total (total_fc); means and allocations are stored in the company currency.
  const fc = p.total_fc != null;
  const lc = fc ? localCur : cur;
  return (
    <RequireModule module="banking">
      <BkHeader title={`${dir === 'I' ? t('bk.paymentIn') : t('bk.paymentOut')} ${p.doc_no}`} back={back}
        pills={<>
          <span className={clsx('pill', p.cancelled ? 'pill-crit' : 'pill-ok')} data-testid="bk-status">{p.cancelled ? t('erp.status.cancelled') : t('erp.status.posted')}</span>
          <span className={clsx('pill', p.source === 'erp' ? 'pill-info' : 'pill-neutral')}>{sourceName(p.source)}</span><LiveBadge live />
        </>}
        sub={[p.card_code && `${p.card_code} · ${p.card_name ?? ''}`, fmtDay(p.doc_date), p.created_by_name].filter(Boolean).join(' · ')}
        actions={<CancelPaymentAction p={p} onDone={() => { setFlash(t('bk.flash.cancelled')); qc.invalidateQueries({ queryKey: ['erp-list'] }); q.refetch(); }} />} />
      <Flash text={flash} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <Fields items={[
              [dir === 'I' ? t('erp.col.customer') : t('erp.col.supplier'), p.card_code ? `${p.card_code} · ${p.card_name ?? ''}` : '—'],
              [t('erp.col.postingDate'), fmtDay(p.doc_date)],
              [t('bk.paymentTotal'), <span key="t" className="num font-semibold" data-testid="bk-detail-total">{fmtMoney(fc ? p.total_fc : p.total, cur)}</span>],
              ...(fc ? [[t('cur.rateLabel'), <span key="r" className="num" data-testid="bk-detail-rate">{t('cur.currencyRate', { cur, rate: fmtRate(p.fx_rate), local: localCur })}</span>] as [string, ReactNode],
                [t('cur.totalLc', { cur: localCur }), <span key="tl" className="num">{fmtMoney(p.total, localCur)}</span>] as [string, ReactNode],
                [t('cur.fxDiff'), <span key="fx" className="num" data-testid="bk-detail-fx">{Number(p.fx_diff ?? 0) === 0 ? fmtMoney(0, localCur) : `${fmtMoney(Math.abs(Number(p.fx_diff)), localCur)} · ${Number(p.fx_diff) > 0 ? t('cur.gain') : t('cur.loss')}`}</span>] as [string, ReactNode]] : []),
              [t('erp.means.cash'), Number(p.cash) ? fmtMoney(p.cash, lc) : '—'],
              [t('erp.means.transfer'), Number(p.transfer) ? `${fmtMoney(p.transfer, lc)}${p.transfer_bank_name ? ` · ${p.transfer_bank_name}` : ''}${p.transfer_ref ? ` · ${p.transfer_ref}` : ''}` : '—'],
              [t('erp.means.cheque'), Number(p.cheque) ? fmtMoney(p.cheque, lc) : '—'],
              [t('erp.means.card'), Number(p.card) ? `${fmtMoney(p.card, lc)}${p.card_ref ? ` · ${p.card_ref}` : ''}` : '—'],
              [t('bk.onAccountShort'), <span key="oa" data-testid="bk-detail-on-account">{fmtMoney(fc ? p.on_account_fc ?? 0 : p.on_account ?? 0, cur)}</span>],
              [t('erp.col.remarks'), p.memo],
              [t('erp.col.source'), sourceName(p.source)],
              [t('bk.journal'), p.trans_id ? (p.can_read_journal ? <Link key="j" id="bk-journal-link" className="text-primary hover:underline" to={`/financials/journals/${p.company_code}/${p.trans_id}`}>{p.trans_id}</Link> : String(p.trans_id)) : '—'],
              ...(p.draft_id ? [[t('bk.fromDraft'), <Link key="d" className="text-primary hover:underline" to={`/banking/payment-drafts/${p.company_code}/${p.draft_id}`}>{t('bk.draftN', { n: p.draft_id })}</Link>] as [string, ReactNode]] : []),
              ...(p.cancelled && p.cancel_trans_id ? [[t('bk.cancelledBy'), <span key="c">{fmtWhen(p.cancelled_at)} · {p.can_read_journal ? <Link className="text-primary hover:underline" to={`/financials/journals/${p.company_code}/${p.cancel_trans_id}`}>{p.cancel_trans_id}</Link> : p.cancel_trans_id} · “{p.cancel_note}”</span>] as [string, ReactNode]] : []),
            ]} />
          </SectionCard>
          <SectionCard title={t('bk.allocations')}>
            {p.allocations.length === 0 ? <p className="p-5 text-sm text-muted">{t('bk.noAllocations')}</p> : (
              <div className="overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="bk-allocations">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.document')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('erp.col.total')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('bk.applied')}</th>
                  </tr></thead>
                  <tbody>
                    {p.allocations.map((a) => {
                      const to = docLink(a.obj_type, p.company_code, a.doc_entry);
                      return (
                        <tr key={a.line_no} className="border-t border-line">
                          <td className="px-4 py-2.5">{to ? <Link className="font-mono text-[13px] text-primary hover:underline" to={to}>{a.doc_no ?? a.doc_entry}</Link> : <span className="font-mono text-[13px]">{a.doc_no ?? a.doc_entry}</span>}
                            <div className="text-xs text-muted">{docLabel(a.obj_type)}{a.doc_date ? ` · ${fmtDay(a.doc_date)}` : ''}</div></td>
                          <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(a.doc_total)}</td>
                          <td className="num px-4 py-2.5 text-end">{fmtMoney(([14, 19].includes(a.obj_type) ? -1 : 1) * Number(fc ? a.applied_fc ?? a.applied : a.applied), cur)}{fc && <span className="block text-xs text-muted">{fmtMoney(([14, 19].includes(a.obj_type) ? -1 : 1) * Number(a.applied), localCur)}</span>}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </SectionCard>
          {p.cheques.length > 0 && (
            <SectionCard title={t('bk.cheques')}>
              <div className="overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="bk-cheques">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('bk.chequeCol')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.dueDate')}</th>
                    <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('erp.col.status')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.amount')}</th>
                  </tr></thead>
                  <tbody>
                    {p.cheques.map((c) => (
                      <tr key={c.cheque_id} className="border-t border-line">
                        <td className="px-4 py-2.5"><span className="font-mono text-[13px]">{c.cheque_no}</span><div className="text-xs text-muted">{c.bank_name}</div></td>
                        <td className="num px-4 py-2.5">{fmtDay(c.due_date)} {c.post_dated && <span className="pill pill-warning">{t('bk.pdc')}</span>}</td>
                        <td className="px-4 py-2.5 max-sm:hidden">{p.direction === 'O' ? <span className="pill pill-neutral">{t('bk.issued')}</span> : c.deposit_no ? <span className="pill pill-ok">{t('bk.depositedIn', { no: c.deposit_no })}</span> : <span className="pill pill-info">{t('bk.onHand')}</span>}</td>
                        <td className="num px-4 py-2.5 text-end">{fmtMoney(c.amount)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </SectionCard>
          )}
        </div>
        <aside className="min-w-0 space-y-5"><ActivityCard items={p.activity} /></aside>
      </div>
    </RequireModule>
  );
}

function CancelPaymentAction({ p, onDone }: { p: { company_code: string; direction: Dir; doc_entry: number; doc_no: string; doc_date: string; can_cancel: boolean; cancel_block: string | null; source: string }; onDone: () => void }) {
  const { t } = useTranslation();
  const { readOnlyReason } = useModuleLevel('banking');
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(todayIso() < p.doc_date ? p.doc_date : todayIso());
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  if (!p.can_cancel) {
    const why = p.cancel_block === 'read_only' ? readOnlyReason : p.cancel_block ?? undefined;
    return <Button variant="secondary" id="bk-cancel-payment" disabled disabledReason={why} icon={<X className="h-4 w-4" aria-hidden />}>{t('bk.cancelPayment')}</Button>;
  }
  async function go() {
    setErr(null);
    if (!reason.trim()) { setErr(t('bk.cancelReasonNeeded')); return; }
    setBusy(true);
    try { await payCancel(p.company_code, p.direction, p.doc_entry, date, reason.trim()); setOpen(false); onDone(); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <>
      <Button variant="danger" id="bk-cancel-payment" onClick={() => { setOpen(true); setErr(null); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('bk.cancelPayment')}</Button>
      <Dialog open={open} title={t('bk.cancelTitle', { no: p.doc_no })} onClose={() => setOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="bk-cancel-confirm" disabled={busy} onClick={go}>{t('bk.cancelPayment')}</Button></>}>
        <p className="text-sm text-ink-2">{t('bk.cancelBody')}</p>
        <label className="block text-xs font-medium text-muted">{t('bk.cancelDate')} <span className="text-crit-fg">*</span>
          <input id="bk-cancel-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} min={p.doc_date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <label className="block text-xs font-medium text-muted">{t('bk.cancelReason')} <span className="text-crit-fg">*</span>
          <textarea id="bk-cancel-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
        {err && <p role="alert" className="text-sm text-crit-fg" dir="auto">{err}</p>}
      </Dialog>
    </>
  );
}

// ---------- Payment drafts (waiting for approval) ----------
export function PaymentDraftsPage() {
  const { t } = useTranslation();
  const m = moduleByKey('banking')!;
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'payment_draft_list', table: 'payment_draft_list',
    select: 'company_code,draft_id,direction,doc_date,card_code,card_name,total,currency,state,reason,created_at,doc_entry',
    searchCols: ['card_code', 'card_name', 'reason'], numberSearchCols: ['draft_id'], searchLabel: t('bk.searchDrafts'),
    filters: [{ key: 'state', label: t('erp.col.status'), options: (['pending_approval', 'posted', 'rejected', 'cancelled'] as const).map((s) => [s, t(`bk.state.${s}`)]) }],
    defaultSort: { col: 'created_at', asc: false },
    rowKey: (r) => `${r.company_code}|${r.draft_id}`,
    rowLink: (r) => `/banking/payment-drafts/${r.company_code}/${r.draft_id}`,
    emptyTitle: t('bk.draftsEmpty'), emptyBody: t('bk.draftsEmptyBody'),
    columns: [
      { key: 'draft_id', header: t('bk.col.draft'), mono: true },
      { key: 'doc_date', header: t('erp.col.postingDate'), cell: (r) => fmtDay(r.doc_date), csv: (r) => r.doc_date },
      { key: 'card_name', header: t('erp.col.supplier'), cell: (r) => <span><span className="font-mono text-[13px] text-muted">{r.card_code}</span> {r.card_name}</span> },
      { key: 'reason', header: t('je.reason'), hideBelow: 'lg' },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <DraftStatePill state={r.state} />, csv: (r) => r.state },
      { key: 'total', header: t('erp.col.total'), align: 'end', cell: (r) => fmtMoney(r.total, r.currency) },
    ],
  }), [t]);
  return (
    <RequireModule module="banking">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/banking'], [t('erp.page.paymentsOut'), '/banking/payments/out'], [t('bk.drafts'), undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{t('bk.drafts')} <LiveBadge live /></span>} desc={t('bk.draftsDesc')} actions={<NewPaymentAction dir="O" />} />
      <ListScreen config={cfg} />
    </RequireModule>
  );
}

export function PaymentDraftPage() {
  const { t } = useTranslation();
  const { company = '', id = '' } = useParams();
  const q = useDraftInfo(company, Number(id));
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const back: [string, string] = [t('bk.drafts'), '/banking/payment-drafts'];
  if (q.isLoading || q.error || !q.data) {
    return (
      <RequireModule module="banking">
        <BkHeader title={t('bk.draftN', { n: id })} back={back} />
        {q.isLoading ? <PageLoading /> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
          : <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>}
      </RequireModule>
    );
  }
  const d = q.data;
  const refresh = (msg: string) => { setFlash(msg); qc.invalidateQueries({ queryKey: ['approval-inbox'] }); qc.invalidateQueries({ queryKey: ['erp-list'] }); q.refetch(); };
  const cur = d.currency ?? '';
  return (
    <RequireModule module="banking">
      <BkHeader title={t('bk.draftN', { n: d.draft_id })} back={back}
        pills={<><DraftStatePill state={d.state} /><span className="pill pill-info">Super ERP</span><LiveBadge live /></>}
        sub={[`${d.card_code} · ${d.card_name ?? ''}`, fmtMoney(d.total, cur), d.created_by_name, fmtWhen(d.created_at)].filter(Boolean).join(' · ')}
        actions={<>
          {d.doc_entry && <Link to={`/banking/payments/${dirPath(d.direction)}/${d.company_code}/${d.doc_entry}`} id="bk-open-posted" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover"><FileText className="h-4 w-4" aria-hidden />{t('bk.openPosted', { no: d.doc_no })}</Link>}
          {d.can_cancel && <CancelDraftAction d={d} onDone={() => refresh(t('bk.flash.draftCancelled'))} />}
        </>} />
      <Flash text={flash} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <Fields items={[[t('erp.col.supplier'), `${d.card_code} · ${d.card_name ?? ''}`], [t('erp.col.postingDate'), fmtDay(d.doc_date)],
              [t('bk.paymentTotal'), fmtMoney(d.total, cur)], [t('erp.means.transfer'), Number(d.header.transfer) ? `${fmtMoney(d.header.transfer, cur)} · ${d.header.transfer_bank ?? ''}` : '—'],
              [t('erp.means.cheque'), Number(d.header.cheque_total) ? `${fmtMoney(d.header.cheque_total, cur)} · ${d.header.cheques.map((c) => c.cheque_no).join(', ')}` : '—'],
              [t('erp.means.cash'), Number(d.header.cash) ? fmtMoney(d.header.cash, cur) : '—'], [t('erp.col.remarks'), d.header.memo]]} />
          </SectionCard>
          <SectionCard title={t('bk.allocations')}>
            {d.lines.length === 0 ? <p className="p-5 text-sm text-muted">{t('bk.noAllocations')}</p> : (
              <ul className="divide-y divide-line">
                {d.lines.map((l) => <li key={`${l.obj_type}-${l.doc_entry}`} className="flex justify-between gap-3 px-5 py-3 text-[14px]"><span><span className="font-mono text-[13px]">{l.doc_no}</span> <span className="text-xs text-muted">{docLabel(l.obj_type)}</span></span><span className="num">{fmtMoney(l.sign * l.amount)}</span></li>)}
              </ul>
            )}
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <DraftApprovalPanel d={d} onDone={refresh} />
          <ActivityCard items={d.activity} />
        </aside>
      </div>
    </RequireModule>
  );
}

function CancelDraftAction({ d, onDone }: { d: DraftInfo; onDone: () => void }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    setErr(null);
    if (!note.trim()) { setErr(t('bk.draftCancelNoteNeeded')); return; }
    setBusy(true);
    try { await payDraftCancel(d.company_code, d.draft_id, note.trim()); setOpen(false); onDone(); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <>
      <Button variant="danger" id="bk-draft-cancel" onClick={() => { setOpen(true); setErr(null); }}>{t('bk.cancelDraft')}</Button>
      <Dialog open={open} title={t('bk.cancelDraftTitle', { n: d.draft_id })} onClose={() => setOpen(false)}
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="bk-draft-cancel-confirm" disabled={busy} onClick={go}>{t('bk.cancelDraft')}</Button></>}>
        <label className="block text-xs font-medium text-muted">{t('je.note')} <span className="text-crit-fg">*</span>
          <textarea id="bk-draft-cancel-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        {err && <p role="alert" className="text-sm text-crit-fg" dir="auto">{err}</p>}
      </Dialog>
    </>
  );
}

function DraftApprovalPanel({ d, onDone }: { d: DraftInfo; onDone: (msg: string) => void }) {
  const { t } = useTranslation();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejOpen, setRejOpen] = useState(false);
  const [note, setNote] = useState('');
  const [noteErr, setNoteErr] = useState<string | null>(null);
  const live = d.approvals.filter((a) => !a.superseded || a.decision);
  const steps = [...new Map(live.map((a) => [`${a.step}:${a.approver_position}`, a])).values()].sort((a, b) => a.step - b.step);
  const msgs = [...new Set((d.checks ?? []).map((c) => c.message))];

  async function decide(decision: 'approved' | 'rejected') {
    setErr(null);
    if (decision === 'rejected' && !note.trim()) { setNoteErr(t('bk.rejectNoteNeeded')); return; }
    setBusy(true);
    try {
      const r = await payDecide(d.company_code, d.draft_id, decision, decision === 'rejected' ? note.trim() : null);
      setRejOpen(false);
      onDone(decision === 'rejected' ? (r.state === 'pending_approval' ? t('apr.flash.rejectionRecorded') : t('bk.flash.rejected')) : r.state === 'posted' ? t('bk.flash.approvedPosted', { no: r.doc_no }) : t('bk.flash.stepApproved'));
    } catch (e) {
      const m = errorMessage(e);
      if (decision === 'rejected') setNoteErr(m); else setErr(m);
    } finally { setBusy(false); }
  }

  const stepList = (
    <ol className="space-y-2" data-testid="bk-steps">
      {steps.map((a) => (
        <li key={a.approval_id} className="flex items-start gap-2 text-sm">
          {a.decision === 'approved' ? <CircleCheck className="mt-0.5 h-4 w-4 shrink-0 text-ok-fg" aria-hidden /> : a.decision === 'rejected' ? <CircleX className="mt-0.5 h-4 w-4 shrink-0 text-crit-fg" aria-hidden />
            : <span className={clsx('mt-1 h-3 w-3 shrink-0 rounded-full border-2', a.current ? 'border-warn-fg' : 'border-line-strong')} aria-hidden />}
          <div>
            <p><span className="font-medium">{t('bk.stepN', { n: a.step })}</span> · {a.approver_position_name} <span className="text-xs text-muted">({t(`so.rule.${a.rule_code}`)})</span></p>
            {a.decision && <p className="text-xs text-muted">{t(a.decision === 'approved' ? 'bk.approvedByWhen' : 'bk.rejectedByWhen', { name: a.decided_by_name ?? '—', when: fmtWhen(a.decided_at) })}</p>}
            {a.note && <p dir="auto" className="text-xs italic text-ink-2">“{a.note}”</p>}
          </div>
        </li>
      ))}
    </ol>
  );

  if (d.can_decide) {
    return (
      <section className="card overflow-hidden border-warn-fg/40" data-testid="bk-approval-card">
        <div className="border-b border-line bg-warn-bg px-5 py-3"><h2 className="text-[15px] font-semibold text-warn-fg">{t('bk.approvalNeeded')}</h2></div>
        <div className="space-y-3 p-5">
          {err && <p role="alert" className="flex items-start gap-2 text-sm text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="bk-decide-error">{err}</span></p>}
          {msgs.map((m) => <p key={m} dir="auto" className="text-sm font-medium">{m}</p>)}
          {stepList}
          <p className="text-sm text-muted">{t('je.requested', { name: d.created_by_name ?? '—', when: fmtWhen(d.created_at) })}</p>
          {d.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 text-[15px] italic text-ink-2">“{d.reason}”</blockquote>}
          <div className="flex flex-col gap-2 pt-1">
            <Button variant="success" id="bk-approve" className="w-full" disabled={busy} onClick={() => decide('approved')} icon={<Check className="h-4 w-4" aria-hidden />}>{t('bk.approve')}</Button>
            <Button variant="danger" id="bk-reject" className="w-full" disabled={busy} onClick={() => { setRejOpen(true); setNoteErr(null); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('je.reject')}</Button>
          </div>
        </div>
        <Dialog open={rejOpen} title={t('bk.rejectTitle', { n: d.draft_id })} onClose={() => setRejOpen(false)}
          footer={<><Button variant="secondary" onClick={() => setRejOpen(false)}>{t('je.keep')}</Button><Button variant="danger" id="bk-reject-confirm" disabled={busy} onClick={() => decide('rejected')}>{t('je.reject')}</Button></>}>
          <label className="block text-xs font-medium text-muted">{t('je.rejectNote')} <span className="text-crit-fg">*</span>
            <textarea id="bk-reject-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => { setNote(e.target.value); setNoteErr(null); }} />
          </label>
          {noteErr && <p role="alert" className="text-sm text-crit-fg" dir="auto">{noteErr}</p>}
        </Dialog>
      </section>
    );
  }
  return (
    <SectionCard title={t('je.status')}>
      <div className="space-y-3 p-5 text-sm" data-testid="bk-status-card">
        {d.state === 'pending_approval' && <p className="font-semibold text-warn-fg">{t('je.waitingFor', { names: [...new Set(steps.filter((a) => a.current).map((a) => a.approver_position_name))].join(', ') })}</p>}
        {d.state === 'pending_approval' && <ApprovalStageNote items={steps.filter((a) => a.current)} />}
        {d.state === 'posted' && <p className="flex items-center gap-2 font-semibold text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{t('bk.postedAfterApproval', { no: d.doc_no })}</p>}
        {d.state === 'rejected' && <p className="flex items-center gap-2 font-semibold text-crit-fg"><CircleX className="h-4 w-4" aria-hidden />{t('bk.state.rejected')}</p>}
        {d.state === 'cancelled' && <><p className="font-semibold text-crit-fg">{t('je.cancelledAt', { when: fmtWhen(d.cancelled_at) })}</p>{d.cancel_note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{d.cancel_note}”</blockquote>}</>}
        {msgs.map((m) => <p key={m} dir="auto" className="text-ink-2">{m}</p>)}
        {stepList}
        {d.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{d.reason}”</blockquote>}
        {d.is_creator && d.state === 'pending_approval' && <p className="text-muted">{t('bk.youCantApprove')}</p>}
      </div>
    </SectionCard>
  );
}
