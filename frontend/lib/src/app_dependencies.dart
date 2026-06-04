import 'dart:async';

import 'core/analytics_engine.dart';
import 'core/result.dart';
import 'data/models/analytics_event.dart';
import 'data/models/device_settings.dart';
import 'data/repositories/analytics_repository.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/business_alert_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/contact_repository.dart';
import 'data/repositories/dashboard_repository.dart';
import 'data/repositories/device_settings_repository.dart';
import 'data/repositories/discount_repository.dart';
import 'data/repositories/inventory_repository.dart';
import 'data/repositories/printing_repository.dart';
import 'data/repositories/purchase_repository.dart';
import 'data/repositories/register_session_repository.dart';
import 'data/repositories/report_repository.dart';
import 'data/repositories/sale_repository.dart';
import 'data/repositories/shop_settings_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/backend_discovery_service.dart';
import 'data/services/connection_coordinator.dart';
import 'data/services/connection_profile_storage.dart';
import 'data/services/pos_api_service.dart';
import 'data/services/pos_http_client.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/activity_log/view_models/activity_log_view_model.dart';
import 'features/contacts/view_models/contact_management_view_model.dart';
import 'features/dashboard/view_models/dashboard_view_model.dart';
import 'features/device_settings/view_models/device_settings_view_model.dart';
import 'features/discounts/view_models/discount_management_view_model.dart';
import 'features/notifications/view_models/notification_center_view_model.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'features/purchasing/view_models/purchase_order_list_view_model.dart';
import 'features/purchasing/view_models/purchase_view_model.dart';

class PointyAppDependencies {
  PointyAppDependencies({
    PosApiService? apiService,
    bool? enableAutomaticConnection,
  }) : service = apiService ?? PosApiService(),
       _enableAutomaticConnection =
           enableAutomaticConnection ?? apiService == null {
    analyticsRepository = AnalyticsRepository(service);
    analyticsEngine = AnalyticsEngine(analyticsRepository);
    service.performanceRecorder = analyticsEngine.recordApiRequest;
    authRepository = AuthRepository(service);
    catalogRepository = CatalogRepository(service);
    contactRepository = ContactRepository(service);
    dashboardRepository = DashboardRepository(service);
    deviceSettingsRepository = const DeviceSettingsRepository();
    businessAlertRepository = BusinessAlertRepository(service);
    discountRepository = DiscountRepository(service);
    inventoryRepository = InventoryRepository(service);
    registerSessionRepository = RegisterSessionRepository(service);
    reportRepository = ReportRepository(service);
    saleRepository = SaleRepository(service);
    shopSettingsRepository = ShopSettingsRepository(service);
    printingRepository = PrintingRepository(service);
    purchaseRepository = PurchaseRepository(service);
    userRepository = UserRepository(service);
    connectionCoordinator = ConnectionCoordinator(
      service: service,
      discovery: BackendDiscoveryService(
        client: createPosHttpClient(),
        defaultApiBaseUrl: service.baseUrl,
      ),
      storage: const SharedPreferencesConnectionProfileStorage(),
    );
    authViewModel = AuthViewModel(
      authRepository,
      analyticsEngine: analyticsEngine,
      autoLoad: false,
    );
    posViewModel = PosViewModel(
      catalogRepository,
      registerSessionRepository,
      saleRepository,
      shopSettingsRepository,
      printingRepository,
      analyticsEngine: analyticsEngine,
    );
  }

  final PosApiService service;
  final bool _enableAutomaticConnection;
  late final AnalyticsRepository analyticsRepository;
  late final AnalyticsEngine analyticsEngine;
  late final AuthRepository authRepository;
  late final CatalogRepository catalogRepository;
  late final ContactRepository contactRepository;
  late final DashboardRepository dashboardRepository;
  late final DeviceSettingsRepository deviceSettingsRepository;
  late final BusinessAlertRepository businessAlertRepository;
  late final DiscountRepository discountRepository;
  late final InventoryRepository inventoryRepository;
  late final RegisterSessionRepository registerSessionRepository;
  late final ReportRepository reportRepository;
  late final SaleRepository saleRepository;
  late final ShopSettingsRepository shopSettingsRepository;
  late final PrintingRepository printingRepository;
  late final PurchaseRepository purchaseRepository;
  late final UserRepository userRepository;
  late final ConnectionCoordinator connectionCoordinator;
  late final AuthViewModel authViewModel;
  late final PosViewModel posViewModel;
  DeviceSettingsViewModel? _deviceSettingsViewModel;
  PrintingSettingsViewModel? _printingSettingsViewModel;
  ContactManagementViewModel? _contactManagementViewModel;
  DiscountManagementViewModel? _discountManagementViewModel;
  NotificationCenterViewModel? _notificationCenterViewModel;
  ActivityLogViewModel? _activityLogViewModel;
  DashboardViewModel? _dashboardViewModel;
  PurchaseViewModel? _purchaseViewModel;
  PurchaseOrderListViewModel? _purchaseOrderListViewModel;

