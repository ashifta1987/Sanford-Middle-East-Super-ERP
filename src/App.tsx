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
import {
  AtpCheckPage, AtpRulesPage, CreditMemoNewPage, DeliveryNewPage, InvoiceNewPage, SalesDocPage, SalesPrintPage,
} from '@/features/erp/pages/SalesCyclePages';
import { JournalDraftPage, JournalDraftsPage, JournalNewPage } from '@/features/erp/pages/JournalPages';
import { GlDeterminationPage, PostingPeriodsPage } from '@/features/erp/pages/FinanceSetupPages';
import { PaymentDetailPage, PaymentDraftPage, PaymentDraftsPage, PaymentNewPage } from '@/features/erp/pages/BankingPages';
import {
  BankingSetupPage, BpBankAccountsPage, CashPositionPage, DepositNewPage, DepositsPage, StatementPage, StatementsPage,
} from '@/features/erp/pages/BankingMorePages';
import {
  ApInvoiceNewPage, GrpoNewPage, LandedCostNewPage, LandedCostPage, LandedCostsPage, PurchaseDocEditPage, PurchaseDocNewPage, PurchaseDocPage,
  PurchaseViewPage, PurchasingSetupPage, QuotationComparePage,
} from '@/features/erp/pages/PurchasingPages';
import {
  CountNewPage, CountPage, CountsPage, InvDocPage, InventorySetupPage, LotPage, LotsPage, StockDocNewPage, TransferNewPage,
} from '@/features/erp/pages/InventoryPages';

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
      {/* A4 · Print / PDF: a clean A4 page without the app shell */}
      <Route path="/print/:kind/:company/:entry" element={<RequireAccess access="signedIn"><SalesPrintPage /></RequireAccess>} />
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
        {/* A4 · sales cycle */}
        <Route path="docs/sales_quotation/new" element={<SalesOrderNewPage kind="sales_quotation" />} />
        <Route path="docs/sales_quotation/:company/:entry" element={<SalesOrderDetailPage kind="sales_quotation" />} />
        <Route path="docs/sales_quotation/:company/:entry/edit" element={<SalesOrderEditPage kind="sales_quotation" />} />
        <Route path="docs/delivery/new" element={<DeliveryNewPage />} />
        <Route path="docs/delivery/:company/:entry" element={<SalesDocPage key="delivery" kind="delivery" />} />
        <Route path="docs/ar_invoice/new" element={<InvoiceNewPage />} />
        <Route path="docs/ar_invoice/:company/:entry" element={<SalesDocPage key="ar_invoice" kind="ar_invoice" />} />
        <Route path="docs/ar_credit_note/new" element={<CreditMemoNewPage />} />
        <Route path="docs/ar_credit_note/:company/:entry" element={<SalesDocPage key="ar_credit_note" kind="ar_credit_note" />} />
        <Route path="sales/atp" element={<AtpCheckPage />} />
        <Route path="sales/atp-rules" element={<AtpRulesPage />} />
        {/* A6 · purchasing, China flow */}
        {(['purchase_request', 'purchase_quotation', 'purchase_order'] as const).map((k) => [
          <Route key={`${k}-new`} path={`docs/${k}/new`} element={<PurchaseDocNewPage key={`${k}-new`} kind={k} />} />,
          <Route key={`${k}-view`} path={`docs/${k}/:company/:entry`} element={<PurchaseDocPage key={k} kind={k} />} />,
          <Route key={`${k}-edit`} path={`docs/${k}/:company/:entry/edit`} element={<PurchaseDocEditPage key={`${k}-edit`} kind={k} />} />,
        ])}
        {(['goods_receipt_po', 'ap_down_payment', 'ap_invoice'] as const).map((k) => (
          <Route key={`${k}-view`} path={`docs/${k}/:company/:entry`} element={<PurchaseViewPage key={k} kind={k} />} />
        ))}
        <Route path="purchasing/compare/:company/:request" element={<QuotationComparePage />} />
        <Route path="purchasing/grpo/new" element={<GrpoNewPage />} />
        <Route path="purchasing/ap-invoice/new" element={<ApInvoiceNewPage />} />
        <Route path="purchasing/landed-costs" element={<LandedCostsPage />} />
        <Route path="purchasing/landed-costs/new" element={<LandedCostNewPage />} />
        <Route path="purchasing/landed-costs/:company/:entry" element={<LandedCostPage />} />
        <Route path="purchasing/setup" element={<PurchasingSetupPage />} />
        {/* A7 · inventory transactions, counting, batches / serials, bins */}
        {(['goods_receipt', 'goods_issue', 'transfer_request', 'inventory_transfer'] as const).map((k) => (
          <Route key={`${k}-inv`} path={`docs/${k}/:company/:entry`} element={<InvDocPage key={k} kind={k} />} />
        ))}
        <Route path="inventory/goods-receipt/new" element={<StockDocNewPage key="gr" kind="goods_receipt" />} />
        <Route path="inventory/goods-issue/new" element={<StockDocNewPage key="gi" kind="goods_issue" />} />
        <Route path="inventory/transfer-request/new" element={<TransferNewPage key="trq" kind="transfer_request" />} />
        <Route path="inventory/transfer/new" element={<TransferNewPage key="tr" kind="inventory_transfer" />} />
        <Route path="inventory/counts" element={<CountsPage />} />
        <Route path="inventory/counts/new" element={<CountNewPage />} />
        <Route path="inventory/counts/:company/:id" element={<CountPage />} />
        <Route path="inventory/batches" element={<LotsPage key="B" kind="B" />} />
        <Route path="inventory/serials" element={<LotsPage key="S" kind="S" />} />
        <Route path="inventory/lots/:company/:id" element={<LotPage />} />
        <Route path="inventory/setup" element={<InventorySetupPage />} />
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
        {/* A5 · banking: payments with approval, deposits, bank statements, cash position, bank details, setup */}
        <Route path="banking/payments/:dir/new" element={<PaymentNewPage />} />
        <Route path="banking/payments/:dir/:company/:entry" element={<PaymentDetailPage />} />
        <Route path="banking/payment-drafts" element={<PaymentDraftsPage />} />
        <Route path="banking/payment-drafts/:company/:id" element={<PaymentDraftPage />} />
        <Route path="banking/deposits" element={<DepositsPage />} />
        <Route path="banking/deposits/new" element={<DepositNewPage />} />
        <Route path="banking/statements" element={<StatementsPage />} />
        <Route path="banking/statements/:company/:id" element={<StatementPage />} />
        <Route path="banking/cash-position" element={<CashPositionPage />} />
        <Route path="banking/bp-bank-accounts" element={<BpBankAccountsPage />} />
        <Route path="banking/setup" element={<BankingSetupPage />} />
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
