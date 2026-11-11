import { useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertCircle, CircleCheck, Lock, LockOpen, Plus } from 'lucide-react';
import { useAuth } from '@/auth/AuthProvider';
import { useCompany } from '@/layout/CompanyContext';
import { erp } from '@/lib/supabase';
import { ApiError, errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { LiveBadge, PageTitle, SectionCard, fmtDay } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { Dialog } from '../components/Dialog';
import { moduleByKey } from '../modules';
import { periodAddYear, periodSetStatus, type PeriodStatus } from '../journal';

/** The company a setup screen works on: the top-bar company, or the user's home company when "all companies" is selected. */
function useSetupCompany() {
  const { profile } = useAuth();
  const { company: top } = useCompany();
  const companies = profile?.companies ?? [];
  const [picked, setPicked] = useState<string | null>(null);
  const company = picked ?? (top !== 'GRP' ? top : profile?.user?.company_code ?? companies[0]?.company_code ?? '');
  return { company, setCompany: setPicked, companies };
}

function SetupFrame({ title, desc, children, company, setCompany, companies }: {
  title: string; desc: string; children: ReactNode; company: string; setCompany: (c: string) => void; companies: Array<{ company_code: string; short_name: string }>;
}) {
  const { t } = useTranslation();
  const m = moduleByKey('financials')!;
  return (
    <RequireModule module="financials">
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/financials'], [t('fs.setup'), undefined], [title, undefined]]}
        eyebrow={t('fs.setup')} title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc}
        actions={companies.length > 1 ? (
          <label className="flex flex-col gap-1 text-xs font-medium text-muted">{t('je.company')}
            <select id="fs-company" className="input min-h-[40px] py-0 text-sm text-ink" value={company} onChange={(e) => setCompany(e.target.value)}>
              {companies.map((c) => <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.short_name}</option>)}
            </select>
          </label>
        ) : undefined} />
      {children}
    </RequireModule>
  );
}

function Flash({ text }: { text: string | null }) {
  if (!text) return null;
  return <p role="status" className="mb-4 flex items-center gap-2 rounded-btn border border-ok-fg/30 bg-ok-bg px-4 py-3 text-sm font-medium text-ok-fg"><CircleCheck className="h-4 w-4" aria-hidden /><span data-testid="fs-flash">{text}</span></p>;
}
function ErrorBox({ text }: { text: string | null }) {
  if (!text) return null;
  return <div role="alert" className="mb-4 flex items-start gap-2 rounded-card border border-crit-fg/30 bg-crit-bg p-4 font-semibold text-crit-fg"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span dir="auto" data-testid="fs-error">{text}</span></div>;
}

// B3 · G/L Account Determination moved to SetupPages.tsx (tabs, item group and warehouse accounts).

// ---------- Posting Periods ----------
interface Period { period_code: string; from_date: string; to_date: string; status: PeriodStatus; updated_at: string }
const TONE: Record<PeriodStatus, string> = { open: 'pill-ok', closed: 'pill-neutral', locked: 'pill-crit' };

