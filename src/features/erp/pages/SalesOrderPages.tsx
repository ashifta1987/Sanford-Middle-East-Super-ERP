import { useEffect, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, AlertTriangle, ArrowLeft, Check, ChevronRight, CircleCheck, CircleX, Pencil, Plus, Printer, Sparkles, Trash2, X } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { erp } from '@/lib/supabase';
import { ApiError, errorMessage } from '@/lib/format';
import i18n from '@/lib/i18n';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, SectionCard, StatusTag, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { Dialog } from '../components/Dialog';
import { moduleByKey } from '../modules';
import {
  itemPrice, itemStock, lineTotal, round2, searchCustomers, searchItems, soCancel, soChecks, soDecide, soSave, soSubmit, useSoInfo, useSoSetup,
  type CustomerHit, type ItemHit, type SoCheck, type SoEval, type SoHeaderInput, type SoInfo, type SoLineInput, type SoSetup, type WorkflowState,
} from '../salesOrder';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

// ---------- Small shared pieces ----------
const STATE_TONE: Record<WorkflowState, string> = {
  draft: 'pill-neutral', pending_approval: 'pill-warning', approved: 'pill-ok', rejected: 'pill-crit', cancelled: 'pill-crit',
};
export function StatePill({ state }: { state: WorkflowState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', STATE_TONE[state])}>{t(`so.state.${state}`)}</span>;
}
function sourceLabel(source: string) {
  return source === 'erp' ? 'Super ERP' : source === 'sap' ? 'SAP Business One' : i18n.t('erp.sampleData');
}
function SourcePill({ source }: { source: string }) {
  return <span className={clsx('pill', source === 'erp' ? 'pill-info' : 'pill-neutral')}>{sourceLabel(source)}</span>;
}
const fmtWhen = (iso: string | null | undefined) =>
  !iso ? '—' : new Intl.DateTimeFormat(i18n.language === 'ar' ? 'ar-AE' : 'en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
const pct = (n: unknown) => `${fmtQty(n)}%`;
function today() {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 10);
}

/** Quotation → Order → Delivery → Invoice → Payment. The order is the current step until delivery exists (A4). */
function FlowStrip() {
  const { t } = useTranslation();
  const steps = ['quotation', 'order', 'delivery', 'invoice', 'payment'] as const;
  return (
    <ol className="mb-5 flex flex-wrap items-center gap-1.5" aria-label={t('so.flow.label')}>
      {steps.map((s, i) => (
        <li key={s} className="flex items-center gap-1.5">
          {i > 0 && <ChevronRight className="h-3.5 w-3.5 text-muted rtl:rotate-180" aria-hidden />}
          <span aria-current={s === 'order' ? 'step' : undefined}
            className={clsx('inline-flex min-h-[32px] items-center rounded-full border px-3 text-[13px] font-medium',
              s === 'order' ? 'border-primary bg-primary-soft text-primary-text' : 'border-line bg-surface text-muted')}>
            {t(`so.flow.${s}`)}
          </span>
        </li>
      ))}
    </ol>
  );
}

function DocHeader({ title, pills, sub, actions, onBack }: { title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode; onBack?: (e: React.MouseEvent) => void }) {
  const { t } = useTranslation();
  const m = moduleByKey('sales')!;
  return (
    <header className="mb-4">
      <Link to="/docs/sales_order" onClick={onBack} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('so.back')}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/sales'], [t('erp.doc.sales_order'), '/docs/sales_order'], [title, undefined]]} />
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

function Totals({ before, discount, vat, total, currency }: { before: number; discount: number; vat: number; total: number; currency: string }) {
  const { t } = useTranslation();
  return (
    <dl className="num ms-auto grid w-full max-w-xs grid-cols-2 gap-x-6 gap-y-1 border-t border-line p-5 text-[15px] sm:border-t-0">
      <dt className="text-muted">{t('so.totals.before')}</dt><dd className="text-end">{fmtMoney(before)}</dd>
      <dt className="text-muted">{t('so.totals.discount')}</dt><dd className="text-end">{discount ? `−${fmtMoney(discount)}` : fmtMoney(0)}</dd>
      <dt className="text-muted">{t('so.totals.vat')}</dt><dd className="text-end">{fmtMoney(vat)}</dd>
      <dt className="text-[17px] font-semibold">{t('so.totals.total', { cur: currency })}</dt><dd className="text-end text-[17px] font-semibold" data-testid="so-total">{fmtMoney(total)}</dd>
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

function ruleLabel(rule: string, limit?: number | null) {
  if (rule === 'discount_pct') return limit != null ? i18n.t('so.rule.discountLimit', { n: fmtQty(limit) }) : i18n.t('so.rule.discount_pct');
  return i18n.t(`so.rule.${rule}`);
}

/** The server words checks for the requester ("your limit"); others see whose limit it is. */
function checkText(c: SoCheck, info: SoInfo | null | undefined) {
  if (!info || info.is_submitter || c.rule_code !== 'discount_pct') return c.message;
  return i18n.t('so.checkDiscountOther', { line: c.line, value: fmtQty(c.value), limit: fmtQty(c.limit), name: info.submitted_by_name ?? '—' });
}

function AskAiCard() {
  const { t } = useTranslation();
  return (
    <SectionCard title={<span className="inline-flex items-center gap-2"><Sparkles className="h-4 w-4" aria-hidden />{t('so.askAi')}</span>} right={<span className="pill pill-neutral">{t('erp.planned')}</span>}>
      <p className="p-5 text-sm text-muted">{t('so.askAiBody')}</p>
    </SectionCard>
  );
}

// ---------- Form (new / edit) ----------
interface FormLine extends SoLineInput { key: string; text: string; name: string; uom: string | null; hit: ItemHit | null }
let lineSeq = 0;
const newLine = (tax: string): FormLine => ({ key: `l${++lineSeq}`, item_code: '', qty: '1', price: '', discount_pct: '0', tax_code: tax, text: '', name: '', uom: null, hit: null });

interface FormInitial { entry: number; docNo: string; header: SoHeaderInput; customer: CustomerHit | null; lines: FormLine[] }

export function SalesOrderNewPage() {
  return <RequireModule module="sales"><SalesOrderForm /></RequireModule>;
}

export function SalesOrderEditPage() {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const q = useQuery({
    queryKey: ['so-edit', company, id],
    queryFn: async (): Promise<{ init: FormInitial; info: SoInfo | null } | null> => {
      const { data: d, error } = await erp().from('document').select('*').match({ company_code: company, obj_type: 17, doc_entry: id }).maybeSingle();
      if (error) throw new ApiError(error);
      if (!d) return null;
      const doc = d as R;
      const [{ data: ls, error: le }, { data: bp }, info] = await Promise.all([
        erp().from('document_line').select('*').match({ company_code: company, obj_type: 17, doc_entry: id }).order('line_num'),
        erp().from('business_partner').select('card_code,name,city,phone,trn,balance,credit_limit,price_list,payment_terms,slp_code,currency')
          .match({ company_code: company, card_code: doc.card_code ?? '' }).maybeSingle(),
        erp().rpc('sales_order_info', { p_company: company, p_doc_entry: id }).then((r) => { if (r.error) throw new ApiError(r.error); return r.data as SoInfo | null; }),
      ]);
      if (le) throw new ApiError(le);
      const lines: FormLine[] = ((ls ?? []) as R[]).map((l) => ({
        key: `l${++lineSeq}`, item_code: l.item_code, qty: String(Number(l.quantity)), price: String(Number(l.price)), discount_pct: String(Number(l.discount_pct ?? 0)),
        tax_code: l.tax_code ?? '', text: `${l.item_code} · ${l.description ?? ''}`, name: l.description ?? '', uom: l.uom, hit: null,
      }));
      return {
        info,
        init: {
          entry: id, docNo: info?.doc_no ?? String(doc.doc_num), customer: (bp as CustomerHit | null) ?? null, lines,
          header: {
            card_code: doc.card_code ?? '', doc_date: doc.doc_date ?? today(), due_date: doc.due_date ?? '', price_list: info?.price_list ?? '',
            payment_terms: info?.payment_terms ?? '', slp_code: doc.slp_code ?? '', whs_code: info?.whs_code ?? '', customer_ref: doc.customer_ref ?? '', comments: doc.comments ?? '',
          },
        },
      };
    },
  });
  let body: ReactNode;
  if (q.isLoading) body = <PageLoading />;
  else if (q.error) body = <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>;
  else if (!q.data) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  else if (!q.data.info?.workflow || !q.data.info.can_edit) {
    body = (
      <div className="card p-8 text-center" role="alert">
        <AlertCircle className="mx-auto h-8 w-8 text-muted" aria-hidden />
        <p className="mt-3 font-medium">{t('so.cantEdit')}</p>
        <p className="mt-1 text-sm text-muted">{q.data.info?.state === 'pending_approval' ? t('so.cantEditPending') : t('so.cantEditBody')}</p>
        <Link to={`/docs/sales_order/${company}/${id}`} className="mt-5 inline-flex min-h-[44px] items-center rounded-btn border border-line px-4 font-medium hover:bg-page">{t('so.viewOrder')}</Link>
      </div>
    );
  } else body = <SalesOrderForm company={company} initial={q.data.init} />;
  return <RequireModule module="sales">{body}</RequireModule>;
}

function SalesOrderForm({ company: fixedCompany, initial }: { company?: string; initial?: FormInitial }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  const companies = profile?.companies ?? [];
  const [company, setCompany] = useState<string>(fixedCompany ?? (top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? ''));
  const setup = useSoSetup(company || null);
  const S: SoSetup | undefined = setup.data;

  const [entry, setEntry] = useState<number | null>(initial?.entry ?? null);
  const [docNo, setDocNo] = useState<string | null>(initial?.docNo ?? null);
  const [header, setHeader] = useState<SoHeaderInput>(initial?.header ?? {
    card_code: '', doc_date: today(), due_date: '', price_list: '', payment_terms: '', slp_code: '', whs_code: '', customer_ref: '', comments: '',
  });
  const [customer, setCustomer] = useState<CustomerHit | null>(initial?.customer ?? null);
  const [custText, setCustText] = useState(initial?.customer ? `${initial.customer.card_code} · ${initial.customer.name}` : initial?.header.card_code ?? '');
  const [lines, setLines] = useState<FormLine[]>(initial?.lines.length ? initial.lines : [newLine('')]);
  const [removed, setRemoved] = useState<{ line: FormLine; index: number } | null>(null);
  const [reason, setReason] = useState('');
  const [reasonErr, setReasonErr] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [attempted, setAttempted] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const [busy, setBusy] = useState<'save' | 'submit' | null>(null);
  const [preview, setPreview] = useState<SoEval | null>(null);

  // Defaults from the company settings (only where the user has not chosen).
  useEffect(() => {
    if (!S) return;
    setHeader((h) => (h.whs_code ? h : { ...h, whs_code: S.default_whs_code ?? S.warehouses[0]?.code ?? '' }));
    setLines((ls) => ls.map((l) => (l.tax_code ? l : { ...l, tax_code: S.default_tax_code ?? '' })));
  }, [S]);

  // Unsaved changes: the browser asks before leaving the page.
  useEffect(() => {
    if (!dirty) return;
    const h = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', h);
    return () => window.removeEventListener('beforeunload', h);
  }, [dirty]);

  const setH = (patch: Partial<SoHeaderInput>) => { setHeader((h) => ({ ...h, ...patch })); setDirty(true); };
  const setL = (key: string, patch: Partial<FormLine>) => { setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l))); setDirty(true); };
  const priceList = header.price_list === '' ? customer?.price_list ?? '' : header.price_list;

  // Live check against the server rules (debounced). The server is the authority; this only previews.
  const filled = lines.filter((l) => l.item_code);
  const previewKey = JSON.stringify([company, entry, header, filled.map(({ item_code, qty, price, discount_pct, tax_code }) => [item_code, qty, price, discount_pct, tax_code])]);
  useEffect(() => {
    if (!company || !header.card_code || !filled.length) { setPreview(null); return; }
    let live = true;
    const h = setTimeout(() => {
      soChecks(company, entry, header, filled).then((r) => { if (live) setPreview(r); }).catch(() => { if (live) setPreview(null); });
    }, 450);
    return () => { live = false; clearTimeout(h); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey]);

  // Browser-side totals while typing.
  const rate = (code: string) => Number(S?.tax_codes.find((x) => x.code === code)?.rate ?? 0);
  const calc = lines.map((l) => {
    const price = l.price !== '' ? Number(l.price) : l.hit ? Number(itemPrice(l.hit, priceList) ?? 0) : 0;
    const qty = Number(l.qty) || 0;
    const disc = Number(l.discount_pct) || 0;
    const net = l.item_code ? lineTotal(qty, price, disc) : 0;
    return { price, gross: l.item_code ? round2(qty * price) : 0, net, vat: round2((net * rate(l.tax_code)) / 100) };
  });
  const sum = (k: 'gross' | 'net' | 'vat') => round2(calc.reduce((s, c) => s + c[k], 0));
  const totals = { before: sum('gross'), discount: round2(sum('gross') - sum('net')), vat: sum('vat'), total: round2(sum('net') + sum('vat')) };
  const currency = S?.currency ?? companies.find((c) => c.company_code === company)?.currency ?? '';

  const problems = attempted ? preview?.errors ?? [] : [];
  const fieldErr = (field: string, line: number | null = null) => problems.find((p) => p.field === field && p.line === line)?.message;
  const checks = preview?.errors.length ? [] : preview?.checks ?? [];
  const lineChecks = (i: number) => checks.filter((c) => c.line === i + 1);
  const needsApproval = checks.length > 0;
  const rules = [...new Set(checks.map((c) => ruleLabel(c.rule_code, c.rule_code === 'discount_pct' ? c.limit : null)))];

  function addLine(focus = true) {
    const l = newLine(S?.default_tax_code ?? '');
    setLines((ls) => [...ls, l]);
    setDirty(true);
    if (focus) setTimeout(() => document.getElementById(`line-${l.key}-item`)?.focus(), 30);
  }
  function removeLine(key: string) {
    const index = lines.findIndex((l) => l.key === key);
    if (index < 0) return;
    setRemoved({ line: lines[index], index });
    setLines((ls) => (ls.length === 1 ? [newLine(S?.default_tax_code ?? '')] : ls.filter((l) => l.key !== key)));
    setDirty(true);
  }
  function undoRemove() {
    if (!removed) return;
    setLines((ls) => { const next = ls.filter((l) => l.item_code || ls.length > 1); next.splice(removed.index, 0, removed.line); return next; });
    setRemoved(null);
  }
  const enterAdds = (e: React.KeyboardEvent) => { if (e.key === 'Enter') { e.preventDefault(); addLine(); } };

  function back(e: React.MouseEvent) {
    if (dirty && !window.confirm(t('so.leave'))) e.preventDefault();
  }

  async function save(submit: boolean) {
    setAttempted(true);
    setServerError(null);
    setReasonErr(null);
    if (submit && needsApproval && !reason.trim()) { setReasonErr(t('so.reasonNeeded')); document.getElementById('so-reason')?.focus(); return; }
    setBusy(submit ? 'submit' : 'save');
    let saved = entry;
    try {
      const res = await soSave(company, entry, header, filled);
      saved = res.doc_entry;
      setEntry(res.doc_entry); setDocNo(res.doc_no);
      let state = res.state;
      if (submit) state = (await soSubmit(company, res.doc_entry, reason.trim() || null)).state;
      setDirty(false);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      qc.invalidateQueries({ queryKey: ['approval-inbox'] });
      // Drop cached copies so the order page never shows the old state while it reloads.
      qc.removeQueries({ queryKey: ['so-info', company, res.doc_entry] });
      qc.removeQueries({ queryKey: ['so-edit', company, res.doc_entry] });
      qc.removeQueries({ queryKey: ['doc', 'sales_order', company, String(res.doc_entry)] });
      const flash = !submit ? t('so.flash.saved') : state === 'approved' ? t('so.flash.open') : t('so.flash.pending');
      nav(`/docs/sales_order/${company}/${res.doc_entry}`, { state: { flash } });
    } catch (e) {
      if (saved !== entry) setDirty(false);
      setServerError(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally {
      setBusy(null);
    }
  }

  const blocked = !canWrite ? readOnlyReason : S && !S.numbering && !entry ? t('so.noNumbering', { company }) : undefined;
  const title = docNo ? t('so.titleNo', { no: docNo }) : t('so.titleNew');

  const custOpts = async (q: string): Promise<Array<ComboOption<CustomerHit>>> => (await searchCustomers(company, q)).map((c) => ({
    value: c.card_code, label: `${c.card_code} · ${c.name}`, data: c,
    meta: `${[c.city, c.phone].filter(Boolean).join(' · ')} · ${t('so.balance')} ${fmtMoney(c.balance)}${c.credit_limit != null ? ` · ${t('so.creditLeft')} ${fmtMoney(Number(c.credit_limit) - Number(c.balance ?? 0))}` : ''}`,
  }));
  const itemOpts = async (q: string): Promise<Array<ComboOption<ItemHit>>> => (await searchItems(company, q)).map((it) => ({
    value: it.item_code, label: `${it.item_code} · ${it.name}`, data: it,
    meta: `${t('so.inStock', { n: fmtQty(itemStock(it, header.whs_code) ?? 0) })} · ${fmtMoney(itemPrice(it, priceList), currency)}${it.barcode ? ` · ${it.barcode}` : ''}`,
  }));

  return (
    <div>
      <DocHeader title={title} onBack={back}
        pills={<><StatePill state="draft" /><SourcePill source="erp" /></>}
        sub={customer ? [customer.name, customer.city].filter(Boolean).join(' · ') : t('so.subNew')}
        actions={
          <Button variant="secondary" disabled disabledReason={t('so.copyLater')} id="so-copy">{t('so.copyToDelivery')}</Button>
        } />
      <FlowStrip />

      {(serverError || problems.length > 0) && (
        <div role="alert" className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-crit-fg">
          <p className="flex items-start gap-2 font-semibold"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="so-error">{serverError ?? t('so.fixProblems')}</span></p>
          {problems.length > 0 && (
            <ul className="mt-2 list-disc space-y-1 ps-8 text-sm">
              {problems.map((p, i) => (
                <li key={i}><a className="underline" href={`#${p.line ? `line-${lines[p.line - 1]?.key}-${p.field === 'item_code' ? 'item' : p.field}` : `so-${p.field}`}`}>{p.message}</a></li>
              ))}
            </ul>
          )}
        </div>
      )}

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
              {!fixedCompany && companies.length > 1 && !entry && (
                <label className="block text-xs font-medium text-muted">{t('so.company')}
                  <select id="so-company" className="input mt-1 text-[15px] text-ink" value={company} onChange={(e) => { setCompany(e.target.value); setCustomer(null); setCustText(''); setH({ card_code: '', whs_code: '' }); }}>
                    {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
                  </select>
                </label>
              )}
              <Combobox<CustomerHit> id="so-card_code" label={t('erp.col.customer')} required text={custText} onText={(s) => { setCustText(s); if (customer) { setCustomer(null); setH({ card_code: '' }); } }}
                search={custOpts} placeholder={t('so.customerPh')} error={fieldErr('card_code')} noMatch={t('so.combo.noCustomer')}
                onSelect={(o) => { setCustomer(o.data); setCustText(o.label); setH({ card_code: o.value, price_list: '', payment_terms: '', slp_code: '' }); }} />
              <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
                <input id="so-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={header.doc_date} onChange={(e) => setH({ doc_date: e.target.value })} aria-invalid={Boolean(fieldErr('doc_date'))} />
                {fieldErr('doc_date') && <span className="mt-1 block text-crit-fg">{fieldErr('doc_date')}</span>}
              </label>
              <label className="block text-xs font-medium text-muted">{t('so.deliveryDate')}
                <input id="so-due_date" type="date" className="input num mt-1 text-[15px] text-ink" value={header.due_date} onChange={(e) => setH({ due_date: e.target.value })} aria-invalid={Boolean(fieldErr('due_date'))} />
                {fieldErr('due_date') && <span className="mt-1 block text-crit-fg">{fieldErr('due_date')}</span>}
              </label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.priceList')}
                <select id="so-price_list" className="input mt-1 text-[15px] text-ink" value={header.price_list} onChange={(e) => setH({ price_list: e.target.value === '' ? '' : Number(e.target.value) })}>
                  <option value="">{t('so.customerDefault')}{customer?.price_list != null ? ` (${S?.price_lists.find((p) => p.code === customer.price_list)?.name ?? customer.price_list})` : ''}</option>
                  {S?.price_lists.map((p) => <option key={p.code} value={p.code}>{p.name}</option>)}
                </select>
              </label>
              <label className="block text-xs font-medium text-muted">{t('so.paymentTerms')}
                <select id="so-payment_terms" className="input mt-1 text-[15px] text-ink" value={header.payment_terms} onChange={(e) => setH({ payment_terms: e.target.value === '' ? '' : Number(e.target.value) })}>
                  <option value="">{t('so.customerDefault')}{customer?.payment_terms != null ? ` (${S?.payment_terms.find((p) => p.code === customer.payment_terms)?.name ?? customer.payment_terms})` : ''}</option>
                  {S?.payment_terms.map((p) => <option key={p.code} value={p.code}>{p.name}</option>)}
                </select>
                {preview?.credit?.left != null && <span className="num mt-1 block">{t('so.creditLeft')} {fmtMoney(preview.credit.left, currency)}</span>}
              </label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.warehouse')} <span className="text-crit-fg">*</span>
                <select id="so-whs_code" className="input mt-1 text-[15px] text-ink" value={header.whs_code} onChange={(e) => setH({ whs_code: e.target.value })}>
                  {S?.warehouses.map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}
                </select>
                {fieldErr('whs_code') && <span className="mt-1 block text-crit-fg">{fieldErr('whs_code')}</span>}
              </label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.customerRef')}
                <input id="so-customer_ref" className="input mt-1 text-[15px] text-ink" dir="auto" value={header.customer_ref} onChange={(e) => setH({ customer_ref: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted sm:col-span-2">{t('erp.col.remarks')}
                <input id="so-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={header.comments} onChange={(e) => setH({ comments: e.target.value })} />
              </label>
            </div>
          </SectionCard>

          <SectionCard title={t('erp.section.lines')} right={<span className="text-sm text-muted">{t('so.enterAdds')}</span>}>
            <ul className="divide-y divide-line">
              {lines.map((l, i) => {
                const lc = lineChecks(i);
                const lineProblems = problems.filter((p) => p.line === i + 1);
                const stock = l.hit ? itemStock(l.hit, header.whs_code) : null;
                const listPrice = l.hit ? itemPrice(l.hit, priceList) : null;
                return (
                  <li key={l.key} data-testid="so-line" className={clsx('px-4 py-3', lc.length > 0 && 'bg-warn-bg')}>
                    <div className="grid grid-cols-2 items-end gap-3 md:grid-cols-[96px_128px_96px_128px_minmax(0,1fr)_44px]">
                      <div className="col-span-2 min-w-0 md:col-span-6">
                        <Combobox<ItemHit> id={`line-${l.key}-item`} label={t('so.itemN', { n: i + 1 })}
                          text={l.text} onText={(s) => setL(l.key, { text: s, ...(l.item_code ? { item_code: '', hit: null, name: '' } : {}) })}
                          search={itemOpts} placeholder={t('so.itemPh')} noMatch={t('so.combo.noItem')}
                          onSelect={(o) => setL(l.key, { item_code: o.value, text: o.label, name: o.data.name, uom: o.data.sales_uom, hit: o.data, price: '' })} />
                        {l.item_code && (
                          <p className="mt-1 text-xs text-muted">
                            <span className="font-mono">{l.item_code}</span>
                            {l.hit && <> · <span className="num">{t('so.inStock', { n: fmtQty(stock ?? 0) })}</span></>}
                          </p>
                        )}
                      </div>
                      <label className="block text-xs font-medium text-muted">
                        <span>{t('erp.col.qty')}</span>
                        <input id={`line-${l.key}-qty`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.qty}
                          onChange={(e) => setL(l.key, { qty: e.target.value })} onKeyDown={enterAdds} />
                      </label>
                      <label className="block text-xs font-medium text-muted">
                        <span>{t('so.unitPrice')}</span>
                        <input id={`line-${l.key}-price`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.price}
                          placeholder={listPrice != null ? fmtMoney(listPrice) : ''} onChange={(e) => setL(l.key, { price: e.target.value })} onKeyDown={enterAdds} />
                      </label>
                      <label className="block text-xs font-medium text-muted">
                        <span>{t('so.disc')}</span>
                        <input id={`line-${l.key}-discount_pct`} inputMode="decimal" className={clsx('input num mt-1 text-end text-[15px] text-ink', lc.some((c) => c.rule_code === 'discount_pct') && 'border-warn-fg')}
                          value={l.discount_pct} onChange={(e) => setL(l.key, { discount_pct: e.target.value })} onKeyDown={enterAdds} />
                      </label>
                      <label className="block text-xs font-medium text-muted">
                        <span>{t('erp.col.taxCode')}</span>
                        <select id={`line-${l.key}-tax_code`} className="input mt-1 px-2 text-[15px] text-ink" value={l.tax_code} onChange={(e) => setL(l.key, { tax_code: e.target.value })}>
                          <option value="">—</option>
                          {S?.tax_codes.map((x) => <option key={x.code} value={x.code}>{x.code} · {fmtQty(x.rate)}%</option>)}
                        </select>
                      </label>
                      <div className="text-end text-xs font-medium text-muted">
                        <span>{t('erp.col.lineTotal')}</span>
                        <span className="num mt-1 flex min-h-[44px] items-center justify-end text-[15px] font-semibold text-ink" data-testid="so-line-total">{fmtMoney(calc[i].net)}</span>
                      </div>
                      <div className="flex min-h-[44px] items-center justify-end">
                        <button type="button" onClick={() => removeLine(l.key)} aria-label={t('so.removeLine', { n: i + 1 })} className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg">
                          <Trash2 className="h-4 w-4" aria-hidden />
                        </button>
                      </div>
                    </div>
                    {lc.map((c, k) => <CheckNote key={k} message={c.message} />)}
                    {lineProblems.map((p, k) => <p key={k} className="mt-1 flex items-start gap-1 text-[13px] text-crit-fg"><AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{p.message}</p>)}
                  </li>
                );
              })}
            </ul>
            <div className="flex flex-col gap-3 border-t border-line sm:flex-row sm:items-start sm:justify-between">
              <div className="flex flex-wrap items-center gap-2 p-4">
                <Button variant="secondary" onClick={() => addLine()} id="so-add-line"><Plus className="h-4 w-4" aria-hidden /> {t('so.addLine')}</Button>
                {removed && (
                  <span className="text-sm text-muted" role="status">{t('so.lineRemoved')} <button type="button" className="font-medium text-primary underline" onClick={undoRemove}>{t('so.undo')}</button></span>
                )}
                {fieldErr('lines') && <span className="text-sm text-crit-fg">{fieldErr('lines')}</span>}
              </div>
              <Totals {...totals} currency={currency} />
            </div>
          </SectionCard>
        </div>

        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('so.submitTitle')}>
            <div className="space-y-3 p-5">
              {!header.card_code || !filled.length ? (
                <p className="text-sm text-muted">{t('so.previewEmpty')}</p>
              ) : !preview ? (
                <p className="text-sm text-muted">{t('so.checking')}</p>
              ) : preview.errors.length ? (
                <p className="text-sm text-muted">{t('so.previewErrors', { count: preview.errors.length })}</p>
              ) : needsApproval ? (
                <div data-testid="so-preview" className="rounded-btn border border-warn-fg/30 bg-warn-bg p-3 text-sm text-warn-fg">
                  <p className="font-semibold">{t('so.needsApproval', { rules: rules.join(', ') })}</p>
                  <ul className="mt-1 list-disc space-y-0.5 ps-5">
                    {[...new Set(checks.map((c) => c.approver_name))].map((n) => <li key={n}>{t('so.approver', { name: n })}</li>)}
                  </ul>
                </div>
              ) : (
                <p data-testid="so-preview" className="flex items-center gap-2 rounded-btn bg-ok-bg p-3 text-sm font-medium text-ok-fg"><Check className="h-4 w-4" aria-hidden />{t('so.straightToOpen')}</p>
              )}
              {needsApproval && (
                <label className="block text-xs font-medium text-muted">{t('so.reason')} <span className="text-crit-fg">*</span>
                  <textarea id="so-reason" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={reason} placeholder={t('so.reasonPh')}
                    onChange={(e) => { setReason(e.target.value); setReasonErr(null); }} aria-invalid={Boolean(reasonErr)} aria-describedby={reasonErr ? 'so-reason-err' : undefined} />
                  {reasonErr && <span id="so-reason-err" className="mt-1 block text-crit-fg">{reasonErr}</span>}
                </label>
              )}
              <div className="flex flex-col gap-2">
                <Button variant="primary" id="so-submit" className="w-full" onClick={() => save(true)} disabled={Boolean(blocked) || busy !== null || !company} disabledReason={blocked}>
                  {busy === 'submit' ? t('so.submitting') : needsApproval ? t('so.submitForApproval') : t('so.submit')}
                </Button>
                <Button variant="secondary" id="so-save" className="w-full" onClick={() => save(false)} disabled={Boolean(blocked) || busy !== null || !company}>
                  {busy === 'save' ? t('so.saving') : t('so.saveDraft')}
                </Button>
                <Link to={entry ? `/docs/sales_order/${company}/${entry}` : '/docs/sales_order'} onClick={back} className="inline-flex min-h-[44px] items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
              </div>
            </div>
          </SectionCard>

          {customer && (
            <SectionCard title={t('so.creditTitle')}>
              <dl className="num grid grid-cols-2 gap-x-4 gap-y-1 p-5 text-sm">
                <dt className="text-muted">{t('erp.col.creditLimit')}</dt><dd className="text-end">{customer.credit_limit != null ? fmtMoney(customer.credit_limit, currency) : t('so.notSet')}</dd>
                <dt className="text-muted">{t('erp.col.balance')}</dt><dd className="text-end">{fmtMoney(customer.balance)}</dd>
                <dt className="text-muted">{t('so.openOrders')}</dt><dd className="text-end">{preview?.credit ? fmtMoney(preview.credit.open_orders) : '…'}</dd>
                <dt className="text-muted">{t('so.thisOrder')}</dt><dd className="text-end">{fmtMoney(totals.total)}</dd>
                <dt className="font-semibold">{t('so.creditLeft')}</dt>
                <dd className={clsx('text-end font-semibold', preview?.credit?.left != null && preview.credit.left - totals.total < 0 && 'text-crit-fg')}>
                  {preview?.credit?.left != null ? fmtMoney(preview.credit.left - totals.total) : '—'}
                </dd>
              </dl>
            </SectionCard>
          )}
          <AskAiCard />
        </aside>
      </div>
    </div>
  );
}

// ---------- Order page (SAP, sample and Super ERP orders) ----------
export function SalesOrderDetailPage() {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const loc = useLocation();
  const qc = useQueryClient();
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  const q = useQuery({
    queryKey: ['doc', 'sales_order', company, entry],
    queryFn: async () => {
      const { data, error } = await erp().from('document').select('*').match({ company_code: company, obj_type: 17, doc_entry: id }).maybeSingle();
      if (error) throw new ApiError(error);
      if (!data) return null;
      const { data: ls, error: le } = await erp().from('document_line').select('*').match({ company_code: company, obj_type: 17, doc_entry: id }).order('line_num');
      if (le) throw new ApiError(le);
      return { doc: data as R, lines: (ls ?? []) as R[] };
    },
  });
  const isErp = q.data?.doc.source === 'erp';
  const info = useSoInfo(company, id, Boolean(isErp));
  const setup = useSoSetup(q.data ? company : null);
  const I = info.data;
  const d = q.data?.doc;

  useEffect(() => { if (flash) { const h = setTimeout(() => setFlash(null), 6000); return () => clearTimeout(h); } }, [flash]);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['doc', 'sales_order', company, entry] });
    qc.invalidateQueries({ queryKey: ['so-info', company, id] });
    qc.invalidateQueries({ queryKey: ['approval-inbox'] });
    qc.invalidateQueries({ queryKey: ['erp-list'] });
  };

  let body: ReactNode = null;
  if (q.isLoading || (isErp && info.isLoading)) body = <PageLoading />;
  else if (q.error || info.error) body = <div className="card"><ErrorState error={q.error ?? info.error} onRetry={() => { q.refetch(); info.refetch(); }} /></div>;
  else if (!d) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  if (body) return <RequireModule module="sales"><DocHeader title={t('erp.doc.sales_order')} />{body}</RequireModule>;

  const S = setup.data;
  const lines = q.data!.lines;
  const docNo = I?.doc_no ?? String(d!.doc_num);
  const title = t('so.titleNo', { no: docNo });
  const pending = (I?.approvals ?? []).filter((a) => a.current);
  const flagged = new Map<number, SoCheck[]>();
  for (const a of pending) for (const c of a.detail?.checks ?? []) if (c.line) flagged.set(c.line, [...(flagged.get(c.line) ?? []), c]);
  const before = round2(lines.reduce((s, l) => s + Number(l.quantity ?? 0) * Number(l.price ?? 0), 0));
  const net = round2(lines.reduce((s, l) => s + Number(l.line_total ?? 0), 0));
  const slp = S?.salespersons.find((s) => s.code === d!.slp_code)?.name;
  const sub = [d!.card_name, slp, I?.created_at ? t('so.createdAt', { when: fmtWhen(I.created_at) }) : d!.created_on ? t('so.createdAt', { when: fmtDay(d!.created_on) }) : null].filter(Boolean).join(' · ');

  return (
    <RequireModule module="sales">
      <DocHeader title={title}
        pills={<>{I?.workflow && I.state ? <StatePill state={I.state} /> : <StatusTag value={d!.status} />}<SourcePill source={d!.source} /><LiveBadge live /></>}
        sub={sub}
        actions={<OrderActions company={company} id={id} info={I} docNo={docNo} onDone={refresh} />} />
      <FlowStrip />
      {flash && <p role="status" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{flash}</p>}

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              [t('erp.col.customer'), <Link className="text-primary hover:underline" to={`/bp/${company}/${encodeURIComponent(d!.card_code ?? '')}`}>{d!.card_code} · {d!.card_name}</Link>],
              [t('erp.col.postingDate'), fmtDay(d!.doc_date)],
              [t('so.deliveryDate'), fmtDay(d!.due_date)],
              [t('erp.col.priceList'), I?.price_list != null ? S?.price_lists.find((p) => p.code === I.price_list)?.name ?? I.price_list : null],
              [t('so.paymentTerms'), I?.payment_terms != null ? S?.payment_terms.find((p) => p.code === I.payment_terms)?.name ?? I.payment_terms : null],
              [t('erp.col.warehouse'), I?.whs_code ?? ([...new Set(lines.map((l) => l.whs_code).filter(Boolean))].join(', ') || null)],
              [t('erp.col.customerRef'), d!.customer_ref],
              [t('erp.col.remarks'), d!.comments],
              [t('erp.col.source'), sourceLabel(d!.source)],
            ]} />
          </SectionCard>

          <SectionCard title={t('erp.section.lines')}>
            {lines.length === 0 ? <EmptyState title={t('erp.list.empty')} /> : (
              <div className="overflow-x-auto">
                <table className="w-full text-[14px] sm:min-w-[560px]">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className="px-4 py-2.5 text-start">{t('so.item')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.qty')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('so.unitPrice')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('so.disc')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.lineTotal')}</th>
                  </tr></thead>
                  <tbody>
                    {lines.map((l) => {
                      const fc = flagged.get(l.line_num + 1) ?? [];
                      return (
                        <tr key={l.line_num} data-testid="so-line" className={clsx('border-t border-line align-top', fc.length > 0 && 'bg-warn-bg')}>
                          <td className="px-4 py-2.5">
                            <div dir="auto" className="font-semibold">{l.description ?? l.item_code}</div>
                            <div className="text-xs text-muted"><Link className="font-mono hover:underline" to={`/items/${company}/${encodeURIComponent(l.item_code ?? '')}`}>{l.item_code}</Link>{l.whs_code ? ` · ${l.whs_code}` : ''}{l.tax_code ? ` · ${l.tax_code}` : ''}</div>
                            {fc.map((c, k) => <CheckNote key={k} message={checkText(c, I)} />)}
                          </td>
                          <td className="num px-4 py-2.5 text-end">{fmtQty(l.quantity)} <span className="text-muted">{l.uom}</span></td>
                          <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(l.price)}</td>
                          <td className="px-4 py-2.5 text-end">{Number(l.discount_pct) ? <span className={clsx('pill num', fc.some((c) => c.rule_code === 'discount_pct') ? 'pill-warning' : 'pill-neutral')} data-testid="so-disc">{pct(l.discount_pct)}</span> : '—'}</td>
                          <td className="num px-4 py-2.5 text-end font-medium">{fmtMoney(l.line_total)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
            <div className="flex justify-end"><Totals before={before} discount={round2(before - net)} vat={Number(d!.vat_total ?? 0)} total={Number(d!.total ?? 0)} currency={d!.currency ?? ''} /></div>
          </SectionCard>
        </div>

        <aside className="min-w-0 space-y-5">
          {I?.workflow ? <ApprovalPanel company={company} id={id} info={I} docNo={docNo} onDone={(msg) => { setFlash(msg); refresh(); }} /> : (
            <SectionCard title={t('so.sourceTitle')}><p className="p-5 text-sm text-muted">{d!.source === 'sap' ? t('so.sapReadOnly') : t('so.sampleReadOnly')}</p></SectionCard>
          )}
          {I?.workflow && <ActivityCard info={I} />}
          <AskAiCard />
        </aside>
      </div>
    </RequireModule>
  );
}

function OrderActions({ company, id, info, docNo, onDone }: { company: string; id: number; info: SoInfo | undefined | null; docNo: string; onDone: () => void }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const approved = info?.state === 'approved';
  async function cancel() {
    setErr(null);
    if (!note.trim()) { setErr(t('so.cancelNoteNeeded')); return; }
    setBusy(true);
    try { await soCancel(company, id, note.trim()); setOpen(false); onDone(); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <>
      {info?.can_edit && (
        <Link to={`/docs/sales_order/${company}/${id}/edit`} id="so-edit" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover">
          <Pencil className="h-4 w-4" aria-hidden />{info.state === 'rejected' ? t('so.editResubmit') : t('so.editDraft')}
        </Link>
      )}
      <Button variant="secondary" onClick={() => window.print()} icon={<Printer className="h-4 w-4" aria-hidden />}>{t('so.print')}</Button>
      <Button variant="secondary" id="so-copy" disabled disabledReason={approved || !info?.workflow ? t('so.copyLater') : t('so.copyAfterApproval')}>{t('so.copyToDelivery')}</Button>
      {info?.can_cancel && <Button variant="danger" id="so-cancel" onClick={() => { setOpen(true); setErr(null); }}>{t('so.cancelOrder')}</Button>}
      <Dialog open={open} title={t('so.cancelTitle', { no: docNo })} onClose={() => setOpen(false)}
        footer={<>
          <Button variant="secondary" onClick={() => setOpen(false)}>{t('so.keep')}</Button>
          <Button variant="danger" id="so-cancel-confirm" onClick={cancel} disabled={busy}>{t('so.cancelOrder')}</Button>
        </>}>
        <p className="text-sm text-ink-2">{t('so.cancelBody')}</p>
        <label className="block text-xs font-medium text-muted">{t('so.note')} <span className="text-crit-fg">*</span>
          <textarea id="so-cancel-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        {err && <p role="alert" className="text-sm text-crit-fg">{err}</p>}
      </Dialog>
    </>
  );
}

function ApprovalPanel({ company, id, info, docNo, onDone }: { company: string; id: number; info: SoInfo; docNo: string; onDone: (msg: string) => void }) {
  const { t } = useTranslation();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejOpen, setRejOpen] = useState(false);
  const [note, setNote] = useState('');
  const [noteErr, setNoteErr] = useState<string | null>(null);
  const approvals = info.approvals ?? [];
  const current = approvals.filter((a) => a.current);
  const mine = current.filter((a) => a.mine);
  const disc = mine.find((a) => a.rule_code === 'discount_pct');
  const reqLimit = info.requester_discount_limit;
  const myLimit = info.my_discount_limit;
  const approveAt = disc && reqLimit != null && myLimit != null && reqLimit <= myLimit && reqLimit < Number(disc.detail?.max_value ?? 0) ? Number(reqLimit) : null;
  const myLast = [...approvals].reverse().find((a) => a.decided_by_me && a.decision);

  async function decide(decision: 'approved' | 'rejected', n: number | null = null) {
    setErr(null);
    if (decision === 'rejected' && !note.trim()) { setNoteErr(t('so.rejectNoteNeeded')); return; }
    setBusy(true);
    try {
      const r = await soDecide(company, id, decision, decision === 'rejected' ? note.trim() : null, n);
      setRejOpen(false);
      onDone(decision === 'rejected' ? t('so.flash.rejected') : r.state === 'approved' ? t('so.flash.approved') : t('so.flash.stepApproved'));
    } catch (e) {
      const m = errorMessage(e);
      if (decision === 'rejected') setNoteErr(m); else setErr(m);
    } finally {
      setBusy(false);
    }
  }

  if (info.can_decide) {
    return (
      <section className="card overflow-hidden border-warn-fg/40" data-testid="so-approval-card">
        <div className="border-b border-line bg-warn-bg px-5 py-3">
          <h2 className="text-[15px] font-semibold text-warn-fg">{t('so.approval.needed')}</h2>
        </div>
        <div className="space-y-3 p-5">
          {err && <p role="alert" className="flex items-start gap-2 text-sm text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />{err}</p>}
          {mine.map((a) => (
            <div key={a.approval_id}>
              <p className="text-sm font-semibold">{a.rule_code === 'discount_pct' && reqLimit != null ? t('so.rule.discountReq', { n: fmtQty(reqLimit) }) : t(`so.rule.${a.rule_code}`)}</p>
              <ul className="mt-1 space-y-0.5 text-[13px] text-ink-2">{(a.detail?.checks ?? []).map((c, k) => <li key={k} dir="auto">{checkText(c, info)}</li>)}</ul>
            </div>
          ))}
          <p className="text-sm text-muted">{t('so.approval.requested', { name: info.submitted_by_name ?? '—', when: fmtWhen(info.submitted_at) })}</p>
          {info.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 text-[15px] italic text-ink-2">“{info.reason}”</blockquote>}
          <div className="flex flex-col gap-2 pt-1">
            <Button variant="success" id="so-approve" className="w-full" disabled={busy} onClick={() => decide('approved')} icon={<Check className="h-4 w-4" aria-hidden />}>{t('so.approval.approve')}</Button>
            {approveAt != null && (
              <Button variant="secondary" id="so-approve-at" className="w-full" disabled={busy} onClick={() => decide('approved', approveAt)}>{t('so.approval.approveAt', { n: fmtQty(approveAt) })}</Button>
            )}
            <Button variant="danger" id="so-reject" className="w-full" disabled={busy} onClick={() => { setRejOpen(true); setNoteErr(null); }} icon={<X className="h-4 w-4" aria-hidden />}>{t('so.approval.reject')}</Button>
          </div>
        </div>
        <Dialog open={rejOpen} title={t('so.approval.rejectTitle', { no: docNo })} onClose={() => setRejOpen(false)}
          footer={<>
            <Button variant="secondary" onClick={() => setRejOpen(false)}>{t('so.keep')}</Button>
            <Button variant="danger" id="so-reject-confirm" disabled={busy} onClick={() => decide('rejected')}>{t('so.approval.reject')}</Button>
          </>}>
          <label className="block text-xs font-medium text-muted">{t('so.approval.rejectNote')} <span className="text-crit-fg">*</span>
            <textarea id="so-reject-note" rows={3} dir="auto" className="input mt-1 py-2 text-[15px] text-ink" value={note}
              onChange={(e) => { setNote(e.target.value); setNoteErr(null); }} aria-invalid={Boolean(noteErr)} aria-describedby={noteErr ? 'so-reject-err' : undefined} />
          </label>
          {noteErr && <p id="so-reject-err" role="alert" className="text-sm text-crit-fg">{noteErr}</p>}
        </Dialog>
      </section>
    );
  }

  // Decided by me: green or red card.
  if (myLast && info.state !== 'pending_approval') {
    const ok = myLast.decision === 'approved';
    return (
      <section data-testid="so-decided-card" className={clsx('card p-5', ok ? 'border-ok-fg/40 bg-ok-bg text-ok-fg' : 'border-crit-fg/40 bg-crit-bg text-crit-fg')}>
        <p className="flex items-center gap-2 font-semibold">{ok ? <CircleCheck className="h-5 w-5" aria-hidden /> : <CircleX className="h-5 w-5" aria-hidden />}
          {t(ok ? 'so.approval.approvedByYou' : 'so.approval.rejectedByYou', { when: fmtWhen(myLast.decided_at) })}</p>
        {myLast.note && <p dir="auto" className="mt-2 text-sm">“{myLast.note}”</p>}
        <p className="mt-2 text-sm">{t('so.approval.requesterSees', { name: info.submitted_by_name ?? info.created_by_name ?? '—' })}</p>
      </section>
    );
  }

  // Everyone else: where the order stands.
  const lastRej = [...approvals].reverse().find((a) => a.decision === 'rejected');
  const lastOk = [...approvals].reverse().find((a) => a.decision === 'approved');
  return (
    <SectionCard title={t('so.approval.status')}>
      <div className="space-y-2 p-5 text-sm" data-testid="so-status-card">
        {info.state === 'draft' && <p className="text-muted">{t('so.approval.draft')}</p>}
        {info.state === 'pending_approval' && (
          <>
            <p className="font-semibold text-warn-fg">{t('so.approval.waitingFor', { names: [...new Set(current.map((a) => a.approver_position_name))].join(', ') })}</p>
            {current.map((a) => (a.detail?.checks ?? []).map((c, k) => <p key={`${a.approval_id}-${k}`} dir="auto" className="text-ink-2">{checkText(c, info)}</p>))}
            {info.reason && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{info.reason}”</blockquote>}
            {info.is_submitter && <p className="text-muted">{t('so.approval.youCantApprove')}</p>}
          </>
        )}
        {info.state === 'approved' && (
          <p className="flex items-center gap-2 font-semibold text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />
            {lastOk ? t('so.approval.approvedBy', { name: lastOk.decided_by_name ?? '—', when: fmtWhen(lastOk.decided_at) }) : t('so.approval.approvedNoRule')}</p>
        )}
        {lastOk?.detail?.approved_at != null && info.state === 'approved' && <p className="text-ink-2">{t('so.approval.approvedAtNote', { n: fmtQty(lastOk.detail.approved_at) })}</p>}
        {info.state === 'rejected' && lastRej && (
          <>
            <p className="flex items-center gap-2 font-semibold text-crit-fg"><CircleX className="h-4 w-4" aria-hidden />{t('so.approval.rejectedBy', { name: lastRej.decided_by_name ?? '—', when: fmtWhen(lastRej.decided_at) })}</p>
            {lastRej.note && <blockquote dir="auto" className="border-s-4 border-line-strong ps-3 italic text-ink-2">“{lastRej.note}”</blockquote>}
            {info.can_edit && <p className="text-muted">{t('so.approval.fixAndResubmit')}</p>}
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

function ActivityCard({ info }: { info: SoInfo }) {
  const { t } = useTranslation();
  const items = info.activity ?? [];
  return (
    <SectionCard title={t('so.activity.title')}>
      {items.length === 0 ? <p className="p-5 text-sm text-muted">{t('so.activity.empty')}</p> : (
        <ol className="space-y-4 p-5" data-testid="so-activity">
          {items.map((a, i) => {
            const det = (a.detail ?? {}) as R;
            const result = a.action === 'sales_order_submit' ? (det.result === 'approved' ? 'submitOpen' : 'submitPending') : a.action.replace('sales_order_', '');
            return (
              <li key={i} className="relative flex gap-3">
                <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', a.action.endsWith('approve') ? 'bg-ok-fg' : a.action.endsWith('reject') || a.action.endsWith('cancel') ? 'bg-crit-fg' : 'bg-primary')} aria-hidden />
                <div className="min-w-0 text-sm">
                  <p><span className="font-medium">{a.actor_name}</span> {t(`so.activity.${result}`, { defaultValue: a.action })}</p>
                  {det.approved_at != null && <p className="text-ink-2">{t('so.approval.approvedAtNote', { n: fmtQty(det.approved_at) })}</p>}
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

/** "+ New sales order" for the Sales Orders list: a link for full Sales access, disabled with the reason otherwise. */
export function NewSalesOrderAction() {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  if (!canWrite) {
    return <Button variant="primary" disabled id="new-sales" disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {t('erp.new.salesOrder')}</Button>;
  }
  return (
    <Link to="/docs/sales_order/new" id="new-sales" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover">
      <Plus className="h-4 w-4" aria-hidden /> {t('erp.new.salesOrder')}
    </Link>
  );
}

