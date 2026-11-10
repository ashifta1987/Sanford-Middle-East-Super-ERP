import { Suspense, lazy, type ComponentType, type LazyExoticComponent } from 'react';
import { Navigate, Route, Routes, useLocation, useParams } from 'react-router-dom';
import { AppShell } from '@/layout/AppShell';
import { CompanyProvider } from '@/layout/CompanyContext';
import { LoginPage } from '@/auth/LoginPage';
import { RequireAccess } from '@/auth/RequireAccess';
import { NoAccessPage, PlaceholderPage } from '@/pages/SystemPages';
import { PageLoading } from '@/components/States';
import { useAuth } from '@/auth/AuthProvider';
import { ControlTowerPage, HomePage, ModulePage, SearchPage } from '@/features/erp/pages/HomePages';

// A14 · route-level code splitting: each page module is its own chunk, loaded when its route opens, so the first load only
// carries the shell, sign-in and Home. (The PDF and Excel libraries were already split out with dynamic imports.)
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyComponent = ComponentType<any>;
function from<M extends Record<string, unknown>>(load: () => Promise<M>) {
  return <K extends keyof M & string>(...names: K[]) =>
    Object.fromEntries(names.map((n) => [n, lazy(() => load().then((m) => ({ default: m[n] as Extract<M[K], AnyComponent> })))])) as
      { [P in K]: LazyExoticComponent<Extract<M[P], AnyComponent>> };
}

