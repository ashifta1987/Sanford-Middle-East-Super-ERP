import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, ArrowLeft, CircleCheck, Plus, Printer, Trash2 } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { erp } from '@/lib/supabase';
import { ApiError, errorMessage } from '@/lib/format';
import i18n from '@/lib/i18n';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Fields, LiveBadge, PageTitle, SectionCard, StatusTag, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Combobox, type ComboOption } from '../components/Combobox';
import { DocFlow } from '../components/DocFlow';
import { SeriesPicker } from '../components/SeriesPicker';
import { AskAiDocCard } from '../components/AskAi';
import { DOC_KINDS, moduleByKey, type DocKind } from '../modules';
import { searchCustomers, useSoSetup, type CustomerHit } from '../salesOrder';
import {
  atpCheck, atpRuleSave, copySource, creditMemoCreate, deliveryCreate, invoiceCreate, printData, searchServiceItems, searchStockItems,
  useAtpRules, useDocView, type AtpCheck, type AtpRule, type CopyLine,
} from '../salesCycle';
import { DocHeader, SourcePill, Totals, fmtWhen, sourceLabel, today } from './SalesOrderPages';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type CycleKind = 'delivery' | 'ar_invoice' | 'ar_credit_note';
const r2 = (n: number) => Math.round(n * 100) / 100;

function useDefaultCompany() {
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const companies = profile?.companies ?? [];
  return top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? '';
}

/** Top-of-form error: the server's message as written (spec §8). */
function FormError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div role="alert" className="mb-5 rounded-card border border-crit-fg/30 bg-crit-bg p-4 text-crit-fg">
      <p className="flex items-start gap-2 font-semibold"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="sc-error">{message}</span></p>
    </div>
  );
}

function Flash({ text }: { text: string | null }) {
  if (!text) return null;
  return <p role="status" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden />{text}</p>;
}

// ---------- Copy-to lines (order → delivery, delivery → invoice, invoice → credit memo) ----------
interface PickRow { key: string; line: CopyLine; sel: boolean; qty: string; whs: string }
const pickRows = (lines: CopyLine[], selected: (l: CopyLine) => boolean): PickRow[] =>
  lines.map((l) => ({ key: `${l.base_doc_entry}-${l.base_line}`, line: l, sel: selected(l), qty: String(Number(l.open_qty)), whs: l.whs_code ?? '' }));

