import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Upload } from 'lucide-react';
import { useOverview, useOpenIssues } from '../queries';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { KeyNumber } from '../components/KeyNumber';
import { StatusPill, RunStatusPill } from '../components/StatusPill';
import { Button } from '@/components/Button';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { fmtCompact, fmtDate, fmtInt } from '@/lib/format';
import type { CompanyOverviewRow } from '@/lib/database.types';

/** B5 Migration centre. Full layout lands in P6; P2 renders the data with loading and empty states. */
export function MigrationCentrePage() {
  const { t } = useTranslation();
  const nav = useNavigate();
  const overview = useOverview();
  const issues = useOpenIssues();
  const rows = overview.data ?? [];
  const loaded = rows.filter((r) => r.tables_loaded > 0);

  const openRun = (r: CompanyOverviewRow) => {
    if (!r.latest_run_id) return nav(`/backoffice/migration/upload?company=${r.company_code}`);
    nav(`/backoffice/migration/runs/${r.latest_run_id}${r.latest_status === 'needs_review' || r.latest_status === 'signed_off' ? '/check' : ''}`);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-[28px] font-semibold leading-tight">{t('migration.centre.title')}</h1>
          <p className="mt-1 max-w-xl text-[15px] text-muted">{t('migration.centre.subtitle')}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button>{t('migration.centre.loadLog')}</Button>
          <Button>{t('migration.centre.crossCheck')}</Button>
          <Link to="/backoffice/migration/upload" className="inline-flex min-h-[44px] items-center gap-2 rounded-btn bg-primary px-4 font-medium text-white">
            <Upload className="h-4 w-4" aria-hidden /> {t('migration.centre.upload')}
          </Link>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <KeyNumber label="Companies loaded" value={`${loaded.length} of ${rows.length || 12}`} />
        <KeyNumber label="Tables loaded" value={fmtInt(rows.reduce((a, r) => a + Number(r.tables_loaded), 0))} tone="ok" />
        <KeyNumber label="Row count differences" value={fmtInt(rows.reduce((a, r) => a + Number(r.row_count_differences), 0))} tone="warning" />
        <KeyNumber label="Orphan links" value={fmtInt(rows.reduce((a, r) => a + Number(r.orphans), 0))} tone="critical" />
        <KeyNumber
          label="Checks passed"
          value={`${fmtInt(rows.reduce((a, r) => a + (Number(r.checks) - Number(r.checks_failed)), 0))} of ${fmtInt(rows.reduce((a, r) => a + Number(r.checks), 0))}`}
        />
      </div>

      <Card title={t('migration.centre.byCompany')}>
        {overview.isLoading ? <SkeletonRows /> : overview.error ? <ErrorState error={overview.error} onRetry={() => overview.refetch()} /> : (
          <DataTable
            caption={t('migration.centre.byCompany')}
            rows={rows}
            rowKey={(r) => r.company_code}
            onRowClick={openRun}
            empty={<EmptyState body={t('migration.centre.noCompanies')} />}
            columns={[
              { key: 'c', header: 'Company', cell: (r) => <span>{r.company_code} · {r.company_name}</span> },
              { key: 'db', header: 'SAP database', cell: (r) => r.sap_schema },
              { key: 'run', header: 'Export', cell: (r) => r.latest_status
                ? <span className="flex items-center gap-2"><RunStatusPill status={r.latest_status} /><span className="text-xs text-muted">{fmtDate(r.latest_created_at)}</span></span>
                : <StatusPill tone="warning">Waiting for IT</StatusPill> },
              { key: 't', header: 'Tables', align: 'end', cell: (r) => fmtInt(r.tables_loaded) },
              { key: 'r', header: 'Rows', align: 'end', cell: (r) => fmtCompact(Number(r.rows_loaded)) },
              { key: 'rc', header: 'Row counts', cell: (r) => r.checks === 0 ? <StatusPill tone="neutral">—</StatusPill>
                : r.row_count_differences > 0 ? <StatusPill tone="warning">{r.row_count_differences} difference{r.row_count_differences > 1 ? 's' : ''}</StatusPill>
                : <StatusPill tone="ok">Match</StatusPill> },
              { key: 'o', header: 'Orphans', cell: (r) => <StatusPill tone={r.checks === 0 ? 'neutral' : r.orphans > 0 ? 'critical' : 'ok'}>{r.checks === 0 ? '—' : fmtInt(r.orphans)}</StatusPill> },
              { key: 'a', header: 'App checks', cell: (r) => r.app_checks === 0 ? <StatusPill tone="neutral">Not run</StatusPill>
                : <StatusPill tone={r.app_checks_ok === r.app_checks ? 'ok' : 'warning'}>{r.app_checks_ok} of {r.app_checks} ok</StatusPill> },
              { key: 's', header: 'Signed', cell: (r) => r.go_live_at ? <StatusPill tone="ok">Live</StatusPill>
                : r.latest_status === 'signed_off' ? <StatusPill tone="ok">Signed</StatusPill>
                : r.latest_status === 'needs_review' ? <StatusPill tone="warning">{r.signoffs_approved} of 3</StatusPill>
                : <StatusPill tone="neutral">—</StatusPill> },
            ]}
          />
        )}
      </Card>

      <Card title={t('migration.centre.toFix')}>
        {issues.isLoading ? <SkeletonRows rows={3} /> : issues.error ? <ErrorState error={issues.error} /> : (issues.data ?? []).length === 0 ? <EmptyState /> : (
          <ul className="divide-y divide-line">
            {issues.data!.map((i) => (
              <li key={i.issue_id} className="flex items-start gap-3 px-5 py-3">
                <StatusPill tone={i.severity === 'critical' ? 'critical' : i.severity === 'warning' ? 'warning' : 'info'}>{i.area}</StatusPill>
                <div>
                  <div className="font-medium">{i.title}</div>
                  {i.detail && <div className="text-sm text-muted">{i.detail}</div>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