const P_MigrationCentrePage = from(() => import('@/features/migration/pages/MigrationCentrePage'));
const { MigrationCentrePage } = P_MigrationCentrePage('MigrationCentrePage');
const P_UploadPage = from(() => import('@/features/migration/pages/UploadPage'));
const { UploadPage } = P_UploadPage('UploadPage');
const P_RunPage = from(() => import('@/features/migration/pages/RunPage'));
const { RunPage } = P_RunPage('RunPage');
const P_CrossCheckPage = from(() => import('@/features/migration/pages/CrossCheckPage'));
const { CrossCheckPage } = P_CrossCheckPage('CrossCheckPage');
const P_CustomFieldsPage = from(() => import('@/features/migration/pages/CustomFieldsPage'));
const { CustomFieldsPage } = P_CustomFieldsPage('CustomFieldsPage');
const P_SpecialPricePages = from(() => import('@/features/erp/pages/SpecialPricePages'));
const { DiscountGroupsPage, SpecialPricesPage } = P_SpecialPricePages('DiscountGroupsPage', 'SpecialPricesPage');
const P_ApprovalsPage = from(() => import('@/pages/ApprovalsPage'));
const { ApprovalsPage } = P_ApprovalsPage('ApprovalsPage');
const P_PreviewPage = from(() => import('@/features/erp/pages/PreviewPage'));
const { PreviewPage } = P_PreviewPage('PreviewPage');
const P_ListPages = from(() => import('@/features/erp/pages/ListPages'));
const { AccountsPage, BusinessPartnersPage, DocumentsPage, EmployeesPage, ItemsPage, JournalsPage, PaymentsPage, PricesPage, StockPage } = P_ListPages('AccountsPage', 'BusinessPartnersPage', 'DocumentsPage', 'EmployeesPage', 'ItemsPage', 'JournalsPage', 'PaymentsPage', 'PricesPage', 'StockPage');
const P_DetailPages = from(() => import('@/features/erp/pages/DetailPages'));
const { BusinessPartnerDetail, DocumentDetail, ItemDetail, JournalDetail } = P_DetailPages('BusinessPartnerDetail', 'DocumentDetail', 'ItemDetail', 'JournalDetail');
const P_SalesOrderPages = from(() => import('@/features/erp/pages/SalesOrderPages'));
const { SalesOrderDetailPage, SalesOrderEditPage, SalesOrderNewPage } = P_SalesOrderPages('SalesOrderDetailPage', 'SalesOrderEditPage', 'SalesOrderNewPage');
const P_SalesCyclePages = from(() => import('@/features/erp/pages/SalesCyclePages'));
const { AtpCheckPage, AtpRulesPage, CreditMemoNewPage, DeliveryNewPage, InvoiceNewPage, SalesDocPage, SalesPrintPage } = P_SalesCyclePages('AtpCheckPage', 'AtpRulesPage', 'CreditMemoNewPage', 'DeliveryNewPage', 'InvoiceNewPage', 'SalesDocPage', 'SalesPrintPage');
const P_JournalPages = from(() => import('@/features/erp/pages/JournalPages'));
const { JournalDraftPage, JournalDraftsPage, JournalNewPage } = P_JournalPages('JournalDraftPage', 'JournalDraftsPage', 'JournalNewPage');
const P_FinanceSetupPages = from(() => import('@/features/erp/pages/FinanceSetupPages'));
const { GlDeterminationPage, PostingPeriodsPage } = P_FinanceSetupPages('GlDeterminationPage', 'PostingPeriodsPage');
const P_BankingPages = from(() => import('@/features/erp/pages/BankingPages'));
const { PaymentDetailPage, PaymentDraftPage, PaymentDraftsPage, PaymentNewPage } = P_BankingPages('PaymentDetailPage', 'PaymentDraftPage', 'PaymentDraftsPage', 'PaymentNewPage');
const P_BankingMorePages = from(() => import('@/features/erp/pages/BankingMorePages'));
const { BankingSetupPage, BpBankAccountsPage, CashPositionPage, DepositNewPage, DepositsPage, StatementPage, StatementsPage } = P_BankingMorePages('BankingSetupPage', 'BpBankAccountsPage', 'CashPositionPage', 'DepositNewPage', 'DepositsPage', 'StatementPage', 'StatementsPage');
const P_PurchasingPages = from(() => import('@/features/erp/pages/PurchasingPages'));
const { ApInvoiceNewPage, GrpoNewPage, LandedCostNewPage, LandedCostPage, LandedCostsPage, PurchaseDocEditPage, PurchaseDocNewPage, PurchaseDocPage, PurchaseViewPage, PurchasingSetupPage, QuotationComparePage } = P_PurchasingPages('ApInvoiceNewPage', 'GrpoNewPage', 'LandedCostNewPage', 'LandedCostPage', 'LandedCostsPage', 'PurchaseDocEditPage', 'PurchaseDocNewPage', 'PurchaseDocPage', 'PurchaseViewPage', 'PurchasingSetupPage', 'QuotationComparePage');
const P_MasterDataPages = from(() => import('@/features/erp/pages/MasterDataPages'));
const { BpChangesPage, BpFormPage, ItemFormPage, TrademarksPage } = P_MasterDataPages('BpChangesPage', 'BpFormPage', 'ItemFormPage', 'TrademarksPage');
const P_HrPages = from(() => import('@/features/erp/pages/HrPages'));
const { AttendancePage, ExpiryPage, LeaveListPage, LeavePage, PayslipPage, PortalPage } = P_HrPages('AttendancePage', 'ExpiryPage', 'LeaveListPage', 'LeavePage', 'PayslipPage', 'PortalPage');
const P_HrAdminPages = from(() => import('@/features/erp/pages/HrAdminPages'));
const { EmployeeDetailPage, EmployeeFormPage, HrSetupPage, PayrollListPage, PayrollRunPage } = P_HrAdminPages('EmployeeDetailPage', 'EmployeeFormPage', 'HrSetupPage', 'PayrollListPage', 'PayrollRunPage');
const P_InventoryPages = from(() => import('@/features/erp/pages/InventoryPages'));
const { CountNewPage, CountPage, CountsPage, InvDocPage, InventorySetupPage, LotPage, LotsPage, StockDocNewPage, TransferNewPage } = P_InventoryPages('CountNewPage', 'CountPage', 'CountsPage', 'InvDocPage', 'InventorySetupPage', 'LotPage', 'LotsPage', 'StockDocNewPage', 'TransferNewPage');
const P_AdminPages = from(() => import('@/features/erp/pages/AdminPages'));
const { AuthorizationsPage, UserFormPage, UsersPage } = P_AdminPages('AuthorizationsPage', 'UserFormPage', 'UsersPage');
const P_AdminSetupPages = from(() => import('@/features/erp/pages/AdminSetupPages'));
const { AiAssistantPage, ApprovalTemplatesPage, CompanyDetailsPage, ExchangeRatesPage } = P_AdminSetupPages('AiAssistantPage', 'ApprovalTemplatesPage', 'CompanyDetailsPage', 'ExchangeRatesPage');
const P_ApprovalProcessPages = from(() => import('@/features/erp/pages/ApprovalProcessPages'));
const { ApprovalStagesPage, ApprovalStatusReportPage, ApprovalTemplateFormPage, ApprovalTemplatesListPage } = P_ApprovalProcessPages('ApprovalStagesPage', 'ApprovalStatusReportPage', 'ApprovalTemplateFormPage', 'ApprovalTemplatesListPage');
const P_NumberingPages = from(() => import('@/features/erp/pages/NumberingPages'));
const { CompaniesPage, CompanyFormPage, DocNumberingPage } = P_NumberingPages('CompaniesPage', 'CompanyFormPage', 'DocNumberingPage');
const P_SalesRequestPages = from(() => import('@/features/erp/pages/SalesRequestPages'));
const { SalesRequestPage } = P_SalesRequestPages('SalesRequestPage');
const P_ReportPages = from(() => import('@/features/erp/pages/ReportPages'));
const { ReportPage, ReportPrintPage, ReportsLibraryPage } = P_ReportPages('ReportPage', 'ReportPrintPage', 'ReportsLibraryPage');
const P_ProductionPages = from(() => import('@/features/erp/pages/ProductionPages'));
const { BomFormPage, BomPage, BomsPage, MouldPage, MouldsPage, ProdOrderNewPage, ProdOrderPage, ProdOrdersPage, ProductionSetupPage } = P_ProductionPages('BomFormPage', 'BomPage', 'BomsPage', 'MouldPage', 'MouldsPage', 'ProdOrderNewPage', 'ProdOrderPage', 'ProdOrdersPage', 'ProductionSetupPage');
const P_GoLivePages = from(() => import('@/features/erp/pages/GoLivePages'));
const { GoLiveChecklistPage, GoLiveOverviewPage, SystemHealthPage } = P_GoLivePages('GoLiveChecklistPage', 'GoLiveOverviewPage', 'SystemHealthPage');
const P_ServicePages = from(() => import('@/features/erp/pages/ServicePages'));
const { ContractFormPage, ContractPage, ContractsPage, EquipmentCardPage, EquipmentPage, ServiceCallFormPage, ServiceCallPage, ServiceCallsPage, ServiceSetupPage } = P_ServicePages('ContractFormPage', 'ContractPage', 'ContractsPage', 'EquipmentCardPage', 'EquipmentPage', 'ServiceCallFormPage', 'ServiceCallPage', 'ServiceCallsPage', 'ServiceSetupPage');