  int? _lastAuthenticatedUserId;

  Future<void> start() async {
    if (_enableAutomaticConnection) {
      await connectionCoordinator.bootstrap();
    }
    final usageModeResult = await deviceSettingsRepository.loadUsageMode();
    final usageMode = switch (usageModeResult) {
      Ok<DeviceUsageMode>(value: final mode) => mode,
      Error<DeviceUsageMode>() => DeviceUsageMode.singleUser,
    };
    await authViewModel.loadCurrentUser(
      forgetRememberedUser: usageMode == DeviceUsageMode.multiUser,
    );
  }

  DeviceSettingsViewModel get deviceSettingsViewModel =>
      _deviceSettingsViewModel ??= DeviceSettingsViewModel(
        deviceSettingsRepository,
      );

  PrintingSettingsViewModel get printingSettingsViewModel =>
      _printingSettingsViewModel ??= PrintingSettingsViewModel(
        printingRepository,
      );

  ContactManagementViewModel get contactManagementViewModel =>
      _contactManagementViewModel ??= ContactManagementViewModel(
        contactRepository,
      );

  DiscountManagementViewModel get discountManagementViewModel =>
      _discountManagementViewModel ??= DiscountManagementViewModel(
        discountRepository,
      );

  DashboardViewModel get dashboardViewModel =>
      _dashboardViewModel ??= DashboardViewModel(dashboardRepository);

  ActivityLogViewModel get activityLogViewModel => _activityLogViewModel ??=
      ActivityLogViewModel(analyticsRepository, userRepository);

  NotificationCenterViewModel get notificationCenterViewModel =>
      _notificationCenterViewModel ??= NotificationCenterViewModel(
        businessAlertRepository,
      );

  PurchaseViewModel get purchaseViewModel =>
      _purchaseViewModel ??= PurchaseViewModel(
        catalogRepository,
        purchaseRepository,
        analyticsEngine: analyticsEngine,
      );

  PurchaseOrderListViewModel get purchaseOrderListViewModel =>
      _purchaseOrderListViewModel ??= PurchaseOrderListViewModel(
        purchaseRepository,
      );

  void handleAuthChanged() {
    final currentUser = authViewModel.currentUser;
    if (authViewModel.status == AuthStatus.authenticated &&
        currentUser != null &&
        _lastAuthenticatedUserId != currentUser.id) {
      _lastAuthenticatedUserId = currentUser.id;
      analyticsEngine.setCurrentUser(currentUser.id);
      unawaited(
        analyticsEngine.trackUsage(
          AnalyticsEventName.authSessionStarted,
          attributes: {'role': currentUser.role.toJson()},
        ),
      );
      posViewModel.loadCurrentRegisterSession();
      posViewModel.loadCheckoutSettings();
      unawaited(notificationCenterViewModel.loadAlerts());
      if (_enableAutomaticConnection) {
        unawaited(connectionCoordinator.pairAuthenticatedDevice());
      }
      _dashboardViewModel?.loadDashboard();
      _purchaseViewModel?.loadCatalog();
      _purchaseOrderListViewModel?.loadOrders();
      _contactManagementViewModel?.loadContacts();
      _discountManagementViewModel?.loadRules();
      _activityLogViewModel?.loadEvents();
      _activityLogViewModel?.loadUsers();
    }

    if (authViewModel.status == AuthStatus.unauthenticated) {
      _lastAuthenticatedUserId = null;
      analyticsEngine.setCurrentUser(null);
      _disposeSessionViewModels();
    }
  }

  void dispose() {
    connectionCoordinator.dispose();
    analyticsEngine.dispose();
    authViewModel.dispose();
    posViewModel.dispose();
    _deviceSettingsViewModel?.dispose();
    _printingSettingsViewModel?.dispose();
    _disposeSessionViewModels();
  }

  void _disposeSessionViewModels() {
    _contactManagementViewModel?.dispose();
    _contactManagementViewModel = null;
    _discountManagementViewModel?.dispose();
    _discountManagementViewModel = null;
    _notificationCenterViewModel?.dispose();
    _notificationCenterViewModel = null;
    _activityLogViewModel?.dispose();
    _activityLogViewModel = null;
    _dashboardViewModel?.dispose();
    _dashboardViewModel = null;
    _purchaseViewModel?.dispose();
    _purchaseViewModel = null;
    _purchaseOrderListViewModel?.dispose();
    _purchaseOrderListViewModel = null;
  }
}
