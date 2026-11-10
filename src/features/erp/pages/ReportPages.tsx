import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ArrowLeft, BarChart3, Download, Lock, Play, Printer, Sparkles } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading, SkeletonRows } from '@/components/States';
import { LiveBadge, PageTitle, SectionCard } from '../components/ui';
import { RequireModule } from '../components/Guard';
import { useAskAi } from '../components/AskAi';
import { useOptions } from '../api';
import { moduleByKey } from '../modules';
import {
  OPEN_KINDS, REPORTS, REPORT_CATS, canRun, cellText, colLabel, defaultParams, downloadCsv, orderedRows, paramString, reportByCode,
  sectionLabel, useReport, type ReportDef, type ReportParams, type Row,
} from '../reports';

const hideCls = { sm: 'max-sm:hidden', md: 'max-md:hidden', lg: 'max-lg:hidden' } as const;
const money = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function useMods() {
  const { profile } = useAuth();
  return profile?.modules ?? [];
}

// ---------- Library (/reports) ----------
export function ReportsLibraryPage() {
  const { t } = useTranslation();
  const mods = useMods();
  const [sp, setSp] = useSearchParams();
  const { open } = useAskAi();
  const cat = sp.get('cat') ?? '';
  const rep = moduleByKey('reports')!;
  useEffect(() => { if (sp.get('ask') === '1') open({}); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const cats = REPORT_CATS.filter((c) => !cat || c.key === cat);

  return (
    <RequireModule module="reports">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${rep.num} ${rep.title}`, '/m/reports'], [t('rpt.library'), undefined]]}
        eyebrow={`${t('erp.module')} ${rep.num}`} title={<span className="inline-flex items-center gap-3">{t('rpt.library')} <LiveBadge live /></span>}
        desc={t('rpt.libraryDesc')}
        actions={<Button variant="secondary" id="rpt-ask" icon={<Sparkles className="h-4 w-4" aria-hidden />} onClick={() => open({})}>{t('rpt.askAi')}</Button>} />
      <div className="mb-5 flex flex-wrap gap-2" role="group" aria-label={t('rpt.categories')}>
        {[{ key: '', label: t('rpt.all') }, ...REPORT_CATS.map((c) => ({ key: c.key, label: t(`rpt.cat.${c.key}`) }))].map((c) => (
          <button key={c.key || 'all'} type="button" aria-pressed={cat === c.key} onClick={() => setSp(c.key ? { cat: c.key } : {}, { replace: true })}
            className={clsx('min-h-[40px] rounded-full px-4 text-sm font-semibold', cat === c.key ? 'bg-ink text-surface' : 'border border-line-strong hover:bg-surface-2')}>{c.label}</button>
        ))}
      </div>
      <div className="space-y-6">
        {cats.map((c) => {
          const list = REPORTS.filter((r) => r.cat === c.key);
          const fn = rep.functions.find((f) => f.name === c.menu);
          const planned = (fn?.items ?? []).filter((it) => !list.some((r) => r.menuItem === it.name)).length;
          return (
            <section key={c.key} aria-labelledby={`cat-${c.key}`}>
              <h2 id={`cat-${c.key}`} className="eyebrow mb-3">{t(`rpt.cat.${c.key}`)}</h2>
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
                {list.map((r) => {
                  const ok = canRun(r, mods);
                  const body = (
                    <>
                      <span className="grid h-10 w-10 shrink-0 place-items-center rounded-btn bg-primary-soft text-primary">{ok ? <BarChart3 className="h-5 w-5" aria-hidden /> : <Lock className="h-5 w-5" aria-hidden />}</span>
                      <span className="min-w-0">
                        <span className="block font-semibold">{t(`rpt.name.${r.code}`)}</span>
                        <span className="mt-1 block text-sm text-muted">{t(`rpt.desc.${r.code}`)}</span>
                        {!ok && <span className="mt-2 block text-xs text-ink-2">{t('rpt.needs', { module: r.needsLabel })}</span>}
                      </span>
                    </>
                  );
                  return ok
                    ? <Link key={r.code} to={`/reports/${r.code}`} data-report={r.code} className="card flex gap-4 p-5 transition hover:border-primary-line">{body}</Link>
                    : <div key={r.code} data-report={r.code} aria-disabled="true" className="card flex gap-4 p-5 opacity-70">{body}</div>;
                })}
              </div>
              {planned > 0 && <p className="mt-2 text-sm text-muted">{t('rpt.morePlanned', { n: planned })} <Link to={`/m/reports?fn=${rep.functions.indexOf(fn!)}`} className="text-primary hover:underline">{t('rpt.seeMenu')}</Link></p>}
            </section>
          );
        })}
      </div>
      <p className="mt-6 text-sm text-muted">{t('rpt.libraryFoot')}</p>
    </RequireModule>
  );
}

// ---------- One report (/reports/:code) ----------
export function ReportPage() {
  const { code } = useParams();
  const def = reportByCode(code);
  const { t } = useTranslation();
  if (!def) return <PageTitle title={t('erp.notFound')} />;
  return <ReportView key={def.code} def={def} />;
}

function ReportView({ def }: { def: ReportDef }) {
  const { t } = useTranslation();
  const mods = useMods();
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const [sp, setSp] = useSearchParams();
  const { open } = useAskAi();
  const companies = profile?.companies ?? [];
  const fallback = top !== 'GRP' ? top : companies[0]?.company_code ?? '';
  const applied = defaultParams(sp, fallback);
  const [form, setForm] = useState<ReportParams>(applied);
  const ok = canRun(def, mods);
  const q = useReport(def, applied, ok && Boolean(applied.company));
  const whs = useOptions('warehouse', 'whs_code', 'name', applied.company || 'GRP');
  const cur = companies.find((c) => c.company_code === applied.company)?.currency ?? '';
  const rep = moduleByKey('reports')!;
  const run = () => setSp(paramString(def, form), { replace: true });
  const set = (k: keyof ReportParams, v: string) => setForm((f) => ({ ...f, [k]: v }));
  const rows = q.data ?? [];

  const title = t(`rpt.name.${def.code}`);
  const head = (
    <PageTitle crumbs={[[t('nav.home'), '/'], [`${rep.num} ${rep.title}`, '/m/reports'], [t('rpt.library'), '/reports'], [title, undefined]]}
      eyebrow={t(`rpt.cat.${def.cat}`)} title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={t(`rpt.desc.${def.code}`)} />
  );
  if (!ok) {
    return (
      <div>
        {head}
        <div className="card mx-auto mt-6 max-w-lg p-8 text-center" role="alert" data-testid="rpt-no-access">
          <Lock className="mx-auto h-10 w-10 text-muted" aria-hidden />
          <h2 className="mt-3 text-2xl font-semibold">{t('access.title')}</h2>
          <p className="mt-2 text-muted">{t('rpt.noAccess', { module: def.needsLabel })}</p>
          <Link to="/" className="mt-5 inline-flex min-h-[44px] items-center rounded-btn border border-line px-4 font-medium hover:bg-page">{t('access.home')}</Link>
        </div>
      </div>
    );
  }

  return (
    <div>
      {head}
      <SectionCard className="mb-5">
        <form className="flex flex-wrap items-end gap-3 p-4" onSubmit={(e) => { e.preventDefault(); run(); }} data-testid="rpt-params">
          <Field label={t('rpt.p.company')}>
            <select id="rpt-company" value={form.company} onChange={(e) => set('company', e.target.value)} className="input min-h-[44px] py-0 text-sm">
              {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.legal_name}</option>)}
            </select>
          </Field>
          {def.params.includes('range') && <>
            <Field label={t('rpt.p.from')}><input id="rpt-from" type="date" value={form.from} onChange={(e) => set('from', e.target.value)} className="input min-h-[44px] text-sm" /></Field>
            <Field label={t('rpt.p.to')}><input id="rpt-to" type="date" value={form.to} onChange={(e) => set('to', e.target.value)} className="input min-h-[44px] text-sm" /></Field>
          </>}
          {def.params.includes('as_of') && <Field label={t('rpt.p.asOf')}><input id="rpt-asof" type="date" value={form.as_of} onChange={(e) => set('as_of', e.target.value)} className="input min-h-[44px] text-sm" /></Field>}
          {def.params.includes('by') && (
            <Field label={t('rpt.p.by')}>
              <select id="rpt-by" value={form.by} onChange={(e) => set('by', e.target.value)} className="input min-h-[44px] py-0 text-sm">
                {['customer', 'item', 'salesperson'].map((b) => <option key={b} value={b}>{t(`rpt.by.${b}`)}</option>)}
              </select>
            </Field>
          )}
          {def.params.includes('kind') && (
            <Field label={t('rpt.p.kind')}>
              <select id="rpt-kind" value={form.kind} onChange={(e) => set('kind', e.target.value)} className="input min-h-[44px] py-0 text-sm">
                <option value="">{t('rpt.allKinds')}</option>
                {OPEN_KINDS.map((k) => <option key={k} value={k}>{t(`erp.doc.${k}`, { defaultValue: k })}</option>)}
              </select>
            </Field>
          )}
          {def.params.includes('whs') && (
            <Field label={t('rpt.p.whs')}>
              <select id="rpt-whs" value={form.whs} onChange={(e) => set('whs', e.target.value)} className="input min-h-[44px] py-0 text-sm">
                <option value="">{t('rpt.allWhs')}</option>
                {(whs.data ?? []).map(([v, l]) => <option key={v} value={v}>{v} · {l}</option>)}
              </select>
            </Field>
          )}
          <div className="ms-auto flex flex-wrap gap-2">
            <Button variant="primary" type="submit" id="rpt-run" icon={<Play className="h-4 w-4" aria-hidden />}>{t('rpt.run')}</Button>
            <Button variant="secondary" id="rpt-csv" disabled={!rows.length} onClick={() => downloadCsv(def, rows, applied.company)} icon={<Download className="h-4 w-4" aria-hidden />}>{t('erp.list.export')}</Button>
            <Link to={`/print/report/${def.code}?${paramString(def, applied)}`} target="_blank" rel="noopener" id="rpt-pdf"
              className={clsx('inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-line bg-surface px-4 text-[15px] font-medium hover:bg-page', !rows.length && 'pointer-events-none opacity-50')}>
              <Printer className="h-4 w-4" aria-hidden /> {t('rpt.pdf')}</Link>
          </div>
        </form>
      </SectionCard>

      {q.isLoading ? <div className="card"><SkeletonRows rows={8} /></div>
        : q.error ? <div className="card" data-testid="rpt-error"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
          : (
            <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_360px]">
              <SectionCard title={<span aria-live="polite" data-testid="rpt-count">{t('rpt.rows', { count: rows.length })}</span>}
                right={<span className="text-sm text-muted">{applied.company}{cur ? ` · ${cur}` : ''}</span>}>
                {rows.length === 0 ? <EmptyState title={t('rpt.empty')} body={t('rpt.emptyBody')} /> : <ReportTable def={def} rows={rows} company={applied.company} />}
              </SectionCard>
              <div className="space-y-5">
                <SectionCard title={t('rpt.chart')}>{rows.length ? <ReportChart def={def} rows={rows} /> : <p className="p-5 text-sm text-muted">{t('rpt.empty')}</p>}</SectionCard>
                <SectionCard title={<span className="inline-flex items-center gap-2"><Sparkles className="h-4 w-4" aria-hidden />{t('rpt.askAboutTitle')}</span>}>
                  <div className="space-y-3 p-5">
                    <p className="text-sm text-muted">{t('rpt.askAboutBody')}</p>
                    <Button variant="secondary" id="rpt-ask-about" className="w-full" onClick={() => open({ company: applied.company, question: t(`rpt.askQ.${def.code}`) })}>{t('rpt.askAi')}</Button>
                  </div>
                </SectionCard>
              </div>
            </div>
          )}
      <p className="mt-3 text-sm text-muted">{t('rpt.foot')}</p>
    </div>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return <label className="flex min-w-[150px] flex-col gap-1 text-xs font-medium text-muted max-sm:w-full">{label}{children}</label>;
}

/** The report table: data rows (data-testid=rpt-row), section subtotals, and a totals row. */
export function ReportTable({ def, rows, company, print = false }: { def: ReportDef; rows: Row[]; company: string; print?: boolean }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const cols = def.columns;
  const data = orderedRows(def, rows);
  const sum = (rs: Row[], k: string) => rs.reduce((s, r) => s + Number(r[k] ?? 0), 0);
  const cell = (c: (typeof cols)[number], r: Row, i: number) => {
    const link = !print && c.link?.(r, company);
    const text = cellText(c, r);
    return (
      <td key={c.key} className={clsx('px-4 py-2', ['money', 'qty', 'int', 'pct'].includes(c.type) && 'num text-end', c.type === 'code' && 'font-mono text-[13px]',
        c.hide && !print && hideCls[c.hide], i === 0 && 'whitespace-nowrap')} data-col={c.key}>
        {link ? <a href={link} onClick={(e) => { e.preventDefault(); nav(link); }} className="font-medium text-primary hover:underline">{text}</a> : <span dir={c.type === 'text' ? 'auto' : undefined}>{text}</span>}
      </td>
    );
  };
  const totalRow = (label: string, rs: Row[], key: string, strong = false) => (
    <tr key={key} className={clsx('border-b border-line bg-surface-2', strong && 'font-semibold')} data-testid={key.startsWith('sub') ? 'rpt-subtotal' : 'rpt-total'}>
      {cols.map((c, i) => (
        <td key={c.key} className={clsx('px-4 py-2', ['money', 'qty', 'int'].includes(c.type) && 'num text-end', c.hide && !print && hideCls[c.hide])}>
          {i === 0 ? label : (c.total || (def.sections && c.key === 'amount')) ? (c.type === 'money' ? money.format(sum(rs, c.key)) : new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(sum(rs, c.key))) : ''}
        </td>
      ))}
    </tr>
  );
  const body: ReactNode[] = [];
  if (def.sections) {
    for (const s of def.sections) {
      const rs = data.filter((r) => r.section === s);
      if (!rs.length) continue;
      body.push(<tr key={`h-${s}`} className="border-b border-line"><th scope="colgroup" colSpan={cols.length} className="px-4 pb-1 pt-3 text-start text-xs font-semibold uppercase tracking-wide text-muted">{sectionLabel(s)}</th></tr>);
      rs.forEach((r, i) => body.push(<tr key={`${s}-${i}`} className="border-b border-line" data-testid="rpt-row">{cols.map((c, j) => cell(c, r, j))}</tr>));
      body.push(totalRow(t('rpt.totalOf', { name: sectionLabel(s) }), rs, `sub-${s}`));
    }
    const net = rows.find((r) => r.section === 'net_profit');
    if (net) body.push(totalRow(t('rpt.netProfit'), [net], 'total-net', true));
    if (def.code === 'balance-sheet') body.push(totalRow(t('rpt.liabEquity'), data.filter((r) => r.section !== 'assets'), 'total-le', true));
  } else {
    data.forEach((r, i) => body.push(<tr key={i} className="border-b border-line" data-testid="rpt-row">{cols.map((c, j) => cell(c, r, j))}</tr>));
    if (cols.some((c) => c.total)) body.push(totalRow(t('rpt.total'), data, 'total', true));
  }
  return (
    <div className={clsx(!print && 'overflow-x-auto')}>
      <table className={clsx('w-full border-collapse', print ? 'text-[11.5px]' : 'text-[14px]')} data-testid="rpt-table">
        <thead>
          <tr className="border-y border-line bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
            {cols.map((c) => <th key={c.key} scope="col" className={clsx('px-4 py-2.5 text-start font-semibold', ['money', 'qty', 'int', 'pct'].includes(c.type) && 'text-end', c.hide && !print && hideCls[c.hide])}>{colLabel(c.key)}</th>)}
          </tr>
        </thead>
        <tbody>{body}</tbody>
      </table>
    </div>
  );
}

/** Bar chart in design tokens (no chart library): the largest rows, or the section totals. */
export function ReportChart({ def, rows }: { def: ReportDef; rows: Row[] }) {
  const { t } = useTranslation();
  const items = useMemo(() => {
    if (def.chart.sections) {
      const secs = [...(def.sections ?? [])];
      const out = secs.map((s) => ({ label: sectionLabel(s), value: rows.filter((r) => r.section === s).reduce((a, r) => a + Number(r[def.chart.value] ?? 0), 0) }));
      const net = rows.find((r) => r.section === 'net_profit');
      if (net) out.push({ label: t('rpt.netProfit'), value: Number(net.amount ?? 0) });
      return out;
    }
    // group by the label column (e.g. warehouse, item group, document kind), largest first
    const m = new Map<string, number>();
    for (const r of rows) {
      const k = def.chart.label === 'doc_kind' ? t(`erp.doc.${String(r.doc_kind)}`, { defaultValue: String(r.doc_kind) }) : String(r[def.chart.label] ?? r.key ?? '—');
      m.set(k, (m.get(k) ?? 0) + Number(r[def.chart.value] ?? 0));
    }
    return [...m.entries()].map(([label, value]) => ({ label, value })).sort((a, b) => Math.abs(b.value) - Math.abs(a.value)).slice(0, def.chart.top ?? 8);
  }, [def, rows, t]);
  const max = Math.max(1, ...items.map((i) => Math.abs(i.value)));
  return (
    <figure className="p-5" data-testid="rpt-chart">
      <figcaption className="mb-3 text-xs text-muted">{t('rpt.chartOf', { value: colLabel(def.chart.value) })}</figcaption>
      <ul className="space-y-2.5">
        {items.map((i) => (
          <li key={i.label}>
            <div className="mb-1 flex items-baseline justify-between gap-2 text-[13px]"><span dir="auto" className="min-w-0 truncate">{i.label}</span><span className="num shrink-0 text-ink-2">{money.format(i.value)}</span></div>
            <div className="h-2.5 rounded-full bg-surface-2" aria-hidden>
              <div className={clsx('h-2.5 rounded-full', i.value < 0 ? 'bg-crit-fg' : 'bg-primary')} style={{ width: `${Math.max(2, (Math.abs(i.value) / max) * 100)}%` }} />
            </div>
          </li>
        ))}
      </ul>
    </figure>
  );
}

// ---------- Print / PDF (/print/report/:code) ----------
export function ReportPrintPage() {
  const { code } = useParams();
  const def = reportByCode(code);
  const { t } = useTranslation();
  const [sp] = useSearchParams();
  const { profile } = useAuth();
  const mods = profile?.modules ?? [];
  const p = defaultParams(sp, sp.get('company') ?? '');
  const ok = Boolean(def) && canRun(def!, mods);
  const q = useReport(def, p, ok && Boolean(p.company));
  const co = profile?.companies.find((c) => c.company_code === p.company);
  useEffect(() => { if (def) document.title = `${t(`rpt.name.${def.code}`)} · ${p.company}`; }, [def, p.company, t]);
  let body: ReactNode;
  if (!def) body = <EmptyState title={t('erp.notFound')} />;
  else if (!ok) body = <EmptyState title={t('access.title')} body={t('rpt.noAccess', { module: def.needsLabel })} />;
  else if (q.isLoading) body = <PageLoading />;
  else if (q.error) body = <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  if (body) return <main className="mx-auto max-w-3xl p-6">{body}</main>;
  const period = def!.params.includes('range') ? `${p.from} – ${p.to}` : def!.params.includes('as_of') ? t('rpt.atDate', { d: p.as_of }) : t('rpt.now');
  return (
    <div className="min-h-screen bg-page">
      <div className="no-print sticky top-0 z-10 flex flex-wrap items-center justify-between gap-3 border-b border-line bg-surface px-4 py-3">
        <Link to={`/reports/${def!.code}?${paramString(def!, p)}`} className="inline-flex min-h-[44px] items-center gap-1 text-sm font-medium text-primary hover:underline"><ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {t('rpt.backToReport')}</Link>
        <Button variant="primary" id="print-now" onClick={() => window.print()} icon={<Printer className="h-4 w-4" aria-hidden />}>{t('rpt.printNow')}</Button>
      </div>
      <article className="paper mx-auto my-6 w-[210mm] max-w-full border border-line bg-surface p-[12mm] text-ink shadow-card max-sm:p-4" data-testid="print-sheet">
        <header className="mb-4 border-b-2 border-ink pb-3">
          <p dir="auto" className="text-[18px] font-semibold">{co?.legal_name ?? p.company}</p>
          <p className="text-[15px] font-semibold">{t(`rpt.name.${def!.code}`)}</p>
          <p className="text-[12px] text-ink-2">{period} · {co?.currency ?? ''} · {t('rpt.printedBy', { name: profile?.user?.display_name ?? '', at: new Date().toLocaleString(i18n_locale()) })}</p>
        </header>
        <ReportTable def={def!} rows={q.data ?? []} company={p.company} print />
        <p className="mt-4 text-[11px] text-muted">{t('rpt.printFoot')}</p>
      </article>
    </div>
  );
}
const i18n_locale = () => (document.documentElement.lang === 'ar' ? 'ar-AE' : 'en-GB');
