import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Upload } from 'lucide-react';
import { useOpenIssues, useOverview, useReview } from '../queries';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { KeyNumber } from '../components/KeyNumber';
import { StatusPill, RunStatusPill, type Tone } from '../components/StatusPill';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { fmtCompact, fmtDate, fmtInt } from '@/lib/format';
import { qty } from '../check/derive';
import type { CompanyOverviewRow } from '@/lib/database.types';

const sevTone: Record<string, Tone> = { critical: 'critical', warning: 'warning', info: 'info' };
const linkBtn = 'inline-flex min-h-[44px] items-center gap-2 rounded-btn border border-line bg-surface px-4 font-medium hover:bg-page';

/** B5 Migration centre (design/B5-migration-centre.jpg). Data: erp.migration_company_overview. */
export function MigrationCentrePage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const overview = useOverview();
  const issues = useOpenIssues();
  const rows = useMemo(() => overview.data ?? [], [overview.data]);

  // companies with nothing yet are grouped into one "Waiting for IT" row, like the design
  const started = rows.filter((r) => r.latest_run_id || Number(r.tables_loaded) > 0);
  const waiting = rows.filter((r) => !r.latest_run_id && Number(r.tables_loaded) === 0);
  const loaded = rows.filter((r) => Number(r.tables_loaded) > 0);
  const sum = (f: (r: CompanyOverviewRow) => number) => rows.reduce((a, r) => a + f(r), 0);
  const checks = sum((r) => Number(r.checks));
  const failed = sum((r) => Number(r.checks_failed));
  const orphanCos = rows.filter((r) => Number(r.orphans) > 0).length;

  // the checks table shows one company: the first with a reviewable run (or the one picked)
  const reviewable = started.filter((r) => r.latest_status === 'needs_review' || r.latest_status === 'signed_off');
  const [picked, setPicked] = useState<string | null>(null);
  const focus = rows.find((r) => r.company_code === picked) ?? reviewable[0] ?? null;
  const focusReview = useReview(focus?.latest_status === 'needs_review' || focus?.latest_status === 'signed_off' ? focus.latest_run_id ?? undefined : undefined, 'app_tables');
  const focusChecks = (focusReview.data ?? []).filter((c) => c.item === 'check' && c.area === 'app_tables' && c.company_code === focus?.company_code);

  const latestRunning = started.find((r) => r.latest_status && !['needs_review', 'signed_off', 'failed', 'cancelled'].includes(r.latest_status));
  const openRun = (r: CompanyOverviewRow) => {
    setPicked(r.company_code);
    if (!r.latest_run_id) return nav(`/backoffice/migration/upload?company=${r.company_code}`);
    nav(`/backoffice/migration/runs/${r.latest_run_id}${r.latest_status === 'needs_review' || r.latest_status === 'signed_off' ? '/check' : ''}`);
  };

  const tableRows: Array<CompanyOverviewRow | { waiting: CompanyOverviewRow[] }> = [...started, ...(waiting.length ? [{ waiting }] : [])];
  const isWaiting = (r: (typeof tableRows)[number]): r is { waiting: CompanyOverviewRow[] } => 'waiting' in r;
  const dash = <StatusPill tone="neutral">—</StatusPill>;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="max-w-xl">
          <h1 className="text-[28px] font-semibold leading-tight">{t('migration.centre.title')}</h1>
          <p className="mt-1 text-[15px] text-muted">{t('migration.centre.subtitle')}</p>
          <Link to="/backoffice/migration/upload" className="mt-4 inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 font-medium text-white">
            <Upload className="h-4 w-4" aria-hidden /> {t('migration.centre.upload')}
          </Link>
        </div>
        <div className="flex flex-wrap gap-2">
          {latestRunning?.latest_run_id
            ? <Link className={linkBtn} to={`/backoffice/migration/runs/${latestRunning.latest_run_id}`}>{t('migration.centre.loadLog')}</Link>
            : started[0]?.latest_run_id && <Link className={linkBtn} to={`/backoffice/migration/runs/${started[0].latest_run_id}`}>{t('migration.centre.loadLog')}</Link>}
          {reviewable[0]?.latest_run_id && <Link className={linkBtn} to={`/backoffice/migration/runs/${reviewable[0].latest_run_id}/check`}>{t('migration.centre.crossCheck')}</Link>}
          <Link className={linkBtn} to={`/backoffice/migration/fields${focus ? `?company=${focus.company_code}` : ''}`}>{t('migration.fields.open')}</Link>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <KeyNumber label={t('migration.centre.companiesLoaded')} value={t('migration.centre.nOf', { a: loaded.length, b: rows.length || 12 })}
          note={t('migration.centre.companiesNote', { n: Math.max(0, (rows.length || 12) - loaded.length) })} />
        <KeyNumber label={t('migration.centre.tablesLoaded')} value={fmtInt(sum((r) => Number(r.tables_loaded)))} tone="ok" note={t('migration.centre.tablesNote', { n: loaded.length })} />
        <KeyNumber label={t('migration.centre.rowDiffs')} value={fmtInt(sum((r) => Number(r.row_count_differences)))} tone={sum((r) => Number(r.row_count_differences)) ? 'warning' : 'neutral'}
          note={rows.filter((r) => Number(r.row_count_differences) > 0).map((r) => r.company_code).join(', ') || undefined} />
        <KeyNumber label={t('migration.centre.orphans')} value={fmtInt(sum((r) => Number(r.orphans)))} tone={orphanCos ? 'critical' : 'neutral'} note={t('migration.centre.orphansNote', { n: orphanCos })} />
        <KeyNumber label={t('migration.centre.checksPassed')} value={t('migration.centre.nOf', { a: fmtInt(checks - failed), b: fmtInt(checks) })} note={t('migration.centre.checksNote', { n: failed })} />
      </div>

      <Card title={t('migration.centre.byCompany')}>
        {overview.isLoading ? <SkeletonRows /> : overview.error ? <ErrorState error={overview.error} onRetry={() => overview.refetch()} /> : (
          <DataTable
            caption={t('migration.centre.byCompany')}
            rows={tableRows}
            rowKey={(r) => (isWaiting(r) ? '__waiting' : r.company_code)}
            onRowClick={(r) => (isWaiting(r) ? nav(`/backoffice/migration/upload?company=${r.waiting[0].company_code}`) : openRun(r))}
            empty={<EmptyState body={t('migration.centre.noCompanies')} />}
            columns={[
              { key: 'c', header: t('migration.centre.colCompany'), cell: (r) => (isWaiting(r) ? r.waiting.map((w) => w.company_code).join(', ') : `${r.company_code} · ${r.company_name}`) },
              { key: 'db', header: t('migration.centre.colDb'), cell: (r) => (isWaiting(r) ? '—' : r.sap_schema) },
              { key: 'x', header: t('migration.centre.colExport'), cell: (r) => (isWaiting(r) ? <StatusPill tone="warning">{t('migration.centre.waitingIt')}</StatusPill>
                : !r.latest_status ? <span className="flex items-center gap-2"><StatusPill tone="ok">{t('migration.centre.loadedOn')}</StatusPill><span className="whitespace-nowrap text-xs text-muted">{fmtDate(r.last_loaded_at)}</span></span>
                : <span className="flex items-center gap-2"><RunStatusPill status={r.latest_status} /><span className="whitespace-nowrap text-xs text-muted">{fmtDate(r.latest_created_at)}</span></span>) },
              { key: 't', header: t('migration.centre.colTables'), align: 'end', cell: (r) => (isWaiting(r) ? '—' : fmtInt(r.tables_loaded)) },
              { key: 'r', header: t('migration.centre.colRows'), align: 'end', cell: (r) => (isWaiting(r) ? '—' : fmtCompact(Number(r.rows_loaded))) },
              { key: 'rc', header: t('migration.centre.colCounts'), cell: (r) => (isWaiting(r) || !Number(r.checks) ? dash
                : Number(r.row_count_differences) > 0 ? <StatusPill tone="warning">{t(Number(r.row_count_differences) === 1 ? 'migration.centre.diff' : 'migration.centre.diffs', { n: r.row_count_differences })}</StatusPill>
                : <StatusPill tone="ok">{t('migration.centre.match')}</StatusPill>) },
              { key: 'o', header: t('migration.centre.colOrphans'), cell: (r) => (isWaiting(r) || !Number(r.checks) ? dash : <StatusPill tone={Number(r.orphans) > 0 ? 'critical' : 'ok'}>{fmtInt(r.orphans)}</StatusPill>) },
              { key: 'a', header: t('migration.centre.colApp'), cell: (r) => (isWaiting(r) ? dash : !Number(r.app_checks) ? <StatusPill tone="neutral">{t('migration.centre.notRun')}</StatusPill>
                : <StatusPill tone={r.app_checks_ok === r.app_checks ? 'ok' : 'warning'}>{t('migration.centre.appOk', { a: r.app_checks_ok, b: r.app_checks })}</StatusPill>) },
              { key: 's', header: t('migration.centre.colSigned'), cell: (r) => (isWaiting(r) ? dash : r.go_live_at ? <StatusPill tone="ok">{t('migration.centre.live')}</StatusPill>
                : r.latest_status === 'signed_off' ? <StatusPill tone="ok">{t('migration.centre.signed')}</StatusPill>
                : r.latest_status === 'needs_review' ? <StatusPill tone="warning">{Number(r.signoffs_approved) ? t('migration.centre.signN', { n: r.signoffs_approved }) : t('migration.centre.waiting')}</StatusPill>
                : dash) },
            ]}
          />
        )}
      </Card>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)]">
        <Card title={t('migration.centre.checksTitle', { code: focus?.company_code ?? '—' })}>
          {focusReview.isLoading ? <SkeletonRows rows={4} /> : focusChecks.length === 0 ? <EmptyState body={t('migration.centre.noChecks')} /> : (
            <DataTable
              minWidth={360}
              rows={focusChecks}
              rowKey={(r) => r.id}
              columns={[
                { key: 'n', header: t('migration.centre.colCheck'), cell: (r) => r.name },
                { key: 's', header: t('migration.centre.colSap'), align: 'end', cell: (r) => qty(r.sap_value ?? r.raw_value) },
                { key: 'a', header: t('migration.centre.colAppV'), align: 'end', cell: (r) => qty(r.app_value) },
                { key: 'r', header: t('migration.centre.colResult'), cell: (r) => <StatusPill tone={r.ok ? 'ok' : 'critical'}>{r.ok ? t('migration.check.ok') : t('migration.check.rawAppDiffer')}</StatusPill> },
              ]}
            />
          )}
        </Card>

        <Card title={t('migration.centre.toFix')}>
          {issues.isLoading ? <SkeletonRows rows={3} /> : issues.error ? <ErrorState error={issues.error} /> : (issues.data ?? []).length === 0 ? <EmptyState /> : (
            <ul className="divide-y divide-line">
              {issues.data!.map((i) => (
                <li key={i.issue_id} className="flex items-start gap-3 px-5 py-3">
                  <StatusPill tone={sevTone[i.severity] ?? 'info'} className="mt-0.5">{t(`migration.check.area.${i.area}`, { defaultValue: i.area })}</StatusPill>
                  <div className="min-w-0 flex-1">
                    <div className="font-medium">{i.title}</div>
                    {i.detail && <div className="line-clamp-2 text-sm text-muted">{i.detail}</div>}
                  </div>
                  <Link to={`/backoffice/migration/runs/${i.run_id}/check`} className="inline-flex min-h-[40px] shrink-0 items-center rounded-btn border border-line px-3 text-sm font-medium hover:bg-page">
                    {t('migration.centre.openList')}
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </div>
  );
}
