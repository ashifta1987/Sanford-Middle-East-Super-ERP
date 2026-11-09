import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, CircleCheck, CircleX, FileText, LogIn, LogOut, MapPin, Printer } from 'lucide-react';
import { errorMessage } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { Crumbs, Fields, LiveBadge, PageTitle, SectionCard, fmtDay, fmtMoney, fmtQty } from '../components/ui';
import { RequireModule, useModuleLevel } from '../components/Guard';
import { ListScreen, type ListConfig } from '../components/ListScreen';
import { moduleByKey } from '../modules';
import type { Row } from '../api';
import { Flash, FormError, fmtWhen, useDefaultCompany, useFlash } from './BankingPages';
import {
  attendanceCheck, currentPosition, leaveCancel, leaveChecks, leaveDecide, leaveSubmit, openHrFile, useLeaveInfo, usePayslip, usePortal,
  type Balance, type LeaveEval, type LeaveState, type PortalMe,
} from '../hr';

type R = Row & Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
export const hrLabel = 'block text-xs font-medium text-muted';
export const hrInput = 'input mt-1 text-[15px] text-ink';
export const linkBtn = 'inline-flex min-h-[44px] items-center gap-2 rounded-btn px-4 text-[15px] font-medium';
export const primaryLink = `${linkBtn} bg-primary text-white hover:bg-primary-hover`;
export const secondaryLink = `${linkBtn} border border-line bg-surface text-ink hover:bg-page`;

const LEAVE_TONE: Record<LeaveState, string> = { pending_approval: 'pill-warning', approved: 'pill-ok', rejected: 'pill-crit', cancelled: 'pill-neutral' };
export function LeavePill({ state }: { state: LeaveState }) {
  const { t } = useTranslation();
  return <span className={clsx('pill', LEAVE_TONE[state])}>{t(`hr.leaveState.${state}`)}</span>;
}
export function FlagPills({ flags }: { flags: string[] | null | undefined }) {
  const { t } = useTranslation();
  if (!flags || flags.length === 0) return <span className="pill pill-ok">{t('hr.flag.none')}</span>;
  return <span className="inline-flex flex-wrap gap-1">{flags.map((f) => <span key={f} className={clsx('pill', f === 'outside_site' || f === 'no_location' ? 'pill-crit' : 'pill-warning')}>{t(`hr.flag.${f}`, { defaultValue: f })}</span>)}</span>;
}
const time = (iso: string | null | undefined, tz?: string) =>
  !iso ? '—' : new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: tz }).format(new Date(iso));
export const days = (n: unknown) => fmtQty(n);

