import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/attachment_summary.dart';
import '../models/pos_user.dart';
import '../models/analytics_export.dart';
import '../models/analytics_event.dart';
import '../models/bill_of_materials.dart';
import '../models/bought_together_product.dart';
import '../models/business_alert.dart';
import '../models/onboarding.dart';
import '../models/permission_catalog.dart';
import '../models/price_check_event.dart';
import '../models/price_checker_device.dart';
import '../models/price_lookup_result.dart';
import '../models/print_audit_event.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';
import '../models/product.dart';
import '../models/unit_of_measure.dart';
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
import '../models/customer_asset.dart';
import '../models/operations_job.dart';
import '../models/payment_card.dart';
import '../models/dashboard.dart';
import '../models/dashboard_ai_digest.dart';
import '../models/discount_rule.dart';
import '../models/employee.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/expense_ledger_entry.dart';
import '../models/fraud_finding.dart';
import '../models/purchase_submission.dart';
import '../models/query.dart';
import '../models/register_cash_movement.dart';
import '../models/migration.dart';
import '../models/register_cash_movement_page.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../models/register_session_summary.dart';
import '../../features/payments/models/payment_record.dart';
import '../models/relay_installation_status.dart';
import '../models/relay_pairing.dart';
import '../models/report_run.dart';
import '../models/sale_order.dart';
import '../models/sale_order_page.dart';
import '../models/modifier_group.dart';
import '../models/prep_station.dart';
import '../models/sales_channel.dart';
import '../models/shop_settings.dart';
import '../models/stock_count.dart';
import '../models/stock_count_draft.dart';
import '../models/stock_count_line.dart';
import '../models/stock_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_page.dart';
import '../models/system_backup.dart';
import '../models/variant_option_page.dart';
import '../models/variant_option_query.dart';
import '../models/variant_option.dart';
import '../models/variant_option_draft.dart';
import '../models/variant_option_value.dart';
import '../models/variant_option_value_draft.dart';
import '../models/variant_option_value_page.dart';
import '../models/user_activity.dart';
import '../models/workflow.dart';
import '../models/attendance.dart';
import '../models/ai_chat.dart';
import 'api_session.dart';
import 'ai_api_client.dart';
import 'analytics_api_client.dart';
import 'attendance_api_client.dart';
import 'auth_api_client.dart';
import 'business_notification_api_client.dart';
import 'catalog_api_client.dart';
import 'customer_api_client.dart';
import 'dashboard_api_client.dart';
import 'discount_api_client.dart';
import 'employee_api_client.dart';
import 'expense_api_client.dart';
import 'fraud_api_client.dart';
import 'inventory_api_client.dart';
import 'operations_api_client.dart';
import 'pos_http_client.dart';
import '../models/campaign.dart';
import '../models/conversation.dart';
import '../models/messaging_gateway.dart';
import 'crm_api_client.dart';
import 'messaging_api_client.dart';
import 'price_checker_api_client.dart';
import 'printing_api_client.dart';
import 'migration_api_client.dart';
import 'purchasing_api_client.dart';
import 'register_session_api_client.dart';
import 'relay_api_client.dart';
import 'reports_api_client.dart';
import 'sales_api_client.dart';
import 'modifier_group_api_client.dart';
import 'prep_station_api_client.dart';
import 'unit_of_measure_api_client.dart';
import 'sales_channel_api_client.dart';
import 'shop_settings_api_client.dart';
import 'stock_count_api_client.dart';
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
    _attendance = AttendanceApiClient(_session);
    _migration = MigrationApiClient(_session);
    _auth = AuthApiClient(_session);
    _businessNotifications = BusinessNotificationApiClient(_session);
    _users = UserApiClient(_session);
    _shopSettings = ShopSettingsApiClient(_session);
    _catalog = CatalogApiClient(_session);
    _customers = CustomerApiClient(_session);
    _dashboard = DashboardApiClient(_session);
    _discounts = DiscountApiClient(_session);
    _employees = EmployeeApiClient(_session);
    _expenses = ExpenseApiClient(_session);
    _fraud = FraudApiClient(_session);
    _inventory = InventoryApiClient(_session);
    _operations = OperationsApiClient(_session);
    _registerSessions = RegisterSessionApiClient(_session);
    _relay = RelayApiClient(_session);
    _reports = ReportsApiClient(_session);
    _sales = SalesApiClient(_session);
    _salesChannels = SalesChannelApiClient(_session);
    _prepStations = PrepStationApiClient(_session);
    _modifierGroups = ModifierGroupApiClient(_session);
    _unitsOfMeasure = UnitOfMeasureApiClient(_session);
    _purchasing = PurchasingApiClient(_session);
    _printing = PrintingApiClient(_session);
    _messaging = MessagingApiClient(_session);
    _crm = CrmApiClient(_session);
    _priceChecker = PriceCheckerApiClient(_session);
    _stockCounts = StockCountApiClient(_session);
    _ai = AiApiClient(_session);
  }

  String get baseUrl => _session.baseUrl;
  String? get catalogVersionToken => _session.catalogVersionToken;
  String? get discountsVersionToken => _session.discountsVersionToken;
  bool get usesRelay => _session.usesRelay;

  late final PosApiSession _session;
  late final AttendanceApiClient _attendance;
  late final MigrationApiClient _migration;
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
  late final ExpenseApiClient _expenses;
  late final FraudApiClient _fraud;
  late final InventoryApiClient _inventory;
  late final OperationsApiClient _operations;
  late final RegisterSessionApiClient _registerSessions;
  late final RelayApiClient _relay;
  late final ReportsApiClient _reports;
  late final SalesApiClient _sales;
  late final SalesChannelApiClient _salesChannels;
  late final PrepStationApiClient _prepStations;
  late final ModifierGroupApiClient _modifierGroups;
  late final UnitOfMeasureApiClient _unitsOfMeasure;
  late final PurchasingApiClient _purchasing;
  late final PrintingApiClient _printing;
  late final MessagingApiClient _messaging;
  late final CrmApiClient _crm;
  late final PriceCheckerApiClient _priceChecker;
  late final StockCountApiClient _stockCounts;
  late final AiApiClient _ai;

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

  Future<OnboardingStatus> fetchOnboardingStatus() {
    return _auth.fetchOnboardingStatus();
  }

  Future<PosUser> createInitialAdmin(InitialAdminDraft draft) {
    return _auth.createInitialAdmin(draft);
  }

  Future<PosUser> updateCurrentUser(CurrentUserProfileDraft draft) {
    return _auth.updateCurrentUser(draft);
  }

  Future<void> changePassword(PasswordChangeDraft draft) {
    return _auth.changePassword(draft);
  }

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

  Future<PosUserPage> fetchUsers({
    int page = 1,
    String search = '',
    String role = '',
  }) {
    return _users.fetchUsers(page: page, search: search, role: role);
  }

  Future<PermissionCatalog> fetchPermissionCatalog() {
    return _users.fetchPermissionCatalog();
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

  Future<FraudFindingPage> fetchFraudFindings({
    int page = 1,
    String status = '',
  }) {
    return _fraud.fetchFindings(page: page, status: status);
  }

  Future<FraudFinding> reviewFraudFinding(int id, {String note = ''}) {
    return _fraud.reviewFinding(id, note: note);
  }

  Future<FraudFinding> dismissFraudFinding(int id, {String note = ''}) {
    return _fraud.dismissFinding(id, note: note);
  }

  Future<FraudFinding> reopenFraudFinding(int id) {
    return _fraud.reopenFinding(id);
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

  Future<PayrollRun> createPayrollBulkAdjustment(
    int payrollRunId,
    PayrollBulkAdjustmentDraft draft,
  ) {
    return _employees.createPayrollBulkAdjustment(payrollRunId, draft);
  }

  Future<PayrollDraftResult> draftMonthlyPayrollRun() {
    return _employees.draftMonthlyPayrollRun();
  }

  Future<MigrationCatalog> fetchMigrationCatalog() {
    return _migration.fetchCatalog();
  }

  Future<List<MigrationSource>> fetchMigrationSources() {
    return _migration.fetchSources();
  }

  Future<MigrationSource> createMigrationSource(MigrationSourceDraft draft) {
    return _migration.createSource(draft);
  }

  Future<MigrationSource> updateMigrationSource(
    int id,
    MigrationSourceDraft draft,
  ) {
    return _migration.updateSource(id, draft);
  }

  Future<void> deleteMigrationSource(int id) {
    return _migration.deleteSource(id);
  }

  Future<List<DiscoveredServer>> discoverMigrationServers() {
    return _migration.discoverServers();
  }

  Future<MigrationConnectionTest> testMigrationConnection(int id) {
    return _migration.testConnection(id);
  }

  Future<CompatibilityReport> checkMigrationCompatibility(int id) {
    return _migration.checkCompatibility(id);
  }

  Future<MigrationRun> startMigrationRun({
    required int sourceId,
    required String mode,
    required List<String> entities,
    Map<String, Object?> options = const {},
  }) {
    return _migration.startRun(
      sourceId: sourceId,
      mode: mode,
      entities: entities,
      options: options,
    );
  }

  Future<MigrationRun> fetchMigrationRun(int id) {
    return _migration.fetchRun(id);
  }

  Future<List<MigrationRun>> fetchMigrationRuns({int? sourceId}) {
    return _migration.fetchRuns(sourceId: sourceId);
  }

  Future<MigrationIssuePage> fetchMigrationIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) {
    return _migration.fetchIssues(runId, page: page, severity: severity);
  }

  Future<AttendanceConfig> fetchAttendanceConfig() {
    return _attendance.fetchConfig();
  }

  Future<AttendanceConfig> updateAttendanceConfig(AttendanceConfigDraft draft) {
    return _attendance.updateConfig(draft);
  }

  Future<int> testAttendanceConnection() {
    return _attendance.testConnection();
  }

  Future<AttendanceSyncResult> syncAttendance() {
    return _attendance.sync();
  }

  Future<AttendanceProfilePage> fetchAttendanceProfiles({int page = 1}) {
    return _attendance.fetchProfiles(page: page);
  }

  Future<void> ensureAttendanceProfiles() {
    return _attendance.ensureProfiles();
  }

  Future<AttendanceProfileLink> updateAttendanceProfile(
    int profileId, {
    String? bioTimeEmpCode,
    bool? isTracked,
  }) {
    return _attendance.updateProfile(
      profileId,
      bioTimeEmpCode: bioTimeEmpCode,
      isTracked: isTracked,
    );
  }

  Future<AttendanceDayPage> fetchAttendanceDays({
    int page = 1,
    int? employeeId,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) {
    return _attendance.fetchDays(
      page: page,
      employeeId: employeeId,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );
  }

  Future<AttendanceSummary> fetchAttendanceSummary({
    required int employeeId,
    required DateTime dateFrom,
    required DateTime dateTo,
  }) {
    return _attendance.fetchSummary(
      employeeId: employeeId,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );
  }

  Future<PayrollRun> applyAttendanceToPayrollRun(int payrollRunId) {
    return _attendance.applyAttendanceToPayrollRun(payrollRunId);
  }

  Future<PayrollRun> approvePayrollRun(int id) {
    return _employees.approvePayrollRun(id);
  }

  Future<PayrollRun> markPayrollRunPaid(int id) {
    return _employees.markPayrollRunPaid(id);
  }

  Future<EmployeeLoanPage> fetchEmployeeLoans({
    int page = 1,
    String status = '',
  }) {
    return _employees.fetchEmployeeLoans(page: page, status: status);
  }

  Future<MyEmployeeLoans> fetchMyEmployeeLoans() {
    return _employees.fetchMyEmployeeLoans();
  }

  Future<EmployeeLoan> requestEmployeeLoan(EmployeeLoanRequestDraft draft) {
    return _employees.requestEmployeeLoan(draft);
  }

  Future<EmployeeLoan> approveEmployeeLoan(int id, {String reviewNotes = ''}) {
    return _employees.approveEmployeeLoan(id, reviewNotes: reviewNotes);
  }

  Future<EmployeeLoan> rejectEmployeeLoan(int id, {String reviewNotes = ''}) {
    return _employees.rejectEmployeeLoan(id, reviewNotes: reviewNotes);
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

  Future<ShopSettings> setupShop({
    required String shopType,
    String? shopName,
    bool? allowOverselling,
    bool? requireOpeningCash,
    bool? autoPrintReceipts,
    bool? autoPrintKitchenTickets,
  }) {
    return _shopSettings.setupShop(
      shopType: shopType,
      shopName: shopName,
      allowOverselling: allowOverselling,
      requireOpeningCash: requireOpeningCash,
      autoPrintReceipts: autoPrintReceipts,
      autoPrintKitchenTickets: autoPrintKitchenTickets,
    );
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

  Future<List<BackupDestination>> fetchBackupDestinations() {
    return _shopSettings.fetchBackupDestinations();
  }

  Future<BackupOperationsStatus> fetchBackupOperationsStatus() {
    return _shopSettings.fetchBackupOperationsStatus();
  }

  Future<BackupOperationsStatus> updateBackupSchedule(
    BackupScheduleDraft draft,
  ) {
    return _shopSettings.updateBackupSchedule(draft);
  }

  Future<SystemMaintenanceJob> startBackup() {
    return _shopSettings.startBackup();
  }

  Future<SystemMaintenanceJob> restoreBackup(RestoreBackupUpload upload) {
    return _shopSettings.restoreBackup(upload);
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

  Future<List<BoughtTogetherProduct>> fetchBoughtTogether(
    int productId, {
    int limit = 8,
  }) {
    return _catalog.fetchBoughtTogether(productId, limit: limit);
  }

  Future<Product> archiveProduct(int id) {
    return _catalog.archiveProduct(id);
  }

  Future<Product> restoreProduct(int id) {
    return _catalog.restoreProduct(id);
  }

  Future<int> bulkArchiveProducts({
    required List<int> ids,
    required bool archived,
  }) {
    return _catalog.bulkArchiveProducts(ids: ids, archived: archived);
  }

  Future<int> bulkRepriceProducts({
    required List<int> ids,
    required String mode,
    required double value,
  }) {
    return _catalog.bulkRepriceProducts(ids: ids, mode: mode, value: value);
  }

  Future<Product> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
  }) {
    return _catalog.setVariantPrices(
      productId: productId,
      pricesByVariant: pricesByVariant,
    );
  }

  Future<int> bulkCategorizeProducts({
    required List<int> ids,
    required List<int> categoryIds,
    required String mode,
  }) {
    return _catalog.bulkCategorizeProducts(
      ids: ids,
      categoryIds: categoryIds,
      mode: mode,
    );
  }

  Future<int> bulkSetProductFlags({
    required List<int> ids,
    bool? isActive,
    bool? tracksExpiry,
    bool? isService,
    bool? isPrepared,
  }) {
    return _catalog.bulkSetProductFlags(
      ids: ids,
      isActive: isActive,
      tracksExpiry: tracksExpiry,
      isService: isService,
      isPrepared: isPrepared,
    );
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

  Future<ProductCategory> updateProductCategory({
    required int id,
    required Map<String, Object?> changes,
  }) {
    return _catalog.updateProductCategory(id: id, changes: changes);
  }

  Future<void> deleteProductCategory(int id) {
    return _catalog.deleteProductCategory(id);
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

  Future<void> setCustomerConsent(
    int customerId, {
    bool? marketingOptedOut,
    bool? doNotContact,
  }) {
    return _customers.setCustomerConsent(
      customerId,
      marketingOptedOut: marketingOptedOut,
      doNotContact: doNotContact,
    );
  }

  Future<void> sendInvoiceSms(int saleOrderId) {
    return _sales.sendInvoiceSms(saleOrderId);
  }

  Future<CustomerSalesSummary> fetchCustomerSalesSummary(int customerId) {
    return _customers.fetchCustomerSalesSummary(customerId);
  }

  Future<CustomerSalesSummary> recordCustomerAccountPayment(
    int customerId, {
    required String method,
    required double amount,
    String cardReceiptUrl = '',
    String? idempotencyKey,
  }) {
    return _customers.recordCustomerAccountPayment(
      customerId,
      method: method,
      amount: amount,
      cardReceiptUrl: cardReceiptUrl,
      idempotencyKey: idempotencyKey,
    );
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

  Future<Customer> patchCustomer(int customerId, Map<String, Object?> body) {
    return _customers.patchCustomer(customerId, body);
  }

  Future<Customer> mergeCustomer({
    required int customerId,
    required int sourceId,
  }) {
    return _customers.mergeCustomer(customerId: customerId, sourceId: sourceId);
  }

  Future<PaymentCardPage> fetchCustomerCards({
    required int customerId,
    int page = 1,
  }) {
    return _customers.fetchCustomerCards(customerId: customerId, page: page);
  }

  Future<PaymentCard> reassignCard({
    required int cardId,
    required int customerId,
  }) {
    return _customers.reassignCard(cardId: cardId, customerId: customerId);
  }

  Future<ReportRun> createReportRun(ReportRunDraft draft) {
    return _reports.createReportRun(draft);
  }

  Future<DashboardSnapshot> fetchDashboard({required int days}) {
    return _dashboard.fetchDashboard(days: days);
  }

  Future<DashboardAiDigest> fetchDashboardAiDigest({required int days}) {
    return _dashboard.fetchAiDigest(days: days);
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

  Future<StockCount> startStockCount(StockCountStartDraft draft) {
    return _stockCounts.startCount(draft);
  }

  Future<StockCount?> fetchCurrentStockCount() {
    return _stockCounts.fetchCurrentCount();
  }

  Future<StockCountPage> fetchStockCounts({String? status, int page = 1}) {
    return _stockCounts.fetchCounts(status: status, page: page);
  }

  Future<StockCount> fetchStockCount(int countId) {
    return _stockCounts.fetchCount(countId);
  }

  Future<StockCountLine> recordStockCountLine(
    int countId,
    StockCountLineDraft draft,
  ) {
    return _stockCounts.countLine(countId, draft);
  }

  Future<List<StockCountLine>> fetchStockCountReconciliation(int countId) {
    return _stockCounts.fetchReconciliation(countId);
  }

  Future<StockCount> applyStockCount(
    int countId, {
    required String idempotencyKey,
  }) {
    return _stockCounts.applyCount(countId, idempotencyKey: idempotencyKey);
  }

  Future<StockCount> cancelStockCount(int countId) {
    return _stockCounts.cancelCount(countId);
  }

  Future<OperationsJobPage> fetchJobs({
    OperationsJobStatus? status,
    OperationsJobType? jobType,
    int? currentStage,
    int? assignedTo,
    int? customer,
    int? asset,
    int? workflowTemplate,
    String search = '',
    int page = 1,
  }) {
    return _operations.fetchJobs(
      status: status,
      jobType: jobType,
      currentStage: currentStage,
      assignedTo: assignedTo,
      customer: customer,
      asset: asset,
      workflowTemplate: workflowTemplate,
      search: search,
      page: page,
    );
  }

  Future<OperationsJob> fetchJob(int jobId) {
    return _operations.fetchJob(jobId);
  }

  Future<OperationsJob> createJob(
    OperationsJobDraft draft, {
    String? idempotencyKey,
  }) {
    return _operations.createJob(draft, idempotencyKey: idempotencyKey);
  }

  Future<OperationsJob> updateJob(int jobId, Map<String, Object?> changes) {
    return _operations.updateJob(jobId, changes);
  }

  Future<OperationsJob> assignJob(int jobId, int? employeeId) {
    return _operations.assignJob(jobId, employeeId);
  }

  Future<OperationsJob> transitionJob(
    int jobId, {
    required int toStage,
    String note = '',
    String? idempotencyKey,
  }) {
    return _operations.transitionJob(
      jobId,
      toStage: toStage,
      note: note,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<OperationsJob> addJobMaterial(
    int jobId, {
    required int variant,
    required double quantity,
    required bool consumeNow,
    String? idempotencyKey,
  }) {
    return _operations.addJobMaterial(
      jobId,
      variant: variant,
      quantity: quantity,
      consumeNow: consumeNow,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<OperationsJob> reverseJobMaterial(int jobId, int materialId) {
    return _operations.reverseJobMaterial(jobId, materialId);
  }

  Future<OperationsJob> cancelJob(int jobId, {String reason = ''}) {
    return _operations.cancelJob(jobId, reason: reason);
  }

  Future<OperationsJob> reopenJob(int jobId, {String note = ''}) {
    return _operations.reopenJob(jobId, note: note);
  }

  Future<OperationsJob> invoiceJob(
    int jobId,
    JobInvoiceDraft draft, {
    String? idempotencyKey,
  }) {
    return _operations.invoiceJob(jobId, draft, idempotencyKey: idempotencyKey);
  }

  Future<CustomerAssetPage> fetchCustomerAssets({
    int? customer,
    String search = '',
    int page = 1,
  }) {
    return _operations.fetchCustomerAssets(
      customer: customer,
      search: search,
      page: page,
    );
  }

  Future<CustomerAsset> createCustomerAsset(CustomerAssetDraft draft) {
    return _operations.createCustomerAsset(draft);
  }

  Future<CustomerAsset> updateCustomerAsset(
    int assetId,
    CustomerAssetDraft draft,
  ) {
    return _operations.updateCustomerAsset(assetId, draft);
  }

  Future<WorkflowTemplatePage> fetchWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
    int page = 1,
  }) {
    return _operations.fetchWorkflowTemplates(
      jobType: jobType,
      isActive: isActive,
      page: page,
    );
  }

  Future<WorkflowTemplate> saveWorkflowTemplate(WorkflowTemplateDraft draft) {
    return _operations.saveWorkflowTemplate(draft);
  }

  Future<void> deleteWorkflowTemplate(int templateId) {
    return _operations.deleteWorkflowTemplate(templateId);
  }

  Future<BillOfMaterialsPage> fetchBoms({bool? isActive, int page = 1}) {
    return _operations.fetchBoms(isActive: isActive, page: page);
  }

  Future<BillOfMaterials> saveBom(BillOfMaterialsDraft draft) {
    return _operations.saveBom(draft);
  }

  Future<void> deleteBom(int bomId) {
    return _operations.deleteBom(bomId);
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

  Future<RegisterSessionSummary> fetchRegisterSessionSummary(int sessionId) {
    return _registerSessions.fetchRegisterSessionSummary(sessionId);
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

  Future<RelayInstallationStatus> fetchRelayInstallationStatus({
    bool sync = false,
  }) {
    return _relay.fetchInstallationStatus(sync: sync);
  }

  Future<SaleOrder> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) {
    return _sales.checkout(draft, idempotencyKey: idempotencyKey);
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

  Future<CustomerPaymentPage> fetchCustomerPayments({
    String? method,
    int? customerId,
    DateTime? paidAtGte,
    DateTime? paidAtLte,
    int page = 1,
  }) {
    return _sales.fetchCustomerPayments(
      method: method,
      customerId: customerId,
      paidAtGte: paidAtGte,
      paidAtLte: paidAtLte,
      page: page,
    );
  }

  Future<SaleOrder> convertQuotation(
    int quotationId, {
    required SaleType saleType,
    double? amountReceived,
    String? idempotencyKey,
  }) {
    return _sales.convertQuotation(
      quotationId,
      saleType: saleType,
      amountReceived: amountReceived,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<SaleOrder> recordInvoicePayment(
    int saleOrderId, {
    required String method,
    required double amount,
    String cardReceiptUrl = '',
    String? idempotencyKey,
  }) {
    return _sales.recordInvoicePayment(
      saleOrderId,
      method: method,
      amount: amount,
      cardReceiptUrl: cardReceiptUrl,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<SaleOrder> assignSaleOrderCustomer(
    int saleOrderId, {
    required int customerId,
    String? idempotencyKey,
  }) {
    return _sales.assignSaleOrderCustomer(
      saleOrderId,
      customerId: customerId,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<SaleDiscountPreview> previewSaleDiscounts(
    SaleDiscountPreviewDraft draft,
  ) {
    return _sales.previewDiscounts(draft);
  }

  Future<SalesChannelPage> fetchSalesChannels({int page = 1}) {
    return _salesChannels.fetchSalesChannels(page: page);
  }

  Future<SalesChannelKeyGrant> createSalesChannel(SalesChannelDraft draft) {
    return _salesChannels.createSalesChannel(draft);
  }

  Future<SalesChannel> updateSalesChannel(
    int channelId,
    Map<String, Object?> changes,
  ) {
    return _salesChannels.updateSalesChannel(channelId, changes);
  }

  Future<void> deleteSalesChannel(int channelId) {
    return _salesChannels.deleteSalesChannel(channelId);
  }

  Future<SalesChannelKeyGrant> rotateSalesChannelKey(int channelId) {
    return _salesChannels.rotateSalesChannelKey(channelId);
  }

  Future<ExpenseCategoryPage> fetchExpenseCategories({int page = 1}) {
    return _expenses.fetchCategories(page: page);
  }

  Future<ExpenseCategory> createExpenseCategory(ExpenseCategoryDraft draft) {
    return _expenses.createCategory(draft);
  }

  Future<ExpenseCategory> updateExpenseCategory(
    int categoryId,
    Map<String, Object?> changes,
  ) {
    return _expenses.updateCategory(categoryId, changes);
  }

  Future<void> deleteExpenseCategory(int categoryId) {
    return _expenses.deleteCategory(categoryId);
  }

  Future<ExpenseLedger> fetchExpenseLedger({
    required DateTime start,
    required DateTime end,
  }) {
    return _expenses.fetchLedger(start: start, end: end);
  }

  Future<Expense> fetchExpense(int expenseId) {
    return _expenses.fetchExpense(expenseId);
  }

  Future<Expense> createExpense(ExpenseDraft draft) {
    return _expenses.createExpense(draft);
  }

  Future<Expense> updateExpense(int expenseId, ExpenseDraft draft) {
    return _expenses.updateExpense(expenseId, draft);
  }

  Future<void> deleteExpense(int expenseId) {
    return _expenses.deleteExpense(expenseId);
  }

  Future<PrepStationPage> fetchPrepStations({int page = 1}) {
    return _prepStations.fetchPrepStations(page: page);
  }

  Future<PrepStation> createPrepStation(PrepStationDraft draft) {
    return _prepStations.createPrepStation(draft);
  }

  Future<PrepStation> updatePrepStation(
    int stationId,
    Map<String, Object?> changes,
  ) {
    return _prepStations.updatePrepStation(stationId, changes);
  }

  Future<void> deletePrepStation(int stationId) {
    return _prepStations.deletePrepStation(stationId);
  }

  Future<ModifierGroupPage> fetchModifierGroups({int page = 1}) {
    return _modifierGroups.fetchModifierGroups(page: page);
  }

  Future<UnitOfMeasurePage> fetchUnitsOfMeasure({int page = 1, bool? active}) {
    return _unitsOfMeasure.fetchUnits(page: page, active: active);
  }

  Future<UnitOfMeasure> createUnitOfMeasure(UnitOfMeasureDraft draft) {
    return _unitsOfMeasure.createUnit(draft);
  }

  Future<UnitOfMeasure> updateUnitOfMeasure({
    required int id,
    required Map<String, Object?> changes,
  }) {
    return _unitsOfMeasure.updateUnit(id: id, changes: changes);
  }

  Future<void> deleteUnitOfMeasure(int id) {
    return _unitsOfMeasure.deleteUnit(id);
  }

  Future<ModifierGroup> createModifierGroup(ModifierGroupDraft draft) {
    return _modifierGroups.createModifierGroup(draft);
  }

  Future<ModifierGroup> updateModifierGroup(
    int groupId,
    ModifierGroupDraft draft,
  ) {
    return _modifierGroups.updateModifierGroup(groupId, draft);
  }

  Future<void> deleteModifierGroup(int groupId) {
    return _modifierGroups.deleteModifierGroup(groupId);
  }

  Future<PrintJob> requestSaleReprint(int saleOrderId) {
    return _sales.requestSaleReprint(saleOrderId);
  }

  Future<PrintJob> requeuePrintJob(int printJobId) {
    return _printing.requeuePrintJob(jobId: printJobId);
  }

  Future<List<MessagingGateway>> fetchMessagingGateways() =>
      _messaging.fetchGateways();

  Future<MessagingGateway> createMessagingGateway(
    MessagingGatewayDraft draft,
  ) => _messaging.createGateway(draft);

  Future<MessagingGateway> updateMessagingGateway(
    int id,
    MessagingGatewayDraft draft,
  ) => _messaging.updateGateway(id, draft);

  Future<void> deleteMessagingGateway(int id) => _messaging.deleteGateway(id);

  Future<MessagingSendResult> testSendMessagingGateway({
    required int id,
    required String to,
    String? body,
  }) => _messaging.testSend(id: id, to: to, body: body);

  Future<GatewayActivation> activateMessagingGateway(int id) =>
      _messaging.activate(id);

  Future<List<Conversation>> fetchConversations({String? status}) =>
      _crm.fetchConversations(status: status);

  Future<Conversation> fetchConversation(int id) => _crm.fetchConversation(id);

  Future<ConversationMessage> replyToConversation(int id, String body) =>
      _crm.reply(id, body);

  Future<Conversation> markConversationRead(int id) => _crm.markRead(id);

  Future<Conversation> startConversation(int customerId) =>
      _crm.startConversation(customerId);

  Future<List<Campaign>> fetchCampaigns({String? status}) =>
      _crm.fetchCampaigns(status: status);

  Future<Campaign> fetchCampaign(int id) => _crm.fetchCampaign(id);

  Future<Campaign> createCampaign(CampaignDraft draft) =>
      _crm.createCampaign(draft);

  Future<Campaign> updateCampaign(int id, CampaignDraft draft) =>
      _crm.updateCampaign(id, draft);

  Future<void> deleteCampaign(int id) => _crm.deleteCampaign(id);

  Future<CampaignPreview> previewCampaign(int id) => _crm.previewCampaign(id);

  Future<Campaign> sendCampaign(int id) => _crm.sendCampaign(id);

  Future<Campaign> cancelCampaign(int id) => _crm.cancelCampaign(id);

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

  Future<SaleOrder> exchangeSaleOrderItems({
    required int saleOrderId,
    required SaleExchangeDraft draft,
  }) {
    return _sales.exchangeSaleOrderItems(
      saleOrderId: saleOrderId,
      draft: draft,
    );
  }

  Future<SaleOrder> lookupSaleOrderByReceipt(String receiptNumber) {
    return _sales.lookupSaleOrderByReceipt(receiptNumber);
  }

  Future<PurchaseOrder> createPurchaseOrder(
    PurchaseOrderDraft draft, {
    String? idempotencyKey,
  }) {
    return _purchasing.createPurchaseOrder(
      draft,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PurchaseOrder> updatePurchaseOrder(
    int purchaseOrderId,
    PurchaseOrderDraft draft,
  ) {
    return _purchasing.updatePurchaseOrder(purchaseOrderId, draft);
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
    String? method,
    DateTime? paidAtGte,
    DateTime? paidAtLte,
    int page = 1,
  }) {
    return _purchasing.fetchSupplierPayments(
      supplierId: supplierId,
      purchaseOrderId: purchaseOrderId,
      method: method,
      paidAtGte: paidAtGte,
      paidAtLte: paidAtLte,
      page: page,
    );
  }

  Future<SupplierPayment> createSupplierPayment(
    SupplierPaymentDraft draft, {
    String? idempotencyKey,
  }) {
    return _purchasing.createSupplierPayment(
      draft,
      idempotencyKey: idempotencyKey,
    );
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

  Future<List<VariantCostSummary>> fetchProductCostSummary(int productId) {
    return _purchasing.fetchProductCostSummary(productId);
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

  Future<({double? suggestedPrice, double? markupPercent})> fetchPricingSuggestion(
    double unitCost,
  ) {
    return _purchasing.fetchPricingSuggestion(unitCost);
  }

  Future<PurchaseOrderPage> fetchPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) {
    return _purchasing.fetchPurchaseOrders(query: query, page: page);
  }

  Future<PurchaseOrder> submitPurchaseOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) {
    return _purchasing.submitPurchaseOrder(
      purchaseOrderId,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PurchaseOrder> receivePurchaseOrder(
    int purchaseOrderId, {
    PurchaseReceiveDraft? draft,
    String? idempotencyKey,
  }) {
    return _purchasing.receivePurchaseOrder(
      purchaseOrderId,
      draft: draft,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PurchaseOrder> cancelPurchaseOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) {
    return _purchasing.cancelPurchaseOrder(
      purchaseOrderId,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PurchaseOrder> returnPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) {
    return _purchasing.returnPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      draft: draft,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PurchaseOrder> refundPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) {
    return _purchasing.refundPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      draft: draft,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PurchaseOrder> exchangePurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) {
    return _purchasing.exchangePurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      draft: draft,
      idempotencyKey: idempotencyKey,
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

  Future<SupplierContact> patchSupplier(
    int supplierId,
    Map<String, Object?> body,
  ) {
    return _purchasing.patchSupplier(supplierId, body);
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
    PrintAuditPaymentKind? paymentKind,
    int page = 1,
  }) {
    return _printing.fetchPrintAuditEvents(
      documentType: documentType,
      documentId: documentId,
      paymentKind: paymentKind,
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

  Future<List<PriceCheckerDevice>> fetchPriceCheckerDevices({int page = 1}) {
    return _priceChecker.fetchDevices(page: page);
  }

  Future<PriceCheckerScanSummary> runPriceCheckerScan() {
    return _priceChecker.runScan();
  }

  Future<List<PriceCheckEvent>> fetchPriceCheckEvents({
    int? deviceId,
    int page = 1,
  }) {
    return _priceChecker.fetchEvents(deviceId: deviceId, page: page);
  }

  Future<PriceLookupResult> lookupPrice({
    required String barcode,
    String deviceIdentifier = '',
  }) {
    return _priceChecker.lookup(
      barcode: barcode,
      deviceIdentifier: deviceIdentifier,
    );
  }

  Future<void> registerPriceCheckerKiosk({
    required String identifier,
    String name = '',
    String location = '',
  }) {
    return _priceChecker.registerKiosk(
      identifier: identifier,
      name: name,
      location: location,
    );
  }

  Stream<AiChatEvent> streamAiChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) {
    return _ai.streamChat(
      conversationId: conversationId,
      message: message,
      attachments: attachments,
    );
  }

  Stream<AiChatEvent> streamAiChatResume({
    required int conversationId,
    required int messageId,
    required String toolCallId,
    List<AiAnswer> answers = const [],
    bool declined = false,
  }) {
    return _ai.resumeChat(
      conversationId: conversationId,
      messageId: messageId,
      toolCallId: toolCallId,
      answers: answers,
      declined: declined,
    );
  }

  Future<AiUsage> fetchAiUsage() {
    return _ai.fetchUsage();
  }

  Future<List<AiConversationSummary>> fetchAiConversations({int page = 1}) {
    return _ai.fetchConversations(page: page);
  }

  Future<AiConversation> fetchAiConversation(int id) {
    return _ai.fetchConversation(id);
  }

  Future<void> deleteAiConversation(int id) {
    return _ai.deleteConversation(id);
  }

  Future<void> truncateAiConversation(int conversationId, int messageId) {
    return _ai.truncateConversation(conversationId, messageId);
  }
}

const _shopLogoPdfContentTypes = {'image/jpeg', 'image/jpg', 'image/png'};