export function PostingPeriodsPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const sc = useSetupCompany();
  const { company } = sc;
  const { canWrite, readOnlyReason } = useModuleLevel('financials');
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [year, setYear] = useState<string>('');
  const [yearInput, setNewYear] = useState<string | null>(null);
  const [lockFor, setLockFor] = useState<Period | null>(null);
  const q = useQuery({
    queryKey: ['periods', company], enabled: Boolean(company),
    queryFn: async () => {
      const { data, error } = await erp().from('posting_period').select('period_code,from_date,to_date,status,updated_at').eq('company_code', company).order('from_date');
      if (error) throw new ApiError(error);
      return (data ?? []) as Period[];
    },
  });
  const years = [...new Set((q.data ?? []).map((p) => p.from_date.slice(0, 4)))];
  const thisYear = String(new Date().getFullYear());
  const shown = year || (years.includes(thisYear) ? thisYear : years[years.length - 1] ?? '');
  const rows = (q.data ?? []).filter((p) => p.from_date.startsWith(shown));
  // Suggest the year after the last one in the calendar.
  const newYear = yearInput ?? String(Number(years[years.length - 1] ?? Number(thisYear) - 1) + 1);

  async function setStatus(p: Period, s: PeriodStatus) {
    setErr(null); setFlash(null); setBusy(true);
    try {
      await periodSetStatus(company, p.period_code, s);
      setLockFor(null);
      setFlash(t(`fs.per.flash.${s}`, { p: p.period_code }));
      await qc.invalidateQueries({ queryKey: ['periods', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }
  async function addYear() {
    setErr(null); setFlash(null); setBusy(true);
    try {
      await periodAddYear(company, Number(newYear));
      setFlash(t('fs.per.flash.added', { y: newYear }));
      setYear(newYear);
      await qc.invalidateQueries({ queryKey: ['periods', company] });
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  }

  return (
    <SetupFrame title={t('fs.per.title')} desc={t('fs.per.desc')} {...sc}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      {!canWrite && readOnlyReason && <p className="mb-4 text-sm text-muted">{readOnlyReason}. {t('fs.readOnlyBody')}</p>}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_320px]">
        <SectionCard title={t('fs.per.periods')} right={years.length > 1 ? (
          <label className="flex items-center gap-2 text-xs font-medium text-muted">{t('fs.per.year')}
            <select id="per-year" className="input min-h-[40px] w-auto py-0 text-sm text-ink" value={shown} onChange={(e) => setYear(e.target.value)}>
              {years.map((y) => <option key={y} value={y}>{y}</option>)}
            </select>
          </label>
        ) : undefined}>
          {q.isLoading ? <SkeletonRows rows={6} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : rows.length === 0 ? (
            <EmptyState title={t('fs.per.empty')} body={t('fs.per.emptyBody')} />
          ) : (
            <div className="relative overflow-x-auto">
              <table className="w-full text-[14px]" data-testid="per-table">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-4 py-2.5 text-start">{t('fs.per.period')}</th>
                  <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('fs.per.from')}</th>
                  <th scope="col" className="px-4 py-2.5 text-start max-sm:hidden">{t('fs.per.to')}</th>
                  <th scope="col" className="px-4 py-2.5 text-start">{t('erp.col.status')}</th>
                  {canWrite && <th scope="col" className="px-4 py-2.5 text-end">{t('fs.per.actions')}</th>}
                </tr></thead>
                <tbody>
                  {rows.map((p) => (
                    <tr key={p.period_code} className="border-t border-line" data-testid="per-row" data-period={p.period_code}>
                      <td className="px-4 py-2 font-mono text-[13px]">{p.period_code}</td>
                      <td className="num px-4 py-2 max-sm:hidden">{fmtDay(p.from_date)}</td>
                      <td className="num px-4 py-2 max-sm:hidden">{fmtDay(p.to_date)}</td>
                      <td className="px-4 py-2"><span className={clsx('pill', TONE[p.status])}>{t(`fs.per.status.${p.status}`)}</span></td>
                      {canWrite && (
                        <td className="px-4 py-2">
                          <div className="flex flex-wrap justify-end gap-1">
                            {p.status !== 'open' && <Button variant="ghost" className="min-h-[40px] px-3 text-sm" disabled={busy} id={`per-open-${p.period_code}`} onClick={() => setStatus(p, 'open')} icon={<LockOpen className="h-4 w-4" aria-hidden />}>{t('fs.per.open')}</Button>}
                            {p.status !== 'closed' && <Button variant="ghost" className="min-h-[40px] px-3 text-sm" disabled={busy} id={`per-close-${p.period_code}`} onClick={() => setStatus(p, 'closed')}>{t('fs.per.close')}</Button>}
                            {p.status !== 'locked' && <Button variant="ghost" className="min-h-[40px] px-3 text-sm" disabled={busy} id={`per-lock-${p.period_code}`} onClick={() => setLockFor(p)} icon={<Lock className="h-4 w-4" aria-hidden />}>{t('fs.per.lock')}</Button>}
                          </div>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </SectionCard>
        <aside className="space-y-5">
          <SectionCard title={t('fs.per.meaning')}>
            <dl className="space-y-3 p-5 text-sm">
              {(['open', 'closed', 'locked'] as const).map((s) => (
                <div key={s}><dt><span className={clsx('pill', TONE[s])}>{t(`fs.per.status.${s}`)}</span></dt><dd className="mt-1 text-ink-2">{t(`fs.per.means.${s}`)}</dd></div>
              ))}
            </dl>
          </SectionCard>
          {canWrite && (
            <SectionCard title={t('fs.per.addYear')}>
              <div className="space-y-3 p-5">
                <label className="block text-xs font-medium text-muted">{t('fs.per.year')}
                  <input id="per-new-year" inputMode="numeric" className="input num mt-1 text-[15px] text-ink" value={newYear} onChange={(e) => setNewYear(e.target.value)} />
                </label>
                <p className="text-sm text-muted">{t('fs.per.addYearBody')}</p>
                <Button variant="secondary" id="per-add-year" className="w-full" disabled={busy || !newYear.trim()} onClick={addYear} icon={<Plus className="h-4 w-4" aria-hidden />}>{t('fs.per.addYearBtn')}</Button>
              </div>
            </SectionCard>
          )}
        </aside>
      </div>
      <Dialog open={Boolean(lockFor)} title={t('fs.per.lockTitle', { p: lockFor?.period_code ?? '' })} onClose={() => setLockFor(null)}
        footer={<><Button variant="secondary" onClick={() => setLockFor(null)}>{t('je.keep')}</Button><Button variant="danger" id="per-lock-confirm" disabled={busy} onClick={() => lockFor && setStatus(lockFor, 'locked')}>{t('fs.per.lock')}</Button></>}>
        <p className="text-sm text-ink-2">{t('fs.per.lockBody')}</p>
      </Dialog>
    </SetupFrame>
  );
}
