import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/attachment_summary.dart';
import '../models/pos_user.dart';
import '../models/analytics_export.dart';
import '../models/analytics_event.dart';
import '../models/business_alert.dart';
import '../models/print_audit_event.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';
import '../models/product.dart';
import '../models/product_category.dart';
import '../models/product_draft.dart';
import '../models/product_image_search_result.dart';
import '../models/product_image_upload.dart';
import '../models/product_page.dart';
import '../models/product_update_draft.dart';
import '../models/product_variant.dart';
import '../models/product_variant_draft.dart';
import '../models/product_variant_page.dart';
import '../models/contact.dart';
import '../models/customer_activity.dart';
import '../models/dashboard.dart';
import '../models/discount_rule.dart';
import '../models/employee.dart';
import '../models/purchase_submission.dart';
import '../models/query.dart';
import '../models/register_cash_movement.dart';
import '../models/register_cash_movement_page.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../models/relay_pairing.dart';
import '../models/report_run.dart';
import '../models/sale_order.dart';
import '../models/sale_order_page.dart';
import '../models/shop_settings.dart';
import '../models/stock_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_page.dart';
import '../models/variant_option_page.dart';
import '../models/variant_option_query.dart';
import '../models/variant_option.dart';
import '../models/variant_option_draft.dart';
import '../models/variant_option_value.dart';
import '../models/variant_option_value_draft.dart';
import '../models/variant_option_value_page.dart';
import '../models/user_activity.dart';
import 'api_session.dart';
import 'analytics_api_client.dart';
import 'auth_api_client.dart';
import 'business_notification_api_client.dart';
import 'catalog_api_client.dart';
import 'customer_api_client.dart';
import 'dashboard_api_client.dart';
import 'discount_api_client.dart';
import 'employee_api_client.dart';
import 'inventory_api_client.dart';
import 'pos_http_client.dart';
import 'printing_api_client.dart';
import 'purchasing_api_client.dart';
import 'register_session_api_client.dart';
import 'relay_api_client.dart';
import 'reports_api_client.dart';
import 'sales_api_client.dart';
import 'shop_settings_api_client.dart';
import 'user_api_client.dart';

export 'api_session.dart' show PosApiException;

class PosApiService {
  PosApiService({
    http.Client? client,
    String baseUrl = 'http://127.0.0.1:8000/api',
  }) {
    _session = PosApiSession(
      client: client ?? createPosHttpClient(),
      baseUrl: baseUrl,
    );
    _analytics = AnalyticsApiClient(_session);
    _auth = AuthApiClient(_session);
    _businessNotifications = BusinessNotificationApiClient(_session);
    _users = UserApiClient(_session);
    _shopSettings = ShopSettingsApiClient(_session);
    _catalog = CatalogApiClient(_session);
    _customers = CustomerApiClient(_session);
    _dashboard = DashboardApiClient(_session);
    _discounts = DiscountApiClient(_session);
    _employees = EmployeeApiClient(_session);
    _inventory = InventoryApiClient(_session);
    _registerSessions = RegisterSessionApiClient(_session);
    _relay = RelayApiClient(_session);
    _reports = ReportsApiClient(_session);
    _sales = SalesApiClient(_session);
    _purchasing = PurchasingApiClient(_session);
    _printing = PrintingApiClient(_session);
  }

  String get baseUrl => _session.baseUrl;
  bool get usesRelay => _session.usesRelay;

  late final PosApiSession _session;
  late final AuthApiClient _auth;
  late final BusinessNotificationApiClient _businessNotifications;
  late final AnalyticsApiClient _analytics;
  late final UserApiClient _users;
  late final ShopSettingsApiClient _shopSettings;
  late final CatalogApiClient _catalog;
  late final CustomerApiClient _customers;
  late final DashboardApiClient _dashboard;
  late final DiscountApiClient _discounts;
  late final EmployeeApiClient _employees;
  late final InventoryApiClient _inventory;
  late final RegisterSessionApiClient _registerSessions;
  late final RelayApiClient _relay;
  late final ReportsApiClient _reports;
  late final SalesApiClient _sales;
  late final PurchasingApiClient _purchasing;
  late final PrintingApiClient _printing;

