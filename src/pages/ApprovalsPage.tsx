import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { erp } from '@/lib/supabase';
import { ApiError, fmtDate } from '@/lib/format';
import { Card } from '@/features/migration/components/Card';
import { StatusPill, RunStatusPill } from '@/features/migration/components/StatusPill';
import { EmptyState, ErrorState, SkeletonRows } from '@/components/States';
import type { RunStatus } from '@/lib/database.types';

interface InboxRow {
  run_id: string; company_code: string; company_name: string; kind: string; status: RunStatus; finished_at: string | null;
  critical_open: number; warning_open: number; signoffs: Array<{ role: string; decision: string }>; my_roles: string[]; waiting_for_me: boolean; live: boolean;
}

/** Approvals inbox: sign-off users reach B8 from here (erp.migration_inbox, 14_signoff_inbox.sql). */
export function ApprovalsPage() {
  const { t } = useTranslation();
  const q = useQuery({
    queryKey: ['migration', 'inbox'],
    queryFn: async () => {
      const { data, error } = await erp().rpc('migration_inbox');
      if (error) throw new ApiError(error);
      return (data ?? []) as InboxRow[];
    },
    refetchInterval: 30_000,
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-[28px] font-semibold">{t('inbox.title')}</h1>
        <p className="mt-1 text-[15px] text-muted">{t('inbox.subtitle')}</p>
      </div>
      <Card>
        {q.isLoading ? <SkeletonRows rows={3} /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !q.data?.length ? <EmptyState title={t('inbox.empty')} /> : (
          <ul className="divide-y divide-line">
            {q.data.map((r) => {
              const approved = r.signoffs.filter((s) => s.decision === 'approved').length;
              return (
                <li key={r.run_id} className="flex flex-wrap items-center gap-3 px-5 py-4">
                  <div className="min-w-0 flex-1">
                    <div className="font-semibold">{r.company_code} · {r.company_name}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-muted">
                      <RunStatusPill status={r.status} />
                      <span>{fmtDate(r.finished_at)}</span>
                      <span>· {t('inbox.signed', { n: approved })}</span>
                      {r.critical_open > 0 && <StatusPill tone="critical">{t('inbox.critical', { n: r.critical_open })}</StatusPill>}
                    </div>
                  </div>
                  {r.live ? <StatusPill tone="ok">{t('inbox.live')}</StatusPill>
                    : r.waiting_for_me ? <StatusPill tone="warning">{t('inbox.waitingYou')}</StatusPill>
                    : <StatusPill tone="neutral">{t('inbox.done')}</StatusPill>}
                  <Link to={`/backoffice/migration/runs/${r.run_id}/check`} className="inline-flex min-h-[44px] items-center rounded-btn bg-primary px-4 font-medium text-white">
                    {t('inbox.open')}
                  </Link>
                </li>
              );
            })}
          </ul>
        )}
      </Card>
    </div>
  );
}