function PickTable({ rows, setRows, warehouses, showStock, showBase }: {
  rows: PickRow[]; setRows: (f: (rs: PickRow[]) => PickRow[]) => void; warehouses?: Array<{ code: string; name: string }>; showStock?: boolean; showBase?: boolean;
}) {
  const { t } = useTranslation();
  const set = (key: string, patch: Partial<PickRow>) => setRows((rs) => rs.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  if (!rows.length) return <EmptyState title={t('sc.nothingToCopy')} body={t('sc.nothingToCopyBody')} />;
  return (
    <ul className="divide-y divide-line">
      {rows.map((r, i) => {
        const l = r.line;
        const qty = Number(r.qty);
        const over = r.sel && (Number.isNaN(qty) || qty > Number(l.open_qty));
        const short = r.sel && showStock && l.is_stock && r.whs === l.whs_code && l.on_hand != null && qty > Number(l.on_hand);
        const net = r2(qty * Number(l.price) * (1 - Number(l.discount_pct ?? 0) / 100)) || 0;
        return (
          <li key={r.key} data-testid="pick-line" className={clsx('px-4 py-3', !r.sel && 'opacity-60', (over || short) && 'bg-warn-bg')}>
            <div className="grid grid-cols-2 items-end gap-3 md:grid-cols-[44px_minmax(0,1fr)_120px_140px_128px]">
              <label className="col-span-2 flex min-h-[44px] items-center gap-3 md:col-span-1">
                <input type="checkbox" className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked={r.sel} onChange={(e) => set(r.key, { sel: e.target.checked })}
                  aria-label={t('sc.includeLine', { n: i + 1 })} id={`pick-${i}-sel`} />
                <span className="md:hidden text-sm font-semibold" dir="auto">{l.description ?? l.item_code}</span>
              </label>
              <div className="col-span-2 min-w-0 max-md:hidden md:col-span-1">
                <div dir="auto" className="font-semibold">{l.description ?? l.item_code}</div>
                <div className="text-xs text-muted">
                  <span className="font-mono">{l.item_code}</span>
                  {showBase && <> · <span className="font-mono">{l.base_doc_no}</span> {t('sc.lineN', { n: l.base_line + 1 })}</>}
                  {' · '}{t('sc.openN', { n: fmtQty(l.open_qty) })}
                  {showStock && l.is_stock && <> · <span className="num">{t('sc.inStockAt', { n: fmtQty(l.on_hand ?? 0), whs: l.whs_code })}</span></>}
                </div>
              </div>
              <div className="col-span-2 text-xs text-muted md:hidden">
                <span className="font-mono">{l.item_code}</span>{showBase && <> · {l.base_doc_no}</>} · {t('sc.openN', { n: fmtQty(l.open_qty) })}
                {showStock && l.is_stock && <> · {t('sc.inStockAt', { n: fmtQty(l.on_hand ?? 0), whs: l.whs_code })}</>}
              </div>
              <label className="block text-xs font-medium text-muted">{t('erp.col.qty')}
                <input id={`pick-${i}-qty`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={r.qty} disabled={!r.sel}
                  onChange={(e) => set(r.key, { qty: e.target.value })} aria-invalid={over} />
              </label>
              {warehouses ? (
                <label className="block text-xs font-medium text-muted">{t('erp.col.warehouse')}
                  <select id={`pick-${i}-whs`} className="input mt-1 px-2 text-[15px] text-ink" value={r.whs} disabled={!r.sel || !l.is_stock} onChange={(e) => set(r.key, { whs: e.target.value })}>
                    {warehouses.map((w) => <option key={w.code} value={w.code}>{w.code}</option>)}
                  </select>
                </label>
              ) : <div className="max-md:hidden" />}
              <div className="text-end text-xs font-medium text-muted">
                <span>{t('erp.col.lineTotal')}</span>
                <span className="num mt-1 flex min-h-[44px] items-center justify-end text-[15px] font-semibold text-ink">{r.sel ? fmtMoney(net) : '—'}</span>
              </div>
            </div>
            {over && <p className="mt-1 flex items-start gap-1 text-[13px] text-warn-fg"><AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{t('sc.moreThanOpen', { n: fmtQty(l.open_qty) })}</p>}
            {short && <p className="mt-1 flex items-start gap-1 text-[13px] text-warn-fg"><AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{t('sc.moreThanStock', { n: fmtQty(l.on_hand ?? 0), whs: l.whs_code })}</p>}
          </li>
        );
      })}
    </ul>
  );
}

function pickTotals(rows: PickRow[]) {
  let before = 0; let net = 0; let vat = 0;
  for (const r of rows) {
    if (!r.sel) continue;
    const q = Number(r.qty) || 0;
    const b = r2(q * Number(r.line.price));
    const n = r2(q * Number(r.line.price) * (1 - Number(r.line.discount_pct ?? 0) / 100));
    before += b; net += n; vat += r2((n * Number(r.line.tax_rate ?? 0)) / 100);
  }
  return { before: r2(before), discount: r2(before - net), vat: r2(vat), total: r2(net + vat) };
}

function CreateShell({ kind, title, sub, flow, error, children, aside }: {
  kind: CycleKind; title: string; sub?: ReactNode; flow?: ReactNode; error: string | null; children: ReactNode; aside: ReactNode;
}) {
  return (
    <RequireModule module="sales">
      <DocHeader kind={kind} title={title} pills={<SourcePill source="erp" />} sub={sub} />
      {flow}
      <FormError message={error} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">{children}</div>
        <aside className="min-w-0 space-y-5">{aside}</aside>
      </div>
    </RequireModule>
  );
}

// ---------- New delivery (Copy to delivery from an approved order) ----------
export function DeliveryNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const company = params.get('company') ?? '';
  const order = Number(params.get('order')) || null;
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  const setup = useSoSetup(company || null, 17);
  const q = useQuery({ queryKey: ['copy', company, 17, order], enabled: Boolean(company && order), queryFn: () => copySource(company, 17, order) });
  const [rows, setRows] = useState<PickRow[]>([]);
  const [date, setDate] = useState(today());
  const [comments, setComments] = useState('');
  const [series, setSeries] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (q.data) setRows(pickRows(q.data.lines, () => true)); }, [q.data]);

  if (!company || !order) return <RequireModule module="sales"><PageTitle title={t('sc.newDelivery')} /><div className="card"><EmptyState title={t('sc.pickOrder')} body={t('sc.pickOrderBody')} /></div></RequireModule>;
  if (q.isLoading) return <RequireModule module="sales"><PageLoading /></RequireModule>;
  if (q.error) return <RequireModule module="sales"><DocHeader kind="delivery" title={t('sc.newDelivery')} /><div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div></RequireModule>;
  const h = q.data!.header!;
  const tot = pickTotals(rows);
  const sel = rows.filter((r) => r.sel);

  async function submit() {
    setErr(null);
    if (!sel.length) { setErr(t('sc.chooseLines')); return; }
    setBusy(true);
    try {
      const res = await deliveryCreate(company, { doc_date: date, comments },
        sel.map((r) => ({ base_doc_entry: r.line.base_doc_entry, base_line: r.line.base_line, qty: r.qty, whs_code: r.whs || null })), series);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      qc.invalidateQueries({ queryKey: ['sales-flow'] });
      qc.removeQueries({ queryKey: ['doc', 'sales_order', company, String(order)] });
      nav(`/docs/delivery/${company}/${res.doc_entry}`, { state: { flash: t('sc.flash.delivery', { no: res.doc_no }) } });
    } catch (e) {
      setErr(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally { setBusy(false); }
  }

  return (
    <CreateShell kind="delivery" title={t('sc.newDelivery')} error={err}
      sub={[h.card_code, h.card_name, t('sc.fromOrder', { no: h.doc_no })].filter(Boolean).join(' · ')}
      flow={<DocFlow company={company} obj={17} entry={order} current="delivery" />}
      aside={
        <SectionCard title={t('sc.addTitle')}>
          <div className="space-y-3 p-5">
            <p className="text-sm text-muted">{t('sc.deliveryWhat')}</p>
            <Button variant="primary" id="sc-submit" className="w-full" onClick={submit} disabled={busy || !canWrite || !sel.length} disabledReason={!canWrite ? readOnlyReason : undefined}>
              {busy ? t('so.saving') : t('sc.addDelivery')}
            </Button>
            <Link to={`/docs/sales_order/${company}/${order}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
          </div>
        </SectionCard>
      }>
      <SectionCard title={t('erp.section.header')}>
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
            <input id="sc-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.remarks')}
            <input id="sc-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={comments} onChange={(e) => setComments(e.target.value)} />
          </label>
          <SeriesPicker company={company} obj={15} value={series} onChange={setSeries} date={date} />
        </div>
      </SectionCard>
      <SectionCard title={t('sc.linesToDeliver')}>
        <PickTable rows={rows} setRows={setRows} warehouses={setup.data?.warehouses} showStock />
        <div className="flex justify-end border-t border-line"><Totals {...tot} currency={h.currency} /></div>
      </SectionCard>
    </CreateShell>
  );
}

// ---------- New A/R invoice (from deliveries, or service lines) ----------
interface SvcLine { key: string; item_code: string; text: string; qty: string; price: string; disc: string; tax_code: string; listPrice: number | null }
let svcSeq = 0;

export function InvoiceNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const fallback = useDefaultCompany();
  const company = params.get('company') ?? fallback;
  const delivery = Number(params.get('delivery')) || null;
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  const setup = useSoSetup(company || null, 17);
  const first = useQuery({ queryKey: ['copy', company, 15, delivery], enabled: Boolean(company && delivery), queryFn: () => copySource(company, 15, delivery) });
  const [customer, setCustomer] = useState<CustomerHit | null>(null);
  const [custText, setCustText] = useState('');
  const card = delivery ? first.data?.header?.card_code ?? null : customer?.card_code ?? null;
  const open = useQuery({ queryKey: ['copy-card', company, 15, card], enabled: Boolean(company && card), queryFn: () => copySource(company, 15, null, card) });
  const [rows, setRows] = useState<PickRow[]>([]);
  const [svc, setSvc] = useState<SvcLine[]>([]);
  const [date, setDate] = useState(today());
  const [due, setDue] = useState('');
  const [ref, setRef] = useState('');
  const [comments, setComments] = useState('');
  const [why, setWhy] = useState('');
  const [series, setSeries] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (open.data) setRows(pickRows(open.data.lines, (l) => (delivery ? l.base_doc_entry === delivery : false))); }, [open.data, delivery]);
  const S = setup.data;
  const currency = S?.currency ?? '';
  const defTax = S?.default_tax_code ?? '';
  const rate = (code: string) => Number(S?.tax_codes.find((x) => x.code === code)?.rate ?? 0);
  const priceList = customer?.price_list ?? null;

  const svcTot = svc.reduce((acc, l) => {
    if (!l.item_code) return acc;
    const p = l.price !== '' ? Number(l.price) : Number(l.listPrice ?? 0);
    const b = r2((Number(l.qty) || 0) * p);
    const n = r2(b * (1 - (Number(l.disc) || 0) / 100));
    return { before: acc.before + b, net: acc.net + n, vat: acc.vat + r2((n * rate(l.tax_code)) / 100) };
  }, { before: 0, net: 0, vat: 0 });
  const pt = pickTotals(rows);
  const tot = { before: r2(pt.before + svcTot.before), discount: r2(pt.discount + svcTot.before - svcTot.net), vat: r2(pt.vat + svcTot.vat), total: r2(pt.total + svcTot.net + svcTot.vat) };
  const sel = rows.filter((r) => r.sel);
  const svcFilled = svc.filter((l) => l.item_code);

  const custOpts = async (s: string): Promise<Array<ComboOption<CustomerHit>>> => (await searchCustomers(company, s)).map((c) => ({
    value: c.card_code, label: `${c.card_code} · ${c.name}`, data: c, meta: `${t('so.balance')} ${fmtMoney(c.balance)}`,
  }));
  const svcOpts = async (s: string) => (await searchServiceItems(company, s)).map((it) => ({
    value: it.item_code, label: `${it.item_code} · ${it.name}`, data: it, meta: fmtMoney(it.item_price.find((p) => p.list_num === (priceList ?? 1))?.price ?? null, currency),
  }));

  async function submit() {
    setErr(null);
    if (!sel.length && !svcFilled.length) { setErr(t('sc.chooseLines')); return; }
    setBusy(true);
    try {
      const res = await invoiceCreate(company, { card_code: card, doc_date: date, due_date: due || null, customer_ref: ref, comments, approval_reason: why || null }, [
        ...sel.map((r) => ({ base_doc_entry: r.line.base_doc_entry, base_line: r.line.base_line, qty: r.qty })),
        ...svcFilled.map((l) => ({ item_code: l.item_code, qty: l.qty, price: l.price === '' ? null : l.price, discount_pct: l.disc === '' ? null : l.disc, tax_code: l.tax_code || null })),
      ], series);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      qc.invalidateQueries({ queryKey: ['sales-flow'] });
      if (res.state === 'pending_approval') nav(`/sales/requests/${company}/${res.request_id}`, { state: { flash: t('sreq.flash.sent', { no: res.doc_no }) } });
      else nav(`/docs/ar_invoice/${company}/${res.doc_entry}`, { state: { flash: t('sc.flash.invoice', { no: res.doc_no }) } });
    } catch (e) {
      setErr(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally { setBusy(false); }
  }

  if (delivery && first.isLoading) return <RequireModule module="sales"><PageLoading /></RequireModule>;
  if (delivery && first.error) return <RequireModule module="sales"><DocHeader kind="ar_invoice" title={t('sc.newInvoice')} /><div className="card"><ErrorState error={first.error} onRetry={() => first.refetch()} /></div></RequireModule>;
  const h = first.data?.header;

  return (
    <CreateShell kind="ar_invoice" title={t('sc.newInvoice')} error={err}
      sub={h ? [h.card_code, h.card_name, t('sc.fromDelivery', { no: h.doc_no })].filter(Boolean).join(' · ') : t('sc.invoiceSub')}
      flow={delivery ? <DocFlow company={company} obj={15} entry={delivery} current="invoice" /> : <DocFlow obj={13} current="invoice" />}
      aside={
        <SectionCard title={t('sc.addTitle')}>
          <div className="space-y-3 p-5">
            <p className="text-sm text-muted">{t('sc.invoiceWhat')}</p>
            <Button variant="primary" id="sc-submit" className="w-full" onClick={submit} disabled={busy || !canWrite || !card || (!sel.length && !svcFilled.length)}
              disabledReason={!canWrite ? readOnlyReason : !card ? t('sc.chooseCustomerFirst') : undefined}>
              {busy ? t('so.saving') : t('sc.addInvoice')}
            </Button>
            <Link to={delivery ? `/docs/delivery/${company}/${delivery}` : '/docs/ar_invoice'} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
          </div>
        </SectionCard>
      }>
      <SectionCard title={t('erp.section.header')}>
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-3">
          {delivery ? (
            <div className="text-xs font-medium text-muted">{t('erp.col.customer')}<p className="mt-1 flex min-h-[44px] items-center text-[15px] text-ink">{h?.card_code} · {h?.card_name}</p></div>
          ) : (
            <Combobox<CustomerHit> id="sc-card_code" label={t('erp.col.customer')} required text={custText}
              onText={(s) => { setCustText(s); if (customer) { setCustomer(null); setRows([]); } }}
              search={custOpts} placeholder={t('so.customerPh')} noMatch={t('so.combo.noCustomer')}
              onSelect={(o) => { setCustomer(o.data); setCustText(o.label); }} />
          )}
          <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
            <input id="sc-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.dueDate')}
            <input id="sc-due_date" type="date" className="input num mt-1 text-[15px] text-ink" value={due} onChange={(e) => setDue(e.target.value)} />
            <span className="mt-1 block">{t('sc.dueFromTerms')}</span>
          </label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.customerRef')}
            <input id="sc-ref" className="input mt-1 text-[15px] text-ink" dir="auto" value={ref} onChange={(e) => setRef(e.target.value)} />
          </label>
          <label className="block text-xs font-medium text-muted sm:col-span-2">{t('erp.col.remarks')}
            <input id="sc-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={comments} onChange={(e) => setComments(e.target.value)} />
          </label>
          <SeriesPicker company={company} obj={13} value={series} onChange={setSeries} date={date} />
          <label className="block text-xs font-medium text-muted sm:col-span-2 xl:col-span-3">{t('sreq.reasonField')}
            <input id="sc-approval-reason" className="input mt-1 text-[15px] text-ink" dir="auto" value={why} onChange={(e) => setWhy(e.target.value)} placeholder={t('sreq.reasonPhInvoice')} />
          </label>
        </div>
      </SectionCard>
      <SectionCard title={t('sc.deliveredLines')} right={<span className="text-sm text-muted">{t('sc.openDeliveries')}</span>}>
        {!card ? <p className="p-5 text-sm text-muted">{t('sc.chooseCustomerFirst')}</p> : open.isLoading ? <PageLoading /> : (
          <PickTable rows={rows} setRows={setRows} showBase />
        )}
      </SectionCard>
      <SectionCard title={t('sc.serviceLines')} right={<span className="text-sm text-muted">{t('sc.serviceHint')}</span>}>
        <ul className="divide-y divide-line">
          {svc.map((l, i) => (
            <li key={l.key} className="px-4 py-3" data-testid="svc-line">
              <div className="grid grid-cols-2 items-end gap-3 md:grid-cols-[minmax(0,1fr)_88px_120px_88px_120px_44px]">
                <div className="col-span-2 min-w-0 md:col-span-1">
                  <Combobox id={`svc-${l.key}-item`} label={t('so.itemN', { n: i + 1 })} text={l.text}
                    onText={(s) => setSvc((ls) => ls.map((x) => (x.key === l.key ? { ...x, text: s, item_code: '' } : x)))}
                    search={svcOpts} placeholder={t('so.itemPh')} noMatch={t('sc.noService')}
                    onSelect={(o) => setSvc((ls) => ls.map((x) => (x.key === l.key ? { ...x, item_code: o.value, text: o.label, listPrice: o.data.item_price.find((p) => p.list_num === (priceList ?? 1))?.price ?? null } : x)))} />
                </div>
                <label className="block text-xs font-medium text-muted">{t('erp.col.qty')}
                  <input id={`svc-${l.key}-qty`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.qty}
                    onChange={(e) => setSvc((ls) => ls.map((x) => (x.key === l.key ? { ...x, qty: e.target.value } : x)))} />
                </label>
                <label className="block text-xs font-medium text-muted">{t('so.unitPrice')}
                  <input id={`svc-${l.key}-price`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.price}
                    placeholder={l.listPrice != null ? fmtMoney(l.listPrice) : ''} onChange={(e) => setSvc((ls) => ls.map((x) => (x.key === l.key ? { ...x, price: e.target.value } : x)))} />
                </label>
                <label className="block text-xs font-medium text-muted">{t('so.disc')}
                  <input id={`svc-${l.key}-disc`} inputMode="decimal" className="input num mt-1 text-end text-[15px] text-ink" value={l.disc} placeholder="0"
                    onChange={(e) => setSvc((ls) => ls.map((x) => (x.key === l.key ? { ...x, disc: e.target.value } : x)))} />
                </label>
                <label className="block text-xs font-medium text-muted">{t('erp.col.taxCode')}
                  <select className="input mt-1 px-2 text-[15px] text-ink" value={l.tax_code} onChange={(e) => setSvc((ls) => ls.map((x) => (x.key === l.key ? { ...x, tax_code: e.target.value } : x)))}>
                    {S?.tax_codes.map((x) => <option key={x.code} value={x.code}>{x.code} · {fmtQty(x.rate)}%</option>)}
                  </select>
                </label>
                <div className="flex min-h-[44px] items-center justify-end">
                  <button type="button" onClick={() => setSvc((ls) => ls.filter((x) => x.key !== l.key))} aria-label={t('so.removeLine', { n: i + 1 })}
                    className="grid h-10 w-10 place-items-center rounded-btn text-muted hover:bg-crit-bg hover:text-crit-fg"><Trash2 className="h-4 w-4" aria-hidden /></button>
                </div>
              </div>
            </li>
          ))}
        </ul>
        <div className="flex flex-col gap-3 border-t border-line sm:flex-row sm:items-start sm:justify-between">
          <div className="p-4">
            <Button variant="secondary" id="svc-add" onClick={() => setSvc((ls) => [...ls, { key: `s${++svcSeq}`, item_code: '', text: '', qty: '1', price: '', disc: '', tax_code: defTax, listPrice: null }])}>
              <Plus className="h-4 w-4" aria-hidden /> {t('sc.addService')}
            </Button>
          </div>
          <Totals {...tot} currency={currency} />
        </div>
      </SectionCard>
    </CreateShell>
  );
}

// ---------- New A/R credit memo (Copy to credit memo from an invoice) ----------
export function CreditMemoNewPage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [params] = useSearchParams();
  const company = params.get('company') ?? '';
  const invoice = Number(params.get('invoice')) || null;
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  const setup = useSoSetup(company || null, 17);
  const q = useQuery({ queryKey: ['copy', company, 13, invoice], enabled: Boolean(company && invoice), queryFn: () => copySource(company, 13, invoice) });
  const [rows, setRows] = useState<PickRow[]>([]);
  const [date, setDate] = useState(today());
  const [ret, setRet] = useState(true);
  const [whs, setWhs] = useState('');
  const [comments, setComments] = useState('');
  const [why, setWhy] = useState('');
  const [series, setSeries] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (q.data) { setRows(pickRows(q.data.lines, () => true)); setWhs(q.data.lines.find((l) => l.whs_code)?.whs_code ?? ''); } }, [q.data]);

  if (!company || !invoice) return <RequireModule module="sales"><PageTitle title={t('sc.newCreditMemo')} /><div className="card"><EmptyState title={t('sc.pickInvoice')} body={t('sc.pickInvoiceBody')} /></div></RequireModule>;
  if (q.isLoading) return <RequireModule module="sales"><PageLoading /></RequireModule>;
  if (q.error) return <RequireModule module="sales"><DocHeader kind="ar_credit_note" title={t('sc.newCreditMemo')} /><div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div></RequireModule>;
  const h = q.data!.header!;
  const tot = pickTotals(rows);
  const sel = rows.filter((r) => r.sel);
  const anyStock = sel.some((r) => r.line.is_stock);

  async function submit() {
    setErr(null);
    if (!sel.length) { setErr(t('sc.chooseLines')); return; }
    setBusy(true);
    try {
      const res = await creditMemoCreate(company, { doc_date: date, return_stock: ret && anyStock, whs_code: ret ? whs || null : null, comments, approval_reason: why || null },
        sel.map((r) => ({ base_doc_entry: r.line.base_doc_entry, base_line: r.line.base_line, qty: r.qty })), series);
      qc.invalidateQueries({ queryKey: ['erp-list'] });
      qc.invalidateQueries({ queryKey: ['sales-flow'] });
      if (res.state === 'pending_approval') nav(`/sales/requests/${company}/${res.request_id}`, { state: { flash: t('sreq.flash.sent', { no: res.doc_no }) } });
      else nav(`/docs/ar_credit_note/${company}/${res.doc_entry}`, { state: { flash: t('sc.flash.creditMemo', { no: res.doc_no }) } });
    } catch (e) {
      setErr(errorMessage(e));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally { setBusy(false); }
  }

  return (
    <CreateShell kind="ar_credit_note" title={t('sc.newCreditMemo')} error={err}
      sub={[h.card_code, h.card_name, t('sc.fromInvoice', { no: h.doc_no })].filter(Boolean).join(' · ')}
      flow={<DocFlow company={company} obj={13} entry={invoice} current="credit" />}
      aside={
        <SectionCard title={t('sc.addTitle')}>
          <div className="space-y-3 p-5">
            <p className="text-sm text-muted">{ret && anyStock ? t('sc.creditWhatReturn') : t('sc.creditWhat')}</p>
            <Button variant="primary" id="sc-submit" className="w-full" onClick={submit} disabled={busy || !canWrite || !sel.length} disabledReason={!canWrite ? readOnlyReason : undefined}>
              {busy ? t('so.saving') : t('sc.addCreditMemo')}
            </Button>
            <Link to={`/docs/ar_invoice/${company}/${invoice}`} className="inline-flex min-h-[44px] w-full items-center justify-center rounded-btn px-4 text-[15px] font-medium text-ink hover:bg-page">{t('so.cancelEdit')}</Link>
          </div>
        </SectionCard>
      }>
      <SectionCard title={t('erp.section.header')}>
        <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <label className="block text-xs font-medium text-muted">{t('erp.col.postingDate')} <span className="text-crit-fg">*</span>
            <input id="sc-doc_date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <label className="block text-xs font-medium text-muted">{t('erp.col.remarks')}
            <input id="sc-comments" className="input mt-1 text-[15px] text-ink" dir="auto" value={comments} onChange={(e) => setComments(e.target.value)} placeholder={t('sc.creditReasonPh')} />
          </label>
          <label className="flex min-h-[44px] items-center gap-3 text-[15px]">
            <input id="sc-return" type="checkbox" className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked={ret} onChange={(e) => setRet(e.target.checked)} />
            {t('sc.returnStock')}
          </label>
          {ret && (
            <label className="block text-xs font-medium text-muted">{t('sc.returnWhs')}
              <select id="sc-whs" className="input mt-1 text-[15px] text-ink" value={whs} onChange={(e) => setWhs(e.target.value)}>
                {setup.data?.warehouses.map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}
              </select>
            </label>
          )}
          <SeriesPicker company={company} obj={14} value={series} onChange={setSeries} date={date} />
          <label className="block text-xs font-medium text-muted sm:col-span-2">{t('sreq.reasonField')}
            <input id="sc-approval-reason" className="input mt-1 text-[15px] text-ink" dir="auto" value={why} onChange={(e) => setWhy(e.target.value)} placeholder={t('sreq.reasonPhCredit')} />
          </label>
        </div>
      </SectionCard>
      <SectionCard title={t('sc.linesToCredit')}>
        <PickTable rows={rows} setRows={setRows} />
        <div className="flex justify-end border-t border-line"><Totals {...tot} currency={h.currency} /></div>
      </SectionCard>
    </CreateShell>
  );
}

// ---------- Delivery / A/R invoice / A/R credit memo page ----------
export function SalesDocPage({ kind }: { kind: CycleKind }) {
  const { t } = useTranslation();
  const { company = '', entry = '' } = useParams();
  const id = Number(entry);
  const obj = DOC_KINDS[kind].obj;
  const loc = useLocation();
  const [flash, setFlash] = useState<string | null>((loc.state as { flash?: string } | null)?.flash ?? null);
  useEffect(() => { if (flash) { const h = setTimeout(() => setFlash(null), 8000); return () => clearTimeout(h); } }, [flash]);
  const q = useQuery({
    queryKey: ['doc', kind, company, entry],
    queryFn: async () => {
      const { data, error } = await erp().from('document').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).maybeSingle();
      if (error) throw new ApiError(error);
      if (!data) return null;
      const { data: ls, error: le } = await erp().from('document_line').select('*').match({ company_code: company, obj_type: obj, doc_entry: id }).order('line_num');
      if (le) throw new ApiError(le);
      return { doc: data as R, lines: (ls ?? []) as R[] };
    },
  });
  const view = useDocView(company, obj, id);
  const V = view.data;
  const d = q.data?.doc;

  let body: ReactNode = null;
  if (q.isLoading || view.isLoading) body = <PageLoading />;
  else if (q.error || view.error) body = <div className="card"><ErrorState error={q.error ?? view.error} onRetry={() => { q.refetch(); view.refetch(); }} /></div>;
  else if (!d) body = <div className="card"><EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} /></div>;
  if (body) return <RequireModule module="sales"><DocHeader kind={kind} title={t(`erp.doc.${kind}`)} />{body}</RequireModule>;

  const lines = q.data!.lines;
  const docNo = V?.doc_no ?? String(d!.doc_num);
  const title = t(`sc.title.${kind}`, { no: docNo });
  const before = lines.reduce((s, l) => s + r2(Number(l.quantity ?? 0) * Number(l.price ?? 0)), 0);
  const net = lines.reduce((s, l) => s + Number(l.line_total ?? 0), 0);
  const showOpen = kind !== 'ar_credit_note' && d!.source === 'erp';
  const copy = kind === 'delivery' ? { label: t('sc.copyToInvoice'), to: `/docs/ar_invoice/new?company=${company}&delivery=${id}` }
    : kind === 'ar_invoice' ? { label: t('sc.copyToCreditMemo'), to: `/docs/ar_credit_note/new?company=${company}&invoice=${id}` } : null;
  const whs = [...new Set(lines.map((l) => l.whs_code).filter(Boolean))].join(', ');

  return (
    <RequireModule module="sales">
      <DocHeader kind={kind} title={title}
        pills={<><StatusTag value={d!.status} /><SourcePill source={d!.source} /><LiveBadge live /></>}
        sub={[d!.card_name, V?.created_by_name, V?.created_at ? t('so.createdAt', { when: fmtWhen(V.created_at) }) : d!.created_on ? t('so.createdAt', { when: fmtDay(d!.created_on) }) : null].filter(Boolean).join(' · ')}
        actions={<>
          <Link to={`/print/${kind}/${company}/${id}`} id="sc-print" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-line bg-surface px-4 text-[15px] font-medium text-ink hover:bg-page">
            <Printer className="h-4 w-4" aria-hidden />{t('so.print')}
          </Link>
          {copy && (V?.can_copy ? (
            <Link to={copy.to} id="sc-copy" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover">{copy.label}</Link>
          ) : (
            <Button variant="secondary" id="sc-copy" disabled disabledReason={V?.copy_block === 'source' ? t('sc.copyErpOnly') : V?.copy_block ? t(`sc.copyBlock.${V.copy_block}`) : undefined}>{copy.label}</Button>
          ))}
        </>} />
      <DocFlow company={company} obj={obj} entry={id} />
      <Flash text={flash} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.header')}>
            <Fields items={[
              [t('erp.col.customer'), <Link className="text-primary hover:underline" to={`/bp/${company}/${encodeURIComponent(d!.card_code ?? '')}`}>{d!.card_code} · {d!.card_name}</Link>],
              [t('erp.col.postingDate'), fmtDay(d!.doc_date)],
              [kind === 'ar_invoice' ? t('erp.col.dueDate') : t('sc.docDate'), fmtDay(kind === 'ar_invoice' ? d!.due_date : d!.tax_date ?? d!.doc_date)],
              [t('erp.col.warehouse'), whs || null],
              [t('erp.col.customerRef'), d!.customer_ref],
              [t('erp.col.remarks'), d!.comments],
              ...(kind === 'ar_credit_note' ? [[t('sc.returnStock'), V?.return_stock ? t('erp.yes') : t('erp.no')] as [string, ReactNode]] : []),
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
                    {showOpen && <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t(kind === 'delivery' ? 'sc.col.notInvoiced' : 'sc.col.notCredited')}</th>}
                    <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('so.unitPrice')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end max-md:hidden">{t('so.disc')}</th>
                    <th scope="col" className="px-4 py-2.5 text-end">{t('erp.col.lineTotal')}</th>
                  </tr></thead>
                  <tbody>
                    {lines.map((l) => (
                      <tr key={l.line_num} data-testid="sc-line" className="border-t border-line align-top">
                        <td className="px-4 py-2.5">
                          <div dir="auto" className="font-semibold">{l.description ?? l.item_code}</div>
                          <div className="text-xs text-muted"><Link className="font-mono hover:underline" to={`/items/${company}/${encodeURIComponent(l.item_code ?? '')}`}>{l.item_code}</Link>
                            {l.whs_code ? ` · ${l.whs_code}` : ''}{l.tax_code ? ` · ${l.tax_code}` : ''}</div>
                        </td>
                        <td className="num px-4 py-2.5 text-end">{fmtQty(l.quantity)} <span className="text-muted">{l.uom}</span></td>
                        {showOpen && <td className="num px-4 py-2.5 text-end max-sm:hidden" data-testid="sc-open-qty">{fmtQty(l.line_status === 'C' ? 0 : l.open_qty)}</td>}
                        <td className="num px-4 py-2.5 text-end max-sm:hidden">{fmtMoney(l.price)}</td>
                        <td className="num px-4 py-2.5 text-end max-md:hidden">{Number(l.discount_pct) ? `${fmtQty(l.discount_pct)}%` : '—'}</td>
                        <td className="num px-4 py-2.5 text-end font-medium">{fmtMoney(l.line_total)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <div className="flex justify-end"><Totals before={r2(before)} discount={r2(before - net)} vat={Number(d!.vat_total ?? 0)} total={Number(d!.total ?? 0)} currency={d!.currency ?? ''} /></div>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          <SectionCard title={t('sc.postingTitle')}>
            <div className="space-y-2 p-5 text-sm" data-testid="sc-posting">
              {d!.source !== 'erp' ? <p className="text-muted">{d!.source === 'sap' ? t('sc.sapPosted') : t('so.sampleReadOnly')}</p> : V?.trans_id ? (
                <>
                  <p className="font-semibold text-ok-fg">{t(`sc.posted.${kind}`)}{kind === 'ar_credit_note' && V.return_stock ? ` ${t('sc.posted.returned')}` : ''}</p>
                  <p>{t('sc.journal')}{' '}
                    {V.can_read_journal
                      ? <Link className="font-mono text-primary hover:underline" to={`/financials/journals/${company}/${V.trans_id}`}>{V.trans_id}</Link>
                      : <span className="font-mono">{V.trans_id}</span>}</p>
                </>
              ) : <p className="text-muted">{t('sc.noJournal')}</p>}
            </div>
          </SectionCard>
          {(V?.activity?.length ?? 0) > 0 && (
            <SectionCard title={t('so.activity.title')}>
              <ol className="space-y-3 p-5 text-sm">
                {V!.activity.map((a, i) => (
                  <li key={i}><span className="font-medium">{a.actor_name}</span> {t(`sc.activity.${a.action}`, { defaultValue: a.action })}
                    <p className="num text-xs text-muted">{fmtWhen(a.at)}</p></li>
                ))}
              </ol>
            </SectionCard>
          )}
          <AskAiDocCard company={company} obj={obj} entry={id} title={t('ai.docTitle')} label={t(`erp.doc.${kind}`)} />
        </aside>
      </div>
    </RequireModule>
  );
}

// ---------- Print / PDF (A4, browser print; English and Arabic labels) ----------
const PRINT_KINDS: Record<string, number> = { sales_quotation: 23, sales_order: 17, delivery: 15, ar_invoice: 13, ar_credit_note: 14 };

export function SalesPrintPage() {
  const { kind = '', company = '', entry = '' } = useParams();
  const { t } = useTranslation();
  const obj = PRINT_KINDS[kind];
  const q = useQuery({ queryKey: ['print', kind, company, entry], enabled: Boolean(obj), queryFn: () => printData(company, obj, Number(entry)) });
  const en = useMemo(() => i18n.getFixedT('en'), []);
  const ar = useMemo(() => i18n.getFixedT('ar'), []);
  // Labels in both languages; <bdi> keeps each label's own direction next to numbers and codes.
  const both = (k: string) => <bdi>{i18n.language === 'ar' ? `${ar(k)} · ${en(k)}` : `${en(k)} · ${ar(k)}`}</bdi>;
  useEffect(() => { document.title = q.data ? `${q.data.doc.doc_no} · ${q.data.company.short_name}` : 'Print'; }, [q.data]);
  const back = `/docs/${kind}/${company}/${entry}`;

  let body: ReactNode;
  if (!obj) body = <EmptyState title={t('erp.notFound')} />;
  else if (q.isLoading) body = <PageLoading />;
  else if (q.error) body = <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  else if (!q.data) body = <EmptyState title={t('erp.notFound')} body={t('erp.notFoundBody')} />;
  if (body) return <main className="mx-auto max-w-3xl p-6">{body}</main>;

  const P = q.data!;
  const cur = P.doc.currency;
  const addr = P.customer.address;
  const before = P.lines.reduce((s, l) => s + r2(Number(l.qty) * Number(l.price)), 0);
  const net = P.lines.reduce((s, l) => s + Number(l.line_total), 0);
  const titleKey = `print.title.${kind}`;
  return (
    <div className="min-h-screen bg-page">
      <div className="no-print sticky top-0 z-10 flex flex-wrap items-center justify-between gap-3 border-b border-line bg-surface px-4 py-3">
        <Link to={back} className="inline-flex min-h-[44px] items-center gap-1 text-sm font-medium text-primary hover:underline"><ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('print.back')}</Link>
        <div className="flex items-center gap-3">
          <span className="text-sm text-muted max-sm:hidden">{t('print.hint')}</span>
          <Button variant="primary" id="print-now" onClick={() => window.print()} icon={<Printer className="h-4 w-4" aria-hidden />}>{t('so.print')}</Button>
        </div>
      </div>
      {P.doc.source !== 'erp' && <p className="no-print mx-auto mt-4 max-w-[210mm] rounded-btn border border-warn-fg/30 bg-warn-bg px-4 py-2 text-sm text-warn-fg">{P.doc.source === 'sap' ? t('print.sapCopy') : t('print.sampleCopy')}</p>}
      <article className="paper mx-auto my-6 w-[210mm] max-w-full border border-line bg-surface p-[14mm] text-[12.5px] leading-snug text-ink shadow-card max-sm:p-5" data-testid="print-sheet">
        <header className="flex flex-wrap items-start justify-between gap-4 border-b-2 border-ink pb-4">
          <div className="min-w-0">
            <p dir="auto" className="text-[20px] font-semibold">{P.company.legal_name}</p>
            {P.company.licence_authority && <p className="text-ink-2">{P.company.licence_authority}</p>}
            <p className="mt-1"><span className="text-muted">{both('print.trn')}:</span> <span className="font-mono" data-testid="print-company-trn">{P.company.tax_id ?? '—'}</span></p>
          </div>
          <div className="text-end">
            <p className="text-[18px] font-semibold uppercase tracking-wide" data-testid="print-title">{en(titleKey)}</p>
            <p className="text-[18px] font-semibold" dir="rtl" lang="ar">{ar(titleKey)}</p>
            <p className="mt-1 font-mono text-[14px]" data-testid="print-doc-no">{P.doc.doc_no}</p>
          </div>
        </header>

        <section className="grid grid-cols-2 gap-6 border-b border-line py-4 max-sm:grid-cols-1">
          <div className="min-w-0">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-muted">{both('print.billTo')}</p>
            <p dir="auto" className="mt-1 text-[14px] font-semibold">{P.customer.name}</p>
            {P.customer.foreign_name && <p dir="rtl" lang="ar">{P.customer.foreign_name}</p>}
            {addr && <p dir="auto" className="text-ink-2">{[addr.building, addr.street, addr.block, addr.city, addr.country].filter(Boolean).join(', ')}</p>}
            {!addr && (P.customer.city || P.customer.country) && <p className="text-ink-2">{[P.customer.city, P.customer.country].filter(Boolean).join(', ')}</p>}
            <p><span className="text-muted">{both('print.customerTrn')}:</span> <span className="font-mono">{P.customer.trn ?? '—'}</span></p>
            {P.customer.phone && <p className="text-ink-2">{P.customer.phone}</p>}
          </div>
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 self-start">
            <dt className="text-muted">{both('print.date')}</dt><dd className="num text-end">{P.doc.doc_date}</dd>
            {P.doc.due_date && kind !== 'delivery' && <><dt className="text-muted">{both(kind === 'sales_quotation' ? 'print.validUntil' : kind === 'sales_order' ? 'print.deliveryDate' : 'print.dueDate')}</dt><dd className="num text-end">{P.doc.due_date}</dd></>}
            <dt className="text-muted">{both('print.customerCode')}</dt><dd className="text-end font-mono">{P.customer.card_code}</dd>
            {P.doc.customer_ref && <><dt className="text-muted">{both('print.customerRef')}</dt><dd className="text-end">{P.doc.customer_ref}</dd></>}
            {(P.doc.base_docs?.length ?? 0) > 0 && <><dt className="text-muted">{both('print.basedOn')}</dt><dd className="text-end font-mono">{P.doc.base_docs!.join(', ')}</dd></>}
            {P.doc.salesperson && <><dt className="text-muted">{both('print.salesperson')}</dt><dd className="text-end">{P.doc.salesperson}</dd></>}
            <dt className="text-muted">{both('print.currency')}</dt><dd className="text-end">{cur}</dd>
          </dl>
        </section>

        <table className="mt-4 w-full border-collapse">
          <thead>
            <tr className="border-y border-ink text-[10.5px] uppercase tracking-wide">
              <th scope="col" className="py-2 pe-2 text-start">#</th>
              <th scope="col" className="py-2 pe-2 text-start">{en('print.description')}<br /><span lang="ar">{ar('print.description')}</span></th>
              <th scope="col" className="py-2 pe-2 text-end">{en('print.qty')}<br /><span lang="ar">{ar('print.qty')}</span></th>
              {kind !== 'delivery' && <>
                <th scope="col" className="py-2 pe-2 text-end">{en('print.unitPrice')}<br /><span lang="ar">{ar('print.unitPrice')}</span></th>
                <th scope="col" className="py-2 pe-2 text-end">{en('print.discount')}<br /><span lang="ar">{ar('print.discount')}</span></th>
                <th scope="col" className="py-2 pe-2 text-end">{en('print.net')}<br /><span lang="ar">{ar('print.net')}</span></th>
                <th scope="col" className="py-2 pe-2 text-end">{en('print.vat')}<br /><span lang="ar">{ar('print.vat')}</span></th>
                <th scope="col" className="py-2 text-end">{en('print.total')}<br /><span lang="ar">{ar('print.total')}</span></th>
              </>}
            </tr>
          </thead>
          <tbody>
            {P.lines.map((l) => (
              <tr key={l.line_num} className="border-b border-line align-top" data-testid="print-line">
                <td className="py-1.5 pe-2 text-muted">{l.line_num + 1}</td>
                <td className="py-1.5 pe-2">
                  <div dir="auto">{l.description ?? l.item_code}</div>
                  {l.foreign_name && <div dir="rtl" lang="ar" className="text-ink-2">{l.foreign_name}</div>}
                  <div className="font-mono text-[10.5px] text-muted">{l.item_code}{l.tax_code ? ` · ${l.tax_code}` : ''}</div>
                </td>
                <td className="num py-1.5 pe-2 text-end">{fmtQty(l.qty)} {l.uom}</td>
                {kind !== 'delivery' && <>
                  <td className="num py-1.5 pe-2 text-end">{fmtMoney(l.price)}</td>
                  <td className="num py-1.5 pe-2 text-end">{Number(l.discount_pct) ? `${fmtQty(l.discount_pct)}%` : '—'}</td>
                  <td className="num py-1.5 pe-2 text-end">{fmtMoney(l.line_total)}</td>
                  <td className="num py-1.5 pe-2 text-end">{fmtMoney(l.vat)}</td>
                  <td className="num py-1.5 text-end">{fmtMoney(Number(l.line_total) + Number(l.vat))}</td>
                </>}
              </tr>
            ))}
          </tbody>
        </table>

        {kind !== 'delivery' && (
          <section className="mt-4 flex flex-wrap items-start justify-between gap-6">
            <table className="text-[11.5px]">
              <caption className="pb-1 text-start text-[10.5px] font-semibold uppercase tracking-wide text-muted">{both('print.vatSummary')}</caption>
              <tbody>
                {P.vat.map((v) => (
                  <tr key={v.tax_code ?? '-'}><td className="pe-4">{v.tax_code} · {fmtQty(v.rate)}%</td><td className="num pe-4 text-end">{fmtMoney(v.net)}</td><td className="num text-end">{fmtMoney(v.vat)}</td></tr>
                ))}
              </tbody>
            </table>
            <dl className="num ms-auto grid min-w-[260px] grid-cols-[1fr_auto] gap-x-6 gap-y-1 text-[13px]">
              <dt className="text-muted">{both('print.subtotal')}</dt><dd className="text-end">{fmtMoney(before)}</dd>
              <dt className="text-muted">{both('print.discount')}</dt><dd className="text-end">{fmtMoney(r2(before - net))}</dd>
              <dt className="text-muted">{both('print.vat')}</dt><dd className="text-end">{fmtMoney(P.doc.vat_total)}</dd>
              <dt className="border-t-2 border-ink pt-1 text-[15px] font-semibold">{both('print.total')} ({cur})</dt>
              <dd className="border-t-2 border-ink pt-1 text-end text-[15px] font-semibold" data-testid="print-total">{fmtMoney(P.doc.total)}</dd>
            </dl>
          </section>
        )}

        {P.doc.comments && <p dir="auto" className="mt-5 border-t border-line pt-3 text-ink-2"><span className="text-muted">{both('print.remarks')}:</span> {P.doc.comments}</p>}
        {kind === 'delivery' && (
          <section className="mt-10 grid grid-cols-2 gap-10">
            <p className="border-t border-ink pt-1 text-muted">{both('print.deliveredBy')}</p>
            <p className="border-t border-ink pt-1 text-muted">{both('print.receivedBy')}</p>
          </section>
        )}
        <footer className="mt-8 border-t border-line pt-2 text-[10.5px] text-muted">
          {P.company.legal_name} · {both('print.trn')} {P.company.tax_id ?? '—'} · {P.doc.doc_no} · {en('print.footer')}
        </footer>
      </article>
    </div>
  );
}

// ---------- Sales › Available-to-Promise Check ----------
export function AtpCheckPage() {
  const { t } = useTranslation();
  const company = useDefaultCompany();
  const setup = useSoSetup(company || null, 17);
  const [itemText, setItemText] = useState('');
  const [item, setItem] = useState('');
  const [whs, setWhs] = useState('');
  const [date, setDate] = useState(today());
  const [res, setRes] = useState<AtpCheck | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (setup.data && !whs) setWhs(setup.data.default_whs_code ?? setup.data.warehouses[0]?.code ?? ''); }, [setup.data, whs]);
  const m = moduleByKey('sales')!;
  const opts = async (s: string) => (await searchStockItems(company, s)).map((it) => ({ value: it.item_code, label: `${it.item_code} · ${it.name}`, data: it }));
  async function run() {
    setErr(null); setRes(null);
    if (!item) { setErr(t('sc.atp.chooseItem')); return; }
    setBusy(true);
    try { setRes(await atpCheck(company, item, whs, date)); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  return (
    <RequireModule module="sales">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/sales'], [t('sc.atp.title'), undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{t('sc.atp.title')} <LiveBadge live /></span>} desc={t('sc.atp.desc')}
        actions={<Link to="/sales/atp-rules" className="inline-flex min-h-[44px] items-center rounded-btn border border-line bg-surface px-4 text-[15px] font-medium hover:bg-page">{t('sc.atp.rulesLink')}</Link>} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <SectionCard title={t('sc.atp.checkTitle')}>
          <div className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2 xl:grid-cols-[minmax(0,1fr)_160px_180px_auto] xl:items-end">
            <Combobox id="atp-item" label={t('so.item')} required text={itemText} onText={(s) => { setItemText(s); setItem(''); }} search={opts}
              placeholder={t('so.itemPh')} noMatch={t('so.combo.noItem')} onSelect={(o) => { setItem(o.value); setItemText(o.label); }} />
            <label className="block text-xs font-medium text-muted">{t('erp.col.warehouse')}
              <select id="atp-whs" className="input mt-1 text-[15px] text-ink" value={whs} onChange={(e) => setWhs(e.target.value)}>
                {setup.data?.warehouses.map((w) => <option key={w.code} value={w.code}>{w.code} · {w.name}</option>)}
              </select>
            </label>
            <label className="block text-xs font-medium text-muted">{t('sc.atp.byDate')}
              <input id="atp-date" type="date" className="input num mt-1 text-[15px] text-ink" value={date} onChange={(e) => setDate(e.target.value)} />
            </label>
            <Button variant="primary" id="atp-run" onClick={run} disabled={busy}>{t('sc.atp.check')}</Button>
          </div>
          {res && (
            <div className="border-t border-line p-5" data-testid="atp-result">
              {res.available == null ? <p className="text-sm text-muted">{res.message ?? t('sc.atp.noCheck')}</p> : (
                <>
                  <p className="text-[17px] font-semibold">{t('sc.atp.canPromiseLong', { n: fmtQty(Math.max(Number(res.available), 0)), item: res.item_code, date: fmtDay(res.date), whs: res.whs_code })}</p>
                  <dl className="num mt-3 grid max-w-sm grid-cols-2 gap-x-6 gap-y-1 text-sm">
                    <dt className="text-muted">{t('erp.col.onHand')}</dt><dd className="text-end">{fmtQty(res.on_hand)}</dd>
                    <dt className="text-muted">{t('sc.atp.committed')}</dt><dd className="text-end">−{fmtQty(res.committed)}</dd>
                    <dt className="text-muted">{t('sc.atp.pos')}</dt><dd className="text-end">+{fmtQty(res.purchase_orders)}</dd>
                    <dt className="text-muted">{t('sc.atp.transfers')}</dt><dd className="text-end">+{fmtQty(res.transfers)}</dd>
                    <dt className="font-semibold">{t('sc.atp.available')}</dt><dd className="text-end font-semibold">{fmtQty(res.available)}</dd>
                  </dl>
                  <p className="mt-2 text-xs text-muted">{t('sc.atp.ruleUsed', { rule: res.rule_code, name: res.rule_name ?? '' })}</p>
                </>
              )}
            </div>
          )}
        </SectionCard>
        <SectionCard title={t('sc.atp.incoming')}>
          {!res?.incoming?.length ? <p className="p-5 text-sm text-muted">{t('sc.atp.noIncoming')}</p> : (
            <ul className="divide-y divide-line text-sm">
              {res.incoming.map((x) => (
                <li key={`${x.obj_type}-${x.doc_entry}-${x.whs_code}`} className={clsx('flex items-center justify-between gap-3 px-5 py-2.5', !x.counted && 'text-muted')}>
                  <span><span className="font-mono">{x.doc_no}</span> · {x.obj_type === 22 ? t('sc.atp.po') : t('sc.atp.tr')} · {fmtDay(x.due_date)}</span>
                  <span className="num">{fmtQty(x.open_qty)}{!x.counted && ` · ${t('sc.atp.later')}`}</span>
                </li>
              ))}
            </ul>
          )}
          <p className="border-t border-line p-5 text-xs text-muted">{t('sc.atp.containersLater')}</p>
        </SectionCard>
      </div>
    </RequireModule>
  );
}

// ---------- Setup › Sales › ATP Checking Rule List ----------
const emptyRule = (): Partial<AtpRule> => ({ rule_code: '', name: '', whs_scope: 'order_whs', subtract_committed: true, include_purchase_orders: true,
  include_transfers: false, include_in_transit: false, no_check: false, item_group: null, is_default: false, active: true, note: '' });

export function AtpRulesPage() {
  const { t } = useTranslation();
  const company = useDefaultCompany();
  const qc = useQueryClient();
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  const rules = useAtpRules(company || null);
  const groups = useQuery({
    queryKey: ['item-groups', company], enabled: Boolean(company),
    queryFn: async () => {
      const { data, error } = await erp().from('item_group').select('group_code,name').eq('company_code', company).order('group_code');
      if (error) throw new ApiError(error);
      return (data ?? []) as Array<{ group_code: number; name: string }>;
    },
  });
  const [edit, setEdit] = useState<Partial<AtpRule> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const m = moduleByKey('sales')!;
  async function save() {
    if (!edit) return;
    setErr(null); setBusy(true);
    try {
      const r = await atpRuleSave(company, edit);
      setEdit(null); setFlash(t('sc.rules.saved', { code: r.rule_code }));
      qc.invalidateQueries({ queryKey: ['atp-rules', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  const counts = (r: AtpRule) => [t('erp.col.onHand'), r.subtract_committed && `− ${t('sc.atp.committed')}`, r.include_purchase_orders && `+ ${t('sc.atp.pos')}`,
    r.include_transfers && `+ ${t('sc.atp.transfers')}`, r.include_in_transit && `+ ${t('sc.rules.inTransit')}`].filter(Boolean).join(' ');
  const set = (p: Partial<AtpRule>) => setEdit((e) => ({ ...e, ...p }));
  return (
    <RequireModule module="sales">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/sales'], [t('sc.rules.title'), undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{t('sc.rules.title')} <LiveBadge live /></span>} desc={t('sc.rules.desc')}
        actions={<Button variant="primary" id="rule-new" onClick={() => { setEdit(emptyRule()); setErr(null); }} disabled={!canWrite} disabledReason={readOnlyReason}><Plus className="h-4 w-4" aria-hidden /> {t('sc.rules.new')}</Button>} />
      <Flash text={flash} />
      {edit && (
        <SectionCard title={edit.rule_id ? t('sc.rules.editTitle', { code: edit.rule_code }) : t('sc.rules.new')} className="mb-5">
          <div className="p-5">
            <FormError message={err} />
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
              <label className="block text-xs font-medium text-muted">{t('sc.rules.code')} <span className="text-crit-fg">*</span>
                <input id="rule-code" className="input mt-1 font-mono text-[15px] text-ink" value={edit.rule_code ?? ''} disabled={Boolean(edit.rule_id)} onChange={(e) => set({ rule_code: e.target.value })} placeholder="ATP-STD" />
              </label>
              <label className="block text-xs font-medium text-muted">{t('erp.col.name')} <span className="text-crit-fg">*</span>
                <input id="rule-name" className="input mt-1 text-[15px] text-ink" dir="auto" value={edit.name ?? ''} onChange={(e) => set({ name: e.target.value })} />
              </label>
              <label className="block text-xs font-medium text-muted">{t('sc.rules.scope')}
                <select id="rule-scope" className="input mt-1 text-[15px] text-ink" value={edit.whs_scope} onChange={(e) => set({ whs_scope: e.target.value as AtpRule['whs_scope'] })}>
                  <option value="order_whs">{t('sc.rules.scopeOrder')}</option><option value="all_whs">{t('sc.rules.scopeAll')}</option>
                </select>
              </label>
              <label className="block text-xs font-medium text-muted">{t('sc.rules.usedFor')}
                <select id="rule-group" className="input mt-1 text-[15px] text-ink" value={edit.item_group ?? ''} onChange={(e) => set({ item_group: e.target.value === '' ? null : Number(e.target.value) })}>
                  <option value="">{t('sc.rules.allItems')}</option>
                  {groups.data?.map((g) => <option key={g.group_code} value={g.group_code}>{g.group_code} · {g.name}</option>)}
                </select>
              </label>
              {([['subtract_committed', 'sc.rules.subtract'], ['include_purchase_orders', 'sc.rules.pos'], ['include_transfers', 'sc.rules.transfers'],
                ['include_in_transit', 'sc.rules.inTransitLong'], ['no_check', 'sc.rules.noCheck'], ['is_default', 'sc.rules.default'], ['active', 'erp.status.active']] as Array<[keyof AtpRule, string]>).map(([k, label]) => (
                <label key={k} className="flex min-h-[44px] items-center gap-3 text-[15px]">
                  <input type="checkbox" id={`rule-${k}`} className="h-5 w-5 accent-[rgb(var(--c-primary))]" checked={Boolean(edit[k])} onChange={(e) => set({ [k]: e.target.checked } as Partial<AtpRule>)} />{t(label)}
                </label>
              ))}
              <label className="block text-xs font-medium text-muted sm:col-span-2">{t('so.note')}
                <input id="rule-note" className="input mt-1 text-[15px] text-ink" dir="auto" value={edit.note ?? ''} onChange={(e) => set({ note: e.target.value })} />
              </label>
            </div>
            <div className="mt-4 flex flex-wrap gap-2">
              <Button variant="primary" id="rule-save" onClick={save} disabled={busy}>{busy ? t('so.saving') : t('sc.rules.save')}</Button>
              <Button variant="secondary" onClick={() => setEdit(null)}>{t('so.cancelEdit')}</Button>
            </div>
          </div>
        </SectionCard>
      )}
      <SectionCard title={t('sc.rules.listTitle', { count: rules.data?.length ?? 0 })}>
        {rules.isLoading ? <PageLoading /> : rules.error ? <ErrorState error={rules.error} onRetry={() => rules.refetch()} /> : !rules.data?.length ? (
          <EmptyState title={t('sc.rules.none')} body={t('sc.rules.noneBody')} />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-[14px] sm:min-w-[640px]" data-testid="rules-table">
              <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                <th scope="col" className="px-4 py-2.5 text-start">{t('sc.rules.code')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.name')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-md:hidden">{t('sc.rules.counts')}</th>
                <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('sc.rules.usedFor')}</th>
                <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
              </tr></thead>
              <tbody>
                {rules.data.map((r) => (
                  <tr key={r.rule_id} className="border-t border-line">
                    <td className="px-4 py-2.5">
                      {canWrite ? <button type="button" className="font-mono text-primary hover:underline" onClick={() => { setEdit(r); setErr(null); }}>{r.rule_code}</button> : <span className="font-mono">{r.rule_code}</span>}
                    </td>
                    <td className="px-4 py-2.5" dir="auto">{r.name}{r.is_default && <span className="pill pill-info ms-2">{t('sc.rules.default')}</span>}</td>
                    <td className="px-4 py-2.5 text-ink-2 max-md:hidden">{r.no_check ? t('sc.rules.noCheck') : counts(r)} · {r.whs_scope === 'all_whs' ? t('sc.rules.scopeAll') : t('sc.rules.scopeOrder')}</td>
                    <td className="px-4 py-2.5 max-sm:hidden">{r.item_group != null ? groups.data?.find((g) => g.group_code === r.item_group)?.name ?? r.item_group : t('sc.rules.allItems')}</td>
                    <td className="px-4 py-2.5"><StatusTag value={r.active ? 'active' : 'inactive'} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="border-t border-line p-5 text-sm text-muted">{t('sc.rules.note')}</p>
      </SectionCard>
    </RequireModule>
  );
}

/** "+ New …" on the quotation, delivery, invoice and credit memo lists. */
export function NewCycleAction({ kind }: { kind: DocKind }) {
  const { t } = useTranslation();
  const { canWrite, readOnlyReason } = useModuleLevel('sales');
  const to = kind === 'sales_quotation' ? '/docs/sales_quotation/new' : kind === 'ar_invoice' ? '/docs/ar_invoice/new' : null;
  const label = t(`sc.new.${kind}`);
  if (!canWrite || !to) {
    return <Button variant="primary" disabled id={`new-${kind}`} disabledReason={!canWrite ? readOnlyReason : t(`sc.newHint.${kind}`)}><Plus className="h-4 w-4" aria-hidden /> {label}</Button>;
  }
  return (
    <Link to={to} id={`new-${kind}`} className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 text-[15px] font-medium text-white hover:bg-primary-hover">
      <Plus className="h-4 w-4" aria-hidden /> {label}
    </Link>
  );
}