  set performanceRecorder(ApiPerformanceRecorder? recorder) {
    _session.performanceRecorder = recorder;
  }

  void configureConnectionTarget({
    required String baseUrl,
    String relayToken = '',
    ApiConnectionTarget? fallbackTarget,
  }) {
    _session.configureConnectionTarget(
      baseUrl: baseUrl,
      relayToken: relayToken,
      fallbackTarget: fallbackTarget,
    );
  }

  Future<PosUser> login({required String username, required String password}) {
    return _auth.login(username: username, password: password);
  }

  Future<void> logout() => _auth.logout();

  void clearAuthState() {
    _session.clearAuthState();
  }

  Future<PosUser?> fetchCurrentUser() => _auth.fetchCurrentUser();

  Future<AnalyticsIngestResult> ingestAnalyticsEvents(
    List<AnalyticsEventDraft> events,
  ) {
    return _analytics.ingestEvents(events);
  }

  Future<AnalyticsEventPage> fetchAnalyticsEvents({
    required AnalyticsEventQuery query,
    int page = 1,
  }) {
    return _analytics.fetchEvents(query: query, page: page);
  }

  Future<BusinessAlertDigest> fetchBusinessNotifications({
    bool includeHidden = true,
  }) {
    return _businessNotifications.fetchNotifications(
      includeHidden: includeHidden,
    );
  }

  Future<BusinessAlert> dismissBusinessNotification(String id) {
    return _businessNotifications.dismissNotification(id);
  }

  Future<BusinessAlert> snoozeBusinessNotification(
    String id, {
    required int hours,
  }) {
    return _businessNotifications.snoozeNotification(id, hours: hours);
  }

  Future<void> dismissAllBusinessNotifications() {
    return _businessNotifications.dismissAllNotifications();
  }

  Future<void> restoreHiddenBusinessNotifications() {
    return _businessNotifications.restoreHiddenNotifications();
  }

  Future<PosUserPage> fetchUsers({int page = 1, String search = ''}) {
    return _users.fetchUsers(page: page, search: search);
  }

  Future<PosUser> createUser(UserCreateDraft draft) {
    return _users.createUser(draft);
  }

