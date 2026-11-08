import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useAuth } from '@/auth/AuthProvider';
import type { ReactNode } from 'react';

export function PageHeader({ crumb, title, subtitle, right }: { crumb?: string; title: ReactNode; subtitle?: ReactNode; right?: ReactNode }) {
  const { t } = useTranslation();
  const { isMigrationAdmin } = useAuth();
  return (
    <div className="flex flex-wrap items-end justify-between gap-4">
      <div>
        {crumb && (
          <nav aria-label={t('tabs.migration')} className="mb-1 text-sm text-muted">
            {isMigrationAdmin ? <Link to="/backoffice/migration" className="text-primary underline">{t('tabs.migration')}</Link> : <span>{t('tabs.migration')}</span>}
            <span aria-hidden> › </span>
            <span>{crumb}</span>
          </nav>
        )}
        <h1 className="text-[28px] font-semibold leading-tight">{title}</h1>
        {subtitle && <p className="mt-1 text-[15px] text-muted">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}

