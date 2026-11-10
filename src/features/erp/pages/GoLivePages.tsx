import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { Activity, Check, CircleCheck, ExternalLink, Flag, HeartPulse, ListChecks, Plus, RefreshCw, RotateCcw, Rocket, X } from 'lucide-react';
import { errorMessage, fmtDate } from '@/lib/format';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { Fields, SectionCard, fmtDay } from '../components/ui';
import { Dialog } from '../components/Dialog';
import {
  STEP_NEEDS_EVIDENCE, companyGoLive, goLiveIssueClose, goLiveIssueSave, goLiveStepSet, useGoLiveChecklist, useGoLiveOverview, useSystemHealth,
  type GoLiveChecklist, type GoLiveStep, type HealthStatus,
} from '../golive';
import { AdminFrame, ErrorBox, Flash, ReadOnlyNote } from './AdminPages';

const when = (iso: string | null | undefined) => fmtDate(iso, { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const toneOf = (s: HealthStatus) => (s === 'ok' ? 'pill-ok' : s === 'warn' ? 'pill-warning' : 'pill-crit');

function Progress({ done, total }: { done: number; total: number }) {
  const { t } = useTranslation();
  const pct = Math.round((done / total) * 100);
  return (
    <div>
      <div className="mb-1 flex justify-between text-xs text-muted"><span>{t('gl.progress', { done, total })}</span><span className="num">{pct}%</span></div>
      <div className="h-2 overflow-hidden rounded-full bg-surface-2" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done} aria-label={t('gl.progress', { done, total })}>
        <div className={clsx('h-full rounded-full', done === total ? 'bg-ok-fg' : 'bg-primary')} style={{ inlineSize: `${pct}%` }} />
      </div>
    </div>
  );
}

// ---------- Overview: one card per company ----------
export function GoLiveOverviewPage() {
  const { t } = useTranslation();
  const q = useGoLiveOverview();
  return (
    <AdminFrame title={t('gl.title')} desc={t('gl.desc')}
      actions={<Link to="/admin/health" className="inline-flex min-h-[44px] items-center justify-center gap-2 rounded-btn border border-line bg-surface px-4 text-[15px] font-medium text-ink transition-colors hover:bg-page" id="gl-health-link"><HeartPulse className="h-4 w-4" aria-hidden />{t('gl.health.title')}</Link>}>
      {q.isLoading ? <div className="card"><SkeletonRows rows={4} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : !(q.data ?? []).length ? (
        <div className="card"><EmptyState title={t('gl.none')} body={t('gl.noneBody')} /></div>
      ) : (
        <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3" data-testid="gl-companies">
          {(q.data ?? []).map((c) => (
            <Link key={c.company_code} to={`/admin/go-live/${c.company_code}`} className="card block p-5 hover:border-primary-line" data-company={c.company_code}>
              <div className="mb-3 flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <span className="font-mono text-xs font-semibold text-primary-text">{c.company_code}</span>
                  <div className="truncate font-semibold" dir="auto">{c.company_name}</div>
                </div>
                {c.go_live_at
                  ? <span className="pill pill-ok shrink-0">{t('gl.liveSince', { date: fmtDay(c.go_live_at) })}</span>
                  : <span className="pill pill-neutral shrink-0">{t('gl.preparing')}</span>}
              </div>
              <Progress done={c.steps_done} total={c.steps_total} />
              <p className="mt-3 text-sm text-ink-2">
                {c.next_step ? t('gl.next', { n: c.next_step, title: t(`gl.step.${c.next_step}.title`) }) : t('gl.allDone')}
              </p>
              {c.go_live_at && c.hypercare_until && c.steps_done < 7 && (
                <p className="mt-1 text-xs text-muted">{t('gl.hypercareUntil', { date: fmtDay(c.hypercare_until) })} · {t('gl.openIssues', { n: c.open_issues })}</p>
              )}
            </Link>
          ))}
        </div>
      )}
      <SectionCard title={t('gl.howTitle')} className="mt-5">
        <ol className="grid gap-x-8 gap-y-3 p-5 text-sm sm:grid-cols-2">
          {[1, 2, 3, 4, 5, 6, 7].map((n) => (
            <li key={n} className="flex gap-3">
              <span className="num grid h-6 w-6 shrink-0 place-items-center rounded-full bg-surface-2 text-xs font-semibold">{n}</span>
              <span><span className="font-medium">{t(`gl.step.${n}.title`)}</span><span className="block text-muted">{t(`gl.step.${n}.desc`)}</span></span>
            </li>
          ))}
        </ol>
      </SectionCard>
    </AdminFrame>
  );
}

// ---------- One company ----------
function StepPill({ s, live }: { s: GoLiveStep; live: boolean }) {
  const { t } = useTranslation();
  if (s.done) return <span className="pill pill-ok">{t('gl.st.done')}</span>;
  if (s.step === 7 && !live) return <span className="pill pill-neutral">{t('gl.st.afterLive')}</span>;
  if (s.waiting_for) return <span className="pill pill-neutral">{t('gl.st.waiting', { n: s.waiting_for })}</span>;
  return <span className="pill pill-warning">{t('gl.st.todo')}</span>;
}

export function GoLiveChecklistPage() {
  const { t } = useTranslation();
  const { company = '' } = useParams();
  const qc = useQueryClient();
  const q = useGoLiveChecklist(company);
  const [form, setForm] = useState<{ step: number; done: boolean; note: string; evidence: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [goLive, setGoLive] = useState(false);
  const [issue, setIssue] = useState({ title: '', severity: 'normal' as 'normal' | 'critical' });
  const [closing, setClosing] = useState<{ id: number; note: string } | null>(null);
  const d = q.data;

  async function run(fn: () => Promise<unknown>, ok: string) {
    setErr(null); setFlash(null); setBusy(true);
    try {
      await fn();
      setFlash(ok);
      await Promise.all([qc.invalidateQueries({ queryKey: ['golive', company] }), qc.invalidateQueries({ queryKey: ['golive-overview'] })]);
      return true;
    } catch (e) { setErr(errorMessage(e)); return false; } finally { setBusy(false); }
  }
  async function saveStep() {
    if (!form) return;
    const f = form;
    if (await run(() => goLiveStepSet(company, f.step, f.done, f.note, f.evidence), t(f.done ? 'gl.flash.done' : 'gl.flash.reopened', { n: f.step }))) setForm(null);
  }

  const doneCount = d?.steps.filter((s) => s.done).length ?? 0;
  const ready = Boolean(d && d.steps.filter((s) => s.step <= 5).every((s) => s.done));
  return (
    <AdminFrame title={t('gl.companyTitle', { company })} desc={t('gl.companyDesc')}
      crumbs={[[t('gl.title'), '/admin/go-live'], [company, undefined]]}
      actions={d ? (d.live
        ? <span className="pill pill-ok" data-testid="gl-state">{t('gl.liveSince', { date: fmtDay(d.go_live_at) })}</span>
        : <span className="pill pill-neutral" data-testid="gl-state">{t('gl.progress', { done: doneCount, total: 7 })}</span>) : undefined}>
      <Flash text={flash} />
      <ErrorBox text={err} />
      <ReadOnlyNote show={Boolean(d && !d.can_write)} />
      {q.isLoading ? <div className="card"><SkeletonRows rows={7} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : d && (
        <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_360px]">
          <SectionCard title={<span className="inline-flex items-center gap-2"><ListChecks className="h-4 w-4" aria-hidden />{d.company_code} · <span dir="auto">{d.company_name}</span></span>}>
            <div className="border-b border-line px-5 py-4"><Progress done={doneCount} total={7} /></div>
            <ol className="divide-y divide-line" data-testid="gl-steps">
              {d.steps.map((s) => (
                <li key={s.step} className={clsx('px-5 py-4', s.done && 'bg-ok-bg/40')} data-step={s.step} data-done={s.done}>
                  <div className="flex flex-wrap items-start gap-3">
                    <span className={clsx('num grid h-8 w-8 shrink-0 place-items-center rounded-full text-sm font-semibold', s.done ? 'bg-ok-bg text-ok-fg' : 'bg-surface-2 text-ink-2')}>
                      {s.done ? <Check className="h-4 w-4" aria-hidden /> : s.step}
                    </span>
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="font-semibold">{t(`gl.step.${s.step}.title`)}</h3>
                        <StepPill s={s} live={d.live} />
                        {s.auto && <span className="pill pill-info">{t('gl.st.auto')}</span>}
                      </div>
                      <p className="mt-0.5 text-sm text-muted">{t(`gl.step.${s.step}.desc`)}</p>
                      <StepFacts d={d} s={s} />
                      {(s.done_at || s.note || s.evidence) && (
                        <div className="mt-2 space-y-1 text-sm">
                          {s.done_at && <p className="text-ink-2">{t('gl.doneBy', { who: s.done_by ?? '—', when: when(s.done_at) })}</p>}
                          {s.evidence && <p><span className="text-muted">{t('gl.evidence')}: </span><span dir="auto" className="font-mono text-[13px]">{s.evidence}</span></p>}
                          {s.note && <p dir="auto" className="text-ink-2">“{s.note}”</p>}
                        </div>
                      )}
                    </div>
                    {d.can_write && !s.auto && form?.step !== s.step && !(d.live && s.step <= 5) && (
                      <div className="ms-auto">
                        {s.done
                          ? <Button id={`gl-reopen-${s.step}`} icon={<RotateCcw className="h-4 w-4" aria-hidden />} onClick={() => { setErr(null); setForm({ step: s.step, done: false, note: '', evidence: '' }); }}>{t('gl.reopen')}</Button>
                          : <Button id={`gl-mark-${s.step}`} variant="primary" icon={<Check className="h-4 w-4" aria-hidden />} onClick={() => { setErr(null); setForm({ step: s.step, done: true, note: '', evidence: '' }); }}>{t('gl.markDone')}</Button>}
                      </div>
                    )}
                    {s.step === 6 && !d.live && d.can_go_live && (
                      <div className="ms-auto">
                        <Button id="gl-golive" variant="primary" icon={<Rocket className="h-4 w-4" aria-hidden />} disabled={!ready || !d.run || d.run.status !== 'signed_off'}
                          disabledReason={!ready ? t('gl.goLiveWait') : undefined} onClick={() => { setErr(null); setGoLive(true); }}>{t('gl.goLive')}</Button>
                      </div>
                    )}
                  </div>
                  {form?.step === s.step && (
                    <div className="mt-3 space-y-3 rounded-btn border border-line bg-surface p-4 sm:ms-11" data-testid="gl-form">
                      {form.done && STEP_NEEDS_EVIDENCE.has(s.step) && (
                        <label className="block text-xs font-medium text-muted">{t(`gl.ev.${s.step}`)}
                          <input id="gl-evidence" dir="auto" className="input mt-1 text-[15px] text-ink" value={form.evidence} onChange={(e) => setForm({ ...form, evidence: e.target.value })} />
                        </label>
                      )}
                      <label className="block text-xs font-medium text-muted">{form.done ? t('gl.noteOptional') : t('gl.reopenWhy')}
                        <textarea id="gl-note" dir="auto" rows={2} className="input mt-1 min-h-[64px] py-2 text-[15px] text-ink" value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} />
                      </label>
                      <div className="flex flex-wrap justify-end gap-2">
                        <Button id="gl-cancel" variant="ghost" onClick={() => setForm(null)} icon={<X className="h-4 w-4" aria-hidden />}>{t('app.cancel')}</Button>
                        <Button id="gl-save" variant="primary" disabled={busy} onClick={saveStep} icon={<CircleCheck className="h-4 w-4" aria-hidden />}>
                          {form.done ? t('gl.confirmDone', { n: s.step }) : t('gl.confirmReopen', { n: s.step })}
                        </Button>
                      </div>
                    </div>
                  )}
                </li>
              ))}
            </ol>
          </SectionCard>

          <aside className="space-y-5">
            <SectionCard title={t('gl.facts')}>
              <Fields items={[
                [t('gl.f.company'), <span key="c" className="font-mono">{d.company_code}</span>],
                [t('gl.f.goLive'), d.go_live_at ? when(d.go_live_at) : '—'],
                [t('gl.f.by'), d.go_live_by ?? '—'],
                [t('gl.f.hypercare'), d.hypercare_until ? fmtDay(d.hypercare_until) : '—'],
                [t('gl.f.run'), d.run ? <span key="r" className="font-mono text-[13px]">{d.run.run_id.slice(0, 8)} · {t(`status.${d.run.status}`, { defaultValue: d.run.status })}</span> : '—'],
              ]} />
            </SectionCard>
            <SectionCard title={<span className="inline-flex items-center gap-2"><Flag className="h-4 w-4" aria-hidden />{t('gl.issues')}</span>}>
              {!d.live ? <p className="p-5 text-sm text-muted">{t('gl.issuesBeforeLive')}</p> : (
                <div>
                  {d.can_write && (
                    <div className="space-y-2 border-b border-line p-5">
                      <label className="block text-xs font-medium text-muted">{t('gl.issueTitle')}
                        <input id="gl-issue-title" dir="auto" className="input mt-1 text-[15px] text-ink" value={issue.title} onChange={(e) => setIssue({ ...issue, title: e.target.value })} />
                      </label>
                      <div className="flex items-end gap-2">
                        <label className="block flex-1 text-xs font-medium text-muted">{t('gl.severity')}
                          <select id="gl-issue-sev" className="input mt-1 text-[15px] text-ink" value={issue.severity} onChange={(e) => setIssue({ ...issue, severity: e.target.value as 'normal' | 'critical' })}>
                            <option value="normal">{t('gl.sev.normal')}</option><option value="critical">{t('gl.sev.critical')}</option>
                          </select>
                        </label>
                        <Button id="gl-issue-add" disabled={busy} icon={<Plus className="h-4 w-4" aria-hidden />}
                          onClick={async () => { if (await run(() => goLiveIssueSave(company, issue.title, issue.severity), t('gl.flash.issue'))) setIssue({ title: '', severity: 'normal' }); }}>{t('gl.addIssue')}</Button>
                      </div>
                    </div>
                  )}
                  {!d.issues.length ? <p className="p-5 text-sm text-muted">{t('gl.noIssues')}</p> : (
                    <ul className="divide-y divide-line" data-testid="gl-issues">
                      {d.issues.map((i) => (
                        <li key={i.issue_id} className="px-5 py-3 text-sm" data-status={i.status}>
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <span className="font-medium" dir="auto">{i.title}</span>
                            <span className="flex gap-1">
                              {i.severity === 'critical' && <span className="pill pill-crit">{t('gl.sev.critical')}</span>}
                              <span className={clsx('pill', i.status === 'open' ? 'pill-warning' : 'pill-ok')}>{t(`gl.is.${i.status}`)}</span>
                            </span>
                          </div>
                          <p className="text-xs text-muted">{i.raised_by} · {when(i.raised_at)}</p>
                          {i.fix_note && <p className="mt-1 text-xs text-ink-2" dir="auto">{t('gl.fixed', { who: i.fixed_by ?? '—' })}: {i.fix_note}</p>}
                          {d.can_write && i.status === 'open' && (closing?.id === i.issue_id ? (
                            <div className="mt-2 flex items-end gap-2">
                              <label className="block flex-1 text-xs font-medium text-muted">{t('gl.howFixed')}
                                <input id="gl-close-note" dir="auto" className="input mt-1 text-[15px] text-ink" value={closing.note} onChange={(e) => setClosing({ ...closing, note: e.target.value })} />
                              </label>
                              <Button id="gl-close-save" variant="success" disabled={busy}
                                onClick={async () => { if (await run(() => goLiveIssueClose(company, i.issue_id, closing.note), t('gl.flash.closed'))) setClosing(null); }}>{t('gl.close')}</Button>
                            </div>
                          ) : <button type="button" className="mt-1 min-h-[40px] text-sm font-medium text-primary hover:underline" data-close-issue={i.issue_id} onClick={() => setClosing({ id: i.issue_id, note: '' })}>{t('gl.closeIssue')}</button>)}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              )}
            </SectionCard>
            <SectionCard title={<span className="inline-flex items-center gap-2"><Activity className="h-4 w-4" aria-hidden />{t('gl.activity')}</span>}>
              {!d.activity.length ? <p className="p-5 text-sm text-muted">{t('gl.noActivity')}</p> : (
                <ul className="divide-y divide-line" data-testid="gl-activity">
                  {d.activity.slice(0, 12).map((a, i) => (
                    <li key={i} className="px-5 py-3 text-sm">
                      <div className="flex flex-wrap justify-between gap-2">
                        <span className="font-medium">{t(`gl.act.${a.action}`, { n: (a.detail as { step?: number } | null)?.step ?? '' })}</span>
                        <span className="num text-xs text-muted">{fmtDate(a.at, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</span>
                      </div>
                      <div className="text-xs text-muted" dir="auto">{a.by}</div>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
          </aside>
        </div>
      )}
      <Dialog open={goLive} title={t('gl.goLiveTitle', { company })} onClose={() => setGoLive(false)}
        footer={<>
          <Button variant="ghost" onClick={() => setGoLive(false)}>{t('app.cancel')}</Button>
          <Button id="gl-golive-confirm" variant="primary" disabled={busy || !d?.run}
            onClick={async () => { if (d?.run && await run(() => companyGoLive(company, d.run!.run_id), t('gl.flash.live', { company }))) setGoLive(false); }}>{t('gl.goLiveConfirm')}</Button>
        </>}>
        <p className="text-sm text-ink-2">{t('gl.goLiveBody', { company })}</p>
      </Dialog>
    </AdminFrame>
  );
}

function StepFacts({ d, s }: { d: GoLiveChecklist; s: GoLiveStep }) {
  const { t } = useTranslation();
  const link = 'inline-flex min-h-[40px] items-center gap-1 text-sm font-medium text-primary hover:underline';
  if (s.step === 1) return (
    <div className="mt-2 flex flex-wrap items-center gap-2 text-sm">
      {d.run ? (<>
        <span className="text-ink-2">{t('gl.run', { status: t(`status.${d.run.status}`, { defaultValue: d.run.status }) })}</span>
        {(['finance', 'it', 'business'] as const).map((r) => {
          const so = d.run!.signoffs.find((x) => x.role === r);
          return <span key={r} className={clsx('pill', so?.decision === 'approved' ? 'pill-ok' : so ? 'pill-crit' : 'pill-neutral')}>{t(`gl.role.${r}`)}{so ? ` · ${t(`gl.dec.${so.decision}`)}` : ''}</span>;
        })}
        <Link className={link} to={`/backoffice/migration/runs/${d.run.run_id}`}>{t('gl.openRun')}<ExternalLink className="h-3.5 w-3.5 rtl:-scale-x-100" aria-hidden /></Link>
      </>) : <span className="text-muted">{t('gl.noRun')}</span>}
    </div>
  );
  if (s.step === 3) return (
    <div className="mt-2 flex flex-wrap items-center gap-x-4 text-sm text-ink-2">
      <span>{t('gl.users', { n: d.users.active, p: d.users.positions })}</span>
      {d.users.pending_invites > 0 && <span className="text-warn-fg">{t('gl.pendingInvites', { n: d.users.pending_invites })}</span>}
      <Link className={link} to="/admin/users">{t('gl.openUsers')}</Link>
    </div>
  );
  if ((s.step === 4 || s.step === 7) && d.run) return (
    <Link className={clsx(link, 'mt-1')} to={`/backoffice/migration/runs/${d.run.run_id}/check`}>{t(s.step === 4 ? 'gl.openCheck' : 'gl.dailyRecon')}</Link>
  );
  if (s.step === 6 && d.live) return <p className="mt-2 text-sm text-ink-2">{t('gl.sapStops')}</p>;
  return null;
}

// ---------- System health (read-only monitoring) ----------
export function SystemHealthPage() {
  const { t } = useTranslation();
  const q = useSystemHealth();
  const h = q.data;
  const th = 'px-4 py-2.5 text-start';
  return (
    <AdminFrame title={t('gl.health.title')} desc={t('gl.health.desc')} crumbs={[[t('gl.title'), '/admin/go-live'], [t('gl.health.title'), undefined]]}
      actions={<Button id="gl-health-refresh" icon={<RefreshCw className={clsx('h-4 w-4', q.isFetching && 'animate-spin')} aria-hidden />} onClick={() => q.refetch()}>{t('gl.health.refresh')}</Button>}>
      {q.isLoading ? <div className="card"><SkeletonRows rows={6} /></div> : q.error ? <div className="card"><ErrorState error={q.error} onRetry={() => q.refetch()} /></div> : h && (
        <div className="space-y-5">
          <div className={clsx('flex flex-wrap items-center gap-3 rounded-card border p-4', h.status === 'ok' ? 'border-ok-fg/30 bg-ok-bg text-ok-fg' : h.status === 'warn' ? 'border-warn-fg/30 bg-warn-bg text-warn-fg' : 'border-crit-fg/30 bg-crit-bg text-crit-fg')} data-testid="gl-health-status" data-status={h.status}>
            <HeartPulse className="h-5 w-5" aria-hidden /><span className="font-semibold">{t(`gl.health.overall.${h.status}`)}</span>
            <span className="text-sm">{t('gl.health.checkedAt', { when: when(h.server_time) })}</span>
          </div>
          <div className="grid gap-5 xl:grid-cols-2">
            <SectionCard title={t('gl.health.db')}>
              <Fields items={[
                [t('gl.health.version'), <span key="v" className="font-mono">{h.database.version}</span>],
                [t('gl.health.size'), <span key="s" className="num">{h.database.size_mb.toLocaleString('en-US')} MB</span>],
                [t('gl.health.locks'), <span key="l" className="num">{h.database.max_locks_per_transaction}</span>],
              ]} />
              <p className="px-5 pb-5 text-xs text-muted">{t('gl.health.locksNote')}</p>
            </SectionCard>
            <SectionCard title={t('gl.health.checks')}>
              <ul className="divide-y divide-line" data-testid="gl-health-checks">
                {h.checks.map((c) => (
                  <li key={c.key} className="px-5 py-3 text-sm" data-key={c.key} data-status={c.status}>
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="font-medium">{t(`gl.health.check.${c.key}`)}</span>
                      <span className={clsx('pill', toneOf(c.status))}>{c.status === 'ok' ? t('gl.health.ok') : t('gl.health.found', { n: c.count })}</span>
                    </div>
                    {c.items.length > 0 && <p className="mt-1 break-words font-mono text-[12px] text-muted" dir="ltr">{c.items.slice(0, 12).join(', ')}{c.items.length > 12 ? ' …' : ''}</p>}
                    {c.key === 'direct_write_grants' && c.count > 0 && <p className="mt-1 text-xs text-ink-2">{t('gl.health.grantsNote')}</p>}
                  </li>
                ))}
              </ul>
            </SectionCard>
          </div>
          <SectionCard title={t('gl.health.companies')}>
            <div className="overflow-x-auto">
              <table className="w-full text-[14px]" data-testid="gl-health-companies">
                <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className={th}>{t('gl.f.company')}</th>
                  <th scope="col" className={th}>{t('gl.health.lastLoad')}</th>
                  <th scope="col" className={th}>{t('gl.f.goLive')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end">{t('gl.health.checklist')}</th>
                  <th scope="col" className="px-4 py-2.5 text-end max-sm:hidden">{t('gl.issues')}</th>
                </tr></thead>
                <tbody>
                  {h.companies.map((c) => (
                    <tr key={c.company_code} className="border-t border-line">
                      <td className="px-4 py-2.5"><Link to={`/admin/go-live/${c.company_code}`} className="font-mono font-medium text-primary hover:underline">{c.company_code}</Link> <span className="text-muted max-md:hidden" dir="auto">{c.company_name}</span></td>
                      <td className="px-4 py-2.5">{c.last_sap_load ? when(c.last_sap_load) : '—'}</td>
                      <td className="px-4 py-2.5">{c.go_live_at ? fmtDay(c.go_live_at) : '—'}</td>
                      <td className="num px-4 py-2.5 text-end">{c.checklist_done} / 7</td>
                      <td className="num px-4 py-2.5 text-end max-sm:hidden">{c.open_issues}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SectionCard>
          <div className="grid gap-5 xl:grid-cols-2">
            <SectionCard title={t('gl.health.files')}>
              <div className="overflow-x-auto">
                <table className="w-full text-[14px]" data-testid="gl-health-files">
                  <thead><tr className="bg-surface-2 text-xs font-semibold uppercase tracking-wide text-muted">
                    <th scope="col" className={th}>{t('gl.health.file')}</th><th scope="col" className={clsx(th, 'max-sm:hidden')}>{t('gl.health.object')}</th><th scope="col" className={th}>{t('erp.col.status')}</th>
                  </tr></thead>
                  <tbody>
                    {h.files.map((f) => (
                      <tr key={f.file} className="border-t border-line">
                        <td className="px-4 py-2 font-mono text-[13px]" dir="ltr">{f.file}</td>
                        <td className="px-4 py-2 font-mono text-[12px] text-muted max-sm:hidden" dir="ltr">{f.object}</td>
                        <td className="px-4 py-2"><span className={clsx('pill', f.present ? 'pill-ok' : 'pill-crit')}>{f.present ? t('gl.health.present') : t('gl.health.missing')}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </SectionCard>
            <SectionCard title={t('gl.health.releases')}>
              {!h.releases.length ? <p className="p-5 text-sm text-muted">{t('gl.health.noReleases')}</p> : (
                <ul className="divide-y divide-line" data-testid="gl-health-releases">
                  {h.releases.map((r, i) => (
                    <li key={i} className="flex flex-wrap items-center justify-between gap-2 px-5 py-3 text-sm">
                      <span className="font-mono text-[13px]" dir="ltr">{r.file}</span>
                      <span className="pill pill-info">{r.environment}</span>
                      <span className="w-full text-xs text-muted" dir="auto">{r.applied_by} · {when(r.applied_at)}{r.note ? ` · ${r.note}` : ''}</span>
                    </li>
                  ))}
                </ul>
              )}
            </SectionCard>
          </div>
        </div>
      )}
    </AdminFrame>
  );
}
