import { Navigate, Route, Routes, useParams } from 'react-router-dom';
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
import { ApprovalsPage } from '@/pages/ApprovalsPage';
import { ControlTowerPage, HomePage, ModulePage, SearchPage } from '@/features/erp/pages/HomePages';
import { PreviewPage } from '@/features/erp/pages/PreviewPage';
import {
  AccountsPage, BusinessPartnersPage, DocumentsPage, EmployeesPage, ItemsPage, JournalsPage, PaymentsPage, PricesPage, StockPage,
} from '@/features/erp/pages/ListPages';
import { BusinessPartnerDetail, DocumentDetail, ItemDetail, JournalDetail } from '@/features/erp/pages/DetailPages';
import { SalesOrderDetailPage, SalesOrderEditPage, SalesOrderNewPage } from '@/features/erp/pages/SalesOrderPages';
import { JournalDraftPage, JournalDraftsPage, JournalNewPage } from '@/features/erp/pages/JournalPages';
import { GlDeterminationPage, PostingPeriodsPage } from '@/features/erp/pages/FinanceSetupPages';

// Paths from the first app shell, kept so old links and bookmarks still land somewhere sensible.
const legacy: Array<[string, string]> = [
  ['sales', '/m/sales'], ['purchase', '/m/purchasing'], ['accountant', '/m/financials'], ['warehouses', '/m/inventory'],
  ['hr', '/m/hr'], ['my-hr', '/'], ['field', '/'], ['logistics', '/'], ['quality', '/'], ['marketing', '/'],
];
const backOffice: Array<[string, string]> = [
  ['requests', 'tabs.requests'], ['licences', 'tabs.licences'], ['it', 'tabs.it'], ['sysadmin', 'tabs.sysadmin'],
];

function BackOfficeHome() {
  const { isMigrationAdmin } = useAuth();
  return <Navigate to={isMigrationAdmin ? '/backoffice/migration' : '/backoffice/requests'} replace />;
}
function ModuleRoute() {
  const { key = '' } = useParams();
  return <ModulePage key={key} moduleKey={key} />;
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
        <Route index element={<HomePage />} />
        <Route path="m/:key" element={<ModuleRoute />} />
        <Route path="preview/:key" element={<PreviewPage />} />
        <Route path="search" element={<SearchPage />} />
        <Route path="control" element={<ControlTowerPage />} />

        {/* Working screens on live data (Stage 1: read, search, filter, export) */}
        <Route path="bp" element={<BusinessPartnersPage />} />
        <Route path="bp/:company/:code" element={<BusinessPartnerDetail />} />
        <Route path="items" element={<ItemsPage />} />
        <Route path="items/:company/:code" element={<ItemDetail />} />
        <Route path="inventory/stock" element={<StockPage />} />
        <Route path="inventory/prices" element={<PricesPage />} />
        {/* A2: sales order document form (new, view for SAP + ERP orders, edit drafts) */}
        <Route path="docs/sales_order/new" element={<SalesOrderNewPage />} />
        <Route path="docs/sales_order/:company/:entry" element={<SalesOrderDetailPage />} />
        <Route path="docs/sales_order/:company/:entry/edit" element={<SalesOrderEditPage />} />
        <Route path="docs/:kind" element={<DocumentsPage />} />
        <Route path="docs/:kind/:company/:entry" element={<DocumentDetail />} />
        <Route path="financials/accounts" element={<AccountsPage />} />
        <Route path="financials/journals" element={<JournalsPage />} />
        {/* A3: manual journals, drafts and approvals, G/L account determination, posting periods */}
        <Route path="financials/journals/new" element={<JournalNewPage />} />
        <Route path="financials/journals/drafts" element={<JournalDraftsPage />} />
        <Route path="financials/journals/drafts/:company/:id" element={<JournalDraftPage />} />
        <Route path="financials/gl-determination" element={<GlDeterminationPage />} />
        <Route path="financials/periods" element={<PostingPeriodsPage />} />
        <Route path="financials/journals/:company/:id" element={<JournalDetail />} />
        <Route path="banking/payments/:dir" element={<PaymentsPage />} />
        <Route path="hr/employees" element={<EmployeesPage />} />

        {legacy.map(([from, to]) => <Route key={from} path={from} element={<Navigate to={to} replace />} />)}
        <Route path="approvals" element={<ApprovalsPage />} />
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