// Paths from the first app shell, kept so old links and bookmarks still land somewhere sensible.
const legacy: Array<[string, string]> = [
  ['sales', '/m/sales'], ['purchase', '/m/purchasing'], ['accountant', '/m/financials'], ['warehouses', '/m/inventory'],
  ['hr', '/m/hr'], ['my-hr', '/'], ['field', '/'], ['logistics', '/'], ['quality', '/'], ['marketing', '/'],
];
const backOffice: Array<[string, string]> = [
  ['requests', 'tabs.requests'], ['licences', 'tabs.licences'], ['it', 'tabs.it'], ['sysadmin', 'tabs.sysadmin'],
];

/** Old links keep their ?company= when they move. */
function RedirectKeepQuery({ to }: { to: string }) {
  return <Navigate to={`${to}${useLocation().search}`} replace />;
}
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
    <Suspense fallback={<PageLoading />}>
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      {/* A4 · Print / PDF: a clean A4 page without the app shell */}
      <Route path="/print/:kind/:company/:entry" element={<RequireAccess access="signedIn"><SalesPrintPage /></RequireAccess>} />
      {/* A11 · report Print / PDF sheet */}
      <Route path="/print/report/:code" element={<RequireAccess access="signedIn"><ReportPrintPage /></RequireAccess>} />
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
        {/* A8 · master data: partner and item create / edit, change requests, Trademark Master (read-only) */}
        <Route path="bp/new" element={<BpFormPage key="bp-new" mode="new" />} />
        <Route path="bp/changes" element={<BpChangesPage />} />
        <Route path="bp/trademarks" element={<TrademarksPage />} />
        <Route path="bp/:company/:code/edit" element={<BpFormPage key="bp-edit" mode="edit" />} />
        <Route path="items/new" element={<ItemFormPage key="item-new" mode="new" />} />
        <Route path="items/:company/:code/edit" element={<ItemFormPage key="item-edit" mode="edit" />} />
        <Route path="bp/:company/:code" element={<BusinessPartnerDetail />} />
        <Route path="items" element={<ItemsPage />} />
        <Route path="items/:company/:code" element={<ItemDetail />} />
        <Route path="inventory/stock" element={<StockPage />} />
        <Route path="inventory/prices" element={<PricesPage />} />
        <Route path="inventory/special-prices" element={<SpecialPricesPage />} />
        <Route path="inventory/discounts" element={<DiscountGroupsPage />} />
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
        {/* B1 · credit memos and direct service invoices waiting for approval */}
        <Route path="sales/requests/:company/:id" element={<SalesRequestPage />} />
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
        {/* A9 · HR and Staff Portal */}
        <Route path="hr/employees/new" element={<EmployeeFormPage key="emp-new" mode="new" />} />
        <Route path="hr/employees/:company/:id" element={<EmployeeDetailPage />} />
        <Route path="hr/employees/:company/:id/edit" element={<EmployeeFormPage key="emp-edit" mode="edit" />} />
        <Route path="hr/leave" element={<LeaveListPage />} />
        <Route path="hr/leave/:company/:id" element={<LeavePage />} />
        <Route path="hr/attendance" element={<AttendancePage />} />
        <Route path="hr/expiry" element={<ExpiryPage />} />
        <Route path="hr/payroll" element={<PayrollListPage />} />
        <Route path="hr/payroll/:company/:id" element={<PayrollRunPage />} />
        <Route path="hr/setup" element={<HrSetupPage />} />
        <Route path="portal" element={<PortalPage />} />
        {/* A10 · Administration */}
        <Route path="admin/users" element={<UsersPage />} />
        <Route path="admin/users/invite" element={<UserFormPage key="u-new" mode="new" />} />
        <Route path="admin/users/:id" element={<UserFormPage key="u-edit" mode="edit" />} />
        <Route path="admin/authorizations" element={<AuthorizationsPage />} />
        {/* B2 · Approval Process: stages, templates (the earlier rule list stays under approval-rules), status report */}
        <Route path="admin/approval-templates" element={<RedirectKeepQuery to="/admin/approvals/templates" />} />
        <Route path="admin/approval-rules" element={<ApprovalTemplatesPage />} />
        <Route path="admin/approvals" element={<RedirectKeepQuery to="/admin/approvals/templates" />} />
        <Route path="admin/approvals/stages" element={<ApprovalStagesPage />} />
        <Route path="admin/approvals/templates" element={<ApprovalTemplatesListPage />} />
        <Route path="admin/approvals/templates/new" element={<ApprovalTemplateFormPage key="apr-new" mode="new" />} />
        <Route path="admin/approvals/templates/:id" element={<ApprovalTemplateFormPage key="apr-edit" mode="edit" />} />
        <Route path="admin/approvals/report" element={<ApprovalStatusReportPage />} />
        {/* B1 · Document Numbering (several series per type, user defaults) and Choose/Create Company */}
        <Route path="admin/numbering" element={<DocNumberingPage />} />
        <Route path="admin/companies" element={<CompaniesPage />} />
        <Route path="admin/companies/new" element={<CompanyFormPage key="cmp-new" mode="new" />} />
        <Route path="admin/companies/:code" element={<CompanyFormPage key="cmp-edit" mode="edit" />} />
        <Route path="admin/company" element={<CompanyDetailsPage />} />
        <Route path="admin/exchange-rates" element={<ExchangeRatesPage />} />
        <Route path="admin/ai-assistant" element={<AiAssistantPage />} />
        {/* A14 · go-live checklist per company and system health */}
        <Route path="admin/go-live" element={<GoLiveOverviewPage />} />
        <Route path="admin/go-live/:company" element={<GoLiveChecklistPage />} />
        <Route path="admin/health" element={<SystemHealthPage />} />
        <Route path="portal/payslip/:company/:run" element={<PayslipPage />} />
        {/* A11 · Reports */}
        <Route path="reports" element={<ReportsLibraryPage />} />
        <Route path="reports/:code" element={<ReportPage />} />
        {/* A13 · Production and Service */}
        <Route path="production/boms" element={<BomsPage />} />
        <Route path="production/boms/new" element={<BomFormPage key="bom-new" mode="new" />} />
        <Route path="production/boms/:company/:item" element={<BomPage />} />
        <Route path="production/boms/:company/:item/edit" element={<BomFormPage key="bom-edit" mode="edit" />} />
        <Route path="production/orders" element={<ProdOrdersPage />} />
        <Route path="production/orders/new" element={<ProdOrderNewPage />} />
        <Route path="production/orders/:company/:id" element={<ProdOrderPage />} />
        <Route path="production/moulds" element={<MouldsPage />} />
        <Route path="production/moulds/new" element={<MouldPage key="mould-new" mode="new" />} />
        <Route path="production/moulds/:company/:code" element={<MouldPage key="mould-view" mode="view" />} />
        <Route path="production/setup" element={<ProductionSetupPage />} />
        <Route path="service/calls" element={<ServiceCallsPage />} />
        <Route path="service/calls/new" element={<ServiceCallFormPage key="call-new" mode="new" />} />
        <Route path="service/calls/:company/:id" element={<ServiceCallPage />} />
        <Route path="service/calls/:company/:id/edit" element={<ServiceCallFormPage key="call-edit" mode="edit" />} />
        <Route path="service/equipment" element={<EquipmentPage />} />
        <Route path="service/equipment/new" element={<EquipmentCardPage key="eq-new" mode="new" />} />
        <Route path="service/equipment/:company/:id" element={<EquipmentCardPage key="eq-view" mode="view" />} />
        <Route path="service/contracts" element={<ContractsPage />} />
        <Route path="service/contracts/new" element={<ContractFormPage key="ct-new" mode="new" />} />
        <Route path="service/contracts/:company/:id" element={<ContractPage />} />
        <Route path="service/contracts/:company/:id/edit" element={<ContractFormPage key="ct-edit" mode="edit" />} />
        <Route path="service/setup" element={<ServiceSetupPage />} />

        {legacy.map(([from, to]) => <Route key={from} path={from} element={<Navigate to={to} replace />} />)}
        <Route path="approvals" element={<ApprovalsPage />} />
        <Route path="backoffice" element={<BackOfficeHome />} />
        {backOffice.map(([path, key]) => <Route key={path} path={`backoffice/${path}`} element={<PlaceholderPage nameKey={key} />} />)}

        <Route path="backoffice/migration" element={<RequireAccess access="migrationAdmin"><MigrationCentrePage /></RequireAccess>} />
        <Route path="backoffice/migration/upload" element={<RequireAccess access="migrationAdmin"><UploadPage /></RequireAccess>} />
        <Route path="backoffice/migration/runs/:runId" element={<RequireAccess access="migrationAdmin"><RunPage /></RequireAccess>} />
        {/* Finance / CFO signers reach only this screen */}
        <Route path="backoffice/migration/fields" element={<RequireAccess access="signedIn"><CustomFieldsPage /></RequireAccess>} />
        <Route path="backoffice/migration/runs/:runId/check" element={<RequireAccess access="migrationReviewer"><CrossCheckPage /></RequireAccess>} />

        <Route path="no-access" element={<NoAccessPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
    </Suspense>
  );
}