/** Header for HR records: back link, breadcrumb (10 Human Resources), title with pills, one line, actions. */
export function HrHeader({ back, title, pills, sub, actions }: { back: [string, string]; title: string; pills?: ReactNode; sub?: ReactNode; actions?: ReactNode }) {
  const { t } = useTranslation();
  const m = moduleByKey('hr')!;
  return (
    <header className="mb-4">
      <Link to={back[1]} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {back[0]}
      </Link>
      <Crumbs items={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/hr'], [back[0], back[1]], [title, undefined]]} />
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
/** List frame for HR screens. Leave is open to every employee (the database shows their own, their team's, or all for HR). */
export function HrFrame({ title, desc, actions, gate = true, children }: { title: string; desc?: string; actions?: ReactNode; gate?: boolean; children: ReactNode }) {
  const { t } = useTranslation();
  const m = moduleByKey('hr')!;
  const body = (
    <>
      <PageTitle crumbs={[[t('nav.home'), '/'], [`${m.num} ${m.title}`, '/m/hr'], [title, undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{title} <LiveBadge live /></span>} desc={desc} actions={actions} />
      {children}
    </>
  );
  return gate ? <RequireModule module="hr">{body}</RequireModule> : body;
}
export function BalanceList({ items }: { items: Balance[] }) {
  const { t } = useTranslation();
  if (items.length === 0) return <p className="p-5 text-sm text-muted">{t('hr.portal.noBalances')}</p>;
  return (
    <ul className="divide-y divide-line" data-testid="hr-balances">
      {items.map((b) => (
        <li key={b.leave_code} className="flex items-center justify-between gap-3 px-5 py-3">
          <div className="min-w-0">
            <div dir="auto" className="font-medium">{b.name}</div>
            <div className="text-xs text-muted">
              {b.tracked ? t('hr.balance.detail', { entitled: days(b.entitled), taken: days(b.taken), pending: days(b.pending), adjusted: days(b.adjusted) }) : t('hr.balance.notTracked')}
            </div>
          </div>
          <div className="num text-end text-lg font-semibold">{b.tracked ? days(b.available) : '—'}<span className="ms-1 text-xs font-normal text-muted">{b.tracked ? t('hr.daysShort') : ''}</span></div>
        </li>
      ))}
    </ul>
  );
}

// ---------- Staff Portal ----------
export function PortalPage() {
  const { t } = useTranslation();
  const company = useDefaultCompany();
  const q = usePortal(company);
  const [flash, setFlash] = useFlash();
  const me = q.data;
  return (
    <div className="mx-auto max-w-5xl">
      <PageTitle crumbs={[[t('nav.home'), '/'], [t('hr.portal.title'), undefined]]}
        title={<span className="inline-flex flex-wrap items-center gap-3">{t('hr.portal.title')} <LiveBadge live /></span>}
        desc={me?.linked ? t('hr.portal.hello', { name: me.employee.name }) : t('hr.portal.desc')} />
      <Flash text={flash} />
      {q.isLoading ? <PageLoading /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !me?.linked ? (
        <div className="card p-6 text-center" role="status" data-testid="portal-unlinked">
          <AlertTriangle className="mx-auto h-8 w-8 text-warn-fg" aria-hidden />
          <p className="mt-2 font-semibold">{t('hr.portal.unlinkedTitle')}</p>
          <p className="mt-1 text-sm text-muted">{t('hr.portal.unlinkedBody')}</p>
        </div>
      ) : (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
          <div className="min-w-0 space-y-5">
            <CheckInCard company={company} me={me} onDone={() => q.refetch()} />
            <LeaveRequestCard company={company} me={me} onDone={(msg) => { setFlash(msg); q.refetch(); }} />
            <SectionCard title={t('hr.portal.myRequests')} right={<Link to="/hr/leave" className="text-sm font-medium text-primary hover:underline">{t('hr.portal.allLeave')}</Link>}>
              {me.requests.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.portal.noRequests')}</p> : (
                <ul className="divide-y divide-line" data-testid="portal-requests">
                  {me.requests.map((r) => (
                    <li key={r.request_id}>
                      <Link to={`/hr/leave/${company}/${r.request_id}`} className="flex min-h-[48px] flex-wrap items-center justify-between gap-2 px-5 py-3 hover:bg-surface-2">
                        <span><span className="font-medium">{me.balances.find((b) => b.leave_code === r.leave_code)?.name ?? r.leave_code}</span>
                          <span className="ms-2 text-sm text-muted">{fmtDay(r.from_date)} – {fmtDay(r.to_date)} · {t('hr.nDays', { n: days(r.days) })}</span></span>
                        <LeavePill state={r.state} />
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
            <SectionCard title={t('hr.portal.payslips')}>
              {me.payslips.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.portal.noPayslips')}</p> : (
                <ul className="divide-y divide-line" data-testid="portal-payslips">
                  {me.payslips.map((p) => (
                    <li key={p.run_id}>
                      <Link to={`/portal/payslip/${company}/${p.run_id}`} className="flex min-h-[48px] items-center justify-between gap-2 px-5 py-3 hover:bg-surface-2">
                        <span className="inline-flex items-center gap-2 font-medium"><FileText className="h-4 w-4 text-muted" aria-hidden />{t('hr.payslipFor', { period: p.period })}</span>
                        <span className="num font-semibold">{fmtMoney(p.net, me.currency)}</span>
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
          </div>
          <aside className="min-w-0 space-y-5">
            <SectionCard title={t('hr.portal.profile')}>
              <dl className="space-y-2 p-5 text-sm" data-testid="portal-profile">
                <div><dt className="text-xs text-muted">{t('hr.f.name')}</dt><dd dir="auto" className="font-medium">{me.employee.name} <span className="font-mono text-xs text-muted">{me.employee.hr_code}</span></dd></div>
                <div><dt className="text-xs text-muted">{t('hr.f.jobTitle')}</dt><dd dir="auto">{me.employee.job_title ?? '—'} · {me.employee.department ?? '—'}</dd></div>
                <div><dt className="text-xs text-muted">{t('hr.f.manager')}</dt><dd dir="auto">{me.employee.manager_name ?? '—'}</dd></div>
                <div><dt className="text-xs text-muted">{t('hr.f.joined')}</dt><dd>{fmtDay(me.employee.joined_on)}</dd></div>
              </dl>
              {me.team_waiting > 0 && (
                <Link to="/approvals" className="mx-5 mb-5 flex min-h-[44px] items-center justify-between rounded-btn border border-warn-fg/30 bg-warn-bg px-4 text-sm font-medium text-warn-fg" data-testid="portal-team-waiting">
                  {t('hr.portal.teamWaiting', { count: me.team_waiting })}
                </Link>
              )}
            </SectionCard>
            <SectionCard title={t('hr.portal.balances')}><BalanceList items={me.balances} /></SectionCard>
            <SectionCard title={t('hr.portal.duties')}>
              <div className="p-5 text-sm">
                {me.shift ? <p className="mb-3" data-testid="portal-shift"><span className="font-medium">{me.shift.name}</span> · {me.shift.start_time.slice(0, 5)}–{me.shift.end_time.slice(0, 5)}</p>
                  : <p className="mb-3 text-muted">{t('hr.portal.noShift')}</p>}
                {me.duties.length === 0 ? <p className="text-muted">{t('hr.portal.noDuties')}</p> : (
                  <ul className="list-disc space-y-1 ps-5" data-testid="portal-duties">{me.duties.map((d) => <li key={d.duty_id} dir="auto">{d.title}</li>)}</ul>
                )}
              </div>
            </SectionCard>
            <SectionCard title={t('hr.portal.documents')}>
              {me.documents.length === 0 ? <p className="p-5 text-sm text-muted">{t('hr.portal.noDocuments')}</p> : (
                <ul className="divide-y divide-line">
                  {me.documents.map((d) => <DocRow key={d.doc_id} d={d} />)}
                </ul>
              )}
            </SectionCard>
          </aside>
        </div>
      )}
    </div>
  );
}

export function DocRow({ d }: { d: { doc_type: string; doc_no: string | null; expires_on: string | null; storage_path: string | null; days_left?: number | null } }) {
  const { t } = useTranslation();
  const [err, setErr] = useState<string | null>(null);
  const left = d.days_left ?? (d.expires_on ? Math.round((new Date(d.expires_on).getTime() - Date.now()) / 86400000) : null);
  const tone = left === null ? 'pill-neutral' : left < 0 ? 'pill-crit' : left <= 30 ? 'pill-warning' : 'pill-ok';
  return (
    <li className="flex flex-wrap items-center justify-between gap-2 px-5 py-3 text-sm">
      <div className="min-w-0">
        <div className="font-medium">{t(`hr.docType.${d.doc_type}`, { defaultValue: d.doc_type })} <span className="font-mono text-xs text-muted">{d.doc_no ?? ''}</span></div>
        <div className="text-xs text-muted">{t('hr.expires')} {fmtDay(d.expires_on)}</div>
        {err && <p role="alert" className="text-xs text-crit-fg">{err}</p>}
      </div>
      <span className="inline-flex items-center gap-2">
        {left !== null && <span className={clsx('pill', tone)}>{left < 0 ? t('hr.expired') : t('hr.daysLeft', { n: left })}</span>}
        {d.storage_path && <button type="button" className="min-h-[40px] text-sm font-medium text-primary hover:underline"
          onClick={() => openHrFile(d.storage_path!).catch((e) => setErr(errorMessage(e)))}>{t('hr.openFile')}</button>}
      </span>
    </li>
  );
}

function CheckInCard({ company, me, onDone }: { company: string; me: PortalMe; onDone: () => void }) {
  const { t } = useTranslation();
  const [busy, setBusy] = useState<'locating' | 'saving' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ text: string; flagged: boolean } | null>(null);
  const a = me.attendance_today;
  const kind: 'in' | 'out' | null = !a ? 'in' : !a.check_out_at ? 'out' : null;
  const run = async () => {
    if (!kind) return;
    setErr(null); setMsg(null); setBusy('locating');
    const pos = await currentPosition();
    setBusy('saving');
    try {
      const r = await attendanceCheck(company, kind, pos);
      setMsg({ text: r.message, flagged: r.flags.some((f) => f === 'outside_site' || f === 'no_location' || f === 'late') });
      onDone();
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(null); }
  };
  return (
    <SectionCard title={t('hr.portal.attendance')} right={<span className="text-sm text-muted">{fmtDay(me.today)}</span>}>
      <div className="p-5">
        <FormError message={err} />
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-0 flex-1 text-sm">
            {a ? (
              <>
                <p data-testid="portal-today">{t('hr.portal.checkedInAt', { time: time(a.check_in_at, me.timezone) })}{a.check_out_at ? ` · ${t('hr.portal.checkedOutAt', { time: time(a.check_out_at, me.timezone) })}` : ''}</p>
                <div className="mt-1"><FlagPills flags={[...a.in_flags, ...a.out_flags]} /></div>
              </>
            ) : <p className="text-muted">{t('hr.portal.notCheckedIn')}</p>}
            <p className="mt-2 flex items-center gap-1 text-xs text-muted"><MapPin className="h-3.5 w-3.5" aria-hidden />
              {me.site ? t('hr.portal.siteNote', { site: me.site.name, m: me.site.radius_m }) : t('hr.portal.noSite')}</p>
          </div>
          {kind ? (
            <Button variant="primary" id="portal-check" data-testid="portal-check" className="w-full sm:w-auto" disabled={busy !== null}
              icon={kind === 'in' ? <LogIn className="h-4 w-4" aria-hidden /> : <LogOut className="h-4 w-4" aria-hidden />} onClick={run}>
              {busy === 'locating' ? t('hr.portal.locating') : busy === 'saving' ? t('hr.portal.saving') : kind === 'in' ? t('hr.portal.checkIn') : t('hr.portal.checkOut')}
            </Button>
          ) : <span className="pill pill-ok">{t('hr.portal.dayDone')}</span>}
        </div>
        {msg && (
          <p role="status" dir="auto" data-testid="portal-check-msg"
            className={clsx('mt-4 rounded-btn border px-4 py-3 text-sm', msg.flagged ? 'border-warn-fg/30 bg-warn-bg text-warn-fg' : 'border-ok-fg/30 bg-ok-bg text-ok-fg')}>{msg.text}</p>
        )}
      </div>
    </SectionCard>
  );
}

function LeaveRequestCard({ company, me, onDone }: { company: string; me: PortalMe; onDone: (msg: string) => void }) {
  const { t } = useTranslation();
  const [f, setF] = useState({ leave_code: '', from_date: '', to_date: '', reason: '' });
  const [ev, setEv] = useState<LeaveEval | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ready = f.leave_code && f.from_date && f.to_date;
  useEffect(() => {
    if (!ready) { setEv(null); return; }
    const h = setTimeout(() => { leaveChecks(company, f).then(setEv).catch((e) => setErr(errorMessage(e))); }, 300);
    return () => clearTimeout(h);
  }, [company, f, ready]);
  const fieldErr = (k: string) => ev?.errors.find((e) => e.field === k)?.message;
  const general = ev?.errors.find((e) => e.field === null)?.message;
  const submit = async () => {
    setErr(null); setBusy(true);
    try {
      const r = await leaveSubmit(company, f);
      setF({ leave_code: '', from_date: '', to_date: '', reason: '' }); setEv(null);
      onDone(t('hr.leave.sent', { who: r.steps.map((s) => s.approver_name).join(' → ') }));
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => setF((p) => ({ ...p, [k]: e.target.value }));
  return (
    <SectionCard title={t('hr.leave.new')}>
      <div className="p-5">
        <FormError message={err ?? general ?? null} />
        <div className="grid gap-4 sm:grid-cols-3">
          <label className={hrLabel}>{t('hr.f.leaveType')}<span className="text-crit-fg"> *</span>
            <select data-testid="leave-type" className={hrInput} value={f.leave_code} onChange={set('leave_code')}>
              <option value="">{t('hr.choose')}</option>
              {me.leave_types.map((lt) => <option key={lt.code} value={lt.code}>{lt.name}</option>)}
            </select>
            <FieldErr m={fieldErr('leave_code')} />
          </label>
          <label className={hrLabel}>{t('hr.f.from')}<span className="text-crit-fg"> *</span>
            <input data-testid="leave-from" type="date" className={hrInput} value={f.from_date} onChange={set('from_date')} />
            <FieldErr m={fieldErr('from_date')} />
          </label>
          <label className={hrLabel}>{t('hr.f.to')}<span className="text-crit-fg"> *</span>
            <input data-testid="leave-to" type="date" className={hrInput} value={f.to_date} min={f.from_date || undefined} onChange={set('to_date')} />
            <FieldErr m={fieldErr('to_date')} />
          </label>
          <label className={clsx(hrLabel, 'sm:col-span-3')}>{t('hr.f.reason')}
            <textarea data-testid="leave-reason" rows={2} dir="auto" className={hrInput} value={f.reason} onChange={set('reason')} />
          </label>
        </div>
        {ev && ev.errors.length === 0 && (
          <div className="mt-4 rounded-btn border border-primary-line bg-primary-soft px-4 py-3 text-sm text-primary-text" data-testid="leave-preview">
            <p><span data-testid="leave-days" className="font-semibold">{t('hr.nDays', { n: days(ev.days) })}</span>
              {ev.balance?.tracked ? ` · ${t('hr.leave.leftAfter', { n: days(Number(ev.balance.available) - Number(ev.days)) })}` : ''}</p>
            <p className="mt-1" data-testid="leave-steps">{t('hr.leave.goesTo')} {ev.steps.map((s) => s.approver_name).join(' → ')}</p>
          </div>
        )}
        <div className="mt-4 flex justify-end">
          <Button variant="primary" data-testid="leave-submit" disabled={busy || !ready || !ev || ev.errors.length > 0} onClick={submit}>{t('hr.leave.submit')}</Button>
        </div>
      </div>
    </SectionCard>
  );
}
export function FieldErr({ m }: { m?: string }) {
  if (!m) return null;
  return <span role="alert" dir="auto" className="mt-1 flex items-start gap-1 text-[13px] font-normal text-crit-fg" data-testid="hr-field-error"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />{m}</span>;
}

// ---------- Payslip ----------
export function PayslipPage() {
  const { t } = useTranslation();
  const { company = '', run = '' } = useParams();
  const emp = new URLSearchParams(window.location.search).get('emp');
  const q = usePayslip(company, Number(run), emp ? Number(emp) : undefined);
  if (q.isLoading) return <PageLoading />;
  if (q.error || !q.data) return <ErrorState error={q.error ?? new Error(t('erp.notFound'))} onRetry={() => q.refetch()} />;
  const p = q.data;
  const cur = p.company.currency;
  const earn = p.lines.filter((l) => l.kind === 'earning');
  const ded = p.lines.filter((l) => l.kind === 'deduction');
  return (
    <div className="mx-auto max-w-3xl">
      <header className="mb-4 print:hidden">
        <Link to={emp ? `/hr/payroll` : '/portal'} className="mb-2 inline-flex min-h-[32px] items-center gap-1 text-sm font-medium text-primary hover:underline">
          <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /> {emp ? t('hr.payroll.title') : t('hr.portal.title')}
        </Link>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h1 className="text-[26px] font-semibold sm:text-[28px]">{t('hr.payslipFor', { period: p.period })}</h1>
          <Button icon={<Printer className="h-4 w-4" aria-hidden />} onClick={() => window.print()}>{t('hr.print')}</Button>
        </div>
      </header>
      <article className="card p-6" data-testid="payslip">
        <div className="flex flex-wrap justify-between gap-3 border-b border-line pb-4">
          <div><div className="font-semibold" dir="auto">{p.company.name}</div><div className="text-sm text-muted">{fmtDay(p.from_date)} – {fmtDay(p.to_date)}</div></div>
          <div className="text-end"><div className="font-semibold" dir="auto">{p.employee.name}</div><div className="text-sm text-muted"><span className="font-mono">{p.employee.hr_code}</span> · {p.job_title ?? ''}</div></div>
        </div>
        <div className="grid gap-6 py-4 sm:grid-cols-2">
          {([['hr.earnings', earn], ['hr.deductions', ded]] as const).map(([k, rows]) => (
            <div key={k}>
              <h2 className="mb-2 text-sm font-semibold">{t(k)}</h2>
              {rows.length === 0 ? <p className="text-sm text-muted">—</p> : (
                <table className="w-full text-sm"><tbody>
                  {rows.map((l) => (
                    <tr key={l.line_no} className="border-t border-line">
                      <td className="py-1.5" dir="auto">{l.name ?? l.wage_code}{l.note && <div className="text-xs text-muted">{l.note}</div>}</td>
                      <td className="num py-1.5 text-end">{fmtMoney(l.amount)}</td>
                    </tr>
                  ))}
                </tbody></table>
              )}
            </div>
          ))}
        </div>
        <dl className="grid grid-cols-2 gap-2 border-t border-line pt-4 text-sm sm:grid-cols-4">
          <div><dt className="text-xs text-muted">{t('hr.daysPaid')}</dt><dd className="num">{days(p.employee.days_paid)} / {days(p.employee.days_in_period)}</dd></div>
          <div><dt className="text-xs text-muted">{t('hr.gross')}</dt><dd className="num">{fmtMoney(p.employee.gross, cur)}</dd></div>
          <div><dt className="text-xs text-muted">{t('hr.deductions')}</dt><dd className="num">{fmtMoney(p.employee.deductions, cur)}</dd></div>
          <div><dt className="text-xs text-muted">{t('hr.net')}</dt><dd className="num text-lg font-semibold" data-testid="payslip-net">{fmtMoney(p.employee.net, cur)}</dd></div>
        </dl>
      </article>
    </div>
  );
}

// ---------- Leave list and leave request ----------
export function LeaveListPage() {
  const { t } = useTranslation();
  const { level } = useModuleLevel('hr');
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'hr-leave', table: 'leave_request_list',
    select: 'company_code,request_id,hr_code,emp_name,department,leave_code,leave_name,from_date,to_date,days,state,waiting_for,mine,my_team,requested_at',
    searchCols: ['emp_name', 'hr_code', 'leave_name', 'department'], numberSearchCols: ['request_id'], searchLabel: t('hr.leave.search'),
    filters: [
      { key: 'state', label: t('erp.col.status'), options: (['pending_approval', 'approved', 'rejected', 'cancelled'] as LeaveState[]).map((s) => [s, t(`hr.leaveState.${s}`)]) },
      { key: 'my_team', label: t('hr.leave.scope'), options: [['true', t('hr.leave.myTeam')]], type: 'boolean' },
      { key: 'mine', label: t('hr.leave.mineFilter'), options: [['true', t('hr.leave.mine')]], type: 'boolean' },
    ],
    defaultSort: { col: 'from_date', asc: false },
    rowKey: (r) => `${r.company_code}|${r.request_id}`,
    rowLink: (r) => `/hr/leave/${r.company_code}/${r.request_id}`,
    emptyTitle: t('hr.leave.empty'), emptyBody: t('hr.leave.emptyBody'),
    columns: [
      { key: 'request_id', header: t('hr.col.request'), mono: true },
      { key: 'emp_name', header: t('hr.col.employee'), cell: (r) => <span dir="auto">{r.emp_name}<span className="ms-1 font-mono text-xs text-muted">{r.hr_code}</span></span> },
      { key: 'leave_name', header: t('hr.f.leaveType'), hideBelow: 'sm' },
      { key: 'from_date', header: t('hr.f.from'), cell: (r) => fmtDay(r.from_date), csv: (r) => r.from_date },
      { key: 'to_date', header: t('hr.f.to'), cell: (r) => fmtDay(r.to_date), csv: (r) => r.to_date, hideBelow: 'md' },
      { key: 'days', header: t('hr.col.days'), align: 'end', cell: (r) => days(r.days) },
      { key: 'waiting_for', header: t('hr.col.waitingFor'), hideBelow: 'lg' },
      { key: 'state', header: t('erp.col.status'), cell: (r) => <LeavePill state={r.state} />, csv: (r) => r.state },
    ],
  }), [t]);
  return (
    <HrFrame gate={false} title={t('hr.leave.title')} desc={level ? t('hr.leave.descHr') : t('hr.leave.desc')}
      actions={<Link to="/portal" className={primaryLink}>{t('hr.leave.new')}</Link>}>
      <ListScreen config={cfg} />
    </HrFrame>
  );
}

export function LeavePage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const nav = useNavigate();
  const { company = '', id = '' } = useParams();
  const q = useLeaveInfo(company, Number(id));
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [flash, setFlash] = useFlash();
  if (q.isLoading) return <PageLoading />;
  if (q.error || !q.data) return <ErrorState error={q.error ?? new Error(t('erp.notFound'))} onRetry={() => q.refetch()} />;
  const { request: r, approvals, balance } = q.data;
  const act = async (fn: () => Promise<unknown>, msg: string) => {
    setErr(null); setBusy(true);
    try { await fn(); setNote(''); setFlash(msg); qc.invalidateQueries({ queryKey: ['hr-leave'] }); qc.invalidateQueries({ queryKey: ['hr-portal'] }); await q.refetch(); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const current = approvals.find((a) => !a.decision && !a.superseded);
  return (
    <div>
      <HrHeader back={[t('hr.leave.title'), '/hr/leave']} title={t('hr.leave.titleN', { n: r.request_id })} pills={<LeavePill state={r.state} />}
        sub={<span dir="auto">{r.emp_name} · {r.leave_name ?? r.leave_code} · {fmtDay(r.from_date)} – {fmtDay(r.to_date)}</span>}
        actions={q.data.can_cancel ? <Button variant="danger" data-testid="leave-cancel" disabled={busy}
          onClick={() => act(() => leaveCancel(company, r.request_id, note.trim() || null), t('hr.leave.cancelled'))}>{t('hr.leave.cancel')}</Button> : undefined} />
      <Flash text={flash} />
      <FormError message={err} />
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-5">
          <SectionCard title={t('erp.section.general')}>
            <Fields items={[
              [t('hr.col.employee'), <span dir="auto">{r.emp_name} <span className="font-mono text-xs text-muted">{r.hr_code}</span></span>],
              [t('hr.f.department'), r.department], [t('hr.f.leaveType'), r.leave_name ?? r.leave_code],
              [t('hr.f.from'), fmtDay(r.from_date)], [t('hr.f.to'), fmtDay(r.to_date)], [t('hr.col.days'), <span data-testid="leave-info-days">{days(r.days)}</span>],
              [t('hr.f.reason'), r.reason ? <span dir="auto">“{r.reason}”</span> : null], [t('hr.requestedBy'), r.requested_by_name], [t('hr.requestedAt'), fmtWhen(r.requested_at)],
            ]} />
          </SectionCard>
          <SectionCard title={t('hr.balance.title')}>
            <BalanceList items={[{ ...balance, name: r.leave_name ?? r.leave_code } as Balance]} />
          </SectionCard>
          <SectionCard title={t('hr.leave.steps')}>
            <ol className="divide-y divide-line" data-testid="leave-approvals">
              {approvals.length === 0 ? <li className="p-5 text-sm text-muted">—</li> : approvals.map((a) => (
                <li key={a.approval_id} className="flex flex-wrap items-start justify-between gap-2 px-5 py-3 text-sm">
                  <div className="min-w-0"><div className="font-medium" dir="auto">{a.message}</div>
                    <div className="text-xs text-muted" dir="auto">{a.approver_name}{a.decided_by_name ? ` · ${a.decided_by_name} · ${fmtWhen(a.decided_at)}` : ''}</div>
                    {a.note && <div className="text-xs italic text-ink-2" dir="auto">“{a.note}”</div>}</div>
                  <span className={clsx('pill', a.decision === 'approved' ? 'pill-ok' : a.decision === 'rejected' ? 'pill-crit' : a.superseded ? 'pill-neutral' : 'pill-warning')}>
                    {a.decision ? t(`erp.status.${a.decision}`) : a.superseded ? t('inbox.closed') : t('hr.leaveState.pending_approval')}</span>
                </li>
              ))}
            </ol>
          </SectionCard>
        </div>
        <aside className="min-w-0 space-y-5">
          {q.data.can_decide && current && (
            <section className="card border-warn-fg/40 p-5" data-testid="leave-approval-card">
              <h2 className="text-[15px] font-semibold">{t('hr.leave.yourApproval')}</h2>
              <p className="mt-1 text-sm text-ink-2" dir="auto">{current.message}</p>
              {r.reason && <p className="mt-2 text-sm italic" dir="auto">“{r.reason}”</p>}
              <label className={clsx(hrLabel, 'mt-3')}>{t('hr.leave.note')}
                <textarea data-testid="leave-note" rows={2} dir="auto" className={hrInput} value={note} onChange={(e) => setNote(e.target.value)} />
              </label>
              <div className="mt-3 flex flex-wrap gap-2">
                <Button variant="success" data-testid="leave-approve" disabled={busy} icon={<CircleCheck className="h-4 w-4" aria-hidden />}
                  onClick={() => act(() => leaveDecide(company, r.request_id, 'approved', note.trim() || null), t('hr.leave.approvedMsg'))}>{t('hr.approve')}</Button>
                <Button variant="danger" data-testid="leave-reject" disabled={busy} icon={<CircleX className="h-4 w-4" aria-hidden />}
                  onClick={() => act(() => leaveDecide(company, r.request_id, 'rejected', note.trim() || null), t('hr.leave.rejectedMsg'))}>{t('hr.reject')}</Button>
              </div>
            </section>
          )}
          <SectionCard title={t('je.activity.title')}>
            <ol className="space-y-3 p-5 text-sm">
              {q.data.history.map((h, i) => (
                <li key={i}><span className="font-medium">{h.actor ?? '—'}</span> {t(`hr.activity.${h.action}`, { defaultValue: h.action })}
                  <div className="text-xs text-muted">{fmtWhen(h.at)}</div></li>
              ))}
            </ol>
          </SectionCard>
          <Button variant="ghost" onClick={() => nav('/portal')}>{t('hr.portal.title')}</Button>
        </aside>
      </div>
    </div>
  );
}

// ---------- Attendance and document expiry (HR) ----------
export function AttendancePage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'hr-att', table: 'attendance_list',
    select: 'company_code,att_id,hr_code,emp_name,department,work_date,check_in_at,check_out_at,in_distance_m,late_min,flags,in_flags,out_flags,flagged,outside_site',
    searchCols: ['emp_name', 'hr_code', 'department'], searchLabel: t('hr.att.search'),
    filters: [
      { key: 'outside_site', label: t('hr.att.rule'), options: [['true', t('hr.flag.outside_site')]], type: 'boolean' },
      { key: 'flagged', label: t('hr.att.flagged'), options: [['true', t('hr.att.onlyFlagged')], ['false', t('hr.att.noFlags')]], type: 'boolean' },
    ],
    defaultSort: { col: 'work_date', asc: false },
    rowKey: (r) => String(r.att_id),
    emptyTitle: t('hr.att.empty'), emptyBody: t('hr.att.emptyBody'),
    columns: [
      { key: 'work_date', header: t('hr.col.date'), cell: (r) => fmtDay(r.work_date), csv: (r) => r.work_date },
      { key: 'emp_name', header: t('hr.col.employee'), cell: (r) => <span dir="auto">{r.emp_name}<span className="ms-1 font-mono text-xs text-muted">{r.hr_code}</span></span> },
      { key: 'department', header: t('hr.f.department'), hideBelow: 'lg' },
      { key: 'check_in_at', header: t('hr.col.in'), cell: (r) => time(r.check_in_at, 'Asia/Dubai'), csv: (r) => r.check_in_at },
      { key: 'check_out_at', header: t('hr.col.out'), cell: (r) => time(r.check_out_at, 'Asia/Dubai'), csv: (r) => r.check_out_at, hideBelow: 'sm' },
      { key: 'in_distance_m', header: t('hr.col.distance'), align: 'end', cell: (r) => (r.in_distance_m === null ? '—' : `${fmtQty(r.in_distance_m)} m`), hideBelow: 'md' },
      { key: 'flags', header: t('hr.col.flags'), sortable: false, cell: (r) => <FlagPills flags={[...(r.in_flags ?? []), ...(r.out_flags ?? [])]} />, csv: (r) => r.flags },
    ],
  }), [t]);
  return <HrFrame title={t('hr.att.title')} desc={t('hr.att.desc')}><ListScreen config={cfg} /></HrFrame>;
}

export function ExpiryPage() {
  const { t } = useTranslation();
  const cfg = useMemo<ListConfig<R>>(() => ({
    id: 'hr-expiry', table: 'hr_doc_expiry',
    select: 'company_code,emp_id,hr_code,emp_name,department,doc_type,doc_no,expires_on,days_left,band,source,doc_id',
    searchCols: ['emp_name', 'hr_code', 'doc_no', 'doc_type'], searchLabel: t('hr.exp.search'),
    filters: [{ key: 'band', label: t('hr.exp.band'), options: ['expired', 'd7', 'd30', 'd60'].map((b) => [b, t(`hr.exp.b.${b}`)]) }],
    defaultSort: { col: 'expires_on', asc: true },
    rowKey: (r) => `${r.company_code}|${r.emp_id}|${r.doc_type}|${r.doc_no}|${r.source}`,
    rowLink: (r) => `/hr/employees/${r.company_code}/${r.emp_id}`,
    emptyTitle: t('hr.exp.empty'), emptyBody: t('hr.exp.emptyBody'),
    columns: [
      { key: 'emp_name', header: t('hr.col.employee'), cell: (r) => <span dir="auto">{r.emp_name}<span className="ms-1 font-mono text-xs text-muted">{r.hr_code}</span></span> },
      { key: 'doc_type', header: t('hr.col.document'), cell: (r) => t(`hr.docType.${r.doc_type}`, { defaultValue: r.doc_type }) },
      { key: 'doc_no', header: t('hr.col.docNo'), mono: true, hideBelow: 'md' },
      { key: 'expires_on', header: t('hr.expires'), cell: (r) => fmtDay(r.expires_on), csv: (r) => r.expires_on },
      { key: 'days_left', header: t('hr.col.daysLeft'), align: 'end', cell: (r) => r.days_left, hideBelow: 'sm' },
      { key: 'band', header: t('hr.exp.band'), cell: (r) => <span className={clsx('pill', r.band === 'expired' || r.band === 'd7' ? 'pill-crit' : r.band === 'd30' ? 'pill-warning' : 'pill-info')}>{t(`hr.exp.b.${r.band}`)}</span>, csv: (r) => r.band },
    ],
  }), [t]);
  return <HrFrame title={t('hr.exp.title')} desc={t('hr.exp.desc')}><ListScreen config={cfg} /></HrFrame>;
}

export function EmptyNote({ text }: { text: string }) { return <EmptyState title={text} />; }
