import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { X } from 'lucide-react';
import { PageHeader } from '../components/PageHeader';
import { Card } from '../components/Card';
import { KeyNumber } from '../components/KeyNumber';
import { RunStatusPill, StatusPill, StepStatusPill, runTone } from '../components/StatusPill';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { useRunRealtime } from '../useRunRealtime';
import { RUNNING, useCancelRun, useCompanyRuns, useOverview, useStatus } from '../queries';
import { errorMessage, fmtCompact, fmtDate, fmtDuration } from '@/lib/format';
import { STEP_ORDER } from '../steps';
import type { MigrationStatusRow, StepStatus } from '@/lib/database.types';

const STOPPABLE = ['uploading', ...RUNNING];

/** "61 of 83" in a step message → progress. */
function nOfM(msg: string | null): [number, number] | null {
  const m = msg?.match(/(\d[\d,]*)\s+of\s+(\d[\d,]*)/);
  if (!m) return null;
  const a = Number(m[1].replace(/,/g, '')), b = Number(m[2].replace(/,/g, ''));
  return b > 0 ? [a, b] : null;
}

const circle: Record<StepStatus, string> = {
  ok: 'bg-ok-fg text-white',
  warning: 'bg-[#8A3B00] text-white',
  running: 'bg-primary text-white',
  failed: 'bg-crit-fg text-white',
  skipped: 'bg-neutral-bg text-neutral-fg',
  pending: 'bg-neutral-bg text-neutral-fg',
};

const time = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { hour12: false });

