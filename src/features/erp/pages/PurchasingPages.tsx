import { Fragment, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, Check, ChevronRight, CircleCheck, CircleX, Pencil, Plus, Trash2, X } from 'lucide-react';
import { erp, supabase } from '@/lib/supabase';
import { ApiError, errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, SectionCard, StatusTag, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { SeriesPicker } from '../components/SeriesPicker';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { DOC_KINDS, moduleByKey, type DocKind } from '../modules';
import type { WorkflowState } from '../salesOrder';
import { FormError, Flash, fmtWhen, useDefaultCompany, useFlash } from './BankingPages';
import { SourcePill, StatePill, sourceLabel, today } from './SalesOrderPages';
import { AskAiDocCard } from '../components/AskAi';
import {
  PURCHASE_OBJ, VIEW_OBJ, apInvoiceCreate, depositCreate, grpoCreate, grpoLines, lcCodeSave, lcCreate, lcPreview, piSave, puCancel, puChecks, puCompare,
  puCopySource, puDecide, puListSave, puSave, puSettingSet, puSubmit, purchaseKindOfObj, qcSave, searchBuyItems, searchSuppliers, shipmentSave,
  useLcInfo, usePuFlow, usePuInfo, usePuLists, usePuSetup, usePuView,
  type LcEval, type PuCheck, type PuCopyLine, type PuEval, type PuHeaderInput, type PuInfo, type PuLineInput, type PurchaseKind, type PurchaseViewKind,
  type SupplierHit,
} from '../purchasing';
import { ApprovalStageNote } from '../components/ApprovalStageNote';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const r2 = (n: number) => Math.round(n * 100) / 100;
const num = (s: string) => (s.trim() === '' ? 0 : Number(s) || 0);
const linkBtn = 'inline-flex min-h-[44px] items-center gap-2 rounded-btn px-4 text-[15px] font-medium';
const primaryLink = `${linkBtn} bg-primary text-white hover:bg-primary-hover`;
const secondaryLink = `${linkBtn} border border-line bg-surface text-ink hover:bg-page`;

// ---------- Shared pieces ----------
/** Header for purchasing documents: back link, breadcrumb (Home › 04 Purchasing › list › record), title with pills, one line, actions. */
export function PuHeader({ kind, title, pills, sub, actions, listTo, listLabel }: {
  kind?: DocKind; title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode; listTo?: string; listLabel?: string;
}) {
  const { t } = useTranslation();
  const m = moduleByKey('purchasing')!;
  const to = listTo ?? (kind ? `/docs/${kind}` : '/m/purchasing');
  const label = listLabel ?? (kind ? t(`erp.doc.${kind}`) : m.title);
  return (
    <header className="mb-4">
      <Link to={to} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('pu.back')}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/purchasing'], [label, to], [title, undefined]]} />
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

function PuTotals({ net, vat, total, currency, extra }: { net: number; vat: number; total: number; currency: string; extra?: Array<[string, ReactNode]> }) {
  const { t } = useTranslation();
  return (
    <dl className="num ms-auto grid w-full max-w-xs grid-cols-2 gap-x-6 gap-y-1 border-t border-line p-5 text-[15px] sm:border-t-0">
      <dt className="text-muted">{t('pu.totals.net')}</dt><dd className="text-end">{fmtMoney(net)}</dd>
      <dt className="text-muted">{t('pu.totals.vat')}</dt><dd className="text-end">{fmtMoney(vat)}</dd>
      {extra?.map(([k, v]) => <Fragment key={k}><dt className="text-muted">{k}</dt><dd className="text-end">{v}</dd></Fragment>)}
      <dt className="text-[17px] font-semibold">{t('pu.totals.total', { cur: currency })}</dt><dd className="text-end text-[17px] font-semibold" data-testid="pu-total">{fmtMoney(total)}</dd>
    </dl>
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

const docPath = (obj: number, company: string, entry: number) => {
  const k = purchaseKindOfObj(obj);
  return k ? `/docs/${k}/${company}/${entry}` : undefined;
};

type FlowStep = 'request' | 'quotation' | 'order' | 'deposit' | 'qc' | 'shipment' | 'grpo' | 'invoice' | 'landed';
const STEPS: FlowStep[] = ['request', 'quotation', 'order', 'deposit', 'qc', 'shipment', 'grpo', 'invoice', 'landed'];
const STEP_OF_OBJ: Record<number, FlowStep> = { 1470000113: 'request', 540000006: 'quotation', 22: 'order', 204: 'deposit', 20: 'grpo', 18: 'invoice', 69: 'landed' };

/**
 * Document flow strip for the China flow (spec §4.4): Request → Quotation → PO → PI/Deposit → QC → Shipment → GRPO → A/P invoice →
 * Landed costs, from erp.purchase_doc_flow. Done steps are green with links, the current step is indigo, future steps grey.
 */
export function PuFlowStrip({ company, obj, entry, current }: { company?: string; obj: number; entry?: number | null; current?: FlowStep }) {
  const { t } = useTranslation();
  const flow = usePuFlow(company ?? '', obj, entry ?? 0, Boolean(company && entry));
  const F = flow.data;
  const cur = current ?? STEP_OF_OBJ[obj] ?? 'order';
  const items = (s: FlowStep): Array<{ key: string; label: string; to?: string; here?: boolean }> => {
    if (!F || !company) return [];
    const docs = (o: number) => F.docs.filter((d) => d.obj_type === o).map((d) => ({ key: `${o}-${d.doc_entry}`, label: d.doc_no, to: d.current ? undefined : docPath(o, company, d.doc_entry), here: d.current }));
    const po = F.docs.find((d) => d.obj_type === 22);
    const poTo = po ? `${docPath(22, company, po.doc_entry)}#china` : undefined;
    switch (s) {
      case 'request': return docs(1470000113);
      case 'quotation': return docs(540000006);
      case 'order': return docs(22);
      case 'deposit': return [...(F.pis ?? []).map((p) => ({ key: `pi-${p.pi_id}`, label: `PI ${p.vendor_pi_no}`, to: poTo })), ...docs(204)];
      case 'qc': return (F.qcs ?? []).slice(-1).map((q) => ({ key: `qc-${q.qc_id}`, label: t(`pu.qc.result.${q.result}`), to: poTo }));
      case 'shipment': return (F.shipments ?? []).map((x) => ({ key: `sh-${x.shipment_id}`, label: x.container_no ?? `#${x.shipment_id}`, to: poTo }));
      case 'grpo': return docs(20);
      case 'invoice': return docs(18);
      case 'landed': return (F.landed_costs ?? []).map((l) => ({ key: `lc-${l.doc_entry}`, label: l.doc_no, to: l.current ? undefined : `/purchasing/landed-costs/${company}/${l.doc_entry}` }));
    }
  };
  return (
    <ol className="mb-5 flex flex-wrap items-center gap-1.5" aria-label={t('so.flow.label')} data-testid="pu-flow">
      {STEPS.map((s, i) => {
        const mine = items(s);
        const isCur = s === cur;
        const done = !isCur && mine.length > 0;
        const tone = isCur ? 'border-primary bg-primary-soft text-primary-text' : done ? 'border-ok-fg/30 bg-ok-bg text-ok-fg' : 'border-line bg-surface text-muted';
        return (
          <li key={s} className="flex items-center gap-1.5">
            {i > 0 && <ChevronRight className="h-3.5 w-3.5 text-muted rtl:rotate-180" aria-hidden />}
            <span aria-current={isCur ? 'step' : undefined} data-step={s} data-state={isCur ? 'current' : done ? 'done' : 'future'}
              className={clsx('inline-flex min-h-[32px] flex-wrap items-center gap-x-1.5 rounded-full border px-3 text-[13px] font-medium', tone)}>
              {t(`pu.flow.${s}`)}
              {mine.map((d, k) => (
                <Fragment key={d.key}>
                  {k > 0 && <span aria-hidden>,</span>}
                  {d.to ? <Link to={d.to} className="font-mono text-[12px] underline-offset-2 hover:underline">{d.label}</Link> : <span className="font-mono text-[12px]">{d.label}</span>}
                </Fragment>
              ))}
            </span>
          </li>
        );
      })}
    </ol>
  );
}

function ActivityCard({ items }: { items: Array<{ at: string; action: string; actor_name: string; detail: Record<string, unknown> | null }> }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('so.activity.title')}>
      {items.length === 0 ? <p className="p-5 text-sm text-muted">{t('so.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid="pu-activity">
          {items.map((a, i) => {
            const det = (a.detail ?? {}) as R;
            const verb = a.action.endsWith('_submit') ? (det.result === 'approved' ? 'submit_open' : 'submit_pending') : a.action;
            return (
              <li key={i} className="flex gap-3">
                <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', /approve|pass/.test(a.action) || det.result === 'pass' ? 'bg-ok-fg' : /reject|cancel/.test(a.action) ? 'bg-crit-fg' : 'bg-primary')} aria-hidden />
                <div className="min-w-0 text-sm">
                  <p><span className="font-medium">{a.actor_name}</span> {t(`pu.activity.${verb.replace(/^purchase_(request|quotation|order)_/, '')}`, { defaultValue: a.action.replace(/_/g, ' '), ...det,
                    result: det.result ? t(`pu.qc.result.${det.result}`, { defaultValue: String(det.result) }) : undefined, eta: det.eta ? fmtDay(det.eta) : undefined })}</p>
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

// ---------- Request / quotation / order form ----------
interface FormLine extends PuLineInput { key: string; text: string; baseNo?: string | null; baseOpen?: number | null }
let lineSeq = 0;
const newLine = (tax: string): FormLine => ({ key: `l${++lineSeq}`, item_code: '', qty: '1', price: '', tax_code: tax, cbm: '', text: '' });
const emptyHeader = (): PuHeaderInput => ({ card_code: '', doc_date: today(), due_date: '', whs_code: '', china_office: '', payment_terms: '', customer_ref: '', comments: '' });

export function PurchaseDocNewPage({ kind }: { kind: PurchaseKind }) {
  const { t } = useTranslation();
  const [params] = useSearchParams();
  const def = useDefaultCompany();
  const company = params.get('company') || def;
  const from = Number(params.get('from')) || null;
  const fromObj = Number(params.get('fromObj')) || null;
  const src = useQuery({ queryKey: ['pu-copy', company, fromObj, from], enabled: Boolean(company && from && fromObj), queryFn: () => puCopySource(company, fromObj!, from) });
  if (from && src.isLoading) return <RequireModule module="purchasing"><PageLoading /></RequireModule>;
  if (from && src.error) return <RequireModule module="purchasing"><PuHeader kind={kind} title={t(`pu.new.${kind}`)} /><div className="card"><ErrorState error={src.error} onRetry={() => src.refetch()} /></div></RequireModule>;
  const S = src.data;
  const initial = S?.header ? {
    entry: null, docNo: null, supplierText: kind === 'purchase_order' && S.header.card_code ? `${S.header.card_code} · ${S.header.card_name ?? ''}` : '',
    header: { ...emptyHeader(), card_code: kind === 'purchase_order' ? S.header.card_code ?? '' : '', whs_code: S.header.whs_code ?? '', china_office: S.header.china_office ?? '',
      due_date: kind === 'purchase_order' ? '' : S.header.due_date ?? '' },
    lines: S.lines.map((l) => ({ key: `l${++lineSeq}`, item_code: l.item_code, text: `${l.item_code} · ${l.description ?? ''}`, qty: String(Number(l.open_qty)),
      price: kind === 'purchase_order' && l.price != null ? String(Number(l.price)) : '', tax_code: l.tax_code ?? '', whs_code: l.whs_code ?? '', cbm: l.cbm != null ? String(Number(l.cbm)) : '',
      base_obj_type: l.base_obj_type, base_doc_entry: l.base_doc_entry, base_line: l.base_line, baseNo: l.base_doc_no, baseOpen: Number(l.open_qty) })),
    baseNo: S.header.doc_no,
  } : undefined;
  return <RequireModule module="purchasing"><PurchaseDocForm kind={kind} company={company} initial={initial} /></RequireModule>;
}

export function PurchaseDocEditPage({ kind }: { kind: PurchaseKind }) {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const obj = PURCHASE_OBJ[kind];
  const q = useQuery({
    queryKey: ['pu-edit', company, obj, id],
    queryFn: async () => {
      const [{ data: d, error: e1 }, { data: ls, error: e2 }, { data: w, error: e3 }] = await Promise.all([
        erp().from('document').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).maybeSingle(),
        erp().from('document_line').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).order('line_num'),
        erp().from('doc_workflow').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).maybeSingle(),
      ]);
      if (e1 || e2 || e3) throw new ApiError((e1 ?? e2 ?? e3)!);
      return { d: d as R | null, ls: (ls ?? []) as R[], w: w as R | null };
    },
  });
  if (q.isLoading) return <RequireModule module="purchasing"><PageLoading /></RequireModule>;
  if (q.error || !q.data?.d) return <RequireModule module="purchasing"><PuHeader kind={kind} title={t(`erp.doc.${kind}`)} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} />}</div></RequireModule>;
  const { d, ls, w } = q.data;
  const initial = {
    entry: id, docNo: w?.doc_no ?? String(d!.doc_num), supplierText: d!.card_code ? `${d!.card_code} · ${d!.card_name ?? ''}` : '',
    header: { card_code: d!.card_code ?? '', doc_date: d!.doc_date, due_date: d!.due_date ?? '', whs_code: w?.whs_code ?? '', china_office: w?.china_office ?? '',
      payment_terms: w?.payment_terms ?? '', customer_ref: d!.customer_ref ?? '', comments: d!.comments ?? '' } as PuHeaderInput,
    lines: ls.map((l) => ({ key: `l${++lineSeq}`, item_code: l.item_code, text: `${l.item_code} · ${l.description ?? ''}`, qty: String(Number(l.quantity)),
      price: l.price != null && obj !== 1470000113 ? String(Number(l.price)) : '', tax_code: l.tax_code ?? '', whs_code: l.whs_code ?? '', cbm: l.cbm != null ? String(Number(l.cbm)) : '',
      base_obj_type: l.base_obj_type, base_doc_entry: l.base_doc_entry, base_line: l.base_line })),
  };
  return <RequireModule module="purchasing"><PurchaseDocForm kind={kind} company={company} initial={initial} /></RequireModule>;
}

function PurchaseDocForm({ kind, company, initial }: {
  kind: PurchaseKind; company: string;
  initial?: { entry: number | null; docNo: string | null; supplierText: string; header: PuHeaderInput; lines: FormLine[]; baseNo?: string };
}) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const obj = PURCHASE_OBJ[kind];
  const isReq = kind === 'purchase_request';
  const isPo = kind === 'purchase_order';
  const setup = usePuSetup(company || null);
  const S = setup.data;
  const { canWrite, readOnlyReason } = useModuleLevel('purchasing');
  const allowed = isReq ? Boolean(S?.can_request) : canWrite;
  const [h, setH] = useState<PuHeaderInput>(initial?.header ?? emptyHeader());
  const [supText, setSupText] = useState(initial?.supplierText ?? '');
  const [lines, setLines] = useState<FormLine[]>(initial?.lines ?? []);
  const [entry, setEntry] = useState<number | null>(initial?.entry ?? null);
  const [series, setSeries] = useState<number | null>(null);
  const [preview, setPreview] = useState<PuEval | null>(null);
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [attempted, setAttempted] = useState(false);

  useEffect(() => {
    if (!S) return;
    setH((x) => ({ ...x, whs_code: x.whs_code || S.default_whs_code || '' }));
    setLines((ls) => (ls.length ? ls.map((l) => ({ ...l, tax_code: l.tax_code || S.default_tax_code || '' })) : [newLine(S.default_tax_code ?? '')]));
  }, [S]);
  useEffect(() => {
    if (!dirty) return;
    const fn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', fn);
    return () => window.removeEventListener('beforeunload', fn);
  }, [dirty]);
  const filled = lines.filter((l) => l.item_code);
  const key = JSON.stringify([h, filled.map(({ text: _t, key: _k, ...l }) => l)]); // eslint-disable-line @typescript-eslint/no-unused-vars
  useEffect(() => {
    if (!company || !filled.length) { setPreview(null); return; }
    let live = true;
    const tm = setTimeout(() => { puChecks(company, obj, entry, h, filled).then((r) => { if (live) setPreview(r); }).catch(() => { if (live) setPreview(null); }); }, 400);
    return () => { live = false; clearTimeout(tm); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, company]);

  const set = (patch: Partial<PuHeaderInput>) => { setH((x) => ({ ...x, ...patch })); setDirty(true); };
  const setLine = (k: string, patch: Partial<FormLine>) => { setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...patch } : l))); setDirty(true); };
  const checks = preview && !preview.errors.length ? preview.checks : [];
  const errors = preview?.errors ?? [];
  const shownErr = attempted ? errors : [];
  const lineInfo = (i: number) => preview?.lines.find((x) => x.line_num === i);
  const rate = (code: string) => Number(S?.tax_codes.find((x) => x.code === code)?.rate ?? 0);
  const est = filled.reduce((acc, l, i) => {
    const p = l.price !== '' ? num(l.price) : Number(lineInfo(i)?.price ?? 0);
    const n = r2(num(l.qty) * p);
    return { net: acc.net + n, vat: acc.vat + r2((n * rate(l.tax_code)) / 100) };
  }, { net: 0, vat: 0 });
  const tot = preview && !errors.length ? preview.totals : { net: r2(est.net), vat: r2(est.vat), total: r2(est.net + est.vat), currency: S?.currency ?? '' };

  const supOpts = async (s: string): Promise<Array<ComboOption<SupplierHit>>> => (await searchSuppliers(company, s)).map((c) => ({
    value: c.card_code, label: `${c.card_code} · ${c.name}`, data: c, meta: [c.city, c.currency].filter(Boolean).join(' · '),
  }));
  const itemOpts = async (s: string) => (await searchBuyItems(company, s)).map((it) => ({ value: it.item_code, label: `${it.item_code} · ${it.name}`, data: it, meta: it.purchase_uom ?? '' }));

  async function save(thenSubmit: boolean) {
    setErr(null); setAttempted(true);
    setBusy(true);
    try {
      const res = await puSave(company, obj, entry, h, filled, entry ? null : series);
      setEntry(res.doc_entry);
      setDirty(false);
      if (thenSubmit) {
        const r = await puSubmit(company, obj, res.doc_entry, reason.trim() || null);
        qc.invalidateQueries({ queryKey: ['erp-list'] });
        qc.invalidateQueries({ queryKey: ['pu-flow'] });
        nav(`/docs/${kind}/${company}/${res.doc_entry}`, { state: { flash: r.state === 'approved' ? t('pu.flash.open', { no: res.doc_no }) : t('pu.flash.pending', { no: res.doc_no }) } });
      } else {
        qc.invalidateQueries({ queryKey: ['erp-list'] });
        nav(`/docs/${kind}/${company}/${res.doc_entry}`, { state: { flash: t('pu.flash.draft', { no: res.doc_no }) } });
      }
    } catch (e) {
      setErr(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally { setBusy(false); }
  }

  const title = initial?.docNo ? t(`pu.title.${kind}`, { no: initial.docNo }) : t(`pu.new.${kind}`);
  return (
    <>
      <PuHeader kind={kind} title={title} pills={<><SourcePill source="erp" />{initial?.docNo && <StatePill state="draft" />}</>}
        sub={initial?.baseNo ? t('pu.copiedFrom', { no: initial.baseNo }) : t(`pu.formSub.${kind}`)} />
      <PuFlowStrip obj={obj} current={STEP_OF_OBJ[obj]} />
      <FormError message={err} />
      {shownErr.length > 1 && (
        <div className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-sm text-crit-fg" role="alert">
          <p className="font-semibold">{t('pu.problems', { n: shownErr.length })}</p>
          <ul className="mt-1 list-disc ps-5">{shownErr.map((e, i) => <li key={i} dir="auto">{e.message}</li>)}</ul>
        </div>
      )}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              {!isReq && (
                <Combobox<SupplierHit> id="pu-card_code" label={t('erp.col.supplier')} required text={supText}
                  onText={(s) => { setSupText(s); if (h.card_code) set({ card_code: '' }); }}
                  search={supOpts} placeholder={t('pu.supplierPh')} noMatch={t('pu.noSupplier')}
                  error={attempted ? errors.find((e) => e.field === 'card_code' && e.line == null)?.message : undefined}
                  onSelect={(o) => { set({ card_code: o.value, payment_terms: o.data.payment_terms ?? '' }); setSupText(o.label); }} />
              )}
              <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
                <input id="pu-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={h.doc_date} onChange={(e) => set({ doc_date: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t(`pu.due.${kind}`)} {isReq && <span className="text-crit-fg">*</span>}
                <input id="pu-due_date" type="date" className="input num mt-1 text-[15px] text-ink" value={h.due_date} onChange={(e) => set({ due_date: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t('pu.receiveWhs')}
                <select id="pu-whs" className="input mt-1 text-[15px] text-ink" value={h.whs_code} onChange={(e) => set({ whs_code: e.target.value })}>
                  <option value="">—</option>
                  {S?.warehouses.map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}
                </select>
              </label>
              <label className="block text-xs font-medium text-muted">{t('pu.office')}
                <select id="pu-office" className="input mt-1 text-[15px] text-ink" value={h.china_office} onChange={(e) => set({ china_office: e.target.value })}>
                  <option value="">—</option>
                  {S?.offices.map((o) => <option key={o.code} value={o.code}>{o.name}</option>)}
                </select>
              </label>
              {!isReq && (
                <label className="block text-xs font-medium text-muted">{t('pu.supplierRef')}
                  <input id="pu-ref" className="input mt-1 text-[15px] text-ink" dir="auto" value={h.customer_ref} onChange={(e) => set({ customer_ref: e.target.value })} />
                </label>
              )}
              <label className={clsx('block text-xs font-medium text-muted', isReq ? 'sm:col-span-2' : 'xl:col-span-3 sm:col-span-2')}>{t('erp.col.remarks')}
                <input id="pu-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={h.comments} onChange={(e) => set({ comments: e.target.value })} />
              </label>
              {!entry && <SeriesPicker company={company} obj={obj} value={series} onChange={setSeries} date={h.doc_date} whs={h.whs_code} />}
            </div>
          </SectionCard>

          <SectionCard title={t('erp.section.lines')}>
            <ul className="divide-y divide-line">
              {lines.map((l, i) => {
                const info = l.item_code ? lineInfo(filled.indexOf(l)) : undefined;
                const lineErr = attempted ? errors.filter((e) => e.line === filled.indexOf(l) + 1) : [];
                const lineChecks = checks.filter((c) => c.line === filled.indexOf(l) + 1);
                return (
                  <li key={l.key} data-testid="pu-line" className={clsx('px-4 py-3', (lineChecks.length > 0 || lineErr.length > 0) && 'bg-warn-bg')}>
                    <div className={clsx('grid grid-cols-2 items-end gap-3', isReq ? 'md:grid-cols-[minmax(0,1fr)_110px_44px]' : 'md:grid-cols-[minmax(0,1fr)_96px_120px_108px_84px_44px]')}>
                      <div className="col-span-2 min-w-0 md:col-span-1">
                        <Combobox id={`pu-line-${i}-item`} label={t('so.itemN', { n: i + 1 })} text={l.text}
                          onText={(s) => setLine(l.key, { text: s, item_code: '' })} search={itemOpts} placeholder={t('so.itemPh')} noMatch={t('pu.noItem')}
                          onSelect={(o) => setLine(l.key, { item_code: o.value, text: o.label })} />
                      </div>
                      <label className="block text-xs font-medium text-muted">{t('erp.col.qty')}
                        <input id={`pu-line-${i}-qty`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.qty} onChange={(e) => setLine(l.key, { qty: e.target.value })} />
                      </label>
                      {!isReq && (
                        <>
                          <label className="block text-xs font-medium text-muted">{t('so.unitPrice')}
                            <input id={`pu-line-${i}-price`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.price}
                              placeholder={info?.last_price != null ? fmtMoney(info.last_price) : ''} onChange={(e) => setLine(l.key, { price: e.target.value })} />
                          </label>
                          <label className="block text-xs font-medium text-muted">{t('erp.col.taxCode')}
                            <select className="input mt-1 px-2 text-[15px] text-ink" value={l.tax_code} onChange={(e) => setLine(l.key, { tax_code: e.target.value })}>
                              {S?.tax_codes.map((x) => <option key={x.code} value={x.code}>{x.code} · {fmtQty(x.rate)}%</option>)}
                            </select>
                          </label>
                          <label className="block text-xs font-medium text-muted">{t('pu.cbm')}
                            <input id={`pu-line-${i}-cbm`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.cbm} onChange={(e) => setLine(l.key, { cbm: e.target.value })} />
                          </label>
                        </>
                      )}
                      <div className="flex min-h-[44px] items-center justify-end">
                        <button type="button" onClick={() => { setLines((ls) => ls.filter((x) => x.key !== l.key)); setDirty(true); }} aria-label={t('so.removeLine', { n: i + 1 })}
                          className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg"><Trash2 className="h-4 w-4" aria-hidden /></button>
                      </div>
                    </div>
                    <p className="mt-1 text-xs text-muted">
                      {l.baseNo && <>{t('pu.fromBase', { no: l.baseNo, n: fmtQty(l.baseOpen) })} · </>}
                      {info?.last_price != null ? t('pu.lastPrice', { price: fmtMoney(info.last_price), no: info.last_doc_no, date: fmtDay(info.last_doc_date) }) : l.item_code && !isReq ? t('pu.noLastPrice') : ''}
                      {info && !isReq && <> · {t('erp.col.lineTotal')} <span className="num font-medium text-ink">{fmtMoney(info.line_total)}</span></>}
                    </p>
                    {lineErr.map((e, k) => <p key={k} className="mt-1 text-[13px] text-crit-fg" dir="auto">{e.message}</p>)}
                    {lineChecks.map((c, k) => <CheckNote key={k} message={c.message} />)}
                  </li>
                );
              })}
            </ul>
            <div className="flex flex-col gap-3 border-t border-line sm:flex-row sm:items-start sm:justify-between">
              <div className="p-4">
                <Button variant="secondary" id="pu-add-line" onClick={() => { setLines((ls) => [...ls, newLine(S?.default_tax_code ?? '')]); setDirty(true); }}>
                  <Plus className="h-4 w-4" aria-hidden /> {t('so.addLine')}
                </Button>
              </div>
              {!isReq && <PuTotals {...tot} currency={tot.currency || S?.currency || ''} />}
            </div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('pu.submitTitle')}>
            <div className="space-y-3 p-5" data-testid="pu-submit-card">
              {checks.length > 0 ? (
                <>
                  <p className="font-semibold text-warn-fg">{t('pu.needsApproval', { who: [...new Set(checks.map((c) => c.approver_name))].join(', ') })}</p>
                  <ul className="space-y-1 text-[13px] text-ink-2">{checks.map((c, i) => <li key={i} dir="auto">{c.message}</li>)}</ul>
                  <label className="block text-xs font-medium text-muted">{t('so.reason')} <span className="text-crit-fg">*</span>
                    <textarea id="pu-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} onChange={(e) => setReason(e.target.value)} />
                  </label>
                </>
              ) : (
                <p className="text-sm text-muted">{preview && !errors.length ? t(`pu.goesOpen.${kind}`) : t('pu.fillToCheck')}</p>
              )}
              {isPo && S?.my_po_limit != null && <p className="text-xs text-muted">{t('pu.myLimit', { n: fmtMoney(S.my_po_limit, S.currency) })}</p>}
              <Button variant="primary" id="pu-submit" className="w-full" disabled={busy || !allowed || !filled.length} onClick={() => save(true)}
                disabledReason={!allowed ? readOnlyReason : !filled.length ? t('pu.addLineFirst') : undefined}>
                {busy ? t('so.saving') : checks.length ? t('so.submitForApproval') : t('pu.submitOpen')}
              </Button>
              <Button variant="secondary" id="pu-save" className="w-full" disabled={busy || !allowed || !filled.length} onClick={() => save(false)}>{t('so.saveDraft')}</Button>
              <Link to={entry ? `/docs/${kind}/${company}/${entry}` : `/docs/${kind}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
            </div>
          </SectionCard>
        </aside>
      </div>
    </>
  );
}

// ---------- Request / quotation / order page ----------
function useDocLines(company: string, obj: number, id: number, key: string) {
  return useQuery({
    queryKey: ['doc', key, company, String(id)],
    queryFn: async () => {
      const { data, error } = await erp().from('document').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).maybeSingle();
      if (error) throw new ApiError(error);
      if (!data) return null;
      const { data: ls, error: le } = await erp().from('document_line').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).order('line_num');
      if (le) throw new ApiError(le);
      return { doc: data as R, lines: (ls ?? []) as R[] };
    },
  });
}

export function PurchaseDocPage({ kind }: { kind: PurchaseKind }) {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const obj = PURCHASE_OBJ[kind];
  const qc = useQueryClient();
  const [flash, setFlash] = useFlash();
  const q = useDocLines(company, obj, id, kind);
  const info = usePuInfo(company, obj, id);
  const I = info.data;
  const d = q.data?.doc;
  const refresh = (msg?: string) => {
    q.refetch(); info.refetch();
    qc.invalidateQueries({ queryKey: ['pu-flow'] });
    qc.invalidateQueries({ queryKey: ['erp-list'] });
    qc.invalidateQueries({ queryKey: ['approval-inbox'] });
    if (msg) setFlash(msg);
  };

  let body: ReactNode = null;
  if (q.isLoading || info.isLoading) body = <PageLoading />;
  else if (q.error || info.error) body = <div className="card"><ErrorState error={q.error ?? info.error} onRetry={() => { q.refetch(); info.refetch(); }} /></div>;
  else if (!d) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  if (body) return <RequireModule module="purchasing"><PuHeader kind={kind} title={t(`erp.doc.${kind}`)} />{body}</RequireModule>;

  const lines = q.data!.lines;
  const wf = Boolean(I?.workflow);
  const docNo = wf ? I!.doc_no : String(d!.doc_num);
  const isReq = kind === 'purchase_request';
  const net = lines.reduce((s, l) => s + Number(l.line_total ?? 0), 0);
  const whs = [...new Set(lines.map((l) => l.whs_code).filter(Boolean))].join(', ');
  const pill = wf && I!.state !== 'approved' && I!.state !== 'cancelled' ? <StatePill state={I!.state} /> : <StatusTag value={d!.status} />;

  return (
    <RequireModule module="purchasing">
      <PuHeader kind={kind} title={t(`pu.title.${kind}`, { no: docNo })} pills={<>{pill}<SourcePill source={d!.source} /><LiveBadge live /></>}
        sub={[d!.card_name, I?.china_office_name ? t('pu.officeOf', { name: I.china_office_name }) : null, I?.created_by_name,
          I?.created_at ? t('so.createdAt', { when: fmtWhen(I.created_at) }) : d!.created_on ? t('so.createdAt', { when: fmtDay(d!.created_on) }) : null].filter(Boolean).join(' · ')}
        actions={wf ? <DocActions kind={kind} company={company} id={id} info={I!} docNo={docNo} onDone={refresh} /> : undefined} />
      <PuFlowStrip company={company} obj={obj} entry={id} />
      <Flash text={flash} />
      {!wf && <p className="mb-4 rounded-btn border border-line bg-surface-2 px-4 py-3 text-sm text-muted">{d!.source === 'sap' ? t('pu.sapReadOnly') : t('so.sampleReadOnly')}</p>}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              ...(isReq ? [] : [[t('erp.col.supplier'), d!.card_code ? <Link className="text-primary hover:underline" to={`/bp/${company}/${encodeURIComponent(d!.card_code)}`}>{d!.card_code} · {d!.card_name}</Link> : null] as [string, ReactNode]]),
              [t('erp.col.postingDate'), fmtDay(d!.doc_date)],
              [t(`pu.due.${kind}`), d!.due_date ? fmtDay(d!.due_date) : null],
              [t('pu.receiveWhs'), whs || I?.whs_code || null],
              [t('pu.office'), I?.china_office_name ?? null],
              ...(isReq ? [] : [[t('pu.supplierRef'), d!.customer_ref] as [string, ReactNode]]),
              ...(kind === 'purchase_order' && d!.container_no ? [[t('pu.container'), <span className="font-mono">{d!.container_no}</span>] as [string, ReactNode]] : []),
              [t('erp.col.remarks'), d!.comments],
              [t('erp.col.source'), sourceLabel(d!.source)],
            ]} />
          </SectionCard>
          <SectionCard title={t('erp.section.lines')}>
            {lines.length === 0 ? <EmptyState title={t('erp.list.empty')} /> : (
              <div className="overflow-x-auto">
                <table className="w-full text-[14px] sm:min-w-[600px]">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('so.item')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.qty')}</th>
                    {wf && <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t(`pu.col.open.${kind}`)}</th>}
                    {!isReq && <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('so.unitPrice')}</th>}
                    {!isReq && <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.lineTotal')}</th>}
                  </tr></thead>
                  <tbody>
                    {lines.map((l) => (
                      <tr key={l.line_num} data-testid="pu-doc-line" className="border-t border-line align-top">
                        <td className="px-4 py-2.5">
                          <div dir="auto" className="font-semibold">{l.description ?? l.item_code}</div>
                          <div className="text-xs text-muted"><Link className="font-mono hover:underline" to={`/items/${company}/${encodeURIComponent(l.item_code ?? '')}`}>{l.item_code}</Link>
                            {l.whs_code ? ` · ${l.whs_code}` : ''}{l.tax_code ? ` · ${l.tax_code}` : ''}{l.cbm != null ? ` · ${fmtQty(l.cbm)} CBM` : ''}</div>
                        </td>
                        <td className="num px-4 py-2.5 text-end">{fmtQty(l.quantity)} <span className="text-muted">{l.uom}</span></td>
                        {wf && <td className="num px-4 py-2.5 text-end max-sm:hidden" data-testid="pu-open-qty">{fmtQty(l.line_status === 'C' ? 0 : l.open_qty)}</td>}
                        {!isReq && <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(l.price)}</td>}
                        {!isReq && <td className="num px-4 py-2.5 text-end font-medium">{fmtMoney(l.line_total)}</td>}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {!isReq && <div className="flex justify-end"><PuTotals net={r2(net)} vat={Number(d!.vat_total ?? 0)} total={Number(d!.total ?? 0)} currency={d!.currency ?? ''} /></div>}
          </SectionCard>
          {kind === 'purchase_order' && wf && I!.state === 'approved' && <ChinaSteps company={company} po={id} poNo={docNo} info={I!} doc={d!} lines={lines} onDone={refresh} />}
        </div>
        <aside className="min-w-0 space-y-5">
          {wf && <ApprovalPanel company={company} id={id} info={I!} kind={kind} docNo={docNo} onDone={refresh} />}
          {wf && <ActivityCard items={I!.activity ?? []} />}
          <AskAiDocCard company={company} obj={obj} entry={id} title={t('ai.docTitle')} label={docNo} />
        </aside>
      </div>
    </RequireModule>
  );
}

function DocActions({ kind, company, id, info, docNo, onDone }: { kind: PurchaseKind; company: string; id: number; info: PuInfo; docNo: string; onDone: (m?: string) => void }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const obj = PURCHASE_OBJ[kind];
  const copyReason = info.copy_block ? t(`pu.copyBlock.${info.copy_block}`) : undefined;
  const copies: Array<{ id: string; label: string; to: string }> = kind === 'purchase_request'
    ? [{ id: 'pu-copy-quotation', label: t('pu.copyToQuotation'), to: `/docs/purchase_quotation/new?company=${company}&fromObj=${obj}&from=${id}` },
       { id: 'pu-copy-order', label: t('pu.copyToOrder'), to: `/docs/purchase_order/new?company=${company}&fromObj=${obj}&from=${id}` }]
    : kind === 'purchase_quotation' ? [{ id: 'pu-copy-order', label: t('pu.copyToOrder'), to: `/docs/purchase_order/new?company=${company}&fromObj=${obj}&from=${id}` }]
      : [{ id: 'pu-copy-grpo', label: t('pu.copyToGrpo'), to: `/purchasing/grpo/new?company=${company}&po=${id}` }];
  async function cancel() {
    setErr(null);
    if (!note.trim()) { setErr(t('pu.cancelNoteNeeded')); return; }
    setBusy(true);
    try { await puCancel(company, obj, id, note.trim()); setOpen(false); onDone(t('pu.flash.cancelled', { no: docNo })); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <>
      {info.can_edit && (
        <Link to={`/docs/${kind}/${company}/${id}/edit`} id="pu-edit" className={primaryLink}>
          <Pencil className="h-4 w-4" aria-hidden />{info.state === 'rejected' ? t('so.editResubmit') : t('so.editDraft')}
        </Link>
      )}
      {kind === 'purchase_request' && <Link to={`/purchasing/compare/${company}/${id}`} id="pu-compare" className={secondaryLink}>{t('pu.compare')}</Link>}
      {copies.map((c, i) => (info.can_copy
        ? <Link key={c.id} to={c.to} id={c.id} className={i === 0 ? primaryLink : secondaryLink}>{c.label}</Link>
        : <Button key={c.id} variant="secondary" id={c.id} disabled disabledReason={i === copies.length - 1 ? copyReason : undefined}>{c.label}</Button>))}
      {info.can_cancel && <Button variant="danger" id="pu-cancel" onClick={() => { setOpen(true); setErr(null); }}>{t(`pu.cancel.${kind}`)}</Button>}
      <Dialog open={open} title={t('pu.cancelTitle', { no: docNo })} onClose={() => setOpen(false)}
        footer={<>
          <Button variant="secondary" onClick={() => setOpen(false)}>{t('so.keep')}</Button>
          <Button variant="danger" id="pu-cancel-confirm" onClick={cancel} disabled={busy}>{t(`pu.cancel.${kind}`)}</Button>
        </>}>
        <p className="text-sm text-ink-2">{t('pu.cancelBody')}</p>
        <label className="block text-xs font-medium text-muted">{t('so.note')} <span className="text-crit-fg">*</span>
          <textarea id="pu-cancel-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        {err && <p role="alert" className="text-sm text-crit-fg">{err}</p>}
      </Dialog>
    </>
  );
}

function ApprovalPanel({ company, id, info, kind, docNo, onDone }: { company: string; id: number; info: PuInfo; kind: PurchaseKind; docNo: string; onDone: (m?: string) => void }) {
  const { t } = useTranslation();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejOpen, setRejOpen] = useState(false);
  const [note, setNote] = useState('');
  const [noteErr, setNoteErr] = useState<string | null>(null);
  const approvals = info.approvals ?? [];
  const current = approvals.filter((a) => a.current);
  const mine = current.filter((a) => a.mine);
  const myLast = [...approvals].reverse().find((a) => a.decided_by_me && a.decision);
  const msgs = (a: { detail: { checks?: PuCheck[] } | null }) => (a.detail?.checks ?? []).map((c) => c.message);

  async function decide(decision: 'approved' | 'rejected') {
    setErr(null);
    if (decision === 'rejected' && !note.trim()) { setNoteErr(t('pu.rejectNoteNeeded')); return; }
    setBusy(true);
    try {
      const r = await puDecide(company, id, decision, decision === 'rejected' ? note.trim() : null);
      setRejOpen(false);
      onDone(decision === 'rejected' ? (r.state === 'pending_approval' ? t('apr.flash.rejectionRecorded') : t('so.flash.rejected')) : r.state === 'approved' ? t('pu.flash.approved', { no: docNo }) : t('so.flash.stepApproved'));
    } catch (e) {
      const m = errorMessage(e);
      if (decision === 'rejected') setNoteErr(m); else setErr(m);
    } finally { setBusy(false); }
  }

  if (info.can_decide) {
    return (
      <section className="card overflow-hidden border-warn-fg/40" data-testid="pu-approval-card">
        <div className="border-b border-line bg-warn-bg px-5 py-3"><h2 className="text-[15px] font-semibold text-warn-fg">{t('so.approval.needed')}</h2></div>
        <div className="space-y-3 p-5">
          {err && <p role="alert" className="text-sm text-crit-fg">{err}</p>}
          {mine.map((a) => (
            <div key={a.approval_id}>
              <p className="text-sm font-semibold">{t(`so.rule.${a.rule_code}`)}</p>
              <ul className="mt-1 space-y-0.5 text-[13px] text-ink-2">{msgs(a).map((m, k) => <li key={k} dir="auto">{m}</li>)}</ul>
            </div>
          ))}
          <p className="text-sm text-muted">{t('so.approval.requested', { name: info.submitted_by_name ?? '—', when: fmtWhen(info.submitted_at) })}</p>
          {info.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 text-[15px] italic text-ink-2">“{info.reason}”</blockquote>}
          <div className="flex flex-col gap-2 pt-1">
            <Button variant="success" id="pu-approve" className="w-full" disabled={busy} onClick={() => decide('approved')} icon={<Check className="h-4 w-4" aria-hidden />}>{t('so.approval.approve')}</Button>
            <Button variant="danger" id="pu-reject" className="w-full" disabled={busy} onClick={() => { setRejOpen(true); setNoteErr(null); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('so.approval.reject')}</Button>
          </div>
        </div>
        <Dialog open={rejOpen} title={t('pu.rejectTitle', { no: docNo })} onClose={() => setRejOpen(false)}
          footer={<>
            <Button variant="secondary" onClick={() => setRejOpen(false)}>{t('so.keep')}</Button>
            <Button variant="danger" id="pu-reject-confirm" disabled={busy} onClick={() => decide('rejected')}>{t('so.approval.reject')}</Button>
          </>}>
          <label className="block text-xs font-medium text-muted">{t('so.approval.rejectNote')} <span className="text-crit-fg">*</span>
            <textarea id="pu-reject-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => { setNote(e.target.value); setNoteErr(null); }} />
          </label>
          {noteErr && <p role="alert" className="text-sm text-crit-fg">{noteErr}</p>}
        </Dialog>
      </section>
    );
  }
  if (myLast && info.state !== 'pending_approval') {
    const ok = myLast.decision === 'approved';
    return (
      <section data-testid="pu-decided-card" className={clsx('card p-5', ok ? 'border-ok-fg/40 bg-ok-bg text-ok-fg' : 'border-crit-fg/40 bg-crit-bg text-crit-fg')}>
        <p className="flex items-center gap-2 font-semibold">{ok ? <CircleCheck className="h-5 w-5" aria-hidden /> : <CircleX className="h-5 w-5" aria-hidden />}
          {t(ok ? 'so.approval.approvedByYou' : 'so.approval.rejectedByYou', { when: fmtWhen(myLast.decided_at) })}</p>
        {myLast.note && <p dir="auto" className="mt-2 text-sm">“{myLast.note}”</p>}
        <p className="mt-2 text-sm">{t('pu.requesterSees', { name: info.submitted_by_name ?? info.created_by_name ?? '—' })}</p>
      </section>
    );
  }
  const lastRej = [...approvals].reverse().find((a) => a.decision === 'rejected');
  const lastOk = [...approvals].reverse().find((a) => a.decision === 'approved');
  return (
    <SectionCard title={t('so.approval.status')}>
      <div className="space-y-2 p-5 text-sm" data-testid="pu-status-card">
        {info.state === 'draft' && <p className="text-muted">{t(`pu.statusDraft.${kind}`)}</p>}
        {info.state === 'pending_approval' && (
          <>
            <p className="font-semibold text-warn-fg">{t('so.approval.waitingFor', { names: [...new Set(current.map((a) => a.approver_position_name))].join(', ') })}</p>
            <ApprovalStageNote items={current} />
            {current.map((a) => msgs(a).map((m, k) => <p key={`${a.approval_id}-${k}`} dir="auto" className="text-ink-2">{m}</p>))}
            {info.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{info.reason}”</blockquote>}
            {info.is_submitter && <p className="text-muted">{t('pu.youCantApprove')}</p>}
          </>
        )}
        {info.state === 'approved' && (
          <p className="flex items-center gap-2 font-semibold text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />
            {lastOk ? t('so.approval.approvedBy', { name: lastOk.decided_by_name ?? '—', when: fmtWhen(lastOk.decided_at) }) : t(`pu.openNoRule.${kind}`)}</p>
        )}
        {info.state === 'rejected' && lastRej && (
          <>
            <p className="flex items-center gap-2 font-semibold text-crit-fg"><CircleX className="h-4 w-4" aria-hidden />{t('so.approval.rejectedBy', { name: lastRej.decided_by_name ?? '—', when: fmtWhen(lastRej.decided_at) })}</p>
            {lastRej.note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{lastRej.note}”</blockquote>}
          </>
        )}
        {info.state === 'cancelled' && (
          <>
            <p className="font-semibold text-crit-fg">{t('so.approval.cancelled', { when: fmtWhen(info.cancelled_at) })}</p>
            {info.cancel_note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{info.cancel_note}”</blockquote>}
          </>
        )}
      </div>
    </SectionCard>
  );
}

// ---------- PO › China steps: PI and deposit, QC, shipment ----------
function ChinaSteps({ company, po, poNo, info, doc, lines, onDone }: { company: string; po: number; poNo: string; info: PuInfo; doc: R; lines: R[]; onDone: (m?: string) => void }) {
  const { t } = useTranslation();
  const setup = usePuSetup(company);
  const S = setup.data;
  // New PIs, deposits, inspections and shipments need an open order; a PI's status can still change afterwards.
  const canEdit = info.can_write;
  const can = canEdit && doc.status === 'open';
  const cur = doc.currency ?? '';
  const [form, setForm] = useState<'pi' | 'deposit' | 'qc' | 'shipment' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pi, setPi] = useState({ vendor_pi_no: '', pi_date: today(), amount: '', eta: '', status: '', note: '' });
  const [piEdit, setPiEdit] = useState<number | null>(null);
  const [dep, setDep] = useState({ doc_date: today(), mode: 'pct', pct: '30', amount: '', pi_id: '' });
  const [depSeries, setDepSeries] = useState<number | null>(null);
  const [qcF, setQcF] = useState({ inspected_on: today(), inspector: '', result: 'pass', note: '', photo: '' });
  const [ticks, setTicks] = useState<Record<string, boolean>>({});
  const [sh, setSh] = useState({ container_no: '', shipping_mark: '', shipment_mode: 'sea', etd: '', eta: '', note: '' });
  const [shQty, setShQty] = useState<Record<number, string>>({});
  const open = (f: typeof form) => { setForm(f); setErr(null); };
  const lastQc = (info.qcs ?? []).slice(-1)[0];
  const qcBlock = info.last_qc !== 'pass';   // B1: QC must always pass before goods ship

  async function run(fn: () => Promise<unknown>, msg: string) {
    setErr(null); setBusy(true);
    try { await fn(); setForm(null); onDone(msg); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const field = 'block text-xs font-medium text-muted';
  const input = 'input mt-1 text-[15px] text-ink';
  const Actions = ({ submitId, label, onSubmit }: { submitId: string; label: string; onSubmit: () => void }) => (
    <div className="flex flex-wrap gap-2 sm:col-span-2">
      <Button variant="primary" id={submitId} disabled={busy} onClick={onSubmit}>{busy ? t('so.saving') : label}</Button>
      <Button variant="ghost" onClick={() => setForm(null)}>{t('so.cancelEdit')}</Button>
    </div>
  );

  return (
    <div id="china" className="space-y-5">
      {err && <FormError message={err} />}
      {/* PI and deposit */}
      <SectionCard title={t('pu.china.pi')} right={can && form !== 'pi' ? <Button variant="secondary" id="pu-pi-add" onClick={() => { setPiEdit(null); setPi({ vendor_pi_no: '', pi_date: today(), amount: String(Number(doc.total ?? 0)), eta: '', status: S?.pi_statuses[0]?.code ?? '', note: '' }); open('pi'); }}><Plus className="h-4 w-4" aria-hidden />{t('pu.pi.add')}</Button> : undefined}>
        {form === 'pi' && (
          <div className="grid grid-cols-1 gap-4 border-b border-line p-5 sm:grid-cols-2" data-testid="pu-pi-form">
            <label className={field}>{t('pu.pi.no')} <span className="text-crit-fg">*</span><input id="pu-pi-no" className={input} value={pi.vendor_pi_no} onChange={(e) => setPi({ ...pi, vendor_pi_no: e.target.value })} /></label>
            <label className={field}>{t('pu.pi.date')} <span className="text-crit-fg">*</span><input id="pu-pi-date" type="date" className={`${input} num`} value={pi.pi_date} onChange={(e) => setPi({ ...pi, pi_date: e.target.value })} /></label>
            <label className={field}>{t('pu.pi.amount', { cur })}<input id="pu-pi-amount" inputMode="decimal" className={`${input} num text-end`} value={pi.amount} onChange={(e) => setPi({ ...pi, amount: e.target.value })} /></label>
            <label className={field}>{t('pu.eta')}<input id="pu-pi-eta" type="date" className={`${input} num`} value={pi.eta} onChange={(e) => setPi({ ...pi, eta: e.target.value })} /></label>
            <label className={field}>{t('pu.pi.status')} <span className="text-crit-fg">*</span>
              <select id="pu-pi-status" className={input} value={pi.status} onChange={(e) => setPi({ ...pi, status: e.target.value })}>
                <option value="">—</option>{S?.pi_statuses.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
              </select>
            </label>
            <label className={field}>{t('so.note')}<input id="pu-pi-note" className={input} dir="auto" value={pi.note} onChange={(e) => setPi({ ...pi, note: e.target.value })} /></label>
            <Actions submitId="pu-pi-save" label={piEdit ? t('pu.pi.update') : t('pu.pi.save')}
              onSubmit={() => run(() => piSave(company, piEdit, { po_doc_entry: po, ...pi, amount: pi.amount || null, eta: pi.eta || null }), t('pu.flash.pi', { no: pi.vendor_pi_no }))} />
          </div>
        )}
        {(info.pis ?? []).length === 0 ? <p className="p-5 text-sm text-muted">{t('pu.pi.none')}</p> : (
          <ul className="divide-y divide-line">
            {info.pis!.map((p) => (
              <li key={p.pi_id} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3" data-testid="pu-pi-row">
                <div className="min-w-0 text-sm">
                  <p className="font-semibold"><span className="font-mono">{p.vendor_pi_no}</span> <span className="pill pill-info ms-1">{p.status_name ?? p.status}</span></p>
                  <p className="text-muted">{fmtDay(p.pi_date)}{p.amount != null && <> · <span className="num">{fmtMoney(p.amount, cur)}</span></>}{p.eta && <> · {t('pu.etaOn', { date: fmtDay(p.eta) })}</>}
                    {p.deposit_doc_no && <> · {t('pu.pi.deposit')} <Link className="font-mono text-primary hover:underline" to={`/docs/ap_down_payment/${company}/${p.deposit_doc_entry}`}>{p.deposit_doc_no}</Link></>}</p>
                </div>
                {canEdit && <Button variant="ghost" id={`pu-pi-edit-${p.pi_id}`} onClick={() => { setPiEdit(p.pi_id); setPi({ vendor_pi_no: p.vendor_pi_no, pi_date: p.pi_date, amount: p.amount != null ? String(p.amount) : '', eta: p.eta ?? '', status: p.status, note: p.note ?? '' }); open('pi'); }}>
                  <Pencil className="h-4 w-4" aria-hidden />{t('pu.pi.changeStatus')}</Button>}
              </li>
            ))}
          </ul>
        )}
        <div className="border-t border-line">
          <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3">
            <h3 className="text-sm font-semibold">{t('pu.china.deposits')}</h3>
            {can && form !== 'deposit' && <Button variant="secondary" id="pu-deposit-add" onClick={() => open('deposit')}><Plus className="h-4 w-4" aria-hidden />{t('pu.deposit.add')}</Button>}
          </div>
          {form === 'deposit' && (
            <div className="grid grid-cols-1 gap-4 border-y border-line p-5 sm:grid-cols-2" data-testid="pu-deposit-form">
              <label className={field}>{t('erp.col.postingDate')}<input id="pu-dep-date" type="date" className={`${input} num`} value={dep.doc_date} onChange={(e) => setDep({ ...dep, doc_date: e.target.value })} /></label>
              <SeriesPicker company={company} obj={204} value={depSeries} onChange={setDepSeries} date={dep.doc_date} id="pu-dep-series" />
              <label className={field}>{t('pu.deposit.how')}
                <select id="pu-dep-mode" className={input} value={dep.mode} onChange={(e) => setDep({ ...dep, mode: e.target.value })}>
                  <option value="pct">{t('pu.deposit.pct')}</option><option value="amount">{t('pu.deposit.amount', { cur })}</option>
                </select>
              </label>
              {dep.mode === 'pct'
                ? <label className={field}>{t('pu.deposit.pct')}<input id="pu-dep-pct" inputMode="decimal" className={`${input} num text-end`} value={dep.pct} onChange={(e) => setDep({ ...dep, pct: e.target.value })} />
                    <span className="mt-1 block num">{fmtMoney(r2(Number(doc.total ?? 0) * num(dep.pct) / 100), cur)}</span></label>
                : <label className={field}>{t('pu.deposit.amount', { cur })}<input id="pu-dep-amount" inputMode="decimal" className={`${input} num text-end`} value={dep.amount} onChange={(e) => setDep({ ...dep, amount: e.target.value })} /></label>}
              <label className={field}>{t('pu.deposit.forPi')}
                <select id="pu-dep-pi" className={input} value={dep.pi_id} onChange={(e) => setDep({ ...dep, pi_id: e.target.value })}>
                  <option value="">—</option>{(info.pis ?? []).map((p) => <option key={p.pi_id} value={p.pi_id}>{p.vendor_pi_no}</option>)}
                </select>
              </label>
              <p className="text-sm text-muted sm:col-span-2">{t('pu.deposit.what')}</p>
              <Actions submitId="pu-dep-save" label={t('pu.deposit.save')}
                onSubmit={() => run(() => depositCreate(company, po, { doc_date: dep.doc_date, pct: dep.mode === 'pct' ? dep.pct : null, amount: dep.mode === 'amount' ? dep.amount : null, pi_id: dep.pi_id || null }, depSeries), t('pu.flash.deposit'))} />
            </div>
          )}
          {(info.deposits ?? []).length === 0 ? <p className="px-5 pb-4 text-sm text-muted">{t('pu.deposit.none')}</p> : (
            <ul className="divide-y divide-line border-t border-line">
              {info.deposits!.map((x) => {
                const openAmt = r2(Number(x.total) - Number(x.paid));
                return (
                  <li key={x.doc_entry} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm" data-testid="pu-deposit-row">
                    <div>
                      <Link className="font-mono font-semibold text-primary hover:underline" to={`/docs/ap_down_payment/${company}/${x.doc_entry}`}>{x.doc_no}</Link>
                      <span className="ms-2 num">{fmtMoney(x.total, cur)}</span>
                      <p className="text-muted">{openAmt > 0 ? t('pu.deposit.toPay', { n: fmtMoney(openAmt, cur) }) : t('pu.deposit.paid')}{Number(x.drawn) > 0 && ` · ${t('pu.deposit.drawn', { n: fmtMoney(x.drawn, cur) })}`}</p>
                    </div>
                    {openAmt > 0 && <Link className={secondaryLink} id={`pu-pay-${x.doc_entry}`} to={`/banking/payments/out/new?company=${company}&card=${encodeURIComponent(doc.card_code)}&apply=204:${x.doc_entry}:${openAmt}`}>{t('pu.payInBanking')}</Link>}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </SectionCard>

      {/* QC */}
      <SectionCard title={t('pu.china.qc')} right={can && form !== 'qc' ? <Button variant="secondary" id="pu-qc-add" onClick={() => { setTicks({}); setQcF({ inspected_on: today(), inspector: '', result: 'pass', note: '', photo: '' }); open('qc'); }}><Plus className="h-4 w-4" aria-hidden />{t('pu.qc.add')}</Button> : undefined}>
        {form === 'qc' && (
          <div className="grid grid-cols-1 gap-4 border-b border-line p-5 sm:grid-cols-2" data-testid="pu-qc-form">
            <label className={field}>{t('pu.qc.date')}<input id="pu-qc-date" type="date" className={`${input} num`} value={qcF.inspected_on} onChange={(e) => setQcF({ ...qcF, inspected_on: e.target.value })} /></label>
            <label className={field}>{t('pu.qc.inspector')}<input id="pu-qc-inspector" className={input} dir="auto" value={qcF.inspector} onChange={(e) => setQcF({ ...qcF, inspector: e.target.value })} /></label>
            <fieldset className="sm:col-span-2">
              <legend className="text-xs font-medium text-muted">{t('pu.qc.checklist')}</legend>
              {(S?.qc_checklist ?? []).length === 0 ? <p className="mt-1 text-sm text-muted">{t('pu.qc.noChecklist')}</p> : (
                <div className="mt-1 grid gap-1 sm:grid-cols-2">
                  {S!.qc_checklist.map((c) => (
                    <label key={c.code} className="flex min-h-[40px] items-center gap-3 text-[15px]">
                      <input type="checkbox" id={`pu-qc-check-${c.code}`} className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked={Boolean(ticks[c.code])} onChange={(e) => setTicks({ ...ticks, [c.code]: e.target.checked })} />
                      <span dir="auto">{c.name}</span>
                    </label>
                  ))}
                </div>
              )}
            </fieldset>
            <fieldset className="sm:col-span-2">
              <legend className="text-xs font-medium text-muted">{t('pu.qc.resultLabel')}</legend>
              <div className="mt-1 flex flex-wrap gap-2">
                {(['pass', 'rework', 'fail'] as const).map((r) => (
                  <label key={r} className={clsx('inline-flex min-h-[40px] cursor-pointer items-center gap-2 rounded-full border px-4 text-sm font-medium', qcF.result === r ? 'border-primary bg-primary-soft text-primary-text' : 'border-line')}>
                    <input type="radio" name="qc-result" id={`pu-qc-${r}`} className="sr-only" checked={qcF.result === r} onChange={() => setQcF({ ...qcF, result: r })} />{t(`pu.qc.result.${r}`)}
                  </label>
                ))}
              </div>
            </fieldset>
            <label className={clsx(field, 'sm:col-span-2')}>{t('so.note')} {qcF.result !== 'pass' && <span className="text-crit-fg">*</span>}
              <textarea id="pu-qc-note" rows={2} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={qcF.note} onChange={(e) => setQcF({ ...qcF, note: e.target.value })} />
            </label>
            <div className="sm:col-span-2 rounded-btn border border-dashed border-line-strong p-3 text-sm text-muted">
              <p className="font-medium text-ink-2">{t('pu.qc.photos')}</p>
              <p>{t('pu.qc.photosHint', { path: `qc/${company}/${po}/` })}</p>
              <QcPhotoUpload company={company} po={po} value={qcF.photo} onChange={(p) => setQcF({ ...qcF, photo: p })} />
            </div>
            <Actions submitId="pu-qc-save" label={t('pu.qc.save')}
              onSubmit={() => run(() => qcSave(company, { po_doc_entry: po, inspected_on: qcF.inspected_on, inspector: qcF.inspector, result: qcF.result, note: qcF.note,
                checklist: (S?.qc_checklist ?? []).map((c) => ({ code: c.code, ok: Boolean(ticks[c.code]) })), photos: qcF.photo ? [qcF.photo] : [] }), t('pu.flash.qc'))} />
          </div>
        )}
        {(info.qcs ?? []).length === 0 ? <p className="p-5 text-sm text-muted">{t('pu.qc.none')}</p> : (
          <ul className="divide-y divide-line">
            {info.qcs!.map((x) => (
              <li key={x.qc_id} className="px-5 py-3 text-sm" data-testid="pu-qc-row">
                <p className="flex flex-wrap items-center gap-2 font-semibold">
                  <span className={clsx('pill', x.result === 'pass' ? 'pill-ok' : x.result === 'fail' ? 'pill-crit' : 'pill-warning')}>{t(`pu.qc.result.${x.result}`)}</span>
                  {fmtDay(x.inspected_on)}{x.inspector && <span className="font-normal text-muted">· {x.inspector}</span>}
                </p>
                {x.checklist.length > 0 && <p className="mt-1 text-muted">{t('pu.qc.ticked', { n: x.checklist.filter((c) => c.ok).length, of: x.checklist.length })}</p>}
                {x.note && <p dir="auto" className="mt-1 text-ink-2">“{x.note}”</p>}
                {x.photos.length > 0 && <p className="mt-1 text-xs text-muted">{t('pu.qc.photoCount', { count: x.photos.length })} · <span className="font-mono">{x.photos.join(', ')}</span></p>}
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {/* Shipment */}
      <SectionCard title={t('pu.china.shipment')} right={can && form !== 'shipment' ? (
        <Button variant="secondary" id="pu-ship-add" disabled={qcBlock} disabledReason={qcBlock ? (lastQc ? t('pu.ship.lastQc', { r: t(`pu.qc.result.${lastQc.result}`) }) : t('pu.ship.needQc')) : undefined}
          onClick={() => { setShQty(Object.fromEntries(lines.map((l) => [l.line_num, String(Math.max(Number(l.open_qty) - shipped(info, l.line_num), 0))]))); open('shipment'); }}>
          <Plus className="h-4 w-4" aria-hidden />{t('pu.ship.add')}</Button>) : undefined}>
        {form === 'shipment' && (
          <div className="grid grid-cols-1 gap-4 border-b border-line p-5 sm:grid-cols-2" data-testid="pu-ship-form">
            <label className={field}>{t('pu.ship.mode')}
              <select id="pu-ship-mode" className={input} value={sh.shipment_mode} onChange={(e) => setSh({ ...sh, shipment_mode: e.target.value })}>
                {['sea', 'air', 'road', 'courier'].map((m) => <option key={m} value={m}>{t(`pu.ship.modes.${m}`)}</option>)}
              </select>
            </label>
            <label className={field}>{t('pu.container')}<input id="pu-ship-container" className={`${input} font-mono`} value={sh.container_no} onChange={(e) => setSh({ ...sh, container_no: e.target.value })} /></label>
            <label className={field}>{t('pu.ship.mark')}<input id="pu-ship-mark" className={input} dir="auto" value={sh.shipping_mark} onChange={(e) => setSh({ ...sh, shipping_mark: e.target.value })} /></label>
            <label className={field}>{t('pu.ship.etd')}<input id="pu-ship-etd" type="date" className={`${input} num`} value={sh.etd} onChange={(e) => setSh({ ...sh, etd: e.target.value })} /></label>
            <label className={field}>{t('pu.eta')} <span className="text-crit-fg">*</span><input id="pu-ship-eta" type="date" className={`${input} num`} value={sh.eta} onChange={(e) => setSh({ ...sh, eta: e.target.value })} /></label>
            <div className="sm:col-span-2">
              <p className="text-xs font-medium text-muted">{t('pu.ship.lines')}</p>
              <ul className="mt-1 divide-y divide-line rounded-btn border border-line">
                {lines.map((l) => (
                  <li key={l.line_num} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
                    <span className="min-w-0"><span className="font-mono">{l.item_code}</span> <span className="text-muted">· {t('pu.ship.openNotShipped', { n: fmtQty(Math.max(Number(l.open_qty) - shipped(info, l.line_num), 0)) })}</span></span>
                    <input id={`pu-ship-qty-${l.line_num}`} aria-label={t('erp.col.qty')} inputMode="decimal" className="input num w-28 text-end text-[15px] text-ink" value={shQty[l.line_num] ?? ''} onChange={(e) => setShQty({ ...shQty, [l.line_num]: e.target.value })} />
                  </li>
                ))}
              </ul>
            </div>
            <Actions submitId="pu-ship-save" label={t('pu.ship.save')}
              onSubmit={() => run(() => shipmentSave(company, null, { po_doc_entry: po, ...sh, etd: sh.etd || null },
                Object.entries(shQty).filter(([, v]) => num(v) > 0).map(([k, v]) => ({ po_line: Number(k), qty: v }))), t('pu.flash.shipment'))} />
          </div>
        )}
        {(info.shipments ?? []).length === 0 ? <p className="p-5 text-sm text-muted">{qcBlock && can ? (lastQc ? t('pu.ship.lastQc', { r: t(`pu.qc.result.${lastQc.result}`) }) : t('pu.ship.needQc')) : t('pu.ship.none')}</p> : (
          <ul className="divide-y divide-line">
            {info.shipments!.map((x) => (
              <li key={x.shipment_id} className="px-5 py-3 text-sm" data-testid="pu-ship-row">
                <p className="flex flex-wrap items-center gap-2 font-semibold">
                  <span className={clsx('pill', x.status === 'arrived' ? 'pill-ok' : 'pill-info')}>{t(`pu.ship.status.${x.status}`)}</span>
                  <span className="font-mono">{x.container_no ?? `#${x.shipment_id}`}</span>
                  <span className="font-normal text-muted">· {x.shipment_mode ? t(`pu.ship.modes.${x.shipment_mode}`) : ''} · {t('pu.etaOn', { date: fmtDay(x.eta) })}</span>
                </p>
                {x.shipping_mark && <p className="text-muted">{t('pu.ship.mark')}: {x.shipping_mark}</p>}
                <p className="text-muted">{(x.lines ?? []).map((l) => `${l.item_code} ${fmtQty(l.received_qty)}/${fmtQty(l.qty)}`).join(' · ')}</p>
              </li>
            ))}
          </ul>
        )}
        <p className="border-t border-line px-5 py-3 text-xs text-muted">{t('pu.ship.atpNote')}</p>
      </SectionCard>
      <p className="sr-only">{poNo}</p>
    </div>
  );
}
const shipped = (info: PuInfo, line: number) => (info.shipments ?? []).filter((s) => s.status === 'in_transit')
  .reduce((a, s) => a + (s.lines ?? []).filter((l) => l.po_line === line).reduce((b, l) => b + Number(l.qty) - Number(l.received_qty), 0), 0);

/** QC photo: uploads to Supabase Storage bucket qc at <company>/<po>/<file>; the inspection stores the path. */
function QcPhotoUpload({ company, po, value, onChange }: { company: string; po: number; value: string; onChange: (p: string) => void }) {
  const { t } = useTranslation();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function pick(f: File | undefined) {
    if (!f) return;
    setErr(null); setBusy(true);
    const path = `${company}/${po}/${Date.now()}-${f.name.replace(/[^A-Za-z0-9._-]/g, '_')}`;
    try {
      const { error } = await supabase.storage.from('qc').upload(path, f, { upsert: false });
      if (error) throw error;
      onChange(path);
    } catch (e) { setErr(t('pu.qc.uploadFailed', { msg: errorMessage(e) })); } finally { setBusy(false); }
  }
  return (
    <div className="mt-2 space-y-1">
      <input type="file" accept="image/*" id="pu-qc-photo" disabled={busy} onChange={(e) => pick(e.target.files?.[0])} className="block w-full text-sm file:me-3 file:min-h-[40px] file:rounded-btn file:border file:border-line file:bg-surface file:px-3 file:text-ink" />
      {value && <p className="font-mono text-xs text-ok-fg">{value}</p>}
      {err && <p role="alert" className="text-xs text-crit-fg">{err}</p>}
    </div>
  );
}

// ---------- Purchase Quotation Comparison ----------
export function QuotationComparePage() {
  const { t } = useTranslation();
  const { company = '', request = '' } = useParams();
  const id = Number(request);
  const { canWrite } = useModuleLevel('purchasing');
  const q = useQuery({ queryKey: ['pu-compare', company, id], queryFn: () => puCompare(company, id) });
  if (q.isLoading) return <RequireModule module="purchasing"><PageLoading /></RequireModule>;
  if (q.error) return <RequireModule module="purchasing"><PuHeader kind="purchase_quotation" title={t('pu.compareTitle')} /><div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div></RequireModule>;
  const C = q.data!;
  const quotes = C.quotations;
  const reqOpen = C.request.status === 'open' && C.request.state === 'approved';
  return (
    <RequireModule module="purchasing">
      <PuHeader kind="purchase_quotation" title={t('pu.compareTitle')} pills={<LiveBadge live />}
        sub={t('pu.compareSub', { no: C.request.doc_no, date: fmtDay(C.request.due_date) })}
        actions={<>
          <Link to={`/docs/purchase_request/${company}/${id}`} className={secondaryLink}>{t('pu.openRequest', { no: C.request.doc_no })}</Link>
          {canWrite && reqOpen && <Link to={`/docs/purchase_quotation/new?company=${company}&fromObj=1470000113&from=${id}`} id="pu-compare-new" className={primaryLink}><Plus className="h-4 w-4" aria-hidden />{t('pu.addQuotation')}</Link>}
        </>} />
      <PuFlowStrip company={company} obj={1470000113} entry={id} current="quotation" />
      <SectionCard title={t('pu.compareCard', { n: quotes.length })}>
        {quotes.length === 0 ? <EmptyState title={t('pu.noQuotes')} body={t('pu.noQuotesBody')} /> : (
          <div className="overflow-x-auto">
            <table className="w-full text-[14px]" data-testid="pu-compare-table" style={{ minWidth: `${280 + quotes.length * 170}px` }}>
              <thead>
                <tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2.5 text-start">{t('so.item')}</th>
                  {quotes.map((x) => (
                    <th key={x.doc_entry} scope="col" className="px-4 py-2.5 text-end align-bottom normal-case tracking-normal">
                      <Link to={`/docs/purchase_quotation/${company}/${x.doc_entry}`} className="font-mono text-[13px] text-primary hover:underline">{x.doc_no}</Link>
                      <div dir="auto" className="text-[13px] font-semibold text-ink">{x.card_name ?? x.card_code}</div>
                      <div className="font-normal text-muted">{x.status === 'open' ? t('erp.status.open') : t(`erp.status.${x.status}`, { defaultValue: x.status })}</div>
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {C.lines.map((l) => (
                  <tr key={l.line_num} className="border-t border-line align-top">
                    <td className="px-4 py-2.5">
                      <div dir="auto" className="font-semibold">{l.description ?? l.item_code}</div>
                      <div className="text-xs text-muted"><span className="font-mono">{l.item_code}</span> · {fmtQty(l.quantity)} {l.uom}{l.last_price != null && <> · {t('pu.last', { price: fmtMoney(l.last_price) })}</>}</div>
                    </td>
                    {quotes.map((x) => {
                      const o = l.offers.find((f) => f.doc_entry === x.doc_entry);
                      return (
                        <td key={x.doc_entry} className={clsx('num px-4 py-2.5 text-end', o?.best && 'bg-ok-bg text-ok-fg')} data-best={o?.best ? 'true' : undefined}>
                          {o ? <><div className="font-semibold">{fmtMoney(o.price)}</div><div className="text-xs">{fmtMoney(o.line_total)}</div>{o.best && <div className="text-xs font-medium">{t('pu.best')}</div>}</> : <span className="text-muted">—</span>}
                        </td>
                      );
                    })}
                  </tr>
                ))}
                <tr className="border-t-2 border-line-strong font-semibold">
                  <td className="px-4 py-2.5">{t('pu.quoteTotal', { cur: C.request.currency })}</td>
                  {quotes.map((x) => <td key={x.doc_entry} className="num px-4 py-2.5 text-end">{fmtMoney(x.total)}</td>)}
                </tr>
                <tr className="border-t border-line">
                  <td className="px-4 py-2.5" />
                  {quotes.map((x) => (
                    <td key={x.doc_entry} className="px-4 py-2.5 text-end">
                      {canWrite && x.status === 'open' && x.state === 'approved'
                        ? <Link to={`/docs/purchase_order/new?company=${company}&fromObj=540000006&from=${x.doc_entry}`} id={`pu-choose-${x.doc_entry}`} className={`${primaryLink} justify-center`}>{t('pu.choose')}</Link>
                        : <span className="text-xs text-muted">{x.status !== 'open' ? t('pu.quoteClosed') : ''}</span>}
                    </td>
                  ))}
                </tr>
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>
    </RequireModule>
  );
}

// ---------- Copy-to pick table (PO → GRPO, GRPO → A/P invoice) ----------
interface Pick { key: string; line: PuCopyLine; sel: boolean; qty: string; whs: string }
const toPicks = (ls: PuCopyLine[]): Pick[] => ls.map((l) => ({ key: `${l.base_doc_entry}-${l.base_line}`, line: l, sel: true, qty: String(Number(l.open_qty)), whs: l.whs_code ?? '' }));
function PickLines({ rows, setRows, warehouses }: { rows: Pick[]; setRows: (f: (r: Pick[]) => Pick[]) => void; warehouses?: Array<{ code: string; name: string }> }) {
  const { t } = useTranslation();
  const set = (k: string, p: Partial<Pick>) => setRows((rs) => rs.map((r) => (r.key === k ? { ...r, ...p } : r)));
  if (!rows.length) return <EmptyState title={t('sc.nothingToCopy')} body={t('sc.nothingToCopyBody')} />;
  return (
    <ul className="divide-y divide-line">
      {rows.map((r, i) => {
        const l = r.line;
        const over = r.sel && (Number.isNaN(Number(r.qty)) || Number(r.qty) > Number(l.open_qty));
        return (
          <li key={r.key} data-testid="pu-pick" className={clsx('px-4 py-3', !r.sel && 'opacity-60', over && 'bg-warn-bg')}>
            <div className={clsx('grid grid-cols-2 items-end gap-3', warehouses ? 'md:grid-cols-[44px_minmax(0,1fr)_110px_120px_128px]' : 'md:grid-cols-[44px_minmax(0,1fr)_110px_128px]')}>
              <label className="col-span-2 flex min-h-[44px] items-center gap-3 md:col-span-1">
                <input type="checkbox" id={`pu-pick-${i}-sel`} className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked={r.sel} onChange={(e) => set(r.key, { sel: e.target.checked })} aria-label={t('sc.includeLine', { n: i + 1 })} />
                <span className="text-sm font-semibold md:hidden" dir="auto">{l.description ?? l.item_code}</span>
              </label>
              <div className="col-span-2 min-w-0 text-xs text-muted md:col-span-1">
                <div dir="auto" className="text-[15px] font-semibold text-ink max-md:hidden">{l.description ?? l.item_code}</div>
                <span className="font-mono">{l.item_code}</span> · <span className="font-mono">{l.base_doc_no}</span> {t('sc.lineN', { n: l.base_line + 1 })} · {t('sc.openN', { n: fmtQty(l.open_qty) })}
                {Number(l.in_transit ?? 0) > 0 && <> · {t('pu.inTransitN', { n: fmtQty(l.in_transit) })}</>}
              </div>
              <label className="block text-xs font-medium text-muted">{t('erp.col.qty')}
                <input id={`pu-pick-${i}-qty`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={r.qty} disabled={!r.sel} onChange={(e) => set(r.key, { qty: e.target.value })} aria-invalid={over} />
              </label>
              {warehouses && (
                <label className="block text-xs font-medium text-muted">{t('erp.col.warehouse')}
                  <select id={`pu-pick-${i}-whs`} className="input mt-1 px-2 text-[15px] text-ink" value={r.whs} disabled={!r.sel} onChange={(e) => set(r.key, { whs: e.target.value })}>
                    {warehouses.map((w) => <option key={w.code} value={w.code}>{w.code}</option>)}
                  </select>
                </label>
              )}
              <div className="text-end text-xs font-medium text-muted"><span>{t('erp.col.lineTotal')}</span>
                <span className="num mt-1 flex min-h-[44px] items-center justify-end text-[15px] font-semibold text-ink">{r.sel ? fmtMoney(r2(num(r.qty) * Number(l.price ?? 0))) : '—'}</span></div>
            </div>
            {over && <p className="mt-1 flex items-start gap-1 text-[13px] text-warn-fg"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{t('sc.moreThanOpen', { n: fmtQty(l.open_qty) })}</p>}
          </li>
        );
      })}
    </ul>
  );
}
const pickTotals = (rows: Pick[]) => rows.filter((r) => r.sel).reduce((a, r) => {
  const n = r2(num(r.qty) * Number(r.line.price ?? 0));
  return { net: r2(a.net + n), vat: r2(a.vat + r2((n * Number(r.line.tax_rate ?? 0)) / 100)) };
}, { net: 0, vat: 0 });

function CreateShell({ kind, title, sub, flow, error, children, aside }: { kind: DocKind; title: string; sub?: ReactNode; flow?: ReactNode; error: string | null; children: ReactNode; aside: ReactNode }) {
  return (
    <RequireModule module="purchasing">
      <PuHeader kind={kind} title={title} pills={<SourcePill source="erp" />} sub={sub} />
      {flow}
      <FormError message={error} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">{children}</div>
        <aside className="min-w-0 space-y-5">{aside}</aside>
      </div>
    </RequireModule>
  );
}

// ---------- New goods receipt PO (Copy to goods receipt from an approved PO) ----------
export function GrpoNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const company = params.get('company') ?? '';
  const po = Number(params.get('po')) || null;
  const { canWrite, readOnlyReason } = useModuleLevel('purchasing');
  const setup = usePuSetup(company || null);
  const src = useQuery({ queryKey: ['pu-copy', company, 22, po], enabled: Boolean(company && po), queryFn: () => puCopySource(company, 22, po) });
  const [rows, setRows] = useState<Pick[]>([]);
  const [date, setDate] = useState(today());
  const [ref, setRef] = useState('');
  const [comments, setComments] = useState('');
  const [series, setSeries] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (src.data) setRows(toPicks(src.data.lines)); }, [src.data]);
  if (!company || !po) return <RequireModule module="purchasing"><PuHeader kind="goods_receipt_po" title={t('pu.newGrpo')} /><div className="card"><EmptyState title={t('pu.pickPo')} body={t('pu.pickPoBody')} /></div></RequireModule>;
  if (src.isLoading) return <RequireModule module="purchasing"><PageLoading /></RequireModule>;
  if (src.error) return <RequireModule module="purchasing"><PuHeader kind="goods_receipt_po" title={t('pu.newGrpo')} /><div className="card"><ErrorState error={src.error} onRetry={() => src.refetch()} /></div></RequireModule>;
  const h = src.data!.header!;
  const tot = pickTotals(rows);
  const sel = rows.filter((r) => r.sel);
  async function submit() {
    setErr(null);
    if (!sel.length) { setErr(t('sc.chooseLines')); return; }
    setBusy(true);
    try {
      const res = await grpoCreate(company, { doc_date: date, customer_ref: ref, comments }, sel.map((r) => ({ base_doc_entry: r.line.base_doc_entry, base_line: r.line.base_line, qty: r.qty, whs_code: r.whs || null })), series);
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['pu-flow'] }); qc.invalidateQueries({ queryKey: ['pu-info'] });
      nav(`/docs/goods_receipt_po/${company}/${res.doc_entry}`, { state: { flash: t('pu.flash.grpo', { no: res.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  return (
    <CreateShell kind="goods_receipt_po" title={t('pu.newGrpo')} error={err} sub={[h.card_code, h.card_name, t('pu.fromPo', { no: h.doc_no })].filter(Boolean).join(' · ')}
      flow={<PuFlowStrip company={company} obj={22} entry={po} current="grpo" />}
      aside={
        <SectionCard title={t('sc.addTitle')}>
          <div className="space-y-3 p-5">
            <p className="text-sm text-muted">{t('pu.grpoWhat')}</p>
            <Button variant="primary" id="pu-grpo-submit" className="w-full" onClick={submit} disabled={busy || !canWrite || !sel.length} disabledReason={!canWrite ? readOnlyReason : undefined}>{busy ? t('so.saving') : t('pu.addGrpo')}</Button>
            <Link to={`/docs/purchase_order/${company}/${po}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
          </div>
        </SectionCard>
      }>
      <SectionCard title={t('erp.section.header')}>
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
          <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span><input id="pu-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label className="block text-xs font-medium text-muted">{t('pu.deliveryNote')}<input id="pu-ref" className="input mt-1 text-[15px] text-ink" value={ref} onChange={(e) => setRef(e.target.value)} /></label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.remarks')}<input id="pu-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={comments} onChange={(e) => setComments(e.target.value)} /></label>
          <SeriesPicker company={company} obj={20} value={series} onChange={setSeries} date={date} />
        </div>
      </SectionCard>
      <SectionCard title={t('pu.linesToReceive')}>
        <PickLines rows={rows} setRows={setRows} warehouses={setup.data?.warehouses} />
        <div className="flex justify-end border-t border-line"><PuTotals net={tot.net} vat={tot.vat} total={r2(tot.net + tot.vat)} currency={h.currency} /></div>
      </SectionCard>
    </CreateShell>
  );
}

// ---------- New A/P invoice (from a goods receipt; draws paid deposits) ----------
export function ApInvoiceNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const company = params.get('company') ?? '';
  const grpo = Number(params.get('grpo')) || null;
  const { canWrite: pw } = useModuleLevel('purchasing');
  const { canWrite: fw } = useModuleLevel('financials');
  const can = pw || fw;
  const src = useQuery({ queryKey: ['pu-copy', company, 20, grpo], enabled: Boolean(company && grpo), queryFn: () => puCopySource(company, 20, grpo) });
  const card = src.data?.header?.card_code ?? null;
  const dps = useQuery({
    queryKey: ['pu-dps', company, card], enabled: Boolean(company && card),
    queryFn: async () => {
      const [{ data: d, error: e1 }, { data: x, error: e2 }] = await Promise.all([
        erp().from('purchase_doc_list').select('doc_entry,doc_no,doc_date,total,paid,status').match({ company_code: company, obj_type: 204, card_code: card!, source: 'erp' }).neq('status', 'cancelled').order('doc_entry'),
        erp().from('ap_dp_draw').select('dp_entry,amount').eq('company_code', company),
      ]);
      if (e1 || e2) throw new ApiError((e1 ?? e2)!);
      const drawn = new Map<number, number>();
      for (const r of (x ?? []) as R[]) drawn.set(r.dp_entry, (drawn.get(r.dp_entry) ?? 0) + Number(r.amount));
      return ((d ?? []) as R[]).map((r): R => ({ ...r, drawn: drawn.get(r.doc_entry) ?? 0, avail: r2(Number(r.paid ?? 0) - (drawn.get(r.doc_entry) ?? 0)) }));
    },
  });
  const [rows, setRows] = useState<Pick[]>([]);
  const [draw, setDraw] = useState<Record<number, string>>({});
  const [date, setDate] = useState(today());
  const [due, setDue] = useState('');
  const [ref, setRef] = useState('');
  const [comments, setComments] = useState('');
  const [series, setSeries] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (src.data) setRows(toPicks(src.data.lines)); }, [src.data]);
  const tot = pickTotals(rows);
  const gross = r2(tot.net + tot.vat);
  useEffect(() => {
    if (!dps.data) return;
    let left = gross;
    const m: Record<number, string> = {};
    for (const d of dps.data) { const a = Math.max(Math.min(d.avail, left), 0); if (a > 0) { m[d.doc_entry] = String(a); left = r2(left - a); } }
    setDraw(m);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dps.data]);
  if (!company || !grpo) return <RequireModule module="purchasing"><PuHeader kind="ap_invoice" title={t('pu.newAp')} /><div className="card"><EmptyState title={t('pu.pickGrpo')} body={t('pu.pickGrpoBody')} /></div></RequireModule>;
  if (src.isLoading) return <RequireModule module="purchasing"><PageLoading /></RequireModule>;
  if (src.error) return <RequireModule module="purchasing"><PuHeader kind="ap_invoice" title={t('pu.newAp')} /><div className="card"><ErrorState error={src.error} onRetry={() => src.refetch()} /></div></RequireModule>;
  const h = src.data!.header!;
  const sel = rows.filter((r) => r.sel);
  const drawn = r2(Object.values(draw).reduce((a, v) => a + num(v), 0));
  async function submit() {
    setErr(null);
    if (!sel.length) { setErr(t('sc.chooseLines')); return; }
    setBusy(true);
    try {
      const res = await apInvoiceCreate(company, { doc_date: date, due_date: due || null, customer_ref: ref, comments,
        down_payments: Object.entries(draw).filter(([, v]) => num(v) > 0).map(([k, v]) => ({ doc_entry: Number(k), amount: v })) },
      sel.map((r) => ({ base_doc_entry: r.line.base_doc_entry, base_line: r.line.base_line, qty: r.qty })), series);
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['pu-flow'] });
      nav(`/docs/ap_invoice/${company}/${res.doc_entry}`, { state: { flash: t('pu.flash.ap', { no: res.doc_no, n: fmtMoney(res.total, h.currency) }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  return (
    <CreateShell kind="ap_invoice" title={t('pu.newAp')} error={err} sub={[h.card_code, h.card_name, t('pu.fromGrpo', { no: h.doc_no })].filter(Boolean).join(' · ')}
      flow={<PuFlowStrip company={company} obj={20} entry={grpo} current="invoice" />}
      aside={
        <SectionCard title={t('sc.addTitle')}>
          <div className="space-y-3 p-5">
            <p className="text-sm text-muted">{t('pu.apWhat')}</p>
            <Button variant="primary" id="pu-ap-submit" className="w-full" onClick={submit} disabled={busy || !can || !sel.length} disabledReason={!can ? t('pu.apReadOnly') : undefined}>{busy ? t('so.saving') : t('pu.addAp')}</Button>
            <Link to={`/docs/goods_receipt_po/${company}/${grpo}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
          </div>
        </SectionCard>
      }>
      <SectionCard title={t('erp.section.header')}>
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <label className="block text-xs font-medium text-muted">{t('pu.supplierInvoice')}<input id="pu-ref" className="input mt-1 text-[15px] text-ink" value={ref} onChange={(e) => setRef(e.target.value)} /></label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span><input id="pu-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.dueDate')}<input id="pu-due_date" type="date" className="input num mt-1 text-[15px] text-ink" value={due} onChange={(e) => setDue(e.target.value)} /><span className="mt-1 block">{t('sc.dueFromTerms')}</span></label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.remarks')}<input id="pu-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={comments} onChange={(e) => setComments(e.target.value)} /></label>
          <SeriesPicker company={company} obj={18} value={series} onChange={setSeries} date={date} />
        </div>
      </SectionCard>
      <SectionCard title={t('pu.linesToInvoice')}><PickLines rows={rows} setRows={setRows} /></SectionCard>
      <SectionCard title={t('pu.depositsToDraw')}>
        {!dps.data?.length ? <p className="p-5 text-sm text-muted">{t('pu.noDeposits')}</p> : (
          <ul className="divide-y divide-line">
            {dps.data.map((d) => (
              <li key={d.doc_entry} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm" data-testid="pu-draw-row">
                <div><span className="font-mono font-semibold">{d.doc_no}</span> <span className="num">{fmtMoney(d.total, h.currency)}</span>
                  <p className="text-muted">{Number(d.paid ?? 0) <= 0 ? t('pu.dpNotPaid') : t('pu.dpAvail', { n: fmtMoney(d.avail, h.currency) })}</p></div>
                <input id={`pu-draw-${d.doc_entry}`} aria-label={t('pu.drawAmount', { no: d.doc_no })} inputMode="decimal" className="input num w-36 text-end text-[15px] text-ink" value={draw[d.doc_entry] ?? ''} onChange={(e) => setDraw({ ...draw, [d.doc_entry]: e.target.value })} />
              </li>
            ))}
          </ul>
        )}
        <div className="flex justify-end border-t border-line">
          <PuTotals net={tot.net} vat={tot.vat} total={r2(gross - drawn)} currency={h.currency}
            extra={[[t('pu.totals.gross'), fmtMoney(gross)], [t('pu.totals.drawn'), drawn ? `−${fmtMoney(drawn)}` : fmtMoney(0)]]} />
        </div>
      </SectionCard>
    </CreateShell>
  );
}

// ---------- Goods receipt PO / A/P down payment invoice / A/P invoice page ----------
export function PurchaseViewPage({ kind }: { kind: PurchaseViewKind }) {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const obj = VIEW_OBJ[kind];
  const [flash] = useFlash();
  const q = useDocLines(company, obj, id, kind);
  const view = usePuView(company, obj, id);
  const V = view.data;
  const d = q.data?.doc;
  let body: ReactNode = null;
  if (q.isLoading || view.isLoading) body = <PageLoading />;
  else if (q.error || view.error) body = <div className="card"><ErrorState error={q.error ?? view.error} onRetry={() => { q.refetch(); view.refetch(); }} /></div>;
  else if (!d) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  if (body) return <RequireModule module="purchasing"><PuHeader kind={kind} title={t(`erp.doc.${kind}`)} />{body}</RequireModule>;
  const lines = q.data!.lines;
  const cur = d!.currency ?? '';
  const net = lines.reduce((s, l) => s + Number(l.line_total ?? 0), 0);
  const erpDoc = d!.source === 'erp';
  const payTo = V?.open_amount && V.open_amount > 0 ? `/banking/payments/out/new?company=${company}&card=${encodeURIComponent(d!.card_code)}&apply=${obj}:${id}:${V.open_amount}` : null;
  return (
    <RequireModule module="purchasing">
      <PuHeader kind={kind} title={t(`pu.title.${kind}`, { no: V?.doc_no ?? d!.doc_num })} pills={<><StatusTag value={d!.status} /><SourcePill source={d!.source} /><LiveBadge live /></>}
        sub={[d!.card_name, V?.created_by_name, V?.created_at ? t('so.createdAt', { when: fmtWhen(V.created_at) }) : null].filter(Boolean).join(' · ')}
        actions={<>
          {kind === 'goods_receipt_po' && (V?.can_copy
            ? <Link to={`/purchasing/ap-invoice/new?company=${company}&grpo=${id}`} id="pu-copy-ap" className={primaryLink}>{t('pu.copyToAp')}</Link>
            : <Button variant="secondary" id="pu-copy-ap" disabled disabledReason={V?.copy_block ? t(`pu.copyBlock.${V.copy_block}`) : undefined}>{t('pu.copyToAp')}</Button>)}
          {kind === 'goods_receipt_po' && V?.can_landed_cost && <Link to={`/purchasing/landed-costs/new?company=${company}&grpo=${id}`} id="pu-landed" className={secondaryLink}>{t('pu.addLanded')}</Link>}
          {payTo && <Link to={payTo} id="pu-pay" className={primaryLink}>{t('pu.payInBanking')}</Link>}
          {kind === 'ap_down_payment' && V?.po_doc_entry && <Link to={`/docs/purchase_order/${company}/${V.po_doc_entry}#china`} className={secondaryLink}>{t('pu.openPo')}</Link>}
        </>} />
      <PuFlowStrip company={company} obj={obj} entry={id} />
      <Flash text={flash} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              [t('erp.col.supplier'), d!.card_code ? <Link className="text-primary hover:underline" to={`/bp/${company}/${encodeURIComponent(d!.card_code)}`}>{d!.card_code} · {d!.card_name}</Link> : null],
              [t('erp.col.postingDate'), fmtDay(d!.doc_date)],
              [t('erp.col.dueDate'), kind === 'goods_receipt_po' ? null : fmtDay(d!.due_date)],
              [kind === 'goods_receipt_po' ? t('pu.deliveryNote') : t('pu.supplierInvoice'), d!.customer_ref],
              [t('erp.col.remarks'), d!.comments],
              [t('erp.col.source'), sourceLabel(d!.source)],
            ]} />
          </SectionCard>
          <SectionCard title={t('erp.section.lines')}>
            <div className="overflow-x-auto">
              <table className="w-full text-[14px] sm:min-w-[560px]">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2.5 text-start">{t('so.item')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.qty')}</th>
                  {kind === 'goods_receipt_po' && erpDoc && <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('pu.col.notInvoiced')}</th>}
                  <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('so.unitPrice')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.lineTotal')}</th>
                </tr></thead>
                <tbody>
                  {lines.map((l) => (
                    <tr key={l.line_num} data-testid="pu-view-line" className="border-t border-line align-top">
                      <td className="px-4 py-2.5"><div dir="auto" className="font-semibold">{l.description ?? l.item_code}</div>
                        <div className="text-xs text-muted">{l.item_code && <span className="font-mono">{l.item_code}</span>}{l.whs_code ? ` · ${l.whs_code}` : ''}{l.tax_code ? ` · ${l.tax_code}` : ''}</div></td>
                      <td className="num px-4 py-2.5 text-end">{fmtQty(l.quantity)} <span className="text-muted">{l.uom}</span></td>
                      {kind === 'goods_receipt_po' && erpDoc && <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtQty(l.line_status === 'C' ? 0 : l.open_qty)}</td>}
                      <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(l.price)}</td>
                      <td className="num px-4 py-2.5 text-end font-medium">{fmtMoney(l.line_total)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="flex justify-end">
              <PuTotals net={r2(net)} vat={Number(d!.vat_total ?? 0)} total={Number(d!.total ?? 0)} currency={cur}
                extra={kind === 'ap_invoice' && V?.gross != null && (V.draws ?? []).length ? [[t('pu.totals.gross'), fmtMoney(V.gross)], [t('pu.totals.drawn'), `−${fmtMoney(r2(Number(V.gross) - Number(d!.total)))}`]] : undefined} />
            </div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('sc.postingTitle')}>
            <div className="space-y-2 p-5 text-sm" data-testid="pu-posting">
              {!erpDoc ? <p className="text-muted">{d!.source === 'sap' ? t('sc.sapPosted') : t('so.sampleReadOnly')}</p> : V?.trans_id ? (
                <>
                  <p className="font-semibold text-ok-fg">{t(`pu.posted.${kind}`)}</p>
                  <p>{t('sc.journal')} {V.can_read_journal ? <Link className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${V.trans_id}`}>{V.trans_id}</Link> : <span className="font-mono">{V.trans_id}</span>}</p>
                </>
              ) : <p className="text-muted">{t('sc.noJournal')}</p>}
              {V?.open_amount != null && <p data-testid="pu-open-amount">{t('pu.openToPay', { n: fmtMoney(V.open_amount, cur) })}</p>}
              {(V?.draws ?? []).map((x) => <p key={x.dp_entry}>{t('pu.drew', { no: x.doc_no, n: fmtMoney(x.amount, cur) })}</p>)}
              {(V?.drawn_by ?? []).map((x) => <p key={x.invoice_entry}>{t('pu.drawnBy', { no: x.doc_no, n: fmtMoney(x.amount, cur) })}</p>)}
              {(V?.landed_costs ?? []).map((x) => <p key={x.doc_entry}>{t('pu.landedOn')} <Link className="font-mono text-primary hover:underline" to={`/purchasing/landed-costs/${company}/${x.doc_entry}`}>{x.doc_no}</Link> <span className="num">{fmtMoney(x.total, cur)}</span></p>)}
            </div>
          </SectionCard>
          {(V?.activity?.length ?? 0) > 0 && <ActivityCard items={V!.activity} />}
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Landed costs ----------
export function LandedCostsPage() {
  const { t } = useTranslation();
  const m = moduleByKey('purchasing')!;
  const { canWrite: pw } = useModuleLevel('purchasing');
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'landed_cost_list', table: 'landed_cost_list',
    select: 'company_code,doc_entry,doc_no,doc_date,card_code,card_name,reference,total,to_inventory,to_cogs,currency,trans_id,grpos',
    searchCols: ['doc_no', 'reference', 'card_name', 'grpos'], searchLabel: t('pu.lc.search'),
    defaultSort: { col: 'doc_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.doc_entry}`,
    rowLink: (r) => `/purchasing/landed-costs/${r.company_code}/${r.doc_entry}`,
    columns: [
      { key: 'doc_no', header: t('erp.col.docNo'), mono: true },
      { key: 'doc_date', header: t('erp.col.date'), cell: (r) => fmtDay(r.doc_date), csv: (r) => r.doc_date },
      { key: 'grpos', header: t('pu.lc.receipts'), mono: true, hideBelow: 'md' },
      { key: 'card_name', header: t('pu.lc.broker'), hideBelow: 'lg', cell: (r) => r.card_name ?? '—' },
      { key: 'to_inventory', header: t('pu.lc.toInventory'), align: 'end', hideBelow: 'md', cell: (r) => fmtMoney(r.to_inventory) },
      { key: 'total', header: t('erp.col.total'), align: 'end', cell: (r) => fmtMoney(r.total, r.currency) },
    ],
  }), [t]);
  return (
    <RequireModule module="purchasing">
      <header className="mb-6">
        <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/purchasing'], [t('pu.lc.title'), undefined]]} />
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div><h1 className="flex flex-wrap items-center gap-3 text-[26px] font-semibold sm:text-[28px]">{t('pu.lc.title')} <LiveBadge live /></h1>
            <p className="mt-1 max-w-3xl text-[15px] text-muted">{t('pu.lc.desc')}</p></div>
          {pw ? <Link to="/purchasing/landed-costs/new" id="new-landed" className={primaryLink}><Plus className="h-4 w-4" aria-hidden />{t('pu.lc.new')}</Link> : null}
        </div>
      </header>
      <ListScreen config={cfg} />
    </RequireModule>
  );
}

interface LcRow { key: string; grpo_entry: number; grpo_line: number; grpo_no: string; item_code: string; description: string | null; qty: number; value: number; cbm: string; weight: string; sel: boolean }
let chgSeq = 0;
export function LandedCostNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const def = useDefaultCompany();
  const company = params.get('company') || def;
  const first = Number(params.get('grpo')) || null;
  const setup = usePuSetup(company || null);
  const S = setup.data;
  const { canWrite: pw } = useModuleLevel('purchasing');
  const { canWrite: fw } = useModuleLevel('financials');
  const can = pw || fw;
  const grpos = useQuery({
    queryKey: ['pu-grpos', company], enabled: Boolean(company),
    queryFn: async () => {
      const { data, error } = await erp().from('purchase_doc_list').select('doc_entry,doc_no,doc_date,card_name,total')
        .match({ company_code: company, obj_type: 20, source: 'erp' }).neq('status', 'cancelled').order('doc_entry', { ascending: false }).limit(50);
      if (error) throw new ApiError(error);
      return (data ?? []) as R[];
    },
  });
  const [rows, setRows] = useState<LcRow[]>([]);
  const [pick, setPick] = useState('');
  const [charges, setCharges] = useState<Array<{ key: string; code: string; amount: string }>>([]);
  const [h, setH] = useState({ doc_date: today(), reference: '', comments: '' });
  const [series, setSeries] = useState<number | null>(null);
  const [preview, setPreview] = useState<LcEval | null>(null);
  const [pErr, setPErr] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function addGrpo(entry: number) {
    if (rows.some((r) => r.grpo_entry === entry)) return;
    const ls = await grpoLines(company, entry);
    const no = grpos.data?.find((g) => g.doc_entry === entry)?.doc_no ?? String(entry);
    setRows((rs) => [...rs, ...ls.map((l) => ({ key: `${entry}-${l.line_num}`, grpo_entry: entry, grpo_line: l.line_num, grpo_no: no, item_code: l.item_code, description: l.description,
      qty: Number(l.quantity), value: Number(l.line_total), cbm: l.cbm != null ? String(Number(l.cbm)) : '', weight: '', sel: true }))]);
  }
  useEffect(() => { if (first && grpos.data && !rows.length) addGrpo(first); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [first, grpos.data]);
  useEffect(() => { if (S && !charges.length) setCharges([{ key: `c${++chgSeq}`, code: S.landed_cost_codes[0]?.code ?? '', amount: '' }]); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [S]);
  const sel = rows.filter((r) => r.sel);
  const payload = () => ({
    header: { doc_date: h.doc_date, reference: h.reference, comments: h.comments },
    lines: sel.map((r) => ({ grpo_entry: r.grpo_entry, grpo_line: r.grpo_line, cbm: r.cbm || null, weight: r.weight || null })),
    charges: charges.filter((c) => c.code && c.amount).map((c) => ({ code: c.code, amount: c.amount })),
  });
  const key = JSON.stringify(payload());
  useEffect(() => {
    const p = payload();
    if (!company || !p.lines.length || !p.charges.length) { setPreview(null); setPErr(null); return; }
    let live = true;
    const tm = setTimeout(() => { lcPreview(company, p.header, p.lines, p.charges).then((r) => { if (live) { setPreview(r); setPErr(null); } }).catch((e) => { if (live) { setPreview(null); setPErr(errorMessage(e)); } }); }, 400);
    return () => { live = false; clearTimeout(tm); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, company]);
  const setRow = (k: string, p: Partial<LcRow>) => setRows((rs) => rs.map((r) => (r.key === k ? { ...r, ...p } : r)));
  const method = (code: string) => S?.landed_cost_codes.find((c) => c.code === code)?.split_method;
  async function submit() {
    setErr(null); setBusy(true);
    try {
      const p = payload();
      const res = await lcCreate(company, p.header, p.lines, p.charges, series);
      qc.invalidateQueries({ queryKey: ['erp-list'] }); qc.invalidateQueries({ queryKey: ['pu-flow'] }); qc.invalidateQueries({ queryKey: ['pu-view'] });
      nav(`/purchasing/landed-costs/${company}/${res.doc_entry}`, { state: { flash: t('pu.flash.lc', { no: res.doc_no }) } });
    } catch (e) { setErr(errorMessage(e)); window.scrollTo({ top: 0, behavior: 'smooth' }); } finally { setBusy(false); }
  }
  const P = preview;
  return (
    <RequireModule module="purchasing">
      <PuHeader listTo="/purchasing/landed-costs" listLabel={t('pu.lc.title')} title={t('pu.lc.new')} pills={<SourcePill source="erp" />} sub={t('pu.lc.newSub')} />
      {first && <PuFlowStrip company={company} obj={20} entry={first} current="landed" />}
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-3">
              <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span><input id="lc-date" type="date" className="input num mt-1 text-[15px] text-ink" value={h.doc_date} onChange={(e) => setH({ ...h, doc_date: e.target.value })} /></label>
              <label className="block text-xs font-medium text-muted">{t('pu.lc.reference')}<input id="lc-ref" className="input mt-1 text-[15px] text-ink" value={h.reference} onChange={(e) => setH({ ...h, reference: e.target.value })} /></label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.remarks')}<input id="lc-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={h.comments} onChange={(e) => setH({ ...h, comments: e.target.value })} /></label>
              <SeriesPicker company={company} obj={69} value={series} onChange={setSeries} date={h.doc_date} />
            </div>
          </SectionCard>
          <SectionCard title={t('pu.lc.lines')} right={
            <div className="flex items-center gap-2">
              <select id="lc-grpo" aria-label={t('pu.lc.addReceipt')} className="input min-h-[40px] py-0 text-sm" value={pick} onChange={(e) => setPick(e.target.value)}>
                <option value="">{t('pu.lc.addReceipt')}</option>
                {grpos.data?.filter((g) => !rows.some((r) => r.grpo_entry === g.doc_entry)).map((g) => <option key={g.doc_entry} value={g.doc_entry}>{g.doc_no} · {g.card_name}</option>)}
              </select>
              <Button variant="secondary" id="lc-grpo-add" disabled={!pick} onClick={() => { addGrpo(Number(pick)); setPick(''); }}><Plus className="h-4 w-4" aria-hidden /></Button>
            </div>}>
            {rows.length === 0 ? <p className="p-5 text-sm text-muted">{t('pu.lc.noLines')}</p> : (
              <ul className="divide-y divide-line">
                {rows.map((r, i) => {
                  const pl = P?.lines.find((x) => x.grpo_entry === r.grpo_entry && x.grpo_line === r.grpo_line);
                  return (
                    <li key={r.key} className={clsx('px-4 py-3', !r.sel && 'opacity-60')} data-testid="lc-line">
                      <div className="grid grid-cols-2 items-end gap-3 md:grid-cols-[44px_minmax(0,1fr)_96px_96px_120px]">
                        <label className="col-span-2 flex min-h-[44px] items-center gap-3 md:col-span-1"><input type="checkbox" id={`lc-${i}-sel`} className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked={r.sel} onChange={(e) => setRow(r.key, { sel: e.target.checked })} aria-label={t('sc.includeLine', { n: i + 1 })} />
                          <span className="text-sm font-semibold md:hidden" dir="auto">{r.description ?? r.item_code}</span></label>
                        <div className="col-span-2 min-w-0 text-xs text-muted md:col-span-1"><div dir="auto" className="text-[15px] font-semibold text-ink max-md:hidden">{r.description ?? r.item_code}</div>
                          <span className="font-mono">{r.item_code}</span> · <span className="font-mono">{r.grpo_no}</span> · {fmtQty(r.qty)} · <span className="num">{fmtMoney(r.value)}</span></div>
                        <label className="block text-xs font-medium text-muted">{t('pu.cbm')}<input id={`lc-${i}-cbm`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={r.cbm} onChange={(e) => setRow(r.key, { cbm: e.target.value })} /></label>
                        <label className="block text-xs font-medium text-muted">{t('pu.lc.weight')}<input id={`lc-${i}-weight`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={r.weight} onChange={(e) => setRow(r.key, { weight: e.target.value })} /></label>
                        <div className="text-end text-xs font-medium text-muted"><span>{t('pu.lc.allocated')}</span>
                          <span className="num mt-1 flex min-h-[44px] items-center justify-end text-[15px] font-semibold text-ink" data-testid="lc-allocated">{pl ? fmtMoney(pl.allocated) : '—'}</span></div>
                      </div>
                      {pl && <p className="mt-1 text-xs text-muted">{t('pu.lc.avg', { from: fmtMoney(pl.avg_before), to: fmtMoney(pl.avg_after), oh: fmtQty(pl.on_hand) })}{Number(pl.to_cogs) > 0 && ` · ${t('pu.lc.cogsShare', { n: fmtMoney(pl.to_cogs) })}`}</p>}
                    </li>
                  );
                })}
              </ul>
            )}
          </SectionCard>
          <SectionCard title={t('pu.lc.charges')}>
            <ul className="divide-y divide-line">
              {charges.map((c, i) => (
                <li key={c.key} className="grid grid-cols-2 items-end gap-3 px-4 py-3 md:grid-cols-[minmax(0,1fr)_160px_44px]" data-testid="lc-charge">
                  <label className="col-span-2 block text-xs font-medium text-muted md:col-span-1">{t('pu.lc.code')}
                    <select id={`lc-charge-${i}-code`} className="input mt-1 text-[15px] text-ink" value={c.code} onChange={(e) => setCharges((cs) => cs.map((x) => (x.key === c.key ? { ...x, code: e.target.value } : x)))}>
                      <option value="">—</option>
                      {S?.landed_cost_codes.map((x) => <option key={x.code} value={x.code}>{x.name} · {t(`pu.lc.method.${x.split_method}`)}</option>)}
                    </select>
                  </label>
                  <label className="block text-xs font-medium text-muted">{t('pu.lc.amount', { cur: S?.currency ?? '' })}
                    <input id={`lc-charge-${i}-amount`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={c.amount} onChange={(e) => setCharges((cs) => cs.map((x) => (x.key === c.key ? { ...x, amount: e.target.value } : x)))} />
                  </label>
                  <div className="flex min-h-[44px] items-center justify-end">
                    <button type="button" onClick={() => setCharges((cs) => cs.filter((x) => x.key !== c.key))} aria-label={t('pu.lc.removeCharge', { n: i + 1 })} className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg"><Trash2 className="h-4 w-4" aria-hidden /></button>
                  </div>
                  {c.code && <p className="col-span-2 text-xs text-muted md:col-span-3">{t(`pu.lc.methodHint.${method(c.code) ?? 'qty'}`)}</p>}
                </li>
              ))}
            </ul>
            <div className="border-t border-line p-4"><Button variant="secondary" id="lc-charge-add" onClick={() => setCharges((cs) => [...cs, { key: `c${++chgSeq}`, code: '', amount: '' }])}><Plus className="h-4 w-4" aria-hidden />{t('pu.lc.addCharge')}</Button></div>
          </SectionCard>
          {P && <LcSplitTable lines={P.lines.map((l) => ({ ...l, allocs: Object.fromEntries(P.allocs.filter((a) => a.line_num === l.line_num).map((a) => [String(a.charge_no), a.amount])) }))} charges={P.charges} currency={P.totals.currency} />}
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('pu.lc.summary')}>
            <div className="space-y-3 p-5" data-testid="lc-summary">
              {pErr ? <p role="alert" className="text-sm text-crit-fg" dir="auto">{pErr}</p> : P ? (
                <dl className="num grid grid-cols-2 gap-y-1 text-[15px]">
                  <dt className="text-muted">{t('pu.lc.toInventory')}</dt><dd className="text-end">{fmtMoney(P.totals.to_inventory)}</dd>
                  <dt className="text-muted">{t('pu.lc.toCogs')}</dt><dd className="text-end">{fmtMoney(P.totals.to_cogs)}</dd>
                  <dt className="font-semibold">{t('pu.totals.total', { cur: P.totals.currency })}</dt><dd className="text-end font-semibold" data-testid="lc-total">{fmtMoney(P.totals.total)}</dd>
                </dl>
              ) : <p className="text-sm text-muted">{t('pu.lc.fill')}</p>}
              <p className="text-xs text-muted">{t('pu.lc.what')}</p>
              <Button variant="primary" id="lc-submit" className="w-full" onClick={submit} disabled={busy || !can || !P} disabledReason={!can ? t('pu.apReadOnly') : undefined}>{busy ? t('so.saving') : t('pu.lc.post')}</Button>
            </div>
          </SectionCard>
        </aside>
      </div>
    </RequireModule>
  );
}

function LcSplitTable({ lines, charges, currency }: { lines: Array<{ line_num: number; item_code: string; grpo_no: string; allocated: number; allocs?: Record<string, number> | null }>; charges: Array<{ charge_no: number; name: string; amount: number; split_method: string }>; currency: string }) {
  const { t } = useTranslation();
  return (
    <SectionCard title={t('pu.lc.split')}>
      <div className="overflow-x-auto">
        <table className="w-full text-[14px]" data-testid="lc-split" style={{ minWidth: `${220 + charges.length * 140}px` }}>
          <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
            <th scope="col" className="px-4 py-2.5 text-start">{t('so.item')}</th>
            {charges.map((c) => <th key={c.charge_no} scope="col" className="px-4 py-2.5 text-end normal-case tracking-normal"><div className="text-ink">{c.name}</div><div className="font-normal">{t(`pu.lc.method.${c.split_method}`)}</div></th>)}
            <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.total')}</th>
          </tr></thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.line_num} className="border-t border-line">
                <td className="px-4 py-2.5"><span className="font-mono">{l.item_code}</span> <span className="text-xs text-muted">· {l.grpo_no}</span></td>
                {charges.map((c) => <td key={c.charge_no} className="num px-4 py-2.5 text-end">{fmtMoney(l.allocs?.[String(c.charge_no)] ?? 0)}</td>)}
                <td className="num px-4 py-2.5 text-end font-semibold">{fmtMoney(l.allocated)}</td>
              </tr>
            ))}
            <tr className="border-t-2 border-line-strong font-semibold">
              <td className="px-4 py-2.5">{t('pu.totals.total', { cur: currency })}</td>
              {charges.map((c) => <td key={c.charge_no} className="num px-4 py-2.5 text-end">{fmtMoney(c.amount)}</td>)}
              <td className="num px-4 py-2.5 text-end">{fmtMoney(charges.reduce((a, c) => a + Number(c.amount), 0))}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p className="border-t border-line px-5 py-3 text-xs text-muted">{t('pu.lc.remainder')}</p>
    </SectionCard>
  );
}

export function LandedCostPage() {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const [flash] = useFlash();
  const q = useLcInfo(company, id);
  const L = q.data;
  if (q.isLoading) return <RequireModule module="purchasing"><PageLoading /></RequireModule>;
  if (q.error || !L) return <RequireModule module="purchasing"><PuHeader listTo="/purchasing/landed-costs" listLabel={t('pu.lc.title')} title={t('pu.lc.title')} /><div className="card">{q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : <EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} />}</div></RequireModule>;
  return (
    <RequireModule module="purchasing">
      <PuHeader listTo="/purchasing/landed-costs" listLabel={t('pu.lc.title')} title={t('pu.lc.titleN', { no: L.doc_no })} pills={<><span className="pill pill-ok">{t('pu.lc.posted')}</span><SourcePill source="erp" /><LiveBadge live /></>}
        sub={[L.card_name, L.created_by_name, t('so.createdAt', { when: fmtWhen(L.created_at) })].filter(Boolean).join(' · ')} />
      <PuFlowStrip company={company} obj={69} entry={id} current="landed" />
      <Flash text={flash} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[[t('erp.col.postingDate'), fmtDay(L.doc_date)], [t('pu.lc.reference'), L.reference], [t('erp.col.remarks'), L.comments],
              [t('pu.lc.toInventory'), fmtMoney(L.to_inventory, L.currency)], [t('pu.lc.toCogs'), fmtMoney(L.to_cogs, L.currency)], [t('erp.col.total'), fmtMoney(L.total, L.currency)]]} />
          </SectionCard>
          <LcSplitTable lines={L.lines} charges={L.charges} currency={L.currency} />
          <SectionCard title={t('pu.lc.avgTitle')}>
            <div className="overflow-x-auto">
              <table className="w-full text-[14px] sm:min-w-[560px]">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2.5 text-start">{t('so.item')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.onHand')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('pu.lc.toInventory')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('pu.lc.toCogs')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('pu.lc.avgCol')}</th>
                </tr></thead>
                <tbody>
                  {L.lines.map((l) => (
                    <tr key={l.line_num} className="border-t border-line" data-testid="lc-avg-row">
                      <td className="px-4 py-2.5"><span className="font-mono">{l.item_code}</span> <span className="text-xs text-muted">· {l.whs_code}</span></td>
                      <td className="num px-4 py-2.5 text-end">{fmtQty(l.on_hand)}</td>
                      <td className="num px-4 py-2.5 text-end">{fmtMoney(l.to_inventory)}</td>
                      <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(l.to_cogs)}</td>
                      <td className="num px-4 py-2.5 text-end">{fmtMoney(l.avg_before)} → <b>{fmtMoney(l.avg_after)}</b></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('sc.postingTitle')}>
            <div className="space-y-2 p-5 text-sm">
              <p className="font-semibold text-ok-fg">{t('pu.lc.postedNote')}</p>
              {L.trans_id && <p>{t('sc.journal')} {L.can_read_journal ? <Link className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${L.trans_id}`}>{L.trans_id}</Link> : <span className="font-mono">{L.trans_id}</span>}</p>}
            </div>
          </SectionCard>
          <ActivityCard items={L.activity.map((a) => ({ ...a, detail: null }))} />
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Purchasing Setup ----------
export function PurchasingSetupPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const m = moduleByKey('purchasing')!;
  const company = useDefaultCompany();
  const setup = usePuSetup(company || null);
  const lists = usePuLists(company || null);
  const { canWrite, readOnlyReason } = useModuleLevel('purchasing');
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [st, setSt] = useState({ default_tax_code: '', default_whs_code: '', require_qc_pass: false });
  useEffect(() => { const s = lists.data?.setting; if (s) setSt({ default_tax_code: s.default_tax_code ?? '', default_whs_code: s.default_whs_code ?? '', require_qc_pass: Boolean(s.require_qc_pass) }); }, [lists.data]);
  async function run(fn: () => Promise<unknown>, ok: string) {
    setErr(null); setMsg(null);
    try { await fn(); setMsg(ok); qc.invalidateQueries({ queryKey: ['pu-lists'] }); qc.invalidateQueries({ queryKey: ['pu-setup'] }); } catch (e) { setErr(errorMessage(e)); }
  }
  const L = lists.data;
  return (
    <RequireModule module="purchasing">
      <header className="mb-6">
        <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/purchasing'], [t('pu.setup.title'), undefined]]} />
        <h1 className="flex flex-wrap items-center gap-3 text-[26px] font-semibold sm:text-[28px]">{t('pu.setup.title')} <LiveBadge live /></h1>
        <p className="mt-1 max-w-3xl text-[15px] text-muted">{t('pu.setup.desc', { company })}</p>
      </header>
      {/* B3 · setup windows */}
      <nav aria-label={t('stp.setupWindows')} className="mb-5 flex flex-wrap gap-2" data-testid="stp-links"><Link id="pu-lc-types" to="/purchasing/landed-cost-types" className="inline-flex min-h-[40px] items-center rounded-btn border border-line bg-surface px-3 text-sm font-medium hover:bg-page">{t('stp.lc.title')}</Link></nav>
      <FormError message={err} />
      <Flash text={msg} />
      {lists.isLoading ? <PageLoading /> : lists.error ? <div className="card"><ErrorState error={lists.error} onRetry={() => lists.refetch()} /></div> : (
        <div className="grid gap-5 lg:grid-cols-2">
          <SectionCard title={t('pu.setup.defaults')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
              <label className="block text-xs font-medium text-muted">{t('pu.setup.tax')}
                <select id="ps-tax" className="input mt-1 text-[15px] text-ink" value={st.default_tax_code} disabled={!canWrite} onChange={(e) => setSt({ ...st, default_tax_code: e.target.value })}>
                  <option value="">—</option>{setup.data?.tax_codes.map((x) => <option key={x.code} value={x.code}>{x.code} · {x.name}</option>)}
                </select>
              </label>
              <label className="block text-xs font-medium text-muted">{t('pu.setup.whs')}
                <select id="ps-whs" className="input mt-1 text-[15px] text-ink" value={st.default_whs_code} disabled={!canWrite} onChange={(e) => setSt({ ...st, default_whs_code: e.target.value })}>
                  <option value="">—</option>{setup.data?.warehouses.map((x) => <option key={x.code} value={x.code}>{x.code} · {x.name}</option>)}
                </select>
              </label>
              <label className="flex min-h-[44px] items-center gap-3 text-[15px] sm:col-span-2">
                <input type="checkbox" id="ps-qc" className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked readOnly disabled aria-describedby="ps-qc-note" />{t('pu.setup.qcPass')}
              </label>
              <p id="ps-qc-note" className="-mt-2 text-[13px] text-muted sm:col-span-2">{t('pu.setup.qcAlways')}</p>
              <div className="sm:col-span-2"><Button variant="primary" id="ps-save" disabled={!canWrite} disabledReason={readOnlyReason} onClick={() => run(() => puSettingSet(company, st), t('pu.setup.saved'))}>{t('pu.setup.save')}</Button></div>
            </div>
          </SectionCard>
          <SetupList title={t('pu.setup.codes')} rows={(L?.codes ?? []).map((c) => ({ code: c.code, name: c.name, extra: c.split_method, active: c.active, sample: c.source }))} canWrite={canWrite} withMethod
            onSave={(r) => run(() => lcCodeSave(company, { code: r.code, name: r.name, split_method: r.extra, active: r.active }), t('pu.setup.saved'))} />
          <SetupList title={t('pu.setup.offices')} rows={(L?.offices ?? []).map((c) => ({ code: c.code, name: c.name, active: c.active }))} canWrite={canWrite}
            onSave={(r) => run(() => puListSave(company, 'china_office', { code: r.code, name: r.name, active: r.active }), t('pu.setup.saved'))} />
          <SetupList title={t('pu.setup.statuses')} rows={(L?.statuses ?? []).map((c) => ({ code: c.code, name: c.name, active: c.active }))} canWrite={canWrite}
            onSave={(r) => run(() => puListSave(company, 'pi_status', { code: r.code, name: r.name, active: r.active }), t('pu.setup.saved'))} />
          <SetupList title={t('pu.setup.checklist')} rows={(L?.checks ?? []).map((c) => ({ code: c.code, name: c.name, active: c.active }))} canWrite={canWrite}
            onSave={(r) => run(() => puListSave(company, 'qc_check', { code: r.code, name: r.name, active: r.active }), t('pu.setup.saved'))} />
          <SectionCard title={t('pu.setup.rules')}>
            <p className="p-5 text-sm text-muted">{t('pu.setup.rulesBody', { limit: setup.data?.my_po_limit != null ? fmtMoney(setup.data.my_po_limit, setup.data.currency) : '—', pct: setup.data?.price_increase_pct != null ? fmtQty(setup.data.price_increase_pct) : '—' })}</p>
          </SectionCard>
        </div>
      )}
    </RequireModule>
  );
}

interface SetupRow { code: string; name: string; extra?: string; active: boolean; sample?: string }
function SetupList({ title, rows, canWrite, withMethod, onSave }: { title: string; rows: SetupRow[]; canWrite: boolean; withMethod?: boolean; onSave: (r: SetupRow) => void }) {
  const { t } = useTranslation();
  const [n, setN] = useState<SetupRow>({ code: '', name: '', extra: 'qty', active: true });
  return (
    <SectionCard title={title}>
      {rows.length === 0 ? <p className="p-5 text-sm text-muted">{t('pu.setup.empty')}</p> : (
        <ul className="divide-y divide-line">
          {rows.map((r) => (
            <li key={r.code} className="flex flex-wrap items-center justify-between gap-2 px-5 py-2.5 text-sm">
              <span className="min-w-0"><span className="font-mono">{r.code}</span> · <span dir="auto">{r.name}</span>{withMethod && r.extra && <span className="text-muted"> · {t(`pu.lc.method.${r.extra}`)}</span>}
                {r.sample === 'sample' && <span className="pill pill-warning ms-2">{t('erp.sampleData')}</span>}</span>
              <span className="flex items-center gap-2">
                <StatusTag value={r.active ? 'active' : 'inactive'} />
                {canWrite && r.sample !== 'sap' && <Button variant="ghost" onClick={() => onSave({ ...r, active: !r.active })}>{r.active ? t('pu.setup.deactivate') : t('pu.setup.activate')}</Button>}
              </span>
            </li>
          ))}
        </ul>
      )}
      {canWrite && (
        <div className="grid grid-cols-2 items-end gap-3 border-t border-line p-4 sm:grid-cols-[110px_minmax(0,1fr)_auto_auto]">
          <label className="block text-xs font-medium text-muted">{t('erp.col.code')}<input className="input mt-1 font-mono text-[15px] text-ink" value={n.code} onChange={(e) => setN({ ...n, code: e.target.value })} /></label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.name')}<input className="input mt-1 text-[15px] text-ink" dir="auto" value={n.name} onChange={(e) => setN({ ...n, name: e.target.value })} /></label>
          {withMethod && (
            <label className="block text-xs font-medium text-muted">{t('pu.lc.splitBy')}
              <select className="input mt-1 text-[15px] text-ink" value={n.extra} onChange={(e) => setN({ ...n, extra: e.target.value })}>
                {['cbm', 'qty', 'value', 'weight'].map((x) => <option key={x} value={x}>{t(`pu.lc.method.${x}`)}</option>)}
              </select>
            </label>
          )}
          <Button variant="secondary" disabled={!n.code || !n.name} onClick={() => { onSave(n); setN({ code: '', name: '', extra: 'qty', active: true }); }}><Plus className="h-4 w-4" aria-hidden />{t('pu.setup.add')}</Button>
        </div>
      )}
    </SectionCard>
  );
}

/** "+ New …" on the purchasing lists: requests for anyone with Purchasing access, quotations and orders for full access. */
export function NewPurchaseAction({ kind }: { kind: DocKind }) {
  const { t } = useTranslation();
  const { level, canWrite, readOnlyReason } = useModuleLevel('purchasing');
  const map: Partial<Record<DocKind, { to: string; label: string; anyone?: boolean }>> = {
    purchase_request: { to: '/docs/purchase_request/new', label: t('pu.new.purchase_request'), anyone: true },
    purchase_quotation: { to: '/docs/purchase_quotation/new', label: t('pu.new.purchase_quotation') },
    purchase_order: { to: '/docs/purchase_order/new', label: t('pu.new.purchase_order') },
    goods_receipt_po: { to: '/docs/purchase_order?f_status=open', label: t('pu.newGrpo') },
    ap_invoice: { to: '/docs/goods_receipt_po?f_status=open', label: t('pu.newAp') },
  };
  const a = map[kind];
  if (!a) return null;
  const ok = a.anyone ? level !== null : canWrite;
  if (!ok) return <Button variant="primary" disabled id="new-purchase" disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {a.label}</Button>;
  return <Link to={a.to} id="new-purchase" className={primaryLink}><Plus className="h-4 w-4" aria-hidden /> {a.label}</Link>;
}
export const PURCHASE_LIST_KINDS: DocKind[] = ['purchase_request', 'purchase_quotation', 'purchase_order', 'goods_receipt_po', 'goods_return', 'ap_down_payment', 'ap_invoice', 'ap_credit_note'];
export const isPurchaseKind = (k: string) => (PURCHASE_LIST_KINDS as string[]).includes(k) && DOC_KINDS[k as DocKind].module === 'purchasing';
export type { WorkflowState };
