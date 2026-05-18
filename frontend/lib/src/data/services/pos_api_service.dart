import 'package:http/http.dart' as http;

import '../models/pos_user.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';
import '../models/product.dart';
import '../models/product_page.dart';
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
import 'api_session.dart';
import 'auth_api_client.dart';
import 'catalog_api_client.dart';
import 'inventory_api_client.dart';
import 'pos_http_client.dart';
import 'printing_api_client.dart';
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
    _inventory = InventoryApiClient(session);
    _registerSessions = RegisterSessionApiClient(session);
    _sales = SalesApiClient(session);
    _printing = PrintingApiClient(session);
  }

  final String baseUrl;

  late final AuthApiClient _auth;
  late final UserApiClient _users;
  late final ShopSettingsApiClient _shopSettings;
  late final CatalogApiClient _catalog;
  late final InventoryApiClient _inventory;
  late final RegisterSessionApiClient _registerSessions;
  late final SalesApiClient _sales;
  late final PrintingApiClient _printing;

  Future<PosUser> login({required String username, required String password}) {
    return _auth.login(username: username, password: password);
  }

  Future<void> logout() => _auth.logout();

  Future<PosUser?> fetchCurrentUser() => _auth.fetchCurrentUser();

  Future<List<PosUser>> fetchUsers() => _users.fetchUsers();

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

  Future<StockItem?> fetchStockForProduct(int productId) {
    return _inventory.fetchStockForProduct(productId);
  }

  Future<StockMovementPage> fetchStockMovementsForProduct(
    int productId, {
    int page = 1,
  }) {
    return _inventory.fetchStockMovementsForProduct(productId, page: page);
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
    int page = 1,
  }) {
    return _registerSessions.fetchRegisterSessionOrders(sessionId, page: page);
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
