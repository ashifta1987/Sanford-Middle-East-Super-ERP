import { useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { PageHeader } from '../components/PageHeader';
import { Card } from '../components/Card';
import { DataTable } from '../components/DataTable';
import { StatusPill } from '../components/StatusPill';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import { useReview } from '../queries';
import { useRunRealtime } from '../useRunRealtime';

/** B8 Cross-check and sign-off — shell for P2 (review data wired). Full design in P5. */
export function CrossCheckPage() {
  const { t } = useTranslation();
  const { runId } = useParams();
  useRunRealtime(runId);
  const review = useReview(runId);
  const checks = (review.data ?? []).filter((r) => r.item === 'check');

  return (
    <div className="space-y-6">
      <PageHeader crumb={t('migration.check.breadcrumb')} title={t('migration.check.title')} />
      <Card title="Checks">
        {review.isLoading ? <SkeletonRows /> : review.error ? <ErrorState error={review.error} onRetry={() => review.refetch()} /> : (
          <DataTable
            rows={checks}
            rowKey={(r) => r.id}
            empty={<EmptyState />}
            columns={[
              { key: 'a', header: 'Area', cell: (r) => r.area },
              { key: 'n', header: 'Check', cell: (r) => r.name },
              { key: 's', header: 'SAP copy', align: 'end', cell: (r) => r.raw_value ?? '—' },
              { key: 'p', header: 'App', align: 'end', cell: (r) => r.app_value ?? '—' },
              { key: 'd', header: 'Difference', align: 'end', cell: (r) => r.difference ?? '—' },
              { key: 'r', header: 'Result', cell: (r) => <StatusPill tone={r.ok ? 'ok' : 'critical'}>{r.ok ? 'ok' : 'differs'}</StatusPill> },
            ]}
          />
        )}
      </Card>
    </div>
  );
}

