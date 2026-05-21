import 'package:http/http.dart' as http;

import '../models/pos_user.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';
import '../models/product.dart';
import '../models/product_category.dart';
import '../models/product_draft.dart';
import '../models/product_page.dart';
import '../models/product_update_draft.dart';
import '../models/product_variant.dart';
import '../models/product_variant_draft.dart';
import '../models/product_variant_page.dart';
import '../models/contact.dart';
import '../models/dashboard.dart';
import '../models/discount_rule.dart';
import '../models/purchase_submission.dart';
import '../models/query.dart';
import '../models/register_cash_movement.dart';
import '../models/register_cash_movement_page.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../models/sale_order.dart';
import '../models/sale_order_page.dart';
import '../models/shop_settings.dart';
import '../models/stock_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_page.dart';
import '../models/variant_option_value_page.dart';
import 'api_session.dart';
import 'auth_api_client.dart';
import 'catalog_api_client.dart';
import 'customer_api_client.dart';
import 'dashboard_api_client.dart';
import 'discount_api_client.dart';
import 'inventory_api_client.dart';
import 'pos_http_client.dart';
import 'printing_api_client.dart';
import 'purchasing_api_client.dart';
import 'register_session_api_client.dart';
import 'sales_api_client.dart';
import 'shop_settings_api_client.dart';
import 'user_api_client.dart';

export 'api_session.dart' show PosApiException;

class PosApiService {
  PosApiService({
    http.Client? client,
    this.baseUrl = 'http://127.0.0.1:8000/api',
  }) {
    final session = PosApiSession(
      client: client ?? createPosHttpClient(),
      baseUrl: baseUrl,
    );
    _auth = AuthApiClient(session);
    _users = UserApiClient(session);
    _shopSettings = ShopSettingsApiClient(session);
    _catalog = CatalogApiClient(session);
    _customers = CustomerApiClient(session);
    _dashboard = DashboardApiClient(session);
    _discounts = DiscountApiClient(session);
    _inventory = InventoryApiClient(session);
    _registerSessions = RegisterSessionApiClient(session);
    _sales = SalesApiClient(session);
    _purchasing = PurchasingApiClient(session);
    _printing = PrintingApiClient(session);
  }

  final String baseUrl;

  late final AuthApiClient _auth;
  late final UserApiClient _users;
  late final ShopSettingsApiClient _shopSettings;
  late final CatalogApiClient _catalog;
  late final CustomerApiClient _customers;
  late final DashboardApiClient _dashboard;
  late final DiscountApiClient _discounts;
  late final InventoryApiClient _inventory;
  late final RegisterSessionApiClient _registerSessions;
  late final SalesApiClient _sales;
  late final PurchasingApiClient _purchasing;
  late final PrintingApiClient _printing;

  Future<PosUser> login({required String username, required String password}) {
    return _auth.login(username: username, password: password);
  }

  Future<void> logout() => _auth.logout();

  Future<PosUser?> fetchCurrentUser() => _auth.fetchCurrentUser();

  Future<PosUserPage> fetchUsers({int page = 1}) {
    return _users.fetchUsers(page: page);
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

  Future<ShopSettings> fetchShopSettings() {
    return _shopSettings.fetchShopSettings();
  }

  Future<ShopSettings> updateShopSettings(ShopSettingsDraft draft) {
    return _shopSettings.updateShopSettings(draft);
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

  Future<CustomerPage> fetchCustomers({
    required ContactQuery query,
    int page = 1,
  }) {
    return _customers.fetchCustomers(query: query, page: page);
  }

  Future<Customer> createCustomer(CustomerDraft draft) {
    return _customers.createCustomer(draft);
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

  Future<SaleOrder> checkout(SaleCheckoutDraft draft) {
    return _sales.checkout(draft);
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
    int page = 1,
  }) {
    return _purchasing.fetchPurchaseAdjustmentHistory(
      adjustmentType: adjustmentType,
      supplierId: supplierId,
      productId: productId,
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
}
