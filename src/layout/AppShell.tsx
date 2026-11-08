import { useState } from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Sidebar } from './Sidebar';
import { TopBar } from './TopBar';
import { ModuleTabs } from './ModuleTabs';

export function AppShell() {
  const { t } = useTranslation();
  const [menuOpen, setMenuOpen] = useState(false);
  const loc = useLocation();
  const inBackOffice = loc.pathname.startsWith('/backoffice');

  return (
    <div className="flex min-h-screen">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:start-2 focus:top-2 focus:z-50 focus:rounded-btn focus:bg-white focus:p-3">
        {t('app.skip')}
      </a>
      <Sidebar open={menuOpen} onClose={() => setMenuOpen(false)} />
      <div className="flex min-w-0 flex-1 flex-col">
        <TopBar onMenu={() => setMenuOpen(true)} />
        {inBackOffice && <ModuleTabs />}
        <main id="main" className="flex-1">
          <div className="mx-auto w-full max-w-content px-4 py-6 sm:px-7">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
