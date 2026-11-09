import { useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { ArrowRight, Search } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { erp } from '@/lib/supabase';
import { ApiError, fmtInt } from '@/lib/format';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { rpc } from '../api';
import { Kpi, LiveBadge, PageTitle, SectionCard, StatusTag, fmtMoney } from '../components/ui';
import { RequireModule, useModuleAccess } from '../components/Guard';
import { ModuleIcon } from '../icons';
import {
  DOC_KINDS, MODULES, PREVIEW_SCREENS, canOpenModule, docKindByObj, liveRouteForFunction, liveRouteForItem, moduleByKey,
  type MenuFunction, type MenuItem, type ModuleDef,
} from '../modules';

type R = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const pc = (company: string) => (company === 'GRP' ? null : company);

// ---------- Home ----------
interface Kpis { open_sales_orders: { n: number; value: number }; open_quotations: { n: number; value: number }; open_purchase_orders: { n: number; value: number };
  overdue_ar: { n: number; value: number }; due_ap: { n: number; value: number }; low_stock: { n: number }; customers: number; items: number }

export function HomePage() {
  const { t } = useTranslation();
  const { profile } = useAuth();
  const { company } = useCompany();
  const can = useModuleAccess();
  const mods = profile?.modules ?? [];
  const visible = MODULES.filter((m) => canOpenModule(m, mods));
  const cur = profile?.companies.find((c) => c.company_code === company)?.currency ?? 'AED';
  const k = useQuery({ queryKey: ['home-kpis', company], queryFn: () => rpc<Kpis>('home_kpis', { p_company: pc(company) }) });
  const first = profile?.user?.display_name?.split(/\s+/)[0];

  return (
    <div>
      <PageTitle eyebrow={t('erp.home.eyebrow')} title={first ? t('erp.home.hello', { name: first }) : t('nav.dashboard')} desc={t('erp.home.desc')} />
      {k.error ? <div className="card mb-6"><ErrorState error={k.error} onRetry={() => k.refetch()} /></div> : (
        <div className="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {can('sales') && <Kpi label={t('erp.home.openSO')} value={k.data ? fmtInt(k.data.open_sales_orders.n) : '…'} sub={k.data && fmtMoney(k.data.open_sales_orders.value, cur)} to="/docs/sales_order?f_status=open" />}
          {can('purchasing') && <Kpi label={t('erp.home.openPO')} value={k.data ? fmtInt(k.data.open_purchase_orders.n) : '…'} sub={k.data && fmtMoney(k.data.open_purchase_orders.value, cur)} to="/docs/purchase_order?f_status=open" />}
          {can('sales') && <Kpi label={t('erp.home.overdueAR')} value={k.data ? fmtInt(k.data.overdue_ar.n) : '…'} sub={k.data && fmtMoney(k.data.overdue_ar.value, cur)} tone={k.data?.overdue_ar.n ? 'crit' : undefined} to="/docs/ar_invoice?f_status=open" />}
          {can('inventory') && <Kpi label={t('erp.home.lowStock')} value={k.data ? fmtInt(k.data.low_stock.n) : '…'} sub={t('erp.home.lowStockSub')} tone={k.data?.low_stock.n ? 'warn' : undefined} to="/control" />}
          {can('purchasing') && <Kpi label={t('erp.home.dueAP')} value={k.data ? fmtInt(k.data.due_ap.n) : '…'} sub={k.data && fmtMoney(k.data.due_ap.value, cur)} to="/docs/ap_invoice?f_status=open" />}
          {can('sales') && <Kpi label={t('erp.home.openQT')} value={k.data ? fmtInt(k.data.open_quotations.n) : '…'} sub={k.data && fmtMoney(k.data.open_quotations.value, cur)} to="/docs/sales_quotation?f_status=open" />}
          {can('bp') && <Kpi label={t('erp.home.customers')} value={k.data ? fmtInt(k.data.customers) : '…'} sub={t('erp.home.active')} to="/bp?f_kind=customer" />}
          {can('inventory') && <Kpi label={t('erp.home.items')} value={k.data ? fmtInt(k.data.items) : '…'} sub={t('erp.home.active')} to="/items" />}
        </div>
      )}

      <h2 className="eyebrow mb-3">{t('nav.modules')}</h2>
      {visible.length === 0 ? <div className="card"><EmptyState title={t('erp.home.noModules')} body={t('erp.home.noModulesBody')} /></div> : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {visible.map((m) => {
            const live = m.functions.filter((f) => liveRouteForFunction(m.key, f.name) || f.items.some((i) => liveRouteForItem(i.name))).length;
            return (
              <Link key={m.key} to={`/m/${m.key}`} className="card group flex gap-4 p-5 transition hover:border-primary-line">
                <span className="grid h-10 w-10 shrink-0 place-items-center rounded-btn bg-primary-soft text-primary"><ModuleIcon name={m.key} /></span>
                <span className="min-w-0">
                  <span className="flex items-baseline gap-2"><span className="num text-xs font-semibold text-muted">{m.num}</span><span className="font-semibold">{m.title}</span></span>
                  <span dir="auto" className="mt-1 line-clamp-2 block text-sm text-muted">{m.desc}</span>
                  <span className="mt-2 block text-xs text-ink-2">{t('erp.home.fnCount', { n: m.functions.length, live })}</span>
                </span>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ---------- Module (SAP menu) ----------
function itemTarget(m: ModuleDef, it: MenuItem): { kind: 'live' | 'preview' | 'planned'; to?: string } {
  const live = liveRouteForItem(it.name) ?? (it.preview === 'migration' ? '/backoffice/migration' : it.preview === 'doc' ? '/docs/sales_order' : undefined);
  if (live) return { kind: 'live', to: live };
  if (it.preview && PREVIEW_SCREENS[it.preview]) return { kind: 'preview', to: `/preview/${it.preview}?from=${m.key}` };
  return { kind: 'planned' };
}

function FlagTag({ f }: { f: MenuFunction }) {
  const { t } = useTranslation();
  if (!f.flag) return null;
  const cls = f.flag === 'off' ? 'pill-neutral' : f.flag === 'custom' ? 'pill-warning' : 'pill-info';
  return <span className={clsx('pill', cls)}>{t(`erp.flag.${f.flag}`)}</span>;
}

export function ModulePage({ moduleKey }: { moduleKey: string }) {
  const { t } = useTranslation();
  const m = moduleByKey(moduleKey);
  const [sp, setSp] = useSearchParams();
  const [q, setQ] = useState('');
  const sel = Math.max(0, Number(sp.get('fn') ?? 0) || 0);
  const ql = q.trim().toLowerCase();
  const list = useMemo(() => (m?.functions ?? []).map((f, i) => ({ f, i })).filter(({ f }) => !ql
    || f.name.toLowerCase().includes(ql) || f.desc.toLowerCase().includes(ql) || f.items.some((it) => it.name.toLowerCase().includes(ql))), [m, ql]);
  if (!m) return <PageTitle title={t('erp.notFound')} />;
  const fn = m.functions[sel] ?? m.functions[0];
  const fnLive = liveRouteForFunction(m.key, fn.name);

  return (
    <RequireModule module={m.key}>
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, undefined]]} eyebrow={`${t('erp.module')} ${m.num}`} title={m.title} desc={m.desc} />
      <div className="grid gap-5 lg:grid-cols-[minmax(280px,360px)_1fr]">
        <SectionCard title={t('erp.mod.functions', { n: m.functions.length })}>
          <div className="border-b border-line p-3">
            <label className="relative block">
              <span className="sr-only">{t('erp.mod.searchFn')}</span>
              <Search className="pointer-events-none absolute start-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" aria-hidden />
              <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('erp.mod.searchFn')} className="input min-h-[40px] ps-9 text-sm" />
            </label>
          </div>
          {list.length === 0 ? <EmptyState title={t('erp.list.noMatch')} /> : (
            <ul className="max-h-[70vh] overflow-y-auto py-1" role="listbox" aria-label={t('erp.mod.functions', { n: m.functions.length })}>
              {list.map(({ f, i }) => {
                const on = (m.functions[sel] ? sel : 0) === i;
                const live = liveRouteForFunction(m.key, f.name) || f.items.some((it) => liveRouteForItem(it.name));
                return (
                  <li key={f.name} role="option" aria-selected={on}>
                    <button type="button" onClick={() => setSp({ fn: String(i) }, { replace: true })}
                      className={clsx('flex min-h-[44px] w-full items-center gap-3 px-4 py-2 text-start text-[14px]', on ? 'bg-side-active text-side-active-text' : 'hover:bg-surface-2', f.flag === 'off' && !on && 'text-muted')}>
                      <span className="num w-6 shrink-0 text-xs text-muted">{f.no}</span>
                      <span className="min-w-0 flex-1 truncate font-medium">{f.name}{f.submenu ? ' ›' : ''}</span>
                      {live && <span className="h-2 w-2 shrink-0 rounded-full bg-ok-fg" title={t('erp.liveData')} aria-label={t('erp.liveData')} />}
                      <FlagTag f={f} />
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </SectionCard>

        <div className="space-y-5">
          <SectionCard>
            <div className="p-5">
              <div className="flex flex-wrap items-center gap-2">
                <span className="num text-sm text-muted">{m.num}.{String(fn.no).padStart(2, '0')}</span>
                <h2 className="text-xl font-semibold">{fn.name}</h2>
                <FlagTag f={fn} />
                {fnLive ? <LiveBadge live /> : null}
              </div>
              <p dir="auto" className="mt-2 text-[15px] text-ink-2">{fn.desc}</p>
              {fn.note && <p dir="auto" className="mt-3 rounded-btn border border-primary-line bg-primary-soft px-3 py-2 text-sm text-primary-text"><b>{t('erp.mod.note')}</b> {fn.note}</p>}
              {fnLive && <Link to={fnLive} className="mt-4 inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 font-medium text-white hover:bg-primary-hover">{t('erp.open', { name: fn.name })} <ArrowRight className="h-4 w-4 rtl:rotate-180" aria-hidden /></Link>}
              {!fnLive && fn.items.length === 0 && <p className="mt-4 text-sm text-muted">{t('erp.mod.planned')}</p>}
            </div>
          </SectionCard>
          {fn.items.length > 0 && (
            <SectionCard title={fn.submenu ? t('erp.mod.submenu', { n: fn.items.length }) : t('erp.mod.whatItDoes')}>
              <ul className="divide-y divide-line">
                {fn.items.map((it) => {
                  const target = itemTarget(m, it);
                  const body = (
                    <>
                      <span className="min-w-0 flex-1">
                        <span dir="auto" className="block font-medium">{it.name}</span>
                        <span dir="auto" className="block text-sm text-muted">{it.desc}</span>
                      </span>
                      {target.kind === 'live' && <LiveBadge live />}
                      {target.kind === 'preview' && <LiveBadge live={false} />}
                      {target.kind === 'planned' && <span className="pill pill-neutral">{t('erp.planned')}</span>}
                    </>
                  );
                  return (
                    <li key={it.name}>
                      {target.to
                        ? <Link to={target.to} className="flex min-h-[52px] items-center gap-3 px-5 py-3 hover:bg-surface-2">{body}<ArrowRight className="h-4 w-4 shrink-0 text-muted rtl:rotate-180" aria-hidden /></Link>
                        : <div className="flex min-h-[52px] items-center gap-3 px-5 py-3">{body}</div>}
                    </li>
                  );
                })}
              </ul>
            </SectionCard>
          )}
        </div>
      </div>
    </RequireModule>
  );
}

// ---------- Control Tower (rule-based checks on live data) ----------
const CHECKS = ['credit_limit', 'below_cost', 'overdue_60', 'high_discount', 'low_stock'] as const;
function checkLink(r: R) {
  if (r.check_code === 'credit_limit') return `/bp/${r.company_code}/${encodeURIComponent(r.ref)}`;
  if (r.check_code === 'low_stock') return `/items/${r.company_code}/${encodeURIComponent(String(r.ref).split(' @ ')[0])}`;
  const [kind, entry] = String(r.ref).split(':');
  return DOC_KINDS[kind as keyof typeof DOC_KINDS] ? `/docs/${kind}/${r.company_code}/${entry}` : undefined;
}

export function ControlTowerPage() {
  const { t } = useTranslation();
  const { company } = useCompany();
  const [sev, setSev] = useState<'all' | 'critical' | 'warning'>('all');
  const [check, setCheck] = useState<string>('');
  const q = useQuery({ queryKey: ['control', company], queryFn: () => rpc<R[]>('control_checks', { p_company: pc(company) }), refetchInterval: 60_000 });
  const rows = (q.data ?? []).filter((r) => (sev === 'all' || r.severity === sev) && (!check || r.check_code === check));
  const counts = Object.fromEntries(CHECKS.map((c) => [c, (q.data ?? []).filter((r) => r.check_code === c).length]));
  return (
    <div>
      <PageTitle eyebrow={t('nav.oversight')} title={<span className="inline-flex items-center gap-3">{t('erp.control.title')} <LiveBadge live /></span>} desc={t('erp.control.desc')} />
      <div className="mb-5 grid grid-cols-2 gap-3 md:grid-cols-5">
        {CHECKS.map((c) => (
          <button key={c} type="button" onClick={() => setCheck(check === c ? '' : c)} aria-pressed={check === c}
            className={clsx('card p-4 text-start transition', check === c ? 'border-primary ring-1 ring-primary' : 'hover:border-primary-line')}>
            <div className="text-sm text-muted">{t(`erp.control.check.${c}`)}</div>
            <div className={clsx('num mt-1 text-2xl font-semibold', counts[c] ? (c === 'low_stock' || c === 'high_discount' ? 'text-warn-fg' : 'text-crit-fg') : '')}>{q.data ? counts[c] : '…'}</div>
          </button>
        ))}
      </div>
      <SectionCard title={t('erp.control.findings', { n: rows.length })} right={
        <div className="flex gap-1" role="group" aria-label={t('erp.control.severity')}>
          {(['all', 'critical', 'warning'] as const).map((s) => (
            <button key={s} type="button" aria-pressed={sev === s} onClick={() => setSev(s)}
              className={clsx('min-h-[36px] rounded-full px-3 text-sm font-semibold', sev === s ? 'bg-ink text-surface' : 'border border-line-strong hover:bg-surface-2')}>{t(`erp.control.sev.${s}`)}</button>
          ))}
        </div>
      }>
        {q.isLoading ? <SkeletonRows rows={5} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : rows.length === 0 ? (
          <EmptyState title={t('erp.control.none')} body={t('erp.control.noneBody')} />
        ) : (
          <ul className="divide-y divide-line">
            {rows.map((r, i) => {
              const to = checkLink(r);
              const inner = (
                <>
                  <StatusTag value={r.severity} />
                  <span className="min-w-0 flex-1">
                    <span className="block font-medium">{t(`erp.control.check.${r.check_code}`)} · {r.title}</span>
                    <span className="block text-sm text-muted">{r.company_code} · {r.detail}</span>
                  </span>
                  {r.amount !== null && <span className="num whitespace-nowrap text-sm text-ink-2">{r.check_code === 'low_stock' ? t('erp.control.short', { n: fmtInt(r.amount) }) : fmtMoney(r.amount)}</span>}
                </>
              );
              return <li key={i}>{to ? <Link to={to} className="flex items-center gap-3 px-5 py-3 hover:bg-surface-2">{inner}</Link> : <div className="flex items-center gap-3 px-5 py-3">{inner}</div>}</li>;
            })}
          </ul>
        )}
      </SectionCard>
      <p className="mt-3 text-sm text-muted">{t('erp.control.foot')}</p>
    </div>
  );
}

// ---------- Global search ----------
export function SearchPage() {
  const { t } = useTranslation();
  const [sp] = useSearchParams();
  const { company } = useCompany();
  const can = useModuleAccess();
  const term = (sp.get('q') ?? '').replace(/[,()*%\\:"]/g, ' ').trim();
  const q = useQuery({
    queryKey: ['search', term, company],
    enabled: term.length >= 2,
    queryFn: async () => {
      const scope = <T,>(qb: T) => (company === 'GRP' ? qb : (qb as unknown as { eq: (a: string, b: string) => T }).eq('company_code', company));
      const like = `*${term}*`;
      const tasks = [
        can('bp') ? scope(erp().from('business_partner').select('company_code,card_code,name,kind').or(`card_code.ilike.${like},name.ilike.${like},phone.ilike.${like}`)).limit(8) : null,
        can('inventory') ? scope(erp().from('item').select('company_code,item_code,name,barcode').or(`item_code.ilike.${like},name.ilike.${like},barcode.ilike.${like}`)).limit(8) : null,
        scope(erp().from('document').select('company_code,obj_type,doc_entry,doc_num,doc_kind,card_name,doc_date,status,total,currency')
          .or([`card_name.ilike.${like}`, `customer_ref.ilike.${like}`, ...(/^\d{1,9}$/.test(term) ? [`doc_num.eq.${term}`] : [])].join(','))).order('doc_date', { ascending: false }).limit(12),
      ];
      const res = await Promise.all(tasks.map((x) => x ?? Promise.resolve({ data: [], error: null })));
      for (const r of res) if (r.error) throw new ApiError(r.error);
      const docs = ((res[2].data ?? []) as R[]).filter((d) => { const k = docKindByObj(d.obj_type); return k && can(DOC_KINDS[k].module as never); });
      return { bps: (res[0].data ?? []) as R[], items: (res[1].data ?? []) as R[], docs };
    },
  });
  const total = q.data ? q.data.bps.length + q.data.items.length + q.data.docs.length : 0;
  return (
    <div>
      <PageTitle title={term ? t('erp.searchPage.title', { q: term }) : t('erp.searchPage.empty')} desc={t('erp.searchPage.desc')} />
      {term.length < 2 ? <div className="card"><EmptyState title={t('erp.searchPage.hint')} /></div>
        : q.isLoading ? <div className="card"><SkeletonRows rows={6} /></div>
        : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div>
        : total === 0 ? <div className="card"><EmptyState title={t('erp.list.noMatch')} body={t('erp.searchPage.none')} /></div> : (
          <div className="grid gap-5 lg:grid-cols-2">
            {q.data!.bps.length > 0 && (
              <SectionCard title={t('erp.page.bp')}>
                <ul className="divide-y divide-line">{q.data!.bps.map((b) => (
                  <li key={b.company_code + b.card_code}><Link to={`/bp/${b.company_code}/${encodeURIComponent(b.card_code)}`} className="flex items-center gap-3 px-5 py-3 hover:bg-surface-2">
                    <span className="font-mono text-[13px] text-muted">{b.card_code}</span><span className="flex-1 font-medium">{b.name}</span><span className="text-sm text-muted">{t(`erp.kind.${b.kind}`, { defaultValue: b.kind })}</span></Link></li>))}</ul>
              </SectionCard>
            )}
            {q.data!.items.length > 0 && (
              <SectionCard title={t('erp.page.items')}>
                <ul className="divide-y divide-line">{q.data!.items.map((i) => (
                  <li key={i.company_code + i.item_code}><Link to={`/items/${i.company_code}/${encodeURIComponent(i.item_code)}`} className="flex items-center gap-3 px-5 py-3 hover:bg-surface-2">
                    <span className="font-mono text-[13px] text-muted">{i.item_code}</span><span className="flex-1 font-medium">{i.name}</span></Link></li>))}</ul>
              </SectionCard>
            )}
            {q.data!.docs.length > 0 && (
              <SectionCard title={t('erp.searchPage.docs')} className="lg:col-span-2">
                <ul className="divide-y divide-line">{q.data!.docs.map((d) => {
                  const k = docKindByObj(d.obj_type)!;
                  return (
                    <li key={`${d.company_code}-${d.obj_type}-${d.doc_entry}`}><Link to={`/docs/${k}/${d.company_code}/${d.doc_entry}`} className="flex flex-wrap items-center gap-3 px-5 py-3 hover:bg-surface-2">
                      <span className="w-40 text-sm text-muted">{t(`erp.doc.${k}`, { defaultValue: DOC_KINDS[k].title })}</span>
                      <span className="font-mono text-[13px]">{d.doc_num}</span><span className="flex-1 font-medium">{d.card_name ?? '—'}</span>
                      <StatusTag value={d.status} /><span className="num text-sm">{fmtMoney(d.total, d.currency)}</span></Link></li>
                  );
                })}</ul>
              </SectionCard>
            )}
          </div>
        )}
    </div>
  );
}
