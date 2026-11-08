import { useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { PageHeader } from '../components/PageHeader';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { RunStatusPill, StepStatusPill } from '../components/StatusPill';
import { EmptyState, ErrorState, PageLoading } from '@/components/States';
import { useRunRealtime } from '../useRunRealtime';
import { useStatus } from '../queries';
import { fmtDuration, fmtInt } from '@/lib/format';
import { STEP_NAMES } from '../steps';

/** B7 Rebuild run — shell for P2 (live data wired). Full design in P4. */
export function RunPage() {
  const { t } = useTranslation();
  const { runId } = useParams();
  const mode = useRunRealtime(runId);
  const status = useStatus(runId);

  if (status.isLoading) return <PageLoading />;
  if (status.error) return <ErrorState error={status.error} onRetry={() => status.refetch()} />;
  const rows = status.data ?? [];
  if (!rows.length) return <EmptyState title={t('migration.run.notFound')} />;
  const head = rows[0];

  return (
    <div className="space-y-6">
      <PageHeader
        crumb={t('tabs.run')}
        title={`${t('migration.run.title')} · ${head.company_code}`}
        subtitle={t('migration.run.note')}
        right={<div className="flex items-center gap-2"><RunStatusPill status={head.run_status} /><span className="text-xs text-muted">{mode}</span></div>}
      />
      <Card title="Steps">
        <DataTable
          rows={rows.filter((r) => r.step_no !== null)}
          rowKey={(r) => r.step_no!}
          columns={[
            { key: 'n', header: '#', cell: (r) => r.step_no },
            { key: 'name', header: 'Step', cell: (r) => <div><div className="font-medium">{STEP_NAMES[r.step_code ?? '']?.name ?? r.step_code}</div><div className="text-sm text-muted">{r.step_message}</div></div> },
            { key: 'rows', header: 'Rows', align: 'end', cell: (r) => fmtInt(r.step_rows) },
            { key: 'time', header: 'Time', align: 'end', cell: (r) => fmtDuration(r.step_seconds) },
            { key: 's', header: 'Status', cell: (r) => <StepStatusPill status={r.step_status} /> },
          ]}
          empty={<EmptyState />}
        />
      </Card>
    </div>
  );
}