/** B7 Rebuild run (design/B7-rebuild-run.jpg). Live through useRunRealtime. */
export function RunPage() {
  const { t } = useTranslation();
  const { runId } = useParams();
  const mode = useRunRealtime(runId);
  const status = useStatus(runId);
  const overview = useOverview();
  const rows = useMemo(() => status.data ?? [], [status.data]);
  const head = rows[0] as MigrationStatusRow | undefined;
  const runs = useCompanyRuns(head?.company_code);
  const cancel = useCancelRun();
  const [confirmStop, setConfirmStop] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const active = head ? RUNNING.includes(head.run_status) : false;

  useEffect(() => {
    if (!active) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [active]);

  // 12 rows in the worker's order, even before the worker has written them
  const steps = useMemo(() => {
    const by = new Map(rows.filter((r) => r.step_code).map((r) => [r.step_code!, r]));
    const extra = rows.filter((r) => r.step_code && !STEP_ORDER.includes(r.step_code));
    return [...STEP_ORDER.map((code, i) => by.get(code) ?? ({ step_no: i + 1, step_code: code, step_status: 'pending' } as MigrationStatusRow)), ...extra];
  }, [rows]);

  const log = useMemo(() => {
    const lines: Array<{ at: string; key: string; tag: string; text: string; tone: StepStatus }> = [];
    for (const s of rows) {
      if (!s.step_code) continue;
      const tag = s.step_code.replace(/_\d+$/, '');
      if (s.step_started_at) lines.push({ at: s.step_started_at, key: `${s.step_code}-s`, tag, text: t(`stepNames.${s.step_code}.name`, { defaultValue: s.step_code }) + ' · ' + t('migration.run.started'), tone: 'running' });
      if (s.step_finished_at) lines.push({ at: s.step_finished_at, key: `${s.step_code}-f`, tag, text: s.step_message || t('migration.run.finished'), tone: s.step_status ?? 'ok' });
      else if (s.step_status === 'running' && s.step_message) lines.push({ at: s.step_started_at ?? s.created_at, key: `${s.step_code}-m`, tag, text: s.step_message, tone: 'running' });
    }
    return lines.sort((a, b) => b.at.localeCompare(a.at));
  }, [rows, t]);

  if (status.isLoading) return <PageLoading />;
  if (status.error) return <ErrorState error={status.error} onRetry={() => status.refetch()} />;
  if (!head) return <EmptyState title={t('migration.run.notFound')} />;

  const code = head.company_code;
  const name = overview.data?.find((c) => c.company_code === code)?.company_name ?? '';
  const done = steps.filter((s) => s.step_status === 'ok' || s.step_status === 'warning').length;
  const running = steps.find((s) => s.step_status === 'running');
  const failed = steps.find((s) => s.step_status === 'failed');
  const rowsLoaded = Math.max(0, ...steps.filter((s) => s.step_code === 'stage' || s.step_code === 'cast').map((s) => Number(s.step_rows ?? 0)));
  const startMs = head.started_at ? new Date(head.started_at).getTime() : null;
  const endMs = head.finished_at ? new Date(head.finished_at).getTime() : now;
  const stopRequested = Boolean(head.stop_requested_at);
  const canStop = STOPPABLE.includes(head.run_status) && !stopRequested;
  const earlier = (runs.data ?? []).filter((r) => r.run_id !== head.run_id);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <PageHeader
          crumb={t('tabs.run')}
          title={t('migration.run.titleFull', { code, name })}
          subtitle={t('migration.run.note')}
        />
        <div className="flex flex-col items-end gap-1">
          <div className="flex items-center gap-2">
            <RunStatusPill status={head.run_status} />
            <Button
              variant="danger"
              disabled={!canStop || cancel.isPending}
              onClick={() => setConfirmStop(true)}
              title={!canStop && !stopRequested ? t('migration.run.stopNotRunning') : undefined}
            >
              {t('migration.run.stop')}
            </Button>
          </div>
          <span className="text-xs text-muted" aria-live="polite">
            {stopRequested ? t('migration.run.stopping') : active ? t(`migration.run.${mode}`) : ''}
          </span>
        </div>
      </div>

      {head.run_status === 'needs_review' && (
        <div className="card flex flex-wrap items-center justify-between gap-3 bg-warn-bg p-4">
          <span className="font-medium text-warn-fg">{t('migration.run.reviewBanner')}</span>
          <Link to={`/backoffice/migration/runs/${head.run_id}/check`} className="inline-flex min-h-[44px] items-center rounded-btn bg-primary px-4 font-medium text-white">
            {t('migration.run.openCheck')}
          </Link>
        </div>
      )}
      {head.run_status === 'failed' && (
        <div role="alert" className="card flex flex-wrap items-center justify-between gap-3 bg-crit-bg p-4">
          <div>
            <div className="font-semibold text-crit-fg">{t('migration.run.failedBanner', { step: failed ? t(`stepNames.${failed.step_code}.name`) : '—', code })}</div>
            {failed?.step_message && <div className="mt-1 line-clamp-3 font-mono text-xs text-crit-fg">{failed.step_message}</div>}
          </div>
          <Link to={`/backoffice/migration/runs/${head.run_id}/check`} className="inline-flex min-h-[44px] items-center rounded-btn border border-crit-fg/30 bg-surface px-4 font-medium text-crit-fg">
            {t('migration.run.seeIssue')}
          </Link>
        </div>
      )}
      {head.run_status === 'cancelled' && (
        <div className="card bg-neutral-bg p-4 font-medium text-neutral-fg">{t('migration.run.cancelledBanner', { code })}</div>
      )}
      {cancel.error && <p role="alert" className="card bg-crit-bg p-4 text-crit-fg">{errorMessage(cancel.error)}</p>}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <KeyNumber label={t('migration.run.stepsDone')} value={`${done} of ${steps.length}`}
          note={running ? t('migration.run.stepsDoneNote', { n: running.step_no }) : undefined} />
        <KeyNumber label={t('migration.run.rowsLoaded')} value={fmtCompact(rowsLoaded)} tone="ok"
          note={t('migration.run.rowsLoadedNote', { tables: head.tables_loaded.toLocaleString('en-US') })} />
        <KeyNumber label={head.finished_at ? t('migration.run.timeTotal') : t('migration.run.timeSoFar')}
          value={startMs ? fmtDuration((endMs - startMs) / 1000) : '—'}
          note={head.started_at ? t('migration.run.timeNote', { time: `${fmtDate(head.started_at)} ${time(head.started_at).slice(0, 5)}` }) : undefined} />
        <KeyNumber label={t('migration.run.notes')} value={String(head.warning_open)} tone={head.warning_open ? 'warning' : 'neutral'}
          note={t('migration.run.notesNote', { critical: head.critical_open, info: head.info_open })} />
      </div>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
        <Card title={t('migration.run.steps')} actions={<span className="text-sm text-muted">{t('migration.run.stepsCaption')}</span>}>
          <ol>
            {steps.map((s) => {
              const st = (s.step_status ?? 'pending') as StepStatus;
              const prog = st === 'running' ? nOfM(s.step_message) : null;
              const secs = st === 'running' && s.step_started_at ? (now - new Date(s.step_started_at).getTime()) / 1000 : s.step_seconds;
              return (
                <li key={s.step_code} className="grid grid-cols-[36px_minmax(0,1fr)_auto] gap-x-3 gap-y-1 border-b border-line px-5 py-3 last:border-0 sm:grid-cols-[36px_minmax(0,1fr)_110px_70px_120px]">
                  <span className={clsx('grid h-8 w-8 place-items-center rounded-full text-sm font-semibold', circle[st])} aria-hidden>
                    {st === "failed" ? <X className="h-4 w-4" /> : s.step_no}
                  </span>
                  <div className="min-w-0">
                    <div className="font-medium">{t(`stepNames.${s.step_code}.name`, { defaultValue: s.step_code ?? '' })}</div>
                    <div className="text-sm text-muted">
                      {s.step_message && st !== 'pending' && !prog ? s.step_message : t(`stepNames.${s.step_code}.desc`, { defaultValue: '' })}
                    </div>
                    {st === 'running' && (
                      <div className="mt-2 flex items-center gap-3">
                        {prog ? (
                          <>
                            <div role="progressbar" aria-valuemin={0} aria-valuemax={prog[1]} aria-valuenow={prog[0]} aria-label={t(`stepNames.${s.step_code}.name`)}
                              className="h-2 flex-1 overflow-hidden rounded-full bg-neutral-bg">
                              <div className="h-full bg-primary" style={{ width: `${(prog[0] / prog[1]) * 100}%` }} />
                            </div>
                            <span className="num text-sm font-medium text-primary">{prog[0].toLocaleString('en-US')} of {prog[1].toLocaleString('en-US')}</span>
                          </>
                        ) : (
                          <div role="progressbar" aria-label={t(`stepNames.${s.step_code}.name`)} className="relative h-2 flex-1 overflow-hidden rounded-full bg-neutral-bg">
                            <div className="bar-indeterminate rounded-full bg-primary" />
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                  {/* on phones rows/time go under the pill */}
                  <div className="num col-start-2 text-sm text-muted sm:col-start-auto sm:text-end sm:text-[15px] sm:text-ink">{s.step_rows != null ? fmtCompact(Number(s.step_rows)) : st === 'pending' ? '' : '—'}</div>
                  <div className="num col-start-2 text-sm text-muted sm:col-start-auto sm:text-end sm:text-[15px] sm:text-ink">{secs != null && st !== 'pending' ? fmtDuration(secs) : ''}</div>
                  <div className="col-start-3 row-start-1 sm:col-start-auto sm:row-start-auto sm:text-end">
                    <StepStatusPill status={st} />
                  </div>
                </li>
              );
            })}
          </ol>
        </Card>

        <div className="min-w-0 space-y-6">
          <section className="overflow-hidden rounded-card bg-[#16191F] text-[#D7DCE5]" aria-labelledby="live-log">
            <header className="flex items-center justify-between border-b border-white/10 px-5 py-3">
              <h2 id="live-log" className="font-semibold text-white">{t('migration.run.log')}</h2>
              <span className="text-xs text-[#9AA3B2]">{t('migration.run.newest')}</span>
            </header>
            <ol dir="ltr" className="max-h-[360px] space-y-1 overflow-y-auto px-5 py-4 text-start font-mono text-[13px] leading-relaxed" aria-live="polite">
              {log.length === 0 && <li className="text-[#9AA3B2]">{t('migration.run.logEmpty')}</li>}
              {log.map((l) => (
                <li key={l.key} className="grid grid-cols-[72px_minmax(0,1fr)] gap-2">
                  <time dateTime={l.at} className="text-[#9AA3B2]">{time(l.at)}</time>
                  <span className={clsx(
                    l.tone === 'failed' ? 'text-[#FF9C9C]' : l.tone === 'warning' ? 'text-[#F5C27A]' : l.tone === 'running' ? 'text-[#8DB4FF]' : 'text-[#9BE3B0]',
                  )}>
                    {l.tag} · {l.text}
                  </span>
                </li>
              ))}
            </ol>
          </section>

          <section className="card p-5">
            <h2 className="text-[17px] font-semibold">{t('migration.run.safeTitle')}</h2>
            <p className="mt-2 text-[15px] text-muted">{t('migration.run.safe1', { code })}</p>
            <p className="mt-2 text-[15px] text-muted">{t('migration.run.safe2', { code })}</p>
          </section>

          <Card title={t('migration.run.earlier')}>
            {earlier.length === 0 ? <p className="px-5 py-4 text-sm text-muted">{t('migration.run.noEarlier')}</p> : (
              <ul className="divide-y divide-line">
                {earlier.map((r) => (
                  <li key={r.run_id}>
                    <Link to={`/backoffice/migration/runs/${r.run_id}${r.status === 'needs_review' || r.status === 'signed_off' ? '/check' : ''}`}
                      className="flex min-h-[56px] items-center justify-between gap-3 px-5 py-3 hover:bg-page">
                      <div className="min-w-0">
                        <div className="font-medium">{t(`migration.run.kind.${r.kind}`)}</div>
                        <div className="text-sm text-muted">
                          {fmtDate(r.created_at)}
                          {r.started_at && r.finished_at ? ` · ${fmtDuration((new Date(r.finished_at).getTime() - new Date(r.started_at).getTime()) / 1000)}` : ''}
                          {r.notes ? ` · ${r.notes}` : ''}
                        </div>
                      </div>
                      <StatusPill tone={runTone(r.status)}>{t(`status.${r.status}`)}</StatusPill>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
      </div>

      <ConfirmDialog
        open={confirmStop}
        title={t('migration.run.stopTitle')}
        body={t('migration.run.stopBody', { code })}
        confirmLabel={t('migration.run.stop')}
        tone="danger"
        busy={cancel.isPending}
        error={cancel.error ? errorMessage(cancel.error) : null}
        onConfirm={() => cancel.mutate(head.run_id, { onSuccess: () => setConfirmStop(false) })}
        onClose={() => setConfirmStop(false)}
      />
    </div>
  );
}
