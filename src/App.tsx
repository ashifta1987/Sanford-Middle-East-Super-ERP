import { Navigate, Route, Routes } from 'react-router-dom';
import { AppShell } from '@/layout/AppShell';
import { CompanyProvider } from '@/layout/CompanyContext';
import { LoginPage } from '@/auth/LoginPage';
import { RequireAccess } from '@/auth/RequireAccess';
import { NoAccessPage, PlaceholderPage } from '@/pages/SystemPages';
import { MigrationCentrePage } from '@/features/migration/pages/MigrationCentrePage';
import { UploadPage } from '@/features/migration/pages/UploadPage';
import { RunPage } from '@/features/migration/pages/RunPage';
import { CrossCheckPage } from '@/features/migration/pages/CrossCheckPage';
import { useAuth } from '@/auth/AuthProvider';

const modules: Array<[string, string]> = [
  ['my-hr', 'nav.myHr'], ['approvals', 'nav.approvals'], ['sales', 'nav.sales'], ['field', 'nav.field'],
  ['accountant', 'nav.accountant'], ['warehouses', 'nav.warehouses'], ['logistics', 'nav.logistics'],
  ['quality', 'nav.quality'], ['purchase', 'nav.purchase'], ['marketing', 'nav.marketing'], ['hr', 'nav.hr'],
];
const backOffice: Array<[string, string]> = [
  ['requests', 'tabs.requests'], ['licences', 'tabs.licences'], ['it', 'tabs.it'], ['sysadmin', 'tabs.sysadmin'],
];

function BackOfficeHome() {
  const { isMigrationAdmin } = useAuth();
  return <Navigate to={isMigrationAdmin ? '/backoffice/migration' : '/backoffice/requests'} replace />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        element={
          <RequireAccess access="signedIn">
            <CompanyProvider>
              <AppShell />
            </CompanyProvider>
          </RequireAccess>
        }
      >
        <Route index element={<PlaceholderPage nameKey="nav.dashboard" />} />
        {modules.map(([path, key]) => <Route key={path} path={path} element={<PlaceholderPage nameKey={key} />} />)}
        <Route path="backoffice" element={<BackOfficeHome />} />
        {backOffice.map(([path, key]) => <Route key={path} path={`backoffice/${path}`} element={<PlaceholderPage nameKey={key} />} />)}

        <Route path="backoffice/migration" element={<RequireAccess access="migrationAdmin"><MigrationCentrePage /></RequireAccess>} />
        <Route path="backoffice/migration/upload" element={<RequireAccess access="migrationAdmin"><UploadPage /></RequireAccess>} />
        <Route path="backoffice/migration/runs/:runId" element={<RequireAccess access="migrationAdmin"><RunPage /></RequireAccess>} />
        {/* Finance / CFO signers reach only this screen */}
        <Route path="backoffice/migration/runs/:runId/check" element={<RequireAccess access="migrationReviewer"><CrossCheckPage /></RequireAccess>} />

        <Route path="no-access" element={<NoAccessPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
