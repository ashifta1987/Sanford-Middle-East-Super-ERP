import { NavLink, useLocation, useMatch } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import clsx from 'clsx';
import { useAuth } from '@/auth/AuthProvider';

/** Back office module tabs (design/B6 tab row). Migration tabs only for admin/IT. */
export function ModuleTabs() {
  const { t } = useTranslation();
  const { isMigrationAdmin } = useAuth();
  const loc = useLocation();
  const runMatch = useMatch('/backoffice/migration/runs/:runId/*');
  const runId = runMatch?.params.runId ?? sessionStorage.getItem('lastRunId') ?? undefined;
  if (runMatch?.params.runId) sessionStorage.setItem('lastRunId', runMatch.params.runId);

  const tabs: Array<{ to: string; label: string; active: boolean; show: boolean }> = [
    { to: '/backoffice/requests', label: t('tabs.requests'), active: loc.pathname === '/backoffice/requests', show: true },
    { to: '/backoffice/licences', label: t('tabs.licences'), active: loc.pathname === '/backoffice/licences', show: true },
    { to: '/backoffice/it', label: t('tabs.it'), active: loc.pathname === '/backoffice/it', show: true },
    { to: '/backoffice/sysadmin', label: t('tabs.sysadmin'), active: loc.pathname === '/backoffice/sysadmin', show: true },
    { to: '/backoffice/migration', label: t('tabs.migration'), active: loc.pathname === '/backoffice/migration', show: isMigrationAdmin },
    { to: '/backoffice/migration/upload', label: t('tabs.upload'), active: loc.pathname.startsWith('/backoffice/migration/upload'), show: isMigrationAdmin },
    {
      to: runId ? `/backoffice/migration/runs/${runId}` : '/backoffice/migration',
      label: t('tabs.run'),
      active: Boolean(runMatch) && !loc.pathname.endsWith('/check'),
      show: isMigrationAdmin,
    },
    {
      to: runId ? `/backoffice/migration/runs/${runId}/check` : '/backoffice/migration',
      label: t('tabs.check'),
      active: loc.pathname.endsWith('/check'),
      show: isMigrationAdmin,
    },
  ];

  return (
    <div className="flex items-center border-b border-line bg-surface px-4 lg:px-6">
      <nav aria-label={t('nav.backoffice')} className="-mb-px flex flex-1 gap-1 overflow-x-auto">
        {tabs.filter((x) => x.show).map((tab) => (
          <NavLink
            key={tab.label}
            to={tab.to}
            aria-current={tab.active ? 'page' : undefined}
            className={clsx(
              'flex min-h-[48px] items-center whitespace-nowrap border-b-2 px-3 text-[15px]',
              tab.active ? 'border-primary font-medium text-primary' : 'border-transparent text-ink hover:text-primary',
            )}
          >
            {tab.label}
          </NavLink>
        ))}
      </nav>
      <span className="ms-4 hidden whitespace-nowrap text-xs text-muted 2xl:block">{t('tabs.caption')}</span>
    </div>
  );
}

