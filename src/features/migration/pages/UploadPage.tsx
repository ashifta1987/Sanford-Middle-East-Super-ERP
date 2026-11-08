import { useId } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { PageHeader } from '../components/PageHeader';
import { StepTracker } from '../components/StepTracker';
import { Card } from '../components/Card';
import { EmptyState, SkeletonRows } from '@/components/States';
import { useOverview } from '../queries';

/** B6 Upload backup — shell for P2. The upload flow is built in P3. */
export function UploadPage() {
  const { t } = useTranslation();
  const [params, setParams] = useSearchParams();
  const overview = useOverview();
  const company = params.get('company') ?? overview.data?.[0]?.company_code ?? '';
  const selId = useId();

  return (
    <div className="space-y-6">
      <PageHeader
        crumb={t('migration.upload.breadcrumb')}
        title={t('migration.upload.title')}
        subtitle={t('migration.upload.subtitle')}
        right={
          <div className="w-full sm:w-[360px]">
            <label htmlFor={selId} className="mb-1 block text-sm text-muted">{t('top.company')}</label>
            <select id={selId} className="input" value={company} onChange={(e) => setParams({ company: e.target.value })}>
              {(overview.data ?? []).map((c) => (
                <option key={c.company_code} value={c.company_code}>{c.company_code} · {c.company_name} · {c.sap_schema}</option>
              ))}
            </select>
          </div>
        }
      />
      <StepTracker current={0} steps={[{ state: 'action' }, { state: 'waiting' }, { state: 'waiting' }, { state: 'waiting' }, { state: 'waiting' }, { state: 'waiting' }]} />
      <Card title="Add files">
        {overview.isLoading ? <SkeletonRows rows={3} /> : <EmptyState body={t('migration.phase')} />}
      </Card>
    </div>
  );
}