  Future<PosUser> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) {
    return _users.updateUser(id: id, draft: draft);
  }

  Future<UserActivityOverview> fetchUserActivity(int id) {
    return _users.fetchUserActivity(id);
  }

  Future<EmployeePage> fetchEmployees({int page = 1, String search = ''}) {
    return _employees.fetchEmployees(page: page, search: search);
  }

  Future<Employee> createEmployee(EmployeeDraft draft) {
    return _employees.createEmployee(draft);
  }

  Future<CompensationPlan> createCompensationPlan(CompensationPlanDraft draft) {
    return _employees.createCompensationPlan(draft);
  }

  Future<PayrollRunPage> fetchPayrollRuns({int page = 1, String search = ''}) {
    return _employees.fetchPayrollRuns(page: page, search: search);
  }

  Future<PayrollRun> fetchPayrollRun(int id) {
    return _employees.fetchPayrollRun(id);
  }

  Future<PayrollRun> createPayrollRun(PayrollRunDraft draft) {
    return _employees.createPayrollRun(draft);
  }

  Future<PayrollRun> updatePayrollLineAdjustments(
    int payrollRunId,
    int payrollLineId,
    PayrollLineAdjustmentDraft draft,
  ) {
    return _employees.updatePayrollLineAdjustments(
      payrollRunId,
      payrollLineId,
      draft,
    );
  }

  Future<PayrollDraftResult> draftMonthlyPayrollRun() {
    return _employees.draftMonthlyPayrollRun();
  }

  Future<PayrollRun> approvePayrollRun(int id) {
    return _employees.approvePayrollRun(id);
  }

  Future<PayrollRun> markPayrollRunPaid(int id) {
    return _employees.markPayrollRunPaid(id);
  }

  Future<ShopSettings> fetchShopSettings() {
    return _shopSettings.fetchShopSettings();
  }

  Future<Uint8List?> fetchShopLogoBytes(ShopSettings? settings) async {
    final attachment = settings?.logoAttachment;
    final logoUrl = attachment?.contentUrl.trim();
    final contentType = attachment?.contentType.toLowerCase() ?? '';
    if (logoUrl == null ||
        logoUrl.isEmpty ||
        !_shopLogoPdfContentTypes.contains(contentType)) {
      return null;
    }

    final uri = _session.resolveUri(logoUrl);
    if (uri == null) {
      return null;
    }

    final response = await _session.getUri(
      uri,
      performancePath: 'shop-settings/logo-content/',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return response.bodyBytes;
  }

  Future<ShopSettings> updateShopSettings(ShopSettingsDraft draft) {
    return _shopSettings.updateShopSettings(draft);
  }

  Future<ShopSettings> uploadShopLogo(ShopLogoUpload upload) {
    return _shopSettings.uploadShopLogo(upload);
  }

  Future<ShopSettings> removeShopLogo() {
    return _shopSettings.removeShopLogo();
  }

  Future<AnalyticsExportFile> exportAnalyticsEvents(
    AnalyticsExportQuery query,
  ) {
    return _shopSettings.exportAnalyticsEvents(query);
  }

  Future<ProductPage> fetchProducts({required ModelQuery query, int page = 1}) {
    return _catalog.fetchProducts(query: query, page: page);
  }

  Future<Product> createProduct(ProductDraft draft) {
    return _catalog.createProduct(draft);
  }

  Future<Product> updateProduct({
    required int id,
    required ProductUpdateDraft draft,
  }) {
    return _catalog.updateProduct(id: id, draft: draft);
  }

  Future<Product> fetchProduct(int id) {
    return _catalog.fetchProduct(id);
  }

  Future<AttachmentSummary> uploadProductImage({
    required int productId,
    required ProductImageUpload upload,
  }) {
    return _catalog.uploadProductImage(productId: productId, upload: upload);
  }

  Future<AttachmentSummary> importProductImage({
    required int productId,
    required String importToken,
  }) {
    return _catalog.importProductImage(
      productId: productId,
      importToken: importToken,
    );
  }

  Future<List<ProductImageSearchResult>> searchProductImages({
    required String query,
    int page = 1,
    int? pageSize,
  }) {
    return _catalog.searchProductImages(
      query: query,
      page: page,
      pageSize: pageSize,
    );
  }

  Future<ProductVariantPage> fetchProductVariants({
    required ModelQuery query,
    int page = 1,
  }) {
    return _catalog.fetchProductVariants(query: query, page: page);
  }

  Future<ProductVariantPage> fetchVariantsForProduct(
    int productId, {
    int page = 1,
  }) {
    return _catalog.fetchVariantsForProduct(productId, page: page);
  }

  Future<ProductVariant> createProductVariant(ProductVariantDraft draft) {
    return _catalog.createProductVariant(draft);
  }

  Future<ProductVariant> createVariantForProduct(
    int productId,
    ProductVariantDraft draft,
  ) {
    return _catalog.createVariantForProduct(productId, draft);
  }

  Future<ProductVariant> updateProductVariant({
    required int id,
    required ProductVariantDraft draft,
  }) {
    return _catalog.updateProductVariant(id: id, draft: draft);
  }

  Future<void> deleteProductVariant(int id) {
    return _catalog.deleteProductVariant(id);
  }

  Future<ProductCategoryPage> fetchProductCategories({
    required ModelQuery query,
    int page = 1,
  }) {
    return _catalog.fetchProductCategories(query: query, page: page);
  }

  Future<ProductCategory> createProductCategory(ProductCategoryDraft draft) {
    return _catalog.createProductCategory(draft);
  }

  Future<VariantOptionValuePage> fetchVariantOptionValues({
    required ModelQuery query,
    int page = 1,
  }) {
    return _catalog.fetchVariantOptionValues(query: query, page: page);
  }

  Future<VariantOptionValue> createVariantOptionValue(
    VariantOptionValueDraft draft,
  ) {
    return _catalog.createVariantOptionValue(draft);
  }

  Future<VariantOptionPage> fetchVariantOptions({
    required VariantOptionQuery query,
    int page = 1,
  }) {
    return _catalog.fetchVariantOptions(query: query, page: page);
  }

  Future<VariantOption> createVariantOption(VariantOptionDraft draft) {
    return _catalog.createVariantOption(draft);
  }

  Future<CustomerPage> fetchCustomers({
    required ContactQuery query,
    int page = 1,
  }) {
    return _customers.fetchCustomers(query: query, page: page);
  }

  Future<Customer> createCustomer(CustomerDraft draft) {
    return _customers.createCustomer(draft);
  }

  Future<Customer> fetchCustomer(int customerId) {
    return _customers.fetchCustomer(customerId);
  }

  Future<CustomerSalesSummary> fetchCustomerSalesSummary(int customerId) {
    return _customers.fetchCustomerSalesSummary(customerId);
  }

  Future<SaleOrderPage> fetchCustomerOrders({
    required int customerId,
    int page = 1,
  }) {
    return _customers.fetchCustomerOrders(customerId: customerId, page: page);
  }

  Future<CustomerAdjustmentHistoryPage> fetchCustomerAdjustments({
    required int customerId,
    int page = 1,
  }) {
    return _customers.fetchCustomerAdjustments(
      customerId: customerId,
      page: page,
    );
  }

  Future<ReportRun> createReportRun(ReportRunDraft draft) {
    return _reports.createReportRun(draft);
  }

  Future<DashboardSnapshot> fetchDashboard({required int days}) {
    return _dashboard.fetchDashboard(days: days);
  }

  Future<DiscountRulePage> fetchDiscountRules({
    required DiscountRuleQuery query,
    int page = 1,
  }) {
    return _discounts.fetchDiscountRules(query: query, page: page);
  }

  Future<DiscountRule> fetchDiscountRule(int id) {
    return _discounts.fetchDiscountRule(id);
  }

  Future<DiscountRulePerformance> fetchDiscountRulePerformance(int id) {
    return _discounts.fetchDiscountRulePerformance(id);
  }

  Future<DiscountBeneficiaryPage> fetchDiscountRuleBeneficiaries({
    required int id,
    int page = 1,
  }) {
    return _discounts.fetchDiscountRuleBeneficiaries(id: id, page: page);
  }

  Future<DiscountRule> createDiscountRule(DiscountRuleDraft draft) {
    return _discounts.createDiscountRule(draft);
  }

  Future<DiscountRule> updateDiscountRule({
    required int id,
    required DiscountRuleDraft draft,
  }) {
    return _discounts.updateDiscountRule(id: id, draft: draft);
  }

  Future<DiscountRule> enableDiscountRule(int id) {
    return _discounts.enableDiscountRule(id);
  }

  Future<DiscountRule> disableDiscountRule(int id) {
    return _discounts.disableDiscountRule(id);
  }

  Future<DiscountRule> archiveDiscountRule(int id) {
    return _discounts.archiveDiscountRule(id);
  }

  Future<StockItem?> fetchStockForProduct(int productId) {
    return _inventory.fetchStockForProduct(productId);
  }

  Future<StockItem?> fetchStockForVariant(int variantId) {
    return _inventory.fetchStockForVariant(variantId);
  }

  Future<StockMovementPage> fetchStockMovementsForProduct(
    int productId, {
    int page = 1,
  }) {
    return _inventory.fetchStockMovementsForProduct(productId, page: page);
  }

  Future<StockMovementPage> fetchStockMovementsForVariant(
    int variantId, {
    int page = 1,
  }) {
    return _inventory.fetchStockMovementsForVariant(variantId, page: page);
  }

  Future<StockMovement> createStockMovement(StockMovementDraft draft) {
    return _inventory.createStockMovement(draft);
  }

  Future<RegisterSession?> fetchCurrentRegisterSession() {
    return _registerSessions.fetchCurrentRegisterSession();
  }

  Future<RegisterSessionPage> fetchRegisterSessionHistory({int page = 1}) {
    return _registerSessions.fetchRegisterSessionHistory(page: page);
  }

  Future<SaleOrderPage> fetchRegisterSessionOrders(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) {
    return _registerSessions.fetchRegisterSessionOrders(
      sessionId,
      query: query,
      page: page,
    );
  }

  Future<RegisterCashMovementPage> fetchRegisterSessionCashMovements(
    int sessionId, {
    int page = 1,
  }) {
    return _registerSessions.fetchRegisterSessionCashMovements(
      sessionId,
      page: page,
    );
  }

  Future<RegisterCashMovement> createRegisterCashMovement({
    required int sessionId,
    required RegisterCashMovementType movementType,
    required RegisterCashMovementDraft draft,
  }) {
    return _registerSessions.createRegisterCashMovement(
      sessionId: sessionId,
      movementType: movementType,
      draft: draft,
    );
  }

  Future<RegisterSession> startRegisterSession({required double openingCash}) {
    return _registerSessions.startRegisterSession(openingCash: openingCash);
  }

  Future<RegisterSession> closeRegisterSession({
    required int sessionId,
    required RegisterSessionCloseDraft draft,
  }) {
    return _registerSessions.closeRegisterSession(
      sessionId: sessionId,
      draft: draft,
    );
  }

  Future<RelayPairing> requestRelayPairing({
    String deviceId = '',
    String deviceName = '',
  }) {
    return _relay.requestPairing(
      RelayPairingRequest(deviceId: deviceId, deviceName: deviceName),
    );
  }

  Future<SaleOrder> checkout(SaleCheckoutDraft draft) {
    return _sales.checkout(draft);
  }

  Future<SaleOrderPage> fetchOrders({
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) {
    return _sales.fetchOrders(query: query, page: page);
  }

  Future<SaleOrder> fetchOrder(int saleOrderId) {
    return _sales.fetchOrder(saleOrderId);
  }

  Future<SaleDiscountPreview> previewSaleDiscounts(
    SaleDiscountPreviewDraft draft,
  ) {
    return _sales.previewDiscounts(draft);
  }

  Future<PrintJob> requestSaleReprint(int saleOrderId) {
    return _sales.requestSaleReprint(saleOrderId);
  }

  Future<SaleOrder> voidSaleOrder({
    required int saleOrderId,
    required SaleVoidDraft draft,
  }) {
    return _sales.voidSaleOrder(saleOrderId: saleOrderId, draft: draft);
  }

  Future<SaleOrder> returnSaleOrderItems({
    required int saleOrderId,
    required SaleReturnDraft draft,
  }) {
    return _sales.returnSaleOrderItems(saleOrderId: saleOrderId, draft: draft);
  }

  Future<PurchaseOrder> createPurchaseOrder(PurchaseOrderDraft draft) {
    return _purchasing.createPurchaseOrder(draft);
  }

  Future<PurchaseDiscountPreview> previewPurchaseDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) {
    return _purchasing.previewDiscounts(draft);
  }

  Future<PurchaseOrder> fetchPurchaseOrder(int purchaseOrderId) {
    return _purchasing.fetchPurchaseOrder(purchaseOrderId);
  }

  Future<SupplierPaymentPage> fetchSupplierPayments({
    int? supplierId,
    int? purchaseOrderId,
    int page = 1,
  }) {
    return _purchasing.fetchSupplierPayments(
      supplierId: supplierId,
      purchaseOrderId: purchaseOrderId,
      page: page,
    );
  }

  Future<SupplierPayment> createSupplierPayment(SupplierPaymentDraft draft) {
    return _purchasing.createSupplierPayment(draft);
  }

  Future<PurchaseOrderPage> fetchOutstandingReceivedNotPaidPurchases({
    int page = 1,
  }) {
    return _purchasing.fetchOutstandingReceivedNotPaidPurchases(page: page);
  }

  Future<PurchaseOrderPage> fetchSupplierPurchaseHistory({
    required int supplierId,
    int page = 1,
  }) {
    return _purchasing.fetchSupplierPurchaseHistory(
      supplierId: supplierId,
      page: page,
    );
  }

  Future<ProductCostHistoryPage> fetchProductCostHistory({
    required int productId,
    int? variantId,
    int page = 1,
  }) {
    return _purchasing.fetchProductCostHistory(
      productId: productId,
      variantId: variantId,
      page: page,
    );
  }

  Future<ProductMarginImpact?> fetchProductMarginImpact(
    int productId, {
    int? variantId,
  }) {
    return _purchasing.fetchProductMarginImpact(
      productId,
      variantId: variantId,
    );
  }

  Future<PurchaseAdjustmentHistoryPage> fetchPurchaseAdjustmentHistory({
    PurchaseAdjustmentType? adjustmentType,
    int? supplierId,
    int? productId,
    int? variantId,
    int page = 1,
  }) {
    return _purchasing.fetchPurchaseAdjustmentHistory(
      adjustmentType: adjustmentType,
      supplierId: supplierId,
      productId: productId,
      variantId: variantId,
      page: page,
    );
  }

  Future<double?> fetchLastProductCost(int productId, {int? variantId}) {
    return _purchasing.fetchLastProductCost(productId, variantId: variantId);
  }

  Future<PurchaseOrderPage> fetchPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) {
    return _purchasing.fetchPurchaseOrders(query: query, page: page);
  }

  Future<PurchaseOrder> submitPurchaseOrder(int purchaseOrderId) {
    return _purchasing.submitPurchaseOrder(purchaseOrderId);
  }

  Future<PurchaseOrder> receivePurchaseOrder(
    int purchaseOrderId, {
    PurchaseReceiveDraft? draft,
  }) {
    return _purchasing.receivePurchaseOrder(purchaseOrderId, draft: draft);
  }

  Future<PurchaseOrder> cancelPurchaseOrder(int purchaseOrderId) {
    return _purchasing.cancelPurchaseOrder(purchaseOrderId);
  }

  Future<PurchaseOrder> returnPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) {
    return _purchasing.returnPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      draft: draft,
    );
  }

  Future<PurchaseOrder> refundPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) {
    return _purchasing.refundPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      draft: draft,
    );
  }

  Future<PurchaseOrder> exchangePurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) {
    return _purchasing.exchangePurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      draft: draft,
    );
  }

  Future<SupplierPage> fetchSuppliers({
    required ContactQuery query,
    int page = 1,
  }) {
    return _purchasing.fetchSuppliers(query: query, page: page);
  }

  Future<SupplierContact> fetchSupplier(int supplierId) {
    return _purchasing.fetchSupplier(supplierId);
  }

  Future<SupplierContact> createSupplier(SupplierDraft draft) {
    return _purchasing.createSupplier(draft);
  }

  Future<List<PrintJob>> fetchPrintJobs({
    PrintJobStatus? status,
    int page = 1,
  }) {
    return _printing.fetchPrintJobs(status: status, page: page);
  }

  Future<PrintJob> claimPrintJob({
    required int jobId,
    required String agentId,
    required PrinterEndpoint endpoint,
  }) {
    return _printing.claimPrintJob(
      jobId: jobId,
      agentId: agentId,
      endpoint: endpoint,
    );
  }

  Future<PrintJob?> claimNextPrintJob({
    required String agentId,
    required PrinterEndpoint endpoint,
  }) {
    return _printing.claimNextPrintJob(agentId: agentId, endpoint: endpoint);
  }

  Future<PrintJob> reportPrintJob({
    required int jobId,
    required PrintJobReportDraft report,
  }) {
    return _printing.reportPrintJob(jobId: jobId, report: report);
  }

  Future<List<PrintAuditEvent>> fetchPrintAuditEvents({
    required PrintAuditDocumentType documentType,
    required int documentId,
    int page = 1,
  }) {
    return _printing.fetchPrintAuditEvents(
      documentType: documentType,
      documentId: documentId,
      page: page,
    );
  }

  Future<PrintAuditEvent> recordPrintAuditEvent(PrintAuditEventDraft draft) {
    return _printing.recordPrintAuditEvent(draft);
  }

  Future<PrintAuditEvent> reportPrintAuditEvent({
    required int eventId,
    required PrintAuditEventReportDraft report,
  }) {
    return _printing.reportPrintAuditEvent(eventId: eventId, report: report);
  }
}

const _shopLogoPdfContentTypes = {'image/jpeg', 'image/jpg', 'image/png'};
